//go:build !android

package linkctl

import (
	"context"
	"crypto/rand"
	"devicebridge/protocol"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	joinMu     sync.Mutex
	joinCancel context.CancelFunc
)

type savedWifiState struct {
	Interface  string `json:"interface"`
	Connection string `json:"connection"`
}

var (
	iwLinkFreqRe  = regexp.MustCompile(`freq:\s*(\d+)`)
	iwLinkHERe    = regexp.MustCompile(`\bHE-MCS\b|\bHE\b`)
	iwLinkVHTRe   = regexp.MustCompile(`\bVHT-MCS\b|\bVHT\b`)
	iwLinkHTRe    = regexp.MustCompile(`\bMCS\s+\d+`)
	iwLinkEHTRe   = regexp.MustCompile(`\bEHT-MCS\b|\bEHT\b`)
	iwInfoChanRe  = regexp.MustCompile(`channel\s+\d+\s+\((\d+)\s*MHz\),\s*width:\s*(\d+)\s*MHz`)
	iwLinkWidthRe = regexp.MustCompile(`(\d+)\s*MHz`)
)

func bandFromFreq(freq int) string {
	switch {
	case freq > 5925:
		return "6 GHz"
	case freq >= 5000:
		return "5 GHz"
	case freq >= 2400:
		return "2.4 GHz"
	default:
		return ""
	}
}

// ParseIwLinkDetails extracts real negotiated frequency, band, bandwidth, and Wi-Fi standard from `iw dev <iface> link` + `info`.
func ParseIwLinkDetails(iface, linkOut, infoOut string) *protocol.WifiLinkInfo {
	info := &protocol.WifiLinkInfo{Interface: iface}
	if m := iwLinkFreqRe.FindStringSubmatch(linkOut); len(m) == 2 {
		if f, err := strconv.Atoi(m[1]); err == nil && f > 0 {
			info.FrequencyMHz = f
			info.Channel = FreqToChannel(f)
			info.Band = bandFromFreq(f)
		}
	}
	if m := iwInfoChanRe.FindStringSubmatch(infoOut); len(m) == 3 {
		if info.FrequencyMHz == 0 {
			if f, err := strconv.Atoi(m[1]); err == nil && f > 0 {
				info.FrequencyMHz = f
				info.Channel = FreqToChannel(f)
				info.Band = bandFromFreq(f)
			}
		}
		if w, err := strconv.Atoi(m[2]); err == nil && w > 0 {
			info.BandwidthMHz = w
		}
	}
	for _, line := range strings.Split(linkOut, "\n") {
		tr := strings.TrimSpace(line)
		if strings.HasPrefix(tr, "SSID:") {
			info.SSID = strings.TrimSpace(strings.TrimPrefix(tr, "SSID:"))
		}
		if info.BandwidthMHz == 0 && (strings.HasPrefix(tr, "tx bitrate:") || strings.HasPrefix(tr, "rx bitrate:")) {
			if wm := iwLinkWidthRe.FindStringSubmatch(tr); len(wm) == 2 {
				if w, err := strconv.Atoi(wm[1]); err == nil && (w == 20 || w == 40 || w == 80 || w == 160 || w == 320) {
					info.BandwidthMHz = w
				}
			}
		}
	}
	switch {
	case iwLinkEHTRe.MatchString(linkOut):
		info.WifiStandard = "Wi-Fi 7 (802.11be)"
	case iwLinkHERe.MatchString(linkOut):
		info.WifiStandard = "Wi-Fi 6 (802.11ax)"
	case iwLinkVHTRe.MatchString(linkOut):
		info.WifiStandard = "Wi-Fi 5 (802.11ac)"
	case iwLinkHTRe.MatchString(linkOut):
		info.WifiStandard = "Wi-Fi 4 (802.11n)"
	}
	if info.FrequencyMHz == 0 && info.WifiStandard == "" && info.SSID == "" {
		return nil
	}
	return info
}

// WifiLinkDetails inspects the current wireless interface link frequency and Wi-Fi generation via `iw`.
func WifiLinkDetails(ctx context.Context, iface string) *protocol.WifiLinkInfo {
	iwPath, err := exec.LookPath("iw")
	if err != nil {
		return nil
	}
	if iface == "" {
		iface, _ = wifiInterfaceName(ctx)
	}
	if iface == "" {
		return nil
	}
	cctx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	linkBytes, _ := exec.CommandContext(cctx, iwPath, "dev", iface, "link").Output()
	infoBytes, _ := exec.CommandContext(cctx, iwPath, "dev", iface, "info").Output()
	return ParseIwLinkDetails(iface, string(linkBytes), string(infoBytes))
}

