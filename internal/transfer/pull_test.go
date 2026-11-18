package transfer

import (
	"context"
	"crypto/sha256"
	"devicebridge/protocol"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

type fakeSource struct {
	data    []byte
	calls   int
	failAt  int
	corrupt bool
	before  func()
}

func (s *fakeSource) ReadRange(_ context.Context, _, _ string, o, n int64) ([]byte, error) {
	s.calls++
	if s.before != nil {
		s.before()
	}
	if s.failAt > 0 && s.calls == s.failAt {
		return nil, errors.New("connection interrupted")
	}
	b := append([]byte{}, s.data[o:o+n]...)
	if s.corrupt && len(b) > 0 {
		b[0] ^= 0xff
	}
	return b, nil
}
func manifest(data []byte) protocol.Manifest {
	h := sha256.Sum256(data)
	return protocol.Manifest{Version: 1, Root: "shared", Path: "file", Bytes: int64(len(data)), Entries: []protocol.ManifestEntry{{Path: ".", Size: int64(len(data)), SHA256: hex.EncodeToString(h[:])}}}
}
func TestInterruptedPullResumesAndPublishes(t *testing.T) {
	t.Parallel()
	data := make([]byte, ChunkSize+37)
	for i := range data {
		data[i] = byte(i % 251)
	}
	s := &fakeSource{data: data, failAt: 2}
	dest := filepath.Join(t.TempDir(), "result")
	m := manifest(data)
	if _, err := Pull(context.Background(), s, "peer", m, dest, nil); err == nil {
		t.Fatal("expected interruption")
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Fatal("partial payload published")
	}
	s.calls = 0
	s.failAt = 0
	if _, err := Pull(context.Background(), s, "peer", m, dest, nil); err != nil {
		t.Fatal(err)
	}
	if s.calls != 1 {
		t.Fatalf("resume fetched %d chunks, want 1", s.calls)
	}
	got, err := os.ReadFile(dest)
	if err != nil || string(got) != string(data) {
		t.Fatal("payload mismatch", err)
	}
}
func TestCorruptionNeverPublishes(t *testing.T) {
	t.Parallel()
	data := []byte("approved contents")
	s := &fakeSource{data: data, corrupt: true}
	dest := filepath.Join(t.TempDir(), "result")
	if _, err := Pull(context.Background(), s, "peer", manifest(data), dest, nil); err == nil {
		t.Fatal("corruption accepted")
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Fatal("corrupt payload published")
	}
}
func TestDestinationRaceDoesNotOverwrite(t *testing.T) {
	t.Parallel()
	data := []byte("new")
	dest := filepath.Join(t.TempDir(), "result")
	s := &fakeSource{data: data, before: func() {
		if err := os.WriteFile(dest, []byte("original"), 0600); err != nil {
			t.Fatal(err)
		}
	}}
	if _, err := Pull(context.Background(), s, "peer", manifest(data), dest, nil); err == nil {
		t.Fatal("destination race accepted")
	}
	b, _ := os.ReadFile(dest)
	if string(b) != "original" {
		t.Fatal("existing payload overwritten")
	}
}
func TestUnsafeManifestRejected(t *testing.T) {
	t.Parallel()
	for _, p := range []string{"../outside", "/absolute", "x/../../escape", "x\\..\\escape", "x:stream"} {
		m := manifest(nil)
		m.Entries[0].Path = p
		if err := ValidateManifest(m); err == nil {
			t.Fatalf("accepted %q", p)
		}
	}
	m := manifest(nil)
	m.Entries = append(m.Entries, m.Entries[0])
	if ValidateManifest(m) == nil {
		t.Fatal("duplicate accepted")
	}
}
func TestStagingSymlinkRejected(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	dest := filepath.Join(dir, "target")
	if err := os.Symlink(t.TempDir(), dest+".devicebridge-part"); err != nil {
		t.Fatal(err)
	}
	if _, err := Pull(context.Background(), &fakeSource{}, "peer", manifest(nil), dest, nil); err == nil {
		t.Fatal("staging symlink accepted")
	}
}
