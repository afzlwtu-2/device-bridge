package main

import (
	"context"
	"devicebridge/internal/storage"
	"devicebridge/protocol"
	"encoding/json"
	"errors"
	"io"
	"os"
	"slices"
	"sort"
	"strings"
	"time"
)

type aclSnapshot struct {
	Policy      storage.ACLPolicy           `json:"policy"`
	PeerTags    map[string][]string         `json:"peer_tags"`
	Evaluations []storage.PeerACLEvaluation `json:"evaluations"`
}

func buildACLSnapshot(ctx context.Context, s *storage.Store) (aclSnapshot, error) {
	policy, err := s.ACLPolicy(ctx)
	if err != nil {
		return aclSnapshot{}, err
	}
	peers, err := s.Peers()
	if err != nil {
		return aclSnapshot{}, err
	}
	peerTags := map[string][]string{}
	evals := make([]storage.PeerACLEvaluation, 0, len(peers))
	for _, p := range peers {
		if p.Status == "revoked" {
			continue
		}
		ev, err := s.EvaluatePeerACL(ctx, p.ID)
		if err != nil {
			continue
		}
		ev.Name = protocol.DeviceDisplayName(ev.Name)
		peerTags[p.ID] = ev.Tags
		evals = append(evals, ev)
	}
	return aclSnapshot{Policy: policy, PeerTags: peerTags, Evaluations: evals}, nil
}

func aclCommand(s *storage.Store, a []string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if len(a) == 1 {
		snap, err := buildACLSnapshot(ctx, s)
		if err != nil {
			return err
		}
		return output(snap)
	}
	if len(a) == 3 && a[1] == "set" && a[2] == "-" {
		var policy storage.ACLPolicy
		dec := json.NewDecoder(io.LimitReader(os.Stdin, 1<<20))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&policy); err != nil {
			return err
		}
		if dec.Decode(new(any)) != io.EOF {
			return errors.New("invalid ACL payload")
		}
		if _, err := s.SaveACLPolicy(ctx, policy); err != nil {
			return err
		}
		snap, err := buildACLSnapshot(ctx, s)
		if err != nil {
			return err
		}
		return output(snap)
	}
	if len(a) == 3 && a[1] == "preset" && a[2] == "trusted" {
		cur, err := s.ACLPolicy(ctx)
		if err != nil {
			return err
		}
		if _, err = s.SaveACLPolicy(ctx, storage.PresetTrustedACLPolicy(cur.Groups)); err != nil {
			return err
		}
		snap, err := buildACLSnapshot(ctx, s)
		if err != nil {
			return err
		}
		return output(snap)
	}
	if len(a) == 3 && a[1] == "eval" {
		ev, err := s.EvaluatePeerACL(ctx, a[2])
		if err != nil {
			return err
		}
		ev.Name = protocol.DeviceDisplayName(ev.Name)
		return output(ev)
	}
	return errors.New("acl [set - | preset trusted | eval PEER]")
}

func peerTagsCommand(s *storage.Store, a []string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if len(a) < 2 || len(a) > 3 {
		return errors.New("peer-tags PEER [TAG1,TAG2|none|-]")
	}
	if len(a) == 2 {
		tags, err := s.PeerTags(ctx, a[1])
		if err != nil {
			return err
		}
		return output(map[string]any{"peer_id": a[1], "tags": tags})
	}
	var tags []string
	if a[2] == "-" {
		dec := json.NewDecoder(io.LimitReader(os.Stdin, 16384))
		if err := dec.Decode(&tags); err != nil {
			return err
		}
	} else if a[2] != "none" && strings.TrimSpace(a[2]) != "" {
		for _, part := range strings.Split(a[2], ",") {
			if tr := strings.TrimSpace(part); tr != "" {
				tags = append(tags, tr)
			}
		}
	}
	saved, err := s.SetPeerTags(ctx, a[1], tags)
	if err != nil {
		return err
	}
	return output(map[string]any{"peer_id": a[1], "tags": saved})
}

func aclGroupCommand(s *storage.Store, a []string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if len(a) < 2 || len(a) > 3 {
		return errors.New("acl-group GROUP [PEER1,PEER2|none|delete|-]")
	}
	if len(a) == 2 {
		grp, err := storage.NormalizeACLGroup(a[1])
		if err != nil {
			return err
		}
		p, err := s.ACLPolicy(ctx)
		if err != nil {
			return err
		}
		members := append([]string(nil), p.Groups[grp]...)
		sort.Strings(members)
		return output(map[string]any{"group": grp, "members": members})
	}
	deleteGroup := a[2] == "delete"
	var members []string
	if a[2] == "-" {
		dec := json.NewDecoder(io.LimitReader(os.Stdin, 65536))
		if err := dec.Decode(&members); err != nil {
			return err
		}
	} else if !deleteGroup && a[2] != "none" && strings.TrimSpace(a[2]) != "" {
		for _, part := range strings.Split(a[2], ",") {
			if tr := strings.TrimSpace(part); tr != "" && !slices.Contains(members, tr) {
				members = append(members, tr)
			}
		}
	}
	p, err := s.SetACLGroup(ctx, a[1], members, deleteGroup)
	if err != nil {
		return err
	}
	return output(p)
}
