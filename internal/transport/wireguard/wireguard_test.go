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

func TestLoadConfigRequiresImportAndStripsDefaultRoutes(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	if _, err := LoadConfig(dir); err == nil {
		t.Fatal("expected unconfigured state without .conf import")
	}
	// Legacy auto-generated config with 0 peers must still be treated as unconfigured.
	priv, pub, err := GenerateKeyPair()
	if err != nil {
		t.Fatal(err)
	}
	if err := SaveConfig(dir, Config{
		Backend:       BackendAuto,
		PrivateKey:    priv,
		PublicKey:     pub,
		LocalTunnelIP: "10.77.0.2/24",
		ListenPort:    51820,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadConfig(dir); err == nil {
		t.Fatal("expected legacy unimported 0-peer config to report not configured")
	}

	_, peerPub, err := GenerateKeyPair()
	if err != nil {
		t.Fatal(err)
	}
	conf := "[Interface]\n" +
		"PrivateKey = " + priv + "\n" +
		"Address = 10.66.66.5/24\n" +
		"DNS = 1.1.1.1\n\n" +
		"[Peer]\n" +
		"PublicKey = " + peerPub + "\n" +
		"Endpoint = dubai.example.com:51820\n" +
		"AllowedIPs = 0.0.0.0/0, ::/0\n" +
		"PersistentKeepalive = 25\n"

	imported, err := ImportConf(dir, conf)
	if err != nil {
		t.Fatalf("ImportConf failed: %v", err)
	}
	if !imported.Imported || !imported.DefaultRouteStripped {
		t.Fatalf("expected Imported and DefaultRouteStripped true: %+v", imported)
	}
	if len(imported.ScopedAllowedIPs) != 1 || imported.ScopedAllowedIPs[0] != "10.66.66.0/24" {
		t.Fatalf("expected strictly scoped internal tunnel subnet, got %v", imported.ScopedAllowedIPs)
	}
	loaded, err := LoadConfig(dir)
	if err != nil || loaded.PublicKey != pub || len(loaded.Peers) != 1 {
		t.Fatalf("LoadConfig after import failed: %+v err=%v", loaded, err)
	}
	p := &Provider{StateDir: dir, RemoteApproved: true, BackendMode: BackendKernel}
	if _, err := p.Dial(context.Background(), transport.Candidate{Endpoint: "8.8.8.8:8731"}); err == nil {
		t.Fatal("kernel WireGuard dial allowed outside scoped tunnel subnet")
	}
	if err := DeleteConfig(dir); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadConfig(dir); err == nil {
		t.Fatal("expected ErrNotConfigured after DeleteConfig")
	}
}
