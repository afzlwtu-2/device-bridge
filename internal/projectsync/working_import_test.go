package projectsync

import (
	"context"
	"devicebridge/internal/files"
	"devicebridge/internal/filesproviders"
	"os"
	"path/filepath"
	"testing"
)

func TestWorkingImportUpdatesBaselinePreservesGitAndConflicts(t *testing.T) {
	ctx := context.Background()
	destination := t.TempDir()
	source := t.TempDir()
	write := func(root, name, data string) {
		t.Helper()
		if e := os.MkdirAll(filepath.Dir(filepath.Join(root, name)), 0700); e != nil {
			t.Fatal(e)
		}
		if e := os.WriteFile(filepath.Join(root, name), []byte(data), 0600); e != nil {
			t.Fatal(e)
		}
	}
	write(destination, "note.txt", "old")
	write(destination, ".git/config", "private git")
	write(destination, "extra", "local only")
	baseline, e := SnapshotWorking(ctx, destination)
	if e != nil {
		t.Fatal(e)
	}
	write(source, "note.txt", "new")
	write(source, "added", "new file")
	if e = os.Mkdir(filepath.Join(source, "empty"), 0700); e != nil {
		t.Fatal(e)
	}
	provider, e := filesproviders.NewNative("source", source)
	if e != nil {
		t.Fatal(e)
	}
	defer provider.Close()
	manifest, e := files.Manifest(ctx, provider, ".", func(int64) error { return nil })
	if e != nil {
		t.Fatal(e)
	}
	if e = ApplyWorking(ctx, destination, source, manifest, baseline); e != nil {
		t.Fatal(e)
	}
	for name, want := range map[string]string{"note.txt": "new", "added": "new file", ".git/config": "private git", "extra": "local only"} {
		got, e := os.ReadFile(filepath.Join(destination, name))
		if e != nil || string(got) != want {
			t.Fatalf("%s: %s %v", name, got, e)
		}
	}
	versions, e := filepath.Glob(filepath.Join(destination, ".devicebridge-sync-recovery-*", "note.txt"))
	if e != nil || len(versions) != 1 {
		t.Fatalf("recovery: %v %v", versions, e)
	}
	old, _ := os.ReadFile(versions[0])
	if string(old) != "old" {
		t.Fatalf("old content lost: %q", old)
	}
	if st, e := os.Stat(filepath.Join(destination, "empty")); e != nil || !st.IsDir() {
		t.Fatalf("empty directory missing: %v", e)
	}
	baseline, e = SnapshotWorking(ctx, destination)
	if e != nil {
		t.Fatal(e)
	}
	write(destination, "note.txt", "concurrent local edit")
	if e = ApplyWorking(ctx, destination, source, manifest, baseline); e == nil {
		t.Fatal("overwrote concurrent local change")
	}
	got, _ := os.ReadFile(filepath.Join(destination, "note.txt"))
	if string(got) != "concurrent local edit" {
		t.Fatalf("conflict lost: %s", got)
	}
}
