package storage

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"
)

// LinkOperation journals metadata only: never SSIDs, passphrases or credentials.
type LinkOperation struct {
	ID      string `json:"id"`
	Kind    string `json:"kind"`
	Role    string `json:"role"`
	Stage   string `json:"stage"`
	Updated int64  `json:"updated_utc"`
}

func (s *Store) LinkOperation(ctx context.Context, peer, action, kind, role, id string) (LinkOperation, error) {
	var op LinkOperation
	p, err := s.Peer(peer)
	if err != nil || p.Status != "paired" {
		return op, ErrDenied
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return op, err
	}
	defer tx.Rollback()
	key := "link-operation-v1:" + peer
	var raw string
	err = tx.QueryRowContext(ctx, "SELECT value FROM preferences WHERE key=?", key).Scan(&raw)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return op, err
	}
	if err == nil {
		if err = json.Unmarshal([]byte(raw), &op); err != nil {
			return op, err
		}
	}
	if action == "" {
		return op, tx.Commit()
	}
	switch action {
	case "begin":
		if kind != "hotspot" && kind != "wifi_direct" && kind != "adb_usb" {
			return op, errors.New("unsupported link operation")
		}
		if role != "phone" && role != "laptop" {
			return op, errors.New("invalid link role")
		}
		if op.Stage == "preparing" || op.Stage == "verifying" || op.Stage == "needs_recovery" {
			return op, errors.New("restore the previous incomplete link operation first")
		}
		var b [16]byte
		if _, err = rand.Read(b[:]); err != nil {
			return op, err
		}
		op = LinkOperation{ID: hex.EncodeToString(b[:]), Kind: kind, Role: role, Stage: "preparing"}
	case "verifying", "committed", "needs_recovery", "restored":
		if op.ID == "" || op.ID != id {
			return op, errors.New("stale link operation")
		}
		if op.Stage == "restored" && action != "restored" {
			return op, errors.New("link operation already restored")
		}
		if op.Stage == "committed" && action == "verifying" {
			return op, errors.New("link operation already committed")
		}
		op.Stage = action
	default:
		return op, errors.New("unknown link operation state")
	}
	op.Updated = time.Now().Unix()
	b, _ := json.Marshal(op)
	_, err = tx.ExecContext(ctx, "INSERT INTO preferences(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", key, string(b))
	if err != nil {
		return op, err
	}
	return op, tx.Commit()
}
