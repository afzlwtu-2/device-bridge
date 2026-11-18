package storage

import (
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSingleUseInviteGrantsAndRevocation(t *testing.T) {
	t.Parallel()
	s, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	id := strings.Repeat("a", 64)
	if err = s.NewInvite("secret", time.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if err = s.RequestPair("secret", id, "phone"); err != nil {
		t.Fatal(err)
	}
	if err = s.RequestPair("secret", strings.Repeat("b", 64), "other"); err == nil {
		t.Fatal("replayed invitation accepted")
	}
	if err = s.Authorized(id, "shared", "read", 0); err == nil {
		t.Fatal("pending peer permitted")
	}
	if err = s.Export("shared", t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if err = s.Approve(id, []string{"shared"}, time.Minute, 3); err != nil {
		t.Fatal(err)
	}
	if err = s.Authorized(id, "shared", "read", 3); err != nil {
		t.Fatal(err)
	}
	if err = s.Authorized(id, "shared", "read", 1); err == nil {
		t.Fatal("quota bypass")
	}
	if err = s.Authorized(id, "other", "browse", 0); err == nil {
		t.Fatal("ungranted root permitted")
	}
	if err = s.Revoke(id); err != nil {
		t.Fatal(err)
	}
	if err = s.Authorized(id, "shared", "browse", 0); err == nil {
		t.Fatal("revoked peer permitted")
	}
}
func TestExpiredInvitationAndGrant(t *testing.T) {
	t.Parallel()
	s, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err = s.NewInvite("expired", time.Now().Add(-time.Second)); err != nil {
		t.Fatal(err)
	}
	if s.RequestPair("expired", strings.Repeat("c", 64), "phone") == nil {
		t.Fatal("expired invitation accepted")
	}
	id := strings.Repeat("d", 64)
	if err = s.NewInvite("valid", time.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if err = s.RequestPair("valid", id, "phone"); err != nil {
		t.Fatal(err)
	}
	if err = s.Export("shared", t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if err = s.Approve(id, []string{"shared"}, time.Hour, 100); err != nil {
		t.Fatal(err)
	}
	if _, err = s.DB.Exec("UPDATE grants SET expires=? WHERE peer=?", time.Now().Add(-time.Second).Unix(), id); err != nil {
		t.Fatal(err)
	}
	if s.Authorized(id, "shared", "read", 1) == nil {
		t.Fatal("expired grant accepted")
	}
	if _, err = s.DB.Exec("PRAGMA user_version=99"); err != nil {
		t.Fatal(err)
	}
	if err = s.migrate(); err == nil {
		t.Fatal("future schema accepted")
	}
}

func TestRemovePeerCleansGrantsEndpointsAndPreferences(t *testing.T) {
	t.Parallel()
	s, err := Open(t.TempDir() + "/state")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	id := strings.Repeat("e", 64)
	if err = s.TrustOutbound(id, "temp-laptop", "paired"); err != nil {
		t.Fatal(err)
	}
	if err = s.CacheEndpoint(id, "wlan0:10.0.0.2:10.0.0.0/24", "10.0.0.3:8731"); err != nil {
		t.Fatal(err)
	}
	if err = s.RecordRate(id, "direct-lan-v1", 12.5); err != nil {
		t.Fatal(err)
	}
	if err = s.RemovePeer(id); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Peer(id); err == nil {
		t.Fatal("removed peer still present")
	}
	if err = s.RemovePeer(id); err == nil {
		t.Fatal("removing absent peer succeeded")
	}
}
