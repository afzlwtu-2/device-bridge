package bootstrap

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"devicebridge/internal/storage"

	"github.com/cespare/xxhash/v2"
	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
)

func TestGuestSFTPPinScopeDownloadAndRevocation(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	home, state := filepath.Join(root, "remote"), filepath.Join(root, "state")
	if err := os.Mkdir(home, 0700); err != nil {
		t.Fatal(err)
	}
	body := []byte("staged guest fixture")
	if err := os.WriteFile(filepath.Join(home, "readme.txt"), body, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(root, filepath.Join(home, "outside")); err != nil {
		t.Fatal(err)
	}
	store, err := storage.Open(state)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(key)
	if err != nil {
		t.Fatal(err)
	}
	const password = "fixture-login"
	server := &ssh.ServerConfig{
		PasswordCallback: func(metadata ssh.ConnMetadata, pass []byte) (*ssh.Permissions, error) {
			if metadata.User() != "guest" || string(pass) != password {
				return nil, errors.New("denied")
			}
			return nil, nil
		},
	}
	server.AddHostKey(signer)
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go serveGuestFixture(conn, server, home)
		}
	}()
	options := TailnetOptions{StateDir: state}
	address := listener.Addr().(*net.TCPAddr)
	request := GuestOpenRequest{
		Host: address.IP.String(), Port: address.Port, User: "guest", Root: home,
		Fingerprint: "SHA256:wrong", GuestCredentials: GuestCredentials{Password: password},
	}
	if _, err := OpenGuest(ctx, options, store, request); err == nil || !strings.Contains(err.Error(), "host key mismatch") {
		t.Fatalf("unverified guest host was accepted: %v", err)
	}
	request.Fingerprint = hostKeyFingerprint(signer.PublicKey())
	grant, err := OpenGuest(ctx, options, store, request)
	if err != nil {
		t.Fatal(err)
	}
	get := GuestRequest{ID: grant.ID, Path: ".", GuestCredentials: request.GuestCredentials}
	entries, err := ListGuest(ctx, options, store, get)
	if err != nil || len(entries) != 1 || entries[0].Name != "readme.txt" {
		t.Fatalf("listing exposed unapproved entries: %v, %v", entries, err)
	}
	get.Path = "../remote/readme.txt"
	if _, err := PullGuest(ctx, options, store, get); err == nil {
		t.Fatal("guest download accepted a path outside the scope")
	}
	term := TerminalRequest{ID: grant.ID, Columns: 80, Rows: 24, GuestCredentials: request.GuestCredentials}
	if err := RunGuestTerminal(ctx, options, store, term, nil, io.Discard); !errors.Is(err, storage.ErrDenied) {
		t.Fatalf("terminal started before separate approval: %v", err)
	}
	if err := store.SetGuestTerminal(ctx, grant.ID, "approve", ""); err != nil {
		t.Fatal(err)
	}
	terminalInput, keyboard := io.Pipe()
	defer keyboard.Close()
	view, terminalOutput := io.Pipe()
	defer view.Close()
	stopped := make(chan error, 1)
	go func() {
		defer terminalOutput.Close()
		stopped <- RunGuestTerminal(ctx, options, store, term, bufio.NewScanner(terminalInput), terminalOutput)
	}()
	frames := json.NewDecoder(view)
	var frame TerminalFrame
	for frame.State != "ready" {
		if err := frames.Decode(&frame); err != nil {
			t.Fatal(err)
		}
	}
	if err := json.NewEncoder(keyboard).Encode(TerminalFrame{Data: []byte("fixture keystrokes\n"), Columns: 90, Rows: 28}); err != nil {
		t.Fatal(err)
	}
	for {
		frame = TerminalFrame{}
		if err := frames.Decode(&frame); err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(frame.Data), "fixture keystrokes") {
			break
		}
	}
	if err := store.SetGuestTerminal(ctx, grant.ID, "revoke", ""); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-stopped:
		if !errors.Is(err, storage.ErrDenied) {
			t.Fatalf("terminal did not stop on revocation: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("revoked terminal did not close")
	}
	get.Path = "readme.txt"
	receipt, err := PullGuest(ctx, options, store, get)
	digest := xxhash.New()
	_, _ = digest.Write(body)
	if err != nil || receipt.XXH64 != hex.EncodeToString(digest.Sum(nil)) || receipt.Bytes != int64(len(body)) {
		t.Fatalf("guest receipt: %+v, %v", receipt, err)
	}
	if data, err := os.ReadFile(receipt.Destination); err != nil || string(data) != string(body) {
		t.Fatalf("guest download contents: %q, %v", data, err)
	}
	if _, err := PullGuest(ctx, options, store, get); err == nil {
		t.Fatal("second guest download overwrote an existing destination")
	}
	if err := store.RevokeGuest(ctx, grant.ID); err != nil {
		t.Fatal(err)
	}
	get.Path = "."
	if _, err := ListGuest(ctx, options, store, get); !errors.Is(err, storage.ErrDenied) {
		t.Fatalf("revoked guest can browse: %v", err)
	}
}

func serveGuestFixture(raw net.Conn, server *ssh.ServerConfig, home string) {
	defer raw.Close()
	conn, channels, requests, err := ssh.NewServerConn(raw, server)
	if err != nil {
		return
	}
	defer conn.Close()
	go ssh.DiscardRequests(requests)
	for requested := range channels {
		if requested.ChannelType() != "session" {
			_ = requested.Reject(ssh.UnknownChannelType, "fixture allows SFTP")
			continue
		}
		channel, requests, err := requested.Accept()
		if err != nil {
			return
		}
		defer channel.Close()
		for request := range requests {
			if request.Type == "pty-req" {
				_ = request.Reply(true, nil)
				continue
			}
			if request.Type == "shell" {
				_ = request.Reply(true, nil)
				go ssh.DiscardRequests(requests)
				_, _ = io.Copy(channel, channel)
				return
			}
			var payload struct{ Subsystem string }
			allowed := request.Type == "subsystem" && ssh.Unmarshal(request.Payload, &payload) == nil && payload.Subsystem == "sftp"
			_ = request.Reply(allowed, nil)
			if allowed {
				instance, err := sftp.NewServer(channel, sftp.WithServerWorkingDirectory(home), sftp.ReadOnly())
				if err == nil {
					defer instance.Close()
					_ = instance.Serve()
				}
				return
			}
		}
	}
}
