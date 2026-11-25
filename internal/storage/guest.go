package storage

import (
	"context"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"
)

type GuestGrant struct {
	Transport      string `json:"transport,omitempty"`
	RemoteApproved bool   `json:"remote_approved,omitempty"`
	ID             string `json:"id"`
	Host           string `json:"host"`
	Port           int    `json:"port"`
	User           string `json:"user"`
	Fingerprint    string `json:"expected_host_key"`
	Root           string `json:"root"`
	Expires        int64  `json:"expires_utc"`
	Terminal       string `json:"terminal,omitempty"`
	TerminalLease  string `json:"terminal_lease,omitempty"`
}

const guestPrefix = "guest-sftp-v1:"

func guestKey(id string) (string, error) {
	if _, err := hex.DecodeString(id); err != nil || len(id) != 32 {
		return "", errors.New("invalid guest session ID")
	}
	return guestPrefix + id, nil
}

func (s *Store) SaveGuest(ctx context.Context, grant GuestGrant) error {
	key, err := guestKey(grant.ID)
	if err != nil {
		return err
	}
	now := time.Now()
	if grant.Expires <= now.Unix() || grant.Expires > now.Add(10*time.Minute).Unix() {
		return errors.New("invalid guest session expiry")
	}
	raw, err := json.Marshal(grant)
	if err != nil {
		return err
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx,
		"DELETE FROM preferences WHERE key GLOB ? AND json_extract(value,'$.expires_utc')<=?",
		guestPrefix+"*", now.Unix()); err != nil {
		return err
	}
	var count int
	if err := tx.QueryRowContext(ctx, "SELECT count(*) FROM preferences WHERE key GLOB ?", guestPrefix+"*").Scan(&count); err != nil {
		return err
	}
	if count >= 8 {
		return errors.New("close an open guest session before creating another")
	}
	if _, err := tx.ExecContext(ctx, "INSERT INTO preferences(key,value) VALUES(?,?)", key, string(raw)); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) Guest(ctx context.Context, id string) (GuestGrant, error) {
	var grant GuestGrant
	key, err := guestKey(id)
	if err != nil {
		return grant, err
	}
	var raw string
	err = s.DB.QueryRowContext(ctx, "SELECT value FROM preferences WHERE key=?", key).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return grant, ErrDenied
	}
	if err != nil {
		return grant, err
	}
	if err := json.Unmarshal([]byte(raw), &grant); err != nil {
		return grant, err
	}
	if grant.ID != id || grant.Expires <= time.Now().Unix() {
		return GuestGrant{}, ErrDenied
	}
	return grant, nil
}

func (s *Store) RevokeGuest(ctx context.Context, id string) error {
	key, err := guestKey(id)
	if err != nil {
		return err
	}
	_, err = s.DB.ExecContext(ctx, "DELETE FROM preferences WHERE key=?", key)
	return err
}

func (s *Store) SetGuestTerminal(ctx context.Context, id, operation, lease string) error {
	key, err := guestKey(id)
	if err != nil {
		return err
	}
	var transition string
	var statuses []string
	var nextLease, expectedLease string
	switch operation {
	case "approve":
		transition, statuses = "approved", []string{"", "approved"}
	case "start":
		transition, statuses = "active", []string{"approved", "approved"}
		nextLease = lease
	case "revoke":
		transition, statuses = "", []string{"approved", "active"}
	case "finish":
		transition, statuses = "", []string{"active", "active"}
		expectedLease = lease
	default:
		return errors.New("invalid terminal action")
	}
	res, err := s.DB.ExecContext(ctx, `
		UPDATE preferences SET value=json_set(value,'$.terminal',?,'$.terminal_lease',?)
		WHERE key=? AND json_extract(value,'$.expires_utc')>?
		AND coalesce(json_extract(value,'$.terminal'),'') IN (?,?)
		AND (?='' OR json_extract(value,'$.terminal_lease')=?)`,
		transition, nextLease, key, time.Now().Unix(), statuses[0], statuses[1], expectedLease, expectedLease)
	if err != nil {
		return err
	}
	if n, err := res.RowsAffected(); err != nil || (n != 1 && operation != "revoke" && operation != "finish") {
		return errors.Join(ErrDenied, err)
	}
	return nil
}

func (s *Store) PublishGuest(ctx context.Context, id string, publish func() error) error {
	key, err := guestKey(id)
	if err != nil {
		return err
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// Hold the short SQLite write lock across the atomic publication so a
	// successful revocation cannot be followed by a delayed download publish.
	active, err := tx.ExecContext(ctx, `
		UPDATE preferences SET value=value
		WHERE key=? AND json_extract(value,'$.expires_utc')>?`, key, time.Now().Unix())
	if err != nil {
		return err
	}
	if count, err := active.RowsAffected(); err != nil || count != 1 {
		return errors.Join(ErrDenied, err)
	}
	if err := publish(); err != nil {
		return err
	}
	return tx.Commit()
}
