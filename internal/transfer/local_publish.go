package transfer

import (
	"errors"
	"fmt"
	"golang.org/x/sys/unix"
	"os"
	"path/filepath"
	"strings"
)

// MoveLocalNoReplace renames an app-selected local item without overwriting
// an entry that appears at the destination. Callers check their storage scope.
func MoveLocalNoReplace(source, destination string) error {
	if !filepath.IsAbs(source) || !filepath.IsAbs(destination) {
		return errors.New("absolute local paths required")
	}
	src, dst := filepath.Clean(source), filepath.Clean(destination)
	if src == "/" || dst == "/" {
		return errors.New("cannot move a storage root")
	}
	open := func(path string) (*os.File, error) {
		parent := filepath.Dir(path)
		resolved, err := filepath.EvalSymlinks(parent)
		if err != nil {
			return nil, err
		}
		if resolved != parent {
			return nil, errors.New("symbolic link access disabled")
		}
		dir, err := os.OpenRoot(parent)
		if err != nil {
			return nil, err
		}
		defer dir.Close()
		return dir.Open(".")
	}
	from, err := open(src)
	if err != nil {
		return err
	}
	defer from.Close()
	to, err := open(dst)
	if err != nil {
		return err
	}
	defer to.Close()
	if err := unix.Renameat2(int(from.Fd()), filepath.Base(src), int(to.Fd()), filepath.Base(dst), unix.RENAME_NOREPLACE); err != nil {
		return fmt.Errorf("local move without overwrite: %w", err)
	}
	return nil
}

// PublishLocal commits only an operation-owned, already verified sibling stage.
// Kotlin validates its storage grant and rechecks every completed file first.
func PublishLocal(source, destination string) error {
	src, err := filepath.Abs(source)
	if err != nil {
		return err
	}
	dst, err := filepath.Abs(destination)
	if err != nil {
		return err
	}
	stage := filepath.Base(filepath.Dir(src))
	parent := filepath.Dir(dst)
	if filepath.Base(src) != "data" || !strings.HasPrefix(stage, ".devicebridge-local-") || len(stage) < len(".devicebridge-local-")+16 || filepath.Dir(filepath.Dir(src)) != parent {
		return errors.New("invalid local staging location")
	}
	root, err := os.OpenRoot(parent)
	if err != nil {
		return err
	}
	defer root.Close()
	info, err := root.Lstat(stage)
	if err != nil || !info.IsDir() {
		return errors.New("unsafe local staging directory")
	}
	payload, err := root.Lstat(filepath.Join(stage, "data"))
	if err != nil || (payload.Mode()&os.ModeSymlink) != 0 {
		return errors.New("unsafe local staged payload")
	}
	fd, err := root.Open(".")
	if err != nil {
		return err
	}
	defer fd.Close()
	if err = unix.Renameat2(int(fd.Fd()), stage+"/data", int(fd.Fd()), filepath.Base(dst), unix.RENAME_NOREPLACE); err != nil {
		return fmt.Errorf("local publish without overwrite: %w", err)
	}
	if err = fd.Sync(); err != nil && !errors.Is(err, unix.EINVAL) {
		return err
	}
	return nil
}
