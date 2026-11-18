package transfer

import (
	"bytes"
	"context"
	"devicebridge/protocol"
	"encoding/hex"
	"errors"
	"github.com/cespare/xxhash/v2"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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
	h := xxhash.New()
	h.Write(data)
	return protocol.Manifest{Version: protocol.ManifestVersion, Root: "shared", Path: "file", Bytes: int64(len(data)), Entries: []protocol.ManifestEntry{{Path: ".", Size: int64(len(data)), XXH64: hex.EncodeToString(h.Sum(nil))}}}
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

type fakeStreamSource struct {
	fakeSource
	cutAt int64
}

type cutReader struct {
	r      io.Reader
	remain int64
}

func (c *cutReader) Read(p []byte) (int, error) {
	if c.remain <= 0 {
		return 0, errors.New("stream cut")
	}
	if int64(len(p)) > c.remain {
		p = p[:c.remain]
	}
	n, err := c.r.Read(p)
	c.remain -= int64(n)
	return n, err
}

func (s *fakeStreamSource) OpenStream(_ context.Context, _, _ string, offset int64) (io.ReadCloser, error) {
	if s.cutAt > 0 && offset == 0 {
		return io.NopCloser(&cutReader{r: bytes.NewReader(s.data[offset:]), remain: s.cutAt}), nil
	}
	return io.NopCloser(bytes.NewReader(s.data[offset:])), nil
}

func TestStreamPullAndResume(t *testing.T) {
	t.Parallel()
	data := make([]byte, ChunkSize+54321)
	for i := range data {
		data[i] = byte(i % 241)
	}
	s := &fakeStreamSource{fakeSource: fakeSource{data: data}, cutAt: 1 << 20}
	dest := filepath.Join(t.TempDir(), "streamed")
	m := manifest(data)
	if _, err := Pull(context.Background(), s, "peer", m, dest, nil); err == nil {
		t.Fatal("expected stream cut")
	}
	s.cutAt = 0
	receipt, err := Pull(context.Background(), s, "peer", m, dest, nil)
	if err != nil {
		t.Fatal(err)
	}
	if receipt.Mode != "stream" {
		t.Fatalf("expected mode=stream, got %q", receipt.Mode)
	}
	got, err := os.ReadFile(dest)
	if err != nil || !bytes.Equal(got, data) {
		t.Fatal("streamed payload mismatch", err)
	}
}

// Compare the wire/file digest with the independent tool used on both devices.
func TestXXH64MatchesXXHSum(t *testing.T) {
	executable, err := exec.LookPath("xxhsum")
	if err != nil {
		t.Skip("xxhsum not installed")
	}
	for _, size := range []int{0, 3, 31, 32, 33, 1<<20 + 17} {
		data := bytes.Repeat([]byte{0x5a}, size)
		cmd := exec.Command(executable, "-H1", "-q")
		cmd.Stdin = bytes.NewReader(data)
		output, err := cmd.Output()
		if err != nil {
			t.Fatal(err)
		}
		expected := strings.Fields(string(output))[0]
		m := manifest(data)
		if got := m.Entries[0].XXH64; got != expected {
			t.Fatalf("%d bytes: got %s want %s", size, got, expected)
		}
		destination := filepath.Join(t.TempDir(), "received")
		if _, err := Pull(context.Background(), &fakeSource{data: data}, "peer", m, destination, nil); err != nil {
			t.Fatal(err)
		}
		output, err = exec.Command(executable, "-H1", "-q", destination).Output()
		if err != nil || strings.Fields(string(output))[0] != expected {
			t.Fatalf("completed target digest mismatch: %s, %v", output, err)
		}
	}
}

func TestLegacyManifestFailsClosed(t *testing.T) {
	m := manifest([]byte("payload"))
	m.Version = 1
	if ValidateManifest(m) == nil {
		t.Fatal("accepted legacy checksum manifest")
	}
	m.Version = protocol.ManifestVersion
	m.Entries[0].XXH64 = strings.Repeat("0", 64)
	if ValidateManifest(m) == nil {
		t.Fatal("accepted SHA-256 length as XXH64")
	}
}
