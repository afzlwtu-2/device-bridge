// Package actions implements finite, typed diagnostics for an approved peer.
package actions

import (
	"context"
	"encoding/json"
	"errors"

	"devicebridge/internal/storage"
	"devicebridge/protocol"

	"golang.org/x/sys/unix"
)

const Feature = "agent-actions-v1"

type Preset struct {
	ID    string `json:"id"`
	Label string `json:"label"`
}

var presets = []Preset{
	{ID: "agent-status", Label: "Agent status"},
	{ID: "disk-space", Label: "Agent storage space"},
	{ID: "recent-activity", Label: "Recent activity"},
}

func Presets() []Preset {
	return append([]Preset(nil), presets...)
}

func Known(id string) bool {
	for _, preset := range presets {
		if preset.ID == id {
			return true
		}
	}
	return false
}

func Run(ctx context.Context, s *storage.Store, statePath, peer, id string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	var body any
	switch id {
	case "agent-status":
		body = map[string]any{"state": "running", "protocol": protocol.Version, "core": protocol.GoCoreVersion}
	case "disk-space":
		var stat unix.Statfs_t
		if err := unix.Statfs(statePath, &stat); err != nil {
			return "", errors.New("agent filesystem status is unavailable")
		}
		body = map[string]uint64{
			"size_bytes":      uint64(stat.Bsize) * uint64(stat.Blocks),
			"available_bytes": uint64(stat.Bsize) * uint64(stat.Bavail),
		}
	case "recent-activity":
		rows, err := s.DB.QueryContext(ctx, "SELECT at,action FROM audit WHERE peer=? ORDER BY seq DESC LIMIT 12", peer)
		if err != nil {
			return "", errors.New("agent activity is unavailable")
		}
		defer rows.Close()
		type activity struct {
			Time int64  `json:"utc"`
			Kind string `json:"activity"`
		}
		items := []activity{}
		for rows.Next() {
			var item activity
			if err := rows.Scan(&item.Time, &item.Kind); err != nil {
				return "", err
			}
			items = append(items, item)
		}
		if err := rows.Err(); err != nil {
			return "", err
		}
		body = items
	default:
		return "", errors.New("unknown agent action")
	}
	payload, err := json.MarshalIndent(body, "", "  ")
	if err != nil {
		return "", err
	}
	if len(payload) > storage.ActionOutputLimit {
		return "", errors.New("agent action output exceeds its limit")
	}
	return string(payload), nil
}
