package server

import (
	"bufio"
	"context"
	"devicebridge/internal/sshserver"
	"io"
	"net"
	"net/http"
	"os"
	"runtime"
	"strings"
	"sync/atomic"
	"time"
)

const AgentSSHFeature = "agent-ssh-v1"
const agentSSHSetupFeature = "agent-ssh-terminal-setup-v1"

type hijackedSSHConn struct {
	net.Conn
	r  *bufio.Reader
	rx *atomic.Int64
	tx *atomic.Int64
}

func (c *hijackedSSHConn) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	if n > 0 && c.rx != nil {
		c.rx.Add(int64(n))
	}
	return n, err
}

func (c *hijackedSSHConn) Write(p []byte) (int, error) {
	n, err := c.Conn.Write(p)
	if n > 0 && c.tx != nil {
		c.tx.Add(int64(n))
	}
	return n, err
}

func (s *Server) agentSSHEnabled(ctx context.Context) bool {
	if s.DisableAgentSSH || (runtime.GOOS == "linux" && os.Geteuid() == 0) {
		return false
	}
	policy, err := s.Store.NetworkPolicy(ctx, nil)
	return err == nil && policy["network_agent_ssh"]
}

func (s *Server) agentSSHShellReady() bool {
	if runtime.GOOS != "android" {
		return true
	}
	shell, _ := sshserver.ResolveShell(s.StateDir)
	return shell != ""
}

func (s *Server) agentSSH(w http.ResponseWriter, r *http.Request) {
	if !s.agentSSHEnabled(r.Context()) {
		fail(w, http.StatusNotFound, "agent_ssh_disabled")
		return
	}
	if !s.paired(r) {
		fail(w, http.StatusForbidden, "unpaired_device")
		return
	}
	if !s.agentSSHShellReady() {
		fail(w, http.StatusServiceUnavailable, "terminal_setup_required")
		return
	}
	if !strings.EqualFold(strings.TrimSpace(r.Header.Get("Upgrade")), "devicebridge-ssh") {
		fail(w, http.StatusUpgradeRequired, "upgrade_required")
		return
	}
	access, err := s.Store.AgentSSHAccess(r.Context(), peerID(r), "request")
	if err != nil || !access.Allowed {
		fail(w, http.StatusForbidden, "ssh_approval_required")
		return
	}
	rc := http.NewResponseController(w)
	conn, rw, err := rc.Hijack()
	if err != nil {
		fail(w, http.StatusInternalServerError, "hijack_failed")
		return
	}
	defer conn.Close()
	// Hijacked sessions are outside http.Server shutdown. Recheck both policy and
	// pairing so disabling SSH or revoking a peer terminates existing sessions.
	sessionCtx, cancel := context.WithCancel(r.Context())
	defer cancel()
	go func() {
		ticker := time.NewTicker(500 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-sessionCtx.Done():
				_ = conn.Close()
				return
			case <-ticker.C:
				access, err := s.Store.AgentSSHAccess(sessionCtx, peerID(r), "")
				if !s.agentSSHEnabled(sessionCtx) || err != nil || !access.Allowed {
					_ = conn.Close()
					return
				}
			}
		}
	}()
	_ = conn.SetDeadline(time.Time{})

	if _, err := io.WriteString(rw, "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: devicebridge-ssh\r\nX-DeviceBridge-Version: 1\r\n\r\n"); err != nil {
		return
	}
	if err := rw.Flush(); err != nil {
		return
	}

	var rx, tx *atomic.Int64
	if s.Stats != nil {
		s.Stats.ActiveSSH.Add(1)
		defer s.Stats.ActiveSSH.Add(-1)
		rx = &s.Stats.BytesReceived
		tx = &s.Stats.BytesSent
	}
	wrapped := &hijackedSSHConn{Conn: conn, r: rw.Reader, rx: rx, tx: tx}
	_ = sshserver.HandleMTLSConn(sessionCtx, wrapped, s.StateDir, peerID(r))
}
