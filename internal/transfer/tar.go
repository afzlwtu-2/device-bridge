package transfer

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"devicebridge/internal/files"
	"devicebridge/internal/filesproviders"
	"devicebridge/protocol"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"strings"
	"time"
)

// ShouldUseTar chooses streaming archive transport for multi-file directories
// where per-file HTTP range round-trips dominate transfer time.
func ShouldUseTar(m protocol.Manifest) bool {
	if len(m.Entries) <= 1 || !m.Entries[0].Directory {
		return false
	}
	fileCount := 0
	for _, e := range m.Entries {
		if !e.Directory {
			fileCount++
		}
	}
	if fileCount >= 64 {
		return true
	}
	return fileCount >= 16 && m.Bytes/int64(fileCount) <= 512<<10
}

// WriteTar streams a scoped directory tree without creating a temporary archive.
func WriteTar(ctx context.Context, p filesproviders.Provider, rel, codec string, dst io.Writer, authorize func(int64) error, excludes ...string) error {
	normalized, err := files.ValidateExclusions(excludes)
	if err != nil {
		return err
	}
	if codec != "" && codec != "none" && codec != "gzip" {
		return errors.New("unsupported archive codec")
	}
	out := dst
	var gz *gzip.Writer
	if codec == "gzip" {
		var err error
		gz, err = gzip.NewWriterLevel(dst, gzip.BestSpeed)
		if err != nil {
			return err
		}
		out = gz
	}
	tw := tar.NewWriter(out)
	buf := make([]byte, 256<<10)
	entries := 0
	var totalBytes int64
	var walk func(string, string, int) error
	walk = func(src, archivePath string, depth int) error {
		if files.Excluded(archivePath, normalized) {
			return nil
		}
		if depth > 128 || entries >= files.MaxManifestEntries {
			return errors.New("archive entry limit exceeded")
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := authorize(0); err != nil {
			return err
		}
		info, err := p.Stat(ctx, src)
		if err != nil {
			return err
		}
		entries++
		if info.Kind == "directory" {
			if err := tw.WriteHeader(&tar.Header{
				Name:     archivePath + "/",
				Mode:     0755,
				Typeflag: tar.TypeDir,
				ModTime:  info.Modified,
			}); err != nil {
				return err
			}
			token := ""
			for {
				page, err := p.List(ctx, src, token, 200)
				if err != nil {
					return err
				}
				for _, child := range page.Entries {
					if child.Kind != "directory" && child.Kind != "file" {
						return errors.New("archive contains symlink or special file; blocked")
					}
					nextName := child.Name
					if archivePath != "." {
						nextName = path.Join(archivePath, child.Name)
					}
					if err := walk(child.Path, nextName, depth+1); err != nil {
						return err
					}
				}
				if page.Next == "" {
					break
				}
				token = page.Next
			}
			return nil
		}
		if info.Kind != "file" || info.Size < 0 || totalBytes > files.MaxManifestBytes-info.Size {
			return errors.New("unsupported file or archive byte limit exceeded")
		}
		totalBytes += info.Size
		if err := tw.WriteHeader(&tar.Header{
			Name:     archivePath,
			Mode:     0644,
			Size:     info.Size,
			Typeflag: tar.TypeReg,
			ModTime:  info.Modified,
		}); err != nil {
			return err
		}
		f, err := p.OpenRead(ctx, src)
		if err != nil {
			return err
		}
		defer f.Close()
		var copied int64
		for {
			if err := ctx.Err(); err != nil {
				return err
			}
			n, re := f.Read(buf)
			if n > 0 {
				copied += int64(n)
				if copied > info.Size {
					return errors.New("file grew while streaming archive")
				}
				if err := authorize(int64(n)); err != nil {
					return err
				}
				if _, we := tw.Write(buf[:n]); we != nil {
					return we
				}
			}
			if re == io.EOF {
				break
			}
			if re != nil {
				return re
			}
		}
		if copied != info.Size {
			return errors.New("file shrank while streaming archive")
		}
		return nil
	}
	if err := walk(rel, ".", 0); err != nil {
		return err
	}
	if err := tw.Close(); err != nil {
		return err
	}
	if gz != nil {
		return gz.Close()
	}
	return nil
}

func sanitizeArchiveName(name string) (string, error) {
	if name == "" || strings.ContainsRune(name, '\x00') || strings.ContainsRune(name, '\\') || strings.ContainsRune(name, ':') {
		return "", errors.New("unsafe archive entry path")
	}
	if strings.HasPrefix(name, "/") {
		return "", errors.New("absolute archive entry path rejected")
	}
	trimmed := strings.TrimSuffix(name, "/")
	if trimmed == "" || trimmed == "." || trimmed == "./" {
		return ".", nil
	}
	clean := path.Clean(trimmed)
	if clean == ".." || strings.HasPrefix(clean, "../") || strings.HasPrefix(clean, "/") {
		return "", errors.New("archive traversal rejected")
	}
	if filesproviders.ValidPath(clean) != nil {
		return "", errors.New("unsafe archive entry path")
	}
	return clean, nil
}

// PullTar safely extracts a streamed tar archive into private staging, verifies
// every file against the pre-fetched manifest, and atomically publishes without overwrite.
func PullTar(ctx context.Context, stream io.ReadCloser, codec, peer string, m protocol.Manifest, destination string, progress func(Progress)) (Receipt, error) {
	var receipt Receipt
	defer stream.Close()
	if codec != "" && codec != "none" && codec != "gzip" {
		return receipt, errors.New("unsupported archive codec")
	}
	st, err := openStaging(peer, m, destination)
	if err != nil {
		return receipt, err
	}
	defer st.close()

	expected := make(map[string]protocol.ManifestEntry, len(m.Entries))
	for _, e := range m.Entries {
		expected[e.Path] = e
	}
	seen := make(map[string]bool, len(m.Entries))

	maxStream := files.MaxManifestBytes + (64 << 20)
	var r io.Reader = io.LimitReader(stream, maxStream)
	if codec == "gzip" {
		gz, err := gzip.NewReader(r)
		if err != nil {
			return receipt, fmt.Errorf("invalid compressed archive: %w", err)
		}
		defer gz.Close()
		r = io.LimitReader(gz, maxStream)
	}
	tr := tar.NewReader(r)

	started := time.Now()
	var complete int64
	filesDone := 0
	buf := make([]byte, 256<<10)
	for {
		if err := ctx.Err(); err != nil {
			return receipt, err
		}
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return receipt, fmt.Errorf("archive stream error: %w", err)
		}
		if len(seen) >= files.MaxManifestEntries {
			return receipt, errors.New("archive entry limit exceeded")
		}
		if hdr.Typeflag != tar.TypeDir && hdr.Typeflag != tar.TypeReg {
			return receipt, fmt.Errorf("unsafe archive entry type %q rejected", hdr.Typeflag)
		}
		clean, err := sanitizeArchiveName(hdr.Name)
		if err != nil {
			return receipt, err
		}
		exp, ok := expected[clean]
		if !ok {
			return receipt, fmt.Errorf("unexpected archive entry %q", clean)
		}
		if seen[clean] {
			return receipt, fmt.Errorf("duplicate archive entry %q", clean)
		}
		seen[clean] = true
		target := path.Join("data", clean)
		if hdr.Typeflag == tar.TypeDir {
			if !exp.Directory {
				return receipt, fmt.Errorf("archive type mismatch for %q", clean)
			}
			if err := st.root.MkdirAll(target, 0700); err != nil {
				return receipt, err
			}
			continue
		}
		if exp.Directory || hdr.Size < 0 || hdr.Size != exp.Size {
			return receipt, fmt.Errorf("archive size or kind mismatch for %q", clean)
		}
		if parentDir := path.Dir(target); parentDir != "." {
			if err := st.root.MkdirAll(parentDir, 0700); err != nil {
				return receipt, err
			}
		}
		f, err := st.root.OpenFile(target, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0600)
		if err != nil {
			return receipt, err
		}
		var written int64
		limited := io.LimitReader(tr, exp.Size+1)
		for {
			if err := ctx.Err(); err != nil {
				f.Close()
				return receipt, err
			}
			n, re := limited.Read(buf)
			if n > 0 {
				written += int64(n)
				if written > exp.Size {
					f.Close()
					return receipt, fmt.Errorf("archive payload exceeds manifest size for %q", clean)
				}
				w, we := f.Write(buf[:n])
				if we != nil || w != n {
					f.Close()
					return receipt, errors.New("staging write failed (check free space)")
				}
			}
			if re == io.EOF {
				break
			}
			if re != nil {
				f.Close()
				return receipt, re
			}
		}
		if written != exp.Size {
			f.Close()
			return receipt, fmt.Errorf("truncated archive entry %q", clean)
		}
		if err := f.Sync(); err != nil {
			f.Close()
			return receipt, err
		}
		actual, err := digestFile(ctx, f)
		f.Close()
		if err != nil {
			return receipt, err
		}
		if actual != exp.XXH64 {
			return receipt, fmt.Errorf("%w: checksum mismatch for %q; staging preserved", ErrNonRetriable, clean)
		}
		complete += exp.Size
		filesDone++
		if progress != nil {
			mib, ms := rateMiB(complete, started)
			progress(Progress{File: clean, VerifiedBytes: complete, TotalBytes: m.Bytes, MiBPerSecond: mib, ElapsedMillis: ms, Method: "tar"})
		}
	}
	if len(seen) != len(expected) {
		return receipt, errors.New("archive stream incomplete; missing manifest entries")
	}
	if err := st.publish(); err != nil {
		return receipt, err
	}
	mib, ms := rateMiB(complete, started)
	return Receipt{
		Destination:   st.abs,
		Files:         filesDone,
		Bytes:         complete,
		XXH64:         st.manifestHash,
		Mode:          "tar",
		MiBPerSecond:  mib,
		ElapsedMillis: ms,
	}, nil
}
