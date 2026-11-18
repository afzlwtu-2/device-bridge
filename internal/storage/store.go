// Package storage owns the shared SQLite database and explicit schema migrations.
package storage

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	_ "github.com/mattn/go-sqlite3"
	"net/url"
	"os"
	"path/filepath"
	"time"
)

type Store struct{ DB *sql.DB }
type Peer struct {
	ID        string                `json:"id"`
	Name      string                `json:"name"`
	Status    string                `json:"status"`
	Expires   int64                 `json:"expires"`
	Addresses []EndpointObservation `json:"addresses,omitempty"`
}
type EndpointObservation struct {
	Endpoint      string `json:"endpoint"`
	Network       string `json:"network"`
	Observed      int64  `json:"observed"`
	Authenticated bool   `json:"authenticated"`
}

func (s *Store) EndpointRecords(peer string) ([]EndpointObservation, error) {
	rows, err := s.DB.Query("SELECT endpoint,network,observed FROM endpoints WHERE peer=? ORDER BY observed DESC,endpoint LIMIT 8", peer)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []EndpointObservation{}
	for rows.Next() {
		var e EndpointObservation
		if err = rows.Scan(&e.Endpoint, &e.Network, &e.Observed); err != nil {
			return nil, err
		}
		e.Authenticated = true
		out = append(out, e)
	}
	return out, rows.Err()
}

type Export struct {
	ID   string `json:"id"`
	Path string `json:"path"`
}

var ErrDenied = errors.New("permission denied or grant expired")

