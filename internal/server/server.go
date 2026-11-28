package server

import (
	"context"
	"crypto/tls"
	"devicebridge/internal/actions"
	"devicebridge/internal/auth"
	"devicebridge/internal/features"
	"devicebridge/internal/files"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/storage"
	"devicebridge/internal/synccontrol"
	"devicebridge/internal/transfer"
	"devicebridge/protocol"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/cespare/xxhash/v2"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

const ChunkSize = 4 << 20

// AgentStats tracks live connection and byte counters across listeners.
type AgentStats struct {
	ActiveConns    atomic.Int64
	ActiveRequests atomic.Int64
	ActiveSSH      atomic.Int64
	TotalRequests  atomic.Int64
	BytesSent      atomic.Int64
	BytesReceived  atomic.Int64
}

type AgentStatsSnapshot struct {
	ActiveConns    int64 `json:"active_conns"`
	ActiveRequests int64 `json:"active_requests"`
	ActiveSSH      int64 `json:"active_ssh"`
	TotalRequests  int64 `json:"total_requests"`
	BytesSent      int64 `json:"bytes_sent"`
	BytesReceived  int64 `json:"bytes_received"`
}

func (a *AgentStats) Snapshot() AgentStatsSnapshot {
	if a == nil {
		return AgentStatsSnapshot{}
	}
	return AgentStatsSnapshot{
		ActiveConns:    max(0, a.ActiveConns.Load()),
		ActiveRequests: max(0, a.ActiveRequests.Load()),
		ActiveSSH:      max(0, a.ActiveSSH.Load()),
		TotalRequests:  a.TotalRequests.Load(),
		BytesSent:      a.BytesSent.Load(),
		BytesReceived:  a.BytesReceived.Load(),
	}
}

type countingResponseWriter struct {
	http.ResponseWriter
	bytes *atomic.Int64
}

func (w *countingResponseWriter) Write(p []byte) (int, error) {
	n, err := w.ResponseWriter.Write(p)
	if n > 0 && w.bytes != nil {
		w.bytes.Add(int64(n))
	}
	return n, err
}

func (w *countingResponseWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (w *countingResponseWriter) Unwrap() http.ResponseWriter {
	return w.ResponseWriter
}

type countingReadCloser struct {
	io.ReadCloser
	bytes *atomic.Int64
}

func (r *countingReadCloser) Read(p []byte) (int, error) {
	n, err := r.ReadCloser.Read(p)
	if n > 0 && r.bytes != nil {
		r.bytes.Add(int64(n))
	}
	return n, err
}

type Server struct {
	Store           *storage.Store
	Identity        *auth.Identity
	Files           *filesproviders.Registry
	SharedFiles     *os.Root
	TermuxFiles     bool
	StateDir        string
	ActionState     string
	DisableAgentSSH bool
	Capabilities    func(context.Context) *protocol.DeviceCapabilities
	LinkActive      func(context.Context) bool
	PrepareLink     func(context.Context, protocol.ConnectionPrepareRequest) (protocol.ConnectionPrepareResult, error)
	RestoreLink     func(context.Context) (protocol.ConnectionPrepareResult, error)
	Sync            *synccontrol.Manager
	Stats           *AgentStats
	slots           chan struct{}
}

func New(s *storage.Store, id *auth.Identity, providers *filesproviders.Registry) *Server {
	return &Server{Store: s, Identity: id, Files: providers, Stats: &AgentStats{}, slots: make(chan struct{}, 8)}
}
func send(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-DeviceBridge-Version", "1")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func fail(w http.ResponseWriter, status int, code string) {
	send(w, status, protocol.Error{Code: code, Message: code})
}
func peerID(r *http.Request) string { return auth.Fingerprint(r.TLS.PeerCertificates[0]) }
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/pair", s.pair)
	mux.HandleFunc("POST /v1/pair/tailnet", s.tailnetPair)
	mux.HandleFunc("GET /v1/pair/tailnet", s.tailnetPair)
	mux.HandleFunc("GET /v1/pair", s.pairStatus)
	mux.HandleFunc("GET /v1/device", s.device)
	mux.HandleFunc("GET /v1/speedtest", s.speedtest)
	mux.HandleFunc("POST /v1/connections/prepare", s.prepareConnection)
	mux.HandleFunc("POST /v1/connections/restore", s.restoreConnection)
	mux.HandleFunc("POST /v1/connections/commit", s.commitConnection)
	mux.HandleFunc("POST /v1/ssh", s.agentSSH)
	registry := &features.Registry{}
	_ = registry.Register(&remoteFiles{s: s})
	_ = registry.Register(&shareText{s: s})
	if s.Sync != nil {
		_ = registry.Register(&folderSync{s: s})
	}
	if s.TermuxFiles {
		_ = registry.Register(&termuxFiles{s: s})
	}
	if s.ActionState != "" {
		_ = registry.Register(&agentActions{s: s})
	}
	if s.SharedFiles != nil {
		_ = registry.Register(&shareFile{s: s})
	}
	registry.RegisterBackend(mux)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.TLS == nil || len(r.TLS.PeerCertificates) != 1 {
			fail(w, 401, "client_certificate_required")
			return
		}
		if r.Header.Get("X-DeviceBridge-Version") != "1" {
			fail(w, 426, "unsupported_protocol_version")
			return
		}
		if r.Method == http.MethodPost && r.URL.Path == "/v1/ssh" {
			w.Header().Set("Cache-Control", "no-store")
			mux.ServeHTTP(w, r)
			return
		}
		select {
		case s.slots <- struct{}{}:
			defer func() { <-s.slots }()
		default:
			fail(w, 429, "server_busy")
			return
		}
		limit := int64(4096)
		if r.Method == http.MethodPost && r.URL.Path == "/v1/share/text" {
			limit = 6*protocol.MaxSharedTextBytes + 256
		} else if r.Method == http.MethodPost && r.URL.Path == fileShareEndpoint && s.SharedFiles != nil {
			limit = transfer.MaxSharedFileBytes
		} else if r.Method == http.MethodPost && r.URL.Path == folderShareEndpoint && s.SharedFiles != nil {
			limit = transfer.MaxSharedFolderBytes + (32 << 20)
		} else if r.Method == http.MethodPost && s.TermuxFiles {
			switch r.URL.Path {
			case managedUploadEndpoint:
				limit = files.MaxManifestBytes + (64 << 20)
			case managedRemoveEndpoint:
				limit = 128 << 10
			}
		}
		r.Body = http.MaxBytesReader(w, r.Body, limit)
		if s.Stats != nil {
			s.Stats.ActiveRequests.Add(1)
			s.Stats.TotalRequests.Add(1)
			defer s.Stats.ActiveRequests.Add(-1)
			if r.Body != nil {
				r.Body = &countingReadCloser{ReadCloser: r.Body, bytes: &s.Stats.BytesReceived}
			}
			w = &countingResponseWriter{ResponseWriter: w, bytes: &s.Stats.BytesSent}
		}
		w.Header().Set("Cache-Control", "no-store")
		mux.ServeHTTP(w, r)
	})
}
func (s *Server) Serve(ctx context.Context, ln net.Listener) error {
	return s.ServeWithTailnetTags(ctx, ln, nil)
}

