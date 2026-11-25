package transfer

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"

	"devicebridge/internal/files"
	"devicebridge/protocol"

	"github.com/cespare/xxhash/v2"
	"golang.org/x/sys/unix"
)

const (
	SharedFolderFeature          = "quick-share-folder-v1"
	MaxSharedFolderBytes         = int64(1 << 30)
	MaxSharedFolderEntries       = 4096
	maxSharedFolderManifestBytes = 4 << 20
)

type SharedFolder struct {
	Name  string `json:"name"`
	Size  int64  `json:"size"`
	Files int    `json:"files"`
	XXH64 string `json:"manifest_xxh64"`
}

func sharedFolderReceipt(name string, raw []byte, manifest protocol.Manifest) SharedFolder {
	files := 0
	for _, entry := range manifest.Entries {
		if !entry.Directory {
			files++
		}
	}
	return SharedFolder{Name: name, Size: manifest.Bytes, Files: files, XXH64: fmt.Sprintf("%016x", xxhash.Sum64(raw))}
}

type treeTransferLimits struct {
	root    string
	bytes   int64
	entries int
	folders bool
}

var shareTreeLimits = treeTransferLimits{"share", MaxSharedFolderBytes, MaxSharedFolderEntries, true}
var filesTreeLimits = treeTransferLimits{"files", files.MaxManifestBytes, files.MaxManifestEntries, false}

func (limits treeTransferLimits) validate(name string, manifest protocol.Manifest) error {
	if !validSharedName(name) || manifest.Root != limits.root || manifest.Path != "." ||
		len(manifest.Entries) > limits.entries || manifest.Bytes > limits.bytes ||
		len(manifest.Excludes) != 0 || ValidateManifest(manifest) != nil ||
		(limits.folders && !manifest.Entries[0].Directory) {
		return ErrInvalidSharedFile
	}
	return nil
}

func EncodeSharedFolder(name string, manifest protocol.Manifest) ([]byte, SharedFolder, error) {
	return encodeTree(name, manifest, shareTreeLimits)
}

func EncodeManagedTree(name string, manifest protocol.Manifest) ([]byte, SharedFolder, error) {
	return encodeTree(name, manifest, filesTreeLimits)
}

func encodeTree(name string, manifest protocol.Manifest, limits treeTransferLimits) ([]byte, SharedFolder, error) {
	if err := limits.validate(name, manifest); err != nil {
		return nil, SharedFolder{}, err
	}
	raw, err := json.Marshal(manifest)
	if err != nil {
		return nil, SharedFolder{}, err
	}
	if len(raw) > maxSharedFolderManifestBytes {
		return nil, SharedFolder{}, ErrInvalidSharedFile
	}
	frame := binary.BigEndian.AppendUint32(nil, uint32(len(raw)))
	return append(frame, raw...), sharedFolderReceipt(name, raw, manifest), nil
}

// ReceiveSharedFolder verifies the private staged tree, then publishes it as
// one inbox entry after checking that the receiver still grants access.
func ReceiveSharedFolder(ctx context.Context, inbox *os.Root, input io.Reader, peer, name, codec string, authorize func() error) (SharedFolder, error) {
	return receiveTree(ctx, inbox, input, peer, name, codec, shareTreeLimits, func(int64) error {
		if authorize == nil {
			return nil
		}
		return authorize()
	})
}

func ReceiveManagedTree(ctx context.Context, folder *os.Root, input io.Reader, peer, name string, authorize func(int64) error) (SharedFolder, error) {
	return receiveTree(ctx, folder, input, peer, name, "none", filesTreeLimits, authorize)
}

func receiveTree(ctx context.Context, inbox *os.Root, input io.Reader, peer, name, codec string, limits treeTransferLimits, authorize func(int64) error) (SharedFolder, error) {
	var empty SharedFolder
	if !validSharedName(name) || (codec != "none" && codec != "gzip") {
		return empty, ErrInvalidSharedFile
	}
	var length [4]byte
	if _, err := io.ReadFull(input, length[:]); err != nil {
		return empty, ErrInvalidSharedFile
	}
	n := binary.BigEndian.Uint32(length[:])
	if n == 0 || n > maxSharedFolderManifestBytes {
		return empty, ErrInvalidSharedFile
	}
	raw := make([]byte, n)
	if _, err := io.ReadFull(input, raw); err != nil {
		return empty, ErrInvalidSharedFile
	}
	var manifest protocol.Manifest
	if json.Unmarshal(raw, &manifest) != nil || limits.validate(name, manifest) != nil {
		return empty, ErrInvalidSharedFile
	}
	if err := authorize(manifest.Bytes); err != nil {
		return empty, err
	}
	if _, err := inbox.Lstat(name); !errors.Is(err, fs.ErrNotExist) {
		if err != nil {
			return empty, err
		}
		return empty, ErrSharedFileExists
	}
	parent, err := inbox.Open(".")
	if err != nil {
		return empty, err
	}
	defer parent.Close()
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return empty, err
	}
	stage := sharedFileStagePrefix + hex.EncodeToString(nonce[:])
	if err := inbox.Mkdir(stage, 0700); err != nil {
		return empty, err
	}
	defer inbox.RemoveAll(stage)
	fd := int(parent.Fd())
	dest := filepath.Join(fmt.Sprintf("/proc/self/fd/%d", fd), stage, "verified")
	if _, err := pullTar(ctx, io.NopCloser(input), codec, peer, manifest, dest, nil, manifest.Bytes+(32<<20)); err != nil {
		return empty, fmt.Errorf("%w: %v", ErrSharedFileContent, err)
	}
	if os.Geteuid() == 0 {
		info, err := parent.Stat()
		if err != nil {
			return empty, err
		}
		owner, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			return empty, errors.New("inbox ownership unavailable")
		}
		for i := len(manifest.Entries) - 1; i >= 0; i-- {
			entry := manifest.Entries[i]
			if err := inbox.Chown(filepath.Join(stage, "verified", entry.Path), int(owner.Uid), int(owner.Gid)); err != nil {
				return empty, err
			}
		}
	}
	if err := ctx.Err(); err != nil {
		return empty, err
	}
	if err := authorize(0); err != nil {
		return empty, err
	}
	err = unix.Renameat2(fd, stage+"/verified", fd, name, unix.RENAME_NOREPLACE)
	if errors.Is(err, unix.EEXIST) {
		return empty, ErrSharedFileExists
	}
	if err != nil {
		return empty, err
	}
	if err := parent.Sync(); err != nil {
		return empty, err
	}
	return sharedFolderReceipt(name, raw, manifest), nil
}
