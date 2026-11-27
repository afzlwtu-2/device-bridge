package storage

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"slices"
	"strings"
	"time"
)

type Connection struct {
	Transport          string   `json:"transport"`
	PreferredTransport string   `json:"preferred_transport,omitempty"`
	PreferredLink      string   `json:"preferred_link,omitempty"`
	ActiveLink         string   `json:"active_link,omitempty"`
	Endpoint           string   `json:"endpoint,omitempty"`
	RemoteApproved     bool     `json:"remote_approved"`
	FallbackApproved   bool     `json:"fallback_approved"`
	FallbackTransports []string `json:"fallback_transports"`
	LanEndpoint        string   `json:"lan_endpoint,omitempty"`
	TailnetEndpoint    string   `json:"tailnet_endpoint,omitempty"`
	AdbEndpoint        string   `json:"adb_endpoint,omitempty"`
	SshEndpoint        string   `json:"ssh_endpoint,omitempty"`
	WireGuardEndpoint  string   `json:"wireguard_endpoint,omitempty"`
	LastMiBPerSecond   float64  `json:"last_mib_per_second,omitempty"`
	LastRateTransport  string   `json:"last_rate_transport,omitempty"`
	LastRateObservedAt int64    `json:"last_rate_observed_at,omitempty"`
	LastHandshakeAt    int64    `json:"last_handshake_at,omitempty"`
}

type rateRecord struct {
	MiBPerSecond float64 `json:"mib_per_second"`
	Transport    string  `json:"transport"`
	ObservedAt   int64   `json:"observed_at"`
}

// RecordHandshake records a successful authenticated connection without changing route preferences.
func (s *Store) RecordHandshake(peer string, at time.Time) {
	_, _ = s.DB.Exec(`
		INSERT INTO preferences(key,value)
		SELECT ?, ? WHERE EXISTS (SELECT 1 FROM peers WHERE id=? AND status='paired')
		ON CONFLICT(key) DO UPDATE SET value=excluded.value
		WHERE CAST(excluded.value AS INTEGER) > CAST(preferences.value AS INTEGER)
	`, "handshake."+peer, at.Unix(), peer)
}

func (s *Store) RecordRate(peer, transportID string, mibPerSecond float64) error {
	if mibPerSecond <= 0 {
		return nil
	}
	b, err := json.Marshal(rateRecord{
		MiBPerSecond: mibPerSecond,
		Transport:    transportID,
		ObservedAt:   time.Now().Unix(),
	})
	if err != nil {
		return err
	}
	_, err = s.DB.Exec("INSERT INTO preferences(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", "rate."+peer, string(b))
	return err
}

func validLoopbackEndpoint(ep string) bool {
	if ep == "" {
		return true
	}
	host, port, err := net.SplitHostPort(ep)
	if err != nil || port == "" {
		return false
	}
	ip, err := netip.ParseAddr(host)
	return err == nil && ip.IsLoopback()
}

func validLanEndpoint(ep string) bool {
	if ep == "" {
		return true
	}
	host, port, err := net.SplitHostPort(ep)
	if err != nil || port == "" {
		return false
	}
	ip, ie := netip.ParseAddr(host)
	return ie == nil && ip.Is4() && ip.IsPrivate()
}

func validTailnetEndpoint(ep string) bool {
	host, port, err := net.SplitHostPort(ep)
	ip, ie := netip.ParseAddr(host)
	if err != nil || ie != nil || port != "8731" {
		return false
	}
	return netip.MustParsePrefix("100.64.0.0/10").Contains(ip) || netip.MustParsePrefix("fd7a:115c:a1e0::/48").Contains(ip)
}

func validWireGuardEndpoint(ep string) bool {
	if ep == "" {
		return false
	}
	host, port, err := net.SplitHostPort(ep)
	if err != nil || port == "" {
		return false
	}
	ip, ie := netip.ParseAddr(host)
	return ie == nil && (ip.IsPrivate() || ip.IsLoopback() || netip.MustParsePrefix("100.64.0.0/10").Contains(ip) || netip.MustParsePrefix("fd00::/8").Contains(ip))
}

