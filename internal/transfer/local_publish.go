package transfer

import (
	"errors"
	"fmt"
	"golang.org/x/sys/unix"
	"os"
	"path/filepath"
	"strings"
)

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
