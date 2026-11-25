package transfer

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"devicebridge/internal/files"
	"devicebridge/internal/filesproviders"
)

func TestVerifiedMoveKeepsExcludedContent(t *testing.T) {
	home := t.TempDir()
	source := filepath.Join(home, "source")
	if err := os.MkdirAll(filepath.Join(source, "empty"), 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"keep", "move"} {
		if err := os.WriteFile(filepath.Join(source, name), []byte(name), 0600); err != nil {
			t.Fatal(err)
		}
	}
	native, err := filesproviders.NewNative("home", home)
	if err != nil {
		t.Fatal(err)
	}
	defer native.Close()
	ctx := context.Background()
	allow := func(int64) error { return nil }
	excludes := []string{"keep"}
	manifest, err := files.Manifest(ctx, native, "source", allow, excludes...)
	if err != nil {
		t.Fatal(err)
	}
	remaining, err := RemoveVerified(ctx, native, "source", files.ContentXXH64(manifest), excludes, allow)
	if err != nil || !remaining {
		t.Fatalf("move result = %t, %v", remaining, err)
	}
	items, err := os.ReadDir(source)
	if err != nil || len(items) != 1 || items[0].Name() != "keep" {
		t.Fatalf("retained files = %v %v", items, err)
	}
	root, err := os.ReadDir(home)
	if err != nil || len(root) != 1 || root[0].Name() != "source" {
		t.Fatalf("move left private staging: %v %v", root, err)
	}
}
