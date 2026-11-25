package server

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"devicebridge/internal/auth"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/storage"
	"devicebridge/protocol"
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestPrepareLinkFailureRollsBackLease(t *testing.T) {
	s, err := storage.Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	id, err := auth.Load(s, "server")
	if err != nil {
		t.Fatal(err)
	}
	cs, err := storage.Open(filepath.Join(t.TempDir(), "client"))
	if err != nil {
		t.Fatal(err)
	}
	defer cs.Close()
	cliID, err := auth.Load(cs, "client")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.DB.Exec("INSERT INTO peers(id,name,status,expires) VALUES(?,?,?,0)", cliID.ID, "peer", "paired"); err != nil {
		t.Fatal(err)
	}
	var restoreCalls atomic.Int32
	srv := New(s, id, &filesproviders.Registry{})
	srv.PrepareLink = func(context.Context, protocol.ConnectionPrepareRequest) (protocol.ConnectionPrepareResult, error) {
		return protocol.ConnectionPrepareResult{}, errors.New("boom")
	}
	srv.RestoreLink = func(context.Context) (protocol.ConnectionPrepareResult, error) {
		restoreCalls.Add(1)
		return protocol.ConnectionPrepareResult{OK: true}, nil
	}
	opID := strings.Repeat("e", 32)
	req := httptest.NewRequest(http.MethodPost, "/v1/connections/prepare", strings.NewReader(`{"kind":"wifi_join","operation_id":"`+opID+`","lease_seconds":60}`))
	req.Header.Set("X-DeviceBridge-Version", "1")
	req.TLS = &tls.ConnectionState{PeerCertificates: []*x509.Certificate{cliID.Certificate.Leaf}}
	rec := httptest.NewRecorder()
	srv.prepareConnection(rec, req)
	if rec.Code != 400 {
		t.Fatalf("status=%d, want 400", rec.Code)
	}
	if restoreCalls.Load() != 1 {
		t.Fatalf("restoreCalls=%d, want 1", restoreCalls.Load())
	}
	lease, err := s.LinkLease(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if lease.Stage != "restored" {
		t.Fatalf("lease.Stage=%q, want restored", lease.Stage)
	}
}

func TestExpiredLinkLeaseRestoresOnceAcrossListeners(t *testing.T) {
	s, err := storage.Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	id := strings.Repeat("d", 32)
	if _, err = s.ChangeLinkLease(ctx, "peer", id, "begin", 15); err != nil {
		t.Fatal(err)
	}
	if _, err = s.DB.Exec("UPDATE preferences SET value=json_set(value,'$.deadline_utc',?) WHERE key='remote-link-lease-v1'", time.Now().Unix()-1); err != nil {
		t.Fatal(err)
	}
	var calls atomic.Int32
	srv := &Server{Store: s, RestoreLink: func(context.Context) (protocol.ConnectionPrepareResult, error) {
		calls.Add(1)
		return protocol.ConnectionPrepareResult{OK: true}, nil
	}}
	go srv.watchLinkLease(ctx)
	go srv.watchLinkLease(ctx)
	until := time.Now().Add(3 * time.Second)
	for time.Now().Before(until) {
		lease, _ := s.LinkLease(ctx)
		if lease.Stage == "restored" {
			if calls.Load() != 1 {
				t.Fatal("duplicate restoration")
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("expired persisted lease was not restored")
}
