package transfer

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path"

	"devicebridge/internal/files"
	"devicebridge/internal/filesproviders"
	"golang.org/x/sys/unix"
)

// RemoveVerified retires only entries verified at the destination. Each file
// is moved out of the live pathname before its final XXH64 check. A replacement
// at the original path is preserved, and a changed file is restored atomically.
func RemoveVerified(ctx context.Context, source *filesproviders.Native, relative, expected string, excludes []string, authorize func(int64) error) (bool, error) {
	if relative == "" || relative == "." || filesproviders.ValidPath(relative) != nil {
		return true, errors.New("a storage root cannot be moved")
	}
	digest, err := hex.DecodeString(expected)
	if err != nil || len(digest) != 8 {
		return true, errors.New("move requires a verified copy receipt")
	}
	manifest, err := files.Manifest(ctx, source, relative, authorize, excludes...)
	if err != nil {
		return true, err
	}
	if expected != files.ContentXXH64(manifest) {
		return true, errors.New("source changed; verified copy retained and source preserved")
	}
	base, err := source.OpenSyncDirectory(ctx, path.Dir(relative))
	if err != nil {
		return true, err
	}
	defer base.Close()
	root, err := os.OpenRoot(fmt.Sprintf("/proc/self/fd/%d", base.Fd()))
	if err != nil {
		return true, err
	}
	defer root.Close()
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return true, err
	}
	stageName := ".devicebridge-move-" + hex.EncodeToString(nonce[:])
	if err := root.Mkdir(stageName, 0700); err != nil {
		return true, err
	}
	// Remove only an empty stage. A failed restoration leaves its contents
	// accessible to the storage owner under the named recovery path.
	defer root.Remove(stageName)
	stage, err := root.OpenFile(stageName, os.O_RDONLY|unix.O_NOFOLLOW|unix.O_DIRECTORY, 0)
	if err != nil {
		return true, err
	}
	defer stage.Close()
	for i := len(manifest.Entries) - 1; i >= 0; i-- {
		entry := manifest.Entries[i]
		if err := ctx.Err(); err != nil {
			return true, err
		}
		if err := authorize(manifest.Bytes); err != nil {
			return true, err
		}
		full := path.Join(relative, entry.Path)
		parent, err := source.OpenSyncDirectory(ctx, path.Dir(full))
		if err != nil {
			return true, err
		}
		fd := int(parent.Fd())
		if entry.Directory {
			err = unix.Unlinkat(fd, path.Base(full), unix.AT_REMOVEDIR)
			if errors.Is(err, unix.ENOTEMPTY) {
				err = nil // Excluded or newly created entries stay in place.
			}
		} else {
			err = retireFile(ctx, fd, int(stage.Fd()), path.Base(full), entry.XXH64, func() error {
				return authorize(manifest.Bytes)
			})
		}
		parent.Close()
		if err != nil {
			return true, fmt.Errorf("verified copy retained; source cleanup stopped at %q (recovery folder %s): %w", full, stageName, err)
		}
	}
	_, err = source.Stat(ctx, relative)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return true, err
}

func retireFile(ctx context.Context, parent, stage int, name, expected string, authorize func() error) error {
	if err := unix.Renameat2(parent, name, stage, "data", unix.RENAME_NOREPLACE); err != nil {
		return err
	}
	err := verifyRetiredFile(ctx, stage, expected)
	if err == nil {
		err = authorize()
	}
	if err == nil {
		err = unix.Unlinkat(stage, "data", 0)
		if err == nil {
			return nil
		}
	}
	restore := unix.Renameat2(stage, "data", parent, name, unix.RENAME_NOREPLACE)
	if restore != nil {
		return errors.Join(err, fmt.Errorf("source recovery copy kept: %w", restore))
	}
	return err
}

func verifyRetiredFile(ctx context.Context, stage int, expected string) error {
	fd, err := unix.Openat(stage, "data", os.O_RDONLY|unix.O_NONBLOCK|unix.O_NOFOLLOW, 0)
	if err != nil {
		return err
	}
	file := os.NewFile(uintptr(fd), "data")
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return errors.New("source type changed before deletion")
	}
	actual, err := digestFile(ctx, file)
	if err != nil {
		return err
	}
	if actual != expected {
		return errors.New("source changed before deletion")
	}
	return nil
}
