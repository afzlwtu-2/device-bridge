package storage

import (
	"context"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

const ActionOutputLimit = 8192

type ActionRequest struct {
	Peer    string `json:"peer,omitempty"`
	Preset  string `json:"preset"`
	ID      string `json:"id"`
	State   string `json:"state"`
	Expires int64  `json:"expires_utc"`
	Output  string `json:"output,omitempty"`
}

var ErrActionBusy = errors.New("an existing request for this action is still open")

func actionRequestKey(peer, preset string) string {
	return "action-request-v1:" + peer + ":" + preset
}

func validActionRequest(peer, preset, id string) bool {
	if len(peer) != 64 || len(id) != 32 || len(preset) == 0 || len(preset) > 48 {
		return false
	}
	if _, err := hex.DecodeString(peer); err != nil {
		return false
	}
	if _, err := hex.DecodeString(id); err != nil || id != strings.ToLower(id) {
		return false
	}
	for _, char := range preset {
		if (char < 'a' || char > 'z') && (char < '0' || char > '9') && char != '-' {
			return false
		}
	}
	return true
}

func (s *Store) ActionRequests(ctx context.Context, peer string) ([]ActionRequest, error) {
	rows, err := s.DB.QueryContext(ctx, "SELECT value FROM preferences WHERE key LIKE ? ORDER BY key", actionRequestKey(peer, "%"))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []ActionRequest{}
	for rows.Next() {
		var raw string
		var record ActionRequest
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(raw), &record); err != nil {
			return nil, err
		}
		if record.Peer != peer {
			continue
		}
		if record.Expires <= time.Now().Unix() {
			record.State = "expired"
		}
		record.Output = ""
		result = append(result, record)
	}
	return result, rows.Err()
}

// ActionRequestState handles idempotent remote requests. An approved request
// is atomically claimed once before an agent computes its result.
func (s *Store) ActionRequestState(ctx context.Context, peer, preset, id string) (ActionRequest, bool, error) {
	var run bool
	record, err := s.changeAction(ctx, peer, preset, id, func(r *ActionRequest, now int64) error {
		if r.ID == id {
			if r.Expires <= now || r.State == "revoked" {
				return ErrDenied
			}
			if r.State == "approved" {
				r.State = "running"
				run = true
			}
			return nil
		}
		if r.ID != "" && r.Expires > now && (r.State == "pending" || r.State == "approved" || r.State == "running") {
			return ErrActionBusy
		}
		*r = ActionRequest{Peer: peer, Preset: preset, ID: id, State: "pending", Expires: now + 300}
		return nil
	})
	return record, run && err == nil, err
}

func (s *Store) ApproveAction(ctx context.Context, peer, preset, id string, ttl time.Duration) (ActionRequest, error) {
	if ttl < time.Second || ttl > 5*time.Minute {
		return ActionRequest{}, errors.New("choose an action approval duration up to five minutes")
	}
	return s.changeAction(ctx, peer, preset, id, func(r *ActionRequest, now int64) error {
		if r.ID != id || r.Expires <= now || r.State != "pending" {
			return ErrDenied
		}
		r.State, r.Expires = "approved", min(r.Expires, now+int64(ttl/time.Second))
		return nil
	})
}

func (s *Store) RevokeAction(ctx context.Context, peer, preset, id string) (ActionRequest, error) {
	return s.changeAction(ctx, peer, preset, id, func(r *ActionRequest, _ int64) error {
		if r.ID != id {
			return ErrDenied
		}
		r.State, r.Output = "revoked", ""
		return nil
	})
}

func (s *Store) CompleteAction(ctx context.Context, peer, preset, id, output string, success bool) (ActionRequest, error) {
	if len(output) > ActionOutputLimit {
		return ActionRequest{}, errors.New("action output exceeds its limit")
	}
	return s.changeAction(ctx, peer, preset, id, func(r *ActionRequest, now int64) error {
		if r.ID != id || r.State != "running" || r.Expires <= now {
			return ErrDenied
		}
		r.State, r.Output = "completed", output
		if !success {
			r.State = "failed"
		}
		return nil
	})
}

func (s *Store) changeAction(ctx context.Context, peer, preset, id string, change func(*ActionRequest, int64) error) (ActionRequest, error) {
	var record ActionRequest
	if !validActionRequest(peer, preset, id) {
		return record, errors.New("invalid action request")
	}
	key := actionRequestKey(peer, preset)
	var previous string
	err := s.DB.QueryRowContext(ctx, "SELECT value FROM preferences WHERE key=?", key).Scan(&previous)
	if err == nil {
		if err := json.Unmarshal([]byte(previous), &record); err != nil {
			return record, err
		}
	} else if !errors.Is(err, sql.ErrNoRows) {
		return record, err
	}
	if err := change(&record, time.Now().Unix()); err != nil {
		return record, err
	}
	raw, err := json.Marshal(record)
	if err != nil {
		return record, err
	}
	result, err := s.DB.ExecContext(ctx, `
		INSERT INTO preferences(key,value)
		SELECT ?,? WHERE EXISTS (SELECT 1 FROM peers WHERE id=? AND status='paired')
		ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE preferences.value=?`,
		key, string(raw), peer, previous)
	if err != nil {
		return record, err
	}
	if count, err := result.RowsAffected(); err != nil || count != 1 {
		return record, errors.Join(ErrDenied, err)
	}
	return record, nil
}
