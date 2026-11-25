package storage

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
)

// SSHAccess is separate from pairing and file grants. Only the local owner can approve it.
type SSHAccess struct {
	Allowed   bool `json:"allowed"`
	Requested bool `json:"requested"`
}

func (s *Store) AgentSSHAccess(ctx context.Context, peer, action string) (SSHAccess, error) {
	var access SSHAccess
	p, err := s.Peer(peer)
	if err != nil || p.Status != "paired" {
		return access, ErrDenied
	}
	aclEnabled, aclAllowed, aclErr := s.CheckPeerACL(ctx, p.ID, "ssh")
	if aclErr != nil {
		return access, aclErr
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return access, err
	}
	defer tx.Rollback()
	var raw string
	err = tx.QueryRowContext(ctx, "SELECT value FROM preferences WHERE key=?", "agent-ssh-access-v1:"+peer).Scan(&raw)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return access, err
	}
	if err == nil {
		if err = json.Unmarshal([]byte(raw), &access); err != nil {
			return access, err
		}
	}
	switch action {
	case "":
	case "allow":
		access = SSHAccess{Allowed: true}
	case "deny":
		access = SSHAccess{}
	case "request":
		if !access.Allowed && !(aclEnabled && aclAllowed) {
			access.Requested = true
		}
	default:
		return access, errors.New("invalid SSH access action")
	}
	if action != "" {
		b, _ := json.Marshal(access)
		_, err = tx.ExecContext(ctx, "INSERT INTO preferences(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", "agent-ssh-access-v1:"+peer, string(b))
		if err != nil {
			return access, err
		}
	}
	if err = tx.Commit(); err != nil {
		return access, err
	}
	if aclEnabled {
		access.Allowed = aclAllowed
		if aclAllowed {
			access.Requested = false
		}
	}
	return access, nil
}
