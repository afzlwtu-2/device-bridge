// App-only Android/Linux tsnet sidecar. Never uses TUN, VPNService, system daemon
// state, or authentication keys from the environment. Supports SOCKS5 proxy,
// Exit Node routing for tsnet/SOCKS5 traffic, and Tailscale SSH (--ssh).
package main

import (
	"bufio"
	"context"
	"devicebridge/internal/platform"
	"devicebridge/internal/tailnetipc"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"golang.org/x/sys/unix"
	"io"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/net/socks5"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
	"time"
)

func classify(p *ipnstate.PingResult) tailnetipc.Path {
	v := tailnetipc.Path{Kind: "unknown", Observed: time.Now().UTC()}
	if p == nil || p.Err != "" {
		return v
	}
	v.RTTSeconds = p.LatencySeconds
	switch {
	case p.PeerRelay != "":
		v.Kind = "peer-relay"
		v.Relay = p.PeerRelay
	case p.Endpoint != "":
		v.Kind = "direct"
		v.Endpoint = p.Endpoint
	case p.DERPRegionID != 0:
		v.Kind = "derp"
		v.Relay = p.DERPRegionCode
	}
	return v
}
func resolveTarget(st *ipnstate.Status, value string) (netip.Addr, string, error) {
	host, port, err := net.SplitHostPort(value)
	if err != nil {
		host = value
		port = ""
	}
	host = strings.TrimSpace(host)
	if ip, parseErr := netip.ParseAddr(host); parseErr == nil {
		if !netip.MustParsePrefix("100.64.0.0/10").Contains(ip) && !netip.MustParsePrefix("fd7a:115c:a1e0::/48").Contains(ip) {
			return ip, port, errors.New("only tailnet node IPs are supported")
		}
		for _, selfIP := range st.TailscaleIPs {
			if selfIP == ip {
				return ip, port, nil
			}
		}
		for _, p := range st.Peer {
			for _, a := range p.TailscaleIPs {
				if a == ip {
					return ip, port, nil
				}
			}
		}
		return ip, port, errors.New("node not in authenticated tailnet map")
	}
	want := strings.ToLower(strings.TrimSuffix(host, "."))
	for _, p := range st.Peer {
		dnsFull := strings.ToLower(strings.TrimSuffix(p.DNSName, "."))
		dnsShort := strings.Split(dnsFull, ".")[0]
		hostName := strings.ToLower(strings.TrimSpace(p.HostName))
		if want != "" && (want == hostName || want == dnsFull || want == dnsShort) && len(p.TailscaleIPs) > 0 {
			for _, a := range p.TailscaleIPs {
				if a.Is4() {
					return a, port, nil
				}
			}
			return p.TailscaleIPs[0], port, nil
		}
	}
	return netip.Addr{}, port, errors.New("node not in authenticated tailnet map")
}

type tsnetSavedConfig struct {
	Socks5Enabled       bool   `json:"socks5_enabled"`
	Socks5Port          int    `json:"socks5_port"`
	ExitNodeID          string `json:"exit_node_id,omitempty"`
	TailscaleSSHEnabled *bool  `json:"tailscale_ssh_enabled,omitempty"`
	OpenSSHEnabled      bool   `json:"openssh_enabled"`
}

type broker struct {
	stateDir            string
	node                *tsnet.Server
	local               *local.Client
	mu                  sync.Mutex
	upstream            string
	cancel              context.CancelFunc
	socksEnabled        bool
	socksPort           int
	socksAddr           string
	socksListener       *monitoredProxy
	exitNodeID          string
	tailscaleSSHEnabled bool
	openSSHEnabled      bool
}

func (b *broker) configPath() string {
	return filepath.Join(b.stateDir, "tsnet-config.json")
}