// DetectCapabilities inspects local nl80211 (`iw list`) and wired USB ADB state.
func DetectCapabilities(ctx context.Context) *protocol.DeviceCapabilities {
	if fromEnv := envCapabilities(); fromEnv != nil {
		return fromEnv
	}
	caps := &protocol.DeviceCapabilities{OS: runtime.GOOS, CheckedAt: time.Now().Unix()}
	if iwPath, err := exec.LookPath("iw"); err == nil {
		cctx, cancel := context.WithTimeout(ctx, 2*time.Second)
		out, err := exec.CommandContext(cctx, iwPath, "list").Output()
		cancel()
		if err == nil {
			text := string(out)
			caps.Wifi5GHz, caps.Wifi6, caps.Wifi6GHz, caps.WifiDirect, caps.HotspotAP, caps.HotspotSTA = ParseIwListCapabilities(text)
			caps.WifiDirectGO = caps.WifiDirect && canHostWifiDirect(text)
			usable5g, regLimited := ParseIwListDetails(text)
			caps.Usable5GHz = usable5g
			caps.Reg5GHzLimited = regLimited
		}
		rctx, rcancel := context.WithTimeout(ctx, 1*time.Second)
		if regOut, rerr := exec.CommandContext(rctx, iwPath, "reg", "get").Output(); rerr == nil {
			caps.RegCountry = ParseIwRegCountry(string(regOut))
		}
		rcancel()
		caps.CanSetRegdom = CanSetRegDomain(ctx)
	}
	if _, err := exec.LookPath("nmcli"); err != nil {
		caps.HotspotAP = false
	}
	caps.Hotspot5GHzAP = caps.HotspotAP && (len(caps.Usable5GHz) > 0 || (caps.Wifi5GHz && caps.CanSetRegdom))
	if adbPath := FindADBPath(); adbPath != "" {
		cctx, cancel := context.WithTimeout(ctx, 2*time.Second)
		out, err := exec.CommandContext(cctx, adbPath, "devices", "-l").Output()
		cancel()
		if err == nil && len(USBADBSerials(string(out))) > 0 {
			caps.USBAdb = true
		}
	}
	caps.Link = WifiLinkDetails(ctx, "")
	return caps
}

func hasCapNetAdmin() bool {
	b, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, "CapEff:") {
			hexStr := strings.TrimSpace(strings.TrimPrefix(line, "CapEff:"))
			v, perr := strconv.ParseUint(hexStr, 16, 64)
			return perr == nil && (v&(1<<12)) != 0
		}
	}
	return false
}

// CanSetRegDomain reports whether this daemon can run `iw reg set US` on the fly
// (UID 0, CAP_NET_ADMIN ambient capability, or passwordless `sudo iw`).
func CanSetRegDomain(ctx context.Context) bool {
	if os.Geteuid() == 0 || hasCapNetAdmin() {
		return true
	}
	iwPath, err := exec.LookPath("iw")
	if err != nil {
		return false
	}
	sudoPath, err := exec.LookPath("sudo")
	if err != nil {
		return false
	}
	cctx, cancel := context.WithTimeout(ctx, 800*time.Millisecond)
	defer cancel()
	return exec.CommandContext(cctx, sudoPath, "-n", "-l", iwPath).Run() == nil
}

// EnsureRegDomain switches cfg80211 to regulatory domain `country` (default "US")
// on the fly using CAP_NET_ADMIN / UID 0 or `sudo -n iw reg set`.
func EnsureRegDomain(ctx context.Context, country string) (bool, error) {
	if strings.TrimSpace(country) == "" {
		country = "US"
	}
	iwPath, err := exec.LookPath("iw")
	if err != nil {
		return false, err
	}
	cctx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	regOut, _ := exec.CommandContext(cctx, iwPath, "reg", "get").Output()
	cancel()
	if strings.EqualFold(ParseIwRegCountry(string(regOut)), country) {
		return false, nil
	}
	if os.Geteuid() == 0 || hasCapNetAdmin() {
		sctx, scancel := context.WithTimeout(ctx, 2*time.Second)
		out, serr := exec.CommandContext(sctx, iwPath, "reg", "set", country).CombinedOutput()
		scancel()
		if serr == nil {
			time.Sleep(200 * time.Millisecond)
			return true, nil
		}
		err = fmt.Errorf("iw reg set %s: %s (%w)", country, strings.TrimSpace(string(out)), serr)
	}
	if sudoPath, sErr := exec.LookPath("sudo"); sErr == nil {
		sctx, scancel := context.WithTimeout(ctx, 2*time.Second)
		out, serr := exec.CommandContext(sctx, sudoPath, "-n", iwPath, "reg", "set", country).CombinedOutput()
		scancel()
		if serr == nil {
			time.Sleep(200 * time.Millisecond)
			return true, nil
		}
		return false, fmt.Errorf("sudo -n iw reg set %s: %s (%w)", country, strings.TrimSpace(string(out)), serr)
	}
	return false, err
}

