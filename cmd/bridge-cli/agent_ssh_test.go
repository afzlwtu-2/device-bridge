package main

import (
	"context"
	"devicebridge/internal/auth"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/server"
	"devicebridge/internal/storage"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestMatchAgentSSHPeer(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	s, err := storage.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	id1 := "fddaaa9d240b3ddda2e9ede82c26045d0df442ed52b6322fa7f447037436a105"
	id2 := "fbda8373cc63eb130424f3b28879afe278ac699e13eb8bd2c367fc3905898993"
	if _, err := s.DB.Exec(`INSERT INTO peers(id,name,status,expires) VALUES(?,?,?,0)`, id1, "V2427", "paired"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.DB.Exec(`INSERT INTO peers(id,name,status,expires) VALUES(?,?,?,0)`, id2, "Pending Box", "pending"); err != nil {
		t.Fatal(err)
	}

	if p, ok := matchAgentSSHPeer(s, "vivo-v50"); !ok || p.ID != id1 {
		t.Fatalf("expected display slug match for V2427 -> vivo-v50, got ok=%v peer=%+v", ok, p)
	}
	if p, ok := matchAgentSSHPeer(s, "db.fddaaa9d"); !ok || p.ID != id1 {
		t.Fatalf("expected db. prefix match, got ok=%v peer=%+v", ok, p)
	}
	if _, ok := matchAgentSSHPeer(s, "pending-box"); ok {
		t.Fatal("pending peer must not match agent-ssh-match")
	}
}

func TestNormalizeAgentSSHTransport(t *testing.T) {
	cases := map[string]string{
		"":                  "",
		"auto":              "",
		"lan":               "lan",
		"direct-lan-v1":     "lan",
		"direct-hotspot-v1": "lan",
		"wifi-direct-v1":    "lan",
		"wireguard-v1":      "wireguard",
		"tailscale-v1":      "tailnet",
		"tailscale":         "tailnet",
		"adb-v1":            "adb",
		"usb":               "adb",
	}
	for input, want := range cases {
		if got := normalizeAgentSSHTransport(input); got != want {
			t.Fatalf("normalizeAgentSSHTransport(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestAgentSSHApprovalDenialIsNotReplacedByStaleEndpointError(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	dir := filepath.Join(t.TempDir(), "server")
	ss, err := storage.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer ss.Close()
	sid, err := auth.Load(ss, "server")
	if err != nil {
		t.Fatal(err)
	}
	cd := filepath.Join(t.TempDir(), "client")
	cs, err := storage.Open(cd)
	if err != nil {
		t.Fatal(err)
	}
	defer cs.Close()
	cid, err := auth.Load(cs, "client")
	if err != nil {
		t.Fatal(err)
	}
	for _, record := range []struct {
		s  *storage.Store
		id string
	}{{ss, cid.ID}, {cs, sid.ID}} {
		if _, err = record.s.DB.Exec("INSERT INTO peers(id,name,status,expires) VALUES(?,?,?,0)", record.id, "fixture", "paired"); err != nil {
			t.Fatal(err)
		}
	}
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	srv := server.New(ss, sid, &filesproviders.Registry{})
	srv.StateDir = dir
	go srv.Serve(ctx, ln)
	if err = cs.CacheEndpoint(sid.ID, "fixture", "127.0.0.1:1"); err != nil {
		t.Fatal(err)
	}
	conn, _, err := dialAgentSSHStream(ctx, cs, cid, sid.ID, cd, "lo", "127.0.0.1/8", "", "auto", "auto", false, "lan", ln.Addr().String())
	if conn != nil {
		conn.Close()
	}
	if err == nil || !strings.Contains(err.Error(), "ssh_approval_required") {
		t.Fatalf("lost authenticated approval rejection: %v", err)
	}
}

func TestParseSSHLinkInterfaces(t *testing.T) {
	sample := "Linux\n1: lo    inet 127.0.0.1/8 scope host lo\n2: wlan0 inet 192.168.1.40/24 brd 192.168.1.255 scope global wlan0\n3: tailscale0 inet 100.101.102.5/32 scope global tailscale0\n4: wg0 inet 10.66.0.2/24 scope global wg0\n"
	osName, links := parseSSHLinkInterfaces(sample)
	if osName != "Linux" {
		t.Fatalf("os=%q, want Linux", osName)
	}
	if len(links) != 3 {
		t.Fatalf("len(links)=%d, want 3: %+v", len(links), links)
	}
	if links[0].Kind != "wifi" || links[1].Kind != "tailnet" || links[2].Kind != "wireguard" {
		t.Fatalf("unexpected link kinds: %+v", links)
	}
}
