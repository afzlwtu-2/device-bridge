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

type WorkingState map[string]protocol.ManifestEntry

func workingControl(name string) bool {
	return name == ".git" || name == ".stfolder" || name == ".stignore" || name == ".stversions" || strings.HasPrefix(name, ".devicebridge-sync-")
}

// SnapshotWorking records content without copying a second baseline tree.
func SnapshotWorking(ctx context.Context, folder string) (WorkingState, error) {
	source, err := filesproviders.NewNative("working-baseline", folder)
	if err != nil {
		return nil, err
	}
	defer source.Close()
	state := WorkingState{}
	var bytes int64
	var walk func(string) error
	walk = func(relative string) error {
		token := ""
		for {
			listing, e := source.List(ctx, relative, token, 200)
			if e != nil {
				return e
			}
			for _, entry := range listing.Entries {
				if workingControl(entry.Name) {
					continue
				}
				if len(state) >= files.MaxManifestEntries {
					return errors.New("too many working files")
				}
				if entry.Kind == "directory" {
					if e = walk(entry.Path); e != nil {
						return e
					}
					continue
				}
				if entry.Kind != "file" || entry.Size < 0 || bytes > files.MaxManifestBytes-entry.Size {
					return errors.New("unsafe or oversized working tree")
				}
				input, e := source.OpenRead(ctx, entry.Path)
				if e != nil {
					return e
				}
				hash := xxhash.New()
				n, e := io.Copy(hash, io.LimitReader(contextReader{ctx, input}, entry.Size+1))
				input.Close()
				if e != nil || n != entry.Size {
					return errors.New("working file changed during baseline")
				}
				state[entry.Path] = protocol.ManifestEntry{Path: entry.Path, Size: n, XXH64: hex.EncodeToString(hash.Sum(nil))}
				bytes += n
			}
			token = listing.Next
			if token == "" {
				return nil
			}
		}
	}
	return state, walk(".")
}

