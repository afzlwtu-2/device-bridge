package bootstrap

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"devicebridge/internal/filesproviders"
	"devicebridge/internal/storage"
	"devicebridge/protocol"

	"github.com/cespare/xxhash/v2"
	"github.com/pkg/sftp"
	"golang.org/x/sys/unix"
)

const maxGuestBytes = int64(1 << 30)

type GuestCredentials struct {
	Password      string `json:"password,omitempty"`
	PrivateKeyPEM string `json:"private_key_pem,omitempty"`
	KeyPassphrase string `json:"key_passphrase,omitempty"`
}

type GuestOpenRequest struct {
	Transport      string `json:"transport,omitempty"`
	RemoteApproved bool   `json:"remote_approved,omitempty"`
	GuestCredentials
	Host        string `json:"host"`
	Port        int    `json:"port"`
	User        string `json:"user"`
	Fingerprint string `json:"expected_host_key"`
	Root        string `json:"root"`
}

type GuestRequest struct {
	GuestCredentials
	ID   string `json:"id"`
	Path string `json:"path"`
}

type GuestReceipt struct {
	Destination string `json:"destination"`
	Bytes       int64  `json:"bytes"`
	XXH64       string `json:"xxh64"`
}

func OpenGuest(ctx context.Context, opts TailnetOptions, store *storage.Store, request GuestOpenRequest) (storage.GuestGrant, error) {
	var empty storage.GuestGrant
	if request.Port == 0 {
		request.Port = 22
	}
	root := request.Root
	if root == "" {
		root = "."
	}
	if request.Host == "" || len(request.Host) > 253 || request.User == "" || len(request.User) > 128 ||
		request.Port < 1 || request.Port > 65535 || !strings.HasPrefix(request.Fingerprint, "SHA256:") ||
		len(root) > 4096 || strings.ContainsRune(root, 0) {
		return empty, errors.New("provide an SSH host, user, verified host fingerprint and optional starting folder")
	}
	grant := storage.GuestGrant{
		Host: request.Host, Port: request.Port, User: request.User, Fingerprint: request.Fingerprint, Transport: request.Transport, RemoteApproved: request.RemoteApproved,
	}
	session, closeSession, err := connectGuest(ctx, opts, grant, request.GuestCredentials)
	if err != nil {
		return empty, err
	}
	defer closeSession()
	canonical, err := session.RealPath(root)
	if err != nil {
		return empty, err
	}
	if !path.IsAbs(canonical) || len(canonical) > 4096 || path.Clean(canonical) != canonical || strings.ContainsRune(canonical, 0) {
		return empty, errors.New("the SFTP server returned an unsafe starting folder")
	}
	info, err := session.Lstat(canonical)
	if err != nil || !info.IsDir() {
		return empty, errors.New("choose a guest folder that the SSH account can read")
	}
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return empty, err
	}
	grant.ID, grant.Root, grant.Expires = hex.EncodeToString(nonce[:]), canonical, time.Now().Add(10*time.Minute).Unix()
	return grant, store.SaveGuest(ctx, grant)
}

func connectGuest(ctx context.Context, opts TailnetOptions, grant storage.GuestGrant, credentials GuestCredentials) (*sftp.Client, func(), error) {
	opts.SSHTransport = grant.Transport
	opts.RemoteApproved = grant.RemoteApproved
	ssh, _, _, _, err := dialSSHParams(ctx, opts, grant.Host, grant.Port, grant.User, credentials.Password,
		credentials.PrivateKeyPEM, credentials.KeyPassphrase, grant.Fingerprint)
	if err != nil {
		return nil, nil, err
	}
	stop := context.AfterFunc(ctx, func() { _ = ssh.Close() })
	client, err := sftp.NewClient(ssh)
	if err != nil {
		stop()
		ssh.Close()
		return nil, nil, fmt.Errorf("SFTP subsystem unavailable: %w", err)
	}
	return client, func() {
		stop()
		_ = ssh.Close()
		_ = client.Close()
	}, nil
}

func guestPath(client *sftp.Client, root, relative string) (string, os.FileInfo, error) {
	if relative == "" {
		relative = "."
	}
	if filesproviders.ValidPath(relative) != nil || len(relative) > 4096 {
		return "", nil, errors.New("select a path inside the approved guest folder")
	}
	cur := root
	info, err := client.Lstat(cur)
	if err != nil {
		return "", nil, err
	}
	if !info.IsDir() {
		return "", nil, errors.New("the guest root is unavailable")
	}
	canonical, err := client.RealPath(cur)
	if err != nil || canonical != root {
		return "", nil, errors.New("the approved guest root changed")
	}
	if relative == "." {
		return cur, info, nil
	}
	for _, component := range strings.Split(relative, "/") {
		cur = path.Join(cur, component)
		info, err = client.Lstat(cur)
		if err != nil {
			return "", nil, err
		}
		if !info.IsDir() && !info.Mode().IsRegular() {
			return "", nil, errors.New("guest browsing accepts regular files and real directories")
		}
	}
	canonical, err = client.RealPath(cur)
	if err != nil || canonical != cur {
		return "", nil, errors.New("the guest path changed or escapes its approved starting folder")
	}
	return cur, info, nil
}

