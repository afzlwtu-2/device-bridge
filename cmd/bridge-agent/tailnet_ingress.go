package main

import (
	"bufio"
	"context"
	"devicebridge/internal/server"
	"devicebridge/internal/transport/tailscaled"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

func systemTailnetListener(ctx context.Context, address string) (net.Listener, server.TailnetTagSource, error) {
	// Binding the destination address alone allows traffic from another interface.
	// Attach WhoIs authorization only when the kernel confines ingress to the TUN.
	config := net.ListenConfig{Control: func(_, _ string, c syscall.RawConn) error {
		var optErr error
		if err := c.Control(func(fd uintptr) { optErr = unix.BindToDevice(int(fd), "tailscale0") }); err != nil {
			return err
		}
		return optErr
	}}
	listener, err := config.Listen(ctx, "tcp", address)
	if err != nil {
		listener, err = net.Listen("tcp", address)
		return listener, nil, err
	}
	return listener, func(ctx context.Context, conn net.Conn) []string {
		query, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		return (&tailscaled.Provider{}).PeerTags(query, conn.RemoteAddr().String())
	}, nil
}

type sidecarListener struct{ net.Listener }
type sidecarConn struct {
	net.Conn
	reader *bufio.Reader
	tags   []string
	loaded bool
}

func (l sidecarListener) Accept() (net.Conn, error) {
	conn, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	return &sidecarConn{Conn: conn, reader: bufio.NewReaderSize(conn, 4096)}, nil
}

func (c *sidecarConn) Read(p []byte) (int, error) {
	if !c.loaded {
		line, err := c.reader.ReadSlice('\n')
		if err != nil {
			return 0, err
		}
		if json.Unmarshal(line, &c.tags) != nil {
			return 0, io.ErrUnexpectedEOF
		}
		c.loaded = true
	}
	return c.reader.Read(p)
}

func listenSidecarIngress(ctx context.Context, state string, srv *server.Server) {
	// The enclosing directory and filesystem socket are private to the app UID.
	info, err := os.Lstat(state)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return
	}
	lock, err := os.OpenFile(filepath.Join(state, "tailnet-agent.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return
	}
	defer lock.Close()
	if unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB) != nil {
		return
	}
	path := filepath.Join(state, "tailnet-agent.sock")
	if info, err := os.Lstat(path); err == nil && info.Mode()&os.ModeSocket != 0 {
		_ = os.Remove(path)
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		return
	}
	defer listener.Close()
	if err := os.Chmod(path, 0600); err != nil {
		return
	}
	_ = srv.ServeWithTailnetTags(ctx, sidecarListener{listener}, func(_ context.Context, conn net.Conn) []string {
		// TLS has already consumed the private sidecar preface before a handler runs.
		return conn.(*sidecarConn).tags
	})
}
