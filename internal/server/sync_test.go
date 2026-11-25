package server

import (
	"context"
	"crypto/rand"
	"devicebridge/internal/auth"
	"devicebridge/internal/client"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/storage"
	"devicebridge/internal/synccontrol"
	"devicebridge/internal/transport"
	"devicebridge/internal/transport/direct"
	"devicebridge/protocol"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type syncCountingTransport struct {
	http.RoundTripper
	count *atomic.Int64
}
type syncCountingBody struct {
	io.ReadCloser
	count *atomic.Int64
}

func (b syncCountingBody) Read(p []byte) (int, error) {
	n, e := b.ReadCloser.Read(p)
	b.count.Add(int64(n))
	return n, e
}
func (t syncCountingTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	response, e := t.RoundTripper.RoundTrip(r)
	if e == nil {
		response.Body = syncCountingBody{response.Body, t.count}
	}
	return response, e
}

// Run with DEVICEBRIDGE_TEST_SYNCTHING pointing at the pinned built engine.
// The controller is paired with both endpoints, which are not paired with each
// other. Its HTTP byte count proves that bulk content never crosses control RPC.
func TestControllerCoordinatesDirectSyncWithoutRelaying(t *testing.T) {
	engine := os.Getenv("DEVICEBRIDGE_TEST_SYNCTHING")
	if engine == "" {
		t.Skip("set DEVICEBRIDGE_TEST_SYNCTHING to run the real external-engine gate")
	}
	t.Setenv("DEVICEBRIDGE_SYNCTHING_BINARY", engine)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	root := t.TempDir()
	phone, e := storage.Open(filepath.Join(root, "controller"))
	if e != nil {
		t.Fatal(e)
	}
	defer phone.Close()
	phoneID, e := auth.Load(phone, "phone-controller")
	if e != nil {
		t.Fatal(e)
	}
	var controlBytes atomic.Int64
	type endpoint struct {
		store           *storage.Store
		id              *auth.Identity
		client          *client.Client
		address, folder string
		manager         *synccontrol.Manager
	}
	makeEndpoint := func(name string) endpoint {
		t.Helper()
		state := filepath.Join(root, name)
		store, e := storage.Open(state)
		if e != nil {
			t.Fatal(e)
		}
		t.Cleanup(func() { store.Close() })
		id, e := auth.Load(store, name)
		if e != nil {
			t.Fatal(e)
		}
		folder := filepath.Join(root, name+"-files")
		if e = os.MkdirAll(filepath.Join(folder, "folder"), 0700); e != nil {
			t.Fatal(e)
		}
		if e = store.Export("shared", folder); e != nil {
			t.Fatal(e)
		}
		if e = store.NewInvite(name, time.Now().Add(time.Minute)); e != nil {
			t.Fatal(e)
		}
		if e = store.RequestPair(name, phoneID.ID, "phone-controller"); e != nil {
			t.Fatal(e)
		}
		if e = store.Approve(phoneID.ID, []string{"shared"}, time.Hour, 1<<30); e != nil {
			t.Fatal(e)
		}
		if e = phone.TrustOutbound(id.ID, name, "paired"); e != nil {
			t.Fatal(e)
		}
		provider, e := filesproviders.NewNative("shared", folder)
		if e != nil {
			t.Fatal(e)
		}
		t.Cleanup(func() { provider.Close() })
		registry := &filesproviders.Registry{}
		if e = registry.Register(provider); e != nil {
			t.Fatal(e)
		}
		server := New(store, id, registry)
		server.Sync = synccontrol.New(ctx, state, store, registry)
		listener, e := net.Listen("tcp4", "127.0.0.1:0")
		if e != nil {
			t.Fatal(e)
		}
		t.Cleanup(func() { listener.Close() })
		go func() { _ = server.Serve(ctx, listener) }()
		transportProvider, e := direct.NewCIDR("lo", "127.0.0.1/8")
		if e != nil {
			t.Fatal(e)
		}
		cl := client.New(phoneID, phone, transportProvider, transport.Candidate{DeviceID: id.ID, Endpoint: listener.Addr().String()})
		t.Cleanup(cl.Close)
		cl.HTTP.Transport = syncCountingTransport{cl.HTTP.Transport, &controlBytes}
		return endpoint{store, id, cl, listener.Addr().String(), filepath.Join(folder, "folder"), server.Sync}
	}
	source, target := makeEndpoint("source"), makeEndpoint("target")
	target.manager.SocketAdapter = true
	t.Cleanup(func() {
		if t.Failed() {
			for _, name := range []string{"source", "target"} {
				raw, _ := os.ReadFile(filepath.Join(root, name, "syncthing-v1/session.log"))
				lines := strings.Split(string(raw), "\n")
				if len(lines) > 24 {
					lines = lines[len(lines)-24:]
				}
				t.Logf("%s engine log: %s", name, strings.Join(lines, "\n"))
			}
			entries, _ := os.ReadDir(target.folder)
			for _, entry := range entries {
				t.Logf("target entry: %s", entry.Name())
			}
			data, _ := os.ReadFile(filepath.Join(target.folder, ".hidden"))
			t.Logf("target hidden: %s", data)
		}
	})
	request := func(endpoint endpoint, op string, extra func(*protocol.SyncControl)) map[string]any {
		t.Helper()
		req := protocol.SyncControl{Operation: op, Root: "shared", Path: "folder", Group: "direct-pair"}
		if extra != nil {
			extra(&req)
		}
		raw, e := endpoint.client.SyncControl(ctx, req)
		if e != nil {
			t.Fatalf("%s: %v", op, e)
		}
		var value map[string]any
		if e = json.Unmarshal(raw, &value); e != nil {
			t.Fatal(e)
		}
		return value
	}
	if _, e = source.client.SyncControl(ctx, protocol.SyncControl{Operation: "prepare", Root: "shared", Path: "folder"}); e == nil {
		t.Fatal("controller prepared without sync delegation")
	}
	yes := true
	for _, endpoint := range []endpoint{source, target} {
		if _, e = endpoint.store.SyncControlAccess(phoneID.ID, &yes); e != nil {
			t.Fatal(e)
		}
	}
	infos := []map[string]any{request(source, "prepare", nil), request(target, "prepare", nil)}
	payload := make([]byte, 4<<20)
	if _, e = rand.Read(payload); e != nil {
		t.Fatal(e)
	}
	if e = os.MkdirAll(filepath.Join(source.folder, ".git"), 0700); e != nil {
		t.Fatal(e)
	}
	for name, data := range map[string][]byte{"payload.bin": payload, ".hidden": []byte("hidden"), ".git/config": []byte("git data"), "space λ.txt": []byte("unicode")} {
		if e = os.WriteFile(filepath.Join(source.folder, name), data, 0600); e != nil {
			t.Fatal(e)
		}
	}
	if e = os.Mkdir(filepath.Join(source.folder, "empty"), 0700); e != nil {
		t.Fatal(e)
	}
	request(source, "probe", func(r *protocol.SyncControl) {
		r.Interface = "lo"
		r.CIDR = "127.0.0.1/8"
		r.Listen = "127.0.0.1:22001"
		r.PeerEndpoint = target.address
		r.PeerDeviceID = target.id.ID
	})
	for i, endpoint := range []endpoint{source, target} {
		request(endpoint, "register", func(r *protocol.SyncControl) {
			r.Mode = "full"
			r.PeerID = infos[1-i]["device_id"].(string)
			r.Role = "sendonly"
			if i == 1 {
				r.Role = "receiveonly"
			}
		})
	}
	manifestInfo := request(source, "manifest", nil)
	manifest := manifestInfo["manifest_xxh64"].(string)
	manifestBytes := int64(manifestInfo["bytes"].(float64))
	for i, endpoint := range []endpoint{source, target} {
		request(endpoint, "start", func(r *protocol.SyncControl) {
			r.JobID = strings.Repeat(string(rune('a'+i)), 32)
			r.Interface = "lo"
			r.CIDR = "127.0.0.1/8"
			r.Manifest = manifest
			r.Bytes = manifestBytes
			r.Listen = []string{"127.0.0.1:22001", "127.0.0.1:22002"}[i]
			r.PeerEndpoint = []string{"127.0.0.1:22002", "127.0.0.1:22001"}[i]
			r.Seconds = 60
		})
	}
	verified := false
	for {
		complete := true
		for i, endpoint := range []endpoint{source, target} {
			job := request(endpoint, "status", func(r *protocol.SyncControl) { r.JobID = strings.Repeat(string(rune('a'+i)), 32) })
			if job["state"] == "interrupted" {
				t.Fatalf("sync job failed: %+v", job)
			}
			complete = complete && job["state"] == "verified"
		}
		if complete {
			verified = true
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		case <-time.After(200 * time.Millisecond):
		}
	}
	if !verified {
		t.Fatal("sync did not verify")
	}
	for _, name := range []string{"payload.bin", ".hidden", ".git/config", "space λ.txt"} {
		want, _ := os.ReadFile(filepath.Join(source.folder, name))
		got, e := os.ReadFile(filepath.Join(target.folder, name))
		if e != nil || string(got) != string(want) {
			t.Fatalf("%s differs: %v", name, e)
		}
	}
	if info, e := os.Stat(filepath.Join(target.folder, "empty")); e != nil || !info.IsDir() {
		t.Fatal("empty directory missing")
	}
	if controlBytes.Load() > 256<<10 {
		t.Fatalf("controller carried unexpected file data: %d bytes", controlBytes.Load())
	}
	t.Logf("4 MiB source delivered directly; controller received only %d control bytes; manifest %s", controlBytes.Load(), manifest)
	if e = os.WriteFile(filepath.Join(source.folder, ".hidden"), []byte("second full revision"), 0600); e != nil {
		t.Fatal(e)
	}
	secondManifestInfo := request(source, "manifest", nil)
	secondManifest := secondManifestInfo["manifest_xxh64"].(string)
	secondManifestBytes := int64(secondManifestInfo["bytes"].(float64))
	fullJobs := []string{strings.Repeat("f", 32), strings.Repeat("0", 32)}
	for i, endpoint := range []endpoint{source, target} {
		request(endpoint, "start", func(r *protocol.SyncControl) {
			r.JobID = fullJobs[i]
			r.Interface = "lo"
			r.CIDR = "127.0.0.1/8"
			r.Manifest = secondManifest
			r.Bytes = secondManifestBytes
			r.Listen = []string{"127.0.0.1:22001", "127.0.0.1:22002"}[i]
			r.PeerEndpoint = []string{"127.0.0.1:22002", "127.0.0.1:22001"}[i]
			r.Seconds = 40
		})
	}
	for {
		complete := true
		for i, endpoint := range []endpoint{source, target} {
			job := request(endpoint, "status", func(r *protocol.SyncControl) { r.JobID = fullJobs[i] })
			if job["state"] == "interrupted" {
				t.Fatalf("repeat full job failed: %+v", job)
			}
			complete = complete && job["state"] == "verified"
		}
		if complete {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		case <-time.After(200 * time.Millisecond):
		}
	}
	updated, e := os.ReadFile(filepath.Join(target.folder, ".hidden"))
	if e != nil || string(updated) != "second full revision" {
		t.Fatalf("full update missing: %s %v", updated, e)
	}
	versionsFull, _ := filepath.Glob(filepath.Join(target.folder, ".stversions", "*"))
	oldFullRetained := false
	for _, version := range versionsFull {
		data, _ := os.ReadFile(version)
		if string(data) == "hidden" {
			oldFullRetained = true
		}
	}
	if !oldFullRetained {
		t.Fatal("full update did not retain a Syncthing recovery version")
	}
	t.Logf("second full revision updated existing destination with versioning")
	// Change the existing pair to working mode. Import must update the selected
	// destination, keep its Git data and preserve a recovery copy of old content.
	for _, endpoint := range []endpoint{source, target} {
		request(endpoint, "mode", func(r *protocol.SyncControl) { r.Mode = "non-git"; r.Filter = "working" })
	}
	if e = os.WriteFile(filepath.Join(source.folder, "note.txt"), []byte("working update"), 0600); e != nil {
		t.Fatal(e)
	}
	if e = os.WriteFile(filepath.Join(target.folder, "note.txt"), []byte("old target"), 0600); e != nil {
		t.Fatal(e)
	}
	if e = os.WriteFile(filepath.Join(target.folder, ".git/config"), []byte("keep target git"), 0600); e != nil {
		t.Fatal(e)
	}
	workingManifestInfo := request(source, "manifest", nil)
	workingManifest := workingManifestInfo["manifest_xxh64"].(string)
	workingManifestBytes := int64(workingManifestInfo["bytes"].(float64))
	for i, endpoint := range []endpoint{source, target} {
		request(endpoint, "start", func(r *protocol.SyncControl) {
			r.JobID = strings.Repeat(string(rune('c'+i)), 32)
			r.Interface = "lo"
			r.CIDR = "127.0.0.1/8"
			r.Manifest = workingManifest
			r.Bytes = workingManifestBytes
			r.Listen = []string{"127.0.0.1:22001", "127.0.0.1:22002"}[i]
			r.PeerEndpoint = []string{"127.0.0.1:22002", "127.0.0.1:22001"}[i]
			r.Seconds = 60
		})
	}
	for {
		complete := true
		for i, endpoint := range []endpoint{source, target} {
			job := request(endpoint, "status", func(r *protocol.SyncControl) { r.JobID = strings.Repeat(string(rune('c'+i)), 32) })
			if job["state"] == "interrupted" {
				t.Fatalf("working job failed: %+v", job)
			}
			complete = complete && job["state"] == "verified"
		}
		if complete {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		case <-time.After(200 * time.Millisecond):
		}
	}
	for name, want := range map[string]string{"note.txt": "working update", ".git/config": "keep target git"} {
		got, e := os.ReadFile(filepath.Join(target.folder, name))
		if e != nil || string(got) != want {
			t.Fatalf("working import %s: %s %v", name, got, e)
		}
	}
	versions, _ := filepath.Glob(filepath.Join(target.folder, ".devicebridge-sync-recovery-*", "note.txt"))
	if len(versions) != 1 {
		t.Fatalf("recovery version missing: %v", versions)
	}
	old, _ := os.ReadFile(versions[0])
	if string(old) != "old target" {
		t.Fatal("target baseline lost")
	}
	if controlBytes.Load() > 256<<10 {
		t.Fatalf("working control RPC carried file data: %d", controlBytes.Load())
	}
	t.Logf("working mode imported into target, kept Git and recovery copy; total control bytes %d", controlBytes.Load())
	// With no source job, revoke an actively waiting receiver. It must close the
	// engine without relying on the controller to remain connected or send Stop.
	request(target, "start", func(r *protocol.SyncControl) {
		r.JobID = strings.Repeat("e", 32)
		r.Interface = "lo"
		r.CIDR = "127.0.0.1/8"
		r.Manifest = workingManifest
		r.Bytes = workingManifestBytes
		r.Listen = "127.0.0.1:22002"
		r.PeerEndpoint = "127.0.0.1:22003"
		r.Seconds = 30
	})
	no := false
	if _, e = target.store.SyncControlAccess(phoneID.ID, &no); e != nil {
		t.Fatal(e)
	}
	job, e := target.manager.Wait(ctx, strings.Repeat("e", 32))
	if e != nil || job.State != "interrupted" {
		t.Fatalf("revoked job: %+v %v", job, e)
	}
	if connection, e := net.DialTimeout("tcp4", "127.0.0.1:22002", time.Second); e == nil {
		connection.Close()
		t.Fatal("revocation left sync listener active")
	}
}
