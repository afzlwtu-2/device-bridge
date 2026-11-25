package storage

import (
	"context"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"
)

// LinkLease survives the control connection and contains no network credentials.
// There is one physical-network operation per device, regardless of requester.
type LinkLease struct {
	ID       string `json:"operation_id"`
	Peer     string `json:"peer_id"`
	Stage    string `json:"stage"`
	Deadline int64  `json:"deadline_utc"`
}

const linkLeaseKey = "remote-link-lease-v1"

func (s *Store) LinkLease(ctx context.Context) (LinkLease, error) {
	var op LinkLease
	var raw string
	err := s.DB.QueryRowContext(ctx, "SELECT value FROM preferences WHERE key=?", linkLeaseKey).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return op, nil
	}
	if err != nil {
		return op, err
	}
	err = json.Unmarshal([]byte(raw), &op)
	return op, err
}
func (s *Store) ChangeLinkLease(ctx context.Context, peer, id, action string, ttl int) (LinkLease, error) {
	var op LinkLease
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return op, err
	}
	defer tx.Rollback()
	var raw string
	err = tx.QueryRowContext(ctx, "SELECT value FROM preferences WHERE key=?", linkLeaseKey).Scan(&raw)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return op, err
	}
	if err == nil {
		if err = json.Unmarshal([]byte(raw), &op); err != nil {
			return op, err
		}
	}
	now := time.Now().Unix()
	switch action {
	case "begin":
		b, err := hex.DecodeString(id)
		if err != nil || len(b) != 16 || ttl < 15 || ttl > 180 {
			return op, errors.New("invalid link lease")
		}
		if op.Stage == "preparing" || op.Stage == "restoring" || op.Stage == "needs_recovery" || op.Stage == "committed" {
			return op, errors.New("another network operation requires commit or recovery")
		}
		op = LinkLease{ID: id, Peer: peer, Stage: "preparing", Deadline: now + int64(ttl)}
	case "commit":
		if op.ID != id || op.Peer != peer {
			return op, errors.New("link operation is not owned by this peer")
		}
		if op.Stage == "committed" {
			return op, tx.Commit()
		}
		if op.Stage != "preparing" || op.Deadline <= now {
			return op, errors.New("link operation expired before commit")
		}
		op.Stage = "committed"
	case "claim-expired":
		if op.ID == "" || op.Stage != "preparing" || op.Deadline > now {
			return op, errors.New("no expired link lease")
		}
		op.Stage = "restoring"
	case "restored", "needs_recovery":
		if op.ID == "" || op.ID != id || op.Peer != peer {
			return op, errors.New("link operation ownership mismatch")
		}
		op.Stage = action
	default:
		return op, errors.New("unknown link lease action")
	}
	b, err := json.Marshal(op)
	if err != nil {
		return op, err
	}
	_, err = tx.ExecContext(ctx, "INSERT INTO preferences(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", linkLeaseKey, string(b))
	if err != nil {
		return op, err
	}
	return op, tx.Commit()
}
