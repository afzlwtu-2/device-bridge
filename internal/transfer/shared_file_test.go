package transfer

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/cespare/xxhash/v2"
)

func TestReceiveSharedFilePublishesVerifiedBytesOnly(t *testing.T) {
	t.Parallel()
	root, err := os.OpenRoot(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	const text = "received file"
	meta := SharedFile{Name: "sample.txt", Size: int64(len(text)), XXH64: fmt.Sprintf("%016x", xxhash.Sum64String(text))}
	for _, name := range []string{"", "../traverse", "/absolute", "a/b", "a\\b", sharedFileStagePrefix + "reserved"} {
		bad := meta
		bad.Name = name
		if err := ReceiveSharedFile(context.Background(), root, strings.NewReader(text), bad, nil); !errors.Is(err, ErrInvalidSharedFile) {
			t.Fatalf("accepted %q: %v", name, err)
		}
	}
	for _, payload := range []string{"", text + "extra", strings.Repeat("x", len(text))} {
		if err := ReceiveSharedFile(context.Background(), root, strings.NewReader(payload), meta, nil); !errors.Is(err, ErrSharedFileContent) {
			t.Fatalf("accepted invalid payload: %v", err)
		}
	}
	if _, err := root.Lstat(meta.Name); !os.IsNotExist(err) {
		t.Fatalf("invalid transfer published a file: %v", err)
	}
	if err := ReceiveSharedFile(context.Background(), root, strings.NewReader(text), meta, nil); err != nil {
		t.Fatal(err)
	}
	if err := ReceiveSharedFile(context.Background(), root, strings.NewReader(text), meta, nil); !errors.Is(err, ErrSharedFileExists) {
		t.Fatalf("expected no-overwrite failure, got %v", err)
	}
	payload, err := root.ReadFile(meta.Name)
	if err != nil || string(payload) != text {
		t.Fatalf("invalid published file: %q %v", payload, err)
	}
	dir, err := root.Open(".")
	if err != nil {
		t.Fatal(err)
	}
	defer dir.Close()
	items, err := dir.ReadDir(-1)
	if err != nil || len(items) != 1 {
		t.Fatalf("temporary files survived: %v %v", items, err)
	}
}
