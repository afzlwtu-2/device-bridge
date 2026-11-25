package storage

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestLinkLeaseOwnershipDeadlineAndIdempotentCommit(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	id := strings.Repeat("a", 32)
	if _, err = s.ChangeLinkLease(ctx, "peer-a", id, "begin", 120); err != nil {
		t.Fatal(err)
	}
	if _, err = s.ChangeLinkLease(ctx, "peer-b", id, "commit", 0); err == nil {
		t.Fatal("another peer committed network change")
	}
	if _, err = s.ChangeLinkLease(ctx, "peer-b", strings.Repeat("b", 32), "begin", 120); err == nil {
		t.Fatal("concurrent physical-network operation accepted")
	}
	if _, err = s.ChangeLinkLease(ctx, "peer-a", id, "commit", 0); err != nil {
		t.Fatal(err)
	}
	if _, err = s.ChangeLinkLease(ctx, "peer-a", id, "commit", 0); err != nil {
		t.Fatal("idempotent commit failed", err)
	}
	if _, err = s.ChangeLinkLease(ctx, "", "", "claim-expired", 0); err == nil {
		t.Fatal("committed route rolled back")
	}
	if _, err = s.ChangeLinkLease(ctx, "peer-a", id, "restored", 0); err != nil {
		t.Fatal(err)
	}
	id = strings.Repeat("c", 32)
	if _, err = s.ChangeLinkLease(ctx, "peer-a", id, "begin", 15); err != nil {
		t.Fatal(err)
	}
	if _, err = s.DB.Exec("UPDATE preferences SET value=json_set(value,'$.deadline_utc',?) WHERE key=?", time.Now().Unix()-1, linkLeaseKey); err != nil {
		t.Fatal(err)
	}
	if _, err = s.ChangeLinkLease(ctx, "peer-a", id, "commit", 0); err == nil {
		t.Fatal("expired route committed")
	}
	lease, err := s.ChangeLinkLease(ctx, "", "", "claim-expired", 0)
	if err != nil || lease.Stage != "restoring" {
		t.Fatal("expired route not claimable", err)
	}
	if _, err = s.ChangeLinkLease(ctx, "", "", "claim-expired", 0); err == nil {
		t.Fatal("two listeners claimed the same restore")
	}
}
