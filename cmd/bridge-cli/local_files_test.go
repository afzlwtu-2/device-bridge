package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"devicebridge/internal/filesproviders"
	"devicebridge/internal/tailnetipc"
)

func TestLocalFilesCopyPublishesVerifiedContentWithoutOverwrite(t *testing.T) {
	source := t.TempDir()
	target := t.TempDir()
	if err := os.MkdirAll(filepath.Join(source, "folder", "child"), 0700); err != nil {
		t.Fatal(err)
	}
	payload := []byte("DeviceBridge local Files fixture\n")
	if err := os.WriteFile(filepath.Join(source, "folder", "data.txt"), payload, 0600); err != nil {
		t.Fatal(err)
	}
	provider, err := filesproviders.NewNative("source", source)
	if err != nil {
		t.Fatal(err)
	}
	defer provider.Close()
	ctx := context.Background()
	if err := copyLocalFile(ctx, provider, "folder", target, ".", false, nil); err != nil {
		t.Fatal(err)
	}
	copied, err := os.ReadFile(filepath.Join(target, "folder", "data.txt"))
	if err != nil || string(copied) != string(payload) {
		t.Fatalf("published data = %q, %v", copied, err)
	}
	if _, err := os.Stat(filepath.Join(target, "folder.devicebridge-part")); !os.IsNotExist(err) {
		t.Fatalf("verified copy left a stage: %v", err)
	}
	if err := copyLocalFile(ctx, provider, "folder", target, ".", false, nil); err == nil {
		t.Fatal("copy accepted an existing destination")
	}
	if err := copyLocalFile(ctx, provider, "folder", source, "folder/child", false, nil); err == nil {
		t.Fatal("copy accepted a destination inside the source")
	}
}

