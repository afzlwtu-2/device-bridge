package storage

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
)

// SSHHost is persistent trust metadata. Session credentials are never stored here.
type SSHHost struct {
	AgentPeerID    string `json:"agent_peer_id,omitempty"`
	Transport      string `json:"transport,omitempty"`
	RemoteApproved bool   `json:"remote_approved,omitempty"`
	Version        int    `json:"version"`
	ID             string `json:"id"`
	Name           string `json:"name"`
	Host           string `json:"host"`
	Port           int    `json:"port"`
	User           string `json:"user"`
	Fingerprint    string `json:"expected_host_key"`
}

func validSSHHostID(id string) bool {
	b, err := hex.DecodeString(id)
	return err == nil && len(b) == 16
}
func (s *Store) SSHHosts(ctx context.Context) ([]SSHHost, error) {
	rows, err := s.DB.QueryContext(ctx, "SELECT value FROM preferences WHERE key GLOB 'ssh-host-v1:*' ORDER BY key")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	hosts := []SSHHost{}
	for rows.Next() {
		var raw string
		var h SSHHost
		if err = rows.Scan(&raw); err != nil {
			return nil, err
		}
		if err = json.Unmarshal([]byte(raw), &h); err != nil {
			return nil, err
		}
		hosts = append(hosts, h)
	}
	return hosts, rows.Err()
}
func (s *Store) SSHHost(ctx context.Context, id string) (SSHHost, error) {
	var h SSHHost
	if !validSSHHostID(id) {
		return h, ErrDenied
	}
	var raw string
	err := s.DB.QueryRowContext(ctx, "SELECT value FROM preferences WHERE key=?", "ssh-host-v1:"+id).Scan(&raw)
	if err != nil {
		return h, err
	}
	err = json.Unmarshal([]byte(raw), &h)
	return h, err
}
func (s *Store) SaveSSHHost(ctx context.Context, h SSHHost) (SSHHost, error) {
	if h.Transport != "" && h.Transport != "auto" && h.Transport != "direct" && h.Transport != "tailnet" && h.Transport != "wireguard" && h.Transport != "adb" {
		return h, errors.New("unsupported SSH transport")
	}
	if (h.Transport == "tailnet" || h.Transport == "wireguard") && !h.RemoteApproved {
		return h, errors.New("approve remote SSH transport first")
	}
	if h.Version != 1 || h.Host == "" || len(h.Host) > 253 || h.User == "" || len(h.User) > 128 || h.Port < 1 || h.Port > 65535 || !strings.HasPrefix(h.Fingerprint, "SHA256:") || len(h.Name) > 256 {
		return h, errors.New("invalid SSH host")
	}
	if h.ID == "" {
		var b [16]byte
		if _, err := rand.Read(b[:]); err != nil {
			return h, err
		}
		h.ID = hex.EncodeToString(b[:])
	} else if !validSSHHostID(h.ID) {
		return h, ErrDenied
	}
	raw, err := json.Marshal(h)
	if err != nil {
		return h, err
	}
	_, err = s.DB.ExecContext(ctx, "INSERT INTO preferences(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", "ssh-host-v1:"+h.ID, string(raw))
	return h, err
}
func (s *Store) RemoveSSHHost(ctx context.Context, id string) error {
	if !validSSHHostID(id) {
		return ErrDenied
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "DELETE FROM preferences WHERE key=?", "ssh-host-v1:"+id); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "UPDATE preferences SET value='auto' WHERE key GLOB 'ssh-method-v1:*' AND value=?", "ssh:"+id); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) AssociateSSHHost(ctx context.Context, id, peer string) (SSHHost, error) {
	h, err := s.SSHHost(ctx, id)
	if err != nil {
		return h, err
	}
	if peer != "" {
		p, err := s.Peer(peer)
		if err != nil || p.Status != "paired" {
			return h, ErrDenied
		}
	}
	h.AgentPeerID = peer
	return s.SaveSSHHost(ctx, h)
}

// PeerSSHMethod is an explicit account association; never infer it from an address.
func (s *Store) PeerSSHMethod(ctx context.Context, peer string, update *string) (string, error) {
	p, err := s.Peer(peer)
	if err != nil || p.Status != "paired" {
		return "", ErrDenied
	}
	key := "ssh-method-v1:" + peer
	if update != nil {
		if *update != "auto" && *update != "agent" {
			if !strings.HasPrefix(*update, "ssh:") {
				return "", errors.New("invalid SSH method")
			}
			h, err := s.SSHHost(ctx, strings.TrimPrefix(*update, "ssh:"))
			if err != nil {
				return "", err
			}
			if h.AgentPeerID != peer {
				return "", errors.New("associate the verified SSH host with this device first")
			}
		}
		_, err = s.DB.ExecContext(ctx, "INSERT INTO preferences(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", key, *update)
		return *update, err
	}
	var method string
	err = s.DB.QueryRowContext(ctx, "SELECT value FROM preferences WHERE key=?", key).Scan(&method)
	if errors.Is(err, sql.ErrNoRows) {
		return "auto", nil
	}
	return method, err
}
