// Package transfer stages resumable, checksum-verified one-off downloads.
package transfer

import (
	"context"
	"crypto/sha256"
	"devicebridge/internal/files"
	"devicebridge/internal/filesproviders"
	"devicebridge/protocol"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"golang.org/x/sys/unix"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
)

const ChunkSize = 1 << 20

type Source interface {
	ReadRange(context.Context, string, string, int64, int64) ([]byte, error)
}
type Progress struct {
	File          string `json:"file"`
	VerifiedBytes int64  `json:"verified_bytes"`
	TotalBytes    int64  `json:"total_bytes"`
}
type Receipt struct {
	Destination string `json:"destination"`
	Files       int    `json:"files"`
	Bytes       int64  `json:"bytes"`
	SHA256      string `json:"manifest_sha256"`
}

func ValidateManifest(m protocol.Manifest) error {
	if m.Version != 1 || len(m.Entries) == 0 || len(m.Entries) > files.MaxManifestEntries || m.Bytes < 0 || m.Bytes > files.MaxManifestBytes {
		return errors.New("invalid manifest bounds")
	}
	seen := map[string]bool{}
	dirs := map[string]bool{}
	var total int64
	for i, e := range m.Entries {
		if filesproviders.ValidPath(e.Path) != nil || e.Path == "" || path.Clean(e.Path) != e.Path || seen[e.Path] || e.Size < 0 {
			return errors.New("unsafe or duplicate manifest entry")
		}
		if i == 0 && e.Path != "." {
			return errors.New("manifest root missing")
		}
		if i > 0 && !dirs[path.Dir(e.Path)] {
			return errors.New("manifest parent missing or non-directory")
		}
		seen[e.Path] = true
		if e.Directory {
			if e.Size != 0 || e.SHA256 != "" {
				return errors.New("invalid directory metadata")
			}
			dirs[e.Path] = true
		} else {
			h, err := hex.DecodeString(e.SHA256)
			if err != nil || len(h) != 32 || total > files.MaxManifestBytes-e.Size {
				return errors.New("invalid file checksum or size")
			}
			total += e.Size
		}
	}
	if total != m.Bytes {
		return errors.New("manifest byte count mismatch")
	}
	return nil
}
func digestFile(ctx context.Context, f *os.File) (string, error) {
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return "", err
	}
	h := sha256.New()
	buf := make([]byte, 256<<10)
	for {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		n, err := f.Read(buf)
		if n > 0 {
			h.Write(buf[:n])
		}
		if err == io.EOF {
			return hex.EncodeToString(h.Sum(nil)), nil
		}
		if err != nil {
			return "", err
		}
	}
}
func Pull(ctx context.Context, source Source, peer string, m protocol.Manifest, destination string, progress func(Progress)) (Receipt, error) {
	var receipt Receipt
	if err := ValidateManifest(m); err != nil {
		return receipt, err
	}
	if filesproviders.ValidPath(m.Path) != nil {
		return receipt, errors.New("invalid source path")
	}
	abs, err := filepath.Abs(destination)
	if err != nil {
		return receipt, err
	}
	base := filepath.Base(abs)
	if base == "." || base == string(filepath.Separator) || strings.HasSuffix(base, ".devicebridge-part") {
		return receipt, errors.New("invalid destination")
	}
	parent, err := os.OpenRoot(filepath.Dir(abs))
	if err != nil {
		return receipt, err
	}
	defer parent.Close()
	if _, e := parent.Lstat(base); !errors.Is(e, os.ErrNotExist) {
		return receipt, errors.New("destination exists or cannot be inspected; overwrite denied")
	}
	stage := base + ".devicebridge-part"
	err = parent.Mkdir(stage, 0700)
	if err != nil && !errors.Is(err, os.ErrExist) {
		return receipt, err
	}
	info, err := parent.Lstat(stage)
	if err != nil || !info.IsDir() || info.Mode()&0077 != 0 {
		return receipt, errors.New("staging must be a private real directory")
	}
	root, err := parent.OpenRoot(stage)
	if err != nil {
		return receipt, err
	}
	defer root.Close()
	lock, err := root.OpenFile(".lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return receipt, err
	}
	defer lock.Close()
	if err = unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		return receipt, errors.New("another pull owns this staging directory")
	}
	defer unix.Flock(int(lock.Fd()), unix.LOCK_UN)
	metadata, err := json.Marshal(struct {
		Peer     string
		Manifest protocol.Manifest
	}{peer, m})
	if err != nil {
		return receipt, err
	}
	hash := sha256.Sum256(metadata)
	previous, e := root.ReadFile("manifest.json")
	if e == nil {
		if string(previous) != string(metadata) {
			return receipt, errors.New("source manifest changed; preserve old staging and choose a new destination")
		}
	} else if errors.Is(e, os.ErrNotExist) {
		f, e := root.OpenFile("manifest.json", os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if e != nil {
			return receipt, e
		}
		_, e = f.Write(metadata)
		if e == nil {
			e = f.Sync()
		}
		f.Close()
		if e != nil {
			return receipt, e
		}
	} else {
		return receipt, e
	}
	if m.Entries[0].Directory {
		if err = root.MkdirAll("data", 0700); err != nil {
			return receipt, err
		}
	}
	var complete int64
	count := 0
	for _, entry := range m.Entries {
		if err = ctx.Err(); err != nil {
			return receipt, err
		}
		target := path.Join("data", entry.Path)
		if entry.Directory {
			if err = root.MkdirAll(target, 0700); err != nil {
				return receipt, err
			}
			continue
		}
		f, e := root.OpenFile(target, os.O_CREATE|os.O_RDWR, 0600)
		if e != nil {
			return receipt, e
		}
		info, e = f.Stat()
		if e != nil || !info.Mode().IsRegular() {
			f.Close()
			return receipt, errors.New("staged payload is not a regular file")
		}
		offset := info.Size()
		if offset > entry.Size {
			f.Close()
			return receipt, errors.New("staged payload exceeds source size")
		}
		if _, e = f.Seek(offset, io.SeekStart); e != nil {
			f.Close()
			return receipt, e
		}
		for offset < entry.Size {
			n := min(int64(ChunkSize), entry.Size-offset)
			chunk, e := source.ReadRange(ctx, m.Root, path.Join(m.Path, entry.Path), offset, n)
			if e != nil {
				f.Close()
				return receipt, e
			}
			if int64(len(chunk)) != n {
				f.Close()
				return receipt, errors.New("truncated chunk")
			}
			written, e := f.Write(chunk)
			if e != nil || written != len(chunk) {
				f.Close()
				return receipt, errors.New("staging write failed (check free space)")
			}
			offset += n
			if e = f.Sync(); e != nil {
				f.Close()
				return receipt, e
			}
			if progress != nil {
				progress(Progress{File: entry.Path, VerifiedBytes: complete + offset, TotalBytes: m.Bytes})
			}
		}
		actual, e := digestFile(ctx, f)
		f.Close()
		if e != nil {
			return receipt, e
		}
		if actual != entry.SHA256 {
			return receipt, fmt.Errorf("checksum mismatch for %q; staging preserved", entry.Path)
		}
		complete += entry.Size
		count++
	}
	// Linux and Android use the same atomic no-replace primitive. It never
	// overwrites a destination created after the initial existence check.
	fd, err := parent.Open(".")
	if err != nil {
		return receipt, err
	}
	defer fd.Close()
	if err = unix.Renameat2(int(fd.Fd()), stage+"/data", int(fd.Fd()), base, unix.RENAME_NOREPLACE); err != nil {
		return receipt, fmt.Errorf("atomic publish (no overwrite): %w", err)
	}
	if err = fd.Sync(); err != nil {
		return receipt, fmt.Errorf("published but directory sync failed: %w", err)
	}
	// Metadata is small and retained as a receipt; never remove user payloads.
	receipt = Receipt{Destination: abs, Files: count, Bytes: complete, SHA256: hex.EncodeToString(hash[:])}
	return receipt, nil
}
