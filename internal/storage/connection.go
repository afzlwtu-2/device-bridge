package storage

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"strings"
	"time"
)

type Connection struct {
	Transport          string   `json:"transport"`
	Endpoint           string   `json:"endpoint,omitempty"`
	RemoteApproved     bool     `json:"remote_approved"`
	FallbackApproved   bool     `json:"fallback_approved"`
	FallbackTransports []string `json:"fallback_transports,omitempty"`
	AdbEndpoint        string   `json:"adb_endpoint,omitempty"`
	SshEndpoint        string   `json:"ssh_endpoint,omitempty"`
	WireGuardEndpoint  string   `json:"wireguard_endpoint,omitempty"`
	LastMiBPerSecond   float64  `json:"last_mib_per_second,omitempty"`
	LastRateTransport  string   `json:"last_rate_transport,omitempty"`
	LastRateObservedAt int64    `json:"last_rate_observed_at,omitempty"`
}

type rateRecord struct {
	MiBPerSecond float64 `json:"mib_per_second"`
	Transport    string  `json:"transport"`
	ObservedAt   int64   `json:"observed_at"`
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

func (s *Store) Connection(peer string, update *Connection) (Connection, error) {
	var out Connection
	out.Transport = "lan"
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
		if update.Transport == "tailnet" && (!validTailnetEndpoint(update.Endpoint) || !update.RemoteApproved) {
			return out, errors.New("tailnet endpoint and explicit internet/relay consent required")
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
		if update.WireGuardEndpoint != "" && !validWireGuardEndpoint(update.WireGuardEndpoint) {
			return out, errors.New("invalid fallback WireGuard endpoint")
		}
		if update.Endpoint != "" && update.Transport == "tailnet" && !validTailnetEndpoint(update.Endpoint) {
			return out, errors.New("invalid tailnet endpoint")
		}
		cleanedFallback := []string{}
		for _, t := range update.FallbackTransports {
			t = strings.TrimSpace(t)
			switch t {
			case "lan", "adb", "ssh":
				cleanedFallback = append(cleanedFallback, t)
			case "wireguard":
				if update.WireGuardEndpoint != "" || (update.Transport == "wireguard" && validWireGuardEndpoint(update.Endpoint)) {
					cleanedFallback = append(cleanedFallback, t)
				}
			case "tailnet":
				if !update.RemoteApproved || !validTailnetEndpoint(update.Endpoint) {
					return out, errors.New("tailnet fallback requires explicit remote approval and tailnet endpoint")
				}
				cleanedFallback = append(cleanedFallback, t)
			default:
				return out, errors.New("unsupported fallback transport")
			}
		}
		stored := Connection{
			Transport:          update.Transport,
			Endpoint:           update.Endpoint,
			RemoteApproved:     update.RemoteApproved,
			FallbackApproved:   update.FallbackApproved,
			FallbackTransports: cleanedFallback,
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
		if e := json.Unmarshal([]byte(raw), &out); e != nil {
			return out, e
		}
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
	return out, nil
}

type PeerAction struct {
	ID         string `json:"id"`
	Label      string `json:"label"`
	Kind       string `json:"kind"` // "command" | "toggle"
	Command    string `json:"command"`
	OffCommand string `json:"off_command,omitempty"`
	Active     bool   `json:"active,omitempty"`
	Host       string `json:"host,omitempty"`
	Port       int    `json:"port,omitempty"`
	User       string `json:"user,omitempty"`
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
