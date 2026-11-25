package bootstrap

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"devicebridge/internal/storage"
	"golang.org/x/crypto/ssh"
	"net"
	"path/filepath"
	"testing"
	"time"
)

func TestSSHOnlySessionDoesNotRequireSFTP(t *testing.T) {
	_, key, _ := ed25519.GenerateKey(rand.Reader)
	signer, _ := ssh.NewSignerFromKey(key)
	config := &ssh.ServerConfig{NoClientAuth: true}
	config.AddHostKey(signer)
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				conn, chans, reqs, err := ssh.NewServerConn(c, config)
				if err != nil {
					c.Close()
					return
				}
				defer conn.Close()
				go ssh.DiscardRequests(reqs)
				for ch := range chans {
					_ = ch.Reject(ssh.UnknownChannelType, "SFTP and all channels disabled for this authentication fixture")
				}
			}()
		}
	}()
	s, err := storage.Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	addr := ln.Addr().(*net.TCPAddr)
	// Empty credentials are valid for a server accepting tailnet/no-client-auth; host identity is still pinned.
	grant, err := OpenSSHSession(ctx, TailnetOptions{SSHTransport: "direct"}, s, "127.0.0.1", addr.Port, "test", hostKeyFingerprint(signer.PublicKey()), GuestCredentials{Password: "fixture"})
	if err != nil {
		t.Fatal(err)
	}
	if grant.Root != "." || grant.ID == "" {
		t.Fatalf("invalid SSH lease: %+v", grant)
	}
	if _, err = OpenGuest(ctx, TailnetOptions{}, s, GuestOpenRequest{Host: "127.0.0.1", Port: addr.Port, User: "test", Fingerprint: hostKeyFingerprint(signer.PublicKey()), GuestCredentials: GuestCredentials{Password: "fixture"}}); err == nil {
		t.Fatal("fixture unexpectedly offered SFTP")
	}
	if _, err = OpenSSHSession(ctx, TailnetOptions{}, s, "127.0.0.1", addr.Port, "test", "SHA256:wrong", GuestCredentials{Password: "fixture"}); err == nil {
		t.Fatal("host key mismatch accepted")
	}
}
