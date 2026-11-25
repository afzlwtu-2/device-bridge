// Package wireguard implements WireGuard transport discovery, direct-on-LAN preference,
// userspace (non-rooted netstack) and kernel (rooted module) backend selection.
package wireguard

import (
	"bufio"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"devicebridge/internal/tailnetipc"
	"devicebridge/internal/transport"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

var ErrNotConfigured = errors.New("WireGuard is not configured; import a .conf file")

const (
	BackendAuto      = "auto"
	BackendUserspace = "userspace"
	BackendKernel    = "kernel"
)

type PeerConfig struct {
	PeerID              string   `json:"peer_id"`
	Name                string   `json:"name,omitempty"`
	PublicKey           string   `json:"public_key"`
	PresharedKey        string   `json:"preshared_key,omitempty"`
	TunnelIP            string   `json:"tunnel_ip"`
	BridgePort          int      `json:"bridge_port,omitempty"`
	DirectLANEndpoint   string   `json:"direct_lan_endpoint,omitempty"` // direct IP:port on local LAN (preferred over server)
	ServerEndpoint      string   `json:"server_endpoint,omitempty"`     // fallback server/relay WG UDP endpoint
	AllowedIPs          []string `json:"allowed_ips,omitempty"`         // strictly scoped internal tunnel CIDRs (never 0.0.0.0/0 or ::/0)
	PersistentKeepalive int      `json:"persistent_keepalive,omitempty"`
}

type Config struct {
	Backend              string       `json:"backend"` // auto | userspace | kernel
	Imported             bool         `json:"imported,omitempty"`
	DefaultRouteStripped bool         `json:"default_route_stripped,omitempty"`
	PrivateKey           string       `json:"private_key"`
	PublicKey            string       `json:"public_key"`
	LocalTunnelIP        string       `json:"local_tunnel_ip"`
	ListenPort           int          `json:"listen_port"`
	ScopedAllowedIPs     []string     `json:"scoped_allowed_ips,omitempty"`
	Peers                []PeerConfig `json:"peers,omitempty"`
}

func DetectBackend(requested string) string {
	switch requested {
	case BackendUserspace:
		return BackendUserspace
	case BackendKernel:
		return BackendKernel
	}
	if _, err := os.Stat("/sys/module/wireguard"); err == nil {
		if os.Geteuid() == 0 {
			return BackendKernel
		}
		if _, err := exec.LookPath("wg"); err == nil {
			if st, e := exec.Command("id", "-u").Output(); e == nil && string(st) == "0\n" {
				return BackendKernel
			}
		}
	}
	return BackendUserspace
}

func GenerateKeyPair() (privB64, pubB64 string, err error) {
	k, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return "", "", err
	}
	return base64.StdEncoding.EncodeToString(k.Bytes()), base64.StdEncoding.EncodeToString(k.PublicKey().Bytes()), nil
}

func ConfigPath(stateDir string) string {
	return filepath.Join(stateDir, "wireguard", "config.json")
}

func isInternalTunnelPrefix(p netip.Prefix) bool {
	if !p.IsValid() || p.Bits() < 8 {
		return false
	}
	a := p.Addr()
	if a.IsPrivate() {
		return true
	}
	if a.Is4() && netip.MustParsePrefix("100.64.0.0/10").Contains(a) {
		return true
	}
	if a.Is6() && netip.MustParsePrefix("fc00::/7").Contains(a) {
		return true
	}
	return false
}

// ScopeAllowedIPs strips default/internet routes (0.0.0.0/0, ::/0, split-default /1, public CIDRs)
// so WireGuard never routes general device traffic even when running on the kernel module.
func ScopeAllowedIPs(localTunnelIP string, rawAllowed []string) ([]string, bool) {
	stripped := false
	var scoped []string
	seen := map[string]bool{}
	for _, item := range rawAllowed {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		p, err := netip.ParsePrefix(item)
		if err != nil {
			continue
		}
		p = p.Masked()
		if !isInternalTunnelPrefix(p) {
			stripped = true
			continue
		}
		s := p.String()
		if !seen[s] {
			seen[s] = true
			scoped = append(scoped, s)
		}
	}
	if len(scoped) == 0 {
		if lp, err := netip.ParsePrefix(strings.TrimSpace(localTunnelIP)); err == nil {
			bits := lp.Bits()
			if lp.Addr().Is4() && bits > 24 {
				bits = 24
			} else if lp.Addr().Is6() && bits > 64 {
				bits = 64
			}
			sub := netip.PrefixFrom(lp.Addr(), bits).Masked()
			if isInternalTunnelPrefix(sub) {
				scoped = append(scoped, sub.String())
			} else {
				scoped = append(scoped, lp.String())
			}
		}
	}
	return scoped, stripped
}

