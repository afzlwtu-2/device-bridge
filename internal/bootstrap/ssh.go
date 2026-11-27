// Package bootstrap sets up, schedules (systemd), firewall-opens, and pairs a target device over user-authorized SSH.
package bootstrap

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"devicebridge/internal/auth"
	"devicebridge/internal/client"
	"devicebridge/internal/storage"
	"devicebridge/internal/tailnetipc"
	"devicebridge/internal/transport"
	"devicebridge/internal/transport/direct"
	"devicebridge/internal/transport/tailnet"
	"devicebridge/internal/transport/tailscaled"
	"devicebridge/internal/transport/wireguard"
	"devicebridge/protocol"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"path"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/crypto/ssh"
)

type TailnetOptions struct {
	SSHTransport   string          `json:"-"`
	RemoteApproved bool            `json:"-"`
	StateDir       string          `json:"-"`
	ControlSocket  string          `json:"-"`
	Mode           string          `json:"-"` // "auto" | "app" | "system"
	NetworkPolicy  map[string]bool `json:"-"`
}

type Request struct {
	Host                 string         `json:"host"`
	Port                 int            `json:"port"`
	User                 string         `json:"user"`
	Password             string         `json:"password,omitempty"`
	PrivateKeyPEM        string         `json:"private_key_pem,omitempty"`
	KeyPassphrase        string         `json:"key_passphrase,omitempty"`
	SSHHostID            string         `json:"ssh_host_id,omitempty"`
	ExpectedHostKey      string         `json:"expected_host_key,omitempty"`
	SudoPassword         string         `json:"sudo_password,omitempty"`
	OpenFirewall         bool           `json:"open_firewall"`
	InstallSystemd       bool           `json:"install_systemd"`
	InstallSystemService bool           `json:"install_system_service,omitempty"`
	TermuxCompanion      bool           `json:"termux_companion,omitempty"`
	AutoPair             bool           `json:"auto_pair"`
	UpdateBinaries       bool           `json:"update_binaries,omitempty"`
	Reinstall            bool           `json:"reinstall,omitempty"`
	AllowTermuxFiles     bool           `json:"allow_termux_files,omitempty"`
	AllowSyncControl     bool           `json:"allow_sync_control,omitempty"`
	AllowSyncRemote      bool           `json:"allow_sync_remote,omitempty"`
	BridgePort           int            `json:"bridge_port,omitempty"`
	LocalArtifacts       string         `json:"local_artifacts,omitempty"`
	PreferredRoute       string         `json:"preferred_route,omitempty"` // "lan" | "tailnet"
	Transport            string         `json:"transport,omitempty"`       // "auto" | "direct" | "tailnet" | "wireguard" | "adb"
	RemoteApproved       bool           `json:"remote_approved,omitempty"`
	LocalIface           string         `json:"local_iface,omitempty"`
	LocalCIDR            string         `json:"local_cidr,omitempty"`
	Tailnet              TailnetOptions `json:"-"`
}

type HostProbe struct {
	Host          string `json:"host"`
	Port          int    `json:"port"`
	HostKeySHA256 string `json:"host_key_sha256"`
	KeyType       string `json:"key_type"`
	ResolvedHost  string `json:"resolved_host,omitempty"`
	ViaTailnet    bool   `json:"via_tailnet,omitempty"`
}

type Result struct {
	Host             string   `json:"host"`
	HostKeySHA256    string   `json:"host_key_sha256"`
	RemoteHostname   string   `json:"remote_hostname"`
	ResolvedHost     string   `json:"resolved_host,omitempty"`
	ViaTailnet       bool     `json:"via_tailnet,omitempty"`
	LanIface         string   `json:"lan_iface,omitempty"`
	LanCIDR          string   `json:"lan_cidr,omitempty"`
	LanIP            string   `json:"lan_ip,omitempty"`
	TailscaleIP      string   `json:"tailscale_ip,omitempty"`
	WireGuardIP      string   `json:"wireguard_ip,omitempty"`
	SystemdStatus    string   `json:"systemd_status"`
	FirewallStatus   string   `json:"firewall_status"`
	PairedPeerID     string   `json:"paired_peer_id,omitempty"`
	PairedRoute      string   `json:"paired_route,omitempty"`
	PairedEndpoint   string   `json:"paired_endpoint,omitempty"`
	AgentInstalled   bool     `json:"agent_installed"`
	AssociationError string   `json:"association_error,omitempty"`
	SetupError       string   `json:"setup_error,omitempty"`
	Steps            []string `json:"steps"`
}

func hostKeyFingerprint(k ssh.PublicKey) string {
	sum := sha256.Sum256(k.Marshal())
	return "SHA256:" + base64.RawStdEncoding.EncodeToString(sum[:])
}

type ExecRequest struct {
	Host            string         `json:"host"`
	Port            int            `json:"port"`
	User            string         `json:"user"`
	Password        string         `json:"password,omitempty"`
	PrivateKeyPEM   string         `json:"private_key_pem,omitempty"`
	KeyPassphrase   string         `json:"key_passphrase,omitempty"`
	ExpectedHostKey string         `json:"expected_host_key,omitempty"`
	Command         string         `json:"command"`
	Tailnet         TailnetOptions `json:"-"`
}

type ExecResult struct {
	Host          string `json:"host"`
	Port          int    `json:"port"`
	HostKeySHA256 string `json:"host_key_sha256"`
	ViaTailnet    bool   `json:"via_tailnet,omitempty"`
	ExitCode      int    `json:"exit_code"`
	Cancelled     bool   `json:"cancelled,omitempty"`
	Stdout        string `json:"stdout"`
	Stderr        string `json:"stderr"`
}

func sshAuthMethods(password, privateKeyPEM, keyPassphrase string, allowNoAuth bool) ([]ssh.AuthMethod, error) {
	var methods []ssh.AuthMethod
	if strings.TrimSpace(privateKeyPEM) != "" {
		normalized := strings.ReplaceAll(strings.TrimSpace(privateKeyPEM), "\r\n", "\n") + "\n"
		var signer ssh.Signer
		var err error
		if keyPassphrase != "" {
			signer, err = ssh.ParsePrivateKeyWithPassphrase([]byte(normalized), []byte(keyPassphrase))
		} else {
			signer, err = ssh.ParsePrivateKey([]byte(normalized))
		}
		if err != nil {
			var passErr *ssh.PassphraseMissingError
			if errors.As(err, &passErr) {
				if password != "" {
					if s2, e2 := ssh.ParsePrivateKeyWithPassphrase([]byte(normalized), []byte(password)); e2 == nil {
						signer = s2
						err = nil
					}
				}
				if err != nil {
					return nil, errors.New("SSH private key requires passphrase; enter key passphrase")
				}
			} else {
				return nil, fmt.Errorf("invalid private key: %w", err)
			}
		}
		methods = append(methods, ssh.PublicKeys(signer))
	}
	if password != "" {
		pw := password
		methods = append(methods, ssh.Password(pw), ssh.KeyboardInteractive(func(_, _ string, q []string, _ []bool) ([]string, error) {
			ans := make([]string, len(q))
			for i := range q {
				ans[i] = pw
			}
			return ans, nil
		}))
	}
	if len(methods) == 0 {
		if allowNoAuth {
			return methods, nil
		}
		return nil, errors.New("SSH password or private key required")
	}
	return methods, nil
}

