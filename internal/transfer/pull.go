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
	"time"
)

const ChunkSize = 4 << 20

var ErrNonRetriable = errors.New("non-retriable transfer policy or integrity error")

type Source interface {
	ReadRange(context.Context, string, string, int64, int64) ([]byte, error)
}
type StreamSource interface {
	OpenStream(context.Context, string, string, int64) (io.ReadCloser, error)
}
type Progress struct {
	File          string  `json:"file"`
	VerifiedBytes int64   `json:"verified_bytes"`
	TotalBytes    int64   `json:"total_bytes"`
	MiBPerSecond  float64 `json:"mib_per_second"`
	ElapsedMillis int64   `json:"elapsed_ms"`
	Method        string  `json:"method,omitempty"`
	Transport     string  `json:"transport,omitempty"`
}
type Receipt struct {
	Destination   string  `json:"destination"`
	Files         int     `json:"files"`
	Bytes         int64   `json:"bytes"`
	SHA256        string  `json:"manifest_sha256"`
	Mode          string  `json:"mode,omitempty"`
	Transport     string  `json:"transport,omitempty"`
	MiBPerSecond  float64 `json:"mib_per_second"`
	ElapsedMillis int64   `json:"elapsed_ms"`
}

func rateMiB(bytes int64, started time.Time) (float64, int64) {
	elapsed := time.Since(started)
	ms := elapsed.Milliseconds()
	if bytes <= 0 || elapsed <= 0 {
		return 0, ms
	}
	secs := elapsed.Seconds()
	if secs < 0.001 {
		secs = 0.001
	}
	return float64(bytes) / (1024 * 1024) / secs, ms
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

type stagingHandle struct {
	parent       *os.Root
	root         *os.Root
	lock         *os.File
	abs          string
	base         string
	stage        string
	manifestHash string
}

func (s *stagingHandle) close() {
	if s.lock != nil {
		_ = unix.Flock(int(s.lock.Fd()), unix.LOCK_UN)
		_ = s.lock.Close()
	}
	if s.root != nil {
		_ = s.root.Close()
	}
	if s.parent != nil {
		_ = s.parent.Close()
	}
}

func openStaging(peer string, m protocol.Manifest, destination string) (*stagingHandle, error) {
	if err := ValidateManifest(m); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrNonRetriable, err)
	}
	if filesproviders.ValidPath(m.Path) != nil {
		return nil, fmt.Errorf("%w: invalid source path", ErrNonRetriable)
	}
	abs, err := filepath.Abs(destination)
	if err != nil {
		return nil, err
	}
	base := filepath.Base(abs)
	if base == "." || base == string(filepath.Separator) || strings.HasSuffix(base, ".devicebridge-part") {
		return nil, fmt.Errorf("%w: invalid destination", ErrNonRetriable)
	}
	parent, err := os.OpenRoot(filepath.Dir(abs))
	if err != nil {
		return nil, err
	}
	h := &stagingHandle{parent: parent, abs: abs, base: base, stage: base + ".devicebridge-part"}
	if _, e := parent.Lstat(base); !errors.Is(e, os.ErrNotExist) {
		h.close()
		return nil, fmt.Errorf("%w: destination exists or cannot be inspected; overwrite denied", ErrNonRetriable)
	}
	err = parent.Mkdir(h.stage, 0700)
	if err != nil && !errors.Is(err, os.ErrExist) {
		h.close()
		return nil, err
	}
	info, err := parent.Lstat(h.stage)
	if err != nil || !info.IsDir() || info.Mode()&0077 != 0 {
		h.close()
		return nil, fmt.Errorf("%w: staging must be a private real directory", ErrNonRetriable)
	}
	root, err := parent.OpenRoot(h.stage)
	if err != nil {
		h.close()
		return nil, err
	}
	h.root = root
	lock, err := root.OpenFile(".lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		h.close()
		return nil, err
	}
	if err = unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		lock.Close()
		h.close()
		return nil, fmt.Errorf("%w: another pull owns this staging directory", ErrNonRetriable)
	}
	h.lock = lock
	metadata, err := json.Marshal(struct {
		Peer     string
		Manifest protocol.Manifest
	}{peer, m})
	if err != nil {
		h.close()
		return nil, err
	}
	hash := sha256.Sum256(metadata)
	h.manifestHash = hex.EncodeToString(hash[:])
	previous, e := root.ReadFile("manifest.json")
	if e == nil {
		if string(previous) != string(metadata) {
			h.close()
			return nil, fmt.Errorf("%w: source manifest changed; preserve old staging and choose a new destination", ErrNonRetriable)
		}
	} else if errors.Is(e, os.ErrNotExist) {
		f, e := root.OpenFile("manifest.json", os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if e != nil {
			h.close()
			return nil, e
		}
		_, e = f.Write(metadata)
		if e == nil {
			e = f.Sync()
		}
		f.Close()
		if e != nil {
			h.close()
			return nil, e
		}
	} else {
		h.close()
		return nil, e
	}
	if m.Entries[0].Directory {
		if err = root.MkdirAll("data", 0700); err != nil {
			h.close()
			return nil, err
		}
	}
	return h, nil
}