// RecordVerifiedEndpoint remembers an authenticated automatic route without
// changing the user's preference, active route or bulk transfer consent.
func (s *Store) RecordVerifiedEndpoint(peer, transport, endpoint string) error {
	return s.recordEndpoint(peer, transport, endpoint, "paired")
}

// RecordPairingEndpoint retains the TLS-verified route for an outbound
// request while the other device is waiting for approval.
func (s *Store) RecordPairingEndpoint(peer, transport, endpoint string) error {
	return s.recordEndpoint(peer, transport, endpoint, "outbound")
}

func (s *Store) recordEndpoint(peer, transport, endpoint, status string) error {
	var field string
	switch {
	case transport == "lan" && endpoint != "" && validLanEndpoint(endpoint):
		field = "lan_endpoint"
	case transport == "tailnet" && validTailnetEndpoint(endpoint):
		field = "tailnet_endpoint"
	case transport == "wireguard" && validWireGuardEndpoint(endpoint):
		field = "wireguard_endpoint"
	default:
		return nil
	}
	_, err := s.DB.Exec(`
		INSERT INTO preferences(key,value)
		SELECT ?, json_object('transport','lan','preferred_transport','auto','fallback_approved',json('true'),?,?)
		WHERE EXISTS (SELECT 1 FROM peers WHERE id=? AND status=?)
		ON CONFLICT(key) DO UPDATE SET value=json_set(preferences.value,?,?)
		WHERE COALESCE(json_extract(preferences.value,?), '') != ?
	`, "connection."+peer, field, endpoint, peer, status, "$."+field, endpoint, "$."+field, endpoint)
	return err
}

