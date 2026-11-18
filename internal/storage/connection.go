package storage

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"time"
)

type Connection struct {
	Transport          string  `json:"transport"`
	Endpoint           string  `json:"endpoint,omitempty"`
	RemoteApproved     bool    `json:"remote_approved"`
	LastMiBPerSecond   float64 `json:"last_mib_per_second,omitempty"`
	LastRateTransport  string  `json:"last_rate_transport,omitempty"`
	LastRateObservedAt int64   `json:"last_rate_observed_at,omitempty"`
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

func (s *Store) Connection(peer string, update *Connection) (Connection, error) {
	var out Connection
	out.Transport = "lan"
	p, err := s.Peer(peer)
	if err != nil || p.Status == "revoked" {
		return out, ErrDenied
	}
	if update != nil {
		if update.Transport != "lan" && update.Transport != "tailnet" {
			return out, errors.New("unsupported connection choice")
		}
		if update.Transport == "tailnet" {
			host, port, e := net.SplitHostPort(update.Endpoint)
			ip, ie := netip.ParseAddr(host)
			if e != nil || ie != nil || port != "8731" || (!netip.MustParsePrefix("100.64.0.0/10").Contains(ip) && !netip.MustParsePrefix("fd7a:115c:a1e0::/48").Contains(ip)) || !update.RemoteApproved {
				return out, errors.New("tailnet endpoint and explicit internet/relay consent required")
			}
		}
		stored := Connection{
			Transport:      update.Transport,
			Endpoint:       update.Endpoint,
			RemoteApproved: update.RemoteApproved,
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