func (s *stagingHandle) publish() error {
	// Linux and Android use the same atomic no-replace primitive. It never
	// overwrites a destination created after the initial existence check.
	fd, err := s.parent.Open(".")
	if err != nil {
		return err
	}
	defer fd.Close()
	if err = unix.Renameat2(int(fd.Fd()), s.stage+"/data", int(fd.Fd()), s.base, unix.RENAME_NOREPLACE); err != nil {
		return fmt.Errorf("atomic publish (no overwrite): %w", err)
	}
	if err = fd.Sync(); err != nil {
		return fmt.Errorf("published but directory sync failed: %w", err)
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
	st, err := openStaging(peer, m, destination)
	if err != nil {
		return receipt, err
	}
	defer st.close()
	started := time.Now()
	var complete int64
	var sessionBytes int64
	count := 0
	usedStream := false
	buf := make([]byte, ChunkSize)
	for _, entry := range m.Entries {
		if err = ctx.Err(); err != nil {
			return receipt, err
		}
		target := path.Join("data", entry.Path)
		if entry.Directory {
			if err = st.root.MkdirAll(target, 0700); err != nil {
				return receipt, err
			}
			continue
		}
		f, e := st.root.OpenFile(target, os.O_CREATE|os.O_RDWR, 0600)
		if e != nil {
			return receipt, e
		}
		info, e := f.Stat()
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
		streamed := false
		if offset < entry.Size {
			if ss, ok := source.(StreamSource); ok {
				rc, se := ss.OpenStream(ctx, m.Root, path.Join(m.Path, entry.Path), offset)
				if se == nil {
					streamed = true
					usedStream = true
					var sinceSync, sinceReport int64
					for offset < entry.Size {
						if err = ctx.Err(); err != nil {
							rc.Close()
							f.Close()
							return receipt, err
						}
						nRead, re := rc.Read(buf)
						if nRead > 0 {
							if offset+int64(nRead) > entry.Size {
								rc.Close()
								f.Close()
								return receipt, errors.New("stream exceeded expected file size")
							}
							written, we := f.Write(buf[:nRead])
							if we != nil || written != nRead {
								rc.Close()
								f.Close()
								return receipt, errors.New("staging write failed (check free space)")
							}
							offset += int64(nRead)
							sessionBytes += int64(nRead)
							sinceSync += int64(nRead)
							sinceReport += int64(nRead)
							if sinceSync >= 16<<20 {
								if se = f.Sync(); se != nil {
									rc.Close()
									f.Close()
									return receipt, se
								}
								sinceSync = 0
							}
							if progress != nil && (sinceReport >= 1<<20 || offset == entry.Size) {
								mib, ms := rateMiB(sessionBytes, started)
								progress(Progress{File: entry.Path, VerifiedBytes: complete + offset, TotalBytes: m.Bytes, MiBPerSecond: mib, ElapsedMillis: ms, Method: "stream"})
								sinceReport = 0
							}
						}
						if re == io.EOF {
							break
						}
						if re != nil {
							rc.Close()
							f.Close()
							return receipt, re
						}
					}
					rc.Close()
					if offset != entry.Size {
						f.Close()
						return receipt, errors.New("truncated file stream")
					}
				} else if !strings.Contains(se.Error(), "remote 404") {
					f.Close()
					return receipt, se
				}
			}
		}
		if !streamed {
			var sinceSync int64
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
				sessionBytes += n
				sinceSync += n
				if sinceSync >= 16<<20 || offset == entry.Size {
					if e = f.Sync(); e != nil {
						f.Close()
						return receipt, e
					}
					sinceSync = 0
				}
				if progress != nil {
					mib, ms := rateMiB(sessionBytes, started)
					progress(Progress{File: entry.Path, VerifiedBytes: complete + offset, TotalBytes: m.Bytes, MiBPerSecond: mib, ElapsedMillis: ms, Method: "direct"})
				}
			}
		} else if e = f.Sync(); e != nil {
			f.Close()
			return receipt, e
		}
		actual, e := digestFile(ctx, f)
		f.Close()
		if e != nil {
			return receipt, e
		}
		if actual != entry.SHA256 {
			return receipt, fmt.Errorf("%w: checksum mismatch for %q; staging preserved", ErrNonRetriable, entry.Path)
		}
		complete += entry.Size
		count++
	}
	if err = st.publish(); err != nil {
		return receipt, err
	}
	mib, ms := rateMiB(sessionBytes, started)
	mode := "chunked"
	if usedStream {
		mode = "stream"
	}
	// Metadata is small and retained as a receipt; never remove user payloads.
	receipt = Receipt{Destination: st.abs, Files: count, Bytes: complete, SHA256: st.manifestHash, Mode: mode, MiBPerSecond: mib, ElapsedMillis: ms}
	return receipt, nil
}