func (s *Store) Connection(peer string, update *Connection) (Connection, error) {
	var out Connection
	out.Transport, out.PreferredTransport = "lan", "auto"
	out.FallbackApproved = true
	p, err := s.Peer(peer)
	if err != nil || p.Status == "revoked" {
		return out, ErrDenied
	}
	if update != nil {
		switch update.Transport {
		case "lan", "tailnet", "wireguard", "adb", "ssh":
		default:
			return out, errors.New("unsupported connection choice")
		}
		preferred := update.PreferredTransport
		if preferred == "" {
			preferred = update.Transport
		}
		switch preferred {
		case "auto", "lan", "tailnet", "wireguard", "adb", "ssh", "hotspot", "wifi_direct":
		default:
			return out, errors.New("unsupported preferred connection")
		}
		switch update.PreferredLink {
		case "", "auto", "wifi", "ethernet", "usb_net", "hotspot", "wifi_direct":
		default:
			return out, errors.New("unsupported preferred link")
		}
		if update.ActiveLink != "" &&
			(update.Transport != "lan" || (update.ActiveLink != "hotspot" && update.ActiveLink != "wifi_direct")) {
			return out, errors.New("invalid active direct link")
		}
		if update.Transport == "tailnet" && update.Endpoint == "" && update.TailnetEndpoint != "" {
			update.Endpoint = update.TailnetEndpoint
		}
		if update.Transport == "tailnet" && !validTailnetEndpoint(update.Endpoint) {
			return out, errors.New("valid tailnet endpoint required")
		}
		if update.Transport == "wireguard" && !validWireGuardEndpoint(update.Endpoint) {
			return out, errors.New("wireguard requires a private/tunnel endpoint")
		}
		if (update.Transport == "adb" || update.Transport == "ssh") && (update.Endpoint == "" || !validLoopbackEndpoint(update.Endpoint)) {
			return out, errors.New("ADB/SSH tunnel requires an explicit 127.0.0.1:port endpoint")
		}
		if !validLoopbackEndpoint(update.AdbEndpoint) || !validLoopbackEndpoint(update.SshEndpoint) {
			return out, errors.New("fallback ADB/SSH tunnel must use 127.0.0.1:port")
		}
		if !validLanEndpoint(update.LanEndpoint) {
			return out, errors.New("invalid LAN endpoint")
		}
		if update.TailnetEndpoint != "" && !validTailnetEndpoint(update.TailnetEndpoint) {
			return out, errors.New("invalid tailnet endpoint")
		}
		if update.WireGuardEndpoint != "" && !validWireGuardEndpoint(update.WireGuardEndpoint) {
			return out, errors.New("invalid fallback WireGuard endpoint")
		}
		if update.Endpoint != "" && update.Transport == "tailnet" && !validTailnetEndpoint(update.Endpoint) {
			return out, errors.New("invalid tailnet endpoint")
		}
		tailnetEp := update.TailnetEndpoint
		if tailnetEp == "" && update.Transport == "tailnet" {
			tailnetEp = update.Endpoint
		}
		var cleanedFallback []string
		if update.FallbackTransports != nil {
			cleanedFallback = []string{}
		}
		for _, t := range update.FallbackTransports {
			t = strings.TrimSpace(t)
			switch t {
			case "lan":
				cleanedFallback = append(cleanedFallback, t)
			case "adb", "ssh":
				// Older clients stored manual routes in the fallback list.
			case "wireguard":
				if update.WireGuardEndpoint != "" || (update.Transport == "wireguard" && validWireGuardEndpoint(update.Endpoint)) {
					cleanedFallback = append(cleanedFallback, t)
				}
			case "tailnet":
				if validTailnetEndpoint(tailnetEp) {
					cleanedFallback = append(cleanedFallback, t)
				}
			default:
				return out, errors.New("unsupported fallback transport")
			}
		}
		stored := Connection{
			Transport:          update.Transport,
			PreferredTransport: preferred,
			PreferredLink:      update.PreferredLink,
			ActiveLink:         update.ActiveLink,
			Endpoint:           update.Endpoint,
			RemoteApproved:     update.RemoteApproved,
			FallbackApproved:   update.FallbackApproved,
			FallbackTransports: cleanedFallback,
			LanEndpoint:        update.LanEndpoint,
			TailnetEndpoint:    tailnetEp,
			AdbEndpoint:        update.AdbEndpoint,
			SshEndpoint:        update.SshEndpoint,
			WireGuardEndpoint:  update.WireGuardEndpoint,
		}
		b, e := json.Marshal(stored)
		if e != nil {
			return out, e
		}
		if _, e = s.DB.Exec("INSERT INTO preferences(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", "connection."+peer, string(b)); e != nil {
			return out, e
		}
	}
	var raw string
	err = s.DB.QueryRow("SELECT value FROM preferences WHERE key=?", "connection."+peer).Scan(&raw)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return out, err
	}
	if err == nil {
		out.PreferredTransport = ""
		if e := json.Unmarshal([]byte(raw), &out); e != nil {
			return out, e
		}
		if out.PreferredTransport == "" {
			out.PreferredTransport = out.Transport
		}
		out.FallbackTransports = slices.DeleteFunc(out.FallbackTransports, func(t string) bool {
			return t == "adb" || t == "ssh"
		})
	}
	var rateRaw string
	if e := s.DB.QueryRow("SELECT value FROM preferences WHERE key=?", "rate."+peer).Scan(&rateRaw); e == nil {
		var r rateRecord
		if json.Unmarshal([]byte(rateRaw), &r) == nil {
			out.LastMiBPerSecond = r.MiBPerSecond
			out.LastRateTransport = r.Transport
			out.LastRateObservedAt = r.ObservedAt
		}
	}
	_ = s.DB.QueryRow("SELECT value FROM preferences WHERE key=?", "handshake."+peer).Scan(&out.LastHandshakeAt)
	return out, nil
}

type PeerAction struct {
	ID         string `json:"id"`
	Label      string `json:"label"`
	Kind       string `json:"kind"` // "command" | "toggle"
	Command    string `json:"command"`
	OffCommand string `json:"off_command,omitempty"`
	Active     bool   `json:"active,omitempty"`
	AsRoot     bool   `json:"as_root,omitempty"`
	Host       string `json:"host,omitempty"`
	Port       int    `json:"port,omitempty"`
	User       string `json:"user,omitempty"`
}

// PeerSSHProfile persists user-supplied non-secret SSH metadata per machine.
// Passwords/passphrases are never persisted; Tailscale SSH stores username/host only (no private key).
type PeerSSHProfile struct {
	Host            string `json:"host,omitempty"`
	Port            int    `json:"port,omitempty"`
	User            string `json:"user,omitempty"`
	ExpectedHostKey string `json:"expected_host_key,omitempty"`
	ViaTailnet      bool   `json:"via_tailnet,omitempty"`
	PrivateKeyPEM   string `json:"private_key_pem,omitempty"`
}

