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
