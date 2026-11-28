package main

import (
	"bufio"
	"context"
	"database/sql"
	"devicebridge/internal/actions"
	"devicebridge/internal/auth"
	"devicebridge/internal/bootstrap"
	"devicebridge/internal/client"
	"devicebridge/internal/discovery"
	"devicebridge/internal/linkctl"
	"devicebridge/internal/platform"
	"devicebridge/internal/storage"
	"devicebridge/internal/tailnetipc"
	"devicebridge/internal/transfer"
	"devicebridge/internal/transport"
	"devicebridge/internal/transport/direct"
	"devicebridge/internal/transport/tailnet"
	"devicebridge/internal/transport/tailscaled"
	"devicebridge/internal/transport/wireguard"
	"devicebridge/protocol"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"github.com/cespare/xxhash/v2"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type command struct {
	selectedTransport   string
	state               *storage.Store
	identity            *auth.Identity
	provider            *direct.Provider
	endpoint            string
	ctx                 context.Context
	overlay             transport.Provider
	verifiedDevice      protocol.Device
	skipCachedEndpoints bool
	skipSavedLAN        bool
}

type fileSendProgress struct {
	source io.Reader
	total  int64
	sent   int64
	last   time.Time
}

func (p *fileSendProgress) Read(buf []byte) (int, error) {
	n, err := p.source.Read(buf)
	p.record(int64(n))
	return n, err
}

func (p *fileSendProgress) record(n int64) {
	if n == 0 {
		return
	}
	p.sent += n
	now := time.Now()
	if p.sent == p.total || now.Sub(p.last) >= 250*time.Millisecond {
		p.last = now
		_ = json.NewEncoder(os.Stderr).Encode(map[string]int64{
			"sent_bytes": p.sent, "total_bytes": p.total,
		})
	}
}

func output(v any) error { return json.NewEncoder(os.Stdout).Encode(v) }
func (c *command) peer(name string) (storage.Peer, error) {
	peers, err := c.state.Peers()
	if err != nil {
		return storage.Peer{}, err
	}
	var found []storage.Peer
	for _, p := range peers {
		if p.ID == name || p.Name == name || protocol.DeviceDisplayName(p.Name) == name {
			found = append(found, p)
		}
	}
	if len(found) != 1 {
		return storage.Peer{}, errors.New("peer unknown or ambiguous; use the full device id")
	}
	if found[0].Status == "revoked" {
		return storage.Peer{}, storage.ErrDenied
	}
	return found[0], nil
}
func openOverlay(ctx context.Context, stateDir, controlSocket, tailnetMode string, remoteApproved bool) (transport.Provider, error) {
	socket := controlSocket
	if socket == "" {
		socket = filepath.Join(stateDir, "tailnet", "control.sock")
	}
	if runtime.GOOS != "android" && tailnetMode != "app" {
		sys := &tailscaled.Provider{RemoteApproved: remoteApproved}
		st, e := sys.Status(ctx)
		if e == nil && st.State == "Running" {
			return sys, nil
		} else if tailnetMode == "system" {
			return nil, errors.New("system Tailscale unavailable")
		}
	}
	app := &tailnet.Provider{Control: tailnetipc.Client{Socket: socket}, RemoteApproved: remoteApproved}
	if runtime.GOOS == "android" && tailnetMode == "auto" {
		app.SystemVPN = tailnet.NewAndroidVPN(os.Getenv("DEVICEBRIDGE_SYSTEM_TAILNET_HANDLE"), os.Getenv("DEVICEBRIDGE_SYSTEM_TAILNET_IP"))
	}
	return app, nil
}

func (c *command) connect(id string, authenticate bool) (*client.Client, transport.Candidate, error) {
	if c.overlay != nil {
		if c.endpoint == "" {
			return nil, transport.Candidate{}, errors.New("select this device's verified tailnet endpoint first")
		}
		v, err := c.overlay.Probe(c.ctx, transport.Candidate{DeviceID: id, Endpoint: c.endpoint, Transport: c.overlay.ID()})
		if err != nil {
			return nil, v, err
		}
		cl := client.New(c.identity, c.state, c.overlay, v)
		if authenticate {
			var device protocol.Device
			start := time.Now()
			if err = cl.JSON(c.ctx, "/v1/device", nil, &device); err != nil {
				cl.Close()
				return nil, v, err
			}
			if v.RTT == 0 {
				v.RTT = time.Since(start)
			}
			if device.ID != id {
				cl.Close()
				return nil, v, errors.New("tailnet endpoint DeviceBridge key mismatch")
			}
			c.verifiedDevice = device
		}
		return cl, v, nil
	}

	candidates := []transport.Candidate{}
	network := c.provider.Interface + ":" + c.provider.Address.String() + ":" + c.provider.Prefix.String()
	if authenticate && c.endpoint == "" && !c.skipCachedEndpoints {
		cached, err := c.state.CachedEndpoints(id, network)
		if err != nil {
			return nil, transport.Candidate{}, err
		}
		for _, ep := range cached {
			v := transport.Candidate{DeviceID: id, Endpoint: ep, Interface: c.provider.Interface, Transport: c.provider.ID(), Direct: true, Observed: time.Now(), Cost: c.provider.NetworkCost(transport.Candidate{})}
			cl := client.New(c.identity, c.state, c.provider, v)
			var device protocol.Device
			start := time.Now()
			err := cl.JSON(c.ctx, "/v1/device", nil, &device)
			if err == nil && device.ID == id && device.Version == 1 {
				v.RTT = time.Since(start)
				c.verifiedDevice = device
				return cl, v, nil
			}
			cl.Close()
		}
	}
	if c.endpoint != "" {
		candidates = append(candidates, transport.Candidate{DeviceID: id, Endpoint: c.endpoint, Interface: c.provider.Interface, Transport: c.provider.ID(), Direct: true, Observed: time.Now(), Cost: c.provider.NetworkCost(transport.Candidate{})})
	} else {
		all, err := c.provider.DiscoverCandidates(c.ctx)
		if err != nil {
			return nil, transport.Candidate{}, err
		}
		for _, v := range all {
			if v.DeviceID == id {
				candidates = append(candidates, v)
			}
		}
		if len(candidates) == 0 && c.selectedTransport == "lan" && !c.skipSavedLAN {
			if savedConn, ce := c.state.Connection(id, nil); ce == nil && savedConn.LanEndpoint != "" && c.provider.Check(savedConn.LanEndpoint) == nil {
				candidates = append(candidates, transport.Candidate{
					DeviceID:  id,
					Endpoint:  savedConn.LanEndpoint,
					Interface: c.provider.Interface,
					Transport: c.provider.ID(),
					Direct:    true,
					Observed:  time.Now(),
					Cost:      c.provider.NetworkCost(transport.Candidate{}),
				})
			}
		}
	}
	var last error
	for _, v := range candidates {
		if c.selectedTransport == "adb" || c.selectedTransport == "ssh" {
			v.Transport = c.selectedTransport
		}
		cl := client.New(c.identity, c.state, c.provider, v)
		if authenticate {
			var device protocol.Device
			start := time.Now()
			err := cl.JSON(c.ctx, "/v1/device", nil, &device)
			if err != nil {
				last = err
				cl.Close()
				continue
			}
			if device.ID != id || device.Version != 1 {
				last = errors.New("authenticated identity mismatch")
				cl.Close()
				continue
			}
			v.RTT = time.Since(start)
			c.verifiedDevice = device
			if err = c.state.CacheEndpoint(id, network, v.Endpoint); err != nil {
				cl.Close()
				return nil, transport.Candidate{}, err
			}
		}
		return cl, v, nil
	}
	if last != nil {
		return nil, transport.Candidate{}, last
	}
	return nil, transport.Candidate{}, errors.New("device not discovered on the approved LAN; no relay fallback")
}
func isManualLAN(iface string) bool {
	for _, prefix := range []string{"p2p", "dbp2p", "ap", "swlan", "rndis"} {
		if strings.HasPrefix(iface, prefix) {
			return true
		}
	}
	return false
}

func run() error {
	if err := platform.BindApprovedNetwork(); err != nil {
		return err
	}
	state := flag.String("state", "", "private state directory (required)")
	iface := flag.String("interface", "wlan0", "approved unmetered LAN interface")
	cidr := flag.String("lan-cidr", "", "this device's approved local LAN IPv4/CIDR")
	endpoint := flag.String("endpoint", "", "diagnostic explicit endpoint (normal use discovers by identity)")
	transportID := flag.String("transport", "lan", "lan, adb, ssh, or explicitly selected tailnet")
	controlSocket := flag.String("tailnet-socket", "", "private app-only tsnet control socket")
	tailnetMode := flag.String("tailnet-mode", "auto", "auto prefers existing system tailscaled; app explicitly selects tsnet")
	wgBackend := flag.String("wg-backend", wireguard.BackendAuto, "WireGuard backend: auto, userspace, or kernel")
	wgTunnelOnly := flag.Bool("wireguard-tunnel-only", false, "use only the configured WireGuard tunnel")
	remoteApproved := flag.Bool("approve-remote", false, "explicitly allow internet/relay data for this request")
	syncApproved := flag.Bool("approve-sync", false, "explicitly approve this limited direct-LAN Sync session")
	allowFallback := flag.Bool("allow-route-fallback", false, "allow approved alternate-route resume on disruption")
	manualLANContext := flag.Bool("manual-lan-context", false, "exclude a manual local link from alternate-route resume")
	requirePullPolicy := flag.Bool("require-pull-network-policy", false, "require live Android policy for a download")
	flag.Parse()
	a := flag.Args()
	if len(a) > 0 && a[0] == "version" {
		return output(map[string]any{
			"name":    "bridge-cli",
			"version": protocol.GoCoreVersion,
			"go":      runtime.Version(),
			"os":      runtime.GOOS,
			"arch":    runtime.GOARCH,
		})
	}
	if *state == "" || len(a) == 0 {
		return errors.New("usage: bridge-cli --state DIR [--interface wlan0 --lan-cidr LOCAL/24] init|identity|export|invite|peers|approve|revoke|discover|pair|finish|roots|list|stat|pull|resolve")
	}
	if a[0] == "checksum" {
		if len(a) != 2 {
			return errors.New("checksum FILE (or - for stdin)")
		}
		var input io.Reader = os.Stdin
		if a[1] != "-" {
			f, e := os.Open(a[1])
			if e != nil {
				return e
			}
			defer f.Close()
			input = f
		}
		h := xxhash.New()
		n, e := io.Copy(h, input)
		if e != nil {
			return e
		}
		return output(map[string]any{"algorithm": "xxh64", "xxh64": fmt.Sprintf("%016x", h.Sum64()), "bytes": n})
	}

	if a[0] == "publish-local" {
		if len(a) != 3 {
			return errors.New("publish-local STAGED_DATA DESTINATION")
		}
		if err := transfer.PublishLocal(a[1], a[2]); err != nil {
			return err
		}
		return output(map[string]string{"destination": a[2], "status": "published"})
	}

	if a[0] == "move-local-no-replace" {
		if len(a) != 3 {
			return errors.New("move-local-no-replace SOURCE DESTINATION")
		}
		if err := transfer.MoveLocalNoReplace(a[1], a[2]); err != nil {
			return err
		}
		return output(true)
	}

	if a[0] == "tsnet-proxy" {
		if len(a) < 2 || len(a) > 3 {
			return errors.New("tsnet-proxy HOST [PORT]")
		}
		targetHost := a[1]
		targetPort := "22"
		targetAddr := a[1]
		if len(a) == 3 {
			targetPort = a[2]
			targetAddr = net.JoinHostPort(a[1], a[2])
		} else if h, p, spErr := net.SplitHostPort(a[1]); spErr == nil {
			targetHost = h
			targetPort = p
		}
		socket := *controlSocket
		if socket == "" {
			socket = filepath.Join(*state, "tailnet", "control.sock")
		}
		sigCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		var conn net.Conn
		var err error
		if runtime.GOOS != "android" && *tailnetMode != "app" {
			if _, statErr := os.Stat(socket); os.IsNotExist(statErr) {
				qCtx, qCancel := context.WithTimeout(sigCtx, 4*time.Second)
				st, stErr := (&tailscaled.Provider{}).Status(qCtx)
				qCancel()
				if stErr == nil {
					if resolvedIP := tailnetResolveIP(st, targetHost); resolvedIP != "" {
						conn, err = (&net.Dialer{Timeout: 8 * time.Second}).DialContext(sigCtx, "tcp", net.JoinHostPort(resolvedIP, targetPort))
					}
				}
			}
		}
		if conn == nil && err == nil {
			_, conn, err = (tailnetipc.Client{Socket: socket}).Exchange(sigCtx, tailnetipc.Request{
				Operation:      "stream",
				Target:         targetAddr,
				Purpose:        "termux",
				RemoteApproved: true,
			})
		}
		if err != nil {
			return err
		}
		defer conn.Close()
		done := make(chan struct{})
		go func() {
			_, _ = io.Copy(conn, os.Stdin)
			if cw, ok := conn.(interface{ CloseWrite() error }); ok {
				_ = cw.CloseWrite()
			}
			close(done)
		}()
		_, _ = io.Copy(os.Stdout, conn)
		_ = conn.Close()
		<-done
		return nil
	}

	if a[0] == "ensure-termux-ssh" {
		exe, _ := os.Executable()
		var enableSSHD *bool
		for _, arg := range a[1:] {
			switch arg {
			case "--openssh=true":
				v := true
				enableSSHD = &v
			case "--openssh=false":
				v := false
				enableSSHD = &v
			}
		}
		return bootstrap.EnsureTermuxSSHWithMode(*state, exe, enableSSHD, *iface, *cidr)
	}

	if a[0] == "termux-adapt" {
		exe, _ := os.Executable()
		return bootstrap.EnsureTermuxAdapted(*state, exe)
	}

	if a[0] == "termux-setup" {
		setup := flag.NewFlagSet("termux-setup", flag.ContinueOnError)
		mode := setup.String("mode", "base", "base, tools, ssh-client, or openssh")
		archive := setup.String("archive", "", "verified upstream release archive")
		digest := setup.String("release-sha256", "", "published upstream archive digest")
		if err := setup.Parse(a[1:]); err != nil {
			return err
		}
		if setup.NArg() != 0 {
			return errors.New("unexpected Termux setup argument")
		}
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		ctx, cancel := context.WithTimeout(ctx, 8*time.Minute)
		defer cancel()
		exe, _ := os.Executable()
		return bootstrap.SetupTermuxEnvironment(ctx, *state, exe, *mode, *archive, *digest, func(line string) {
			fmt.Println(line)
		})
	}

	if len(a) >= 2 && a[0] == "termux-backup" {
		switch a[1] {
		case "list":
			fs := flag.NewFlagSet("termux-backup list", flag.ContinueOnError)
			subpath := fs.String("path", "", "relative path inside Termux Home")
			if err := fs.Parse(a[2:]); err != nil {
				return err
			}
			entries, err := bootstrap.ListTermuxBackupEntries(*state, *subpath)
			if err != nil {
				return err
			}
			return json.NewEncoder(os.Stdout).Encode(map[string]any{
				"entries":          entries,
				"default_excludes": bootstrap.DefaultTermuxBackupExcludes,
			})
		case "create":
			fs := flag.NewFlagSet("termux-backup create", flag.ContinueOnError)
			specJSON := fs.String("spec", "", "optional JSON TermuxBackupOptions")
			if err := fs.Parse(a[2:]); err != nil {
				return err
			}
			var opts bootstrap.TermuxBackupOptions
			if strings.TrimSpace(*specJSON) != "" {
				if err := json.Unmarshal([]byte(*specJSON), &opts); err != nil {
					return fmt.Errorf("invalid backup spec: %w", err)
				}
			}
			report, err := bootstrap.WriteTermuxBackupWithOptions(*state, os.Stdout, opts)
			if err != nil {
				return err
			}
			return json.NewEncoder(os.Stderr).Encode(report)
		case "restore":
			info, err := bootstrap.RestoreTermuxBackup(*state, os.Stdin)
			if err != nil {
				return err
			}
			return json.NewEncoder(os.Stdout).Encode(info)
		}
		return errors.New("termux-backup list|create|restore")
	}

	if a[0] == "tsnet-match" {
		if len(a) != 2 {
			return errors.New("tsnet-match HOST")
		}
		socket := *controlSocket
		if socket == "" {
			socket = filepath.Join(*state, "tailnet", "control.sock")
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if runtime.GOOS != "android" && *tailnetMode != "app" {
			if _, statErr := os.Stat(socket); os.IsNotExist(statErr) {
				if st, stErr := (&tailscaled.Provider{}).Status(ctx); stErr == nil && tailnetHostMatches(st, a[1]) {
					return nil
				}
			}
		}
		st, _, err := (tailnetipc.Client{Socket: socket}).Exchange(ctx, tailnetipc.Request{
			Operation: "status",
		})
		if err == nil && tailnetHostMatches(st, a[1]) {
			return nil
		}
		os.Exit(1)
	}

	if a[0] == "local-terminal-detached" {
		return detachedTerminalCommand(*state, a[1:])
	}

	s, err := storage.Open(*state)
	if err != nil {
		return err
	}
	defer s.Close()
	name := ""
	if a[0] == "init" {
		if len(a) != 2 && (len(a) != 3 || a[2] != "--home-only") {
			return errors.New("init NAME [--home-only]")
		}
		name = a[1]
	}
	id, err := auth.Load(s, name)
	if err != nil {
		return err
	}
	switch a[0] {
	case "agent-ssh-match":
		if len(a) != 2 {
			return errors.New("agent-ssh-match HOST")
		}
		if _, ok := matchAgentSSHPeer(s, a[1]); ok {
			return nil
		}
		os.Exit(1)
	case "agent-ssh-proxy":
		if len(a) != 2 {
			return errors.New("agent-ssh-proxy PEER")
		}
		peer, ok := matchAgentSSHPeer(s, a[1])
		if !ok {
			if p2, pErr := s.Peer(a[1]); pErr == nil && p2.Status == "paired" {
				peer = p2
				ok = true
			}
		}
		if !ok {
			return errors.New("paired peer not found for DeviceBridge agent SSH")
		}
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		conn, _, err := dialAgentSSHStream(
			ctx, s, id, peer.ID,
			*state, *iface, *cidr, *controlSocket, *tailnetMode, *wgBackend, *wgTunnelOnly,
			*transportID, *endpoint,
		)
		if err != nil {
			return err
		}
		defer conn.Close()
		done := make(chan struct{})
		go func() {
			_, _ = io.Copy(conn, os.Stdin)
			if cw, ok := conn.(interface{ CloseWrite() error }); ok {
				_ = cw.CloseWrite()
			}
			close(done)
		}()
		_, _ = io.Copy(os.Stdout, conn)
		_ = conn.Close()
		<-done
		return nil
	case "agent-terminal":
		if len(a) != 2 || a[1] != "-" {
			return errors.New("agent-terminal - (reads JSON session request followed by terminal frames)")
		}
		frames := bufio.NewScanner(os.Stdin)
		frames.Buffer(make([]byte, 4096), 64<<10)
		var req agentTerminalRequest
		if !frames.Scan() || json.Unmarshal(frames.Bytes(), &req) != nil {
			return errors.New("invalid agent terminal session request")
		}
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		return runAgentTerminalSession(
			ctx, s, id,
			*state, *iface, *cidr, *controlSocket, *tailnetMode, *wgBackend, *wgTunnelOnly,
			req, frames,
		)
	case "agent-ssh-run":
		if len(a) != 2 || a[1] != "-" {
			return errors.New("agent-ssh-run - (reads JSON request from stdin)")
		}
		rawReq, re := io.ReadAll(io.LimitReader(os.Stdin, 65536))
		if re != nil {
			return re
		}
		var req agentSSHRunRequest
		if re = json.Unmarshal(rawReq, &req); re != nil {
			return re
		}
		sigCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		res, ce := runAgentSSHCommand(
			sigCtx, s, id,
			*state, *iface, *cidr, *controlSocket, *tailnetMode, *wgBackend, *wgTunnelOnly,
			req, func(stream, chunk string) {
				evt, _ := json.Marshal(map[string]any{
					"ssh_output": true,
					"stream":     stream,
					"chunk":      chunk,
				})
				fmt.Fprintln(os.Stderr, string(evt))
			},
		)
		if ce != nil {
			return ce
		}
		return output(res)
	case "local-files":
		ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer cancel()
		return localFiles(ctx, *state, a)
	case "connection":
		if len(a) < 2 || len(a) > 5 {
			return errors.New("connection PEER_ID [-|lan|tailnet|adb|ssh ENDPOINT [allow-internet-and-relays]]")
		}
		var change *storage.Connection
		if len(a) > 2 {
			if a[2] == "-" {
				data, e := io.ReadAll(io.LimitReader(os.Stdin, 8192))
				if e != nil {
					return e
				}
				var parsed storage.Connection
				if e = json.Unmarshal(data, &parsed); e != nil {
					return e
				}
				change = &parsed
			} else {
				change = &storage.Connection{Transport: a[2]}
				if a[2] == "tailnet" {
					if len(a) != 5 || a[4] != "allow-internet-and-relays" {
						return errors.New("explicit internet/relay approval required")
					}
					change.Endpoint = a[3]
					change.RemoteApproved = true
				} else if a[2] == "adb" || a[2] == "ssh" {
					if len(a) < 4 {
						return errors.New("ADB/SSH connection requires 127.0.0.1:port")
					}
					change.Endpoint = a[3]
				}
			}
		}
		if change != nil {
			if prev, pe := s.Connection(a[1], nil); pe == nil && change.Transport != prev.Transport && change.LastMiBPerSecond == prev.LastMiBPerSecond {
				change.LastMiBPerSecond = 0
			}
		}
		v, e := s.Connection(a[1], change)
		if e != nil {
			return e
		}
		return output(v)
	case "tailnet":
		if len(a) < 2 || len(a) > 3 {
			return errors.New("tailnet status|login|logout|probe|stop [TAILNET_IP]")
		}
		if runtime.GOOS != "android" && *tailnetMode != "app" {
			sys := &tailscaled.Provider{}
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			st, e := sys.Status(ctx)
			cancel()
			if e == nil {
				if a[1] != "status" {
					return errors.New("existing system Tailscale is managed externally; DeviceBridge only reads/probes it")
				}
				return output(st)
			}
			if *tailnetMode == "system" {
				return e
			}
		}
		socket := *controlSocket
		if socket == "" {
			socket = filepath.Join(*state, "tailnet", "control.sock")
		}
		target := ""
		if len(a) == 3 {
			target = a[2]
		}
		v, _, err := (tailnetipc.Client{Socket: socket}).Exchange(context.Background(), tailnetipc.Request{Operation: a[1], Target: target})
		if err != nil {
			return err
		}
		if a[1] == "status" {
			v.Mode = "app"
		}
		return output(v)
	case "theme":
		if len(a) > 2 {
			return errors.New("theme [system|light|dark|amoled|amoled-green|amoled-red|matte]")
		}
		value := ""
		if len(a) == 2 {
			value = a[1]
		}
		selected, e := s.Theme(value)
		if e != nil {
			return e
		}
		return output(map[string]string{"theme": selected})
	case "init":
		if len(a) == 3 {
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			if err := s.Export("home", home); err != nil {
				return err
			}
		} else if ex, e := s.Exports(); e == nil && len(ex) == 0 {
			if runtime.GOOS != "android" {
				if home, he := os.UserHomeDir(); he == nil && home != "" {
					_ = s.Export("home", home)
				}
				_ = s.Export("filesystem", "/")
			} else {
				if _, se := os.ReadDir("/storage/emulated/0"); se == nil {
					_ = s.Export("phone_storage", "/storage/emulated/0")
				}
				if _, te := os.ReadDir("/data/data/com.termux/files/home"); te == nil {
					_ = s.Export("termux_home", "/data/data/com.termux/files/home")
				}
			}
		}
		return output(protocol.Device{Version: 1, ID: id.ID, Name: id.Name, Features: []string{"remote-files-v1"}})
	case "identity":
		return output(protocol.Device{Version: 1, ID: id.ID, Name: id.Name, Features: []string{"remote-files-v1"}})
	case "networks":
		interfaces, e := net.Interfaces()
		if e != nil {
			return e
		}
		out := []map[string]string{}
		for _, i := range interfaces {
			if i.Flags&net.FlagUp == 0 || i.Flags&net.FlagLoopback != 0 {
				continue
			}
			addrs, e := i.Addrs()
			if e != nil {
				continue
			}
			for _, a := range addrs {
				ip, _, e := net.ParseCIDR(a.String())
				if e == nil && ip.To4() != nil && ip.IsPrivate() {
					out = append(out, map[string]string{"interface": i.Name, "cidr": a.String(), "metered": "unknown; explicit approval required"})
				}
			}
		}
		return output(out)
	case "export":
		if len(a) != 3 {
			return errors.New("export ROOT_ID DIRECTORY (restart agent to apply)")
		}
		if err = s.Export(a[1], a[2]); err != nil {
			return err
		}
		return output(map[string]string{"status": "export_registered", "root": a[1]})
	case "invite":
		inv, e := id.Invite(s)
		if e != nil {
			return e
		}
		inv.LANEndpoint = invitationLANEndpoint(*state, *iface, *cidr)
		return output(inv)
	case "rename-peer":
		if len(a) != 3 {
			return errors.New("rename-peer PEER NAME")
		}
		if err := s.RenamePeer(a[1], a[2]); err != nil {
			return err
		}
		return output(map[string]string{"name": strings.TrimSpace(a[2])})
	case "peers":
		peers, e := s.Peers()
		if e != nil {
			return e
		}
		type peerSummary struct {
			storage.Peer
			AdvertisedName string   `json:"advertised_name,omitempty"`
			SSHTarget      string   `json:"ssh_target,omitempty"`
			Tags           []string `json:"tags,omitempty"`
			Groups         []string `json:"groups,omitempty"`
		}
		aclPolicy, _ := s.ACLPolicy(context.Background())
		summaries := make([]peerSummary, 0, len(peers))
		for _, peer := range peers {
			peer.Name = protocol.DeviceDisplayName(peer.Name)
			peer.Addresses, e = s.EndpointRecords(peer.ID)
			if e != nil {
				return e
			}
			summary := peerSummary{Peer: peer}
			if peer.Alias != "" {
				summary.AdvertisedName = peer.Name
				summary.Name = peer.Alias
			}
			if tags, tagErr := s.PeerTags(context.Background(), peer.ID); tagErr == nil && len(tags) > 0 {
				summary.Tags = tags
			}
			for g, members := range aclPolicy.Groups {
				if slices.Contains(members, peer.ID) {
					summary.Groups = append(summary.Groups, g)
				}
			}
			slices.Sort(summary.Groups)
			if peer.Status == "paired" {
				if profile, err := s.PeerSSH(peer.ID, nil); err == nil && profile.Host != "" {
					port := profile.Port
					if port <= 0 {
						port = 22
					}
					summary.SSHTarget = net.JoinHostPort(strings.Trim(profile.Host, "[]"), strconv.Itoa(port))
					if profile.User != "" {
						summary.SSHTarget = profile.User + "@" + summary.SSHTarget
					}
				}
			}
			summaries = append(summaries, summary)
		}
		return output(summaries)
	case "share-inbox":
		inbox, e := s.TextInbox()
		if e != nil {
			return e
		}
		return output(inbox)
	case "share-files":
		inbox, e := transfer.ListSharedFileInbox(*state)
		if e != nil {
			return e
		}
		return output(inbox)
	case "syncthing":
		return runSyncthing(a[1:], *state, *iface, *cidr, *syncApproved)
	case "project":
		return runProject(a[1:], *state, s, id, *iface, *cidr, *endpoint, *syncApproved)
	case "sync-local":
		return localSyncControl(*state, s, a, *syncApproved)
	case "sync-worker":
		return delegatedSyncControl(*state, s, a)
	case "sync-owner-stop":
		return stopOwnedSync(*state, s, a)
	case "sync-pairs":
		return localSyncPairs(s, a)
	case "action-inbox", "action-approve", "action-revoke":
		return localAction(s, a)
	case "guest-open", "guest-list", "guest-pull", "guest-close", "guest-terminal",
		"guest-terminal-approve", "guest-terminal-revoke", "local-terminal":
		policy, pe := s.NetworkPolicy(context.Background(), nil)
		if pe != nil {
			return pe
		}
		return guestCommand(s, bootstrap.TailnetOptions{
			StateDir: *state, ControlSocket: *controlSocket, Mode: *tailnetMode, NetworkPolicy: policy,
		}, a)
	case "share-forget-text":
		if len(a) != 3 {
			return errors.New("share-forget-text SENDER_ID MESSAGE_ID")
		}
		if err = s.ForgetText(a[1], a[2]); err != nil {
			return err
		}
		return output(map[string]string{"status": "removed"})
	case "share-text-access", "share-file-access", "sync-control-access", "sync-remote-access", "termux-files-access":
		if len(a) < 2 || len(a) > 3 {
			return fmt.Errorf("%s PEER [allow|deny]", a[0])
		}
		peer, e := s.Peer(a[1])
		if e != nil {
			return e
		}
		var update *bool
		if len(a) == 3 {
			if a[2] != "allow" && a[2] != "deny" {
				return fmt.Errorf("%s PEER [allow|deny]", a[0])
			}
			value := a[2] == "allow"
			update = &value
		}
		access := s.TextShareAccess
		if a[0] == "share-file-access" {
			access = s.FileShareAccess
		}
		if a[0] == "sync-control-access" {
			access = s.SyncControlAccess
		}
		if a[0] == "sync-remote-access" {
			access = s.SyncRemoteAccess
		}
		if a[0] == "termux-files-access" {
			access = s.TermuxFilesAccess
		}
		allowed, e := access(peer.ID, update)
		if e != nil {
			return e
		}
		return output(map[string]bool{"allowed": allowed})
	case "approve":
		if len(a) < 2 || len(a) > 5 {
			return errors.New("approve FULL_DEVICE_ID [ROOT_IDS_COMMA_SEPARATED] [TTL=24h] [BYTE_QUOTA=10737418240]")
		}
		roots := []string{}
		if len(a) > 2 && a[2] == "all" {
			ex, exErr := s.Exports()
			if exErr != nil {
				return exErr
			}
			for _, e := range ex {
				roots = append(roots, e.ID)
			}
		} else if len(a) > 2 && a[2] != "" {
			roots = strings.Split(a[2], ",")
		}
		ttl := 24 * time.Hour
		if len(a) > 3 {
			ttl, err = time.ParseDuration(a[3])
			if err != nil {
				return err
			}
		}
		quota := int64(10 << 30)
		if len(a) > 4 {
			if _, err = fmt.Sscan(a[4], &quota); err != nil {
				return err
			}
		}
		if err = s.Approve(a[1], roots, ttl, quota); err != nil {
			return err
		}
		return output(map[string]string{"status": "approved", "id": a[1]})
	case "revoke":
		if len(a) != 2 {
			return errors.New("revoke FULL_DEVICE_ID")
		}
		if err = s.Revoke(a[1]); err != nil {
			return err
		}
		return output(map[string]string{"status": "revoked"})
	case "remove":
		if len(a) != 2 {
			return errors.New("remove FULL_DEVICE_ID")
		}
		if err = s.RemovePeer(a[1]); err != nil {
			return err
		}
		return output(map[string]string{"status": "removed"})
	case "link-operation":
		if len(a) != 2 && len(a) != 5 && len(a) != 4 {
			return errors.New("link-operation PEER [begin KIND ROLE | STAGE ID]")
		}
		action, kind, role, opID := "", "", "", ""
		if len(a) == 5 {
			action = a[2]
			if action != "begin" {
				return errors.New("expected begin")
			}
			kind = a[3]
			role = a[4]
		}
		if len(a) == 4 {
			action = a[2]
			if action == "begin" {
				return errors.New("begin requires kind and role")
			}
			opID = a[3]
		}
		op, err := s.LinkOperation(context.Background(), a[1], action, kind, role, opID)
		if err != nil {
			return err
		}
		return output(op)
	case "peer-ssh-method":
		if len(a) < 2 || len(a) > 3 {
			return errors.New("peer-ssh-method PEER [auto|agent|ssh:HOST_ID]")
		}
		var update *string
		if len(a) == 3 {
			update = &a[2]
		}
		method, err := s.PeerSSHMethod(context.Background(), a[1], update)
		if err != nil {
			return err
		}
		return output(map[string]string{"method": method})
	case "peer-ssh-access":
		if len(a) < 2 || len(a) > 3 {
			return errors.New("peer-ssh-access PEER [allow|deny]")
		}
		action := ""
		if len(a) == 3 {
			action = a[2]
			if action != "allow" && action != "deny" {
				return errors.New("local approval must be allow or deny")
			}
		}
		access, err := s.AgentSSHAccess(context.Background(), a[1], action)
		if err != nil {
			return err
		}
		return output(access)
	case "network-policy":
		var update map[string]bool
		if len(a) == 2 && a[1] == "-" {
			dec := json.NewDecoder(io.LimitReader(os.Stdin, 8192))
			if err := dec.Decode(&update); err != nil {
				return err
			}
		} else if len(a) != 1 {
			return errors.New("network-policy [-]")
		}
		policy, err := s.NetworkPolicy(context.Background(), update)
		if err != nil {
			return err
		}
		return output(policy)
	case "ssh-hosts":
		return sshHostsCommand(s, bootstrap.TailnetOptions{StateDir: *state, ControlSocket: *controlSocket, Mode: *tailnetMode}, a)
	case "acl":
		return aclCommand(s, a)
	case "tailnet-pair-match", "tailnet-pair":
		return tailnetPairCommand(s, id, *state, *controlSocket, *tailnetMode, *endpoint, a)
	case "peer-tags":
		return peerTagsCommand(s, a)
	case "acl-group":
		return aclGroupCommand(s, a)
	case "ssh-probe":
		var pos []string
		probeTransport := ""
		remoteApproved := false
		for i := 1; i < len(a); i++ {
			switch a[i] {
			case "--transport":
				if i+1 >= len(a) {
					return errors.New("missing value for --transport")
				}
				i++
				probeTransport = a[i]
			case "--remote-approved":
				remoteApproved = true
			default:
				pos = append(pos, a[i])
			}
		}
		if len(pos) < 1 || len(pos) > 2 {
			return errors.New("ssh-probe HOST [PORT]")
		}
		port := 22
		if len(pos) == 2 {
			_, _ = fmt.Sscan(pos[1], &port)
		}
		opts, pe := sshOptions(context.Background(), s, bootstrap.TailnetOptions{
			SSHTransport:   probeTransport,
			RemoteApproved: remoteApproved,
			StateDir:       *state,
			ControlSocket:  *controlSocket,
			Mode:           *tailnetMode,
		})
		if pe != nil {
			return pe
		}
		probe, pe := bootstrap.InspectHostWithOptions(context.Background(), pos[0], port, opts)
		if pe != nil {
			return pe
		}
		return output(probe)
	case "ssh-bootstrap":
		if len(a) != 2 || a[1] != "-" {
			return errors.New("ssh-bootstrap - (reads JSON request from stdin)")
		}
		rawReq, re := io.ReadAll(io.LimitReader(os.Stdin, 65536))
		if re != nil {
			return re
		}
		var req bootstrap.Request
		if re = json.Unmarshal(rawReq, &req); re != nil {
			return re
		}
		if req.Port == 0 {
			req.Port = 22
		}
		var upgrade *storage.SSHHost
		if req.SSHHostID != "" {
			host, err := s.SSHHost(context.Background(), req.SSHHostID)
			if err != nil {
				return err
			}
			if (!req.AutoPair && !req.Reinstall) || req.Host != host.Host || req.User != host.User || req.Port != host.Port || req.ExpectedHostKey != host.Fingerprint {
				return errors.New("SSH agent maintenance requires the verified saved account")
			}
			if req.Reinstall {
				req.ServiceUser = host.ServiceUser
				req.Transport, req.RemoteApproved = host.Transport, host.RemoteApproved
			}
			upgrade = &host
		} else if req.Reinstall {
			return errors.New("save and verify the SSH account before reinstalling DeviceBridge")
		}
		if req.PreferredRoute == "" && req.Transport == "tailnet" {
			req.PreferredRoute = "tailnet"
		}
		req.LocalIface = *iface
		req.LocalCIDR = *cidr
		req.Tailnet, re = sshOptions(context.Background(), s, bootstrap.TailnetOptions{
			SSHTransport:   req.Transport,
			RemoteApproved: req.RemoteApproved,
			StateDir:       *state,
			ControlSocket:  *controlSocket,
			Mode:           *tailnetMode,
		})
		if re != nil {
			return re
		}
		setupCtx, cancelSetup := context.WithTimeout(context.Background(), 5*time.Minute)
		defer cancelSetup()
		res, be := bootstrap.Bootstrap(setupCtx, s, id, req)
		if be != nil {
			if !res.AgentInstalled {
				return be
			}
			res.SetupError = be.Error()
		}
		if res.PairedPeerID != "" {
			if err := recordBootstrapSSHAccount(context.Background(), s, req, res, upgrade); err != nil {
				res.AssociationError = err.Error()
			}
		}
		return output(res)
	case "ssh-uninstall", "ssh-uninstall-host":
		if len(a) != 3 || a[2] != "-" {
			return errors.New("ssh-uninstall DEVICE_ID - or ssh-uninstall-host SSH_HOST_ID - (reads JSON credentials from stdin)")
		}
		rawReq, re := io.ReadAll(io.LimitReader(os.Stdin, 65536))
		if re != nil {
			return re
		}
		var req bootstrap.UninstallRequest
		if re = json.Unmarshal(rawReq, &req); re != nil {
			return re
		}
		fromSSH := a[0] == "ssh-uninstall-host"
		if fromSSH {
			host, err := s.SSHHost(context.Background(), a[1])
			if err != nil {
				return err
			}
			req.Host, req.Port, req.User, req.ExpectedHostKey = host.Host, host.Port, host.User, host.Fingerprint
			req.ServiceUser = host.ServiceUser
			req.Transport, req.RemoteApproved = host.Transport, host.RemoteApproved
		} else if _, err := s.Peer(a[1]); err != nil {
			return err
		}
		req.Tailnet, re = sshOptions(context.Background(), s, bootstrap.TailnetOptions{
			SSHTransport:   req.Transport,
			RemoteApproved: req.RemoteApproved,
			StateDir:       *state,
			ControlSocket:  *controlSocket,
			Mode:           *tailnetMode,
		})
		if re != nil {
			return re
		}
		uctx, cancel := context.WithTimeout(context.Background(), 75*time.Second)
		defer cancel()
		peerID := a[1]
		if fromSSH {
			var err error
			peerID, err = bootstrap.UninstallSSHHost(uctx, req)
			if err != nil {
				return err
			}
			if _, err := s.Peer(peerID); errors.Is(err, sql.ErrNoRows) || peerID == "" {
				return output(map[string]string{"status": "uninstalled"})
			} else if err != nil {
				return fmt.Errorf("agent uninstalled, but checking local pairing failed: %w", err)
			}
		} else if err := bootstrap.Uninstall(uctx, peerID, req); err != nil {
			return err
		}
		if err := s.RemovePeer(peerID); err != nil {
			return fmt.Errorf("laptop agent was uninstalled, but local removal failed: %w", err)
		}
		return output(map[string]string{"status": "uninstalled"})
	case "ssh-run":
		if len(a) != 2 || a[1] != "-" {
			return errors.New("ssh-run - (reads JSON request from stdin)")
		}
		rawReq, re := io.ReadAll(io.LimitReader(os.Stdin, 65536))
		if re != nil {
			return re
		}
		var req bootstrap.ExecRequest
		if re = json.Unmarshal(rawReq, &req); re != nil {
			return re
		}
		req.Tailnet = bootstrap.TailnetOptions{
			StateDir:      *state,
			ControlSocket: *controlSocket,
			Mode:          *tailnetMode,
		}
		sigCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		res, ce := bootstrap.RunCommandStreaming(sigCtx, req, func(stream, chunk string) {
			evt, _ := json.Marshal(map[string]any{
				"ssh_output": true,
				"stream":     stream,
				"chunk":      chunk,
			})
			fmt.Fprintln(os.Stderr, string(evt))
		})
		if ce != nil {
			return ce
		}
		return output(res)
	case "adb-devices":
		return output(discoverADBDevices(context.Background()))
	case "adb-forward-peer":
		if len(a) != 2 || runtime.GOOS != "linux" {
			return errors.New("adb-forward-peer PEER is only available on Linux USB hosts")
		}
		peer, e := s.Peer(a[1])
		if e != nil || peer.Status != "paired" {
			return storage.ErrDenied
		}
		adb := linkctl.FindADBPath()
		if adb == "" {
			return errors.New("adb binary not found on host")
		}
		ctx, stop := context.WithTimeout(context.Background(), 14*time.Second)
		defer stop()
		for _, device := range discoverADBDevices(ctx) {
			endpoint := device.Endpoint
			var addedPort string
			if endpoint == "" {
				raw, err := exec.CommandContext(ctx, adb, "-s", device.Serial, "forward", "tcp:0", "tcp:8731").Output()
				port, parseErr := strconv.ParseUint(strings.TrimSpace(string(raw)), 10, 16)
				if err != nil || parseErr != nil || port == 0 {
					continue
				}
				addedPort = strconv.FormatUint(port, 10)
				endpoint = net.JoinHostPort("127.0.0.1", addedPort)
			}
			loopback, _ := direct.NewCIDR("lo", "127.0.0.1/8")
			attempt, cancel := context.WithTimeout(ctx, 2200*time.Millisecond)
			c := &command{state: s, identity: id, provider: loopback, ctx: attempt,
				endpoint: endpoint, selectedTransport: "adb"}
			cl, candidate, verifyErr := c.connect(peer.ID, true)
			cancel()
			if verifyErr == nil {
				cl.Close()
				return output(candidate)
			}
			if addedPort != "" {
				cleanup, stopCleanup := context.WithTimeout(context.Background(), 3*time.Second)
				_ = exec.CommandContext(cleanup, adb, "-s", device.Serial, "forward", "--remove", "tcp:"+addedPort).Run()
				stopCleanup()
			}
		}
		return errors.New("no wired USB Android device authenticated as this peer")
	case "adb-reverse":
		serial := ""
		if len(a) >= 2 {
			serial = a[1]
		}
		res, re := linkctl.Prepare(context.Background(), *state, protocol.ConnectionPrepareRequest{Kind: "adb_usb", Serial: serial}, nil)
		if re != nil {
			return re
		}
		return output(res)
	case "link-caps":
		return output(linkctl.DetectCapabilities(context.Background()))
	case "link-details":
		liIface := ""
		if len(a) >= 2 {
			liIface = a[1]
		}
		res := linkctl.WifiLinkDetails(context.Background(), liIface)
		if res == nil {
			return output(map[string]any{})
		}
		return output(res)
	case "link-active":
		return output(linkctl.ActiveDirectLink(context.Background(), *state))
	case "link-lease-watch":
		if len(a) != 2 {
			return errors.New("link-lease-watch OPERATION_ID")
		}
		return watchLocalLinkLease(context.Background(), s, *state, a[1])
	case "link-local-commit":
		if len(a) != 2 {
			return errors.New("link-local-commit OPERATION_ID")
		}
		if err := commitLocalLink(context.Background(), s, a[1]); err != nil {
			return err
		}
		return output(map[string]bool{"committed": true})
	case "link-host":
		if len(a) != 2 || a[1] != "-" {
			return errors.New("link-host -")
		}
		var req protocol.ConnectionPrepareRequest
		if err := json.NewDecoder(io.LimitReader(os.Stdin, 8192)).Decode(&req); err != nil {
			return err
		}
		if req.Kind != "hotspot" && req.Kind != "wifi_direct" {
			return errors.New("invalid host link kind")
		}
		if err := startLocalLinkLease(context.Background(), s, *state, req.OperationID, req.LeaseSeconds); err != nil {
			return err
		}
		hostCtx, stop := context.WithTimeout(context.Background(), 45*time.Second)
		defer stop()
		res, err := linkctl.Prepare(hostCtx, *state, req, nil)
		if err != nil {
			return err
		}
		return output(res)
	case "wifi-join":
		var req protocol.ConnectionPrepareRequest
		if len(a) >= 2 && a[1] == "-" {
			rawReq, re := io.ReadAll(io.LimitReader(os.Stdin, 8192))
			if re != nil {
				return re
			}
			if re = json.Unmarshal(rawReq, &req); re != nil {
				return re
			}
		}
		req.Kind = "wifi_join"
		if err := startLocalLinkLease(context.Background(), s, *state, req.OperationID, req.LeaseSeconds); err != nil {
			return err
		}
		jctx, jcancel := context.WithTimeout(context.Background(), 35*time.Second)
		defer jcancel()
		res, je := linkctl.JoinWifiNetwork(jctx, *state, protocol.ConnectionPrepareRequest{
			Kind:       "wifi_join",
			SSID:       req.SSID,
			Passphrase: req.Passphrase,
			BSSID:      req.BSSID,
			Band:       req.Band,
		}, nil)
		if je != nil {
			return je
		}
		return output(res)
	case "wifi-restore", "link-stop", "hotspot-stop":
		res, re := linkctl.Restore(context.Background(), *state)
		if re != nil {
			return re
		}
		if lease, err := s.LinkLease(context.Background()); err == nil && lease.Peer == "local" && res.OK {
			_, _ = s.ChangeLinkLease(context.Background(), "local", lease.ID, "restored", 0)
		}
		return output(res)
	case "discover-ssh":
		var req bootstrap.DiscoverRequest
		if len(a) >= 2 && a[1] == "-" {
			rawReq, re := io.ReadAll(io.LimitReader(os.Stdin, 65536))
			if re != nil {
				return re
			}
			if len(rawReq) > 0 {
				if re = json.Unmarshal(rawReq, &req); re != nil {
					return re
				}
			}
		}
		req.Tailnet = bootstrap.TailnetOptions{
			StateDir:      *state,
			ControlSocket: *controlSocket,
			Mode:          *tailnetMode,
		}
		dctx, dcancel := context.WithTimeout(context.Background(), 12*time.Second)
		defer dcancel()
		found, de := bootstrap.DiscoverSSH(dctx, s, req)
		if de != nil {
			return de
		}
		return output(found)
	case "peer-actions":
		if len(a) < 2 || len(a) > 3 {
			return errors.New("peer-actions PEER_ID [-]")
		}
		var update []storage.PeerAction
		save := false
		if len(a) == 3 {
			if a[2] != "-" {
				return errors.New("peer-actions PEER_ID [-]")
			}
			rawActions, re := io.ReadAll(io.LimitReader(os.Stdin, 65536))
			if re != nil {
				return re
			}
			if re = json.Unmarshal(rawActions, &update); re != nil {
				return re
			}
			save = true
		}
		actions, ae := s.PeerActions(a[1], update, save)
		if ae != nil {
			return ae
		}
		return output(actions)
	case "peer-ssh":
		if len(a) < 2 || len(a) > 3 {
			return errors.New("peer-ssh PEER_ID [-]")
		}
		var update *storage.PeerSSHProfile
		if len(a) == 3 {
			if a[2] != "-" {
				return errors.New("peer-ssh PEER_ID [-]")
			}
			rawProfile, re := io.ReadAll(io.LimitReader(os.Stdin, 65536))
			if re != nil {
				return re
			}
			var prof storage.PeerSSHProfile
			if re = json.Unmarshal(rawProfile, &prof); re != nil {
				return re
			}
			update = &prof
		}
		prof, pe := s.PeerSSH(a[1], update)
		if pe != nil {
			return pe
		}
		return output(prof)
	case "host-ssh":
		if len(a) < 2 || len(a) > 3 {
			return errors.New("host-ssh HOST [-]")
		}
		var update *storage.PeerSSHProfile
		if len(a) == 3 {
			if a[2] != "-" {
				return errors.New("host-ssh HOST [-]")
			}
			rawProfile, re := io.ReadAll(io.LimitReader(os.Stdin, 65536))
			if re != nil {
				return re
			}
			var prof storage.PeerSSHProfile
			if re = json.Unmarshal(rawProfile, &prof); re != nil {
				return re
			}
			update = &prof
		}
		prof, pe := s.HostSSH(a[1], update)
		if pe != nil {
			return pe
		}
		return output(prof)
	case "wireguard":
		if len(a) < 2 {
			return errors.New("wireguard status|import-conf|remove-conf|add-peer|probe")
		}
		switch a[1] {
		case "status":
			cfg, we := wireguard.LoadConfig(*state)
			if errors.Is(we, wireguard.ErrNotConfigured) {
				return output(map[string]any{
					"configured":      false,
					"backend":         wireguard.DetectBackend(*wgBackend),
					"public_key":      "",
					"local_tunnel_ip": "",
					"peers":           []wireguard.PeerConfig{},
				})
			}
			if we != nil {
				return we
			}
			return output(map[string]any{
				"configured":             true,
				"imported":               cfg.Imported,
				"default_route_stripped": cfg.DefaultRouteStripped,
				"scoped_allowed_ips":     cfg.ScopedAllowedIPs,
				"backend":                wireguard.DetectBackend(*wgBackend),
				"public_key":             cfg.PublicKey,
				"local_tunnel_ip":        cfg.LocalTunnelIP,
				"listen_port":            cfg.ListenPort,
				"peers":                  cfg.Peers,
			})
		case "import-conf":
			if len(a) != 3 || a[2] != "-" {
				return errors.New("wireguard import-conf - (reads .conf content from stdin)")
			}
			rawConf, re := io.ReadAll(io.LimitReader(os.Stdin, 65536))
			if re != nil {
				return re
			}
			cfg, we := wireguard.ImportConf(*state, string(rawConf))
			if we != nil {
				return we
			}
			return output(map[string]any{
				"configured":             true,
				"imported":               cfg.Imported,
				"default_route_stripped": cfg.DefaultRouteStripped,
				"scoped_allowed_ips":     cfg.ScopedAllowedIPs,
				"backend":                wireguard.DetectBackend(*wgBackend),
				"public_key":             cfg.PublicKey,
				"local_tunnel_ip":        cfg.LocalTunnelIP,
				"listen_port":            cfg.ListenPort,
				"peers":                  cfg.Peers,
			})
		case "remove-conf":
			if we := wireguard.DeleteConfig(*state); we != nil {
				return we
			}
			return output(map[string]any{"configured": false})
		case "init":
			return errors.New("WireGuard never auto-generates keys; import a .conf file with wireguard import-conf -")
		case "add-peer":
			if len(a) != 3 || a[2] != "-" {
				return errors.New("wireguard add-peer - (reads PeerConfig JSON from stdin)")
			}
			rawP, re := io.ReadAll(io.LimitReader(os.Stdin, 16384))
			if re != nil {
				return re
			}
			var peerCfg wireguard.PeerConfig
			if re = json.Unmarshal(rawP, &peerCfg); re != nil {
				return re
			}
			cfg, we := wireguard.UpsertPeer(*state, peerCfg)
			if we != nil {
				return we
			}
			return output(map[string]any{"status": "peer_saved", "peers": cfg.Peers})
		case "probe":
			if len(a) != 3 {
				return errors.New("wireguard probe TUNNEL_IP:PORT")
			}
			wp := &wireguard.Provider{
				StateDir:       *state,
				Control:        tailnetipc.Client{Socket: filepath.Join(*state, "wireguard", "control.sock")},
				RemoteApproved: *remoteApproved,
				BackendMode:    *wgBackend,
			}
			cand, we := wp.Probe(context.Background(), transport.Candidate{Endpoint: a[2], Transport: wp.ID()})
			if we != nil {
				return we
			}
			return output(cand)
		default:
			return errors.New("unknown wireguard subcommand")
		}
	}
	var p *direct.Provider
	policy, policyErr := s.NetworkPolicy(context.Background(), nil)
	if policyErr != nil {
		return policyErr
	}
	if !networkAllowsTransport(policy, *transportID) {
		return errors.New("transport disabled in Network settings")
	}
	switch *transportID {
	case "lan":
		p, err = direct.NewCIDR(*iface, *cidr)
		if err != nil {
			return err
		}
		p.Discovery = func(ctx context.Context) ([]transport.Candidate, error) { return discovery.Browse(ctx, p) }
	case "adb", "ssh":
		p, err = direct.NewCIDR("lo", "127.0.0.1/8")
		if err != nil {
			return err
		}
	case "tailnet", "wireguard":
	default:
		return errors.New("unsupported selected transport")
	}
	reg := &transport.Registry{}
	if p != nil {
		if err = reg.Register(p); err != nil {
			return err
		}
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if a[0] == "resolve" {
		var stopProbe context.CancelFunc
		ctx, stopProbe = context.WithTimeout(ctx, 8*time.Second)
		defer stopProbe()
	}
	c := &command{state: s, identity: id, provider: p, endpoint: *endpoint, ctx: ctx, selectedTransport: *transportID}
	overlayAllowed := *remoteApproved
	switch a[0] {
	case "resolve", "peer-caps", "roots", "list", "stat", "prepare-link", "restore-link", "send-text", "agent-actions", "action", "sync-control":
		// Peer authentication and bounded control requests precede bulk consent.
		overlayAllowed = true
	}
	if *transportID == "tailnet" {
		if !overlayAllowed {
			return errors.New("allow internet and relay transfers for this device before sending file data over Tailscale")
		}
		c.overlay, err = openOverlay(ctx, *state, *controlSocket, *tailnetMode, overlayAllowed)
		if err != nil {
			return err
		}
		if err = reg.Register(c.overlay); err != nil {
			return err
		}
	} else if *transportID == "wireguard" {
		c.overlay = &wireguard.Provider{
			StateDir:       *state,
			Control:        tailnetipc.Client{Socket: filepath.Join(*state, "wireguard", "control.sock")},
			RemoteApproved: overlayAllowed,
			BackendMode:    *wgBackend,
			TunnelOnly:     *wgTunnelOnly,
		}
		if err = reg.Register(c.overlay); err != nil {
			return err
		}
	}
	if a[0] == "discover" {
		if p == nil {
			return errors.New("LAN discovery requires a selected local network")
		}
		all, e := p.DiscoverCandidates(ctx)
		if e != nil {
			return e
		}
		return output(all)
	}
	if a[0] == "pair" {
		if len(a) != 2 {
			return errors.New("pair INVITATION_JSON_FILE (or - for stdin)")
		}
		var data []byte
		if a[1] == "-" {
			data, err = io.ReadAll(io.LimitReader(os.Stdin, 4096))
		} else {
			data, err = os.ReadFile(a[1])
		}
		if err != nil {
			return err
		}
		var inv protocol.Invitation
		if err = json.Unmarshal(data, &inv); err != nil {
			return err
		}
		var status protocol.PairStatus
		err = c.withPairingRoute(inv.ID, inv.LANEndpoint, func(ctx context.Context, cl *client.Client, v transport.Candidate) error {
			var e error
			status, e = cl.RequestPair(ctx, inv, id.Name)
			if e != nil {
				return e
			}
			return s.RecordPairingEndpoint(inv.ID, *transportID, v.Endpoint)
		})
		if err != nil {
			return err
		}
		return output(status)
	}
	if len(a) < 2 {
		return errors.New("device name or full id required")
	}
	peer, err := c.peer(a[1])
	if err != nil {
		return err
	}
	if c.endpoint == "" && (*transportID == "adb" || *transportID == "ssh" || *transportID == "wireguard" || *transportID == "tailnet") {
		if savedConn, ce := s.Connection(peer.ID, nil); ce == nil {
			if *transportID == "adb" && savedConn.AdbEndpoint != "" {
				c.endpoint = savedConn.AdbEndpoint
			} else if *transportID == "ssh" && savedConn.SshEndpoint != "" {
				c.endpoint = savedConn.SshEndpoint
			} else if *transportID == "wireguard" && savedConn.WireGuardEndpoint != "" {
				c.endpoint = savedConn.WireGuardEndpoint
			} else if *transportID == "tailnet" && savedConn.TailnetEndpoint != "" {
				c.endpoint = savedConn.TailnetEndpoint
			} else if savedConn.Transport == *transportID && savedConn.Endpoint != "" {
				c.endpoint = savedConn.Endpoint
			}
		}
	}
	if a[0] == "pull" || a[0] == "pull-tar" {
		snapshot := os.Getenv("DEVICEBRIDGE_PULL_LAN")
		if *requirePullPolicy && snapshot == "" {
			return errors.New("Android download network policy is unavailable")
		}
		return c.runPull(a, peer.ID, pullRoutes{
			stateDir: *state, iface: *iface, cidr: *cidr, controlSocket: *controlSocket,
			tailnetMode: *tailnetMode, wgBackend: *wgBackend, allowFallback: *allowFallback,
			manualLAN: *manualLANContext || isManualLAN(*iface), wgTunnelOnly: *wgTunnelOnly,
			policy: pullPolicy{snapshot: snapshot},
		})
	}
	if a[0] == "finish" {
		conn, err := s.Connection(peer.ID, nil)
		if err != nil {
			return err
		}
		if err := c.withPairingRoute(peer.ID, conn.LanEndpoint, func(ctx context.Context, cl *client.Client, v transport.Candidate) error {
			if err := cl.FinishPair(ctx); err != nil {
				return err
			}
			return s.RecordVerifiedEndpoint(peer.ID, *transportID, v.Endpoint)
		}); err != nil {
			return err
		}
		return output(map[string]string{"status": "paired", "id": peer.ID})
	}
	cl, candidate, err := c.connect(peer.ID, true)
	if err != nil {
		return err
	}
	defer cl.Close()
	switch a[0] {
	case "resolve":
		handshake := time.Now().UTC()
		s.RecordHandshake(peer.ID, handshake)
		switch *transportID {
		case "lan":
			if !*manualLANContext && !isManualLAN(candidate.Interface) {
				_ = s.RecordVerifiedEndpoint(peer.ID, "lan", candidate.Endpoint)
			}
		case "tailnet":
			_ = s.RecordVerifiedEndpoint(peer.ID, "tailnet", candidate.Endpoint)
		case "wireguard":
			if candidate.PathKind != "direct-lan" {
				_ = s.RecordVerifiedEndpoint(peer.ID, "wireguard", candidate.Endpoint)
			}
		}
		if conn, e := s.Connection(peer.ID, nil); e == nil && conn.LastMiBPerSecond > 0 {
			candidate.MiBPerSecond = conn.LastMiBPerSecond
			candidate.BytesPerSecond = conn.LastMiBPerSecond * 1024 * 1024
		}
		return output(struct {
			transport.Candidate
			Capabilities    *protocol.DeviceCapabilities `json:"capabilities,omitempty"`
			LastHandshakeAt int64                        `json:"last_handshake_at"`
		}{candidate, c.verifiedDevice.Capabilities, handshake.Unix()})
	case "peer-caps":
		dev := c.verifiedDevice
		return output(map[string]any{
			"id":           dev.ID,
			"name":         dev.Name,
			"features":     dev.Features,
			"capabilities": dev.Capabilities,
			"rtt":          candidate.RTT,
			"endpoint":     candidate.Endpoint,
			"transport":    candidate.Transport,
		})
	case "file-push", "file-remove":
		if c.selectedTransport != "lan" || !candidate.Direct {
			return errors.New("Termux file management needs the approved local Wi-Fi connection")
		}
		if !slices.Contains(c.verifiedDevice.Features, protocol.TermuxFilesFeature) {
			return errors.New("update the Termux companion to enable copying and moving files")
		}
		if a[0] == "file-push" {
			return pushTermuxFiles(ctx, cl, a)
		}
		return removeTermuxFiles(ctx, cl, a)

	case "sync-control":
		if len(a) != 3 || a[2] != "-" {
			return errors.New("invalid sync control request")
		}
		if !slices.Contains(c.verifiedDevice.Features, protocol.SyncControlFeature) {
			return errors.New("update DeviceBridge on this endpoint to enable GUI folder sync")
		}
		request, e := readSyncControl()
		if e != nil {
			return e
		}
		result, e := cl.SyncControl(ctx, request)
		if e != nil {
			return e
		}
		return output(result)
	case "agent-actions", "action":
		if !slices.Contains(c.verifiedDevice.Features, actions.Feature) {
			return errors.New("the peer does not offer approved agent actions")
		}
		return remoteAction(ctx, cl, a)
	case "send-text":
		if len(a) != 3 || a[2] != "-" {
			return errors.New("send-text PEER - (reads JSON containing a message ID and text from stdin)")
		}
		if !slices.Contains(c.verifiedDevice.Features, protocol.TextShareFeature) {
			return errors.New("the selected device does not support sharing text")
		}
		var req protocol.TextShareRequest
		dec := json.NewDecoder(io.LimitReader(os.Stdin, 6*protocol.MaxSharedTextBytes+256))
		if err = dec.Decode(&req); err != nil || dec.Decode(new(any)) != io.EOF {
			return errors.New("invalid shared text")
		}
		var receipt struct {
			ID string `json:"id"`
		}
		if err = cl.PostJSON(ctx, "/v1/share/text", req, &receipt); err != nil {
			return err
		}
		if receipt.ID != strings.ToLower(req.ID) {
			return errors.New("the peer returned a different message ID")
		}
		return output(receipt)
	case "send-file":
		if len(a) != 3 {
			return errors.New("send-file PEER LOCAL_FILE")
		}
		if !slices.Contains(c.verifiedDevice.Features, "quick-share-file-v1") {
			return errors.New("the selected device does not support receiving files")
		}
		source, err := os.Open(a[2])
		if err != nil {
			return err
		}
		defer source.Close()
		info, err := source.Stat()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() || info.Size() > transfer.MaxSharedFileBytes {
			return errors.New("send a single regular file up to 64 MiB")
		}
		hash := xxhash.New()
		if n, err := io.Copy(hash, io.LimitReader(source, info.Size()+1)); err != nil {
			return err
		} else if n != info.Size() {
			return errors.New("source changed while hashing")
		}
		if _, err := source.Seek(0, io.SeekStart); err != nil {
			return err
		}
		want := transfer.SharedFile{Name: info.Name(), Size: info.Size(), XXH64: fmt.Sprintf("%016x", hash.Sum64())}
		var receipt transfer.SharedFile
		sendCtx, cancel := context.WithTimeout(ctx, 5*time.Minute)
		defer cancel()
		progress := &fileSendProgress{source: source, total: want.Size}
		if err := cl.SendSharedFile(sendCtx, want.Name, want.XXH64, want.Size, progress, &receipt); err != nil {
			return err
		}
		if receipt != want {
			return errors.New("the peer returned unexpected file verification")
		}
		return output(receipt)
	case "send-folder":
		if len(a) < 3 || len(a) > 4 {
			return errors.New("send-folder PEER LOCAL_FOLDER [none|gzip]")
		}
		if !slices.Contains(c.verifiedDevice.Features, transfer.SharedFolderFeature) {
			return errors.New("the selected device does not support receiving folders")
		}
		codec := "gzip"
		if len(a) == 4 {
			codec = a[3]
		}
		receipt, err := sendSharedFolder(ctx, cl, a[2], codec)
		if err != nil {
			return err
		}
		return output(receipt)
	case "commit-link":
		if len(a) != 3 {
			return errors.New("commit-link PEER OPERATION_ID")
		}
		cl, _, err := c.connect(a[1], true)
		if err != nil {
			return err
		}
		defer cl.Close()
		var result map[string]any
		if err = cl.PostJSON(c.ctx, "/v1/connections/commit", map[string]string{"operation_id": a[2]}, &result); err != nil {
			return err
		}
		return output(result)
	case "prepare-link":
		if len(a) != 3 || a[2] != "-" {
			return errors.New("prepare-link PEER -")
		}
		rawReq, re := io.ReadAll(io.LimitReader(os.Stdin, 8192))
		if re != nil {
			return re
		}
		var req protocol.ConnectionPrepareRequest
		if re = json.Unmarshal(rawReq, &req); re != nil {
			return re
		}
		var res protocol.ConnectionPrepareResult
		if err = cl.PostJSON(ctx, "/v1/connections/prepare", req, &res); err != nil {
			return err
		}
		return output(res)
	case "restore-link":
		var res protocol.ConnectionPrepareResult
		if err = cl.PostJSON(ctx, "/v1/connections/restore", map[string]any{}, &res); err != nil {
			return err
		}
		return output(res)
	case "speedtest":
		secs := 5
		if len(a) >= 3 {
			if v, pe := strconv.Atoi(a[2]); pe == nil && v >= 1 && v <= 15 {
				secs = v
			}
		}
		st, se := cl.SpeedTest(ctx, secs)
		if se != nil {
			return se
		}
		if conn, ce := s.Connection(peer.ID, nil); ce == nil {
			conn.LastMiBPerSecond = st.MiBPerSecond
			_, _ = s.Connection(peer.ID, &conn)
		}
		return output(map[string]any{
			"bytes":          st.Bytes,
			"mib":            st.MiB,
			"seconds":        st.Seconds,
			"mib_per_second": st.MiBPerSecond,
			"transport":      candidate.Transport,
			"endpoint":       candidate.Endpoint,
		})
	case "roots":
		var roots []protocol.Root
		if err = cl.JSON(ctx, "/v1/files/roots", nil, &roots); err != nil {
			return err
		}
		return output(roots)
	case "preview":
		if len(a) != 4 {
			return errors.New("preview PEER ROOT PATH")
		}
		var meta protocol.Entry
		if err = cl.JSON(ctx, "/v1/files/stat", url.Values{"root": {a[2]}, "path": {a[3]}}, &meta); err != nil {
			return err
		}
		if meta.Kind != "file" {
			return errors.New("select a regular file")
		}
		data, e := cl.ReadRange(ctx, a[2], a[3], 0, min(meta.Size, 65536))
		if e != nil {
			return e
		}
		text := strings.ToValidUTF8(string(data), "�")
		if strings.ContainsRune(text, 0) {
			text = "Binary file. Download to open with another application."
		}
		return output(map[string]any{"name": meta.Name, "text": text, "truncated": meta.Size > 65536})
	case "list", "stat":
		if len(a) < 3 || len(a) > 5 {
			return errors.New("list|stat PEER ROOT [RELATIVE_PATH] [PAGE]")
		}
		rel := "."
		if len(a) > 3 {
			rel = a[3]
		}
		q := url.Values{"root": {a[2]}, "path": {rel}}
		if len(a) > 4 {
			q.Set("page", a[4])
		}
		var v any
		if err = cl.JSON(ctx, "/v1/files/"+a[0], q, &v); err != nil {
			return err
		}
		return output(v)
	default:
		return errors.New("unknown command")
	}
}

type adbDeviceInfo struct {
	Serial   string `json:"serial"`
	Kind     string `json:"kind"`  // "usb" | "wireless"
	Label    string `json:"label"` // "ADB over USB" | "Wireless ADB"
	Endpoint string `json:"endpoint"`
	Model    string `json:"model,omitempty"`
}

func discoverADBDevices(ctx context.Context) []adbDeviceInfo {
	devices := []adbDeviceInfo{}
	adbPath := linkctl.FindADBPath()
	if adbPath == "" {
		return devices
	}
	dctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	out, err := exec.CommandContext(dctx, adbPath, "devices", "-l").Output()
	if err != nil {
		return devices
	}
	wired := linkctl.USBADBSerials(string(out))
	if len(wired) == 0 {
		return devices
	}
	fwdOut, _ := exec.CommandContext(dctx, adbPath, "forward", "--list").Output()
	existingFwd := map[string]string{}
	for _, line := range strings.Split(string(fwdOut), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 3 && fields[2] == "tcp:8731" && strings.HasPrefix(fields[1], "tcp:") {
			if port, err := strconv.ParseUint(strings.TrimPrefix(fields[1], "tcp:"), 10, 16); err == nil && port > 0 {
				existingFwd[fields[0]] = net.JoinHostPort("127.0.0.1", strconv.FormatUint(port, 10))
			}
		}
	}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 || fields[1] != "device" || !slices.Contains(wired, fields[0]) {
			continue
		}
		forward := adbDeviceInfo{Serial: fields[0], Kind: "usb", Label: "ADB over USB", Endpoint: existingFwd[fields[0]]}
		for _, field := range fields[2:] {
			if model, ok := strings.CutPrefix(field, "model:"); ok {
				forward.Model = model
				break
			}
		}
		devices = append(devices, forward)
	}
	return devices
}

func tailnetResolveIP(st tailnetipc.Response, target string) string {
	want := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(target), "."))
	if want == "" {
		return ""
	}
	pickIP := func(ips []string) string {
		for _, ip := range ips {
			if parsed := net.ParseIP(strings.TrimSpace(ip)); parsed != nil && parsed.To4() != nil {
				return parsed.String()
			}
		}
		if len(ips) > 0 {
			return strings.TrimSpace(ips[0])
		}
		return ""
	}
	if st.Hostname != "" && strings.EqualFold(strings.TrimSpace(st.Hostname), want) {
		if ip := pickIP(st.IPs); ip != "" {
			return ip
		}
	}
	for _, selfIP := range st.IPs {
		if strings.EqualFold(strings.TrimSpace(selfIP), want) {
			return strings.TrimSpace(selfIP)
		}
	}
	for _, peer := range st.Peers {
		if strings.EqualFold(strings.TrimSpace(peer.Name), want) {
			return pickIP(peer.IPs)
		}
		dnsFull := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(peer.DNSName), "."))
		if dnsFull != "" {
			dnsShort := strings.Split(dnsFull, ".")[0]
			if want == dnsFull || want == dnsShort {
				return pickIP(peer.IPs)
			}
		}
		for _, ip := range peer.IPs {
			if strings.EqualFold(strings.TrimSpace(ip), want) {
				return strings.TrimSpace(ip)
			}
		}
	}
	return ""
}

func tailnetHostMatches(st tailnetipc.Response, target string) bool {
	return tailnetResolveIP(st, target) != ""
}

func main() {
	if err := run(); err != nil {
		_ = json.NewEncoder(os.Stderr).Encode(protocol.Error{Code: "command_failed", Message: err.Error()})
		os.Exit(1)
	}
}
