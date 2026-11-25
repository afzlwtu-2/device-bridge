package bootstrap

import (
	"context"
	"crypto/rand"
	"devicebridge/internal/storage"
	"encoding/hex"
	"time"
)

// OpenSSHSession authenticates SSH independently of the optional SFTP subsystem.
func OpenSSHSession(ctx context.Context, opts TailnetOptions, s *storage.Store, host string, port int, user, pin string, creds GuestCredentials) (storage.GuestGrant, error) {
	var grant storage.GuestGrant
	client, _, _, _, err := dialSSHParams(ctx, opts, host, port, user, creds.Password, creds.PrivateKeyPEM, creds.KeyPassphrase, pin)
	if err != nil {
		return grant, err
	}
	defer client.Close()
	var b [16]byte
	if _, err = rand.Read(b[:]); err != nil {
		return grant, err
	}
	grant = storage.GuestGrant{ID: hex.EncodeToString(b[:]), Host: host, Port: port, User: user, Fingerprint: pin, Root: ".", Transport: opts.SSHTransport, RemoteApproved: opts.RemoteApproved, Expires: time.Now().Add(10 * time.Minute).Unix()}
	return grant, s.SaveGuest(ctx, grant)
}