func (s *Store) PeerActions(peer string, update []PeerAction, save bool) ([]PeerAction, error) {
	if _, err := s.Peer(peer); err != nil {
		return nil, ErrDenied
	}
	if save {
		cleaned := make([]PeerAction, 0, len(update))
		for _, a := range update {
			label := strings.TrimSpace(a.Label)
			cmd := strings.TrimSpace(a.Command)
			if a.ID == "" || label == "" || cmd == "" {
				return nil, errors.New("action id, label, and command required")
			}
			if a.Kind != "command" && a.Kind != "toggle" {
				return nil, errors.New("unsupported action kind")
			}
			if a.Kind == "toggle" && strings.TrimSpace(a.OffCommand) == "" {
				return nil, errors.New("toggle requires off_command")
			}
			cleaned = append(cleaned, PeerAction{
				ID:         a.ID,
				Label:      label,
				Kind:       a.Kind,
				Command:    cmd,
				OffCommand: strings.TrimSpace(a.OffCommand),
				Active:     a.Active,
				AsRoot:     a.AsRoot,
				Host:       strings.TrimSpace(a.Host),
				Port:       a.Port,
				User:       strings.TrimSpace(a.User),
			})
		}
		b, err := json.Marshal(cleaned)
		if err != nil {
			return nil, err
		}
		if _, err = s.DB.Exec("INSERT INTO preferences(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", "actions."+peer, string(b)); err != nil {
			return nil, err
		}
		return cleaned, nil
	}
	var raw string
	err := s.DB.QueryRow("SELECT value FROM preferences WHERE key=?", "actions."+peer).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return []PeerAction{}, nil
	}
	if err != nil {
		return nil, err
	}
	var out []PeerAction
	if err = json.Unmarshal([]byte(raw), &out); err != nil {
		return nil, err
	}
	if out == nil {
		out = []PeerAction{}
	}
	return out, nil
}

func (s *Store) sshProfileByPrefKey(prefKey string, update *PeerSSHProfile) (PeerSSHProfile, error) {
	if update != nil {
		cleanHost := strings.TrimSpace(update.Host)
		port := update.Port
		if port <= 0 {
			port = 22
		}
		isTailnet := update.ViaTailnet || strings.HasPrefix(cleanHost, "100.") || strings.HasSuffix(cleanHost, ".ts.net")
		stored := PeerSSHProfile{
			Host:            cleanHost,
			Port:            port,
			User:            strings.TrimSpace(update.User),
			ExpectedHostKey: strings.TrimSpace(update.ExpectedHostKey),
			ViaTailnet:      isTailnet,
		}
		b, err := json.Marshal(stored)
		if err != nil {
			return PeerSSHProfile{}, err
		}
		if _, err = s.DB.Exec("INSERT INTO preferences(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", prefKey, string(b)); err != nil {
			return PeerSSHProfile{}, err
		}
		return stored, nil
	}
	var raw string
	err := s.DB.QueryRow("SELECT value FROM preferences WHERE key=?", prefKey).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return PeerSSHProfile{}, nil
	}
	if err != nil {
		return PeerSSHProfile{}, err
	}
	var out PeerSSHProfile
	if err = json.Unmarshal([]byte(raw), &out); err != nil {
		return PeerSSHProfile{}, err
	}
	out.PrivateKeyPEM = ""
	return out, nil
}

// PeerSSH reads or saves per-peer SSH connection metadata (username & optional non-Tailscale key).
func (s *Store) PeerSSH(peer string, update *PeerSSHProfile) (PeerSSHProfile, error) {
	if _, err := s.Peer(peer); err != nil {
		return PeerSSHProfile{}, ErrDenied
	}
	return s.sshProfileByPrefKey("ssh."+peer, update)
}

// HostSSH reads or saves per-host SSH connection metadata (for setup/bootstrap reuse before pairing).
func (s *Store) HostSSH(host string, update *PeerSSHProfile) (PeerSSHProfile, error) {
	clean := strings.ToLower(strings.TrimSpace(host))
	if clean == "" {
		return PeerSSHProfile{}, nil
	}
	return s.sshProfileByPrefKey("ssh.host."+clean, update)
}
