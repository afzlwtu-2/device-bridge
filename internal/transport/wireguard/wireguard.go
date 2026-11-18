// Package wireguard implements WireGuard transport discovery, direct-on-LAN preference,
// userspace (non-rooted netstack) and kernel (rooted module) backend selection.
package wireguard

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"devicebridge/internal/tailnetipc"
	"devicebridge/internal/transport"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

const (
	BackendAuto      = "auto"
	BackendUserspace = "userspace"
	BackendKernel    = "kernel"
)

type PeerConfig struct {
	PeerID            string `json:"peer_id"`
	Name              string `json:"name,omitempty"`
	PublicKey         string `json:"public_key"`
	TunnelIP          string `json:"tunnel_ip"`
	BridgePort        int    `json:"bridge_port,omitempty"`
	DirectLANEndpoint string `json:"direct_lan_endpoint,omitempty"` // direct IP:port on local LAN (preferred over server)
	ServerEndpoint    string `json:"server_endpoint,omitempty"`     // fallback server/relay WG UDP endpoint
}

type Config struct {
	Backend       string       `json:"backend"` // auto | userspace | kernel
	PrivateKey    string       `json:"private_key"`
	PublicKey     string       `json:"public_key"`
	LocalTunnelIP string       `json:"local_tunnel_ip"`
	ListenPort    int          `json:"listen_port"`
	Peers         []PeerConfig `json:"peers,omitempty"`
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

func LoadOrInitConfig(stateDir, tunnelIP string, listenPort int) (Config, error) {
	p := ConfigPath(stateDir)
	if data, err := os.ReadFile(p); err == nil {
		var cfg Config
		if e := json.Unmarshal(data, &cfg); e == nil && cfg.PublicKey != "" {
			if cfg.Backend == "" {
				cfg.Backend = BackendAuto
			}
			return cfg, nil
		}
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
}

func (*Provider) ID() string { return "wireguard-v1" }
func (*Provider) Capabilities() transport.Capabilities {
	return transport.Capabilities{Version: 1, Streams: true}
}
func (*Provider) DiscoverCandidates(context.Context) ([]transport.Candidate, error) {
	return nil, errors.New("configure a WireGuard peer or direct LAN candidate first")
}

func (p *Provider) findPeer(deviceID, endpoint string) (PeerConfig, bool) {
	if p.StateDir == "" {
		return PeerConfig{}, false
	}
	cfg, err := LoadOrInitConfig(p.StateDir, "", 0)
	if err != nil {
		return PeerConfig{}, false
	}
	host, _, _ := net.SplitHostPort(endpoint)
	for _, peer := range cfg.Peers {
		if (deviceID != "" && peer.PeerID == deviceID) || (host != "" && peer.TunnelIP == host) {
			return peer, true
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
	if hasPeer && peer.DirectLANEndpoint != "" {
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
	if hasPeer && peer.DirectLANEndpoint != "" {
		if _, ok := tryDirectLAN(ctx, peer.DirectLANEndpoint); ok {
			return (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, "tcp", peer.DirectLANEndpoint)
		}
	}
	if !p.RemoteApproved {
		return nil, errors.New("WireGuard server/relay path requires explicit approval when peer is outside LAN")
	}
	backend := DetectBackend(p.BackendMode)
	if backend == BackendKernel {
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
