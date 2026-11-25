package files

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"devicebridge/internal/filesproviders"
)

func TestManifestNamesSymlinkOffenderAndExcludesSkipIt(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "keep"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "keep", "data.txt"), []byte("payload"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "ephemeral", ".plugin_symlinks"), 0700); err != nil {
		t.Fatal(err)
	}
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "ephemeral", ".plugin_symlinks", "jni")); err != nil {
		t.Fatal(err)
	}
	provider, err := filesproviders.NewNative("test", root)
	if err != nil {
		t.Fatal(err)
	}
	defer provider.Close()
	allow := func(int64) error { return nil }

	_, err = Manifest(context.Background(), provider, ".", allow)
	if err == nil {
		t.Fatal("a symlink must block the manifest")
	}
	if !strings.Contains(err.Error(), "ephemeral/.plugin_symlinks/jni") {
		t.Fatalf("error must name the offending entry, got: %v", err)
	}

	manifest, err := Manifest(context.Background(), provider, ".", allow, "ephemeral")
	if err != nil {
		t.Fatalf("excluding the symlink subtree must allow the manifest: %v", err)
	}
	for _, entry := range manifest.Entries {
		if strings.HasPrefix(entry.Path, "ephemeral") {
			t.Fatalf("excluded subtree leaked into the manifest: %s", entry.Path)
		}
	}
	if manifest.Bytes != int64(len("payload")) {
		t.Fatalf("manifest bytes = %d, want %d", manifest.Bytes, len("payload"))
	}
}