func (s *Server) ServeWithTailnetTags(ctx context.Context, ln net.Listener, source TailnetTagSource) error {
	serveCtx, stop := context.WithCancel(ctx)
	go s.watchLinkLease(serveCtx)
	h := &http.Server{
		Handler:     s.Handler(),
		BaseContext: func(net.Listener) context.Context { return serveCtx },
		TLSConfig:   s.Identity.ServerTLS(),
		ConnContext: func(ctx context.Context, conn net.Conn) context.Context {
			if source == nil {
				return ctx
			}
			if tlsConn, ok := conn.(*tls.Conn); ok {
				conn = tlsConn.NetConn()
			}
			return context.WithValue(ctx, tailnetTagsKey{}, func(ctx context.Context) []string {
				return source(ctx, conn)
			})
		},
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      3 * time.Minute,
		IdleTimeout:       30 * time.Second,
		MaxHeaderBytes:    16 << 10,
		ErrorLog:          log.New(io.Discard, "", 0),
		ConnState: func(c net.Conn, state http.ConnState) {
			if s.Stats == nil {
				return
			}
			switch state {
			case http.StateNew:
				s.Stats.ActiveConns.Add(1)
			case http.StateClosed, http.StateHijacked:
				s.Stats.ActiveConns.Add(-1)
			}
		},
	}
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		<-serveCtx.Done()
		c, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := h.Shutdown(c); err != nil {
			_ = h.Close()
		}
	}()
	err := h.ServeTLS(ln, "", "")
	// Replaced listeners exit before the agent shuts down. Cancel their
	// requests and retire any keep-alive sockets before returning.
	stop()
	<-stopped
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}
func (s *Server) pair(w http.ResponseWriter, r *http.Request) {
	var req protocol.PairRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if dec.Decode(&req) != nil || len(req.Token) != 43 {
		fail(w, 400, "invalid_invitation")
		return
	}
	id := peerID(r)
	if err := s.Store.RequestPair(req.Token, id, req.Name); err != nil {
		fail(w, 403, "pairing_denied")
		return
	}
	send(w, 202, protocol.PairStatus{ID: id, Status: "pending"})
}
func (s *Server) pairStatus(w http.ResponseWriter, r *http.Request) {
	id := peerID(r)
	p, err := s.Store.Peer(id)
	if err != nil || p.Status == "revoked" || (p.Status == "pending" && p.Expires <= time.Now().Unix()) {
		fail(w, 403, "pairing_denied")
		return
	}
	send(w, 200, protocol.PairStatus{ID: id, Status: p.Status})
}
func (s *Server) paired(r *http.Request) bool {
	p, err := s.Store.Peer(peerID(r))
	return err == nil && p.Status == "paired"
}
func (s *Server) device(w http.ResponseWriter, r *http.Request) {
	if !s.paired(r) {
		fail(w, 403, "unpaired_device")
		return
	}
	var caps *protocol.DeviceCapabilities
	if s.Capabilities != nil {
		caps = s.Capabilities(r.Context())
	}
	available := []string{"remote-files-v1", protocol.TextShareFeature}
	if s.PrepareLink != nil && s.RestoreLink != nil {
		available = append(available, "network-link-lease-v1")
	}
	if s.TermuxFiles {
		available = append(available, protocol.TermuxFilesFeature)
	}
	if s.Sync != nil {
		available = append(available, protocol.SyncControlFeature)
	}
	if s.ActionState != "" {
		available = append(available, actions.Feature)
	}
	if s.SharedFiles != nil {
		available = append(available, "quick-share-file-v1", transfer.SharedFolderFeature)
	}
	if s.agentSSHEnabled(r.Context()) {
		if s.agentSSHShellReady() {
			available = append(available, AgentSSHFeature)
		} else {
			available = append(available, agentSSHSetupFeature)
		}
	}
	send(w, 200, protocol.Device{Version: 1, ID: s.Identity.ID, Name: s.Identity.Name,
		Features: available, Capabilities: caps})
}

