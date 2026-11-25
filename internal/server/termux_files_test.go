package server

import (
	"bytes"
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"devicebridge/internal/auth"
	"devicebridge/internal/client"
	"devicebridge/internal/files"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/storage"
	"devicebridge/internal/transfer"
	"devicebridge/internal/transport"
	"devicebridge/internal/transport/direct"
	"devicebridge/protocol"
)

func TestTermuxVerifiedCopyAndRemoval(t *testing.T) {
	state := t.TempDir()
	newDevice := func(name string) (*storage.Store, *auth.Identity) {
		t.Helper()
		store, err := storage.Open(filepath.Join(state, name))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { store.Close() })
		id, err := auth.Load(store, name)
		if err != nil {
			t.Fatal(err)
		}
		return store, id
	}
	termux, termuxID := newDevice("termux")
	phone, phoneID := newDevice("phone")
	home := t.TempDir()
	if err := termux.Export("home", home); err != nil {
		t.Fatal(err)
	}
	if err := termux.NewInvite("move-copy-test", time.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if err := termux.RequestPair("move-copy-test", phoneID.ID, phoneID.Name); err != nil {
		t.Fatal(err)
	}
	if err := termux.Approve(phoneID.ID, []string{"home"}, time.Hour, 1<<30); err != nil {
		t.Fatal(err)
	}
	if err := phone.TrustOutbound(termuxID.ID, termuxID.Name, "paired"); err != nil {
		t.Fatal(err)
	}
	native, err := filesproviders.NewNative("home", home)
	if err != nil {
		t.Fatal(err)
	}
	defer native.Close()
	registry := &filesproviders.Registry{}
	if err := registry.Register(native); err != nil {
		t.Fatal(err)
	}
	srv := New(termux, termuxID, registry)
	srv.TermuxFiles = true
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	go func() { _ = srv.Serve(ctx, ln) }()
	lan, err := direct.NewCIDR("lo", "127.0.0.1/8")
	if err != nil {
		t.Fatal(err)
	}
	cl := client.New(phoneID, phone, lan, transport.Candidate{DeviceID: termuxID.ID, Endpoint: ln.Addr().String()})
	defer cl.Close()
	const name = ".payload.bin"
	data := []byte("verified Termux fixture")
	source := t.TempDir()
	if err := os.WriteFile(filepath.Join(source, name), data, 0600); err != nil {
		t.Fatal(err)
	}
	sender, err := filesproviders.NewNative("files", source)
	if err != nil {
		t.Fatal(err)
	}
	defer sender.Close()
	allow := func(int64) error { return nil }
	manifest, err := files.Manifest(ctx, sender, name, allow)
	if err != nil {
		t.Fatal(err)
	}
	manifest.Path = "."
	frame, expected, err := transfer.EncodeManagedTree(name, manifest)
	if err != nil {
		t.Fatal(err)
	}
	body := bytes.NewBuffer(append([]byte{}, frame...))
	if err := transfer.WriteTar(ctx, sender, name, "none", body, allow); err != nil {
		t.Fatal(err)
	}
	checkErr := func(err error, want string) {
		t.Helper()
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Fatalf("wanted %q, got %v", want, err)
		}
	}
	checkRoots := func(writable bool) {
		t.Helper()
		var roots []protocol.Root
		if err := cl.JSON(ctx, "/v1/files/roots", nil, &roots); err != nil || len(roots) != 1 || roots[0].Writable != writable {
			t.Fatalf("root listing = %+v, %v", roots, err)
		}
	}
	push := func(root, destination string, bytesBody []byte) (transfer.SharedFolder, error) {
		var receipt transfer.SharedFolder
		err := cl.SendManagedTree(ctx, root, destination, name, bytes.NewReader(bytesBody), &receipt)
		return receipt, err
	}
	checkRoots(false)
	_, err = push("home", ".", body.Bytes())
	checkErr(err, "termux_file_management_denied")
	yes := true
	if _, err := termux.TermuxFilesAccess(phoneID.ID, &yes); err != nil {
		t.Fatal(err)
	}
	checkRoots(true)
	_, err = push("filesystem", ".", body.Bytes())
	checkErr(err, "termux_file_management_denied")
	_, err = push("home", "../", body.Bytes())
	checkErr(err, "unsafe_path")
	_, err = push("home", ".", body.Bytes()[:len(frame)+8])
	checkErr(err, "termux_file_operation_failed")
	corrupt := append([]byte{}, body.Bytes()...)
	corrupt[len(frame)+512] ^= 1
	_, err = push("home", ".", corrupt)
	checkErr(err, "termux_file_operation_failed")
	if entries, err := os.ReadDir(home); err != nil || len(entries) != 0 {
		t.Fatalf("bad uploads left data: %v %v", entries, err)
	}
	receipt, err := push("home", ".", body.Bytes())
	if err != nil || receipt != expected {
		t.Fatalf("receipt = %+v, %v", receipt, err)
	}
	_, err = push("home", ".", body.Bytes())
	checkErr(err, "destination_exists")
	readback, err := os.ReadFile(filepath.Join(home, name))
	if err != nil || !bytes.Equal(data, readback) {
		t.Fatalf("copy data = %q, %v", readback, err)
	}
	req := protocol.VerifiedRemoval{Root: "home", Path: name, XXH64: "0000000000000000"}
	_, err = cl.RemoveVerifiedTermuxFiles(ctx, req)
	checkErr(err, "source changed")
	if _, err := os.Stat(filepath.Join(home, name)); err != nil {
		t.Fatal(err)
	}
	req.XXH64 = files.ContentXXH64(manifest)
	removed, err := cl.RemoveVerifiedTermuxFiles(ctx, req)
	if err != nil || removed["source_remaining"] {
		t.Fatalf("move = %+v %v", removed, err)
	}
	if _, err := os.Stat(filepath.Join(home, name)); !os.IsNotExist(err) {
		t.Fatalf("verified source not retired: %v", err)
	}
	if err := termux.Revoke(phoneID.ID); err != nil {
		t.Fatal(err)
	}
	_, err = push("home", ".", body.Bytes())
	checkErr(err, "termux_file_management_denied")
}
