package storage

import (
	"fmt"
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

func TestFreshInvitationRenewsPendingPairing(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	id := strings.Repeat("a", 64)
	request := func(token string) error {
		if err := s.NewInvite(token, time.Now().Add(time.Minute)); err != nil {
			t.Fatal(err)
		}
		return s.RequestPair(token, id, "phone")
	}
	if err := request("initial"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.DB.Exec("UPDATE peers SET expires=0 WHERE id=?", id); err != nil {
		t.Fatal(err)
	}
	if err := request("replacement"); err != nil {
		t.Fatal(err)
	}
	if err := s.Approve(id, nil, time.Minute, 1); err != nil {
		t.Fatal(err)
	}
	if err := request("already paired"); err == nil {
		t.Fatal("a new invitation overwrote an active pairing")
	}
	if err := s.Revoke(id); err != nil {
		t.Fatal(err)
	}
	if err := request("revoked"); err == nil {
		t.Fatal("a new invitation revived a revoked pairing")
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
	actions, err := s.PeerActions(id, []PeerAction{
		{ID: "a1", Label: "Uptime", Kind: "command", Command: "uptime"},
		{ID: "t1", Label: "Agent", Kind: "toggle", Command: "start", OffCommand: "stop", Active: true},
	}, true)
	if err != nil || len(actions) != 2 {
		t.Fatalf("PeerActions save failed: %+v err=%v", actions, err)
	}
	loaded, err := s.PeerActions(id, nil, false)
	if err != nil || len(loaded) != 2 || !loaded[1].Active {
		t.Fatalf("PeerActions reload failed: %+v err=%v", loaded, err)
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

func TestConnectionPreservesPerTransportEndpoints(t *testing.T) {
	t.Parallel()
	s, err := Open(t.TempDir() + "/state")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	id := strings.Repeat("f", 64)
	if err = s.TrustOutbound(id, "probook", "paired"); err != nil {
		t.Fatal(err)
	}
	saved, err := s.Connection(id, &Connection{
		Transport:          "tailnet",
		PreferredTransport: "auto",
		PreferredLink:      "wifi",
		Endpoint:           "100.100.78.84:8731",
		LanEndpoint:        "192.168.1.23:8731",
		TailnetEndpoint:    "100.100.78.84:8731",
		AdbEndpoint:        "127.0.0.1:18731",
		RemoteApproved:     true,
		FallbackApproved:   true,
		FallbackTransports: []string{"lan", "adb", "tailnet"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if saved.TailnetEndpoint != "100.100.78.84:8731" || saved.LanEndpoint != "192.168.1.23:8731" {
		t.Fatalf("unexpected saved endpoints: %+v", saved)
	}
	switched, err := s.Connection(id, &Connection{
		Transport:          "lan",
		PreferredTransport: saved.PreferredTransport,
		PreferredLink:      saved.PreferredLink,
		LanEndpoint:        saved.LanEndpoint,
		TailnetEndpoint:    saved.TailnetEndpoint,
		AdbEndpoint:        saved.AdbEndpoint,
		RemoteApproved:     true,
		FallbackApproved:   true,
		FallbackTransports: []string{"lan", "adb", "tailnet"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if switched.PreferredLink != "wifi" || switched.PreferredTransport != "auto" || switched.Transport != "lan" || switched.TailnetEndpoint != "100.100.78.84:8731" || switched.AdbEndpoint != "127.0.0.1:18731" {
		t.Fatalf("switching to lan lost saved endpoints: %+v", switched)
	}
}

func TestVerifiedRoutesKeepPreferenceAndBulkConsent(t *testing.T) {
	t.Parallel()
	s, err := Open(t.TempDir() + "/state")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	peer := strings.Repeat("c", 64)
	if err := s.TrustOutbound(peer, "laptop", "paired"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Connection(peer, &Connection{
		Transport: "tailnet", PreferredTransport: "tailnet",
		Endpoint: "100.100.78.84:8731", FallbackApproved: true,
		FallbackTransports: []string{"lan", "adb", "ssh", "tailnet"},
	}); err != nil {
		t.Fatal(err)
	}
	for kind, ep := range map[string]string{
		"lan": "192.168.1.23:8731", "wireguard": "10.13.0.2:8731",
		"adb": "127.0.0.1:18731",
	} {
		if err := s.RecordVerifiedEndpoint(peer, kind, ep); err != nil {
			t.Fatal(err)
		}
	}
	cfg, err := s.Connection(peer, nil)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.PreferredTransport != "tailnet" || cfg.Transport != "tailnet" ||
		cfg.RemoteApproved || cfg.AdbEndpoint != "" || cfg.LanEndpoint != "192.168.1.23:8731" ||
		cfg.WireGuardEndpoint != "10.13.0.2:8731" ||
		strings.Join(cfg.FallbackTransports, ",") != "lan,tailnet" {
		t.Fatalf("unexpected route state: %+v", cfg)
	}
}

func TestPeerAndHostSSHPersistenceRules(t *testing.T) {
	t.Parallel()
	s, err := Open(t.TempDir() + "/state")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	id := strings.Repeat("a", 64)
	if err = s.TrustOutbound(id, "laptop", "paired"); err != nil {
		t.Fatal(err)
	}

	// The LAN profile preserves trust metadata and discards the PEM.
	lanSaved, err := s.PeerSSH(id, &PeerSSHProfile{
		Host:            "192.168.1.50",
		Port:            22,
		User:            "afzl",
		ExpectedHostKey: "SHA256:lankey",
		ViaTailnet:      false,
		PrivateKeyPEM:   "-----BEGIN OPENSSH PRIVATE KEY-----\nTESTKEY\n-----END OPENSSH PRIVATE KEY-----",
	})
	if err != nil {
		t.Fatal(err)
	}
	if lanSaved.User != "afzl" || lanSaved.PrivateKeyPEM != "" {
		t.Fatalf("expected LAN metadata without the key, got %+v", lanSaved)
	}

	// Tailscale target strips PrivateKeyPEM and saves username/host/host-key only.
	tsSaved, err := s.HostSSH("probook", &PeerSSHProfile{
		Host:            "probook",
		Port:            22,
		User:            "afzl",
		ExpectedHostKey: "SHA256:tskey",
		ViaTailnet:      true,
		PrivateKeyPEM:   "-----BEGIN OPENSSH PRIVATE KEY-----\nSHOULDNOTSAVE\n-----END OPENSSH PRIVATE KEY-----",
	})
	if err != nil {
		t.Fatal(err)
	}
	if tsSaved.User != "afzl" || !tsSaved.ViaTailnet || tsSaved.PrivateKeyPEM != "" {
		t.Fatalf("expected Tailscale profile to save username only with empty key, got %+v", tsSaved)
	}
	reloaded, err := s.HostSSH("probook", nil)
	if err != nil || reloaded.User != "afzl" || reloaded.PrivateKeyPEM != "" {
		t.Fatalf("unexpected reloaded HostSSH profile: %+v err=%v", reloaded, err)
	}
}

func TestCacheEndpointLimitsSavedAddressesToFive(t *testing.T) {
	t.Parallel()
	s, err := Open(t.TempDir() + "/state")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	id := strings.Repeat("b", 64)
	if err = s.TrustOutbound(id, "laptop", "paired"); err != nil {
		t.Fatal(err)
	}
	for i := 1; i <= 8; i++ {
		ep := fmt.Sprintf("192.168.1.%d:8731", 10+i)
		if err = s.CacheEndpoint(id, "lan", ep); err != nil {
			t.Fatal(err)
		}
	}
	records, err := s.EndpointRecords(id)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 5 {
		t.Fatalf("expected 5 retained saved addresses, got %d (%+v)", len(records), records)
	}
}

func TestPeerAliasAndLastHandshakePreserveIdentityAndRoute(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	id := strings.Repeat("f", 64)
	if err := s.TrustOutbound(id, "Published name", "paired"); err != nil {
		t.Fatal(err)
	}
	if err := s.RenamePeer(id, " Travel phone "); err != nil {
		t.Fatal(err)
	}
	peer, err := s.Peer(id)
	if err != nil || peer.ID != id || peer.Name != "Published name" || peer.Alias != "Travel phone" {
		t.Fatalf("unexpected peer after rename: %+v, %v", peer, err)
	}
	when := time.Unix(1700000000, 0)
	s.RecordHandshake(id, when)
	s.RecordHandshake(id, when.Add(-time.Minute))
	connection, err := s.Connection(id, nil)
	if err != nil || connection.Transport != "lan" || connection.LastHandshakeAt != when.Unix() {
		t.Fatalf("unexpected connection: %+v, %v", connection, err)
	}
	if err := s.Revoke(id); err != nil {
		t.Fatal(err)
	}
	if err := s.RenamePeer(id, "another name"); err != ErrDenied {
		t.Fatalf("rename of revoked peer returned %v", err)
	}
}