func decodeX25519Key(b64 string) ([]byte, error) {
	b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil || len(b) != 32 {
		return nil, errors.New("invalid 32-byte WireGuard key")
	}
	return b, nil
}

// ParseConf parses a standard WireGuard .conf file without auto-generating keys
// and strips default/internet routes (0.0.0.0/0, ::/0) and DNS/shell hooks.
func ParseConf(raw string) (Config, error) {
	var cfg Config
	cfg.Backend = BackendAuto
	cfg.Imported = true

	section := ""
	var curPeer *PeerConfig
	var curRawAllowed []string
	flushPeer := func() {
		if curPeer == nil {
			return
		}
		scoped, stripped := ScopeAllowedIPs(cfg.LocalTunnelIP, curRawAllowed)
		if stripped {
			cfg.DefaultRouteStripped = true
		}
		curPeer.AllowedIPs = scoped
		if curPeer.TunnelIP == "" && len(scoped) > 0 {
			if p, err := netip.ParsePrefix(scoped[0]); err == nil && p.Bits() == 32 {
				curPeer.TunnelIP = p.Addr().String()
			}
		}
		cfg.Peers = append(cfg.Peers, *curPeer)
		curPeer = nil
		curRawAllowed = nil
	}

	sc := bufio.NewScanner(strings.NewReader(raw))
	for sc.Scan() {
		line := sc.Text()
		if idx := strings.IndexAny(line, "#;"); idx >= 0 {
			line = line[:idx]
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			hdr := strings.ToLower(strings.TrimSpace(line[1 : len(line)-1]))
			if hdr == "peer" {
				flushPeer()
				curPeer = &PeerConfig{
					PeerID:              fmt.Sprintf("wg-peer-%d", len(cfg.Peers)+1),
					Name:                fmt.Sprintf("WireGuard server %d", len(cfg.Peers)+1),
					BridgePort:          8731,
					PersistentKeepalive: 25,
				}
				section = "peer"
			} else if hdr == "interface" {
				flushPeer()
				section = "interface"
			} else {
				flushPeer()
				section = hdr
			}
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq <= 0 {
			continue
		}
		key := strings.ToLower(strings.TrimSpace(line[:eq]))
		val := strings.TrimSpace(line[eq+1:])
		switch section {
		case "interface":
			switch key {
			case "privatekey":
				rawPriv, err := decodeX25519Key(val)
				if err != nil {
					return Config{}, fmt.Errorf("invalid [Interface] PrivateKey: %w", err)
				}
				k, err := ecdh.X25519().NewPrivateKey(rawPriv)
				if err != nil {
					return Config{}, fmt.Errorf("invalid [Interface] PrivateKey: %w", err)
				}
				cfg.PrivateKey = strings.TrimSpace(val)
				cfg.PublicKey = base64.StdEncoding.EncodeToString(k.PublicKey().Bytes())
			case "address":
				for _, part := range strings.Split(val, ",") {
					part = strings.TrimSpace(part)
					if part == "" {
						continue
					}
					if !strings.Contains(part, "/") {
						if ip, err := netip.ParseAddr(part); err == nil {
							if ip.Is4() {
								part += "/24"
							} else {
								part += "/64"
							}
						}
					}
					if p, err := netip.ParsePrefix(part); err == nil {
						if p.Addr().Is4() || cfg.LocalTunnelIP == "" {
							cfg.LocalTunnelIP = p.String()
							if p.Addr().Is4() {
								break
							}
						}
					}
				}
			case "listenport":
				if port, err := strconv.Atoi(val); err == nil && port > 0 && port <= 65535 {
					cfg.ListenPort = port
				}
			case "dns", "postup", "preup", "postdown", "predown", "table", "fwmark", "saveconfig":
				// Deliberately ignored: never hijack mobile DNS, routing tables, or run shell hooks.
			}
		case "peer":
			if curPeer == nil {
				continue
			}
			switch key {
			case "publickey":
				if _, err := decodeX25519Key(val); err != nil {
					return Config{}, fmt.Errorf("invalid [Peer] PublicKey: %w", err)
				}
				curPeer.PublicKey = val
			case "presharedkey":
				if _, err := decodeX25519Key(val); err != nil {
					return Config{}, fmt.Errorf("invalid [Peer] PresharedKey: %w", err)
				}
				curPeer.PresharedKey = val
			case "endpoint":
				host, port, err := net.SplitHostPort(val)
				if err != nil || host == "" || port == "" {
					return Config{}, fmt.Errorf("invalid [Peer] Endpoint %q", val)
				}
				curPeer.ServerEndpoint = val
				curPeer.Name = host
			case "allowedips":
				for _, part := range strings.Split(val, ",") {
					if part = strings.TrimSpace(part); part != "" {
						curRawAllowed = append(curRawAllowed, part)
					}
				}
			case "persistentkeepalive":
				if sec, err := strconv.Atoi(val); err == nil && sec >= 0 {
					curPeer.PersistentKeepalive = sec
				}
			}
		}
	}
	if err := sc.Err(); err != nil {
		return Config{}, err
	}
	flushPeer()

	if cfg.PrivateKey == "" || cfg.PublicKey == "" {
		return Config{}, errors.New("[Interface] PrivateKey is required in WireGuard .conf")
	}
	if cfg.LocalTunnelIP == "" {
		return Config{}, errors.New("[Interface] Address is required in WireGuard .conf")
	}
	if len(cfg.Peers) == 0 {
		return Config{}, errors.New("at least one [Peer] section is required in WireGuard .conf")
	}
	for i, p := range cfg.Peers {
		if p.PublicKey == "" {
			return Config{}, fmt.Errorf("[Peer] #%d missing PublicKey", i+1)
		}
		if p.ServerEndpoint == "" && p.DirectLANEndpoint == "" {
			return Config{}, fmt.Errorf("[Peer] #%d missing Endpoint", i+1)
		}
		for _, cidr := range p.AllowedIPs {
			cfg.ScopedAllowedIPs = append(cfg.ScopedAllowedIPs, cidr)
		}
	}
	return cfg, nil
}

// ImportConf validates, scopes (stripping 0.0.0.0/0 / ::/0), and saves an imported WireGuard .conf.
func ImportConf(stateDir, raw string) (Config, error) {
	cfg, err := ParseConf(raw)
	if err != nil {
		return Config{}, err
	}
	if err = SaveConfig(stateDir, cfg); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// DeleteConfig removes any saved WireGuard configuration.
func DeleteConfig(stateDir string) error {
	err := os.Remove(ConfigPath(stateDir))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// LoadConfig reads an existing WireGuard configuration without generating one.
func LoadConfig(stateDir string) (Config, error) {
	p := ConfigPath(stateDir)
	data, err := os.ReadFile(p)
	if err != nil {
		return Config{}, ErrNotConfigured
	}
	var cfg Config
	if err = json.Unmarshal(data, &cfg); err != nil || cfg.PrivateKey == "" || cfg.PublicKey == "" || cfg.LocalTunnelIP == "" {
		return Config{}, ErrNotConfigured
	}
	if !cfg.Imported && len(cfg.Peers) == 0 {
		return Config{}, ErrNotConfigured
	}
	if cfg.Backend == "" {
		cfg.Backend = BackendAuto
	}
	if len(cfg.ScopedAllowedIPs) == 0 {
		var all []string
		for i := range cfg.Peers {
			if len(cfg.Peers[i].AllowedIPs) == 0 && cfg.Peers[i].TunnelIP != "" {
				cfg.Peers[i].AllowedIPs = []string{cfg.Peers[i].TunnelIP + "/32"}
			}
			all = append(all, cfg.Peers[i].AllowedIPs...)
		}
		scoped, stripped := ScopeAllowedIPs(cfg.LocalTunnelIP, all)
		cfg.ScopedAllowedIPs = scoped
		if stripped {
			cfg.DefaultRouteStripped = true
		}
	}
	return cfg, nil
}

// LoadOrInitConfig loads a saved config or initializes one when explicitly invoked by tests.
func LoadOrInitConfig(stateDir, tunnelIP string, listenPort int) (Config, error) {
	if cfg, err := LoadConfig(stateDir); err == nil {
		return cfg, nil
	}
	priv, pub, err := GenerateKeyPair()
	if err != nil {
		return Config{}, err
	}
	if tunnelIP == "" {
		tunnelIP = "10.77.0.2/24"
	}
	if listenPort <= 0 {
		listenPort = 51820
	}
	cfg := Config{
		Backend:       BackendAuto,
		PrivateKey:    priv,
		PublicKey:     pub,
		LocalTunnelIP: tunnelIP,
		ListenPort:    listenPort,
	}
	return cfg, SaveConfig(stateDir, cfg)
}

func SaveConfig(stateDir string, cfg Config) error {
	dir := filepath.Join(stateDir, "wireguard")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	tmp := ConfigPath(stateDir) + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, ConfigPath(stateDir))
}

func UpsertPeer(stateDir string, peer PeerConfig) (Config, error) {
	cfg, err := LoadOrInitConfig(stateDir, "", 0)
	if err != nil {
		return cfg, err
	}
	updated := false
	for i := range cfg.Peers {
		if cfg.Peers[i].PeerID == peer.PeerID || (peer.TunnelIP != "" && cfg.Peers[i].TunnelIP == peer.TunnelIP) {
			cfg.Peers[i] = peer
			updated = true
			break
		}
	}
	if !updated {
		cfg.Peers = append(cfg.Peers, peer)
	}
	return cfg, SaveConfig(stateDir, cfg)
}

// Provider routes WireGuard peers directly over same-LAN P2P links when reachable,
// falling back to userspace netstack (`wireguard-go`) or kernel WireGuard module.
type Provider struct {
	StateDir       string
	Control        tailnetipc.Client
	RemoteApproved bool
	BackendMode    string // auto | userspace | kernel
	TunnelOnly     bool   // Verify the configured tunnel independently of ordinary LAN.
}

func (*Provider) ID() string { return "wireguard-v1" }
func (*Provider) Capabilities() transport.Capabilities {
	return transport.Capabilities{Version: 1, Streams: true}
}
func (*Provider) DiscoverCandidates(context.Context) ([]transport.Candidate, error) {
	return nil, errors.New("configure a WireGuard peer or direct LAN candidate first")
}

func (p *Provider) endpointInScopedRoutes(cfg Config, ep string) bool {
	host, _, err := net.SplitHostPort(ep)
	if err != nil {
		return false
	}
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return false
	}
	for _, peer := range cfg.Peers {
		if peer.TunnelIP == host {
			return true
		}
		for _, raw := range peer.AllowedIPs {
			if pre, pe := netip.ParsePrefix(raw); pe == nil && isInternalTunnelPrefix(pre) && pre.Contains(ip) {
				return true
			}
		}
	}
	for _, raw := range cfg.ScopedAllowedIPs {
		if pre, pe := netip.ParsePrefix(raw); pe == nil && isInternalTunnelPrefix(pre) && pre.Contains(ip) {
			return true
		}
	}
	return false
}

func (p *Provider) findPeer(deviceID, endpoint string) (PeerConfig, bool) {
	if p.StateDir == "" {
		return PeerConfig{}, false
	}
	cfg, err := LoadConfig(p.StateDir)
	if err != nil {
		return PeerConfig{}, false
	}
	host, _, _ := net.SplitHostPort(endpoint)
	ip, ipErr := netip.ParseAddr(host)
	for _, peer := range cfg.Peers {
		if (deviceID != "" && peer.PeerID == deviceID) || (host != "" && peer.TunnelIP == host) {
			return peer, true
		}
		if ipErr == nil {
			for _, raw := range peer.AllowedIPs {
				if pre, pe := netip.ParsePrefix(raw); pe == nil && isInternalTunnelPrefix(pre) && pre.Contains(ip) {
					return peer, true
				}
			}
		}
	}
	return PeerConfig{}, false
}

func tryDirectLAN(ctx context.Context, directEndpoint string) (time.Duration, bool) {
	if directEndpoint == "" {
		return 0, false
	}
	d := net.Dialer{Timeout: 400 * time.Millisecond}
	start := time.Now()
	c, err := d.DialContext(ctx, "tcp", directEndpoint)
	if err != nil {
		return 0, false
	}
	_ = c.Close()
	return time.Since(start), true
}

func (p *Provider) Probe(ctx context.Context, c transport.Candidate) (transport.Candidate, error) {
	peer, hasPeer := p.findPeer(c.DeviceID, c.Endpoint)
	if !p.TunnelOnly && hasPeer && peer.DirectLANEndpoint != "" {
		if rtt, ok := tryDirectLAN(ctx, peer.DirectLANEndpoint); ok {
			c.Direct = true
			c.PathKind = "direct-lan"
			c.Endpoint = peer.DirectLANEndpoint
			c.RTT = rtt
			c.Observed = time.Now().UTC()
			c.Cost = transport.NetworkCost{Known: true}
			return c, nil
		}
	}
	backend := DetectBackend(p.BackendMode)
	if backend == BackendKernel {
		cfg, cfgErr := LoadConfig(p.StateDir)
		if cfgErr != nil || !p.endpointInScopedRoutes(cfg, c.Endpoint) {
			return c, errors.New("WireGuard kernel route denied: endpoint is outside app-only scoped tunnel CIDRs")
		}
		d := net.Dialer{Timeout: 2 * time.Second}
		start := time.Now()
		conn, err := d.DialContext(ctx, "tcp", c.Endpoint)
		if err != nil {
			return c, err
		}
		_ = conn.Close()
		c.Direct = true
		c.PathKind = "wireguard-kernel"
		c.RTT = time.Since(start)
		c.Observed = time.Now().UTC()
		c.Cost = transport.NetworkCost{Known: true, Internet: true}
		return c, nil
	}
	if p.Control.Socket != "" {
		v, _, err := p.Control.Exchange(ctx, tailnetipc.Request{Operation: "probe", Target: c.Endpoint})
		if err != nil {
			return c, err
		}
		if v.Path != nil {
			c.Direct = v.Path.Kind == "direct"
			c.PathKind = "wireguard-userspace-" + v.Path.Kind
			c.Relay = v.Path.Relay
			c.RTT = time.Duration(v.Path.RTTSeconds * float64(time.Second))
			c.Observed = v.Path.Observed
		}
		return c, nil
	}
	return c, errors.New("WireGuard userspace tunnel sidecar not running and peer not on LAN")
}

func (p *Provider) Dial(ctx context.Context, c transport.Candidate) (net.Conn, error) {
	peer, hasPeer := p.findPeer(c.DeviceID, c.Endpoint)
	if !p.TunnelOnly && hasPeer && peer.DirectLANEndpoint != "" {
		if _, ok := tryDirectLAN(ctx, peer.DirectLANEndpoint); ok {
			return (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, "tcp", peer.DirectLANEndpoint)
		}
	}
	if !p.RemoteApproved {
		return nil, errors.New("WireGuard server/relay path requires explicit approval when peer is outside LAN")
	}
	backend := DetectBackend(p.BackendMode)
	if backend == BackendKernel {
		cfg, cfgErr := LoadConfig(p.StateDir)
		if cfgErr != nil || !p.endpointInScopedRoutes(cfg, c.Endpoint) {
			return nil, errors.New("WireGuard kernel dial denied: endpoint is outside app-only scoped tunnel CIDRs")
		}
		return (&net.Dialer{Timeout: 8 * time.Second}).DialContext(ctx, "tcp", c.Endpoint)
	}
	if p.Control.Socket == "" {
		return nil, errors.New("WireGuard userspace control socket unavailable")
	}
	_, conn, err := p.Control.Exchange(ctx, tailnetipc.Request{Operation: "stream", Target: c.Endpoint, RemoteApproved: true})
	return conn, err
}

func (*Provider) Listen(context.Context, string) (net.Listener, error) {
	return nil, errors.New("WireGuard tunnel listener is managed by the backend coordinator")
}
func (*Provider) NetworkCost(transport.Candidate) transport.NetworkCost {
	return transport.NetworkCost{Known: true, Internet: true}
}
func (*Provider) Close() error { return nil }
