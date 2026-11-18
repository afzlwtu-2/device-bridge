package wireguard

import (
	"context"
	"devicebridge/internal/transport"
	"net"
	"testing"
)

func TestBackendSelectionAndDirectLANFirst(t *testing.T) {
	t.Parallel()
	if got := DetectBackend(BackendUserspace); got != BackendUserspace {
		t.Fatalf("expected userspace, got %q", got)
	}
	if got := DetectBackend(BackendKernel); got != BackendKernel {
		t.Fatalf("expected kernel when forced, got %q", got)
	}

	dir := t.TempDir()
	cfg, err := LoadOrInitConfig(dir, "10.77.0.2/24", 51820)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.PublicKey == "" || cfg.PrivateKey == "" {
		t.Fatal("expected generated X25519 keypair")
	}

	// Spin up a local listener simulating peer direct LAN endpoint
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	accepted := make(chan string, 1)
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		accepted <- "direct-lan-ok"
		_ = c.Close()
	}()

	if _, err = UpsertPeer(dir, PeerConfig{
		PeerID:            "laptop1",
		Name:              "probook",
		PublicKey:         cfg.PublicKey,
		TunnelIP:          "10.77.0.1",
		DirectLANEndpoint: ln.Addr().String(),
		ServerEndpoint:    "203.0.113.10:51820",
	}); err != nil {
		t.Fatal(err)
	}

	p := &Provider{StateDir: dir, RemoteApproved: false}
	cand, err := p.Probe(context.Background(), transport.Candidate{DeviceID: "laptop1", Endpoint: "10.77.0.1:8731"})
	if err != nil {
		t.Fatal(err)
	}
	if cand.PathKind != "direct-lan" || !cand.Direct || cand.Endpoint != ln.Addr().String() {
		t.Fatalf("expected direct-lan bypass of server hop, got %+v", cand)
	}
	conn, err := p.Dial(context.Background(), cand)
	if err != nil {
		t.Fatal(err)
	}
	_ = conn.Close()
	if got := <-accepted; got != "direct-lan-ok" {
		t.Fatalf("unexpected direct dial result: %q", got)
	}
}
