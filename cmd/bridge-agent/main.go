package main

import (
	"context"
	"devicebridge/internal/auth"
	"devicebridge/internal/discovery"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/linkctl"
	"devicebridge/internal/platform"
	"devicebridge/internal/server"
	"devicebridge/internal/storage"
	"devicebridge/internal/synccontrol"
	"devicebridge/internal/transfer"
	"devicebridge/internal/transport/direct"
	"devicebridge/protocol"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

func resolveInterfaceCIDR(preferred string) (string, string, error) {
	ifaces, err := net.Interfaces()
	if err != nil {
		return "", "", err
	}
	pick := func(n net.Interface) (string, bool) {
		if n.Flags&net.FlagUp == 0 || n.Flags&net.FlagLoopback != 0 {
			return "", false
		}
		addrs, err := n.Addrs()
		if err != nil {
			return "", false
		}
		for _, a := range addrs {
			if ipNet, ok := a.(*net.IPNet); ok {
				if v4 := ipNet.IP.To4(); v4 != nil && !v4.IsLoopback() && !v4.IsLinkLocalUnicast() {
					ones, _ := ipNet.Mask.Size()
					return fmt.Sprintf("%s/%d", v4.String(), ones), true
				}
			}
		}
		return "", false
	}
	if preferred != "" && preferred != "auto" {
		for _, n := range ifaces {
			if n.Name == preferred {
				if c, ok := pick(n); ok {
					return n.Name, c, nil
				}
			}
		}
	}
	for _, n := range ifaces {
		low := strings.ToLower(n.Name)
		if strings.HasPrefix(low, "tailscale") || strings.HasPrefix(low, "tun") ||
			strings.HasPrefix(low, "wg") || strings.HasPrefix(low, "docker") ||
			strings.HasPrefix(low, "waydroid") || strings.HasPrefix(low, "veth") ||
			strings.HasPrefix(low, "virbr") || strings.HasPrefix(low, "br-") {
			continue
		}
		if c, ok := pick(n); ok {
			return n.Name, c, nil
		}
	}
	return "", "", fmt.Errorf("no active private IPv4 LAN interface available (preferred=%q)", preferred)
}

func run() error {
	if err := platform.BindApprovedNetwork(); err != nil {
		return err
	}
	state := flag.String("state", "", "private state directory (required)")
	name := flag.String("name", "", "device name for first initialization")
	iface := flag.String("interface", "wlan0", "approved unmetered LAN interface")
	cidr := flag.String("lan-cidr", "", "this device's approved local LAN IPv4/CIDR (or auto)")
	port := flag.Int("port", 8731, "listen port")
	loopbackPort := flag.Int("loopback-port", 0, "optional loopback listen port for ADB/SSH tunnels (defaults to --port when >0)")
	noDiscovery := flag.Bool("no-discovery", false, "disable mDNS (diagnostic only)")
	systemTailnet := flag.Bool("system-tailnet", false, "also listen on existing system Tailscale IP; never reconfigure daemon")
	showVersion := flag.Bool("version", false, "print agent version JSON and exit")
	termuxFiles := flag.Bool("termux-home-files", false, "enable authorized file management in an unprivileged Termux Home")
	disableActions := flag.Bool("no-remote-actions", false, "disable approved agent diagnostics")
	disableAgentSSH := flag.Bool("no-agent-ssh", false, "disable mTLS agent SSH stream endpoint")
	flag.Parse()
	if *showVersion {
		return json.NewEncoder(os.Stdout).Encode(map[string]any{
			"name":    "bridge-agent",
			"version": protocol.GoCoreVersion,
			"go":      runtime.Version(),
			"os":      runtime.GOOS,
			"arch":    runtime.GOARCH,
		})
	}
	if *termuxFiles && (runtime.GOOS != "android" || os.Geteuid() < 10000) {
		return errors.New("Termux file management requires an unprivileged Android app user")
	}
	if *state == "" {
		return fmt.Errorf("--state required")
	}
	watchLAN := runtime.GOOS != "android" && strings.EqualFold(strings.TrimSpace(*cidr), "auto")
	activeIface := *iface
	activeCIDR := *cidr
	if watchLAN {
		for {
			ri, rc, rerr := resolveInterfaceCIDR(*iface)
			if rerr == nil {
				activeIface, activeCIDR = ri, rc
				break
			}
			time.Sleep(time.Second)
		}
	}
	p, err := direct.NewCIDR(activeIface, activeCIDR)
	if err != nil {
		return err
	}
	s, err := storage.Open(*state)
	if err != nil {
		return err
	}
	defer s.Close()
	id, err := auth.Load(s, *name)
	if err != nil {
		return err
	}
	sharedFiles, err := transfer.OpenSharedFileInbox(*state)
	if err != nil {
		fmt.Fprintln(os.Stderr, "shared files inbox unavailable:", err)
	} else {
		defer sharedFiles.Close()
	}
	providers := &filesproviders.Registry{}
	defer providers.Close()
	exports, err := s.Exports()
	if err != nil {
		return err
	}
	if len(exports) == 0 {
		if home, he := os.UserHomeDir(); he == nil && home != "" {
			_ = s.Export("home", home)
		}
		_ = s.Export("filesystem", "/")
		if _, se := os.ReadDir("/storage/emulated/0"); se == nil {
			_ = s.Export("phone_storage", "/storage/emulated/0")
		}
		exports, _ = s.Exports()
	}
	if endpoint, token := os.Getenv("DEVICEBRIDGE_DOCUMENTS_ENDPOINT"), os.Getenv("DEVICEBRIDGE_DOCUMENTS_TOKEN"); endpoint != "" && token != "" {
		if slices.Contains(strings.Split(os.Getenv("DEVICEBRIDGE_DOCUMENTS_KINDS"), ","), "saf") {
			provider, err := filesproviders.NewDocuments("saf", "saf", endpoint, token)
			if err != nil {
				return err
			}
			if err := s.ExportDocuments("saf", "saf"); err != nil {
				return err
			}
			if err := providers.Register(provider); err != nil {
				return err
			}
		}
	}
	for _, e := range exports {
		if strings.HasPrefix(e.Path, "android-documents://") {
			continue
		}
		f, err := filesproviders.NewNative(e.ID, e.Path)
		if err != nil {
			continue
		}
		if err = providers.Register(f); err != nil {
			f.Close()
			return err
		}
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	defer linkctl.CloseWifiDirect()
	var primaryMu sync.Mutex
	var currentPrimaryP = p
	var primaryCancel context.CancelFunc
	var primaryLn net.Listener
	var stopPrimaryDisc func()

	var newSrv func() *server.Server
	var dynMu sync.Mutex
	dynCancels := map[string]context.CancelFunc{}
	stopDynamic := func() {
		dynMu.Lock()
		for k, cancelFn := range dynCancels {
			cancelFn()
			delete(dynCancels, k)
		}
		dynMu.Unlock()
	}
	defer stopDynamic()

	startPrimaryDiscoveryFor := func(pctx context.Context, dp *direct.Provider, portNum int) (bool, string) {
		if *noDiscovery {
			return false, ""
		}
		primaryMu.Lock()
		defer primaryMu.Unlock()
		if stopPrimaryDisc != nil {
			stopPrimaryDisc()
			stopPrimaryDisc = nil
		}
		stop, e := discovery.Advertise(pctx, dp, id.ID, id.Name, portNum)
		if e != nil {
			return false, e.Error()
		}
		stopPrimaryDisc = stop
		return true, ""
	}
	startPrimaryDiscovery := func() error {
		primaryMu.Lock()
		dp := currentPrimaryP
		lnRef := primaryLn
		primaryMu.Unlock()
		if dp == nil || lnRef == nil {
			return nil
		}
		_, errStr := startPrimaryDiscoveryFor(ctx, dp, lnRef.Addr().(*net.TCPAddr).Port)
		if errStr != "" {
			return fmt.Errorf("%s", errStr)
		}
		return nil
	}

	bindPrimary := func(newIface, newCIDR string) (net.Listener, *direct.Provider, bool, string, error) {
		dp, derr := direct.NewCIDR(newIface, newCIDR)
		if derr != nil {
			return nil, nil, false, "", derr
		}
		pctx, pcancel := context.WithCancel(ctx)
		newLn, lerr := dp.Listen(pctx, net.JoinHostPort(dp.Address.String(), strconv.Itoa(*port)))
		if lerr != nil {
			pcancel()
			return nil, nil, false, "", lerr
		}
		primaryMu.Lock()
		if stopPrimaryDisc != nil {
			stopPrimaryDisc()
			stopPrimaryDisc = nil
		}
		if primaryLn != nil {
			_ = primaryLn.Close()
		}
		if primaryCancel != nil {
			primaryCancel()
		}
		currentPrimaryP = dp
		primaryCancel = pcancel
		primaryLn = newLn
		activeIface = newIface
		activeCIDR = newCIDR
		primaryMu.Unlock()
		okDisc, errDisc := startPrimaryDiscoveryFor(pctx, dp, newLn.Addr().(*net.TCPAddr).Port)
		return newLn, dp, okDisc, errDisc, nil
	}

	ln, curP, discoveryOK, discoveryError, err := bindPrimary(activeIface, activeCIDR)
	if err != nil {
		return err
	}
	defer func() {
		primaryMu.Lock()
		if stopPrimaryDisc != nil {
			stopPrimaryDisc()
			stopPrimaryDisc = nil
		}
		if primaryLn != nil {
			_ = primaryLn.Close()
		}
		if primaryCancel != nil {
			primaryCancel()
		}
		primaryMu.Unlock()
	}()
	if !*noDiscovery && !discoveryOK {
		fmt.Fprintln(os.Stderr, "mDNS unavailable:", discoveryError)
	}
	_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"id": id.ID, "name": id.Name, "endpoint": ln.Addr().String(), "interface": curP.Interface, "transport": curP.ID(), "approved_lan": curP.Prefix.String(), "discovery": discoveryOK, "discovery_error": discoveryError})

	startDynamic := func(dynIface, dynCidr string) {
		key := dynIface + ":" + dynCidr
		dp, derr := direct.NewCIDR(dynIface, dynCidr)
		if derr != nil {
			return
		}
		listenPort := *port
		if listenPort <= 0 {
			listenPort = 8731
		}
		dynMu.Lock()
		if _, exists := dynCancels[key]; exists {
			dynMu.Unlock()
			return
		}
		dctx, dcancel := context.WithCancel(ctx)
		dynCancels[key] = dcancel
		dynMu.Unlock()
		go func() {
			dln, lerr := dp.Listen(dctx, net.JoinHostPort(dp.Address.String(), strconv.Itoa(listenPort)))
			if lerr != nil {
				dcancel()
				dynMu.Lock()
				delete(dynCancels, key)
				dynMu.Unlock()
				return
			}
			defer dln.Close()
			if !*noDiscovery {
				if dstop, aerr := discovery.Advertise(dctx, dp, id.ID, id.Name, dln.Addr().(*net.TCPAddr).Port); aerr == nil {
					defer dstop()
				}
			}
			_ = newSrv().Serve(dctx, dln)
		}()
	}

	var overlays *overlayListeners
	if runtime.GOOS == "linux" && *port > 0 {
		overlays = newOverlayListeners(*port, *systemTailnet)
		defer overlays.close()
	}
	refreshRoutes := func() {
		if overlays == nil {
			return
		}
		primaryMu.Lock()
		primaryAddress := primaryLn.Addr().String()
		primaryMu.Unlock()
		overlays.refresh(ctx, primaryAddress, func(ln net.Listener) {
			go func() { _ = newSrv().Serve(ctx, ln) }()
		})
	}
	syncManager := synccontrol.New(ctx, *state, s, providers)
	sharedStats := &server.AgentStats{}
	statusName := "agent-status.json"
	if runtime.GOOS == "android" && os.Getenv("DEVICEBRIDGE_DIRECT_AGENT") == "1" {
		statusName = "agent-direct-status.json"
	}
	publisher := agentStatusPublisher{path: filepath.Join(*state, statusName)}
	writeAgentStatus := func(running bool) {
		primaryMu.Lock()
		status := agentStatus{
			Running:   running,
			PID:       os.Getpid(),
			Discovery: stopPrimaryDisc != nil,
		}
		if primaryLn != nil {
			status.Endpoint = primaryLn.Addr().String()
		}
		if currentPrimaryP != nil {
			status.Interface = currentPrimaryP.Interface
			status.CIDR = currentPrimaryP.Prefix.String()
		}
		primaryMu.Unlock()
		policy, policyErr := s.NetworkPolicy(ctx, nil)
		status.AgentSSHEnabled = running && !*disableAgentSSH && policyErr == nil && policy["network_agent_ssh"] &&
			(runtime.GOOS != "linux" || os.Geteuid() != 0)
		status.AgentStatsSnapshot = sharedStats.Snapshot()
		_ = publisher.publish(status)
	}
	writeAgentStatus(true)
	stopStatus, statusDone := make(chan struct{}), make(chan struct{})
	defer func() {
		close(stopStatus)
		<-statusDone
		writeAgentStatus(false)
	}()
	go func() {
		defer close(statusDone)
		ticker := time.NewTicker(2 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-stopStatus:
				return
			case <-ticker.C:
				writeAgentStatus(true)
			}
		}
	}()
	newSrv = func() *server.Server {
		srv := server.New(s, id, providers)
		srv.Stats = sharedStats
		srv.Sync = syncManager
		srv.TermuxFiles = *termuxFiles
		srv.StateDir = *state
		srv.DisableAgentSSH = *disableAgentSSH
		srv.SharedFiles = sharedFiles
		if !*disableActions {
			srv.ActionState = *state
		}
		srv.Capabilities = func(ctx context.Context) *protocol.DeviceCapabilities {
			caps := linkctl.DetectCapabilities(ctx)
			if overlays != nil {
				refreshRoutes()
				caps.TailnetEndpoint, caps.WireGuardEndpoints = overlays.endpoints()
			}
			if runtime.GOOS == "android" {
				caps.TailnetEndpoint = sidecarRoute(ctx, *state, "tailnet")
				if ep := sidecarRoute(ctx, *state, "wireguard"); ep != "" {
					caps.WireGuardEndpoints = []string{ep}
				}
			}
			return caps
		}
		srv.LinkActive = func(ctx context.Context) bool { return linkctl.ActiveDirectLink(ctx, *state)["active"] == true }
		srv.PrepareLink = func(pctx context.Context, req protocol.ConnectionPrepareRequest) (protocol.ConnectionPrepareResult, error) {
			return linkctl.Prepare(pctx, *state, req, startDynamic)
		}
		srv.RestoreLink = func(rctx context.Context) (protocol.ConnectionPrepareResult, error) {
			go func() {
				time.Sleep(150 * time.Millisecond)
				stopDynamic()
				_, _ = linkctl.Restore(ctx, *state)
				_ = startPrimaryDiscovery()
			}()
			return protocol.ConnectionPrepareResult{
				OK:      true,
				Kind:    "restore",
				Status:  "restoring",
				Message: "Restoring host Wi-Fi",
			}, nil
		}
		return srv
	}

	refreshRoutes()
	lbPort := *loopbackPort
	if lbPort == 0 && !p.Address.IsLoopback() && *port > 0 {
		lbPort = *port
	}
	if lbPort > 0 && !p.Address.IsLoopback() {
		if lb, le := net.Listen("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(lbPort))); le == nil {
			defer lb.Close()
			go func() { _ = newSrv().Serve(ctx, lb) }()
		}
	}
	if watchLAN {
		go func() { _ = newSrv().Serve(ctx, ln) }()
		ticker := time.NewTicker(2500 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return nil
			case <-ticker.C:
				refreshRoutes()
				dynMu.Lock()
				hasDyn := len(dynCancels) > 0
				dynMu.Unlock()
				if hasDyn {
					continue
				}
				ni, nc, rerr := resolveInterfaceCIDR(*iface)
				if rerr != nil {
					continue
				}
				if ni != activeIface || nc != activeCIDR {
					newLn, _, _, _, berr := bindPrimary(ni, nc)
					if berr == nil {
						fmt.Fprintf(os.Stderr, "{\"lan_rebound\":\"%s\",\"interface\":\"%s\"}\n", nc, ni)
						go func(l net.Listener) { _ = newSrv().Serve(ctx, l) }(newLn)
					}
				}
			}
		}
	}
	return newSrv().Serve(ctx, ln)
}
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
