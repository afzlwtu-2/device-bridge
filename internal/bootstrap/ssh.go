// Package bootstrap sets up, schedules (systemd), firewall-opens, and pairs a target device over user-authorized SSH.
package bootstrap

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"devicebridge/internal/auth"
	"devicebridge/internal/client"
	"devicebridge/internal/storage"
	"devicebridge/internal/transport"
	"devicebridge/internal/transport/direct"
	"devicebridge/protocol"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

type Request struct {
	Host            string `json:"host"`
	Port            int    `json:"port"`
	User            string `json:"user"`
	Password        string `json:"password,omitempty"`
	PrivateKeyPEM   string `json:"private_key_pem,omitempty"`
	ExpectedHostKey string `json:"expected_host_key,omitempty"`
	SudoPassword    string `json:"sudo_password,omitempty"`
	OpenFirewall    bool   `json:"open_firewall"`
	InstallSystemd  bool   `json:"install_systemd"`
	AutoPair        bool   `json:"auto_pair"`
	BridgePort      int    `json:"bridge_port,omitempty"`
	LocalArtifacts  string `json:"local_artifacts,omitempty"`
	PreferredRoute  string `json:"preferred_route,omitempty"` // "lan" | "tailnet"
	LocalIface      string `json:"local_iface,omitempty"`
	LocalCIDR       string `json:"local_cidr,omitempty"`
}

type HostProbe struct {
	Host          string `json:"host"`
	Port          int    `json:"port"`
	HostKeySHA256 string `json:"host_key_sha256"`
	KeyType       string `json:"key_type"`
}

type Result struct {
	Host           string   `json:"host"`
	HostKeySHA256  string   `json:"host_key_sha256"`
	RemoteHostname string   `json:"remote_hostname"`
	LanIface       string   `json:"lan_iface,omitempty"`
	LanCIDR        string   `json:"lan_cidr,omitempty"`
	LanIP          string   `json:"lan_ip,omitempty"`
	TailscaleIP    string   `json:"tailscale_ip,omitempty"`
	SystemdStatus  string   `json:"systemd_status"`
	FirewallStatus string   `json:"firewall_status"`
	PairedPeerID   string   `json:"paired_peer_id,omitempty"`
	PairedRoute    string   `json:"paired_route,omitempty"`
	PairedEndpoint string   `json:"paired_endpoint,omitempty"`
	AgentInstalled bool     `json:"agent_installed"`
	Steps          []string `json:"steps"`
}

func hostKeyFingerprint(k ssh.PublicKey) string {
	sum := sha256.Sum256(k.Marshal())
	return "SHA256:" + base64.RawStdEncoding.EncodeToString(sum[:])
}

func sshAuthMethods(req Request) ([]ssh.AuthMethod, error) {
	var methods []ssh.AuthMethod
	if strings.TrimSpace(req.PrivateKeyPEM) != "" {
		signer, err := ssh.ParsePrivateKey([]byte(req.PrivateKeyPEM))
		if err != nil {
			return nil, fmt.Errorf("invalid private key: %w", err)
		}
		methods = append(methods, ssh.PublicKeys(signer))
	}
	if req.Password != "" {
		pw := req.Password
		methods = append(methods, ssh.Password(pw), ssh.KeyboardInteractive(func(_, _ string, q []string, _ []bool) ([]string, error) {
			ans := make([]string, len(q))
			for i := range q {
				ans[i] = pw
			}
			return ans, nil
		}))
	}
	if len(methods) == 0 {
		return nil, errors.New("SSH password or private key required")
	}
	return methods, nil
}

