package storage

import (
	"context"
	"devicebridge/protocol"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestACLTrustedTagVsNonTrustedDefaultDeny(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()

	trustedID := strings.Repeat("a", 64)
	untrustedID := strings.Repeat("b", 64)
	guestID := strings.Repeat("c", 64)
	for _, p := range []struct {
		id, name string
	}{{trustedID, "Trusted Laptop"}, {untrustedID, "Other Box"}, {guestID, "Guest Phone"}} {
		if _, err := s.DB.Exec(`INSERT INTO peers(id,name,status,expires) VALUES(?,?, 'paired', 0)`, p.id, p.name); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.Export("home", t.TempDir()); err != nil {
		t.Fatal(err)
	}

	if _, err := s.SetPeerTags(ctx, trustedID, []string{"trusted"}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SetPeerTags(ctx, guestID, []string{"tag:guest"}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SaveACLPolicy(ctx, PresetTrustedACLPolicy(nil)); err != nil {
		t.Fatal(err)
	}

	// Trusted device can access all resources even without legacy per-peer toggles.
	if err := s.Authorized(trustedID, "home", "read", 128); err != nil {
		t.Fatalf("trusted file read denied: %v", err)
	}
	if acc, err := s.AgentSSHAccess(ctx, trustedID, ""); err != nil || !acc.Allowed {
		t.Fatalf("trusted ssh denied: acc=%+v err=%v", acc, err)
	}
	if ok, err := s.TextShareAccess(trustedID, nil); err != nil || !ok {
		t.Fatalf("trusted text share denied: ok=%v err=%v", ok, err)
	}
	if ok, err := s.TermuxFilesAccess(trustedID, nil); err != nil || !ok {
		t.Fatalf("trusted termux files denied: ok=%v err=%v", ok, err)
	}

	// Non-trusted device is denied everything under Tailscale-style default-deny,
	// even if a legacy file grant exists.
	if _, err := s.DB.Exec(`INSERT INTO grants(peer,root,browse,read,expires,quota) VALUES(?,'home',1,1,?,100000)`, untrustedID, time.Now().Add(time.Hour).Unix()); err != nil {
		t.Fatal(err)
	}
	if err := s.Authorized(untrustedID, "home", "browse", 0); err != ErrDenied {
		t.Fatalf("untrusted browse = %v, want ErrDenied", err)
	}
	if acc, err := s.AgentSSHAccess(ctx, untrustedID, "request"); err != nil || acc.Allowed {
		t.Fatalf("untrusted ssh = %+v, want denied", acc)
	}
	if _, err := s.ReceiveText(untrustedID, protocol.TextShareRequest{ID: strings.Repeat("1", 32), Text: "hi"}); err != ErrDenied {
		t.Fatalf("untrusted text receive = %v, want ErrDenied", err)
	}

	// Guest tag gets only browse + share:text, not read or ssh.
	if err := s.Authorized(guestID, "home", "browse", 0); err != nil {
		t.Fatalf("guest browse denied: %v", err)
	}
	if err := s.Authorized(guestID, "home", "read", 10); err != ErrDenied {
		t.Fatalf("guest read = %v, want ErrDenied", err)
	}
	if _, err := s.ReceiveText(guestID, protocol.TextShareRequest{ID: strings.Repeat("2", 32), Text: "hello"}); err != nil {
		t.Fatalf("guest text receive denied: %v", err)
	}
	if acc, err := s.AgentSSHAccess(ctx, guestID, ""); err != nil || acc.Allowed {
		t.Fatalf("guest ssh = %+v, want denied", acc)
	}
}

func TestACLGroupsExplicitDenyOverridesAcceptAndRevokeCleans(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()

	peerID := strings.Repeat("d", 64)
	if _, err := s.DB.Exec(`INSERT INTO peers(id,name,status,expires) VALUES(?,?, 'paired', 0)`, peerID, "Dev"); err != nil {
		t.Fatal(err)
	}
	policy := ACLPolicy{
		Version: 1,
		Enabled: true,
		Groups:  map[string][]string{"group:dev": {peerID}},
		Rules: []ACLRule{
			{ID: "allow-dev", Action: "accept", Src: []string{"group:dev"}, Dst: []string{"*"}},
			{ID: "block-ssh", Action: "deny", Src: []string{"peer:" + peerID}, Dst: []string{"ssh"}},
		},
	}
	if _, err := s.SaveACLPolicy(ctx, policy); err != nil {
		t.Fatal(err)
	}
	eval, err := s.EvaluatePeerACL(ctx, peerID)
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range eval.Decisions {
		if d.Resource == "ssh" && d.Allowed {
			t.Fatal("explicit deny did not override group accept for ssh")
		}
		if d.Resource == "files:read" && !d.Allowed {
			t.Fatalf("group:dev should allow files:read: %+v", d)
		}
	}

	if err := s.Revoke(peerID); err != nil {
		t.Fatal(err)
	}
	loaded, err := s.ACLPolicy(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(loaded.Groups["group:dev"]) != 0 {
		t.Fatalf("revoke did not remove peer from ACL groups: %+v", loaded.Groups)
	}
}
