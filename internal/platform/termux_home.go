package platform

import (
	"errors"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

// LockTermuxHome keeps the Home directory attached to running shell sessions
// while allowing read-only backups. Restore takes the exclusive lock.
func LockTermuxHome(home string, restore bool) (*os.File, error) {
	file, err := os.OpenFile(filepath.Join(filepath.Dir(home), ".home-restore.lock"),
		os.O_CREATE|os.O_RDWR|unix.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	mode := unix.LOCK_SH
	if restore {
		mode = unix.LOCK_EX
	}
	if err := unix.Flock(int(file.Fd()), mode|unix.LOCK_NB); err != nil {
		_ = file.Close()
		if errors.Is(err, unix.EWOULDBLOCK) {
			return nil, errors.New("close Terminal and SSH sessions before restoring Terminal Home")
		}
		return nil, err
	}
	return file, nil
}