func (b *broker) loadSavedConfig() {
	raw, err := os.ReadFile(b.configPath())
	if err != nil {
		return
	}
	var cfg tsnetSavedConfig
	if json.Unmarshal(raw, &cfg) != nil {
		return
	}
	if cfg.Socks5Port < 1024 || cfg.Socks5Port > 65535 {
		cfg.Socks5Port = 1055
	}
	b.mu.Lock()
	b.socksEnabled = cfg.Socks5Enabled
	b.socksPort = cfg.Socks5Port
	b.exitNodeID = strings.TrimSpace(cfg.ExitNodeID)
	if cfg.TailscaleSSHEnabled != nil {
		b.tailscaleSSHEnabled = *cfg.TailscaleSSHEnabled
	}
	b.openSSHEnabled = cfg.OpenSSHEnabled
	b.mu.Unlock()
}

func (b *broker) saveConfigLocked() {
	sshEnabled := b.tailscaleSSHEnabled
	cfg := tsnetSavedConfig{
		Socks5Enabled:       b.socksEnabled,
		Socks5Port:          b.socksPort,
		ExitNodeID:          b.exitNodeID,
		TailscaleSSHEnabled: &sshEnabled,
		OpenSSHEnabled:      b.openSSHEnabled,
	}
	if data, err := json.Marshal(cfg); err == nil {
		_ = os.WriteFile(b.configPath(), data, 0o600)
	}
}

func (b *broker) reconcileSocksLocked() error {
	port := b.socksPort
	if port < 1024 || port > 65535 {
		port = 1055
		b.socksPort = port
	}
	wantAddr := ""
	if b.socksEnabled {
		wantAddr = fmt.Sprintf("127.0.0.1:%d", port)
	}
	if b.socksListener != nil && b.socksAddr == wantAddr {
		return nil
	}
	if b.socksListener != nil {
		_ = b.socksListener.Close()
		b.socksListener = nil
		b.socksAddr = ""
	}
	if !b.socksEnabled {
		return nil
	}
	ln, err := net.Listen("tcp", wantAddr)
	if err != nil {
		return err
	}
	proxy := newMonitoredProxy(ln)
	b.socksListener = proxy
	b.socksAddr = wantAddr
	srv := &socks5.Server{
		Logf: func(string, ...any) {},
		Dialer: func(dialCtx context.Context, network, addr string) (net.Conn, error) {
			if b.node == nil {
				return nil, errors.New("tailnet node unavailable")
			}
			return proxy.dial(dialCtx, network, addr, b.node.Dial)
		},
	}
	go func(l net.Listener) {
		_ = srv.Serve(l)
	}(proxy)
	return nil
}

func (b *broker) applyExitNode(ctx context.Context, id string) error {
	if b.local == nil {
		return nil
	}
	st, stErr := b.local.StatusWithoutPeers(ctx)
	if stErr != nil || st == nil || st.BackendState != "Running" {
		// Defer EditPrefs cleanly while logged out / NeedsLogin instead of failing prefs saves.
		return nil
	}
	trimmed := strings.TrimSpace(id)
	mp := &ipn.MaskedPrefs{
		Prefs: ipn.Prefs{
			ExitNodeID: tailcfg.StableNodeID(trimmed),
		},
		ExitNodeIDSet: true,
	}
	if trimmed == "" {
		mp.Prefs.ExitNodeIP = netip.Addr{}
		mp.ExitNodeIPSet = true
	}
	_, err := b.local.EditPrefs(ctx, mp)
	return err
}

func (b *broker) applyRunSSH(ctx context.Context, enabled bool) error {
	if b.local == nil {
		return nil
	}
	mp := &ipn.MaskedPrefs{
		Prefs: ipn.Prefs{
			RunSSH: enabled,
		},
		RunSSHSet: true,
	}
	_, err := b.local.EditPrefs(ctx, mp)
	return err
}