func isTailnetIP(ip netip.Addr) bool {
	return netip.MustParsePrefix("100.64.0.0/10").Contains(ip) || netip.MustParsePrefix("fd7a:115c:a1e0::/48").Contains(ip)
}

func isTailnetIPString(raw string) bool {
	ip, err := netip.ParseAddr(strings.TrimSpace(raw))
	return err == nil && isTailnetIP(ip)
}

func tailnetSocketPath(opts TailnetOptions) string {
	if strings.TrimSpace(opts.ControlSocket) != "" {
		return strings.TrimSpace(opts.ControlSocket)
	}
	if strings.TrimSpace(opts.StateDir) != "" {
		return filepath.Join(opts.StateDir, "tailnet", "control.sock")
	}
	return ""
}

func queryTailnetStatus(ctx context.Context, opts TailnetOptions) (st tailnetipc.Response, systemDaemon bool, sock string, ok bool, note string) {
	if runtime.GOOS != "android" && opts.Mode != "app" {
		sctx, cancel := context.WithTimeout(ctx, 2*time.Second)
		sys, e := (&tailscaled.Provider{}).Status(sctx)
		cancel()
		if e == nil && sys.State == "Running" {
			return sys, true, "", true, sys.State
		}
		if opts.Mode == "system" {
			if e != nil {
				return tailnetipc.Response{}, true, "", false, e.Error()
			}
			return sys, true, "", false, sys.State
		}
	}
	sock = tailnetSocketPath(opts)
	if sock == "" {
		return tailnetipc.Response{}, false, "", false, "no tailnet socket"
	}
	cl := tailnetipc.Client{Socket: sock}
	for i := 0; i < 4; i++ {
		sctx, cancel := context.WithTimeout(ctx, 2500*time.Millisecond)
		resp, _, err := cl.Exchange(sctx, tailnetipc.Request{Operation: "status"})
		cancel()
		if err != nil {
			return tailnetipc.Response{}, false, sock, false, err.Error()
		}
		if resp.State == "Running" {
			return resp, false, sock, true, resp.State
		}
		if resp.State != "Starting" {
			return resp, false, sock, false, resp.State
		}
		select {
		case <-ctx.Done():
			return resp, false, sock, false, ctx.Err().Error()
		case <-time.After(350 * time.Millisecond):
		}
	}
	return tailnetipc.Response{}, false, sock, false, "Starting"
}

func preferredTailnetIP(ips []string) string {
	var fallback string
	for _, raw := range ips {
		ip, err := netip.ParseAddr(strings.TrimSpace(raw))
		if err != nil || !isTailnetIP(ip) {
			continue
		}
		if ip.Is4() {
			return ip.String()
		}
		if fallback == "" {
			fallback = ip.String()
		}
	}
	return fallback
}

func matchTailnetPeer(query string, peers []tailnetipc.Peer) (peerIP string, peerName string, matched bool, err error) {
	q := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(query)), ".")
	if q == "" {
		return "", "", false, nil
	}
	type candidate struct {
		name   string
		ip     string
		online bool
	}
	var exact []candidate
	var prefix []candidate
	for _, p := range peers {
		ip := preferredTailnetIP(p.IPs)
		if ip == "" {
			continue
		}
		name := strings.ToLower(strings.TrimSpace(p.Name))
		dns := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(p.DNSName), "."))
		shortDNS := dns
		if dot := strings.IndexByte(shortDNS, '.'); dot > 0 {
			shortDNS = shortDNS[:dot]
		}
		c := candidate{name: p.Name, ip: ip, online: p.Online}
		if name == q || (dns != "" && dns == q) || (shortDNS != "" && shortDNS == q) {
			exact = append(exact, c)
		} else if (name != "" && strings.HasPrefix(name, q)) || (shortDNS != "" && strings.HasPrefix(shortDNS, q)) {
			prefix = append(prefix, c)
		}
	}
	if len(exact) == 1 {
		return exact[0].ip, exact[0].name, true, nil
	}
	if len(exact) > 1 {
		for _, c := range exact {
			if c.online {
				return c.ip, c.name, true, nil
			}
		}
		return exact[0].ip, exact[0].name, true, nil
	}
	if len(prefix) == 1 {
		return prefix[0].ip, prefix[0].name, true, nil
	}
	if len(prefix) > 1 {
		var online []candidate
		var names []string
		for _, c := range prefix {
			names = append(names, c.name)
			if c.online {
				online = append(online, c)
			}
		}
		if len(online) == 1 {
			return online[0].ip, online[0].name, true, nil
		}
		return "", "", false, fmt.Errorf("ambiguous Tailscale hostname %q matches multiple peers (%s); use full hostname or Tailscale IP", query, strings.Join(names, ", "))
	}
	return "", "", false, nil
}

func (opts TailnetOptions) allows(transport string) bool {
	allowed, set := opts.NetworkPolicy["network_"+transport]
	return !set || allowed
}

