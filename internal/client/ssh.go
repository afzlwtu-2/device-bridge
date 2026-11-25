package client

import (
	"bufio"
	"context"
	"crypto/tls"
	"devicebridge/internal/auth"
	"devicebridge/internal/storage"
	"devicebridge/internal/transport"
	"devicebridge/protocol"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
)

// AgentSSHError is an authenticated service rejection, not a network failure.
type AgentSSHError struct {
	Status  int
	Code    string
	Message string
}

func (e *AgentSSHError) Error() string {
	if e.Message != "" && e.Message != e.Code {
		return fmt.Sprintf("remote %d: %s (%s)", e.Status, e.Message, e.Code)
	}
	return fmt.Sprintf("remote %d: %s", e.Status, e.Code)
}

type bufferedConn struct {
	net.Conn
	r *bufio.Reader
}

func (b *bufferedConn) Read(p []byte) (int, error) {
	return b.r.Read(p)
}

// DialAgentSSH opens an mTLS-authenticated bidirectional SSH stream to a paired peer's agent.
func DialAgentSSH(ctx context.Context, id *auth.Identity, s *storage.Store, p transport.Provider, c transport.Candidate) (net.Conn, error) {
	if s == nil || id == nil || p == nil {
		return nil, errors.New("agent ssh client requires identity, store, and transport")
	}
	peer, err := s.Peer(c.DeviceID)
	if err != nil || peer.Status != "paired" {
		return nil, storage.ErrDenied
	}
	raw, err := p.Dial(ctx, c)
	if err != nil {
		return nil, err
	}
	tlsConn := tls.Client(raw, id.ClientTLS(c.DeviceID))
	if err := tlsConn.HandshakeContext(ctx); err != nil {
		_ = tlsConn.Close()
		return nil, err
	}
	stop := context.AfterFunc(ctx, func() { _ = tlsConn.Close() })
	defer stop()

	target := url.URL{Scheme: "https", Host: c.Endpoint, Path: "/v1/ssh"}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target.String(), http.NoBody)
	if err != nil {
		_ = tlsConn.Close()
		return nil, err
	}
	req.Host = c.Endpoint
	req.Header.Set("X-DeviceBridge-Version", "1")
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Upgrade", "devicebridge-ssh")
	if err := req.Write(tlsConn); err != nil {
		_ = tlsConn.Close()
		return nil, err
	}
	br := bufio.NewReader(tlsConn)
	res, err := http.ReadResponse(br, req)
	if err != nil {
		_ = tlsConn.Close()
		return nil, err
	}
	if res.StatusCode != http.StatusSwitchingProtocols {
		defer res.Body.Close()
		var e protocol.Error
		_ = json.NewDecoder(io.LimitReader(res.Body, 4096)).Decode(&e)
		_ = tlsConn.Close()
		return nil, &AgentSSHError{Status: res.StatusCode, Code: e.Code, Message: e.Message}
	}
	if res.Header.Get("X-DeviceBridge-Version") != "1" ||
		!strings.EqualFold(strings.TrimSpace(res.Header.Get("Upgrade")), "devicebridge-ssh") {
		_ = res.Body.Close()
		_ = tlsConn.Close()
		return nil, errors.New("unsupported agent ssh upgrade response")
	}
	return &bufferedConn{Conn: tlsConn, r: br}, nil
}
