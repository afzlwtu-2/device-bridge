package projectsync

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"

	"devicebridge/internal/files"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/transfer"
	"devicebridge/protocol"

	"github.com/cespare/xxhash/v2"
	"golang.org/x/sys/unix"
)

type ImportReceipt struct {
	Added    int `json:"added"`
	Existing int `json:"already_verified"`
}

// Apply puts a verified projection into approved project paths. An existing
// identical file is a no-op, and any different local file remains protected.
func Apply(ctx context.Context, worktree, projection string, manifest protocol.Manifest, revision Revision, approved []string) (ImportReceipt, error) {
	var receipt ImportReceipt
	rootPath, state, err := Preflight(ctx, worktree)
	if err != nil {
		return receipt, err
	}
	if !revision.matches(state, revision.Manifest) {
		return receipt, errors.New("match the approved Git branch and HEAD before importing")
	}
	approved, err = files.ValidateExclusions(approved)
	if err != nil || len(approved) == 0 || transfer.ValidateManifest(manifest) != nil {
		return receipt, errors.New("provide the approved local paths and a verified projection manifest")
	}
	tracked, submodules, err := trackedPaths(ctx, rootPath)
	if err != nil {
		return receipt, err
	}
	work, err := os.OpenRoot(rootPath)
	if err != nil {
		return receipt, err
	}
	defer work.Close()
	workFD, err := work.Open(".")
	if err != nil {
		return receipt, err
	}
	defer workFD.Close()
	source, err := filesproviders.NewNative("source", projection)
	if err != nil {
		return receipt, err
	}
	defer source.Close()

	var pending []protocol.ManifestEntry
	for _, entry := range manifest.Entries {
		if entry.Directory {
			continue
		}
		name := entry.Path
		if tracked[name] || files.Excluded(name, submodules) || !files.Excluded(name, approved) || excludedDataPath(name) {
			return receipt, fmt.Errorf("projection path is outside the approved persistent files: %q", name)
		}
		exists, err := currentFileMatches(ctx, int(workFD.Fd()), entry)
		if err != nil {
			return receipt, err
		}
		if exists {
			receipt.Existing++
		} else {
			pending = append(pending, entry)
		}
	}
	if len(pending) == 0 {
		return receipt, nil
	}

	stagePath, err := os.MkdirTemp(fmt.Sprintf("/proc/self/fd/%d", workFD.Fd()), ".devicebridge-import-")
	if err != nil {
		return receipt, err
	}
	stageName := filepath.Base(stagePath)
	defer work.RemoveAll(stageName)
	stage, err := work.OpenRoot(stageName)
	if err != nil {
		return receipt, err
	}
	defer stage.Close()
	stageFD, err := stage.Open(".")
	if err != nil {
		return receipt, err
	}
	defer stageFD.Close()
	for _, want := range pending {
		got, err := stageFile(ctx, source, stage, want.Path, want.Size)
		if err != nil {
			return receipt, err
		}
		if got != want {
			return receipt, fmt.Errorf("projection entry changed after verification: %q", want.Path)
		}
	}
	_, final, err := Preflight(ctx, rootPath)
	if err != nil || final != state {
		return receipt, errors.Join(errors.New("Git state changed immediately before import"), err)
	}
	for _, entry := range pending {
		if err := ctx.Err(); err != nil {
			return receipt, err
		}
		parent, err := openProjectParent(int(workFD.Fd()), entry.Path, true)
		if err != nil {
			return receipt, err
		}
		err = unix.Renameat2(int(stageFD.Fd()), entry.Path, parent, path.Base(entry.Path), unix.RENAME_NOREPLACE)
		if err == nil {
			receipt.Added++
			err = unix.Fsync(parent)
		}
		unix.Close(parent)
		if err != nil {
			return receipt, fmt.Errorf("import stopped at %q: %w", entry.Path, err)
		}
	}
	return receipt, nil
}

func currentFileMatches(ctx context.Context, root int, entry protocol.ManifestEntry) (bool, error) {
	parent, err := openProjectParent(root, entry.Path, false)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer unix.Close(parent)
	fd, err := unix.Openat(parent, path.Base(entry.Path), unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	source := os.NewFile(uintptr(fd), entry.Path)
	defer source.Close()
	info, err := source.Stat()
	if err != nil {
		return false, err
	}
	conflict := fmt.Errorf("a different local file already owns %q", entry.Path)
	if !info.Mode().IsRegular() || info.Size() != entry.Size {
		return false, conflict
	}
	digest := xxhash.New()
	n, err := io.Copy(digest, io.LimitReader(contextReader{ctx, source}, entry.Size+1))
	if err != nil {
		return false, err
	}
	if n != entry.Size || hex.EncodeToString(digest.Sum(nil)) != entry.XXH64 {
		return false, conflict
	}
	return true, nil
}

// Each directory is opened without following symlinks. The final rename uses
// the resulting descriptor, so it cannot traverse a substituted path.
func openProjectParent(root int, rel string, create bool) (int, error) {
	current, err := unix.FcntlInt(uintptr(root), unix.F_DUPFD_CLOEXEC, 0)
	if err != nil {
		return 0, err
	}
	parent := path.Dir(rel)
	if parent == "." {
		return current, nil
	}
	for _, name := range strings.Split(parent, "/") {
		const flags = unix.O_RDONLY | unix.O_NOFOLLOW | unix.O_DIRECTORY | unix.O_CLOEXEC
		next, err := unix.Openat(current, name, flags, 0)
		if errors.Is(err, fs.ErrNotExist) && create {
			err = unix.Mkdirat(current, name, 0700)
			if err == nil || errors.Is(err, fs.ErrExist) {
				next, err = unix.Openat(current, name, flags, 0)
			}
		}
		unix.Close(current)
		if err != nil {
			return 0, fmt.Errorf("cannot open project directory %q: %w", name, err)
		}
		current = next
		var metadata unix.Stat_t
		err = unix.Fstatat(current, ".git", &metadata, unix.AT_SYMLINK_NOFOLLOW)
		if !errors.Is(err, fs.ErrNotExist) {
			unix.Close(current)
			return 0, fmt.Errorf("project path crosses a nested Git repository at %q", name)
		}
	}
	return current, nil
}