func (s *Server) speedtest(w http.ResponseWriter, r *http.Request) {
	if !s.paired(r) {
		fail(w, 403, "unpaired_device")
		return
	}
	seconds := 5
	if raw := r.URL.Query().Get("seconds"); raw != "" {
		if v, err := strconv.Atoi(raw); err == nil && v >= 1 && v <= 15 {
			seconds = v
		}
	}
	_ = http.NewResponseController(w).SetWriteDeadline(time.Time{})
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-DeviceBridge-Version", "1")
	w.Header().Set("X-Speedtest-Seconds", strconv.Itoa(seconds))
	w.WriteHeader(200)
	buf := make([]byte, 128<<10)
	for i := range buf {
		buf[i] = byte(i*31 + 7)
	}
	deadline := time.Now().Add(time.Duration(seconds) * time.Second)
	for time.Now().Before(deadline) {
		if r.Context().Err() != nil {
			return
		}
		if _, err := w.Write(buf); err != nil {
			return
		}
	}
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
}

func (s *Server) prepareConnection(w http.ResponseWriter, r *http.Request) {
	if !s.paired(r) {
		fail(w, 403, "unpaired_device")
		return
	}
	if aclEnabled, aclAllowed, err := s.Store.CheckPeerACL(r.Context(), peerID(r), "link"); err != nil || (aclEnabled && !aclAllowed) {
		fail(w, 403, "acl_denied")
		return
	}
	if s.PrepareLink == nil {
		send(w, 501, protocol.Error{Code: "prepare_unsupported", Message: "Connection preparation is unsupported on this host"})
		return
	}
	var req protocol.ConnectionPrepareRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		send(w, 400, protocol.Error{Code: "invalid_request", Message: err.Error()})
		return
	}
	if req.OperationID != "" {
		if s.LinkActive != nil && s.LinkActive(r.Context()) {
			fail(w, 409, "stop_existing_link_first")
			return
		}
		if req.Kind != "wifi_join" && req.Kind != "hotspot" && req.Kind != "wifi_direct" {
			fail(w, 400, "leased_link_kind_unsupported")
			return
		}
		if _, err := s.Store.ChangeLinkLease(r.Context(), peerID(r), req.OperationID, "begin", req.LeaseSeconds); err != nil {
			fail(w, 409, "link_operation_busy")
			return
		}
	}
	pctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	res, err := s.PrepareLink(pctx, req)
	if err != nil {
		if req.OperationID != "" {
			stage := "needs_recovery"
			if s.RestoreLink != nil {
				rctx, rcancel := context.WithTimeout(context.Background(), 15*time.Second)
				if rres, rerr := s.RestoreLink(rctx); rerr == nil && rres.OK {
					stage = "restored"
				}
				rcancel()
			}
			_, _ = s.Store.ChangeLinkLease(context.Background(), peerID(r), req.OperationID, stage, 0)
		}
		send(w, 400, protocol.Error{Code: "prepare_failed", Message: err.Error()})
		return
	}
	send(w, 200, res)
}

