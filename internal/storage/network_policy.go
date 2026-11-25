package storage

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
)

// NetworkPolicy stores availability, independently of runtime readiness.
func (s *Store) NetworkPolicy(ctx context.Context, update map[string]bool) (map[string]bool, error) {
	defaults := map[string]bool{"network_agent_ssh": true, "network_direct": true, "network_tailnet": true, "network_wireguard": true, "network_adb": true, "network_wifi": true, "network_hotspot": true, "network_wifi_direct": true, "network_usb": true, "network_cellular": true}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var raw string
	err = tx.QueryRowContext(ctx, "SELECT value FROM preferences WHERE key='network-policy-v1'").Scan(&raw)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	if err == nil {
		var saved map[string]bool
		if err = json.Unmarshal([]byte(raw), &saved); err != nil {
			return nil, err
		}
		for k, v := range saved {
			if _, ok := defaults[k]; ok {
				defaults[k] = v
			}
		}
	}
	for k, v := range update {
		if _, ok := defaults[k]; !ok {
			return nil, errors.New("unknown network policy")
		}
		defaults[k] = v
	}
	if len(update) > 0 {
		b, _ := json.Marshal(defaults)
		_, err = tx.ExecContext(ctx, "INSERT INTO preferences(key,value) VALUES('network-policy-v1',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", string(b))
		if err != nil {
			return nil, err
		}
	}
	return defaults, tx.Commit()
}