func Open(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() || info.Mode()&0077 != 0 {
		return nil, errors.New("state directory must be private (0700), not a symlink")
	}
	path := filepath.Join(dir, "state.db")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err == nil {
		f.Close()
	} else if !errors.Is(err, os.ErrExist) {
		return nil, err
	}
	info, err = os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode()&0077 != 0 {
		return nil, errors.New("database must be a private regular file")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	dsn := url.URL{Scheme: "file", Path: filepath.ToSlash(abs), RawQuery: "_busy_timeout=5000&_foreign_keys=on&_journal_mode=WAL&_synchronous=FULL"}
	db, err := sql.Open("sqlite3", dsn.String())
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	s := &Store{DB: db}
	if err = s.migrate(); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}
func (s *Store) Close() error { return s.DB.Close() }
func (s *Store) migrate() error {
	var version int
	if err := s.DB.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return err
	}
	if version > 3 {
		return errors.New("database schema is newer than this app")
	}
	if version == 3 {
		return nil
	}
	if version == 2 {
		tx, err := s.DB.Begin()
		if err != nil {
			return err
		}
		defer tx.Rollback()
		if _, err = tx.Exec(`CREATE TABLE preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL); PRAGMA user_version=3;`); err != nil {
			return err
		}
		return tx.Commit()
	}
	if version == 1 {
		tx, err := s.DB.Begin()
		if err != nil {
			return err
		}
		defer tx.Rollback()
		_, err = tx.Exec(`CREATE TABLE endpoints (peer TEXT NOT NULL REFERENCES peers(id), network TEXT NOT NULL, endpoint TEXT NOT NULL, observed INTEGER NOT NULL, PRIMARY KEY(peer,network,endpoint)); PRAGMA user_version=2;`)
		if err != nil {
			return err
		}
		if err = tx.Commit(); err != nil {
			return err
		}
		return s.migrate()
	}
	tx, err := s.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	_, err = tx.Exec(`
CREATE TABLE identity (singleton INTEGER PRIMARY KEY CHECK(singleton=1), name TEXT NOT NULL, cert BLOB NOT NULL, private_key BLOB NOT NULL);
CREATE TABLE peers (id TEXT PRIMARY KEY, name TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('pending','paired','revoked','outbound')), expires INTEGER NOT NULL);
CREATE TABLE invitations (hash TEXT PRIMARY KEY, expires INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0);
CREATE TABLE grants (peer TEXT NOT NULL REFERENCES peers(id), root TEXT NOT NULL, browse INTEGER NOT NULL, read INTEGER NOT NULL, expires INTEGER NOT NULL, quota INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(peer,root));
CREATE TABLE exports (id TEXT PRIMARY KEY, path TEXT NOT NULL);
CREATE TABLE audit (seq INTEGER PRIMARY KEY, at INTEGER NOT NULL, peer TEXT NOT NULL, action TEXT NOT NULL, scope TEXT NOT NULL);
PRAGMA user_version=1;`)
	if err != nil {
		return err
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	return s.migrate()
}

func (s *Store) Theme(value string) (string, error) {
	if value != "" {
		switch value {
		case "system", "light", "dark", "amoled", "amoled-green", "amoled-red", "matte":
		default:
			return "", errors.New("unsupported theme")
		}
		if _, err := s.DB.Exec("INSERT INTO preferences(key,value) VALUES('ui.theme',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", value); err != nil {
			return "", err
		}
	}
	var saved string
	err := s.DB.QueryRow("SELECT value FROM preferences WHERE key='ui.theme'").Scan(&saved)
	if errors.Is(err, sql.ErrNoRows) {
		return "system", nil
	}
	return saved, err
}

// Cache only after an authenticated pinned /device handshake. TTL is deliberately
// short and scoped to the selected source IP/subnet/interface; cached IPs are not trust.
func (s *Store) CacheEndpoint(peer, network, endpoint string) error {
	_, err := s.DB.Exec("INSERT INTO endpoints(peer,network,endpoint,observed) VALUES(?,?,?,?) ON CONFLICT(peer,network,endpoint) DO UPDATE SET observed=excluded.observed", peer, network, endpoint, time.Now().Unix())
	return err
}
func (s *Store) CachedEndpoints(peer, network string) ([]string, error) {
	rows, err := s.DB.Query("SELECT endpoint FROM endpoints WHERE peer=? AND network=? AND observed>? ORDER BY observed DESC LIMIT 8", peer, network, time.Now().Add(-30*time.Second).Unix())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var endpoint string
		if err = rows.Scan(&endpoint); err != nil {
			return nil, err
		}
		out = append(out, endpoint)
	}
	return out, rows.Err()
}
func Hash(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }
func (s *Store) NewInvite(token string, expires time.Time) error {
	_, err := s.DB.Exec("INSERT INTO invitations(hash,expires) VALUES(?,?)", Hash(token), expires.Unix())
	return err
}
func (s *Store) RequestPair(token, id, name string) (err error) {
	if len(name) == 0 || len(name) > 128 || len(id) != 64 {
		return errors.New("invalid pairing identity")
	}
	tx, err := s.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.Exec("UPDATE invitations SET used=1 WHERE hash=? AND used=0 AND expires>?", Hash(token), time.Now().Unix())
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n != 1 {
		return ErrDenied
	}
	// A new invitation cannot reactivate a revoked peer or change a live pairing.
	_, err = tx.Exec("INSERT INTO peers(id,name,status,expires) VALUES(?,?,'pending',?)", id, name, time.Now().Add(5*time.Minute).Unix())
	if err != nil {
		return errors.New("peer already exists; revoke/remove locally before pairing again")
	}
	_, err = tx.Exec("INSERT INTO audit(at,peer,action,scope) VALUES(?,?,?,?)", time.Now().Unix(), id, "pair_requested", "")
	if err != nil {
		return err
	}
	return tx.Commit()
}
func (s *Store) Peer(id string) (Peer, error) {
	var p Peer
	err := s.DB.QueryRow("SELECT id,name,status,expires FROM peers WHERE id=?", id).Scan(&p.ID, &p.Name, &p.Status, &p.Expires)
	return p, err
}
func (s *Store) Peers() ([]Peer, error) {
	rows, err := s.DB.Query("SELECT id,name,status,expires FROM peers ORDER BY name,id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	p := []Peer{}
	for rows.Next() {
		var v Peer
		if err = rows.Scan(&v.ID, &v.Name, &v.Status, &v.Expires); err != nil {
			return nil, err
		}
		p = append(p, v)
	}
	return p, rows.Err()
}
func (s *Store) TrustOutbound(id, name, status string) error {
	if status != "paired" && status != "outbound" {
		return ErrDenied
	}
	_, err := s.DB.Exec("INSERT INTO peers(id,name,status,expires) VALUES(?,?,?,0) ON CONFLICT(id) DO UPDATE SET status=excluded.status WHERE peers.status='outbound'", id, name, status)
	return err
}
func (s *Store) Approve(id string, roots []string, ttl time.Duration, quota int64) error {
	if ttl <= 0 || quota <= 0 {
		return errors.New("positive grant duration and byte quota required")
	}
	tx, err := s.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.Exec("UPDATE peers SET status='paired',expires=0 WHERE id=? AND status='pending' AND expires>?", id, time.Now().Unix())
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n != 1 {
		return ErrDenied
	}
	for _, root := range roots {
		var exists int
		if err = tx.QueryRow("SELECT COUNT(*) FROM exports WHERE id=?", root).Scan(&exists); err != nil {
			return err
		}
		if exists != 1 {
			return fmt.Errorf("root %q not exported", root)
		}
		_, err = tx.Exec("INSERT INTO grants(peer,root,browse,read,expires,quota) VALUES(?,?,1,1,?,?)", id, root, time.Now().Add(ttl).Unix(), quota)
		if err != nil {
			return err
		}
	}
	_, err = tx.Exec("INSERT INTO audit(at,peer,action,scope) VALUES(?,?,?,?)", time.Now().Unix(), id, "pair_approved", fmt.Sprint(roots))
	if err != nil {
		return err
	}
	return tx.Commit()
}
func (s *Store) Revoke(id string) error {
	tx, err := s.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.Exec("UPDATE peers SET status='revoked' WHERE id=?", id)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n != 1 {
		return ErrDenied
	}
	_, err = tx.Exec("DELETE FROM grants WHERE peer=?", id)
	if err != nil {
		return err
	}
	_, err = tx.Exec("INSERT INTO audit(at,peer,action,scope) VALUES(?,?,?,?)", time.Now().Unix(), id, "revoked", "")
	if err != nil {
		return err
	}
	return tx.Commit()
}
func (s *Store) RemovePeer(id string) error {
	tx, err := s.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, stmt := range []string{
		"DELETE FROM grants WHERE peer=?",
		"DELETE FROM endpoints WHERE peer=?",
	} {
		if _, err = tx.Exec(stmt, id); err != nil {
			return err
		}
	}
	if _, err = tx.Exec("DELETE FROM preferences WHERE key IN (?,?)", "connection."+id, "rate."+id); err != nil {
		return err
	}
	res, err := tx.Exec("DELETE FROM peers WHERE id=?", id)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n != 1 {
		return ErrDenied
	}
	if _, err = tx.Exec("INSERT INTO audit(at,peer,action,scope) VALUES(?,?,?,?)", time.Now().Unix(), id, "removed", ""); err != nil {
		return err
	}
	return tx.Commit()
}
func (s *Store) Authorized(id, root, op string, bytes int64) error {
	if bytes < 0 {
		return ErrDenied
	}
	col := "browse"
	if op == "read" {
		col = "read"
	} else if op != "browse" {
		return ErrDenied
	}
	res, err := s.DB.Exec("UPDATE grants SET used=used+? WHERE peer=? AND root=? AND "+col+"=1 AND expires>? AND used<=quota-? AND EXISTS(SELECT 1 FROM peers WHERE id=? AND status='paired')", bytes, id, root, time.Now().Unix(), bytes, id)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n != 1 {
		return ErrDenied
	}
	return nil
}
func (s *Store) Export(id, path string) error {
	if id == "" || len(id) > 80 {
		return errors.New("invalid export id")
	}
	p, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	_, err = s.DB.Exec("INSERT INTO exports(id,path) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET path=excluded.path", id, p)
	return err
}

// ExportDocuments records a versioned Android provider root without treating
// its identifier as a native filesystem path.
func (s *Store) ExportDocuments(id, kind string) error {
	if id == "" || len(id) > 80 || (kind != "saf" && kind != "termux") {
		return errors.New("invalid Android document export")
	}
	_, err := s.DB.Exec("INSERT INTO exports(id,path) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET path=excluded.path", id, "android-documents://"+kind)
	return err
}
func (s *Store) Exports() ([]Export, error) {
	rows, err := s.DB.Query("SELECT id,path FROM exports ORDER BY id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Export{}
	for rows.Next() {
		var e Export
		if err = rows.Scan(&e.ID, &e.Path); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}
func (s *Store) Audit(peer, action, scope string) error {
	_, err := s.DB.Exec("INSERT INTO audit(at,peer,action,scope) VALUES(?,?,?,?)", time.Now().Unix(), peer, action, scope)
	return err
}