func (b *broker) probe(ctx context.Context, ip netip.Addr) tailnetipc.Path {
	ctx, cancel := context.WithTimeout(ctx, 2500*time.Millisecond)
	defer cancel()
	p, err := b.local.Ping(ctx, ip, tailcfg.PingDisco)
	if err != nil {
		return classify(nil)
	}
	return classify(p)
}
func (b *broker) handle(ctx context.Context, conn net.Conn) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(25 * time.Second))
	reader := bufio.NewReader(io.LimitReader(conn, 8192))
	line, err := reader.ReadBytes('\n')
	if err != nil {
		return
	}
	var req tailnetipc.Request
	res := tailnetipc.Response{Version: 1, Userspace: true}
	reply := func() { _ = json.NewEncoder(conn).Encode(res) }
	if json.Unmarshal(line, &req) != nil || req.Version != 1 {
		res.Error = "unsupported control request"
		reply()
		return
	}
	timeout := 18 * time.Second
	if req.TimeoutMS > 0 && req.TimeoutMS < 18000 {
		timeout = time.Duration(req.TimeoutMS) * time.Millisecond
	}
	call, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	switch req.Operation {
	case "status":
		if b.local == nil {
			res.Error = "tailnet backend unavailable"
			break
		}
		st, e := b.local.Status(call)
		if e != nil {
			res.Error = e.Error()
			break
		}
		res.State = st.BackendState
		res.LoginURL = st.AuthURL
		if st.Self != nil {
			res.Hostname = st.Self.HostName
		}
		for _, ip := range st.TailscaleIPs {
			res.IPs = append(res.IPs, ip.String())
		}
		b.mu.Lock()
		res.Socks5Enabled = b.socksEnabled
		res.Socks5Addr = b.socksAddr
		if b.socksListener != nil {
			res.ProxyStats = b.socksListener.snapshot()
		}
		res.ExitNodeID = b.exitNodeID
		res.TailscaleSSHEnabled = b.tailscaleSSHEnabled
		res.OpenSSHEnabled = b.openSSHEnabled
		savedExit := b.exitNodeID
		wantSSH := b.tailscaleSSHEnabled
		b.mu.Unlock()
		res.ActiveSSHConns, res.SSHSessions = activeTailscaleSSHStats()
		if prefs, pErr := b.local.GetPrefs(call); pErr == nil && prefs != nil {
			if res.Hostname == "" {
				res.Hostname = prefs.Hostname
			}
			if prefs.RunSSH != wantSSH {
				_ = b.applyRunSSH(call, wantSSH)
			}
			liveExit := string(prefs.ExitNodeID)
			if st.BackendState == "Running" && savedExit != "" && liveExit == "" {
				// Reconcile deferred exit node selection once logged in / Running.
				_ = b.applyExitNode(call, savedExit)
				res.ExitNodeID = savedExit
			} else if liveExit != "" {
				res.ExitNodeID = liveExit
			}
		}
		res.Peers = []tailnetipc.Peer{}
		for _, p := range st.Peer {
			var tags []string
			if p.Tags != nil && !p.Tags.IsNil() {
				tags = p.Tags.AsSlice()
			}
			v := tailnetipc.Peer{
				ID:             string(p.ID),
				Name:           p.HostName,
				DNSName:        strings.TrimSuffix(p.DNSName, "."),
				Online:         p.Online,
				Tags:           tags,
				ExitNodeOption: p.ExitNodeOption,
				Path:           tailnetipc.Path{Kind: "unknown", TxBytes: p.TxBytes, RxBytes: p.RxBytes},
			}
			for _, ip := range p.TailscaleIPs {
				v.IPs = append(v.IPs, ip.String())
			}
			res.Peers = append(res.Peers, v)
		}
	case "prefs":
		var sockErr error
		b.mu.Lock()
		if req.Socks5Enabled != nil {
			b.socksEnabled = *req.Socks5Enabled
		}
		if req.Socks5Port >= 1024 && req.Socks5Port <= 65535 {
			b.socksPort = req.Socks5Port
		}
		if req.ExitNodeID != nil {
			b.exitNodeID = strings.TrimSpace(*req.ExitNodeID)
		}
		if req.TailscaleSSHEnabled != nil {
			b.tailscaleSSHEnabled = *req.TailscaleSSHEnabled
		}
		if req.OpenSSHEnabled != nil {
			b.openSSHEnabled = *req.OpenSSHEnabled
		}
		b.saveConfigLocked()
		sockErr = b.reconcileSocksLocked()
		res.Socks5Enabled = b.socksEnabled
		res.Socks5Addr = b.socksAddr
		res.ExitNodeID = b.exitNodeID
		res.TailscaleSSHEnabled = b.tailscaleSSHEnabled
		res.OpenSSHEnabled = b.openSSHEnabled
		wantSSH := b.tailscaleSSHEnabled
		b.mu.Unlock()
		if sockErr != nil {
			err = sockErr
			break
		}
		if req.TailscaleSSHEnabled != nil {
			if sshErr := b.applyRunSSH(call, wantSSH); sshErr != nil {
				err = sshErr
				break
			}
		}
		if req.ExitNodeID != nil {
			err = b.applyExitNode(call, *req.ExitNodeID)
		}
	case "login":
		err = b.local.StartLoginInteractive(call)
	case "logout":
		err = b.local.Logout(call)
	case "probe", "stream":
		st, e := b.local.Status(call)
		if e != nil {
			err = e
			break
		}
		ip, port, e := resolveTarget(st, req.Target)
		if e != nil {
			err = e
			break
		}
		if req.Operation == "probe" {
			path := b.probe(call, ip)
			res.Path = &path
		}
		if req.Operation == "stream" {
			if !req.RemoteApproved {
				err = errors.New("explicit internet/relay data approval required")
				break
			}
			if req.NetworkHandle != "" {
				res.NetworkHandle = os.Getenv("DEVICEBRIDGE_NETWORK_HANDLE")
				if req.NetworkHandle != res.NetworkHandle {
					err = tailnetipc.ErrNetworkBinding
					break
				}
			}
			portNum, pe := strconv.Atoi(port)
			allowPort := (req.Purpose == "ssh" || req.Purpose == "termux") && pe == nil && portNum >= 1 && portNum <= 65535
			if port == "" || (port != "8731" && !allowPort) {
				err = errors.New("only the DeviceBridge service port is enabled")
				break
			}
			peer, e := b.node.Dial(call, "tcp", net.JoinHostPort(ip.String(), port))
			if e != nil {
				err = e
				break
			}
			defer peer.Close()
			reply()
			_ = conn.SetDeadline(time.Time{})
			_ = peer.SetDeadline(time.Time{})
			done := make(chan struct{})
			go func() {
				io.Copy(peer, conn)
				if p, ok := peer.(interface{ CloseWrite() error }); ok {
					p.CloseWrite()
				}
				close(done)
			}()
			io.Copy(conn, peer)
			conn.Close()
			<-done
			return
		}
	case "upstream":
		if req.Target != "" {
			host, _, e := net.SplitHostPort(req.Target)
			ip, ie := netip.ParseAddr(host)
			if e != nil || ie != nil || (!ip.IsPrivate() && !ip.IsLoopback()) {
				err = errors.New("upstream must be an app-local approved address")
				break
			}
		}
		b.mu.Lock()
		b.upstream = req.Target
		b.mu.Unlock()
	case "stop":
		b.cancel()
	default:
		err = errors.New("unknown control operation")
	}
	if err != nil {
		res.Error = err.Error()
	}
	reply()
}

