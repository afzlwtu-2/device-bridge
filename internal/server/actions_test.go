package server

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"devicebridge/internal/auth"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/storage"
)

func TestAgentActionNeedsExactOneUseApproval(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	open := func(name string) (*storage.Store, *auth.Identity) {
		t.Helper()
		store, err := storage.Open(filepath.Join(root, name))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = store.Close() })
		id, err := auth.Load(store, name)
		if err != nil {
			t.Fatal(err)
		}
		return store, id
	}
	s, local := open("local")
	_, peer := open("peer")
	srv := New(s, local, &filesproviders.Registry{})
	srv.ActionState = filepath.Join(root, "local")
	handler := srv.Handler()
	cert, err := x509.ParseCertificate(peer.Certificate.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	const id = "11111111111111111111111111111111"
	const next = "22222222222222222222222222222222"
	query := func(preset, id string, status int) storage.ActionRequest {
		t.Helper()
		body, err := json.Marshal(map[string]string{"id": id, "preset": preset})
		if err != nil {
			t.Fatal(err)
		}
		r := httptest.NewRequest(http.MethodPost, "/v1/actions/request", strings.NewReader(string(body)))
		r.Header.Set("X-DeviceBridge-Version", "1")
		r.TLS = &tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != status {
			t.Fatalf("got status %d, wanted %d: %s", w.Code, status, w.Body.String())
		}
		var result storage.ActionRequest
		if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
			t.Fatal(err)
		}
		return result
	}
	query("agent-status", id, http.StatusForbidden)
	if err := s.TrustOutbound(peer.ID, "peer", "paired"); err != nil {
		t.Fatal(err)
	}
	query("shell", id, http.StatusBadRequest)
	if result := query("agent-status", id, http.StatusAccepted); result.State != "pending" || result.Output != "" {
		t.Fatal(result)
	}
	ctx := context.Background()
	if _, err := s.ApproveAction(ctx, peer.ID, "agent-status", next, time.Minute); err == nil {
		t.Fatal("an unrelated request ID received approval")
	}
	if _, err := s.ApproveAction(ctx, peer.ID, "agent-status", id, time.Minute); err != nil {
		t.Fatal(err)
	}
	receipt := query("agent-status", id, http.StatusOK)
	if receipt.State != "completed" || !strings.Contains(receipt.Output, "running") {
		t.Fatal(receipt)
	}
	if repeat := query("agent-status", id, http.StatusOK); receipt != repeat {
		t.Fatal("one-use retry did not return the original receipt")
	}
	var ran int
	if err := s.DB.QueryRow("SELECT count(*) FROM audit WHERE peer=? AND action='agent-action'", peer.ID).Scan(&ran); err != nil || ran != 1 {
		t.Fatalf("wanted one audited run, got %d: %v", ran, err)
	}
	query("agent-status", next, http.StatusAccepted)
	if _, err := s.RevokeAction(ctx, peer.ID, "agent-status", next); err != nil {
		t.Fatal(err)
	}
	query("agent-status", next, http.StatusForbidden)
	if err := s.Revoke(peer.ID); err != nil {
		t.Fatal(err)
	}
	query("agent-status", id, http.StatusForbidden)
	if err := s.RemovePeer(peer.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.TrustOutbound(peer.ID, "peer", "paired"); err != nil {
		t.Fatal(err)
	}
	if result := query("agent-status", id, http.StatusAccepted); result.Output != "" {
		t.Fatal("previous authorization survived peer revocation")
	}
}