func ListGuest(ctx context.Context, options TailnetOptions, store *storage.Store, request GuestRequest) ([]protocol.Entry, error) {
	grant, err := store.Guest(ctx, request.ID)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithDeadline(ctx, time.Unix(grant.Expires, 0))
	defer cancel()
	client, closeSession, err := connectGuest(ctx, options, grant, request.GuestCredentials)
	if err != nil {
		return nil, err
	}
	defer closeSession()
	name, info, err := guestPath(client, grant.Root, request.Path)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() {
		return nil, errors.New("choose a guest directory to browse")
	}
	files, err := client.ReadDirContext(ctx, name)
	if err != nil {
		return nil, err
	}
	if len(files) > 2000 {
		return nil, errors.New("this guest directory exceeds the 2,000-entry browsing limit")
	}
	entries := []protocol.Entry{}
	for _, info := range files {
		label := info.Name()
		if label == "." || label == "" || strings.Contains(label, "/") || filesproviders.ValidPath(label) != nil {
			continue
		}
		var kind string
		if info.IsDir() {
			kind = "directory"
		} else if info.Mode().IsRegular() {
			kind = "file"
		} else {
			continue
		}
		entries = append(entries, protocol.Entry{Name: label, Path: path.Join(request.Path, label), Kind: kind, Size: info.Size()})
	}
	if _, err := store.Guest(ctx, grant.ID); err != nil {
		return nil, err
	}
	slices.SortFunc(entries, func(a, b protocol.Entry) int {
		if a.Kind != b.Kind {
			return strings.Compare(a.Kind, b.Kind)
		}
		return strings.Compare(a.Name, b.Name)
	})
	return entries, nil
}

func PullGuest(ctx context.Context, options TailnetOptions, store *storage.Store, request GuestRequest) (GuestReceipt, error) {
	var receipt GuestReceipt
	grant, err := store.Guest(ctx, request.ID)
	if err != nil {
		return receipt, err
	}
	ctx, cancel := context.WithDeadline(ctx, time.Unix(grant.Expires, 0))
	defer cancel()
	client, closeSession, err := connectGuest(ctx, options, grant, request.GuestCredentials)
	if err != nil {
		return receipt, err
	}
	defer closeSession()
	name, before, err := guestPath(client, grant.Root, request.Path)
	if err != nil {
		return receipt, err
	}
	base := path.Base(name)
	if !before.Mode().IsRegular() || before.Size() < 0 || before.Size() > maxGuestBytes ||
		base == "." || strings.HasPrefix(base, ".devicebridge-guest-") {
		return receipt, errors.New("choose a regular guest file up to 1 GiB")
	}
	remote, err := client.Open(name)
	if err != nil {
		return receipt, err
	}
	defer remote.Close()
	parent, err := os.OpenRoot(options.StateDir)
	if err != nil {
		return receipt, err
	}
	defer parent.Close()
	if err := parent.Mkdir("downloads", 0700); err != nil && !os.IsExist(err) {
		return receipt, err
	}
	info, err := parent.Lstat("downloads")
	if err != nil || !info.IsDir() {
		return receipt, errors.New("a private download directory is required")
	}
	target, err := parent.OpenRoot("downloads")
	if err != nil {
		return receipt, err
	}
	defer target.Close()
	fd, err := target.Open(".")
	if err != nil {
		return receipt, err
	}
	defer fd.Close()
	actual, err := fd.Stat()
	if err != nil || !os.SameFile(actual, info) {
		return receipt, errors.New("the download directory changed")
	}
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return receipt, err
	}
	stage := ".devicebridge-guest-" + hex.EncodeToString(nonce[:])
	output, err := target.OpenFile(stage, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return receipt, err
	}
	defer target.Remove(stage)
	defer output.Close()
	sourceHash := xxhash.New()
	stream := io.LimitReader(remote, before.Size()+1)
	buf := make([]byte, 256<<10)
	writer := io.MultiWriter(output, sourceHash)
	var written int64
	nextCheck := time.Now()
	for {
		if err := ctx.Err(); err != nil {
			return receipt, err
		}
		if time.Now().After(nextCheck) {
			if _, err := store.Guest(ctx, grant.ID); err != nil {
				return receipt, err
			}
			nextCheck = time.Now().Add(time.Second)
		}
		n, readErr := stream.Read(buf)
		if n > 0 {
			written += int64(n)
			if written > before.Size() {
				return receipt, errors.New("the guest file changed while downloading")
			}
			if _, err := writer.Write(buf[:n]); err != nil {
				return receipt, err
			}
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return receipt, readErr
		}
	}
	after, err := remote.Stat()
	if err != nil || written != before.Size() || after.Size() != before.Size() || !after.ModTime().Equal(before.ModTime()) {
		return receipt, errors.New("the guest file changed while downloading")
	}
	if err := output.Sync(); err != nil {
		return receipt, err
	}
	if _, err := output.Seek(0, io.SeekStart); err != nil {
		return receipt, err
	}
	targetHash := xxhash.New()
	if _, err := io.CopyBuffer(targetHash, output, buf); err != nil {
		return receipt, err
	}
	if targetHash.Sum64() != sourceHash.Sum64() {
		return receipt, errors.New("download read-back XXH64 mismatch")
	}
	handle := int(fd.Fd())
	if err := store.PublishGuest(ctx, grant.ID, func() error {
		if err := unix.Renameat2(handle, stage, handle, base, unix.RENAME_NOREPLACE); err != nil {
			return fmt.Errorf("saving the guest file without overwriting: %w", err)
		}
		return fd.Sync()
	}); err != nil {
		return receipt, err
	}
	destination, err := filepath.Abs(filepath.Join(options.StateDir, "downloads", base))
	if err != nil {
		return receipt, err
	}
	return GuestReceipt{Destination: destination, Bytes: written, XXH64: hex.EncodeToString(targetHash.Sum(nil))}, nil
}
