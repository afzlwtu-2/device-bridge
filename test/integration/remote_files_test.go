package integration

import (
	"bytes"
	"context"
	"devicebridge/internal/auth"
	"devicebridge/internal/client"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/server"
	"devicebridge/internal/storage"
	"devicebridge/internal/transfer"
	"devicebridge/internal/transport"
	"devicebridge/protocol"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeTransport exercises a stream provider whose identifier is unrelated to LAN.
type fakeTransport struct{ address string }

func (*fakeTransport) ID() string { return "test-stream-v1" }
func (*fakeTransport) Capabilities() transport.Capabilities {
	return transport.Capabilities{Version: 1, Streams: true}
}
func (*fakeTransport) DiscoverCandidates(context.Context) ([]transport.Candidate, error) {
	return nil, nil
}
func (*fakeTransport) Probe(_ context.Context, c transport.Candidate) (transport.Candidate, error) {
	return c, nil
}
func (p *fakeTransport) Dial(ctx context.Context, _ transport.Candidate) (net.Conn, error) {
	return (&net.Dialer{}).DialContext(ctx, "tcp", p.address)
}
func (*fakeTransport) Listen(context.Context, string) (net.Listener, error) { return nil, nil }
func (*fakeTransport) NetworkCost(transport.Candidate) transport.NetworkCost {
	return transport.NetworkCost{Known: true}
}
func (*fakeTransport) Close() error { return nil }

type seekReader struct{ *bytes.Reader }

func (seekReader) Close() error { return nil }

type fakeFiles struct{ data []byte }

func (*fakeFiles) ID() string { return "memory" }
func (*fakeFiles) Scope() filesproviders.Scope {
	return filesproviders.Scope{Version: 1, RootID: "memory", Read: true}
}
func (*fakeFiles) List(context.Context, string, string, int) (protocol.Listing, error) {
	return protocol.Listing{Entries: []protocol.Entry{{Name: "hello.txt", Path: "hello.txt", Kind: "file"}}}, nil
}
func (f *fakeFiles) Stat(_ context.Context, p string) (protocol.Entry, error) {
	if p == "." {
		return protocol.Entry{Kind: "directory"}, nil
	}
	return protocol.Entry{Name: "hello.txt", Path: p, Kind: "file", Size: int64(len(f.data))}, nil
}
func (f *fakeFiles) OpenRead(context.Context, string) (io.ReadSeekCloser, error) {
	return seekReader{bytes.NewReader(f.data)}, nil
}
func (*fakeFiles) OpenWriteStaged(context.Context, string) (filesproviders.StagedWrite, error) {
	return nil, filesproviders.ErrReadOnly
}
func (*fakeFiles) Close() error { return nil }
func open(t *testing.T, name string) (*storage.Store, *auth.Identity) {
	t.Helper()
	s, err := storage.Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	id, err := auth.Load(s, name)
	if err != nil {
		t.Fatal(err)
	}
	return s, id
}

func TestMutualPairBrowsePullAndRevocation(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	s, host := open(t, "laptop")
	cs, phone := open(t, "phone")
	reg := &filesproviders.Registry{}
	data := []byte("hello from a transport-independent filesystem\n")
	if err := reg.Register(&fakeFiles{data: data}); err != nil {
		t.Fatal(err)
	}
	if err := s.Export("memory", t.TempDir()); err != nil {
		t.Fatal(err)
	}
	h := httptest.NewUnstartedServer(server.New(s, host, reg).Handler())
	h.TLS = host.ServerTLS()
	h.StartTLS()
	t.Cleanup(h.Close)
	address := strings.TrimPrefix(h.URL, "https://")
	p := &fakeTransport{address: address}
	c := client.New(phone, cs, p, transport.Candidate{DeviceID: host.ID, Endpoint: address})
	t.Cleanup(c.Close)
	var roots []protocol.Root
	// Bypass the client's own local policy to test the server boundary itself.
	raw, err := http.NewRequestWithContext(ctx, "GET", h.URL+"/v1/files/roots", nil)
	if err != nil {
		t.Fatal(err)
	}
	raw.Header.Set("X-DeviceBridge-Version", "1")
	response, err := c.HTTP.Do(raw)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 403 {
		t.Fatalf("server allowed unpaired certificate: %d", response.StatusCode)
	}
	raw.Header.Set("X-DeviceBridge-Version", "99")
	response, err = c.HTTP.Do(raw)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 426 {
		t.Fatal("unsupported protocol was not rejected")
	}
	if c.JSON(ctx, "/v1/files/roots", nil, &roots) == nil {
		t.Fatal("unpaired request allowed")
	}
	inv, err := host.Invite(s)
	if err != nil {
		t.Fatal(err)
	}
	status, err := c.RequestPair(ctx, inv, phone.Name)
	if err != nil || status.Status != "pending" {
		t.Fatal(status, err)
	}
	if c.FinishPair(ctx) == nil {
		t.Fatal("pair completed without server approval")
	}
	if err = s.Approve(phone.ID, []string{"memory"}, time.Hour, 10000); err != nil {
		t.Fatal(err)
	}
	if err = c.FinishPair(ctx); err != nil {
		t.Fatal(err)
	}
	if err = c.JSON(ctx, "/v1/files/roots", nil, &roots); err != nil || len(roots) != 1 {
		t.Fatal(roots, err)
	}
	var listing protocol.Listing
	if err = c.JSON(ctx, "/v1/files/list", url.Values{"root": {"memory"}, "path": {"."}}, &listing); err != nil || len(listing.Entries) != 1 {
		t.Fatal(listing, err)
	}
	var manifest protocol.Manifest
	if err = c.JSON(ctx, "/v1/files/manifest", url.Values{"root": {"memory"}, "path": {"."}}, &manifest); err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(t.TempDir(), "received")
	if _, err = transfer.Pull(ctx, c, host.ID, manifest, dest, nil); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(dest, "hello.txt"))
	if err != nil || !bytes.Equal(got, data) {
		t.Fatal("pull mismatch", err)
	}
	if err = c.JSON(ctx, "/v1/files/list", url.Values{"root": {"memory"}, "path": {"../escape"}}, &listing); err == nil {
		t.Fatal("traversal allowed")
	}
	if err = c.JSON(ctx, "/v1/files/list", url.Values{"root": {"secret"}}, &listing); err == nil {
		t.Fatal("unauthorized root allowed")
	}
	// Same persistent TLS connection must enforce revocation on every operation.
	if err = s.Revoke(phone.ID); err != nil {
		t.Fatal(err)
	}
	if _, err = c.ReadRange(ctx, "memory", "hello.txt", 0, 1); err == nil {
		t.Fatal("revoked peer continued reading")
	}
}
func TestPinnedTLSAndPersistentIdentity(t *testing.T) {
	t.Parallel()
	s, host := open(t, "host")
	reloaded, err := auth.Load(s, "")
	if err != nil || reloaded.ID != host.ID {
		t.Fatal("identity not persistent", err)
	}
	cs, phone := open(t, "phone")
	reg := &filesproviders.Registry{}
	h := httptest.NewUnstartedServer(server.New(s, host, reg).Handler())
	h.TLS = host.ServerTLS()
	h.StartTLS()
	t.Cleanup(h.Close)
	addr := strings.TrimPrefix(h.URL, "https://")
	c := client.New(phone, cs, &fakeTransport{address: addr}, transport.Candidate{DeviceID: strings.Repeat("f", 64), Endpoint: addr})
	defer c.Close()
	inv, err := host.Invite(s)
	if err != nil {
		t.Fatal(err)
	}
	inv.ID = strings.Repeat("f", 64)
	if _, err = c.RequestPair(context.Background(), inv, "phone"); err == nil {
		t.Fatal("wrong server pin accepted")
	}
}

