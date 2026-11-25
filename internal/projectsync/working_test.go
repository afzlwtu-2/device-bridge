package projectsync

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func gitRun(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "LC_ALL=C",
		"GIT_AUTHOR_NAME=Test", "GIT_AUTHOR_EMAIL=test@example.com",
		"GIT_COMMITTER_NAME=Test", "GIT_COMMITTER_EMAIL=test@example.com")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

func writeWorkingFile(t *testing.T, root, name, content string) {
	t.Helper()
	full := filepath.Join(root, name)
	if err := os.MkdirAll(filepath.Dir(full), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}
}

func workingRepo(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	gitRun(t, root, "init", "-q", "-b", "main")
	gitRun(t, root, "config", "user.email", "test@example.com")
	gitRun(t, root, "config", "user.name", "Test")
	writeWorkingFile(t, root, "tracked.txt", "committed\n")
	writeWorkingFile(t, root, "nested/tracked2.txt", "nested committed\n")
	gitRun(t, root, "add", ".")
	gitRun(t, root, "commit", "-q", "-m", "initial")
	writeWorkingFile(t, root, "tracked.txt", "committed + uncommitted edit\n")
	writeWorkingFile(t, root, "untracked.txt", "untracked\n")
	writeWorkingFile(t, root, ".hidden", "hidden working file\n")
	writeWorkingFile(t, root, ".gitignore", "ignored.txt\n")
	writeWorkingFile(t, root, "ignored.txt", "ignored but persistent\n")
	gitRun(t, root, "init", "-q", "-b", "main", "nestedrepo")
	writeWorkingFile(t, root, "nestedrepo/inner.txt", "inside nested repo\n")
	return root
}

func projectionPaths(t *testing.T, dest string) []string {
	t.Helper()
	var paths []string
	err := filepath.WalkDir(dest, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(dest, p)
		if err != nil {
			return err
		}
		paths = append(paths, filepath.ToSlash(rel))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	slices.Sort(paths)
	return paths
}

func TestBuildWorkingIncludesEverythingExceptGit(t *testing.T) {
	root := workingRepo(t)
	dest := filepath.Join(t.TempDir(), "projection")
	projection, err := BuildWorking(context.Background(), root, dest)
	if err != nil {
		t.Fatal(err)
	}
	got := projectionPaths(t, dest)
	want := []string{
		".gitignore", ".hidden", "ignored.txt", "nested/tracked2.txt",
		"nestedrepo/inner.txt", "tracked.txt", "untracked.txt",
	}
	if !slices.Equal(got, want) {
		t.Fatalf("working projection files:\n got %v\nwant %v", got, want)
	}
	for _, path := range got {
		if strings.Contains(path, ".git/") || strings.HasSuffix(path, ".git") {
			t.Fatalf("Git metadata leaked into the projection: %s", path)
		}
	}
	dirty, err := os.ReadFile(filepath.Join(dest, "tracked.txt"))
	if err != nil || string(dirty) != "committed + uncommitted edit\n" {
		t.Fatalf("uncommitted content must be staged verbatim: %q %v", dirty, err)
	}
	if projection.Git.Branch != "main" || projection.Git.Head == "" {
		t.Fatalf("best-effort Git evidence: %+v", projection.Git)
	}
	if int64(len(projection.Files)) != int64(len(want)) || projection.Bytes <= 0 {
		t.Fatalf("projection accounting: %+v", projection)
	}
}

func TestBuildWorkingPlainFolderNeedsNoGit(t *testing.T) {
	root := t.TempDir()
	writeWorkingFile(t, root, "data.bin", "payload")
	writeWorkingFile(t, root, ".config/settings.json", "{}")
	dest := filepath.Join(t.TempDir(), "projection")
	projection, err := BuildWorking(context.Background(), root, dest)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(projectionPaths(t, dest), []string{".config/settings.json", "data.bin"}) {
		t.Fatalf("plain folder projection: %v", projectionPaths(t, dest))
	}
	if projection.Git.Branch != "" || projection.Git.Head != "" {
		t.Fatalf("plain folder has no Git evidence: %+v", projection.Git)
	}
}

func TestBuildWorkingBlocksSymlinksAndUnsafeDestinations(t *testing.T) {
	root := workingRepo(t)
	if err := os.Symlink(filepath.Join(root, "tracked.txt"), filepath.Join(root, "link.txt")); err != nil {
		t.Fatal(err)
	}
	if _, err := BuildWorking(context.Background(), root, filepath.Join(t.TempDir(), "projection")); err == nil {
		t.Fatal("symlinks must block the working projection")
	}
	if err := os.Remove(filepath.Join(root, "link.txt")); err != nil {
		t.Fatal(err)
	}
	if _, err := BuildWorking(context.Background(), root, filepath.Join(root, "inside")); err == nil {
		t.Fatal("a destination inside the worktree must fail")
	}
	parent := t.TempDir()
	existing := filepath.Join(parent, "projection")
	if err := os.Mkdir(existing, 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := BuildWorking(context.Background(), root, existing); err == nil {
		t.Fatal("an existing destination must not be replaced")
	}
}
