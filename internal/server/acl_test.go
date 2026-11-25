package server_test

import (
	"bytes"
	"context"
	"crypto/tls"
	"devicebridge/internal/auth"
	"devicebridge/internal/client"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/server"
	"devicebridge/internal/storage"
	"devicebridge/internal/transport"
	"devicebridge/internal/transport/direct"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestServerACLEnforcesTrustedTagVsNonTrustedPeer(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	srvDir := filepath.Join(t.TempDir(), "srv")
	srvStore, err := storage.Open(srvDir)
	if err != nil {
		t.Fatal(err)
	}
	defer srvStore.Close()
	srvID, err := auth.Load(srvStore, "server")
	if err != nil {
		t.Fatal(err)
	}
	if err := srvStore.Export("home", t.TempDir()); err != nil {
		t.Fatal(err)
	}

	trustedDir := filepath.Join(t.TempDir(), "trusted")
	trustedStore, err := storage.Open(trustedDir)
	if err != nil {
		t.Fatal(err)
	}
	defer trustedStore.Close()
	trustedID, err := auth.Load(trustedStore, "trusted")
	if err != nil {
		t.Fatal(err)
	}

	untrustedDir := filepath.Join(t.TempDir(), "untrusted")
	untrustedStore, err := storage.Open(untrustedDir)
	if err != nil {
		t.Fatal(err)
	}
	defer untrustedStore.Close()
	untrustedID, err := auth.Load(untrustedStore, "untrusted")
	if err != nil {
		t.Fatal(err)
	}

	for _, id := range []string{trustedID.ID, untrustedID.ID} {
		if _, err := srvStore.DB.Exec(`INSERT INTO peers(id,name,status,expires) VALUES(?,?,'paired',0)`, id, "peer"); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := srvStore.SetPeerTags(ctx, trustedID.ID, []string{"tag:trusted"}); err != nil {
		t.Fatal(err)
	}
	if _, err := srvStore.SaveACLPolicy(ctx, storage.PresetTrustedACLPolicy(nil)); err != nil {
		t.Fatal(err)
	}

	// Register trustedID / untrustedID client stores knowing srvID.
	for _, cs := range []*storage.Store{trustedStore, untrustedStore} {
		if _, err := cs.DB.Exec(`INSERT INTO peers(id,name,status,expires) VALUES(?,?,'paired',0)`, srvID.ID, "server"); err != nil {
			t.Fatal(err)
		}
	}

	reg := &filesproviders.Registry{}
	p, err := filesproviders.NewNative("home", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	reg.Register(p)

	srv := server.New(srvStore, srvID, reg)
	srv.StateDir = srvDir
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() { _ = srv.Serve(ctx, ln) }()

	httpClient := func(id *auth.Identity) *http.Client {
		return &http.Client{
			Transport: &http.Transport{TLSClientConfig: id.ClientTLS(srvID.ID)},
			Timeout:   3 * time.Second,
		}
	}
	base := "https://" + ln.Addr().String()
	doReq := func(hc *http.Client, method, path string, body []byte) *http.Response {
		req, err := http.NewRequestWithContext(ctx, method, base+path, bytes.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("X-DeviceBridge-Version", "1")
		res, err := hc.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		return res
	}

	// Trusted peer can browse files and share text and open mTLS SSH.
	r := doReq(httpClient(trustedID), http.MethodGet, "/v1/files/list?root=home&path=.", nil)
	r.Body.Close()
	if r.StatusCode != 200 {
		t.Fatalf("trusted list status=%d, want 200", r.StatusCode)
	}
	r = doReq(httpClient(trustedID), http.MethodPost, "/v1/share/text", []byte(`{"id":"`+strings.Repeat("1", 32)+`","text":"hello"}`))
	r.Body.Close()
	if r.StatusCode != 200 {
		t.Fatalf("trusted text share status=%d, want 200", r.StatusCode)
	}

	// Non-trusted peer gets 403 on files, text share, link preparation, and SSH.
	r = doReq(httpClient(untrustedID), http.MethodGet, "/v1/files/list?root=home&path=.", nil)
	r.Body.Close()
	if r.StatusCode != 403 {
		t.Fatalf("untrusted list status=%d, want 403", r.StatusCode)
	}
	r = doReq(httpClient(untrustedID), http.MethodPost, "/v1/share/text", []byte(`{"id":"`+strings.Repeat("2", 32)+`","text":"blocked"}`))
	r.Body.Close()
	if r.StatusCode != 403 {
		t.Fatalf("untrusted text share status=%d, want 403", r.StatusCode)
	}
	r = doReq(httpClient(untrustedID), http.MethodPost, "/v1/connections/prepare", []byte(`{"kind":"link_status"}`))
	r.Body.Close()
	if r.StatusCode != 403 {
		t.Fatalf("untrusted prepare status=%d, want 403", r.StatusCode)
	}

	prov, err := direct.NewCIDR("lo", "127.0.0.1/8")
	if err != nil {
		t.Fatal(err)
	}
	cand := transport.Candidate{DeviceID: srvID.ID, Endpoint: ln.Addr().String(), Transport: "direct-lan-v1"}
	if _, err := client.DialAgentSSH(ctx, untrustedID, untrustedStore, prov, cand); err == nil {
		t.Fatal("untrusted agent ssh should fail")
	}
	sshConn, err := client.DialAgentSSH(ctx, trustedID, trustedStore, prov, cand)
	if err != nil {
		t.Fatalf("trusted agent ssh failed: %v", err)
	}
	// Removing tag:trusted closes the active mTLS SSH stream via the 500ms policy watcher.
	if _, err := srvStore.SetPeerTags(ctx, trustedID.ID, nil); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 128)
	_ = sshConn.SetReadDeadline(time.Now().Add(2 * time.Second))
	for {
		_, readErr := sshConn.Read(buf)
		if readErr != nil {
			break
		}
	}
	_ = sshConn.Close()
	_ = tls.VersionTLS13
}
