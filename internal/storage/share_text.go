package storage

import (
	"context"
	"database/sql"
	"devicebridge/protocol"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"time"
	"unicode/utf8"
)

const textPermissionPrefix = "share.text.allow.v1."
const filePermissionPrefix = "share.file.allow.v1."
const syncPermissionPrefix = "sync.control.allow.v1."
const syncRemotePermissionPrefix = "sync.remote.allow.v1."
const termuxFilesPermissionPrefix = "termux.files.allow.v1."
const textMessagePrefix = "share.text.message.v1."
const textInboxLimit = 128

var ErrTextShareConflict = errors.New("message ID already used for different text")
var ErrInvalidSharedText = errors.New("invalid message ID or text")

// TextShareAccess returns or changes the local owner's grant for one paired sender.
func (s *Store) TextShareAccess(peer string, update *bool) (bool, error) {
	return s.shareReceiveAccess(peer, textPermissionPrefix, update)
}

func (s *Store) FileShareAccess(peer string, update *bool) (bool, error) {
	return s.shareReceiveAccess(peer, filePermissionPrefix, update)
}

// SyncControlAccess is an explicit local-owner delegation to configure/update
// synced folders within this peer's still-live filesystem grants.
func (s *Store) SyncControlAccess(peer string, update *bool) (bool, error) {
	return s.shareReceiveAccess(peer, syncPermissionPrefix, update)
}

func (s *Store) SyncRemoteAccess(peer string, update *bool) (bool, error) {
	return s.shareReceiveAccess(peer, syncRemotePermissionPrefix, update)
}

// TermuxFilesAccess delegates copy and move in the companion's granted Home.
func (s *Store) TermuxFilesAccess(peer string, update *bool) (bool, error) {
	return s.shareReceiveAccess(peer, termuxFilesPermissionPrefix, update)
}

func aclResourceForSharePrefix(prefix string) string {
	switch prefix {
	case textPermissionPrefix:
		return "share:text"
	case filePermissionPrefix:
		return "share:file"
	case syncPermissionPrefix, syncRemotePermissionPrefix:
		return "sync"
	case termuxFilesPermissionPrefix:
		return "termux"
	default:
		return ""
	}
}

func (s *Store) shareReceiveAccess(peer, prefix string, update *bool) (bool, error) {
	if p, err := s.Peer(peer); err != nil || p.Status != "paired" {
		return false, ErrDenied
	}
	if update != nil {
		if *update {
			res, err := s.DB.Exec(`INSERT INTO preferences(key,value)
				SELECT ?, '1' WHERE EXISTS (SELECT 1 FROM peers WHERE id=? AND status='paired')
				ON CONFLICT(key) DO UPDATE SET value='1'`, prefix+peer, peer)
			if err != nil {
				return false, err
			}
			n, err := res.RowsAffected()
			if err != nil {
				return false, err
			}
			if n == 0 {
				return false, ErrDenied
			}
			return true, nil
		}
		_, err := s.DB.Exec("DELETE FROM preferences WHERE key=?", prefix+peer)
		return false, err
	}
	if aclRes := aclResourceForSharePrefix(prefix); aclRes != "" {
		aclEnabled, aclAllowed, aclErr := s.CheckPeerACL(context.Background(), peer, aclRes)
		if aclErr != nil {
			return false, aclErr
		}
		if aclEnabled {
			if !aclAllowed {
				return false, nil
			}
			// SyncRemoteAccess retains explicit per-peer consent for remote/cellular bulk sync.
			if prefix != syncRemotePermissionPrefix {
				return true, nil
			}
		}
	}
	var value string
	err := s.DB.QueryRow("SELECT value FROM preferences WHERE key=?", prefix+peer).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return value == "1", err
}

