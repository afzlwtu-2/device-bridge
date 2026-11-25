package transfer

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
	"syscall"
	"unicode/utf8"

	"github.com/cespare/xxhash/v2"
	"golang.org/x/sys/unix"
)

const MaxSharedFileBytes = 64 << 20

var ErrInvalidSharedFile = errors.New("invalid shared file metadata")
var ErrSharedFileContent = errors.New("shared file size or XXH64 mismatch")
var ErrSharedFileExists = errors.New("a file with this name is already in the inbox")

const sharedFileStagePrefix = ".devicebridge-incoming-"

type SharedFile struct {
	Name  string `json:"name"`
	Size  int64  `json:"size"`
	XXH64 string `json:"xxh64"`
}

type SharedInboxEntry struct {
	Name      string `json:"name"`
	Size      int64  `json:"size"`
	Directory bool   `json:"directory,omitempty"`
}

func ListSharedFileInbox(state string) ([]SharedInboxEntry, error) {
	inbox, err := OpenSharedFileInbox(state)
	if err != nil {
		return nil, err
	}
	defer inbox.Close()
	dir, err := inbox.Open(".")
	if err != nil {
		return nil, err
	}
	defer dir.Close()
	entries, err := dir.ReadDir(-1)
	if err != nil {
		return nil, err
	}
	out := []SharedInboxEntry{}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), sharedFileStagePrefix) {
			continue
		}
		info, err := entry.Info()
		if err == nil && info.Mode().IsRegular() {
			out = append(out, SharedInboxEntry{Name: entry.Name(), Size: info.Size()})
		} else if err == nil && info.IsDir() {
			out = append(out, SharedInboxEntry{Name: entry.Name(), Directory: true})
		}
	}
	slices.SortFunc(out, func(a, b SharedInboxEntry) int { return strings.Compare(a.Name, b.Name) })
	return out, nil
}

type sharedFileReader struct {
	ctx context.Context
	r   io.Reader
}

func (r sharedFileReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.r.Read(p)
}

func validSharedName(name string) bool {
	return name != "." && name != ".." && strings.TrimSpace(name) != "" &&
		!strings.ContainsAny(name, "/\\\x00\r\n") && !strings.HasPrefix(name, sharedFileStagePrefix) &&
		len(name) <= 255 && utf8.ValidString(name)
}

// ReceiveSharedFile copies a single file into an already-open private directory,
// verifies its staged bytes, then publishes atomically without replacing a name.
func ReceiveSharedFile(ctx context.Context, inbox *os.Root, input io.Reader, expected SharedFile, authorize func() error) error {
	name := expected.Name
	if !validSharedName(name) || expected.Size < 0 || expected.Size > MaxSharedFileBytes {
		return ErrInvalidSharedFile
	}
	if _, err := hex.DecodeString(expected.XXH64); err != nil || len(expected.XXH64) != 16 {
		return ErrInvalidSharedFile
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	parent, err := inbox.Open(".")
	if err != nil {
		return err
	}
	defer parent.Close()

	nonce := make([]byte, 16)
	if _, err = rand.Read(nonce); err != nil {
		return err
	}
	stage := sharedFileStagePrefix + hex.EncodeToString(nonce)
	file, err := inbox.OpenFile(stage, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	defer inbox.Remove(stage)
	defer file.Close()

	n, err := io.Copy(file, io.LimitReader(sharedFileReader{ctx, input}, expected.Size+1))
	if err != nil {
		return err
	}
	if n != expected.Size {
		return ErrSharedFileContent
	}
	if _, err = file.Seek(0, io.SeekStart); err != nil {
		return err
	}
	digest := xxhash.New()
	if _, err = io.Copy(digest, sharedFileReader{ctx, file}); err != nil {
		return err
	}
	if !strings.EqualFold(fmt.Sprintf("%016x", digest.Sum64()), expected.XXH64) {
		return ErrSharedFileContent
	}
	if os.Geteuid() == 0 {
		info, err := parent.Stat()
		if err != nil {
			return err
		}
		owner, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			return errors.New("inbox ownership unavailable")
		}
		if err := file.Chown(int(owner.Uid), int(owner.Gid)); err != nil {
			return err
		}
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if authorize != nil {
		if err := authorize(); err != nil {
			return err
		}
	}
	fd := int(parent.Fd())
	err = unix.Renameat2(fd, stage, fd, name, unix.RENAME_NOREPLACE)
	if errors.Is(err, unix.EEXIST) {
		return ErrSharedFileExists
	}
	if err != nil {
		return err
	}
	return parent.Sync()
}

// OpenSharedFileInbox anchors the managed inbox to the app's private state.
func OpenSharedFileInbox(state string) (*os.Root, error) {
	root, err := os.OpenRoot(state)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	const folder = "shared-files"
	createErr := root.Mkdir(folder, 0700)
	if createErr != nil && !os.IsExist(createErr) {
		return nil, createErr
	}
	// A directory symlink is not a managed inbox.
	expected, err := root.Lstat(folder)
	if err != nil {
		return nil, err
	}
	if !expected.IsDir() || expected.Mode().Perm()&0077 != 0 {
		return nil, errors.New("shared files inbox must be a private directory")
	}
	inbox, err := root.OpenRoot(folder)
	if err != nil {
		return nil, err
	}
	ok := false
	defer func() {
		if !ok {
			inbox.Close()
		}
	}()
	info, err := inbox.Stat(".")
	if err != nil || !os.SameFile(expected, info) {
		return nil, errors.New("shared files inbox changed")
	}
	if os.Geteuid() == 0 && createErr == nil {
		stateInfo, err := root.Stat(".")
		if err != nil {
			return nil, err
		}
		owner, ok := stateInfo.Sys().(*syscall.Stat_t)
		if !ok {
			return nil, errors.New("state ownership unavailable")
		}
		if err := inbox.Chown(".", int(owner.Uid), int(owner.Gid)); err != nil {
			return nil, err
		}
	}
	ok = true
	return inbox, nil
}
