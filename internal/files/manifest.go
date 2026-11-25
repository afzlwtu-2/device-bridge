package files

import (
	"context"
	"devicebridge/internal/filesproviders"
	"devicebridge/protocol"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/cespare/xxhash/v2"
	"io"
	"path"
	"slices"
	"strings"
)

const MaxManifestEntries = 20000
const MaxManifestBytes = int64(100 << 30)

// ContentXXH64 identifies the ordered, verified entries independently of
// the selected provider and path on either device.
func ContentXXH64(m protocol.Manifest) string {
	entries := slices.Clone(m.Entries)
	slices.SortFunc(entries, func(a, b protocol.ManifestEntry) int { return strings.Compare(a.Path, b.Path) })
	raw, _ := json.Marshal(entries)
	return fmt.Sprintf("%016x", xxhash.Sum64(raw))
}

func Manifest(ctx context.Context, p filesproviders.Provider, rel string, authorize func(int64) error, excludes ...string) (protocol.Manifest, error) {
	return ManifestWithin(ctx, p, rel, MaxManifestEntries, MaxManifestBytes, authorize, excludes...)
}

func ManifestWithin(ctx context.Context, p filesproviders.Provider, rel string, maxEntries int, maxBytes int64, authorize func(int64) error, excludes ...string) (protocol.Manifest, error) {
	normalized, err := ValidateExclusions(excludes)
	if err != nil {
		return protocol.Manifest{}, err
	}
	m := protocol.Manifest{Excludes: normalized, Version: protocol.ManifestVersion, Root: p.ID(), Path: rel, Entries: []protocol.ManifestEntry{}}
	var walk func(string, string, int) error
	walk = func(src, dst string, depth int) error {
		if Excluded(dst, normalized) {
			return nil
		}
		if depth > 128 || len(m.Entries) >= maxEntries {
			return errors.New("folder manifest limit exceeded")
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
		e := protocol.ManifestEntry{Path: dst, Size: info.Size, Directory: info.Kind == "directory"}
		if e.Directory {
			e.Size = 0
			m.Entries = append(m.Entries, e)
			token := ""
			for {
				page, err := p.List(ctx, src, token, 200)
				if err != nil {
					return err
				}
				for _, child := range page.Entries {
					if child.Kind != "directory" && child.Kind != "file" {
						return fmt.Errorf("folder contains symlink or special file %q (%s); transfer blocked", child.Path, child.Kind)
					}
					if err = walk(child.Path, path.Join(dst, child.Name), depth+1); err != nil {
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
		if info.Kind != "file" || e.Size < 0 || m.Bytes > maxBytes-e.Size {
			return errors.New("unsupported file or manifest byte limit exceeded")
		}
		f, err := p.OpenRead(ctx, src)
		if err != nil {
			return err
		}
		h := xxhash.New()
		buf := make([]byte, 256<<10)
		var read int64
		for {
			if err = ctx.Err(); err != nil {
				f.Close()
				return err
			}
			if err = authorize(0); err != nil {
				f.Close()
				return err
			}
			n, re := f.Read(buf)
			if n > 0 {
				read += int64(n)
				if read > e.Size {
					f.Close()
					return errors.New("file changed while scanning")
				}
				h.Write(buf[:n])
			}
			if re == io.EOF {
				break
			}
			if re != nil {
				f.Close()
				return re
			}
		}
		f.Close()
		if read != e.Size {
			return errors.New("file changed while scanning")
		}
		e.XXH64 = hex.EncodeToString(h.Sum(nil))
		m.Bytes += read
		m.Entries = append(m.Entries, e)
		return nil
	}
	err = walk(rel, ".", 0)
	return m, err
}
