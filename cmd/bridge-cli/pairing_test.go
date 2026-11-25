package main

import (
	"context"
	"devicebridge/internal/auth"
	"devicebridge/internal/client"
	"devicebridge/internal/server"
	"devicebridge/internal/storage"
	"devicebridge/internal/transport"
	"devicebridge/internal/transport/direct"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestInvitationUsesLiveSelectedLANEndpoint(t *testing.T) {
	state := t.TempDir()
	raw := fmt.Sprintf(
		`{"running":true,"pid":%d,"endpoint":"192.168.1.7:41625","interface":"wlan0","cidr":"192.168.1.0/24"}`,
		os.Getpid(),
	)
	if err := os.WriteFile(filepath.Join(state, "agent-status.json"), []byte(raw), 0600); err != nil {
		t.Fatal(err)
	}
	if got := invitationLANEndpoint(state, "wlan0", "192.168.1.7/24"); got != "192.168.1.7:41625" {
		t.Fatalf("invitation endpoint = %q", got)
	}
	if got := invitationLANEndpoint(state, "wlan0", "192.168.1.8/24"); got != "" {
		t.Fatalf("included a stale local address: %q", got)
	}
}

func TestPairingRouteSendsAndFinishesWithoutMulticast(t *testing.T) {
	inviterStore, err := storage.Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer inviterStore.Close()
	inviter, err := auth.Load(inviterStore, "Inviter")
	if err != nil {
		t.Fatal(err)
	}
	requesterStore, err := storage.Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer requesterStore.Close()
	requester, err := auth.Load(requesterStore, "Requester")
	if err != nil {
		t.Fatal(err)
	}
	p, err := direct.NewCIDR("lo", "127.0.0.1/8")
	if err != nil {
		t.Fatal(err)
	}
	p.Discovery = func(context.Context) ([]transport.Candidate, error) {
		return nil, errors.New("multicast unavailable")
	}
	ctx, cancel := context.WithCancel(context.Background())
	listener, err := p.Listen(ctx, "127.0.0.1:0")
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- server.New(inviterStore, inviter, nil).Serve(ctx, listener) }()
	defer func() {
		cancel()
		if err := <-done; err != nil {
			t.Error(err)
		}
	}()
	inv, err := inviter.Invite(inviterStore)
	if err != nil {
		t.Fatal(err)
	}
	inv.LANEndpoint = listener.Addr().String()
	c := command{ctx: ctx, provider: p, selectedTransport: "lan", identity: requester, state: requesterStore}
	request := func(ctx context.Context, cl *client.Client, _ transport.Candidate) error {
		_, err := cl.RequestPair(ctx, inv, requester.Name)
		return err
	}
	if err := c.withPairingRoute(inv.ID, inv.LANEndpoint, request); err != nil {
		t.Fatal(err)
	}
	finish := func(ctx context.Context, cl *client.Client, _ transport.Candidate) error { return cl.FinishPair(ctx) }
	if err := c.withPairingRoute(inv.ID, inv.LANEndpoint, finish); err == nil {
		t.Fatal("pairing finished without remote approval")
	}
	if err := inviterStore.Approve(requester.ID, nil, time.Minute, 1); err != nil {
		t.Fatal(err)
	}
	if err := c.withPairingRoute(inv.ID, inv.LANEndpoint, finish); err != nil {
		t.Fatal(err)
	}
	peer, err := requesterStore.Peer(inv.ID)
	if err != nil || peer.Status != "paired" {
		t.Fatalf("requester peer = %+v, %v", peer, err)
	}
}