func (s *Server) restoreConnection(w http.ResponseWriter, r *http.Request) {
	if !s.paired(r) {
		fail(w, 403, "unpaired_device")
		return
	}
	if aclEnabled, aclAllowed, err := s.Store.CheckPeerACL(r.Context(), peerID(r), "link"); err != nil || (aclEnabled && !aclAllowed) {
		fail(w, 403, "acl_denied")
		return
	}
	if s.RestoreLink == nil {
		send(w, 200, protocol.ConnectionPrepareResult{OK: true, Kind: "restore", Status: "noop"})
		return
	}
	lease, leaseErr := s.Store.LinkLease(r.Context())
	if leaseErr != nil {
		fail(w, 500, "link_state_unavailable")
		return
	}
	if lease.ID != "" && lease.Peer != peerID(r) && (lease.Stage == "preparing" || lease.Stage == "restoring") {
		fail(w, 403, "link_owned_by_another_peer")
		return
	}
	pctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	res, err := s.RestoreLink(pctx)
	if err != nil {
		send(w, 400, protocol.Error{Code: "restore_failed", Message: err.Error()})
		return
	}
	if lease.ID != "" && lease.Peer == peerID(r) && res.OK {
		_, _ = s.Store.ChangeLinkLease(r.Context(), lease.Peer, lease.ID, "restored", 0)
	}
	send(w, 200, res)
}

type remoteFiles struct{ s *Server }

