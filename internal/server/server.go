package server

import (
	"context"
	"crypto/sha256"
	"devicebridge/internal/auth"
	"devicebridge/internal/features"
	"devicebridge/internal/files"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/storage"
	"devicebridge/internal/transfer"
	"devicebridge/protocol"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const ChunkSize = 1 << 20

type Server struct {
	Store    *storage.Store
	Identity *auth.Identity
	Files    *filesproviders.Registry
	slots    chan struct{}
}

func New(s *storage.Store, id *auth.Identity, providers *filesproviders.Registry) *Server {
	return &Server{Store: s, Identity: id, Files: providers, slots: make(chan struct{}, 8)}
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
	mux.HandleFunc("GET /v1/pair", s.pairStatus)
	mux.HandleFunc("GET /v1/device", s.device)
	registry := &features.Registry{}
	_ = registry.Register(&remoteFiles{s: s})
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
		select {
		case s.slots <- struct{}{}:
			defer func() { <-s.slots }()
		default:
			fail(w, 429, "server_busy")
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 4096)
		w.Header().Set("Cache-Control", "no-store")
		mux.ServeHTTP(w, r)
	})
}
func (s *Server) Serve(ctx context.Context, ln net.Listener) error {
	h := &http.Server{Handler: s.Handler(), TLSConfig: s.Identity.ServerTLS(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 3 * time.Minute, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 << 10, ErrorLog: log.New(io.Discard, "", 0)}
	go func() {
		<-ctx.Done()
		c, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = h.Shutdown(c)
	}()
	err := h.ServeTLS(ln, "", "")
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
	send(w, 200, protocol.Device{Version: 1, ID: s.Identity.ID, Name: s.Identity.Name, Features: []string{"remote-files-v1"}})
}

type remoteFiles struct{ s *Server }

func (*remoteFiles) ID() string                     { return "remote-files-v1" }
func (*remoteFiles) ProtocolVersion() int           { return 1 }
func (*remoteFiles) RequiredGrants() []string       { return []string{"browse(root)", "read(root)"} }
func (*remoteFiles) RequiredCapabilities() []string { return []string{"filesystem.read"} }
func (*remoteFiles) FeatureFlags() []string {
	return []string{"roots", "list", "stat", "read-range", "manifest", "preview", "tar"}
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
}
func (s *Server) roots(w http.ResponseWriter, r *http.Request) {
	if !s.paired(r) {
		fail(w, 403, "unpaired_device")
		return
	}
	roots := []protocol.Root{}
	for _, p := range s.Files.All() {
		if s.Store.Authorized(peerID(r), p.ID(), "browse", 0) == nil {
			roots = append(roots, protocol.Root{ID: p.ID(), Name: p.ID()})
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
	h := sha256.Sum256(data)
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Chunk-SHA256", hex.EncodeToString(h[:]))
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
	m, err := files.Manifest(ctx, p, rel, func(n int64) error { return s.Store.Authorized(peerID(r), p.ID(), "read", n) })
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
	_ = http.NewResponseController(w).SetWriteDeadline(time.Time{})
	w.Header().Set("Content-Type", "application/x-tar")
	w.Header().Set("X-Archive-Codec", codec)
	w.Header().Set("X-DeviceBridge-Version", "1")
	w.WriteHeader(200)
	_ = transfer.WriteTar(r.Context(), p, rel, codec, w, func(n int64) error {
		return s.Store.Authorized(peerID(r), p.ID(), "read", n)
	})
}
