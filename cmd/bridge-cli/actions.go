package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"time"

	"devicebridge/internal/actions"
	"devicebridge/internal/client"
	"devicebridge/internal/storage"
)

func localAction(s *storage.Store, args []string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if args[0] == "action-inbox" {
		if len(args) != 2 {
			return errors.New("action-inbox PEER_ID")
		}
		peer, err := s.Peer(args[1])
		if err != nil || peer.Status != "paired" {
			return storage.ErrDenied
		}
		inbox, err := s.ActionRequests(ctx, peer.ID)
		if err != nil {
			return err
		}
		return output(inbox)
	}
	if len(args) < 4 || len(args) > 5 || !actions.Known(args[2]) {
		return errors.New("action-approve PEER_ID PRESET REQUEST_ID [TTL] | action-revoke PEER_ID PRESET REQUEST_ID")
	}
	peer, preset, id := args[1], args[2], args[3]
	var request storage.ActionRequest
	var err error
	if args[0] == "action-approve" {
		ttl := 2 * time.Minute
		if len(args) == 5 {
			ttl, err = time.ParseDuration(args[4])
			if err != nil {
				return err
			}
		}
		request, err = s.ApproveAction(ctx, peer, preset, id, ttl)
	} else {
		if len(args) != 4 {
			return errors.New("action-revoke PEER_ID PRESET REQUEST_ID")
		}
		request, err = s.RevokeAction(ctx, peer, preset, id)
	}
	if err != nil {
		return err
	}
	if err := s.Audit(peer, args[0], preset+":"+id); err != nil {
		return err
	}
	return output(request)
}

func remoteAction(ctx context.Context, cl *client.Client, args []string) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if args[0] == "agent-actions" {
		if len(args) != 2 {
			return errors.New("agent-actions PEER")
		}
		var presets []actions.Preset
		if err := cl.JSON(ctx, "/v1/actions/presets", nil, &presets); err != nil {
			return err
		}
		return output(presets)
	}
	if len(args) < 3 || len(args) > 4 || !actions.Known(args[2]) {
		return errors.New("action PEER PRESET [REQUEST_ID]")
	}
	var id string
	if len(args) == 4 {
		id = args[3]
	} else {
		var nonce [16]byte
		if _, err := rand.Read(nonce[:]); err != nil {
			return err
		}
		id = hex.EncodeToString(nonce[:])
	}
	var receipt storage.ActionRequest
	payload := map[string]string{"id": id, "preset": args[2]}
	if err := cl.PostJSON(ctx, "/v1/actions/request", payload, &receipt); err != nil {
		return err
	}
	if receipt.ID != id || receipt.Preset != args[2] || len(receipt.Output) > storage.ActionOutputLimit {
		return errors.New("the peer returned an invalid action receipt")
	}
	return output(receipt)
}
