package storage

import (
	"devicebridge/internal/filesproviders"
	"devicebridge/protocol"
	"encoding/json"
	"errors"
	"path/filepath"
	"regexp"
	"strings"
)

var syncGroupPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,63}$`)

const syncPairPrefix = "sync.pair.v1."

func (s *Store) SyncPairs() ([]protocol.SyncPair, error) {
	rows, err := s.DB.Query("SELECT value FROM preferences WHERE key LIKE ? ORDER BY key LIMIT 129", syncPairPrefix+"%")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []protocol.SyncPair{}
	for rows.Next() {
		var raw string
		var pair protocol.SyncPair
		if err = rows.Scan(&raw); err != nil {
			return nil, err
		}
		if json.Unmarshal([]byte(raw), &pair) != nil {
			return nil, errors.New("invalid saved folder sync")
		}
		var fields map[string]json.RawMessage
		if json.Unmarshal([]byte(raw), &fields) == nil {
			if _, ok := fields["configured"]; !ok && pair.State != "draft" && pair.State != "configuring" {
				pair.Configured = true
			}
		}
		result = append(result, pair)
	}
	return result, rows.Err()
}

func (s *Store) SaveSyncPair(pair protocol.SyncPair) error {
	if !syncGroupPattern.MatchString(pair.Group) || (pair.Mode != "full" && pair.Mode != "non-git") {
		return errors.New("invalid folder sync")
	}
	if pair.Source.Device == pair.Target.Device {
		return errors.New("choose two different devices for folder sync")
	}
	for _, location := range []protocol.SyncLocation{pair.Source, pair.Target} {
		if len(location.Name) > 256 || strings.ContainsRune(location.Name, 0) || filesproviders.ValidPath(location.Path) != nil {
			return errors.New("invalid folder location")
		}
		if location.Device == "local" {
			if !filepath.IsAbs(location.LocalPath) {
				return errors.New("choose the local folder in Files")
			}
		} else {
			peer, err := s.Peer(location.Device)
			if err != nil || peer.Status != "paired" || location.Root == "" || len(location.Root) > 80 || location.LocalPath != "" {
				return ErrDenied
			}
		}
	}
	pairs, err := s.SyncPairs()
	if err != nil {
		return err
	}
	if len(pairs) >= 128 {
		found := false
		for _, old := range pairs {
			if old.Group == pair.Group {
				found = true
			}
		}
		if !found {
			return errors.New("folder sync registry is full")
		}
	}
	raw, err := json.Marshal(pair)
	if err != nil {
		return err
	}
	_, err = s.DB.Exec("INSERT INTO preferences(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", syncPairPrefix+pair.Group, string(raw))
	return err
}

func (s *Store) ForgetSyncPair(group string) error {
	if !syncGroupPattern.MatchString(group) {
		return errors.New("invalid folder sync")
	}
	_, err := s.DB.Exec("DELETE FROM preferences WHERE key=?", syncPairPrefix+group)
	return err
}