func TestStreamingTarPullOverMTLS(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	s, host := open(t, "host")
	cs, phone := open(t, "phone")
	srcDir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(srcDir, "sub"), 0755); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 20; i++ {
		p := filepath.Join(srcDir, "sub", "item-"+string(rune('a'+i))+".txt")
		if err := os.WriteFile(p, []byte("tar integration payload\n"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	np, err := filesproviders.NewNative("tree", srcDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { np.Close() })
	reg := &filesproviders.Registry{}
	if err := reg.Register(np); err != nil {
		t.Fatal(err)
	}
	if err := s.Export("tree", srcDir); err != nil {
		t.Fatal(err)
	}
	h := httptest.NewUnstartedServer(server.New(s, host, reg).Handler())
	h.TLS = host.ServerTLS()
	h.StartTLS()
	t.Cleanup(h.Close)
	addr := strings.TrimPrefix(h.URL, "https://")
	c := client.New(phone, cs, &fakeTransport{address: addr}, transport.Candidate{DeviceID: host.ID, Endpoint: addr})
	t.Cleanup(c.Close)
	inv, err := host.Invite(s)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.RequestPair(ctx, inv, phone.Name); err != nil {
		t.Fatal(err)
	}
	if err := s.Approve(phone.ID, []string{"tree"}, time.Hour, 10<<20); err != nil {
		t.Fatal(err)
	}
	if err := c.FinishPair(ctx); err != nil {
		t.Fatal(err)
	}
	var manifest protocol.Manifest
	if err := c.JSON(ctx, "/v1/files/manifest", url.Values{"root": {"tree"}, "path": {"."}}, &manifest); err != nil {
		t.Fatal(err)
	}
	if !transfer.ShouldUseTar(manifest) {
		t.Fatal("expected ShouldUseTar=true")
	}
	stream, codec, err := c.OpenTar(ctx, "tree", ".", "adaptive")
	if err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(t.TempDir(), "pulled-tree")
	receipt, err := transfer.PullTar(ctx, stream, codec, host.ID, manifest, dest, nil)
	if err != nil {
		t.Fatal(err)
	}
	if receipt.Files != 20 || receipt.Mode != "tar" || receipt.MiBPerSecond <= 0 {
		t.Fatalf("unexpected tar receipt: %+v", receipt)
	}
	got, err := os.ReadFile(filepath.Join(dest, "sub", "item-a.txt"))
	if err != nil || string(got) != "tar integration payload\n" {
		t.Fatalf("extracted file mismatch: %v", err)
	}
}