// InspectHost connects over TCP/SSH solely to read and display the server host key fingerprint before confirmation.
func InspectHost(ctx context.Context, host string, port int) (HostProbe, error) {
	if port <= 0 {
		port = 22
	}
	var probe HostProbe
	probe.Host = host
	probe.Port = port
	d := net.Dialer{Timeout: 8 * time.Second}
	raw, err := d.DialContext(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
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
	c, _, _, err := ssh.NewClientConn(raw, net.JoinHostPort(host, strconv.Itoa(port)), cfg)
	if c != nil {
		_ = c.Close()
	}
	if probe.HostKeySHA256 != "" {
		return probe, nil
	}
	return probe, err
}

func dialSSH(ctx context.Context, req Request) (*ssh.Client, string, error) {
	if req.Port <= 0 {
		req.Port = 22
	}
	methods, err := sshAuthMethods(req)
	if err != nil {
		return nil, "", err
	}
	if strings.TrimSpace(req.ExpectedHostKey) == "" {
		return nil, "", errors.New("expected SSH host key fingerprint confirmation required")
	}
	var actual string
	d := net.Dialer{Timeout: 10 * time.Second}
	addr := net.JoinHostPort(req.Host, strconv.Itoa(req.Port))
	raw, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, "", err
	}
	cfg := &ssh.ClientConfig{
		User:    req.User,
		Auth:    methods,
		Timeout: 12 * time.Second,
		HostKeyCallback: func(_ string, _ net.Addr, key ssh.PublicKey) error {
			actual = hostKeyFingerprint(key)
			if subtle.ConstantTimeCompare([]byte(actual), []byte(req.ExpectedHostKey)) != 1 {
				return fmt.Errorf("SSH host key mismatch: got %s, expected %s", actual, req.ExpectedHostKey)
			}
			return nil
		},
	}
	conn, chans, reqs, err := ssh.NewClientConn(raw, addr, cfg)
	if err != nil {
		raw.Close()
		return nil, actual, err
	}
	return ssh.NewClient(conn, chans, reqs), actual, nil
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
	if stdin != "" {
		sess.Stdin = strings.NewReader(stdin)
	}
	err = sess.Run(cmd)
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

func Bootstrap(ctx context.Context, s *storage.Store, id *auth.Identity, req Request) (Result, error) {
	var res Result
	res.Host = req.Host
	if req.BridgePort <= 0 {
		req.BridgePort = 8731
	}
	cl, fp, err := dialSSH(ctx, req)
	res.HostKeySHA256 = fp
	if err != nil {
		return res, err
	}
	defer cl.Close()
	res.Steps = append(res.Steps, "SSH authenticated ("+fp+")")

	probeScript := `
set -e
echo "HOST=$(hostname)"
echo "HOME=$HOME"
if command -v ip >/dev/null 2>&1; then
  ip -4 -o addr show scope global 2>/dev/null | grep -E -v 'tailscale|docker|waydroid|virbr|br-|veth' | head -n 1 || true
fi
if command -v tailscale >/dev/null 2>&1; then
  echo "TS=$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
fi
echo "HAS_AGENT=$( [ -x "$HOME/.local/share/devicebridge/bin/bridge-agent" ] && echo 1 || echo 0 )"
echo "HAS_CLI=$( [ -x "$HOME/.local/share/devicebridge/bin/bridge-cli" ] && echo 1 || echo 0 )"
`
	out, errOut, err := runSSH(cl, "bash -s", probeScript)
	if err != nil {
		return res, fmt.Errorf("target inspection failed: %w (%s)", err, errOut)
	}
	remoteHome := ""
	hasAgent, hasCLI := false, false
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(line, "HOST="):
			res.RemoteHostname = strings.TrimPrefix(line, "HOST=")
		case strings.HasPrefix(line, "HOME="):
			remoteHome = strings.TrimPrefix(line, "HOME=")
		case strings.HasPrefix(line, "TS="):
			res.TailscaleIP = strings.TrimSpace(strings.TrimPrefix(line, "TS="))
		case strings.HasPrefix(line, "HAS_AGENT="):
			hasAgent = strings.TrimPrefix(line, "HAS_AGENT=") == "1"
		case strings.HasPrefix(line, "HAS_CLI="):
			hasCLI = strings.TrimPrefix(line, "HAS_CLI=") == "1"
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
	remoteBinDir := remoteState + "/bin"
	remoteAgent := remoteBinDir + "/bridge-agent"
	remoteCLI := remoteBinDir + "/bridge-cli"

	if (!hasAgent || !hasCLI) && req.LocalArtifacts != "" {
		if !hasAgent {
			if st, se := os.Stat(filepath.Join(req.LocalArtifacts, "bridge-agent")); se == nil && !st.IsDir() {
				if ue := streamUploadSSH(cl, filepath.Join(req.LocalArtifacts, "bridge-agent"), remoteAgent); ue != nil {
					return res, ue
				}
				hasAgent = true
			}
		}
		if !hasCLI {
			if st, se := os.Stat(filepath.Join(req.LocalArtifacts, "bridge-cli")); se == nil && !st.IsDir() {
				if ue := streamUploadSSH(cl, filepath.Join(req.LocalArtifacts, "bridge-cli"), remoteCLI); ue != nil {
					return res, ue
				}
				hasCLI = true
			}
		}
	}
	if !hasAgent || !hasCLI {
		return res, errors.New("precompiled bridge-agent / bridge-cli not found on target or in local_artifacts")
	}
	res.AgentInstalled = true
	res.Steps = append(res.Steps, "Verified precompiled agent/CLI on target")

	if _, errOut, err = runSSH(cl, fmt.Sprintf("mkdir -p %s && chmod 700 %s && %s --state %s init %s",
		shellQuote(remoteState), shellQuote(remoteState), shellQuote(remoteCLI), shellQuote(remoteState), shellQuote(res.RemoteHostname)), ""); err != nil {
		return res, fmt.Errorf("remote init failed: %w (%s)", err, errOut)
	}
	res.Steps = append(res.Steps, "Initialized remote DeviceBridge state & full-storage defaults")

	if req.InstallSystemd {
		unit := SystemdUnit(remoteAgent, remoteState, res.LanIface, res.LanCIDR, req.BridgePort, res.TailscaleIP != "")
		unitCmd := fmt.Sprintf(`mkdir -p "$HOME/.config/systemd/user" && cat > "$HOME/.config/systemd/user/devicebridge-agent.service" && systemctl --user daemon-reload && systemctl --user enable --now devicebridge-agent.service && systemctl --user is-active devicebridge-agent.service`)
		stOut, stErr, stRunErr := runSSH(cl, "bash -c "+shellQuote(unitCmd), unit)
		if stRunErr != nil {
			res.SystemdStatus = "systemd user unavailable (" + stErr + ")"
		} else {
			res.SystemdStatus = "active (" + stOut + ")"
			res.Steps = append(res.Steps, "Enabled & started systemd user service devicebridge-agent")
		}
	} else {
		res.SystemdStatus = "skipped"
	}

	if req.OpenFirewall {
		fwScript := fmt.Sprintf("if command -v ufw >/dev/null 2>&1; then ufw status | grep -q 'Status: active' && ufw allow proto tcp from any to any port %d comment 'DeviceBridge agent' || echo 'ufw_inactive'; else echo 'no_ufw'; fi", req.BridgePort)
		if req.SudoPassword != "" {
			fwOut, fwErr, fwE := runSSH(cl, "sudo -S -p '' bash -c "+shellQuote(fwScript), req.SudoPassword+"\n")
			if fwE != nil {
				res.FirewallStatus = "sudo ufw failed: " + fwErr
			} else {
				res.FirewallStatus = fwOut
				res.Steps = append(res.Steps, "Configured UFW TCP/"+strconv.Itoa(req.BridgePort))
			}
		} else {
			fwOut, fwErr, fwE := runSSH(cl, "sudo -n bash -c "+shellQuote(fwScript), "")
			if fwE != nil {
				res.FirewallStatus = "passwordless sudo unavailable (" + fwErr + ")"
			} else {
				res.FirewallStatus = fwOut
				res.Steps = append(res.Steps, "Configured UFW TCP/"+strconv.Itoa(req.BridgePort))
			}
		}
	} else {
		res.FirewallStatus = "skipped"
	}

	if req.AutoPair && s != nil && id != nil {
		invRaw, invErr, ie := runSSH(cl, fmt.Sprintf("%s --state %s invite", shellQuote(remoteCLI), shellQuote(remoteState)), "")
		if ie != nil {
			return res, fmt.Errorf("remote invite failed: %w (%s)", ie, invErr)
		}
		var inv protocol.Invitation
		if json.Unmarshal([]byte(invRaw), &inv) != nil {
			return res, errors.New("invalid invite JSON returned by target")
		}
		targetEndpoint := ""
		route := req.PreferredRoute
		if route == "" {
			if res.LanIP != "" {
				route = "lan"
			} else if res.TailscaleIP != "" {
				route = "tailnet"
			}
		}
		if route == "lan" && res.LanIP != "" {
			targetEndpoint = net.JoinHostPort(res.LanIP, strconv.Itoa(req.BridgePort))
		} else if res.TailscaleIP != "" && req.Host != "" {
			targetEndpoint = net.JoinHostPort(res.TailscaleIP, strconv.Itoa(req.BridgePort))
		} else if res.LanIP != "" {
			targetEndpoint = net.JoinHostPort(res.LanIP, strconv.Itoa(req.BridgePort))
		}
		if targetEndpoint == "" {
			return res, errors.New("cannot determine direct DeviceBridge endpoint for auto-pairing")
		}
		iface := req.LocalIface
		cidr := req.LocalCIDR
		if iface == "" {
			iface = "lo"
		}
		if cidr == "" {
			cidr = "127.0.0.1/8"
		}
		if dp, de := direct.NewCIDR(iface, cidr); de == nil {
			cand := transport.Candidate{DeviceID: inv.ID, Endpoint: targetEndpoint, Interface: dp.Interface, Transport: dp.ID(), Direct: true}
			pc := client.New(id, s, dp, cand)
			if _, pe := pc.RequestPair(ctx, inv, id.Name); pe != nil {
				pc.Close()
				return res, fmt.Errorf("auto-pair request to %s failed: %w", targetEndpoint, pe)
			}
			appCmd := fmt.Sprintf("%s --state %s approve %s all 8760h 1099511627776", shellQuote(remoteCLI), shellQuote(remoteState), shellQuote(id.ID))
			if _, appErr, ae := runSSH(cl, appCmd, ""); ae != nil {
				pc.Close()
				return res, fmt.Errorf("remote approve failed: %w (%s)", ae, appErr)
			}
			if fe := pc.FinishPair(ctx); fe != nil {
				pc.Close()
				return res, fmt.Errorf("auto-pair finish failed: %w", fe)
			}
			pc.Close()
			_, _ = s.Connection(inv.ID, &storage.Connection{
				Transport:          route,
				Endpoint:           targetEndpoint,
				RemoteApproved:     route == "tailnet",
				FallbackApproved:   true,
				FallbackTransports: []string{"lan", "adb", "ssh"},
			})
			res.PairedPeerID = inv.ID
			res.PairedRoute = route
			res.PairedEndpoint = targetEndpoint
			res.Steps = append(res.Steps, "Auto-paired directly with "+inv.Name+" ("+targetEndpoint+")")
		}
	}
	return res, nil
}