func dialDirectSSH(ctx context.Context, host string, port int) (net.Conn, error) {
	dialer := &net.Dialer{
		Timeout: 8 * time.Second,
		ControlContext: func(_ context.Context, _, address string, _ syscall.RawConn) error {
			ip, err := netip.ParseAddrPort(address)
			if err != nil {
				return err
			}
			if isTailnetIP(ip.Addr().Unmap()) {
				return errors.New("select and approve Tailscale for this SSH address")
			}
			return nil
		},
	}
	return dialer.DialContext(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
}

func dialTargetTCP(ctx context.Context, opts TailnetOptions, host string, port int) (net.Conn, bool, string, error) {
	if opts.SSHTransport == "adb" {
		if !opts.allows("adb") || !opts.allows("usb") {
			return nil, false, "", errors.New("ADB SSH disabled in Network settings")
		}
		ip := net.ParseIP(host)
		if ip == nil || !ip.IsLoopback() {
			return nil, false, "", errors.New("ADB SSH endpoint must be an owned loopback mapping")
		}
		conn, err := (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
		return conn, false, host, err
	}
	direct := func(host string) (net.Conn, bool, string, error) {
		if !opts.allows("direct") {
			return nil, false, host, errors.New("direct SSH disabled in Network settings")
		}
		conn, err := dialDirectSSH(ctx, host, port)
		return conn, false, host, err
	}
	if opts.SSHTransport == "direct" {
		return direct(host)
	}
	if opts.SSHTransport == "wireguard" {
		if !opts.RemoteApproved || !opts.allows("wireguard") {
			return nil, false, "", errors.New("WireGuard SSH requires route approval and an enabled transport")
		}
		p := &wireguard.Provider{StateDir: opts.StateDir, Control: tailnetipc.Client{Socket: filepath.Join(opts.StateDir, "wireguard", "control.sock")}, RemoteApproved: true, TunnelOnly: true}
		conn, err := p.Dial(ctx, transport.Candidate{Endpoint: net.JoinHostPort(host, strconv.Itoa(port))})
		return conn, false, host, err
	}
	canUseTailnet := opts.RemoteApproved && opts.allows("tailnet")
	if opts.SSHTransport == "tailnet" && !canUseTailnet {
		return nil, false, "", errors.New("Tailscale SSH requires route approval and an enabled transport")
	}
	cleanHost := strings.TrimSpace(host)
	if cleanHost == "" {
		return nil, false, "", errors.New("target host required")
	}
	if ip, err := netip.ParseAddr(cleanHost); err == nil {
		if opts.SSHTransport == "tailnet" && !isTailnetIP(ip) {
			return nil, false, "", errors.New("selected Tailscale transport requires a tailnet address")
		}
		addr := net.JoinHostPort(ip.String(), strconv.Itoa(port))
		if isTailnetIP(ip.Unmap()) {
			if !canUseTailnet {
				return nil, false, "", errors.New("select and approve Tailscale for this SSH address")
			}
			st, systemDaemon, sock, ok, note := queryTailnetStatus(ctx, opts)
			if ok && !systemDaemon && sock != "" {
				_ = st
				_, conn, dialErr := (tailnetipc.Client{Socket: sock}).Exchange(ctx, tailnetipc.Request{
					Operation:      "stream",
					Target:         addr,
					RemoteApproved: true,
					Purpose:        "ssh",
				})
				if dialErr != nil {
					return nil, true, ip.String(), fmt.Errorf("SSH over tsnet (%s): %w", addr, dialErr)
				}
				return conn, true, ip.String(), nil
			}
			conn, dialErr := (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, "tcp", addr)
			if dialErr != nil && !ok && sock != "" && note != "" {
				return nil, true, ip.String(), fmt.Errorf("%w (tsnet state: %s)", dialErr, note)
			}
			return conn, true, ip.String(), dialErr
		}
		return direct(ip.String())
	}

	if !canUseTailnet {
		return direct(cleanHost)
	}
	st, systemDaemon, sock, ok, note := queryTailnetStatus(ctx, opts)
	if ok {
		peerIP, peerName, matched, matchErr := matchTailnetPeer(cleanHost, st.Peers)
		if matchErr != nil {
			return nil, false, "", matchErr
		}
		if matched {
			addr := net.JoinHostPort(peerIP, strconv.Itoa(port))
			if !systemDaemon && sock != "" {
				_, conn, dialErr := (tailnetipc.Client{Socket: sock}).Exchange(ctx, tailnetipc.Request{
					Operation:      "stream",
					Target:         addr,
					RemoteApproved: true,
					Purpose:        "ssh",
				})
				if dialErr != nil {
					return nil, true, peerIP, fmt.Errorf("SSH over tsnet to %s (%s): %w", peerName, addr, dialErr)
				}
				return conn, true, peerIP, nil
			}
			conn, dialErr := (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, "tcp", addr)
			if dialErr != nil {
				return nil, true, peerIP, fmt.Errorf("SSH to Tailscale peer %s (%s): %w", peerName, addr, dialErr)
			}
			return conn, true, peerIP, nil
		}
	}

	if opts.SSHTransport == "tailnet" {
		return nil, false, "", errors.New("target is not reachable through the selected tailnet")
	}
	raw, _, _, err := direct(cleanHost)
	if err != nil && !ok && strings.Contains(err.Error(), "no such host") && (opts.StateDir != "" || opts.ControlSocket != "") {
		return nil, false, cleanHost, fmt.Errorf("%w (app-only Tailscale/tsnet state: %s — enable and log in to Tailscale in Connections to resolve Tailscale hostnames)", err, note)
	}
	return raw, false, cleanHost, err
}

// InspectHost connects over TCP/SSH solely to read and display the server host key fingerprint before confirmation.
func InspectHost(ctx context.Context, host string, port int) (HostProbe, error) {
	return InspectHostWithOptions(ctx, host, port, TailnetOptions{})
}

// InspectHostWithOptions probes SSH host key fingerprint over direct TCP or app-only tsnet/tailscaled.
func InspectHostWithOptions(ctx context.Context, host string, port int, opts TailnetOptions) (HostProbe, error) {
	if port <= 0 {
		port = 22
	}
	var probe HostProbe
	probe.Host = host
	probe.Port = port
	raw, viaTailnet, resolvedHost, err := dialTargetTCP(ctx, opts, host, port)
	probe.ViaTailnet = viaTailnet
	if resolvedHost != "" {
		probe.ResolvedHost = resolvedHost
	}
	if err != nil {
		return probe, err
	}
	defer raw.Close()
	cfg := &ssh.ClientConfig{
		User:    "probe",
		Auth:    []ssh.AuthMethod{ssh.Password("")},
		Timeout: 8 * time.Second,
		HostKeyCallback: func(_ string, _ net.Addr, key ssh.PublicKey) error {
			probe.HostKeySHA256 = hostKeyFingerprint(key)
			probe.KeyType = key.Type()
			return errors.New("probe_captured")
		},
	}
	addrHost := resolvedHost
	if addrHost == "" {
		addrHost = host
	}
	c, _, _, err := ssh.NewClientConn(raw, net.JoinHostPort(addrHost, strconv.Itoa(port)), cfg)
	if c != nil {
		_ = c.Close()
	}
	if probe.HostKeySHA256 != "" {
		return probe, nil
	}
	return probe, err
}

func dialSSHParams(ctx context.Context, opts TailnetOptions, host string, port int, user, password, privateKeyPEM, keyPassphrase, expectedHostKey string) (*ssh.Client, string, bool, string, error) {
	if port <= 0 {
		port = 22
	}
	if strings.TrimSpace(expectedHostKey) == "" {
		return nil, "", false, "", errors.New("expected SSH host key fingerprint confirmation required")
	}
	var actual string
	raw, viaTailnet, resolvedHost, err := dialTargetTCP(ctx, opts, host, port)
	if err != nil {
		return nil, "", viaTailnet, resolvedHost, err
	}
	methods, err := sshAuthMethods(password, privateKeyPEM, keyPassphrase, viaTailnet)
	if err != nil {
		raw.Close()
		return nil, "", viaTailnet, resolvedHost, err
	}
	addrHost := resolvedHost
	if addrHost == "" {
		addrHost = host
	}
	addr := net.JoinHostPort(addrHost, strconv.Itoa(port))
	deadline := time.Now().Add(12 * time.Second)
	if limit, present := ctx.Deadline(); present && limit.Before(deadline) {
		deadline = limit
	}
	if err := raw.SetDeadline(deadline); err != nil {
		raw.Close()
		return nil, "", viaTailnet, resolvedHost, err
	}
	stopOnCancel := context.AfterFunc(ctx, func() { _ = raw.Close() })
	defer stopOnCancel()
	cfg := &ssh.ClientConfig{
		User:    user,
		Auth:    methods,
		Timeout: 12 * time.Second,
		HostKeyCallback: func(_ string, _ net.Addr, key ssh.PublicKey) error {
			actual = hostKeyFingerprint(key)
			if subtle.ConstantTimeCompare([]byte(actual), []byte(expectedHostKey)) != 1 {
				return fmt.Errorf("SSH host key mismatch: got %s, expected %s", actual, expectedHostKey)
			}
			return nil
		},
	}
	conn, chans, reqs, err := ssh.NewClientConn(raw, addr, cfg)
	if err != nil {
		raw.Close()
		if viaTailnet && password == "" && strings.TrimSpace(privateKeyPEM) == "" && strings.Contains(err.Error(), "unable to authenticate") {
			return nil, actual, viaTailnet, resolvedHost, fmt.Errorf("%w (Tailscale SSH 'none' auth was not accepted on port %d — if this is OpenSSH, enter password or import a PEM key)", err, port)
		}
		return nil, actual, viaTailnet, resolvedHost, err
	}
	_ = raw.SetDeadline(time.Time{})
	return ssh.NewClient(conn, chans, reqs), actual, viaTailnet, resolvedHost, nil
}

func dialSSH(ctx context.Context, req Request) (*ssh.Client, string, bool, string, error) {
	return dialSSHParams(ctx, req.Tailnet, req.Host, req.Port, req.User, req.Password, req.PrivateKeyPEM, req.KeyPassphrase, req.ExpectedHostKey)
}

// RunCommand executes one explicit user-authorized shell command over verified SSH.
func RunCommand(ctx context.Context, req ExecRequest) (ExecResult, error) {
	return RunCommandStreaming(ctx, req, nil)
}

// RunCommandStreaming executes one explicit user-authorized shell command over verified SSH,
// forwarding stdout/stderr chunks to onChunk while active and cleanly terminating on ctx cancellation.
func RunCommandStreaming(ctx context.Context, req ExecRequest, onChunk func(stream, chunk string)) (ExecResult, error) {
	if req.Port <= 0 {
		req.Port = 22
	}
	if strings.TrimSpace(req.Command) == "" {
		return ExecResult{}, errors.New("command required")
	}
	cl, fp, viaTailnet, _, err := dialSSHParams(ctx, req.Tailnet, req.Host, req.Port, req.User, req.Password, req.PrivateKeyPEM, req.KeyPassphrase, req.ExpectedHostKey)
	if err != nil {
		return ExecResult{Host: req.Host, Port: req.Port, HostKeySHA256: fp, ViaTailnet: viaTailnet}, err
	}
	defer cl.Close()

	sess, err := cl.NewSession()
	if err != nil {
		return ExecResult{Host: req.Host, Port: req.Port, HostKeySHA256: fp, ViaTailnet: viaTailnet}, err
	}
	defer sess.Close()

	stdoutPipe, err := sess.StdoutPipe()
	if err != nil {
		return ExecResult{Host: req.Host, Port: req.Port, HostKeySHA256: fp, ViaTailnet: viaTailnet}, err
	}
	stderrPipe, err := sess.StderrPipe()
	if err != nil {
		return ExecResult{Host: req.Host, Port: req.Port, HostKeySHA256: fp, ViaTailnet: viaTailnet}, err
	}
	if err = sess.Start(req.Command); err != nil {
		return ExecResult{Host: req.Host, Port: req.Port, HostKeySHA256: fp, ViaTailnet: viaTailnet}, err
	}

	var stdoutBuf, stderrBuf bytes.Buffer
	var cbMu sync.Mutex
	var readersWG sync.WaitGroup
	readPipe := func(streamName string, r io.Reader, dst *bytes.Buffer) {
		defer readersWG.Done()
		buf := make([]byte, 4096)
		for {
			n, rerr := r.Read(buf)
			if n > 0 {
				chunk := string(buf[:n])
				dst.WriteString(chunk)
				if onChunk != nil {
					cbMu.Lock()
					onChunk(streamName, chunk)
					cbMu.Unlock()
				}
			}
			if rerr != nil {
				return
			}
		}
	}
	readersWG.Add(2)
	go readPipe("stdout", stdoutPipe, &stdoutBuf)
	go readPipe("stderr", stderrPipe, &stderrBuf)

	waitCh := make(chan error, 1)
	go func() {
		readersWG.Wait()
		waitCh <- sess.Wait()
	}()

	var waitErr error
	cancelled := false
	select {
	case waitErr = <-waitCh:
	case <-ctx.Done():
		cancelled = true
		_ = sess.Signal(ssh.SIGTERM)
		_ = sess.Close()
		_ = cl.Close()
		select {
		case waitErr = <-waitCh:
		case <-time.After(750 * time.Millisecond):
		}
	}

	res := ExecResult{
		Host:          req.Host,
		Port:          req.Port,
		HostKeySHA256: fp,
		ViaTailnet:    viaTailnet,
		ExitCode:      0,
		Cancelled:     cancelled,
		Stdout:        strings.TrimSpace(stdoutBuf.String()),
		Stderr:        strings.TrimSpace(stderrBuf.String()),
	}
	if cancelled {
		res.ExitCode = -1
		return res, nil
	}
	if waitErr != nil {
		var exitErr *ssh.ExitError
		if errors.As(waitErr, &exitErr) {
			res.ExitCode = exitErr.ExitStatus()
			return res, nil
		}
		return res, waitErr
	}
	return res, nil
}

func runSSH(cl *ssh.Client, cmd string, stdin string) (string, string, error) {
	sess, err := cl.NewSession()
	if err != nil {
		return "", "", err
	}
	defer sess.Close()
	var stdout, stderr bytes.Buffer
	sess.Stdout = &stdout
	sess.Stderr = &stderr
	var stdinDone chan struct{}
	if stdin != "" {
		pw, pe := sess.StdinPipe()
		if pe != nil {
			return "", "", pe
		}
		stdinDone = make(chan struct{})
		go func() {
			defer close(stdinDone)
			_, _ = io.WriteString(pw, stdin)
			_ = pw.Close()
		}()
	}
	err = sess.Run(cmd)
	_ = sess.Close()
	if stdinDone != nil {
		<-stdinDone
	}
	return strings.TrimSpace(stdout.String()), strings.TrimSpace(stderr.String()), err
}

func streamUploadSSH(cl *ssh.Client, localPath, remotePath string) error {
	f, err := os.Open(localPath)
	if err != nil {
		return err
	}
	defer f.Close()
	sess, err := cl.NewSession()
	if err != nil {
		return err
	}
	defer sess.Close()
	sess.Stdin = f
	cmd := fmt.Sprintf("mkdir -p %s && umask 077 && cat > %s.tmp && chmod 700 %s.tmp && mv -f %s.tmp %s",
		shellQuote(filepath.Dir(remotePath)),
		shellQuote(remotePath),
		shellQuote(remotePath),
		shellQuote(remotePath),
		shellQuote(remotePath),
	)
	var stderr bytes.Buffer
	sess.Stderr = &stderr
	if err = sess.Run(cmd); err != nil {
		return fmt.Errorf("upload %s failed: %w (%s)", filepath.Base(remotePath), err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// SystemdUnit returns the user-level systemd unit template for bridge-agent.
func SystemdUnit(binPath, stateDir, iface, cidr string, port int, withSystemTailnet bool) string {
	if strings.TrimSpace(iface) == "" {
		iface = "auto"
	}
	if strings.TrimSpace(cidr) == "" {
		cidr = "auto"
	}
	execArgs := fmt.Sprintf("%s --state %s --interface %s --lan-cidr %s --port %d", binPath, stateDir, iface, cidr, port)
	if withSystemTailnet {
		execArgs += " --system-tailnet"
	}
	return fmt.Sprintf(`[Unit]
Description=DeviceBridge peer agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%s
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
`, execArgs)
}

func runRemoteRoot(cl *ssh.Client, sshUser, sudoPass, script string) (string, string, error) {
	if strings.TrimSpace(sshUser) == "root" {
		return runSSH(cl, "bash -c "+shellQuote(script), "")
	}
	if sudoPass != "" {
		return runSSH(cl, "sudo -S -p '' bash -c "+shellQuote(script), sudoPass+"\n")
	}
	return runSSH(cl, "sudo -n bash -c "+shellQuote(script), "")
}

func Bootstrap(ctx context.Context, s *storage.Store, id *auth.Identity, req Request) (Result, error) {
	var res Result
	res.Host = req.Host
	if req.InstallSystemService {
		return res, errors.New("root system service setup has been removed; use the systemd user service")
	}
	if req.BridgePort <= 0 {
		req.BridgePort = 8731
	}
	cl, fp, viaTailnet, resolvedHost, err := dialSSH(ctx, req)
	res.HostKeySHA256 = fp
	res.ViaTailnet = viaTailnet
	if resolvedHost != "" {
		res.ResolvedHost = resolvedHost
	}
	if err != nil {
		return res, err
	}
	defer cl.Close()
	if viaTailnet {
		res.Steps = append(res.Steps, "SSH authenticated over Tailscale ("+fp+")")
	} else {
		res.Steps = append(res.Steps, "SSH authenticated ("+fp+")")
	}

	probeScript := `
set -e
export PATH="$PATH:/usr/local/bin:/usr/sbin:/sbin:$HOME/.local/share/devicebridge/bin:$HOME/.local/bin"
echo "HOST=$(hostname)"
echo "USER=$(id -un 2>/dev/null || echo "$USER")"
echo "HOME=$HOME"
read -r _ _ ssh_local _ <<<"${SSH_CONNECTION:-}"
echo "SSH_LOCAL=$ssh_local"
echo "SSH_UID=$(id -u)"
if command -v ip >/dev/null 2>&1; then
  ip -4 -o addr show scope global 2>/dev/null | awk -v ssh="$ssh_local" '
    $2 !~ /^(tailscale|wg|tun|docker|waydroid|virbr|br-|veth)/ && $3 == "inet" {
      if (!first) first = $0
      split($4, address, "/")
      if (address[1] == ssh) {print; matched = 1; exit}
    }
    END {if (!matched && first) print first}'
fi
if command -v tailscale >/dev/null 2>&1; then
  echo "TS=$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
fi
if command -v ip >/dev/null 2>&1; then
  echo "WG=$(ip -4 -o addr show type wireguard 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 || true)"
fi
OS_NAME="$(uname -s 2>/dev/null || echo Linux)"
case "$(uname -o 2>/dev/null || true)" in
  *Android*) OS_NAME="Android" ;;
esac
echo "TARGET_PLATFORM=${OS_NAME}/$(uname -m 2>/dev/null || echo x86_64)"
if [ "$OS_NAME" = Linux ] && [ -e /etc/systemd/system/devicebridge-agent.service ] &&
   (systemctl is-active --quiet devicebridge-agent.service || systemctl is-enabled --quiet devicebridge-agent.service); then
  echo 'LEGACY_SYSTEM_AGENT=1'
fi
AGENT_BIN="$HOME/.local/share/devicebridge/bin/bridge-agent"
if [ ! -x "$AGENT_BIN" ]; then AGENT_BIN="$(command -v bridge-agent 2>/dev/null || true)"; fi
CLI_BIN="$HOME/.local/share/devicebridge/bin/bridge-cli"
if [ ! -x "$CLI_BIN" ]; then CLI_BIN="$(command -v bridge-cli 2>/dev/null || true)"; fi
echo "AGENT_BIN=$AGENT_BIN"
echo "CLI_BIN=$CLI_BIN"
echo "HAS_AGENT=$( [ -n "$AGENT_BIN" ] && [ -x "$AGENT_BIN" ] && echo 1 || echo 0 )"
echo "HAS_CLI=$( [ -n "$CLI_BIN" ] && [ -x "$CLI_BIN" ] && echo 1 || echo 0 )"
if [ "$OS_NAME" = Android ]; then
  echo "ANDROID_MODEL=$(getprop ro.product.model 2>/dev/null || true)"
  companion="${HOME%/home}/usr/var/lib/devicebridge-companion/bin"
  [ ! -x "$companion/bridge-agent" ] || echo 'COMPANION_AGENT=1'
  [ ! -x "$companion/bridge-cli" ] || echo 'COMPANION_CLI=1'
  [ ! -x "$companion/bridge-sync" ] || echo 'COMPANION_ENGINE=1'
fi
`
	out, errOut, err := runSSH(cl, "bash -s", probeScript)
	if err != nil {
		return res, fmt.Errorf("target inspection failed: %w (%s)", err, errOut)
	}
	remoteUser := strings.TrimSpace(req.User)
	remoteHome := ""
	targetPlatform, sshLocal, androidModel := "", "", ""
	sshUID := -1
	agentBin, cliBin := "", ""
	hasAgent, hasCLI := false, false
	var companionAgent, companionCLI, companionEngine, legacySystemAgent bool
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case line == "LEGACY_SYSTEM_AGENT=1":
			legacySystemAgent = true
		case strings.HasPrefix(line, "HOST="):
			res.RemoteHostname = strings.TrimPrefix(line, "HOST=")
		case strings.HasPrefix(line, "USER="):
			if u := strings.TrimSpace(strings.TrimPrefix(line, "USER=")); u != "" {
				remoteUser = u
			}
		case strings.HasPrefix(line, "HOME="):
			remoteHome = strings.TrimPrefix(line, "HOME=")
		case strings.HasPrefix(line, "TARGET_PLATFORM="):
			targetPlatform = strings.TrimSpace(strings.TrimPrefix(line, "TARGET_PLATFORM="))
		case strings.HasPrefix(line, "SSH_LOCAL="):
			sshLocal = strings.TrimPrefix(line, "SSH_LOCAL=")
		case strings.HasPrefix(line, "TS="):
			res.TailscaleIP = strings.TrimSpace(strings.TrimPrefix(line, "TS="))
		case strings.HasPrefix(line, "WG="):
			res.WireGuardIP = strings.TrimSpace(strings.TrimPrefix(line, "WG="))
		case strings.HasPrefix(line, "AGENT_BIN="):
			agentBin = strings.TrimSpace(strings.TrimPrefix(line, "AGENT_BIN="))
		case strings.HasPrefix(line, "CLI_BIN="):
			cliBin = strings.TrimSpace(strings.TrimPrefix(line, "CLI_BIN="))
		case strings.HasPrefix(line, "HAS_AGENT="):
			hasAgent = strings.TrimPrefix(line, "HAS_AGENT=") == "1"
		case strings.HasPrefix(line, "HAS_CLI="):
			hasCLI = strings.TrimPrefix(line, "HAS_CLI=") == "1"
		case strings.HasPrefix(line, "SSH_UID="):
			if uid, err := strconv.Atoi(strings.TrimPrefix(line, "SSH_UID=")); err == nil {
				sshUID = uid
			}
		case strings.HasPrefix(line, "ANDROID_MODEL="):
			androidModel = strings.TrimSpace(strings.TrimPrefix(line, "ANDROID_MODEL="))
		case line == "COMPANION_AGENT=1":
			companionAgent = true
		case line == "COMPANION_CLI=1":
			companionCLI = true
		case line == "COMPANION_ENGINE=1":
			companionEngine = true
		case strings.Contains(line, "inet "):
			fields := strings.Fields(line)
			for i, tok := range fields {
				if tok == "inet" && i+1 < len(fields) && len(fields) > 1 {
					res.LanIface = fields[1]
					res.LanCIDR = fields[i+1]
					ipOnly, _, _ := net.ParseCIDR(res.LanCIDR)
					if ipOnly != nil {
						res.LanIP = ipOnly.String()
					}
					break
				}
			}
		}
	}
	if res.TailscaleIP == "" && viaTailnet && isTailnetIPString(resolvedHost) {
		res.TailscaleIP = resolvedHost
	}
	if remoteHome == "" {
		return res, errors.New("could not resolve target HOME directory")
	}
	if res.LanIface == "" {
		res.LanIface = "eth0"
	}
	if res.LanCIDR == "" {
		res.LanCIDR = "127.0.0.1/8"
	}
	remoteState := remoteHome + "/.local/share/devicebridge"
	isTermux := strings.EqualFold(targetPlatform, "android/aarch64")
	if legacySystemAgent && !req.Reinstall {
		return res, errors.New("the host already has a DeviceBridge system service; migrate that service to the SSH user's account before deploying")
	}
	if req.TermuxCompanion && !isTermux {
		return res, errors.New("the SSH target is not a supported arm64 Termux installation")
	}
	if isTermux {
		if sshUID < 10000 {
			return res, errors.New("sign in as the unprivileged Termux app user")
		}
		remoteState, err = termuxCompanionState(remoteHome)
		if err != nil {
			return res, err
		}
		res.LanCIDR, err = termuxLAN(req.LocalCIDR, sshLocal)
		if err != nil {
			return res, err
		}
		res.LanIP, _, _ = strings.Cut(res.LanCIDR, "/")
		res.LanIface = "wlan0"
		req.BridgePort = termuxCompanionPort
		if androidModel != "" {
			res.RemoteHostname = androidModel
		}
		res.RemoteHostname = "Termux · " + res.RemoteHostname
		hasAgent, hasCLI = companionAgent, companionCLI
		agentBin, cliBin = "", ""
	}
	if !isTermux && (sshUID == 0 || remoteUser == "root") {
		return res, errors.New("sign in as the unprivileged account that will run DeviceBridge")
	}
	if req.Reinstall && isTermux {
		return res, errors.New("SSH agent maintenance only supports the managed Linux installation")
	}
	remoteBinDir := remoteState + "/bin"
	remoteAgent := remoteBinDir + "/bridge-agent"
	if agentBin != "" {
		remoteAgent = agentBin
	}
	remoteCLI := remoteBinDir + "/bridge-cli"
	if cliBin != "" {
		remoteCLI = cliBin
	}

	targetPlatKey := ""
	switch strings.ToLower(targetPlatform) {
	case "linux/x86_64", "linux/amd64":
		targetPlatKey = "linux-x86_64"
	case "linux/aarch64", "linux/arm64":
		targetPlatKey = "linux-aarch64"
	case "android/aarch64", "android/arm64":
		targetPlatKey = "android-aarch64"
	}
	findLocalArt := func(name string) string {
		if req.LocalArtifacts == "" {
			return ""
		}
		if targetPlatKey != "" {
			p := filepath.Join(req.LocalArtifacts, targetPlatKey, name)
			if st, se := os.Stat(p); se == nil && !st.IsDir() {
				return p
			}
		}
		if targetPlatKey == "" || (runtime.GOOS == "linux" && runtime.GOARCH == "amd64" && targetPlatKey == "linux-x86_64") || (runtime.GOOS == "android" && runtime.GOARCH == "arm64" && targetPlatKey == "android-aarch64") {
			p := filepath.Join(req.LocalArtifacts, name)
			if st, se := os.Stat(p); se == nil && !st.IsDir() {
				return p
			}
		}
		return ""
	}

	if req.Reinstall {
		agentArtifact, cliArtifact := findLocalArt("bridge-agent"), findLocalArt("bridge-cli")
		if agentArtifact == "" || cliArtifact == "" {
			return res, fmt.Errorf("reinstall requires bundled agent and CLI binaries for %s", targetPlatform)
		}
		prepare := func(mode string) string {
			return "set -- " + shellQuote(remoteHome) + " " + shellQuote(remoteUser) + " " + mode + "\n" + uninstallLinux
		}
		port, details, err := runSSH(cl, "bash -s", prepare("check-reinstall"))
		if err != nil {
			return res, fmt.Errorf("verify managed installation: %w (%s)", err, details)
		}
		if req.BridgePort, err = strconv.Atoi(port); err != nil || req.BridgePort < 1 || req.BridgePort > 65535 {
			return res, errors.New("could not determine the installed service port")
		}
		stage, details, err := runSSH(cl, "mktemp -d "+shellQuote(remoteBinDir+"/.devicebridge-reinstall.XXXXXXXX"), "")
		if err != nil {
			return res, fmt.Errorf("stage reinstall: %w (%s)", err, details)
		}
		if path.Dir(stage) != remoteBinDir || !strings.HasPrefix(path.Base(stage), ".devicebridge-reinstall.") {
			return res, errors.New("invalid remote staging directory")
		}
		stagedAgent, stagedCLI := stage+"/bridge-agent", stage+"/bridge-cli"
		defer runSSH(cl, "rm -f -- "+shellQuote(stagedAgent)+" "+shellQuote(stagedCLI)+" "+
			shellQuote(stagedAgent+".tmp")+" "+shellQuote(stagedCLI+".tmp")+"; rmdir -- "+shellQuote(stage), "")
		if err := streamUploadSSH(cl, agentArtifact, stagedAgent); err != nil {
			return res, err
		}
		if err := streamUploadSSH(cl, cliArtifact, stagedCLI); err != nil {
			return res, err
		}
		if legacySystemAgent {
			if _, details, err := runRemoteRoot(cl, remoteUser, req.SudoPassword, prepare("prepare-reinstall")); err != nil {
				return res, fmt.Errorf("prepare migration from the legacy system service: %w (%s)", err, details)
			}
			res.Steps = append(res.Steps, "Stopped the legacy system service; restarting under the SSH user")
		}
		remoteAgent, remoteCLI = remoteBinDir+"/bridge-agent", remoteBinDir+"/bridge-cli"
		publish := fmt.Sprintf("mv -fT -- %s %s && mv -fT -- %s %s",
			shellQuote(stagedCLI), shellQuote(remoteCLI), shellQuote(stagedAgent), shellQuote(remoteAgent))
		if _, details, err := runSSH(cl, publish, ""); err != nil {
			return res, fmt.Errorf("publish staged DeviceBridge binaries: %w (%s)", err, details)
		}
		hasAgent, hasCLI = true, true
		req.InstallSystemd, req.UpdateBinaries, req.AutoPair = true, false, false
	}

	if (!hasAgent || !hasCLI || req.UpdateBinaries) && req.LocalArtifacts != "" {
		if req.UpdateBinaries {
			remoteAgent = remoteBinDir + "/bridge-agent"
			remoteCLI = remoteBinDir + "/bridge-cli"
		}
		if !hasAgent || req.UpdateBinaries {
			if localPath := findLocalArt("bridge-agent"); localPath != "" {
				if ue := streamUploadSSH(cl, localPath, remoteAgent); ue != nil {
					return res, ue
				}
				hasAgent = true
			}
		}
		if !hasCLI || req.UpdateBinaries {
			if localPath := findLocalArt("bridge-cli"); localPath != "" {
				if ue := streamUploadSSH(cl, localPath, remoteCLI); ue != nil {
					return res, ue
				}
				hasCLI = true
			}
		}
	}
	if !hasAgent || !hasCLI {
		return res, fmt.Errorf("precompiled bridge-agent / bridge-cli not found on target or in local_artifacts (%s)", targetPlatform)
	}
	res.AgentInstalled = true
	if localPath := findLocalArt("bridge-sync"); !req.Reinstall && localPath != "" && (!isTermux || req.UpdateBinaries || !companionEngine) {
		if err := streamUploadSSH(cl, localPath, remoteBinDir+"/bridge-sync"); err != nil {
			return res, err
		}
	}
	res.Steps = append(res.Steps, "Verified precompiled agent/CLI on target")

	cliCommand := fmt.Sprintf("%s --state %s ", shellQuote(remoteCLI), shellQuote(remoteState))
	initialize := cliCommand + "init " + shellQuote(res.RemoteHostname)
	if isTermux {
		initialize += " --home-only"
	}
	if !req.Reinstall {
		if _, errOut, err = runSSH(cl, fmt.Sprintf("mkdir -p %s && chmod 700 %s && %s",
			shellQuote(remoteState), shellQuote(remoteState), initialize), ""); err != nil {
			return res, fmt.Errorf("remote init failed: %w (%s)", err, errOut)
		}
	}
	if isTermux {
		res.Steps = append(res.Steps, "Exported Termux Home from the companion")
		if _, details, err := runSSH(cl, termuxStartCommand(remoteState, remoteAgent, res.LanIface, res.LanCIDR, req.BridgePort), ""); err != nil {
			return res, fmt.Errorf("Termux companion start failed: %w (%s)", err, details)
		}
		res.SystemdStatus = "Termux companion running"
	} else {
		res.Steps = append(res.Steps, "Initialized remote DeviceBridge state & full-storage defaults")
	}

	if req.InstallSystemd && !isTermux {
		unit := SystemdUnit(remoteAgent, remoteState, res.LanIface, "auto", req.BridgePort, true)
		unitCmd := `mkdir -p "$HOME/.config/systemd/user" && cat > "$HOME/.config/systemd/user/devicebridge-agent.service" && systemctl --user daemon-reload && systemctl --user enable devicebridge-agent.service && systemctl --user restart devicebridge-agent.service && systemctl --user is-active devicebridge-agent.service`
		stOut, stErr, stRunErr := runSSH(cl, "bash -c "+shellQuote(unitCmd), unit)
		if stRunErr != nil {
			res.SystemdStatus = "systemd user unavailable (" + stErr + ")"
			if req.Reinstall {
				return res, fmt.Errorf("restart user service: %w (%s)", stRunErr, stErr)
			}
		} else {
			res.SystemdStatus = "active (" + stOut + ")"
			res.Steps = append(res.Steps, "Enabled & started systemd user service devicebridge-agent")
		}
	} else if !isTermux {
		res.SystemdStatus = "skipped"
	}

	if req.OpenFirewall && !isTermux {
		subnet, subnetErr := netip.ParsePrefix(res.LanCIDR)
		switch {
		case subnetErr == nil && !subnet.Addr().IsLoopback() && subnet.Bits() > 0:
			fwScript := fmt.Sprintf(`set -e
export LC_ALL=C
if ! command -v ufw >/dev/null; then echo 'no_ufw'; exit; fi
if ! ufw status | grep -q 'Status: active'; then echo 'ufw_inactive'; exit; fi
ufw allow in on %s from %s to any port %d proto tcp comment 'DeviceBridge agent'
`, shellQuote(res.LanIface), shellQuote(subnet.Masked().String()), req.BridgePort)
			fwOut, fwErr, fwE := runRemoteRoot(cl, remoteUser, req.SudoPassword, fwScript)
			if fwE != nil {
				res.FirewallStatus = "sudo ufw failed: " + fwErr
			} else {
				res.FirewallStatus = fwOut
				res.Steps = append(res.Steps, "Checked interface-scoped LAN firewall access")
			}
		default:
			res.FirewallStatus = "skipped: no LAN subnet detected"
		}
	} else {
		res.FirewallStatus = "skipped"
	}

	if req.AutoPair && s != nil && id != nil {
		remoteCommand := fmt.Sprintf("%s --state %s ", shellQuote(remoteCLI), shellQuote(remoteState))
		identityRaw, details, err := runSSH(cl, remoteCommand+"identity", "")
		if err != nil {
			return res, fmt.Errorf("remote identity failed: %w (%s)", err, details)
		}
		var remote protocol.Device
		if json.Unmarshal([]byte(identityRaw), &remote) != nil || remote.Version != 1 || len(remote.ID) != 64 {
			return res, errors.New("invalid DeviceBridge identity returned by target")
		}
		peer, err := s.Peer(remote.ID)
		existing := err == nil
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return res, err
		}
		if existing && peer.Status != "paired" && peer.Status != "outbound" {
			return res, fmt.Errorf("the existing DeviceBridge relationship is %s; review it in Devices", peer.Status)
		}
		type pairTarget struct {
			route    string
			endpoint string
			provider transport.Provider
			iface    string
			direct   bool
		}
		var targets []pairTarget
		lanEp := ""
		if res.LanIP != "" {
			lanEp = net.JoinHostPort(res.LanIP, strconv.Itoa(req.BridgePort))
		}
		tsEp := ""
		if res.TailscaleIP != "" {
			tsEp = net.JoinHostPort(res.TailscaleIP, strconv.Itoa(req.BridgePort))
		}
		addLAN := func() {
			if lanEp == "" || !req.Tailnet.allows("direct") {
				return
			}
			iface := req.LocalIface
			cidr := req.LocalCIDR
			if iface == "" {
				iface = "lo"
			}
			if cidr == "" {
				cidr = "127.0.0.1/8"
			}
			if dp, de := direct.NewCIDR(iface, cidr); de == nil && dp.Check(lanEp) == nil {
				targets = append(targets, pairTarget{
					route:    "lan",
					endpoint: lanEp,
					provider: dp,
					iface:    dp.Interface,
					direct:   true,
				})
			}
		}
		addTailnet := func() {
			if tsEp == "" || !req.RemoteApproved || !req.Tailnet.allows("tailnet") {
				return
			}
			_, sys, sock, ok, _ := queryTailnetStatus(ctx, req.Tailnet)
			if !ok {
				return
			}
			var prov transport.Provider
			if sys {
				prov = &tailscaled.Provider{RemoteApproved: true}
			} else if sock != "" {
				prov = &tailnet.Provider{Control: tailnetipc.Client{Socket: sock}, RemoteApproved: true}
			}
			if prov != nil {
				targets = append(targets, pairTarget{
					route:    "tailnet",
					endpoint: tsEp,
					provider: prov,
					direct:   false,
				})
			}
		}
		addWireGuard := func() {
			if !req.RemoteApproved || !req.Tailnet.allows("wireguard") {
				return
			}
			wgIP := res.WireGuardIP
			if wgIP == "" && req.Transport == "wireguard" {
				if resolvedHost != "" {
					wgIP = resolvedHost
				} else {
					wgIP = req.Host
				}
			}
			if wgIP == "" {
				return
			}
			wp := &wireguard.Provider{
				StateDir:       req.Tailnet.StateDir,
				Control:        tailnetipc.Client{Socket: filepath.Join(req.Tailnet.StateDir, "wireguard", "control.sock")},
				RemoteApproved: req.RemoteApproved || viaTailnet,
			}
			targets = append(targets, pairTarget{
				route:    "wireguard",
				endpoint: net.JoinHostPort(wgIP, strconv.Itoa(req.BridgePort)),
				provider: wp,
				direct:   false,
			})
		}
		switch req.Transport {
		case "direct", "adb":
			addLAN()
		case "tailnet":
			addTailnet()
		case "wireguard":
			addWireGuard()
		default:
			preferTailnet := req.PreferredRoute == "tailnet" || (req.PreferredRoute == "" && viaTailnet)
			if preferTailnet {
				addTailnet()
				addWireGuard()
				addLAN()
			} else {
				addLAN()
				addWireGuard()
				addTailnet()
			}
		}
		if len(targets) == 0 {
			return res, errors.New("cannot determine reachable DeviceBridge endpoint (LAN, Tailscale, or WireGuard) for auto-pairing")
		}
		var inv protocol.Invitation
		if !existing {
			invRaw, details, err := runSSH(cl, remoteCommand+"invite", "")
			if err != nil {
				return res, fmt.Errorf("remote invite failed: %w (%s)", err, details)
			}
			if json.Unmarshal([]byte(invRaw), &inv) != nil || inv.ID != remote.ID {
				return res, errors.New("the invitation does not match the SSH-verified DeviceBridge identity")
			}
		}
		var lastPairErr error
		for _, t := range targets {
			cand := transport.Candidate{DeviceID: remote.ID, Endpoint: t.endpoint, Interface: t.iface, Transport: t.provider.ID(), Direct: t.direct}
			pc := client.New(id, s, t.provider, cand)
			if !existing {
				if pe := requestPairWithRetry(ctx, pc, inv, id.Name); pe != nil {
					pc.Close()
					lastPairErr = fmt.Errorf("auto-pair request to %s (%s) failed: %w", t.endpoint, t.route, pe)
					continue
				}
				roots := "all"
				if isTermux {
					roots = "home"
				}
				appCmd := remoteCommand + fmt.Sprintf("approve %s %s 8760h 1099511627776", shellQuote(id.ID), roots)
				if _, details, err = runSSH(cl, appCmd, ""); err != nil {
					pc.Close()
					return res, fmt.Errorf("remote approve failed: %w (%s)", err, details)
				}
			}
			finishErr := pc.FinishPair(ctx)
			pc.Close()
			if finishErr != nil {
				lastPairErr = fmt.Errorf("could not verify the pairing over %s: %w", t.route, finishErr)
				if existing {
					continue
				}
				return res, lastPairErr
			}
			if isTermux && req.AllowTermuxFiles {
				command := remoteCommand + "termux-files-access " + shellQuote(id.ID) + " allow"
				if _, details, e := runSSH(cl, command, ""); e != nil {
					return res, fmt.Errorf("Termux file management approval failed: %w (%s)", e, details)
				}
			}

			if req.AllowSyncControl {
				command := remoteCommand + "sync-control-access " + shellQuote(id.ID) + " allow"
				if _, details, e := runSSH(cl, command, ""); e != nil {
					return res, fmt.Errorf("sync control approval failed: %w (%s)", e, details)
				}
				if req.AllowSyncRemote {
					command = remoteCommand + "sync-remote-access " + shellQuote(id.ID) + " allow"
					if _, details, e := runSSH(cl, command, ""); e != nil {
						return res, fmt.Errorf("remote sync route approval failed: %w (%s)", e, details)
					}
				}
			}
			wgEp := ""
			if res.WireGuardIP != "" {
				wgEp = net.JoinHostPort(res.WireGuardIP, strconv.Itoa(req.BridgePort))
			}
			fallbacks := []string{"lan"}
			if tsEp != "" {
				fallbacks = append(fallbacks, "tailnet")
			}
			if wgEp != "" {
				fallbacks = append(fallbacks, "wireguard")
			}
			if existing {
				if err := s.RecordVerifiedEndpoint(remote.ID, t.route, t.endpoint); err != nil {
					return res, err
				}
			} else {
				_, _ = s.Connection(remote.ID, &storage.Connection{
					Transport:          t.route,
					PreferredTransport: "auto",
					Endpoint:           t.endpoint,
					LanEndpoint:        lanEp,
					TailnetEndpoint:    tsEp,
					WireGuardEndpoint:  wgEp,
					RemoteApproved:     false,
					FallbackApproved:   true,
					FallbackTransports: fallbacks,
				})
			}
			res.PairedPeerID = remote.ID
			res.PairedRoute = t.route
			res.PairedEndpoint = t.endpoint
			action := "Auto-paired"
			if existing {
				action = "Verified existing pairing"
			}
			res.Steps = append(res.Steps, action+" via "+t.route+" with "+remote.Name+" ("+t.endpoint+")")
			return res, nil
		}
		return res, lastPairErr
	}
	return res, nil
}

func requestPairWithRetry(ctx context.Context, pc *client.Client, inv protocol.Invitation, name string) error {
	var err error
	for attempt := 0; attempt < 4; attempt++ {
		if _, err = pc.RequestPair(ctx, inv, name); err == nil {
			return nil
		}
		if attempt < 3 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(350 * time.Millisecond):
			}
		}
	}
	return err
}
