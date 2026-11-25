//go:build linux && !android

package linkctl

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"devicebridge/protocol"
)

var wifiDirect struct {
	sync.Mutex
	group *linuxP2PGroup
}

type linuxP2PGroup struct {
	iface, dir string
	ifindex    int
	processes  []p2pProcess
	result     protocol.ConnectionPrepareResult
}

type p2pProcess struct {
	cmd  *exec.Cmd
	done <-chan struct{}
}

func (g *linuxP2PGroup) startProcess(name string, args ...string) (p2pProcess, error) {
	cmd := exec.Command(name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGTERM}
	if err := cmd.Start(); err != nil {
		return p2pProcess{}, fmt.Errorf("start %s: %w", name, err)
	}
	done := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		close(done)
	}()
	process := p2pProcess{cmd: cmd, done: done}
	g.processes = append(g.processes, process)
	return process, nil
}

func (g *linuxP2PGroup) close() {
	for i := len(g.processes) - 1; i >= 0; i-- {
		process := g.processes[i]
		_ = process.cmd.Process.Signal(syscall.SIGTERM)
		select {
		case <-process.done:
		case <-time.After(800 * time.Millisecond):
			_ = process.cmd.Process.Kill()
			<-process.done
		}
	}
	// Remove the run state before deleting the interface so observers that
	// wait for the interface to disappear never see leftover /run state.
	_ = os.RemoveAll(g.dir)
	if iface, err := net.InterfaceByName(g.iface); err == nil && iface.Index == g.ifindex {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = exec.CommandContext(ctx, "iw", "dev", g.iface, "del").Run()
	}
}

func (g *linuxP2PGroup) control(ctx context.Context, args ...string) (string, error) {
	out, err := exec.CommandContext(ctx, "wpa_cli",
		append([]string{"-p", filepath.Join(g.dir, "ctrl"), "-i", g.iface}, args...)...).Output()
	return strings.TrimSpace(string(out)), err
}

func canHostWifiDirect(iwList string) bool {
	if !hasCapNetAdmin() {
		return false
	}
	for _, tool := range []string{"iw", "ip", "nmcli", "wpa_supplicant", "wpa_cli", "dnsmasq"} {
		if _, err := exec.LookPath(tool); err != nil {
			return false
		}
	}
	return supportsConcurrentWifiDirect(iwList)
}

func supportsConcurrentWifiDirect(iwList string) bool {
	// The private supplicant starts on an AP interface and changes it to a GO.
	// Both interface types need to coexist with the regular station.
	for _, phy := range strings.Split(iwList, "Wiphy ") {
		section := strings.SplitN(phy, "valid interface combinations:", 2)
		if len(section) != 2 {
			continue
		}
		for _, combo := range strings.Split(section[1], "* #{")[1:] {
			combo, _, _ = strings.Cut(combo, "#channels")
			if strings.Contains(combo, "managed }") &&
				strings.Contains(combo, " AP,") &&
				strings.Contains(combo, "P2P-GO") {
				return true
			}
		}
	}
	return false
}

func p2pAddress() (netip.Prefix, error) {
	addresses, err := net.InterfaceAddrs()
	if err != nil {
		return netip.Prefix{}, err
	}
	for _, cidr := range []string{"192.168.49.1/24", "10.43.0.1/24", "10.44.0.1/24"} {
		candidate := netip.MustParsePrefix(cidr)
		overlap := false
		for _, address := range addresses {
			if existing, err := netip.ParsePrefix(address.String()); err == nil && candidate.Overlaps(existing) {
				overlap = true
				break
			}
		}
		if !overlap {
			return candidate, nil
		}
	}
	return netip.Prefix{}, errors.New("no unused IPv4 subnet for Wi-Fi Direct")
}

