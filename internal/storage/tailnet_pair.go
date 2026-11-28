package storage

import (
	"context"
	"database/sql"
	"errors"
	"slices"
	"strings"
	"time"
)

const trustedTailnetTag = "tag:trusted"
const verifiedTailnetTrustPrefix = "tailnet-trusted-v1:"

func (s *Store) PairFromTailnet(ctx context.Context, id, name string, verifiedTags []string) error {
	return s.pairFromTailnet(ctx, id, name, verifiedTags, true)
}

func (s *Store) CompleteTailnetPair(ctx context.Context, id, name string) error {
	return s.pairFromTailnet(ctx, id, name, nil, false)
}

func (s *Store) pairFromTailnet(ctx context.Context, id, name string, verifiedTags []string, incoming bool) error {
	if _, ok := normalizePeerID(id); !ok || strings.TrimSpace(name) == "" || len(name) > 128 {
		return ErrDenied
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	policy, err := readACLPolicy(tx.QueryRowContext(ctx, "SELECT value FROM preferences WHERE key=?", aclPolicyKey))
	if err != nil {
		return err
	}
	allowed := slices.ContainsFunc(verifiedTags, func(tag string) bool {
		return slices.Contains(policy.TailnetPairTags, tag)
	})
	if incoming && !allowed {
		return ErrDenied
	}
	result, err := tx.ExecContext(ctx, `INSERT INTO peers(id,name,status,expires) VALUES(?,?,'paired',0)
		ON CONFLICT(id) DO UPDATE SET status='paired', expires=0
		WHERE peers.status IN ('outbound','pending')`, id, name)
	if err != nil {
		return err
	}
	n, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		// A lost reply can be retried, but cannot change an existing peer's grants.
		var status string
		if err := tx.QueryRowContext(ctx, "SELECT status FROM peers WHERE id=?", id).Scan(&status); err != nil || status != "paired" {
			return ErrDenied
		}
		return nil
	}
	if slices.Contains(verifiedTags, trustedTailnetTag) && slices.Contains(policy.TailnetPairTags, trustedTailnetTag) {
		if _, err := tx.ExecContext(ctx, "INSERT INTO preferences(key,value) VALUES(?,'true') ON CONFLICT(key) DO NOTHING", verifiedTailnetTrustPrefix+id); err != nil {
			return err
		}
	}
	if _, err := tx.ExecContext(ctx, "INSERT INTO audit(at,peer,action,scope) VALUES(?,?,?,?)",
		time.Now().Unix(), id, "tailnet_pair_approved", ""); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) hasVerifiedTailnetTrust(ctx context.Context, peer string, policy ACLPolicy) (bool, error) {
	if !slices.Contains(policy.TailnetPairTags, trustedTailnetTag) {
		return false, nil
	}
	var exists bool
	err := s.DB.QueryRowContext(ctx, "SELECT 1 FROM preferences WHERE key=?", verifiedTailnetTrustPrefix+peer).Scan(&exists)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return exists, err
}

func evaluatePeerPolicy(policy ACLPolicy, peer string, tags []string, resource string, trusted bool) ACLDecision {
	if !trusted {
		return evaluateRuleSet(policy, peer, tags, resource)
	}
	if policy.Enabled {
		decision := evaluateRuleSet(policy, peer, append(tags, trustedTailnetTag), resource)
		if decision.MatchedRule != "" {
			return decision
		}
	}
	return ACLDecision{Resource: resource, Allowed: true, Reason: "Verified Tailscale tag:trusted at pairing"}
}
