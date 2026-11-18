package filesproviders

import (
	"context"
	"devicebridge/protocol"
	"errors"
	"fmt"
	"golang.org/x/sys/unix"
	"io"
	"io/fs"
	"os"
	"path"
	"strconv"
	"strings"
)

type Native struct {
	id   string
	root *os.Root
}

func NewNative(id, dir string) (*Native, error) {
	r, err := os.OpenRoot(dir)
	if err != nil {
		return nil, err
	}
	return &Native{id: id, root: r}, nil
}
func (n *Native) ID() string { return n.id }
func (n *Native) Scope() Scope {
	return Scope{Version: ContractVersion, RootID: n.id, Kind: "native-scoped", Read: true}
}
func (n *Native) Close() error { return n.root.Close() }
func ValidPath(p string) error {
	if p == "" || p == "." {
		return nil
	}
	if !fs.ValidPath(p) || strings.ContainsAny(p, "\\\x00") || strings.Contains(p, ":") {
		return errors.New("unsafe relative path")
	}
	return nil
}
func normalize(p string) string {
	if p == "" {
		return "."
	}
	return p
}
func (n *Native) check(p string) error {
	if err := ValidPath(p); err != nil {
		return err
	}
	p = normalize(p)
	// Reject symbolic links for portable, unambiguous folder manifests. os.Root
	// supplies the actual race-resistant confinement even if a component changes.
	parts := strings.Split(p, "/")
	cur := "."
	for _, part := range parts {
		cur = path.Join(cur, part)
		info, err := n.root.Lstat(cur)
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return errors.New("symbolic link access disabled")
		}
	}
	return nil
}
func entry(p string, info os.FileInfo) protocol.Entry {
	kind := "file"
	if info.IsDir() {
		kind = "directory"
	} else if info.Mode()&os.ModeSymlink != 0 {
		kind = "symlink"
	} else if !info.Mode().IsRegular() {
		kind = "special"
	}
	return protocol.Entry{Name: info.Name(), Path: p, Kind: kind, Size: info.Size(), Modified: info.ModTime().UTC()}
}
func (n *Native) Stat(ctx context.Context, p string) (protocol.Entry, error) {
	if err := ctx.Err(); err != nil {
		return protocol.Entry{}, err
	}
	if err := n.check(p); err != nil {
		return protocol.Entry{}, err
	}
	info, err := n.root.Stat(normalize(p))
	if err != nil {
		return protocol.Entry{}, err
	}
	return entry(normalize(p), info), nil
}
func (n *Native) List(ctx context.Context, p, token string, limit int) (protocol.Listing, error) {
	out := protocol.Listing{Entries: []protocol.Entry{}}
	if err := n.check(p); err != nil {
		return out, err
	}
	if limit < 1 || limit > 500 {
		return out, errors.New("page limit must be 1..500")
	}
	offset := 0
	var err error
	if token != "" {
		offset, err = strconv.Atoi(token)
		if err != nil || offset < 0 || offset > 1000000 {
			return out, errors.New("invalid page token")
		}
	}
	f, err := n.root.OpenFile(normalize(p), os.O_RDONLY|unix.O_NONBLOCK|unix.O_NOFOLLOW|unix.O_DIRECTORY, 0)
	if err != nil {
		return out, err
	}
	defer f.Close()
	for skipped := 0; skipped < offset; {
		if err = ctx.Err(); err != nil {
			return out, err
		}
		batch, e := f.ReadDir(min(500, offset-skipped))
		skipped += len(batch)
		if e == io.EOF {
			return out, nil
		}
		if e != nil {
			return out, e
		}
	}
	items, err := f.ReadDir(limit + 1)
	if err != nil && err != io.EOF {
		return out, err
	}
	if len(items) > limit {
		out.Next = strconv.Itoa(offset + limit)
		items = items[:limit]
	}
	for _, item := range items {
		if err = ctx.Err(); err != nil {
			return out, err
		}
		info, e := n.root.Lstat(path.Join(p, item.Name()))
		if e != nil {
			if errors.Is(e, os.ErrPermission) || errors.Is(e, os.ErrNotExist) {
				continue
			}
			return out, fmt.Errorf("entry changed: %w", e)
		}
		out.Entries = append(out.Entries, entry(path.Join(p, item.Name()), info))
	}
	return out, nil
}
func (n *Native) OpenRead(ctx context.Context, p string) (io.ReadSeekCloser, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := n.check(p); err != nil {
		return nil, err
	}
	f, err := n.root.OpenFile(normalize(p), os.O_RDONLY|unix.O_NONBLOCK|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() {
		f.Close()
		return nil, errors.New("only regular files can be read")
	}
	return f, nil
}
func (n *Native) OpenWriteStaged(context.Context, string) (StagedWrite, error) {
	return nil, ErrReadOnly
}