func startWifiDirect(ctx context.Context, req protocol.ConnectionPrepareRequest, onLinkUp func(string, string)) (protocol.ConnectionPrepareResult, error) {
	wifiDirect.Lock()
	defer wifiDirect.Unlock()
	result := protocol.ConnectionPrepareResult{Kind: req.Kind}
	if wifiDirect.group != nil {
		return result, errors.New("stop the existing Wi-Fi Direct group before creating another")
	}
	iwList, err := exec.CommandContext(ctx, "iw", "list").Output()
	if err != nil || !canHostWifiDirect(string(iwList)) {
		return result, errors.New("Wi-Fi Direct hosting requires concurrent radio modes, network administration, wpa_supplicant and dnsmasq")
	}
	parent, _ := wifiInterfaceName(ctx)
	if parent == "" {
		return result, errors.New("no managed Wi-Fi interface for Wi-Fi Direct")
	}
	station, err := net.InterfaceByName(parent)
	if err != nil {
		return result, err
	}
	address, err := p2pAddress()
	if err != nil {
		return result, err
	}
	dir, err := os.MkdirTemp("/run", "dbp2p-")
	if err != nil {
		return result, err
	}
	// Leave room for the P2P device name derived by wpa_supplicant.
	suffix := strings.TrimPrefix(filepath.Base(dir), "dbp2p-")
	group := &linuxP2PGroup{dir: dir, iface: "dbp2p" + suffix[:min(len(suffix), 5)]}
	defer func() {
		if wifiDirect.group != group {
			group.close()
		}
	}()
	config := filepath.Join(dir, "supplicant.conf")
	if err := os.WriteFile(config, []byte("ctrl_interface="+filepath.Join(dir, "ctrl")+"\np2p_no_group_iface=1\n"), 0600); err != nil {
		return result, err
	}
	if err := exec.CommandContext(ctx, "iw", "dev", parent, "interface", "add", group.iface, "type", "__ap").Run(); err != nil {
		return result, fmt.Errorf("create concurrent Wi-Fi Direct interface: %w", err)
	}
	iface, err := net.InterfaceByName(group.iface)
	if err != nil {
		return result, err
	}
	group.ifindex = iface.Index
	nmcli, _ := exec.LookPath("nmcli")
	if _, err := runNmcli(ctx, nmcli, 3*time.Second, "device", "set", group.iface, "managed", "no"); err != nil {
		return result, errors.New("could not reserve the Wi-Fi Direct interface outside NetworkManager")
	}
	iface, err = net.InterfaceByName(group.iface)
	if err != nil {
		return result, err
	}
	if len(station.HardwareAddr) == 6 && bytes.Equal(iface.HardwareAddr, station.HardwareAddr) {
		// Some drivers copy the station MAC to a new AP interface and
		// reject bringing it up while the station has that address.
		address := make(net.HardwareAddr, 6)
		if _, err := rand.Read(address); err != nil {
			return result, fmt.Errorf("generate Wi-Fi Direct interface address: %w", err)
		}
		address[0] = address[0]&0xfe | 0x02
		if bytes.Equal(address, station.HardwareAddr) {
			address[5] ^= 1
		}
		if err := exec.CommandContext(ctx, "ip", "link", "set", "dev", group.iface, "address", address.String()).Run(); err != nil {
			return result, fmt.Errorf("set distinct Wi-Fi Direct interface address: %w", err)
		}
	}
	supplicant, err := group.startProcess("wpa_supplicant", "-i", group.iface, "-c", config)
	if err != nil {
		return result, err
	}
	ticker := time.NewTicker(150 * time.Millisecond)
	defer ticker.Stop()
	for {
		if reply, _ := group.control(ctx, "ping"); reply == "PONG" {
			break
		}
		select {
		case <-supplicant.done:
			return result, errors.New("private Wi-Fi Direct supplicant exited")
		case <-ctx.Done():
			return result, ctx.Err()
		case <-ticker.C:
		}
	}
	freq := req.FrequencyMHz
	if freq == 0 {
		freq = ChannelToFreq(req.Channel)
	}
	if freq == 0 {
		if link := WifiLinkDetails(ctx, parent); link != nil {
			freq = link.FrequencyMHz
		}
	}
	args := []string{"p2p_group_add"}
	if freq > 0 {
		args = append(args, "freq="+strconv.Itoa(freq))
	}
	if req.BandwidthMHz >= 40 {
		args = append(args, "ht40")
	}
	if req.BandwidthMHz >= 80 && freq >= 5000 {
		args = append(args, "vht")
	}
	if reply, err := group.control(ctx, args...); err != nil || reply != "OK" {
		return result, errors.New("supplicant could not start Wi-Fi Direct on the requested channel")
	}
	var ssid string
	for ssid == "" {
		status, _ := group.control(ctx, "status")
		if strings.Contains(status, "mode=P2P GO\n") && strings.Contains(status, "wpa_state=COMPLETED") {
			for _, line := range strings.Split(status, "\n") {
				if name, ok := strings.CutPrefix(line, "ssid="); ok {
					ssid = name
					break
				}
			}
		}
		if ssid != "" {
			break
		}
		select {
		case <-supplicant.done:
			return result, errors.New("Wi-Fi Direct group stopped during setup")
		case <-ctx.Done():
			return result, ctx.Err()
		case <-ticker.C:
		}
	}
	pass, err := group.control(ctx, "p2p_get_passphrase")
	if err != nil || len(pass) < 8 || len(pass) > 63 {
		return result, errors.New("Wi-Fi Direct group did not return its passphrase")
	}
	if err := exec.CommandContext(ctx, "ip", "-4", "addr", "add", address.String(), "dev", group.iface).Run(); err != nil {
		return result, fmt.Errorf("assign Wi-Fi Direct IPv4 address: %w", err)
	}
	subnet := strings.TrimSuffix(address.Addr().String(), ".1")
	dhcp, err := group.startProcess("dnsmasq",
		"--conf-file=/dev/null", "--keep-in-foreground", "--port=0", "--bind-interfaces",
		"--interface="+group.iface, "--except-interface=lo", "--pid-file=",
		"--dhcp-range="+subnet+".10,"+subnet+".200,255.255.255.0,1h",
		"--dhcp-option=3", "--dhcp-option=6", "--dhcp-leasefile="+filepath.Join(dir, "leases"))
	if err != nil {
		return result, err
	}
	select {
	case <-dhcp.done:
		return result, errors.New("Wi-Fi Direct DHCP server exited")
	case <-ctx.Done():
		return result, ctx.Err()
	case <-time.After(200 * time.Millisecond):
	}
	result.OK, result.Status, result.Transport = true, "active", "lan"
	result.Interface, result.IP, result.CIDR = group.iface, address.Addr().String(), address.String()
	result.Endpoint = net.JoinHostPort(result.IP, "8731")
	result.SSID, result.Passphrase = ssid, pass
	if link := WifiLinkDetails(ctx, group.iface); link != nil {
		result.Band, result.Channel = link.Band, link.Channel
		result.FrequencyMHz, result.BandwidthMHz = link.FrequencyMHz, link.BandwidthMHz
		result.WifiStandard = link.WifiStandard
	}
	group.result = result
	wifiDirect.group = group
	if onLinkUp != nil {
		onLinkUp(result.Interface, result.CIDR)
	}
	return result, nil
}

func CloseWifiDirect() bool {
	wifiDirect.Lock()
	defer wifiDirect.Unlock()
	if wifiDirect.group == nil {
		return false
	}
	wifiDirect.group.close()
	wifiDirect.group = nil
	return true
}

func activeWifiDirect() (protocol.ConnectionPrepareResult, bool) {
	wifiDirect.Lock()
	defer wifiDirect.Unlock()
	group := wifiDirect.group
	if group == nil {
		return protocol.ConnectionPrepareResult{}, false
	}
	for _, process := range group.processes {
		select {
		case <-process.done:
			group.close()
			wifiDirect.group = nil
			return protocol.ConnectionPrepareResult{}, false
		default:
		}
	}
	return group.result, true
}
