package syncthing

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	testSelfID = "AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA"
	testPeerID = "BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB"
)

// preparedProfile fakes an installed Syncthing and a prepared device identity
// so registration policy can be tested without running a daemon.
func preparedProfile(t *testing.T) Profile {
	t.Helper()
	bin := t.TempDir()
	script := filepath.Join(bin, "syncthing")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf 'syncthing v2.1.7\\n'\n"), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	state := t.TempDir()
	profile := Open(state)
	if err := os.MkdirAll(profile.dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(profile.dir, "device-id"), []byte(testSelfID+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	info, err := profile.Inspect(context.Background())
	if err != nil || !info.Prepared {
		t.Fatalf("prepared profile: %v %+v", err, info)
	}
	return profile
}

func TestRegisterDefaultsToNonGitUntrackedProjection(t *testing.T) {
	profile := preparedProfile(t)
	entry, err := profile.Register(context.Background(), "data", testPeerID, SendOnly, "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if entry.Mode != ModeNonGit || entry.Filter != FilterUntracked {
		t.Fatalf("unexpected defaults: %+v", entry)
	}
	if entry.Path != filepath.Join(profile.dir, "projections", "data") {
		t.Fatalf("projection path: %s", entry.Path)
	}
	info, err := os.Lstat(entry.Path)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		t.Fatalf("private projection directory missing: %v", err)
	}
	again, err := profile.Register(context.Background(), "data", testPeerID, SendOnly, "", "", "")
	if err != nil || again.Path != entry.Path {
		t.Fatalf("idempotent register: %v %+v", err, again)
	}
}

func TestRegisterFullModeUsesSourceFolder(t *testing.T) {
	profile := preparedProfile(t)
	source := t.TempDir()
	if err := os.WriteFile(filepath.Join(source, "note.txt"), []byte("data"), 0644); err != nil {
		t.Fatal(err)
	}
	entry, err := profile.Register(context.Background(), "mirror", testPeerID, ReceiveOnly, ModeFull, "", source)
	if err != nil {
		t.Fatal(err)
	}
	if entry.Mode != ModeFull || entry.Path != source || entry.Filter != "" {
		t.Fatalf("full registration: %+v", entry)
	}
	if _, err := os.Lstat(filepath.Join(profile.dir, "projections", "mirror")); !os.IsNotExist(err) {
		t.Fatalf("full mode must not create a projection: %v", err)
	}
	read, err := profile.Registration("mirror")
	if err != nil || read.Path != source || read.Source != source {
		t.Fatalf("full read-back: %v %+v", err, read)
	}
	if _, err := profile.Register(context.Background(), "mirror", testPeerID, ReceiveOnly, ModeNonGit, "", ""); err == nil ||
		!strings.Contains(err.Error(), "syncthing mode") {
		t.Fatalf("mode change must go through SetMode: %v", err)
	}
}

func TestRegisterFullValidation(t *testing.T) {
	profile := preparedProfile(t)
	ctx := context.Background()
	if _, err := profile.Register(ctx, "mirror", testPeerID, SendOnly, ModeFull, "", ""); err == nil {
		t.Fatal("full mode without a source must fail")
	}
	if _, err := profile.Register(ctx, "mirror", testPeerID, SendOnly, ModeFull, "", "relative/path"); err == nil {
		t.Fatal("relative source must fail")
	}
	if _, err := profile.Register(ctx, "mirror", testPeerID, SendOnly, ModeFull, "", filepath.Join(t.TempDir(), "absent")); err == nil {
		t.Fatal("absent source must fail")
	}
	if _, err := profile.Register(ctx, "mirror", testPeerID, SendOnly, ModeFull, "", profile.dir); err == nil {
		t.Fatal("source inside the managed profile must fail")
	}
	if _, err := profile.Register(ctx, "mirror", testPeerID, SendOnly, ModeFull, FilterWorking, t.TempDir()); err == nil {
		t.Fatal("full mode must not accept a filter")
	}
	if _, err := profile.Register(ctx, "mirror", testPeerID, SendOnly, "bogus", "", ""); err == nil {
		t.Fatal("unknown mode must fail")
	}
	if _, err := profile.Register(ctx, "mirror", testPeerID, SendOnly, ModeNonGit, "bogus", ""); err == nil {
		t.Fatal("unknown filter must fail")
	}
}

func TestRegistrationReadsLegacyRecordsAsNonGit(t *testing.T) {
	profile := preparedProfile(t)
	if err := os.MkdirAll(filepath.Join(profile.dir, "folders"), 0700); err != nil {
		t.Fatal(err)
	}
	legacy := map[string]string{"group": "legacy", "peer_id": testPeerID, "role": SendOnly}
	raw, err := json.Marshal(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(profile.dir, "folders", "legacy.json"), raw, 0600); err != nil {
		t.Fatal(err)
	}
	entry, err := profile.Registration("legacy")
	if err != nil {
		t.Fatal(err)
	}
	if entry.Mode != ModeNonGit || entry.Filter != FilterUntracked ||
		entry.Path != filepath.Join(profile.dir, "projections", "legacy") {
		t.Fatalf("legacy normalization: %+v", entry)
	}
}

func TestSetModeSwitchesAndGuardsRunning(t *testing.T) {
	profile := preparedProfile(t)
	ctx := context.Background()
	if _, err := profile.Register(ctx, "switch", testPeerID, SendOnly, "", "", ""); err != nil {
		t.Fatal(err)
	}
	source := t.TempDir()
	entry, err := profile.SetMode("switch", ModeFull, "", source)
	if err != nil || entry.Mode != ModeFull || entry.Path != source {
		t.Fatalf("switch to full: %v %+v", err, entry)
	}
	if err := profile.saveRegistration(entry, "running"); err != nil {
		t.Fatal(err)
	}
	if _, err := profile.SetMode("switch", ModeNonGit, "", ""); err == nil ||
		!strings.Contains(err.Error(), "running session") {
		t.Fatalf("running guard: %v", err)
	}
	if err := profile.saveRegistration(entry, "paused"); err != nil {
		t.Fatal(err)
	}
	back, err := profile.SetMode("switch", ModeNonGit, FilterWorking, "")
	if err != nil || back.Mode != ModeNonGit || back.Filter != FilterWorking || back.Source != source {
		t.Fatalf("switch back keeps source: %v %+v", err, back)
	}
	if _, err := os.Lstat(filepath.Join(profile.dir, "projections", "switch")); err != nil {
		t.Fatalf("non-git switch must restore the projection directory: %v", err)
	}
	if _, err := profile.SetMode("switch", ModeFull, "", ""); err == nil {
		t.Fatal("full switch without a source must fail")
	}
}

func TestDigestFullModeAllowsGitAndHiddenFiles(t *testing.T) {
	profile := preparedProfile(t)
	ctx := context.Background()
	source := t.TempDir()
	for _, dir := range []string{".git", "sub", "sub/.git", ".stfolder", ".stversions"} {
		if err := os.MkdirAll(filepath.Join(source, dir), 0755); err != nil {
			t.Fatal(err)
		}
	}
	for name, content := range map[string]string{
		".git/HEAD":           "ref: refs/heads/main\n",
		"sub/.git/HEAD":       "ref: refs/heads/nested\n",
		".hidden":             "secret-less hidden file",
		"sub/working.txt":     "uncommitted work",
		".stfolder/marker":    "",
		".stversions/old.txt": "stale",
	} {
		if err := os.WriteFile(filepath.Join(source, name), []byte(content), 0644); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := profile.Register(ctx, "full", testPeerID, SendOnly, ModeFull, "", source); err != nil {
		t.Fatal(err)
	}
	digest, err := profile.Digest(ctx, "full")
	if err != nil {
		t.Fatalf("full digest must allow .git and hidden files: %v", err)
	}
	// Entries: root + .git, sub, sub/.git directories + .git/HEAD,
	// sub/.git/HEAD, .hidden, sub/working.txt files; Syncthing control
	// directories stay excluded.
	if digest.Items != 7 {
		t.Fatalf("full digest items = %d, want 7", digest.Items)
	}
	if err := os.WriteFile(filepath.Join(source, ".stignore"), []byte("*\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := profile.Digest(ctx, "full"); err == nil {
		t.Fatal("a foreign .stignore must fail closed even in full mode")
	}
}

func TestExcludesSkipSymlinkSubtreeAndTrustOnlyManagedIgnore(t *testing.T) {
	profile := preparedProfile(t)
	ctx := context.Background()
	source := t.TempDir()
	if err := os.MkdirAll(filepath.Join(source, "keep"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source, "keep", "data.txt"), []byte("payload"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(source, "ephemeral", ".plugin_symlinks"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(t.TempDir(), filepath.Join(source, "ephemeral", ".plugin_symlinks", "jni")); err != nil {
		t.Fatal(err)
	}
	if _, err := profile.Register(ctx, "excl", testPeerID, SendOnly, ModeFull, "", source); err != nil {
		t.Fatal(err)
	}
	if _, err := profile.Digest(ctx, "excl"); err == nil || !strings.Contains(err.Error(), ".plugin_symlinks/jni") {
		t.Fatalf("unexcluded symlink must block and be named: %v", err)
	}
	if _, err := profile.SetExcludes("excl", []string{"../escape"}); err == nil {
		t.Fatal("path-escaping exclusion accepted")
	}
	if _, err := profile.SetExcludes("excl", []string{"ephemeral"}); err != nil {
		t.Fatal(err)
	}
	clean, err := profile.Digest(ctx, "excl")
	if err != nil {
		t.Fatalf("excluding the symlink subtree must allow the digest: %v", err)
	}
	if clean.Items != 2 || clean.Bytes != int64(len("payload")) {
		t.Fatalf("excluded digest = %+v, want 2 items / 7 bytes", clean)
	}
	// A foreign .stignore must still fail closed even with exclusions set.
	if err := os.WriteFile(filepath.Join(source, ".stignore"), []byte("*\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := profile.Digest(ctx, "excl"); err == nil {
		t.Fatal("a foreign .stignore must fail closed")
	}
	// The exact managed ignore file is trusted and stays out of the manifest.
	if err := os.WriteFile(filepath.Join(source, ".stignore"), []byte(managedIgnoreContent([]string{"ephemeral"})), 0600); err != nil {
		t.Fatal(err)
	}
	managed, err := profile.Digest(ctx, "excl")
	if err != nil {
		t.Fatalf("managed .stignore must be trusted: %v", err)
	}
	if managed.XXH64 != clean.XXH64 {
		t.Fatalf("managed ignore changed the verified manifest: %s != %s", managed.XXH64, clean.XXH64)
	}
}

func TestDigestNonGitStillRejectsGit(t *testing.T) {
	profile := preparedProfile(t)
	ctx := context.Background()
	if _, err := profile.Register(ctx, "strict", testPeerID, SendOnly, "", "", ""); err != nil {
		t.Fatal(err)
	}
	entry, err := profile.Registration("strict")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(entry.Path, ".git"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(entry.Path, ".git", "HEAD"), []byte("ref\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := profile.Digest(ctx, "strict"); err == nil {
		t.Fatal("non-git projections must still reject .git")
	}
	if _, err := profile.ReplaceProjection(ctx, "strict", false, func(string) error { return nil }); err == nil {
		t.Fatal("a Git-contaminated projection must not be exchangeable")
	}
	if err := os.RemoveAll(filepath.Join(entry.Path, ".git")); err != nil {
		t.Fatal(err)
	}
	if _, err := profile.ReplaceProjection(ctx, "strict", false, func(path string) error {
		return os.MkdirAll(path, 0700)
	}); err != nil {
		t.Fatalf("empty projection exchange: %v", err)
	}
	if _, err := profile.Register(ctx, "fullblock", testPeerID, SendOnly, ModeFull, "", t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if _, err := profile.ReplaceProjection(ctx, "fullblock", false, func(string) error { return nil }); err == nil {
		t.Fatal("full registrations have no managed projection to replace")
	}
}