// ApplyWorking merges a verified projection, preserving Git metadata and local
// extras. Replaced baseline files stay in a private recovery directory. Changes
// made during the session cause an explicit conflict, never silent data loss.
func ApplyWorking(ctx context.Context, folder, projection string, manifest protocol.Manifest, baseline WorkingState) error {
	if transfer.ValidateManifest(manifest) != nil {
		return errors.New("invalid working import manifest")
	}
	work, err := os.OpenRoot(folder)
	if err != nil {
		return err
	}
	defer work.Close()
	fd, err := work.Open(".")
	if err != nil {
		return err
	}
	defer fd.Close()
	source, err := filesproviders.NewNative("working-import", projection)
	if err != nil {
		return err
	}
	defer source.Close()
	for _, entry := range manifest.Entries {
		for _, part := range strings.Split(entry.Path, "/") {
			if workingControl(part) {
				return errors.New("working import contains control metadata")
			}
		}
		if entry.Directory {
			continue
		}
		matches, e := currentWorkingMatches(ctx, int(fd.Fd()), entry)
		if e == nil && matches {
			continue
		}
		old, exists := baseline[entry.Path]
		if exists {
			if matches, e = currentWorkingMatches(ctx, int(fd.Fd()), old); e != nil || !matches {
				return fmt.Errorf("local file changed during sync: %s", entry.Path)
			}
		} else if !errors.Is(e, fs.ErrNotExist) {
			return fmt.Errorf("local file conflicts with sync: %s", entry.Path)
		}
	}
	stagePath, err := os.MkdirTemp(fmt.Sprintf("/proc/self/fd/%d", fd.Fd()), ".devicebridge-sync-recovery-")
	if err != nil {
		return err
	}
	// Keep replaced files and any conflict evidence. Empty stages are removed.
	stageName := filepath.Base(stagePath)
	stage, err := work.OpenRoot(stageName)
	if err != nil {
		return err
	}
	defer stage.Close()
	stageFD, err := stage.Open(".")
	if err != nil {
		return err
	}
	defer stageFD.Close()
	retained := false
	defer func() {
		if !retained {
			_ = work.RemoveAll(stageName)
		}
	}()
	for _, want := range manifest.Entries {
		if want.Directory {
			continue
		}
		if matches, e := currentWorkingMatches(ctx, int(fd.Fd()), want); e == nil && matches {
			continue
		}
		got, e := stageFile(ctx, source, stage, want.Path, want.Size)
		if e != nil {
			return e
		}
		if got != want {
			return errors.New("working projection changed during import")
		}
	}
	for _, entry := range manifest.Entries {
		if err := ctx.Err(); err != nil {
			return err
		}
		if entry.Path == "." {
			continue
		}
		parent, e := openWorkingParent(int(fd.Fd()), entry.Path, true)
		if e != nil {
			return e
		}
		if entry.Directory {
			e = unix.Mkdirat(parent, path.Base(entry.Path), 0700)
			unix.Close(parent)
			if e != nil && !errors.Is(e, fs.ErrExist) {
				return e
			}
			continue
		}
		if matches, e := currentWorkingMatches(ctx, int(fd.Fd()), entry); e == nil && matches {
			unix.Close(parent)
			continue
		}
		old, exists := baseline[entry.Path]
		flag := uint(unix.RENAME_NOREPLACE)
		if exists {
			flag = unix.RENAME_EXCHANGE
		}
		e = unix.Renameat2(int(stageFD.Fd()), entry.Path, parent, path.Base(entry.Path), flag)
		if e == nil {
			e = unix.Fsync(parent)
		}
		unix.Close(parent)
		if e != nil {
			return fmt.Errorf("working import stopped at %s: %w", entry.Path, e)
		}
		if exists {
			retained = true
			if matches, e := currentWorkingMatches(ctx, int(stageFD.Fd()), old); e != nil || !matches {
				return fmt.Errorf("concurrent change preserved in %s/%s; review the conflict", stageName, entry.Path)
			}
		}
		if matches, e := currentWorkingMatches(ctx, int(fd.Fd()), entry); e != nil || !matches {
			return errors.New("destination XXH64 verification failed; recovery files retained")
		}
	}
	return fd.Sync()
}

func openWorkingParent(root int, relative string, create bool) (int, error) {
	current, err := unix.FcntlInt(uintptr(root), unix.F_DUPFD_CLOEXEC, 0)
	if err != nil {
		return 0, err
	}
	for _, name := range strings.Split(path.Dir(relative), "/") {
		if name == "." {
			continue
		}
		if workingControl(name) {
			unix.Close(current)
			return 0, errors.New("working path crosses control metadata")
		}
		next, e := unix.Openat(current, name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if errors.Is(e, fs.ErrNotExist) && create {
			e = unix.Mkdirat(current, name, 0700)
			if e == nil || errors.Is(e, fs.ErrExist) {
				next, e = unix.Openat(current, name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
			}
		}
		unix.Close(current)
		if e != nil {
			return 0, e
		}
		current = next
	}
	return current, nil
}

func currentWorkingMatches(ctx context.Context, root int, entry protocol.ManifestEntry) (bool, error) {
	parent, err := openWorkingParent(root, entry.Path, false)
	if err != nil {
		return false, err
	}
	defer unix.Close(parent)
	fd, err := unix.Openat(parent, path.Base(entry.Path), unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return false, err
	}
	file := os.NewFile(uintptr(fd), entry.Path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return false, err
	}
	if !info.Mode().IsRegular() || info.Size() != entry.Size {
		return false, nil
	}
	hash := xxhash.New()
	n, err := io.Copy(hash, io.LimitReader(contextReader{ctx, file}, entry.Size+1))
	if err != nil {
		return false, err
	}
	return n == entry.Size && hex.EncodeToString(hash.Sum(nil)) == entry.XXH64, nil
}
