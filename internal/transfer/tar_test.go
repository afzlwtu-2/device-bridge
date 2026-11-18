package transfer

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"devicebridge/internal/files"
	"devicebridge/internal/filesproviders"
	"devicebridge/protocol"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func buildTree(t *testing.T, count int) (string, filesproviders.Provider, protocol.Manifest) {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "nested", "empty"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "nested", "zero.bin"), nil, 0644); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < count; i++ {
		name := filepath.Join(dir, "nested", "file-"+string(rune('a'+i%26))+string(rune('0'+i/26))+".txt")
		if err := os.WriteFile(name, []byte("small file payload for streaming tar\n"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	p, err := filesproviders.NewNative("shared", dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { p.Close() })
	m, err := files.Manifest(context.Background(), p, ".", func(int64) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	return dir, p, m
}

func TestStreamingTarRoundTripAndProgress(t *testing.T) {
	t.Parallel()
	_, p, m := buildTree(t, 20)
	if !ShouldUseTar(m) {
		t.Fatal("expected ShouldUseTar=true for 21 small files")
	}
	for _, codec := range []string{"gzip", "none"} {
		var buf bytes.Buffer
		var charged int64
		if err := WriteTar(context.Background(), p, ".", codec, &buf, func(n int64) error {
			charged += n
			return nil
		}); err != nil {
			t.Fatalf("WriteTar(%s): %v", codec, err)
		}
		if charged != m.Bytes {
			t.Fatalf("charged %d bytes, want %d", charged, m.Bytes)
		}
		dest := filepath.Join(t.TempDir(), "out-"+codec)
		var last Progress
		receipt, err := PullTar(context.Background(), io.NopCloser(&buf), codec, "peer", m, dest, func(v Progress) {
			last = v
		})
		if err != nil {
			t.Fatalf("PullTar(%s): %v", codec, err)
		}
		if receipt.Mode != "tar" || receipt.Bytes != m.Bytes || receipt.MiBPerSecond <= 0 {
			t.Fatalf("unexpected receipt: %+v", receipt)
		}
		if last.VerifiedBytes != m.Bytes || last.MiBPerSecond <= 0 {
			t.Fatalf("unexpected last progress: %+v", last)
		}
		if info, err := os.Stat(filepath.Join(dest, "nested", "empty")); err != nil || !info.IsDir() {
			t.Fatalf("empty dir missing: %v", err)
		}
	}
}

func TestShouldUseTarSingleLargeFileFalse(t *testing.T) {
	t.Parallel()
	m := protocol.Manifest{
		Version: protocol.ManifestVersion,
		Bytes:   10 << 20,
		Entries: []protocol.ManifestEntry{{Path: ".", Directory: false, Size: 10 << 20}},
	}
	if ShouldUseTar(m) {
		t.Fatal("single file should use chunked range transfer, not tar")
	}
}

func TestUnsafeTarEntriesRejected(t *testing.T) {
	t.Parallel()
	_, _, m := buildTree(t, 1)
	cases := []struct {
		name   string
		header *tar.Header
		body   []byte
	}{
		{
			name:   "symlink",
			header: &tar.Header{Name: "nested/link", Typeflag: tar.TypeSymlink, Linkname: "/etc/passwd", Mode: 0777},
		},
		{
			name:   "hardlink",
			header: &tar.Header{Name: "nested/hard", Typeflag: tar.TypeLink, Linkname: "nested/zero.bin", Mode: 0644},
		},
		{
			name:   "traversal",
			header: &tar.Header{Name: "../escape", Typeflag: tar.TypeReg, Size: 3, Mode: 0644},
			body:   []byte("bad"),
		},
		{
			name:   "absolute",
			header: &tar.Header{Name: "/tmp/evil", Typeflag: tar.TypeReg, Size: 3, Mode: 0644},
			body:   []byte("bad"),
		},
		{
			name:   "unexpected",
			header: &tar.Header{Name: "nested/extra.txt", Typeflag: tar.TypeReg, Size: 3, Mode: 0644},
			body:   []byte("bad"),
		},
	}
	for _, tc := range cases {
		var buf bytes.Buffer
		gw := gzip.NewWriter(&buf)
		tw := tar.NewWriter(gw)
		_ = tw.WriteHeader(&tar.Header{Name: "./", Typeflag: tar.TypeDir, Mode: 0755})
		_ = tw.WriteHeader(tc.header)
		if len(tc.body) > 0 {
			_, _ = tw.Write(tc.body)
		}
		_ = tw.Close()
		_ = gw.Close()
		dest := filepath.Join(t.TempDir(), tc.name)
		if _, err := PullTar(context.Background(), io.NopCloser(&buf), "gzip", "peer", m, dest, nil); err == nil {
			t.Fatalf("%s accepted unsafe tar entry", tc.name)
		}
		if _, err := os.Stat(dest); !os.IsNotExist(err) {
			t.Fatalf("%s published partial destination", tc.name)
		}
	}
}

func TestPullTarCorruptionAndNoOverwrite(t *testing.T) {
	t.Parallel()
	_, p, m := buildTree(t, 2)
	var buf bytes.Buffer
	if err := WriteTar(context.Background(), p, ".", "none", &buf, func(int64) error { return nil }); err != nil {
		t.Fatal(err)
	}
	raw := buf.Bytes()
	// Corrupt one byte inside a file payload near the middle of the archive.
	corrupted := append([]byte{}, raw...)
	corrupted[len(corrupted)/2] ^= 0x55
	dest := filepath.Join(t.TempDir(), "corrupt")
	if _, err := PullTar(context.Background(), io.NopCloser(bytes.NewReader(corrupted)), "none", "peer", m, dest, nil); err == nil {
		t.Fatal("corrupted tar accepted")
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Fatal("corrupted tar published")
	}

	existing := filepath.Join(t.TempDir(), "existing")
	if err := os.WriteFile(existing, []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := PullTar(context.Background(), io.NopCloser(bytes.NewReader(raw)), "none", "peer", m, existing, nil); err == nil {
		t.Fatal("overwrite accepted")
	}
}

func TestFolderExclusionsAffectManifestAndArchive(t *testing.T) {
	_, p, _ := buildTree(t, 2)
	excludes := []string{"nested/file-a0.txt", "nested/empty"}
	m, err := files.Manifest(context.Background(), p, ".", func(int64) error { return nil }, excludes...)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range m.Entries {
		if files.Excluded(entry.Path, excludes) {
			t.Fatalf("excluded entry leaked: %s", entry.Path)
		}
	}
	var archive bytes.Buffer
	if err = WriteTar(context.Background(), p, ".", "none", &archive, func(int64) error { return nil }, excludes...); err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(t.TempDir(), "filtered")
	if _, err = PullTar(context.Background(), io.NopCloser(&archive), "none", "peer", m, destination, nil); err != nil {
		t.Fatal(err)
	}
	for _, excluded := range excludes {
		if _, err = os.Stat(filepath.Join(destination, excluded)); !os.IsNotExist(err) {
			t.Fatalf("excluded path exists: %s", excluded)
		}
	}
	if _, err = os.Stat(filepath.Join(destination, "nested", "file-b0.txt")); err != nil {
		t.Fatal(err)
	}
	for _, invalid := range []string{"../outside", "/absolute", ".", "nested/../file"} {
		if _, err = files.ValidateExclusions([]string{invalid}); err == nil {
			t.Fatalf("accepted unsafe exclusion %q", invalid)
		}
	}
}
