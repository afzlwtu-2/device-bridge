package bootstrap

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/cespare/xxhash/v2"
)

func TestTermuxBackupRoundTripPreservesHomeAndPackageNames(t *testing.T) {
	testRoot := t.TempDir()
	sourceState := filepath.Join(testRoot, "org.example.old", "files", "devicebridge")
	targetState := filepath.Join(testRoot, "org.example.new", "files", "devicebridge")
	source := termuxBackupHome(sourceState)
	target := termuxBackupHome(targetState)
	put := func(path, value string, mode os.FileMode) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(value), mode); err != nil {
			t.Fatal(err)
		}
	}
	put(filepath.Join(source, ".config", "settings"), "private settings", 0600)
	put(filepath.Join(source, "projects", "example", ".git", "HEAD"), "ref: refs/heads/main", 0644)
	put(filepath.Join(source, "projects", "example", "run"), "echo run", 0700)
	put(filepath.Join(filepath.Dir(source), "usr", "var", "lib", "dpkg", "status"),
		"Package: git\nStatus: install ok installed\n\nPackage: gone\nStatus: deinstall ok config-files\n\nPackage: bash\nStatus: hold ok installed\n", 0600)
	put(filepath.Join(target, "existing"), "keep me", 0600)
	if err := os.Symlink(filepath.Join(source, ".config", "settings"), filepath.Join(source, "alias")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/outside/home", filepath.Join(source, "external")); err != nil {
		t.Fatal(err)
	}
	var archive bytes.Buffer
	unreadable := filepath.Join(source, "unreadable")
	put(unreadable, "restricted", 0000)
	// An unprivileged Android UID cannot read a root-owned private file.
	_, readErr := os.ReadFile(unreadable)
	report, err := WriteTermuxBackup(sourceState, &archive)
	if err != nil {
		t.Fatal(err)
	}
	if report.XXH64 != fmt.Sprintf("%016x", xxhash.Sum64(archive.Bytes())) {
		t.Fatalf("wrong archive checksum: %+v", report)
	}
	if os.IsPermission(readErr) && report.Skipped != 1 {
		t.Fatalf("unreadable source should be reported: %+v", report)
	}
	truncated := append([]byte(nil), archive.Bytes()[:archive.Len()-4]...)
	if _, err := RestoreTermuxBackup(targetState, bytes.NewReader(truncated)); err == nil {
		t.Fatal("truncated archive restored")
	}
	if got, err := os.ReadFile(filepath.Join(target, "existing")); err != nil || string(got) != "keep me" {
		t.Fatalf("failed restore changed live Home: %q, %v", got, err)
	}
	info, err := RestoreTermuxBackup(targetState, &archive)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(info.Packages, []string{"bash", "git"}) || info.Previous == "" {
		t.Fatalf("unexpected restore info: %+v", info)
	}
	if os.IsPermission(readErr) {
		if _, err := os.Lstat(filepath.Join(target, "unreadable")); !os.IsNotExist(err) {
			t.Fatalf("unreadable file should be absent after restore: %v", err)
		}
	}
	for name, want := range map[string]string{
		".config/settings":           "private settings",
		"alias":                      "private settings",
		"projects/example/.git/HEAD": "ref: refs/heads/main",
	} {
		if got, err := os.ReadFile(filepath.Join(target, name)); err != nil || string(got) != want {
			t.Fatalf("%s: %q, %v", name, got, err)
		}
	}
	if got, err := os.Readlink(filepath.Join(target, "external")); err != nil || got != "/outside/home" {
		t.Fatalf("external symlink: %q, %v", got, err)
	}
	if file, err := os.Stat(filepath.Join(target, "projects", "example", "run")); err != nil || file.Mode().Perm() != 0700 {
		t.Fatalf("executable mode: %v, %v", file, err)
	}
	if got, err := os.ReadFile(filepath.Join(filepath.Dir(target), info.Previous, "existing")); err != nil || string(got) != "keep me" {
		t.Fatalf("previous Home: %q, %v", got, err)
	}
}

func TestTermuxBackupExcludesCachesAndAlwaysPreservesDotEnv(t *testing.T) {
	testRoot := t.TempDir()
	sourceState := filepath.Join(testRoot, "org.example.src", "files", "devicebridge")
	targetState := filepath.Join(testRoot, "org.example.dst", "files", "devicebridge")
	source := termuxBackupHome(sourceState)
	target := termuxBackupHome(targetState)
	put := func(path, value string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
	}

	put(filepath.Join(source, ".cache", "pip", "wheel.whl"), "huge cache")
	put(filepath.Join(source, ".env"), "ROOT_SECRET=yes")
	put(filepath.Join(source, ".env.local"), "LOCAL_SECRET=yes")
	put(filepath.Join(source, "projects", "web", "index.ts"), "console.log('ok')")
	put(filepath.Join(source, "projects", "web", ".env.production"), "PROD_KEY=123")
	put(filepath.Join(source, "projects", "web", "node_modules", "pkg", "big.js"), "generated")
	put(filepath.Join(source, "projects", "web", ".node_modules", "pkg", "big.js"), "generated dot")
	put(filepath.Join(source, "notes", "todo.txt"), "not selected")

	entries, err := ListTermuxBackupEntries(sourceState, "")
	if err != nil {
		t.Fatal(err)
	}
	entryByName := map[string]TermuxBackupEntry{}
	for _, e := range entries {
		entryByName[e.Name] = e
	}
	if !entryByName[".cache"].ExcludedByDefault {
		t.Fatalf("expected .cache excluded by default: %+v", entryByName[".cache"])
	}
	if !entryByName[".env"].AlwaysIncluded || !entryByName[".env.local"].AlwaysIncluded {
		t.Fatalf("expected .env* always included: %+v", entryByName)
	}

	excludes := append(append([]string(nil), DefaultTermuxBackupExcludes...), ".*")
	var archive bytes.Buffer
	report, err := WriteTermuxBackupWithOptions(sourceState, &archive, TermuxBackupOptions{
		IncludePaths:    []string{"projects"},
		ExcludePatterns: &excludes,
	})
	if err != nil {
		t.Fatal(err)
	}
	if report.Excluded == 0 {
		t.Fatalf("expected generated folders to be excluded, got %+v", report)
	}
	if _, err := RestoreTermuxBackup(targetState, &archive); err != nil {
		t.Fatal(err)
	}
	for rel, want := range map[string]string{
		".env":                         "ROOT_SECRET=yes",
		".env.local":                   "LOCAL_SECRET=yes",
		"projects/web/index.ts":        "console.log('ok')",
		"projects/web/.env.production": "PROD_KEY=123",
	} {
		got, err := os.ReadFile(filepath.Join(target, rel))
		if err != nil || string(got) != want {
			t.Fatalf("%s: got %q (%v), want %q", rel, got, err, want)
		}
	}
	for _, absent := range []string{
		".cache/pip/wheel.whl",
		"projects/web/node_modules/pkg/big.js",
		"projects/web/.node_modules/pkg/big.js",
		"notes/todo.txt",
	} {
		if _, err := os.Lstat(filepath.Join(target, absent)); !os.IsNotExist(err) {
			t.Fatalf("%s should have been excluded/unselected, got stat err=%v", absent, err)
		}
	}
}
