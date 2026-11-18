package filesproviders

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestScopedPathsPagingAndLinks(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "secret"), []byte("private"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(dir, "escape")); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"empty", "unicode 空格.txt", "third"} {
		if err := os.WriteFile(filepath.Join(dir, name), nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	p, err := NewNative("test", dir)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	for _, name := range []string{"../secret", "/etc/passwd", "escape/secret", "a/../escape", "..\\secret"} {
		if f, e := p.OpenRead(context.Background(), name); e == nil {
			f.Close()
			t.Fatalf("opened %q", name)
		}
	}
	page, err := p.List(context.Background(), ".", "", 2)
	if err != nil || len(page.Entries) != 2 || page.Next == "" {
		t.Fatal(page, err)
	}
	next, err := p.List(context.Background(), ".", page.Next, 2)
	if err != nil || len(next.Entries) != 2 || next.Next != "" {
		t.Fatal(next, err)
	}
	if _, err = p.OpenWriteStaged(context.Background(), "x"); err != ErrReadOnly {
		t.Fatal("write enabled")
	}
}