// RunADBReverse configures wired USB ADB reverse (phone 127.0.0.1:18731 -> host 127.0.0.1:8731)
// and forward tunnels, ignoring any wireless ADB serials.
func RunADBReverse(ctx context.Context, preferredSerial string) (protocol.ConnectionPrepareResult, error) {
	res := protocol.ConnectionPrepareResult{Kind: "adb_usb", Transport: "adb"}
	adbPath := FindADBPath()
	if adbPath == "" {
		return res, errors.New("adb binary not found on host")
	}
	cctx, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()
	out, err := exec.CommandContext(cctx, adbPath, "devices", "-l").Output()
	if err != nil {
		return res, fmt.Errorf("adb devices failed: %w", err)
	}
	serials := USBADBSerials(string(out))
	if len(serials) == 0 {
		return res, errors.New("no wired USB ADB device connected (wireless ADB ignored)")
	}
	serial := serials[0]
	if preferredSerial != "" {
		matched := false
		for _, s := range serials {
			if s == preferredSerial {
				serial = s
				matched = true
				break
			}
		}
		if !matched {
			return res, fmt.Errorf("wired USB ADB serial %q not connected", preferredSerial)
		}
	}
	if outRev, rerr := exec.CommandContext(cctx, adbPath, "-s", serial, "reverse", "tcp:18731", "tcp:8731").CombinedOutput(); rerr != nil {
		return res, fmt.Errorf("adb reverse failed: %s", strings.TrimSpace(string(outRev)))
	}
	// Also forward host -> device so bidirectional probing / laptop browsing works.
	fwdEp := ""
	fwdOut, _ := exec.CommandContext(cctx, adbPath, "-s", serial, "forward", "--list").Output()
	for _, line := range strings.Split(string(fwdOut), "\n") {
		f := strings.Fields(line)
		if len(f) >= 3 && f[0] == serial && f[2] == "tcp:8731" && strings.HasPrefix(f[1], "tcp:") {
			if p, pe := strconv.Atoi(strings.TrimPrefix(f[1], "tcp:")); pe == nil && p > 0 {
				fwdEp = net.JoinHostPort("127.0.0.1", strconv.Itoa(p))
				break
			}
		}
	}
	if fwdEp == "" {
		if fOut, fErr := exec.CommandContext(cctx, adbPath, "-s", serial, "forward", "tcp:0", "tcp:8731").Output(); fErr == nil {
			if p, pe := strconv.Atoi(strings.TrimSpace(string(fOut))); pe == nil && p > 0 {
				fwdEp = net.JoinHostPort("127.0.0.1", strconv.Itoa(p))
			}
		}
	}
	res.OK = true
	res.Serial = serial
	res.Endpoint = "127.0.0.1:18731"
	res.Status = "ready"
	if fwdEp != "" {
		res.Message = "USB ADB reverse tcp:18731->8731 and forward " + fwdEp + " active"
	} else {
		res.Message = "USB ADB reverse tcp:18731->8731 active"
	}
	return res, nil
}

const tempWifiProfile = "DeviceBridge-Direct"