func (*remoteFiles) ID() string                     { return "remote-files-v1" }
func (*remoteFiles) ProtocolVersion() int           { return 1 }
func (*remoteFiles) RequiredGrants() []string       { return []string{"browse(root)", "read(root)"} }
func (*remoteFiles) RequiredCapabilities() []string { return []string{"filesystem.read"} }
func (*remoteFiles) FeatureFlags() []string {
	return []string{"roots", "list", "stat", "read-range", "manifest", "preview", "tar", "stream"}
}
func (*remoteFiles) RegisterUIActions() []features.Action {
	return []features.Action{{ID: "browse", Label: "Browse files", Icon: "folder", Location: "device-detail", RequiredGrants: []string{"browse(root)"}, RequiredCapabilities: []string{"filesystem.read"}}}
}
func (m *remoteFiles) RegisterBackend(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/files/roots", m.s.roots)
	mux.HandleFunc("GET /v1/files/list", m.s.list)
	mux.HandleFunc("GET /v1/files/stat", m.s.stat)
	mux.HandleFunc("GET /v1/files/range", m.s.read)
	mux.HandleFunc("GET /v1/files/preview", m.s.read)
	mux.HandleFunc("GET /v1/files/manifest", m.s.manifest)
	mux.HandleFunc("GET /v1/files/tar", m.s.tar)
	mux.HandleFunc("GET /v1/files/stream", m.s.stream)
}
func (s *Server) roots(w http.ResponseWriter, r *http.Request) {
	if !s.paired(r) {
		fail(w, 403, "unpaired_device")
		return
	}
	roots := []protocol.Root{}
	for _, p := range s.Files.All() {
		if s.Store.Authorized(peerID(r), p.ID(), "browse", 0) == nil {
			name := p.ID()
			switch name {
			case "phone_storage":
				name = "Internal storage"
			case "saf":
				name = "SAF"
			case "termux_home":
				name = "Termux Home"
			}
			_, native := p.(*filesproviders.Native)
			writable := native && s.termuxFilesAllowed(peerID(r), p.ID(), 0) == nil
			roots = append(roots, protocol.Root{ID: p.ID(), Name: name, Writable: writable})
		}
	}
	send(w, 200, roots)
}
func (s *Server) scoped(w http.ResponseWriter, r *http.Request, op string) (filesproviders.Provider, string, bool) {
	root := r.URL.Query().Get("root")
	p, ok := s.Files.Get(root)
	rel := r.URL.Query().Get("path")
	if !ok || s.Store.Authorized(peerID(r), root, op, 0) != nil {
		fail(w, 403, "root_not_authorized")
		return nil, "", false
	}
	if filesproviders.ValidPath(rel) != nil {
		fail(w, 400, "unsafe_path")
		return nil, "", false
	}
	return p, rel, true
}
func (s *Server) list(w http.ResponseWriter, r *http.Request) {
	p, rel, ok := s.scoped(w, r, "browse")
	if !ok {
		return
	}
	limit := 200
	if n := r.URL.Query().Get("limit"); n != "" {
		v, e := strconv.Atoi(n)
		if e != nil {
			fail(w, 400, "invalid_limit")
			return
		}
		limit = v
	}
	page, err := p.List(r.Context(), rel, r.URL.Query().Get("page"), limit)
	if err != nil {
		fail(w, 400, "listing_failed")
		return
	}
	if s.Store.Audit(peerID(r), "list", p.ID()+":"+rel) != nil {
		fail(w, 500, "audit_unavailable")
		return
	}
	send(w, 200, page)
}
func (s *Server) stat(w http.ResponseWriter, r *http.Request) {
	p, rel, ok := s.scoped(w, r, "browse")
	if !ok {
		return
	}
	e, err := p.Stat(r.Context(), rel)
	if err != nil {
		fail(w, 404, "stat_failed")
		return
	}
	send(w, 200, e)
}
func (s *Server) read(w http.ResponseWriter, r *http.Request) {
	p, rel, ok := s.scoped(w, r, "read")
	if !ok {
		return
	}
	offset, err := strconv.ParseInt(r.URL.Query().Get("offset"), 10, 64)
	if err != nil || offset < 0 {
		fail(w, 400, "invalid_offset")
		return
	}
	length, err := strconv.ParseInt(r.URL.Query().Get("length"), 10, 64)
	if err != nil || length < 0 || length > ChunkSize {
		fail(w, 400, "invalid_length")
		return
	}
	if strings.HasSuffix(r.URL.Path, "/preview") && length > 64<<10 {
		fail(w, 400, "preview_limit_exceeded")
		return
	}
	f, err := p.OpenRead(r.Context(), rel)
	if err != nil {
		fail(w, 404, "read_failed")
		return
	}
	defer f.Close()
	if _, err = f.Seek(offset, io.SeekStart); err != nil {
		fail(w, 400, "seek_failed")
		return
	}
	data, err := io.ReadAll(io.LimitReader(f, length))
	if err != nil {
		fail(w, 409, "file_changed")
		return
	}
	if s.Store.Authorized(peerID(r), p.ID(), "read", int64(len(data))) != nil {
		fail(w, 403, "read_quota_or_grant_denied")
		return
	}
	if s.Store.Audit(peerID(r), "read", p.ID()+":"+rel) != nil {
		fail(w, 500, "audit_unavailable")
		return
	}
	h := xxhash.New()
	h.Write(data)
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Chunk-XXH64", hex.EncodeToString(h.Sum(nil)))
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.Header().Set("X-DeviceBridge-Version", "1")
	_, _ = w.Write(data)
}
func (s *Server) manifest(w http.ResponseWriter, r *http.Request) {
	p, rel, ok := s.scoped(w, r, "read")
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Minute)
	defer cancel()
	m, err := files.Manifest(ctx, p, rel, func(n int64) error { return s.Store.Authorized(peerID(r), p.ID(), "read", n) }, r.URL.Query()["exclude"]...)
	if err != nil {
		fail(w, 409, "manifest_failed_or_changed")
		return
	}
	if s.Store.Audit(peerID(r), "manifest", p.ID()+":"+rel) != nil {
		fail(w, 500, "audit_unavailable")
		return
	}
	send(w, 200, m)
}
func (s *Server) tar(w http.ResponseWriter, r *http.Request) {
	p, rel, ok := s.scoped(w, r, "read")
	if !ok {
		return
	}
	excludes, err := files.ValidateExclusions(r.URL.Query()["exclude"])
	if err != nil {
		fail(w, 400, "invalid_exclusion")
		return
	}
	codec := r.URL.Query().Get("codec")
	if codec == "" || codec == "adaptive" {
		codec = "gzip"
	}
	if codec != "gzip" && codec != "none" {
		fail(w, 400, "unsupported_codec")
		return
	}
	if s.Store.Audit(peerID(r), "tar", p.ID()+":"+rel) != nil {
		fail(w, 500, "audit_unavailable")
		return
	}
	output := beginStreamDownload(w)
	w.Header().Set("Content-Type", "application/x-tar")
	w.Header().Set("X-Archive-Codec", codec)
	w.Header().Set("X-DeviceBridge-Version", "1")
	w.WriteHeader(200)
	_ = transfer.WriteTar(r.Context(), p, rel, codec, output, func(n int64) error {
		return s.Store.Authorized(peerID(r), p.ID(), "read", n)
	}, excludes...)
}
func (s *Server) stream(w http.ResponseWriter, r *http.Request) {
	p, rel, ok := s.scoped(w, r, "read")
	if !ok {
		return
	}
	offset := int64(0)
	if raw := r.URL.Query().Get("offset"); raw != "" {
		v, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || v < 0 {
			fail(w, 400, "invalid_offset")
			return
		}
		offset = v
	}
	meta, err := p.Stat(r.Context(), rel)
	if err != nil || meta.Kind != "file" {
		fail(w, 404, "read_failed")
		return
	}
	if offset > meta.Size {
		fail(w, 409, "offset_past_eof")
		return
	}
	remain := meta.Size - offset
	f, err := p.OpenRead(r.Context(), rel)
	if err != nil {
		fail(w, 404, "read_failed")
		return
	}
	defer f.Close()
	if _, err = f.Seek(offset, io.SeekStart); err != nil {
		fail(w, 400, "seek_failed")
		return
	}
	// Reserve the first window before sending headers so a denied request can
	// still return 403. Charge later windows as the stream advances.
	window := min(remain, int64(transfer.ChunkSize))
	if s.Store.Authorized(peerID(r), p.ID(), "read", window) != nil {
		fail(w, 403, "read_quota_or_grant_denied")
		return
	}
	if s.Store.Audit(peerID(r), "stream", p.ID()+":"+rel) != nil {
		fail(w, 500, "audit_unavailable")
		return
	}
	output := beginStreamDownload(w)
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(remain, 10))
	w.Header().Set("X-DeviceBridge-Version", "1")
	w.WriteHeader(200)
	buf := make([]byte, window)
	for remain > 0 {
		if r.Context().Err() != nil {
			return
		}
		n, readErr := io.ReadFull(f, buf[:window])
		if _, err := output.Write(buf[:n]); err != nil || readErr != nil {
			return
		}
		remain -= int64(n)
		window = min(remain, int64(len(buf)))
		if window > 0 && s.Store.Authorized(peerID(r), p.ID(), "read", window) != nil {
			return
		}
	}
}