func (s *Store) ReceiveText(peer string, req protocol.TextShareRequest) (protocol.TextShareMessage, error) {
	var out protocol.TextShareMessage
	if _, err := hex.DecodeString(req.ID); err != nil || len(req.ID) != 32 ||
		strings.TrimSpace(req.Text) == "" || !utf8.ValidString(req.Text) ||
		len(req.Text) > protocol.MaxSharedTextBytes {
		return out, ErrInvalidSharedText
	}
	p, err := s.Peer(peer)
	if err != nil || p.Status != "paired" {
		return out, ErrDenied
	}
	aclEnabled, aclAllowed, aclErr := s.CheckPeerACL(context.Background(), p.ID, "share:text")
	if aclErr != nil || (aclEnabled && !aclAllowed) {
		return out, ErrDenied
	}
	out = protocol.TextShareMessage{
		ID: strings.ToLower(req.ID), PeerID: peer, PeerName: p.Name,
		Text: req.Text, ReceivedUnix: time.Now().UnixMilli(),
	}
	body, err := json.Marshal(out)
	if err != nil {
		return protocol.TextShareMessage{}, err
	}
	key := textMessagePrefix + peer + "." + out.ID
	var res sql.Result
	if aclEnabled {
		res, err = s.DB.Exec(`
			INSERT INTO preferences(key,value)
			SELECT ?, ? WHERE EXISTS (
				SELECT 1 FROM peers WHERE peers.id=? AND peers.status='paired'
			)
			ON CONFLICT(key) DO NOTHING
		`, key, string(body), peer)
	} else {
		// The grant and peer status are checked in the same statement as the write.
		// A revoked peer cannot deliver a message using a prior permission read.
		res, err = s.DB.Exec(`
			INSERT INTO preferences(key,value)
			SELECT ?, ? WHERE EXISTS (
				SELECT 1 FROM peers JOIN preferences grant ON grant.key=?
				WHERE peers.id=? AND peers.status='paired' AND grant.value='1'
			)
			ON CONFLICT(key) DO NOTHING
		`, key, string(body), textPermissionPrefix+peer, peer)
	}
	if err != nil {
		return protocol.TextShareMessage{}, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return protocol.TextShareMessage{}, err
	}
	if n == 0 {
		var previous string
		if aclEnabled {
			err = s.DB.QueryRow(`
				SELECT msg.value FROM preferences msg, peers
				WHERE msg.key=? AND peers.id=? AND peers.status='paired'
			`, key, peer).Scan(&previous)
		} else {
			err = s.DB.QueryRow(`
				SELECT msg.value FROM preferences msg, peers, preferences grant
				WHERE msg.key=? AND peers.id=? AND peers.status='paired' AND grant.key=? AND grant.value='1'
			`, key, peer, textPermissionPrefix+peer).Scan(&previous)
		}
		if errors.Is(err, sql.ErrNoRows) {
			return protocol.TextShareMessage{}, ErrDenied
		}
		if err != nil {
			return protocol.TextShareMessage{}, err
		}
		var stored protocol.TextShareMessage
		if err = json.Unmarshal([]byte(previous), &stored); err != nil {
			return protocol.TextShareMessage{}, err
		}
		if stored.Text != req.Text {
			return protocol.TextShareMessage{}, ErrTextShareConflict
		}
		return stored, nil
	}
	_, err = s.DB.Exec(`
		DELETE FROM preferences WHERE key GLOB ?
		AND key NOT IN (SELECT key FROM preferences WHERE key GLOB ?
			ORDER BY json_extract(value, '$.received_unix') DESC, key DESC LIMIT ?)
	`, textMessagePrefix+"*", textMessagePrefix+"*", textInboxLimit)
	return out, err
}

func (s *Store) TextInbox() ([]protocol.TextShareMessage, error) {
	rows, err := s.DB.Query(`
		SELECT value FROM preferences WHERE key GLOB ?
		ORDER BY json_extract(value, '$.received_unix') DESC, key DESC LIMIT ?
	`, textMessagePrefix+"*", textInboxLimit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	inbox := []protocol.TextShareMessage{}
	for rows.Next() {
		var value string
		if err := rows.Scan(&value); err != nil {
			return nil, err
		}
		var message protocol.TextShareMessage
		if err := json.Unmarshal([]byte(value), &message); err != nil {
			return nil, err
		}
		inbox = append(inbox, message)
	}
	return inbox, rows.Err()
}

func (s *Store) ForgetText(sender, id string) error {
	if _, err := hex.DecodeString(sender); err != nil || len(sender) != 64 {
		return ErrInvalidSharedText
	}
	if _, err := hex.DecodeString(id); err != nil || len(id) != 32 {
		return ErrInvalidSharedText
	}
	_, err := s.DB.Exec("DELETE FROM preferences WHERE key=?",
		textMessagePrefix+sender+"."+strings.ToLower(id))
	return err
}