func TestLocalFilesMoveTrashRestoreAndDelete(t *testing.T) {
	state := t.TempDir()
	home := t.TempDir()
	targetDir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, "sub"), 0700); err != nil {
		t.Fatal(err)
	}
	sample := filepath.Join(home, "note.txt")
	if err := os.WriteFile(sample, []byte("hello"), 0600); err != nil {
		t.Fatal(err)
	}
	provider, err := filesproviders.NewNative("home", home)
	if err != nil {
		t.Fatal(err)
	}
	defer provider.Close()
	ctx := context.Background()

	// Verified move removes source after copy
	if err := copyLocalFile(ctx, provider, "note.txt", targetDir, ".", true, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(sample); !os.IsNotExist(err) {
		t.Fatalf("expected source to be removed after move, got err=%v", err)
	}
	movedPath := filepath.Join(targetDir, "note.txt")
	if got, err := os.ReadFile(movedPath); err != nil || string(got) != "hello" {
		t.Fatalf("moved file = %q, %v", got, err)
	}

	// Trash -> Restore (including no-overwrite check) -> Delete
	roots := map[string]string{"home": targetDir}
	if err := trashLocalFile(state, targetDir, "home", "note.txt"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(movedPath); !os.IsNotExist(err) {
		t.Fatalf("expected trashed item removed from origin: %v", err)
	}
	entries, err := readLocalTrash(state)
	if err != nil || len(entries) != 1 || entries[0].Name != "note.txt" {
		t.Fatalf("unexpected trash entries: %+v, err=%v", entries, err)
	}
	// Collision prevents restore
	if err := os.WriteFile(movedPath, []byte("conflict"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := restoreLocalTrash(state, roots, entries[0].ID); err == nil {
		t.Fatal("restore overwrote an existing file")
	}
	if err := os.Remove(movedPath); err != nil {
		t.Fatal(err)
	}
	if err := restoreLocalTrash(state, roots, entries[0].ID); err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(movedPath); err != nil || string(got) != "hello" {
		t.Fatalf("restored file = %q, %v", got, err)
	}

	// Permanent delete and empty trash
	if err := trashLocalFile(state, targetDir, "home", "note.txt"); err != nil {
		t.Fatal(err)
	}
	if err := emptyLocalTrash(state); err != nil {
		t.Fatal(err)
	}
	if entries, err := readLocalTrash(state); err != nil || len(entries) != 0 {
		t.Fatalf("expected empty trash, got %+v, err=%v", entries, err)
	}
	victim := filepath.Join(home, "sub")
	if err := deleteLocalFile(home, "sub"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(victim); !os.IsNotExist(err) {
		t.Fatalf("expected deleted dir gone: %v", err)
	}
}

func TestTailnetHostMatchesShortAndDNSNames(t *testing.T) {
	st := tailnetipc.Response{
		IPs: []string{"100.127.71.119"},
		Peers: []tailnetipc.Peer{
			{
				Name:    "singapore",
				DNSName: "singapore.alpine-halfmoon.ts.net",
				IPs:     []string{"100.118.49.56"},
			},
			{
				Name:    "instance-20250328-1502",
				DNSName: "dubai.alpine-halfmoon.ts.net",
				IPs:     []string{"100.100.1.2"},
			},
		},
	}
	for _, want := range []string{"singapore", "SINGAPORE", "singapore.alpine-halfmoon.ts.net", "dubai", "100.118.49.56"} {
		if !tailnetHostMatches(st, want) {
			t.Fatalf("expected %q to match tailnet peers", want)
		}
	}
	for _, reject := range []string{"github.com", "router", "192.168.1.10", ""} {
		if tailnetHostMatches(st, reject) {
			t.Fatalf("expected %q NOT to match tailnet peers", reject)
		}
	}
}

func TestTailnetResolveIPMatchesShortHostnameAndIPv4(t *testing.T) {
	st := tailnetipc.Response{
		Hostname: "termux",
		IPs:      []string{"fd7a:115c:a1e0::1", "100.127.71.119"},
		Peers: []tailnetipc.Peer{
			{
				Name:    "probook",
				DNSName: "probook.alpine-halfmoon.ts.net.",
				IPs:     []string{"fd7a:115c:a1e0::2", "100.100.78.84"},
			},
			{
				Name:    "custom-label",
				DNSName: "laptop-box.alpine-halfmoon.ts.net",
				IPs:     []string{"100.100.9.10"},
			},
		},
	}
	cases := []struct {
		target string
		want   string
	}{
		{target: "probook", want: "100.100.78.84"},
		{target: "PROBOOK", want: "100.100.78.84"},
		{target: "probook.alpine-halfmoon.ts.net", want: "100.100.78.84"},
		{target: "laptop-box", want: "100.100.9.10"},
		{target: "termux", want: "100.127.71.119"},
		{target: "100.100.78.84", want: "100.100.78.84"},
		{target: "unknown-host", want: ""},
	}
	for _, tc := range cases {
		if got := tailnetResolveIP(st, tc.target); got != tc.want {
			t.Fatalf("tailnetResolveIP(%q) = %q, want %q", tc.target, got, tc.want)
		}
	}
}

func TestTrashKeepsSourceWhenIndexCannotBeRead(t *testing.T) {
	state, home := t.TempDir(), t.TempDir()
	source := filepath.Join(home, "note.txt")
	if err := os.WriteFile(source, []byte("keep this file"), 0600); err != nil {
		t.Fatal(err)
	}
	index := trashMetaPath(state)
	if err := os.MkdirAll(filepath.Dir(index), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(index, []byte("unfinished metadata"), 0600); err != nil {
		t.Fatal(err)
	}
	err := withRecycleLock(state, func() error {
		return trashLocalFile(state, home, "home", "note.txt")
	})
	if err == nil {
		t.Fatal("trashing continued with an unreadable index")
	}
	if got, err := os.ReadFile(source); err != nil || string(got) != "keep this file" {
		t.Fatalf("source after rejected trash operation: %q, %v", got, err)
	}
}
