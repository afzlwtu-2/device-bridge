package server

import (
	"bytes"
	"context"
	"crypto/rand"
	"devicebridge/internal/auth"
	"devicebridge/internal/client"
	"devicebridge/internal/files"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/storage"
	"devicebridge/internal/transfer"
	"devicebridge/internal/transport"
	"devicebridge/internal/transport/direct"
	"devicebridge/protocol"
	"fmt"
	"github.com/cespare/xxhash/v2"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPairedTextDeliveryPermissionAndIdempotency(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	makeDevice := func(name string) (*storage.Store, *auth.Identity) {
		t.Helper()
		store, err := storage.Open(filepath.Join(root, name))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = store.Close() })
		id, err := auth.Load(store, name)
		if err != nil {
			t.Fatal(err)
		}
		return store, id
	}
	receiver, receiverID := makeDevice("receiver")
	sender, senderID := makeDevice("sender")
	if err := sender.TrustOutbound(receiverID.ID, "receiver", "paired"); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	srv := New(receiver, receiverID, &filesproviders.Registry{})
	srv.SharedFiles, err = transfer.OpenSharedFileInbox(filepath.Join(root, "receiver"))
	if err != nil {
		t.Fatal(err)
	}
	defer srv.SharedFiles.Close()
	go func() { _ = srv.Serve(ctx, listener) }()
	provider, err := direct.NewCIDR("lo", "127.0.0.1/8")
	if err != nil {
		t.Fatal(err)
	}
	cl := client.New(senderID, sender, provider, transport.Candidate{
		DeviceID: receiverID.ID, Endpoint: listener.Addr().String(),
	})
	defer cl.Close()
	msg := protocol.TextShareRequest{ID: strings.Repeat("1", 32), Text: "Hello over mTLS"}
	var receipt map[string]string
	deliver := func(wantCode string) {
		t.Helper()
		err := cl.PostJSON(ctx, "/v1/share/text", msg, &receipt)
		if wantCode == "" {
			if err != nil || receipt["id"] != msg.ID {
				t.Fatalf("delivery failed: %+v, %v", receipt, err)
			}
		} else if err == nil || !strings.Contains(err.Error(), wantCode) {
			t.Fatalf("wanted %s, got %v", wantCode, err)
		}
	}
	deliver("text_sharing_not_allowed")
	if err = receiver.TrustOutbound(senderID.ID, "sender", "paired"); err != nil {
		t.Fatal(err)
	}
	deliver("text_sharing_not_allowed")
	allow := true
	if _, err = receiver.TextShareAccess(senderID.ID, &allow); err != nil {
		t.Fatal(err)
	}
	deliver("")
	deliver("")
	msg.Text = "Different text with the same ID"
	deliver("text_message_id_conflict")
	messages, err := receiver.TextInbox()
	if err != nil || len(messages) != 1 || messages[0].Text != "Hello over mTLS" {
		t.Fatalf("unexpected inbox: %+v, %v", messages, err)
	}
	const payload = "file contents"
	sum := fmt.Sprintf("%016x", xxhash.Sum64String(payload))
	var file transfer.SharedFile
	pushFile := func() error {
		return cl.SendSharedFile(ctx, "sample.txt", sum, int64(len(payload)), strings.NewReader(payload), &file)
	}
	if err := pushFile(); err == nil || !strings.Contains(err.Error(), "file_sharing_not_allowed") {
		t.Fatalf("text grant also permitted files: %v", err)
	}
	if _, err := receiver.FileShareAccess(senderID.ID, &allow); err != nil {
		t.Fatal(err)
	}
	if err := pushFile(); err != nil || file.XXH64 != sum {
		t.Fatalf("file receipt: %+v, %v", file, err)
	}
	if err := pushFile(); err == nil || !strings.Contains(err.Error(), "shared_file_already_exists") {
		t.Fatalf("duplicate name not rejected: %v", err)
	}
	source := t.TempDir()
	if err := os.Mkdir(filepath.Join(source, "empty"), 0700); err != nil {
		t.Fatal(err)
	}
	folderPayload := make([]byte, 8<<10)
	if _, err := rand.Read(folderPayload); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source, "entry.bin"), folderPayload, 0600); err != nil {
		t.Fatal(err)
	}
	native, err := filesproviders.NewNative("share", source)
	if err != nil {
		t.Fatal(err)
	}
	defer native.Close()
	unrestricted := func(int64) error { return nil }
	manifest, err := files.Manifest(ctx, native, ".", unrestricted)
	if err != nil {
		t.Fatal(err)
	}
	frame, expected, err := transfer.EncodeSharedFolder("sample-folder", manifest)
	if err != nil {
		t.Fatal(err)
	}
	payloadBuffer := bytes.NewBuffer(frame)
	if err := transfer.WriteTar(ctx, native, ".", "gzip", payloadBuffer, unrestricted); err != nil {
		t.Fatal(err)
	}
	var folder transfer.SharedFolder
	pushFolder := func(data []byte) error {
		return cl.SendSharedFolder(ctx, expected.Name, "gzip", bytes.NewReader(data), &folder)
	}
	if err := pushFolder(payloadBuffer.Bytes()[:len(frame)+8]); err == nil || !strings.Contains(err.Error(), "invalid_shared_file") {
		t.Fatalf("truncated tar was accepted: %v", err)
	}
	if _, err := srv.SharedFiles.Lstat(expected.Name); !os.IsNotExist(err) {
		t.Fatalf("truncated upload left an inbox entry: %v", err)
	}
	if err := pushFolder(payloadBuffer.Bytes()); err != nil || folder != expected {
		t.Fatalf("folder receipt: %+v, %v", folder, err)
	}
	data, err := srv.SharedFiles.ReadFile(expected.Name + "/entry.bin")
	if err != nil || !bytes.Equal(data, folderPayload) {
		t.Fatalf("folder entry: %d bytes, %v", len(data), err)
	}
	if err := pushFolder(payloadBuffer.Bytes()); err == nil || !strings.Contains(err.Error(), "shared_file_already_exists") {
		t.Fatalf("duplicate folder name not rejected: %v", err)
	}
	if err := receiver.Revoke(senderID.ID); err != nil {
		t.Fatal(err)
	}
	deliver("text_sharing_not_allowed")
	if err := receiver.RemovePeer(senderID.ID); err != nil {
		t.Fatal(err)
	}
	messages, err = receiver.TextInbox()
	if err != nil || len(messages) != 0 {
		t.Fatalf("peer removal left messages: %+v, %v", messages, err)
	}
}