func run() error {
	state := flag.String("state", "", "private sidecar state directory")
	name := flag.String("name", "termux", "app node hostname")
	flag.Parse()
	if *state == "" {
		return errors.New("--state required")
	}
	if os.Getenv("DEVICEBRIDGE_EXTRA_INTERFACE") == "" {
		if err := platform.BindApprovedNetwork(); err != nil {
			return err
		}
	}
	if err := configureNetworkMonitor(); err != nil {
		return err
	}
	os.Unsetenv("TS_AUTHKEY")
	os.Unsetenv("TSNET_FORCE_LOGIN")
	os.Unsetenv("TS_CLIENT_ID")
	os.Unsetenv("TS_CLIENT_SECRET")
	if err := os.MkdirAll(*state, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(*state)
	if err != nil || !info.IsDir() || info.Mode()&0077 != 0 {
		return errors.New("tailnet state must be a private real directory")
	}
	owner, err := os.OpenFile(filepath.Join(*state, "owner.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer owner.Close()
	if err = unix.Flock(int(owner.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		return errors.New("a live sidecar owns this state")
	}
	defer unix.Flock(int(owner.Fd()), unix.LOCK_UN)
	socket := filepath.Join(*state, "control.sock")
	if existing, e := os.Lstat(socket); e == nil {
		if existing.Mode()&os.ModeSocket == 0 {
			return errors.New("unexpected non-socket control path")
		}
		if e = os.Remove(socket); e != nil {
			return e
		}
	}
	ln, err := net.Listen("unix", socket)
	if err != nil {
		return err
	}
	defer ln.Close()
	defer os.Remove(socket)
	os.Chmod(socket, 0600)
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	node := &tsnet.Server{Dir: filepath.Join(*state, "node"), Hostname: *name, UserLogf: func(string, ...any) {}, Logf: func(string, ...any) {}}
	if err = node.Start(); err != nil {
		return err
	}
	defer node.Close()
	lc, err := node.LocalClient()
	if err != nil {
		return err
	}

	b := &broker{stateDir: *state, node: node, local: lc, cancel: cancel, socksPort: 1055, tailscaleSSHEnabled: true}
	b.loadSavedConfig()
	b.mu.Lock()
	_ = b.reconcileSocksLocked()
	initialExit := b.exitNodeID
	initialSSH := b.tailscaleSSHEnabled
	b.mu.Unlock()
	defer func() {
		b.mu.Lock()
		if b.socksListener != nil {
			_ = b.socksListener.Close()
		}
		b.mu.Unlock()
	}()
	// Reconcile Tailscale SSH (`tailscale up --ssh`) per saved setting (enabled by default).
	sshInitCtx, sshInitCancel := context.WithTimeout(ctx, 3*time.Second)
	_ = b.applyRunSSH(sshInitCtx, initialSSH)
	sshInitCancel()
	go func(id string, wantSSH bool) {
		for i := 0; i < 6; i++ {
			if ctx.Err() != nil {
				return
			}
			attemptCtx, attemptCancel := context.WithTimeout(ctx, 2500*time.Millisecond)
			st, err := lc.StatusWithoutPeers(attemptCtx)
			attemptCancel()
			if err == nil && st != nil && st.BackendState == "Running" {
				applyCtx, applyCancel := context.WithTimeout(ctx, 3*time.Second)
				_ = b.applyRunSSH(applyCtx, wantSSH)
				if id != "" {
					_ = b.applyExitNode(applyCtx, id)
				}
				applyCancel()
				return
			}
			select {
			case <-ctx.Done():
				return
			case <-time.After(1500 * time.Millisecond):
			}
		}
	}(initialExit, initialSSH)
	go func() { <-ctx.Done(); ln.Close() }()
	go func() {
		remote, e := node.Listen("tcp", ":8731")
		if e != nil {
			return
		}
		defer remote.Close()
		for {
			incoming, e := remote.Accept()
			if e != nil {
				return
			}
			go func() {
				defer incoming.Close()
				b.mu.Lock()
				addr := b.upstream
				b.mu.Unlock()
				if addr == "" {
					return
				}
				c, e := net.DialTimeout("tcp", addr, 3*time.Second)
				if e != nil {
					return
				}
				defer c.Close()
				go io.Copy(c, incoming)
				io.Copy(incoming, c)
			}()
		}
	}()
	fmt.Println(`{"version":1,"ready":true,"userspace":true}`)
	for {
		conn, e := ln.Accept()
		if e != nil {
			if ctx.Err() != nil {
				return nil
			}
			return e
		}
		go b.handle(ctx, conn)
	}
}
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