func wifiInterfaceName(ctx context.Context) (string, string) {
	nmcli, err := exec.LookPath("nmcli")
	if err != nil {
		return "", ""
	}
	cctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	out, err := exec.CommandContext(cctx, nmcli, "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "dev").Output()
	if err != nil {
		return "", ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		parts := strings.SplitN(strings.TrimSpace(line), ":", 4)
		if len(parts) == 4 && parts[1] == "wifi" {
			con := parts[3]
			if con == "--" {
				con = ""
			}
			return parts[0], con
		}
	}
	return "", ""
}

func savePrevWifi(stateDir, iface, con string) {
	if stateDir == "" || iface == "" || con == "" || con == tempWifiProfile {
		return
	}
	path := filepath.Join(stateDir, "prev_wifi.json")
	if b, err := json.Marshal(savedWifiState{Interface: iface, Connection: con}); err == nil {
		_ = os.WriteFile(path, b, 0600)
	}
}

func loadPrevWifi(stateDir string) (savedWifiState, bool) {
	if stateDir == "" {
		return savedWifiState{}, false
	}
	b, err := os.ReadFile(filepath.Join(stateDir, "prev_wifi.json"))
	if err != nil {
		return savedWifiState{}, false
	}
	var st savedWifiState
	if json.Unmarshal(b, &st) != nil || st.Connection == "" {
		return savedWifiState{}, false
	}
	return st, true
}

func readWifiIPv4(ctx context.Context, nmcli, iface string) (ip, cidr string) {
	cctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(cctx, nmcli, "-t", "-f", "IP4.ADDRESS", "dev", "show", iface).Output()
	if err != nil {
		return "", ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		if idx := strings.Index(line, ":"); idx > 0 {
			val := strings.TrimSpace(line[idx+1:])
			if val != "" && strings.Contains(val, "/") {
				return strings.SplitN(val, "/", 2)[0], val
			}
		}
	}
	return "", ""
}

func readIwLinkDetails(ctx context.Context, iface string) (freq int, band, std string) {
	iwPath, err := exec.LookPath("iw")
	if err != nil || iface == "" {
		return 0, "", ""
	}
	cctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(cctx, iwPath, "dev", iface, "link").Output()
	if err != nil {
		return 0, "", ""
	}
	text := string(out)
	if m := iwLinkFreqRe.FindStringSubmatch(text); len(m) == 2 {
		freq, _ = strconv.Atoi(m[1])
		switch {
		case freq > 5925:
			band = "6 GHz"
		case freq >= 5000:
			band = "5 GHz"
		case freq >= 2400:
			band = "2.4 GHz"
		}
	}
	if iwLinkHERe.MatchString(text) {
		std = "Wi-Fi 6 (802.11ax)"
	} else if strings.Contains(text, "VHT-MCS") {
		std = "Wi-Fi 5 (802.11ac)"
	}
	return freq, band, std
}

// runNmcli invokes nmcli and retries via passwordless `sudo -n nmcli` if non-session PolicyKit denies access.
func runNmcli(ctx context.Context, nmcli string, timeout time.Duration, args ...string) ([]byte, error) {
	cctx, cancel := context.WithTimeout(ctx, timeout)
	out, err := exec.CommandContext(cctx, nmcli, args...).CombinedOutput()
	cancel()
	if err != nil && os.Geteuid() != 0 {
		low := strings.ToLower(string(out))
		if strings.Contains(low, "not authorized") || strings.Contains(low, "insufficient privileges") || strings.Contains(low, "permission") {
			if sudoPath, sErr := exec.LookPath("sudo"); sErr == nil {
				sctx, scancel := context.WithTimeout(ctx, timeout)
				so, se := exec.CommandContext(sctx, sudoPath, append([]string{"-n", nmcli}, args...)...).CombinedOutput()
				scancel()
				if se == nil {
					return so, nil
				}
				return so, se
			}
		}
	}
	return out, err
}

// JoinWifiNetwork connects the host Wi-Fi interface to a peer's 5GHz/6GHz Hotspot or
// Wi-Fi Direct GO SSID via NetworkManager, restoring the prior Wi-Fi connection automatically if it fails.
func JoinWifiNetwork(ctx context.Context, stateDir string, req protocol.ConnectionPrepareRequest, onLinkUp func(iface, cidr string)) (protocol.ConnectionPrepareResult, error) {
	res := protocol.ConnectionPrepareResult{Kind: req.Kind, SSID: req.SSID, Band: req.Band}
	if strings.TrimSpace(req.SSID) == "" {
		return res, errors.New("ssid is required for wifi_join")
	}
	nmcli, err := exec.LookPath("nmcli")
	if err != nil {
		return res, errors.New("nmcli not available on host")
	}
	iface, curCon := wifiInterfaceName(ctx)
	if iface == "" {
		return res, errors.New("no Wi-Fi interface available on host")
	}
	savePrevWifi(stateDir, iface, curCon)
	prev, _ := loadPrevWifi(stateDir)
	res.PreviousConnection = prev.Connection

	// Clean any stale DeviceBridge-Direct profile first.
	_, _ = runNmcli(ctx, nmcli, 5*time.Second, "con", "delete", tempWifiProfile)

	deadline := time.Now().Add(42 * time.Second)
	var lastOut string
	connected := false
	for time.Now().Before(deadline) {
		if _, serr := runNmcli(ctx, nmcli, 6*time.Second, "dev", "wifi", "rescan", "ifname", iface, "ssid", req.SSID); serr != nil {
			_, _ = runNmcli(ctx, nmcli, 6*time.Second, "dev", "wifi", "rescan", "ifname", iface)
		}
		args := []string{"dev", "wifi", "connect", req.SSID, "ifname", iface, "name", tempWifiProfile}
		if req.Passphrase != "" {
			args = append(args, "password", req.Passphrase)
		}
		if req.BSSID != "" {
			args = append(args, "bssid", req.BSSID)
		}
		out, cerr := runNmcli(ctx, nmcli, 12*time.Second, args...)
		if cerr == nil {
			connected = true
			break
		}
		lastOut = strings.TrimSpace(string(out))
		_, _ = runNmcli(ctx, nmcli, 5*time.Second, "con", "delete", tempWifiProfile)
		select {
		case <-ctx.Done():
			_, _ = RestoreWifi(context.Background(), stateDir)
			return res, ctx.Err()
		case <-time.After(1500 * time.Millisecond):
		}
	}
	if !connected {
		_, _ = RestoreWifi(context.Background(), stateDir)
		return res, fmt.Errorf("failed to join %s: %s", req.SSID, lastOut)
	}

	var ip, cidr string
	for i := 0; i < 16; i++ {
		ip, cidr = readWifiIPv4(ctx, nmcli, iface)
		if ip != "" && cidr != "" {
			break
		}
		select {
		case <-ctx.Done():
			_, _ = RestoreWifi(context.Background(), stateDir)
			return res, ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
	if ip == "" || cidr == "" {
		_, _ = RestoreWifi(context.Background(), stateDir)
		return res, errors.New("joined AP but timed out waiting for IPv4 lease")
	}
	if onLinkUp != nil {
		onLinkUp(iface, cidr)
	}
	freq, band, std := readIwLinkDetails(ctx, iface)
	if band == "" {
		band = req.Band
	}
	res.OK = true
	res.Transport = "lan"
	res.Interface = iface
	res.IP = ip
	res.CIDR = cidr
	res.Endpoint = net.JoinHostPort(ip, "8731")
	res.Band = band
	res.Channel = FreqToChannel(freq)
	res.FrequencyMHz = freq
	res.WifiStandard = std
	res.Status = "connected"
	res.Message = fmt.Sprintf("Joined %s on %s (%s)", req.SSID, cidr, band)
	return res, nil
}

// RestoreWifi disconnects DeviceBridge-Direct and brings the previous Wi-Fi profile back up.
func RestoreWifi(ctx context.Context, stateDir string) (protocol.ConnectionPrepareResult, error) {
	joinMu.Lock()
	if joinCancel != nil {
		joinCancel()
		joinCancel = nil
	}
	joinMu.Unlock()

	res := protocol.ConnectionPrepareResult{Kind: "restore"}
	nmcli, err := exec.LookPath("nmcli")
	if err != nil {
		return res, errors.New("nmcli not available on host")
	}
	_, _ = runNmcli(ctx, nmcli, 6*time.Second, "con", "down", tempWifiProfile)
	_, _ = runNmcli(ctx, nmcli, 6*time.Second, "con", "delete", tempWifiProfile)
	prev, ok := loadPrevWifi(stateDir)
	if ok && prev.Connection != "" {
		out, uerr := runNmcli(ctx, nmcli, 12*time.Second, "con", "up", prev.Connection)
		res.PreviousConnection = prev.Connection
		if uerr != nil {
			return res, fmt.Errorf("failed restoring %s: %s", prev.Connection, strings.TrimSpace(string(out)))
		}
		if prev.Interface != "" {
		waitIP:
			for i := 0; i < 12; i++ {
				if ip, _ := readWifiIPv4(ctx, nmcli, prev.Interface); ip != "" {
					res.Interface = prev.Interface
					res.IP = ip
					break waitIP
				}
				select {
				case <-ctx.Done():
					break waitIP
				case <-time.After(500 * time.Millisecond):
				}
			}
		}
		_ = os.Remove(filepath.Join(stateDir, "prev_wifi.json"))
	} else {
		if iface, _ := wifiInterfaceName(ctx); iface != "" {
			_, _ = runNmcli(ctx, nmcli, 10*time.Second, "device", "connect", iface)
		}
	}
	res.OK = true
	res.Status = "restored"
	return res, nil
}

// Prepare handles authenticated connection setup requests arriving at a Linux host agent.
func Prepare(ctx context.Context, stateDir string, req protocol.ConnectionPrepareRequest, onLinkUp func(iface, cidr string)) (protocol.ConnectionPrepareResult, error) {
	if req.Kind == "wifi_join" || req.Kind == "hotspot" {
		if _, hosting := activeWifiDirect(); hosting {
			return protocol.ConnectionPrepareResult{Kind: req.Kind}, errors.New("stop the Wi-Fi Direct group before changing Wi-Fi")
		}
	}
	switch req.Kind {
	case "link_status":
		if req.SSID == "" {
			return protocol.ConnectionPrepareResult{OK: true, Kind: req.Kind, Status: "inactive"}, nil
		}
		if group, hosting := activeWifiDirect(); hosting && group.SSID == req.SSID {
			return protocol.ConnectionPrepareResult{OK: true, Kind: group.Kind, Status: "active"}, nil
		}
		active := ActiveDirectLink(ctx, stateDir)
		if active["kind"] == "hotspot" && active["ssid"] == req.SSID {
			return protocol.ConnectionPrepareResult{OK: true, Kind: "hotspot", Status: "active"}, nil
		}
		return protocol.ConnectionPrepareResult{OK: true, Kind: req.Kind, Status: "inactive"}, nil
	case "adb_usb":
		return RunADBReverse(ctx, req.Serial)
	case "wifi_direct":
		return startWifiDirect(ctx, req, onLinkUp)
	case "wifi_join":
		if strings.TrimSpace(req.SSID) == "" {
			return protocol.ConnectionPrepareResult{Kind: req.Kind}, errors.New("ssid is required")
		}
		if _, err := exec.LookPath("nmcli"); err != nil {
			return protocol.ConnectionPrepareResult{Kind: req.Kind}, errors.New("nmcli not available on host")
		}
		iface, curCon := wifiInterfaceName(ctx)
		if iface == "" {
			return protocol.ConnectionPrepareResult{Kind: req.Kind}, errors.New("no Wi-Fi interface available")
		}
		savePrevWifi(stateDir, iface, curCon)
		prev, _ := loadPrevWifi(stateDir)
		// Cancel any prior pending join and arm the watcher for the requested SSID
		// BEFORE replying HTTP 200 so the phone can safely start its AP/P2P GO right after.
		joinMu.Lock()
		if joinCancel != nil {
			joinCancel()
		}
		jctx, cancel := context.WithTimeout(context.Background(), 50*time.Second)
		joinCancel = cancel
		joinMu.Unlock()
		go func(myCancel context.CancelFunc) {
			defer myCancel()
			time.Sleep(500 * time.Millisecond)
			if _, jerr := JoinWifiNetwork(jctx, stateDir, req, onLinkUp); jerr != nil && !errors.Is(jerr, context.Canceled) {
				fmt.Fprintf(os.Stderr, "devicebridge linkctl wifi_join (%s) error: %v\n", req.SSID, jerr)
			}
		}(cancel)
		return protocol.ConnectionPrepareResult{
			OK:                 true,
			Kind:               req.Kind,
			Transport:          "lan",
			SSID:               req.SSID,
			Band:               req.Band,
			PreviousConnection: prev.Connection,
			Status:             "armed",
			Message:            "Laptop ready to join " + req.SSID,
		}, nil
	case "hotspot":
		nmcli, err := exec.LookPath("nmcli")
		if err != nil {
			return protocol.ConnectionPrepareResult{Kind: req.Kind}, errors.New("nmcli not available on host")
		}
		iface, curCon := wifiInterfaceName(ctx)
		if iface == "" {
			return protocol.ConnectionPrepareResult{Kind: req.Kind}, errors.New("no Wi-Fi interface available")
		}
		savePrevWifi(stateDir, iface, curCon)
		ssid, pass := randomHotspotCredentials()
		if s := strings.TrimSpace(req.SSID); s != "" {
			ssid = s
		}
		if p := strings.TrimSpace(req.Passphrase); p != "" {
			pass = p
		}
		type hotspotPlan struct {
			band string
			ch   int
		}
		var plans []hotspotPlan
		wantCh := req.Channel
		if wantCh <= 0 && req.FrequencyMHz > 0 {
			wantCh = FreqToChannel(req.FrequencyMHz)
		}
		if req.Band == "2ghz" || req.Band == "bg" || (wantCh > 0 && wantCh <= 14) {
			plans = append(plans, hotspotPlan{"bg", wantCh})
		} else {
			var usable5g []int
			var regLimited bool
			readUsable := func() {
				if iwPath, ierr := exec.LookPath("iw"); ierr == nil {
					cctx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
					if iwOut, oerr := exec.CommandContext(cctx, iwPath, "list").Output(); oerr == nil {
						usable5g, regLimited = ParseIwListDetails(string(iwOut))
					}
					cancel()
				}
			}
			readUsable()
			hasInt := func(list []int, target int) bool {
				for _, v := range list {
					if v == target {
						return true
					}
				}
				return false
			}
			needRegUnlock := len(usable5g) == 0 ||
				(wantCh > 14 && !hasInt(usable5g, wantCh)) ||
				(req.Band == "5ghz" && regLimited)
			if needRegUnlock {
				if switched, _ := EnsureRegDomain(ctx, "US"); switched {
					readUsable()
				}
			}
			if wantCh > 14 {
				plans = append(plans, hotspotPlan{"a", wantCh})
			}
			// Prefer highest 80 MHz-capable UNII-3 primary channel (161) before 20 MHz-only 165.
			seenPlanCh := map[int]bool{wantCh: wantCh > 0}
			for _, pass := range []bool{false, true} {
				for _, ch := range usable5g {
					if seenPlanCh[ch] || ((ch == 165) != pass) {
						continue
					}
					seenPlanCh[ch] = true
					plans = append(plans, hotspotPlan{"a", ch})
				}
			}
			plans = append(plans, hotspotPlan{"a", 0}, hotspotPlan{"bg", 0})
		}
		plannedBand := "5 GHz"
		plannedCh := 0
		if len(plans) > 0 {
			if plans[0].band == "bg" {
				plannedBand = "2.4 GHz"
			}
			plannedCh = plans[0].ch
		}
		plannedFreq := ChannelToFreq(plannedCh)
		// Wait briefly before running nmcli so the HTTP response flushes over
		// the current Wi-Fi socket before wlan0 switches to AP mode (10.42.0.1).
		go func() {
			time.Sleep(250 * time.Millisecond)
			hctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
			defer cancel()
			var herr error
			var out []byte
			for _, plan := range plans {
				_, _ = runNmcli(hctx, nmcli, 5*time.Second, "con", "delete", tempWifiProfile)
				args := []string{"device", "wifi", "hotspot", "ifname", iface, "con-name", tempWifiProfile, "ssid", ssid, "band", plan.band}
				if plan.ch > 0 {
					args = append(args, "channel", strconv.Itoa(plan.ch))
				}
				args = append(args, "password", pass)
				out, herr = runNmcli(hctx, nmcli, 11*time.Second, args...)
				if herr == nil {
					break
				}
				_, _ = runNmcli(hctx, nmcli, 5*time.Second, "con", "delete", tempWifiProfile)
			}
			if herr != nil {
				fmt.Fprintf(os.Stderr, "devicebridge linkctl hotspot (%s) error: %s (%v)\n", ssid, strings.TrimSpace(string(out)), herr)
				_, _ = RestoreWifi(context.Background(), stateDir)
				return
			}
			var cidr string
			for i := 0; i < 10; i++ {
				_, cidr = readWifiIPv4(hctx, nmcli, iface)
				if cidr != "" {
					break
				}
				time.Sleep(350 * time.Millisecond)
			}
			if onLinkUp != nil && cidr != "" {
				onLinkUp(iface, cidr)
			}
		}()
		return protocol.ConnectionPrepareResult{
			OK:           true,
			Kind:         req.Kind,
			Transport:    "lan",
			Interface:    iface,
			IP:           "10.42.0.1",
			Endpoint:     "10.42.0.1:8731",
			SSID:         ssid,
			Passphrase:   pass,
			Band:         plannedBand,
			Channel:      plannedCh,
			FrequencyMHz: plannedFreq,
			Status:       "starting",
			Message:      "Starting hotspot " + ssid,
		}, nil
	case "regdom":
		changed, err := EnsureRegDomain(ctx, "US")
		if err != nil {
			return protocol.ConnectionPrepareResult{Kind: req.Kind}, err
		}
		msg := "Regulatory domain already US"
		if changed {
			msg = "Regulatory domain switched to US (5 GHz channels unlocked)"
		}
		return protocol.ConnectionPrepareResult{
			OK:      true,
			Kind:    req.Kind,
			Status:  "active",
			Message: msg,
		}, nil
	case "restore":
		return Restore(ctx, stateDir)
	default:
		return protocol.ConnectionPrepareResult{Kind: req.Kind}, fmt.Errorf("unsupported connection prepare kind: %s", req.Kind)
	}
}

func randomHotspotCredentials() (string, string) {
	var b [18]byte
	_, _ = rand.Read(b[:])
	ssid := "DB-AP-" + hex.EncodeToString(b[:2])
	const chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	pass := make([]byte, 16)
	for i := range pass {
		pass[i] = chars[int(b[2+i])%len(chars)]
	}
	return ssid, string(pass)
}

func Restore(ctx context.Context, stateDir string) (protocol.ConnectionPrepareResult, error) {
	if CloseWifiDirect() {
		return protocol.ConnectionPrepareResult{OK: true, Kind: "restore", Status: "restored"}, nil
	}
	return RestoreWifi(ctx, stateDir)
}

// ActiveDirectLink inspects whether an orphaned DeviceBridge-Direct AP or Wi-Fi join is currently active on Linux.
func ActiveDirectLink(ctx context.Context, stateDir string) map[string]any {
	out := map[string]any{"active": false}
	nmcli, err := exec.LookPath("nmcli")
	if err != nil {
		return out
	}
	cctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	raw, err := exec.CommandContext(cctx, nmcli, "-t", "-f", "NAME,TYPE,DEVICE", "con", "show", "--active").Output()
	cancel()
	if err != nil {
		return out
	}
	activeIface := ""
	for _, line := range strings.Split(string(raw), "\n") {
		parts := strings.SplitN(strings.TrimSpace(line), ":", 3)
		if len(parts) == 3 && parts[0] == tempWifiProfile {
			activeIface = strings.TrimSpace(parts[2])
			break
		}
	}
	if activeIface == "" {
		return out
	}
	ip, cidr := readWifiIPv4(ctx, nmcli, activeIface)
	info := WifiLinkDetails(ctx, activeIface)
	kind := "wifi_join"
	ssid := ""
	pass := ""
	if iwPath, ierr := exec.LookPath("iw"); ierr == nil {
		ictx, icancel := context.WithTimeout(ctx, 1500*time.Millisecond)
		iwInfo, _ := exec.CommandContext(ictx, iwPath, "dev", activeIface, "info").Output()
		icancel()
		iwTxt := string(iwInfo)
		if strings.Contains(iwTxt, "type AP") {
			kind = "hotspot"
		} else if strings.Contains(iwTxt, "type P2P-GO") {
			kind = "wifi_direct"
		}
		for _, l := range strings.Split(iwTxt, "\n") {
			tr := strings.TrimSpace(l)
			if strings.HasPrefix(tr, "ssid ") {
				ssid = strings.TrimSpace(strings.TrimPrefix(tr, "ssid "))
				break
			}
		}
	}
	sctx, scancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	conVals, cerr := exec.CommandContext(sctx, nmcli, "-s", "-t", "-f", "802-11-wireless.ssid,802-11-wireless-security.psk", "con", "show", tempWifiProfile).Output()
	scancel()
	if cerr == nil {
		for _, l := range strings.Split(string(conVals), "\n") {
			if k, v, ok := strings.Cut(l, ":"); ok {
				if strings.HasSuffix(k, ".ssid") && ssid == "" {
					ssid = strings.TrimSpace(v)
				} else if strings.HasSuffix(k, ".psk") && pass == "" {
					pass = strings.TrimSpace(v)
				}
			}
		}
	}
	freq, channel, bw := 0, 0, 0
	band, std := "", ""
	if info != nil {
		freq = info.FrequencyMHz
		channel = info.Channel
		bw = info.BandwidthMHz
		band = info.Band
		std = info.WifiStandard
		if ssid == "" {
			ssid = info.SSID
		}
	}
	ep := ""
	if ip != "" {
		ep = net.JoinHostPort(ip, "8731")
	}
	return map[string]any{
		"active":        true,
		"resumed":       true,
		"kind":          kind,
		"interface":     activeIface,
		"ip":            ip,
		"cidr":          cidr,
		"endpoint":      ep,
		"ssid":          ssid,
		"passphrase":    pass,
		"band":          band,
		"channel":       channel,
		"frequency_mhz": freq,
		"bandwidth_mhz": bw,
		"wifi_standard": std,
	}
}
