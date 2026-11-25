package bootstrap

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"sync"
	"time"

	"devicebridge/internal/storage"
)

type TerminalRequest struct {
	GuestCredentials
	ID      string `json:"id"`
	Columns int    `json:"columns"`
	Rows    int    `json:"rows"`
}

type TerminalFrame struct {
	Data    []byte `json:"data,omitempty"`
	Columns int    `json:"columns,omitempty"`
	Rows    int    `json:"rows,omitempty"`
	State   string `json:"state,omitempty"`
}

type terminalOutput struct {
	mu      sync.Mutex
	encoder *json.Encoder
	bytes   int64
}

func (t *terminalOutput) emit(frame TerminalFrame) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.bytes += int64(len(frame.Data))
	if t.bytes > 16<<20 {
		return errors.New("guest terminal output budget reached")
	}
	return t.encoder.Encode(frame)
}

func (t *terminalOutput) Write(p []byte) (int, error) {
	if err := t.emit(TerminalFrame{Data: p}); err != nil {
		return 0, err
	}
	return len(p), nil
}

func terminalSize(columns, rows int) (int, int) {
	return min(max(1, columns), 512), min(max(1, rows), 256)
}

func RunGuestTerminal(ctx context.Context, opts TailnetOptions, store *storage.Store, request TerminalRequest, input *bufio.Scanner, output io.Writer) error {
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return err
	}
	lease := hex.EncodeToString(nonce[:])
	if err := store.SetGuestTerminal(ctx, request.ID, "start", lease); err != nil {
		return err
	}
	defer func() {
		stop, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = store.SetGuestTerminal(stop, request.ID, "finish", lease)
	}()
	grant, err := store.Guest(ctx, request.ID)
	if err != nil || grant.Terminal != "active" || grant.TerminalLease != lease {
		return storage.ErrDenied
	}
	ctx, cancel := context.WithDeadline(ctx, time.Unix(grant.Expires, 0))
	defer cancel()
	opts.SSHTransport = grant.Transport
	opts.RemoteApproved = grant.RemoteApproved
	client, _, _, _, err := dialSSHParams(ctx, opts, grant.Host, grant.Port, grant.User,
		request.Password, request.PrivateKeyPEM, request.KeyPassphrase, grant.Fingerprint)
	if err != nil {
		return err
	}
	defer client.Close()
	stop := context.AfterFunc(ctx, func() { _ = client.Close() })
	defer stop()
	return StreamSSHClientTerminal(ctx, client, request.Columns, request.Rows, input, output, func() error {
		active, err := store.Guest(ctx, request.ID)
		if err != nil || active.Terminal != "active" || active.TerminalLease != lease {
			return storage.ErrDenied
		}
		return nil
	})
}
