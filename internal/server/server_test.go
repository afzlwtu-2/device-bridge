package server

import (
	"context"
	"devicebridge/internal/auth"
	"devicebridge/internal/client"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/storage"
	"devicebridge/internal/transport"
	"devicebridge/internal/transport/direct"
	"devicebridge/protocol"
	"net"
	"path/filepath"
	"testing"
	"time"
)

func TestDeviceCapabilitiesAndConnectionsPrepareAuth(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	srvStore, err := storage.Open(filepath.Join(dir, "srv"))
	if err != nil {
		t.Fatal(err)
	}
	defer srvStore.Close()
	srvID, err := auth.Load(srvStore, "probook")
	if err != nil {
		t.Fatal(err)
	}
	cliStore, err := storage.Open(filepath.Join(dir, "cli"))
	if err != nil {
		t.Fatal(err)
	}
	defer cliStore.Close()
	cliID, err := auth.Load(cliStore, "phone")
	if err != nil {
		t.Fatal(err)
	}

	if err := srvStore.TrustOutbound(cliID.ID, "phone", "paired"); err != nil {
		t.Fatal(err)
	}
	if err := cliStore.TrustOutbound(srvID.ID, "probook", "paired"); err != nil {
		t.Fatal(err)
	}

	srv := New(srvStore, srvID, &filesproviders.Registry{})
	srv.Capabilities = func(context.Context) *protocol.DeviceCapabilities {
		return &protocol.DeviceCapabilities{
			OS:         "linux",
			Wifi5GHz:   true,
			Wifi6:      true,
			WifiDirect: true,
			HotspotAP:  true,
			HotspotSTA: true,
			USBAdb:     true,
		}
	}
	var gotKind string
	srv.PrepareLink = func(_ context.Context, req protocol.ConnectionPrepareRequest) (protocol.ConnectionPrepareResult, error) {
		gotKind = req.Kind
		return protocol.ConnectionPrepareResult{
			OK:        true,
			Kind:      req.Kind,
			Transport: "adb",
			Endpoint:  "127.0.0.1:18731",
			Status:    "ready",
		}, nil
	}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = srv.Serve(ctx, ln) }()

	prov, err := direct.NewCIDR("lo", "127.0.0.1/8")
	if err != nil {
		t.Fatal(err)
	}
	cl := client.New(cliID, cliStore, prov, transport.Candidate{
		DeviceID:  srvID.ID,
		Endpoint:  ln.Addr().String(),
		Interface: "lo",
		Transport: prov.ID(),
	})
	defer cl.Close()

	var dev protocol.Device
	if err := cl.JSON(ctx, "/v1/device", nil, &dev); err != nil {
		t.Fatal(err)
	}
	if dev.Capabilities == nil || !dev.Capabilities.Wifi6 || !dev.Capabilities.WifiDirect || !dev.Capabilities.USBAdb {
		t.Fatalf("unexpected device capabilities: %+v", dev.Capabilities)
	}

	var prep protocol.ConnectionPrepareResult
	if err := cl.PostJSON(ctx, "/v1/connections/prepare", protocol.ConnectionPrepareRequest{Kind: "adb_usb"}, &prep); err != nil {
		t.Fatal(err)
	}
	if gotKind != "adb_usb" || !prep.OK || prep.Endpoint != "127.0.0.1:18731" {
		t.Fatalf("unexpected prepare result: kind=%q res=%+v", gotKind, prep)
	}

	st, err := cl.SpeedTest(ctx, 1)
	if err != nil {
		t.Fatal(err)
	}
	if st.Bytes <= 0 || st.MiBPerSecond <= 0 || st.Seconds <= 0 {
		t.Fatalf("unexpected speedtest result: %+v", st)
	}
}

func TestClosingListenerCancelsItsRequests(t *testing.T) {
	dir := t.TempDir()
	srvStore, err := storage.Open(filepath.Join(dir, "server"))
	if err != nil {
		t.Fatal(err)
	}
	defer srvStore.Close()
	srvID, err := auth.Load(srvStore, "server")
	if err != nil {
		t.Fatal(err)
	}
	cliStore, err := storage.Open(filepath.Join(dir, "client"))
	if err != nil {
		t.Fatal(err)
	}
	defer cliStore.Close()
	cliID, err := auth.Load(cliStore, "client")
	if err != nil {
		t.Fatal(err)
	}
	if err := srvStore.TrustOutbound(cliID.ID, "client", "paired"); err != nil {
		t.Fatal(err)
	}
	if err := cliStore.TrustOutbound(srvID.ID, "server", "paired"); err != nil {
		t.Fatal(err)
	}

	entered := make(chan struct{})
	srv := New(srvStore, srvID, &filesproviders.Registry{})
	srv.Capabilities = func(ctx context.Context) *protocol.DeviceCapabilities {
		close(entered)
		<-ctx.Done()
		return nil
	}
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	parent, cancel := context.WithCancel(context.Background())
	defer cancel()
	served := make(chan error, 1)
	go func() { served <- srv.Serve(parent, ln) }()

	provider, err := direct.NewCIDR("lo", "127.0.0.1/8")
	if err != nil {
		t.Fatal(err)
	}
	cl := client.New(cliID, cliStore, provider, transport.Candidate{
		DeviceID: srvID.ID,
		Endpoint: ln.Addr().String(),
	})
	defer cl.Close()
	ctx, timeout := context.WithTimeout(parent, 3*time.Second)
	defer timeout()
	requestDone := make(chan struct{})
	go func() {
		defer close(requestDone)
		_ = cl.JSON(ctx, "/v1/device", nil, new(protocol.Device))
	}()
	select {
	case <-entered:
	case <-ctx.Done():
		t.Fatal("request did not reach the listener")
	}
	if err := ln.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-served:
		if got := srv.Stats.Snapshot(); got.ActiveRequests != 0 || got.ActiveConns != 0 {
			t.Fatalf("retired listener still owns resources: %+v", got)
		}
	case <-ctx.Done():
		t.Fatal("listener did not shut down")
	}
	<-requestDone
}
