package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	"devicebridge/internal/features"
	"devicebridge/internal/files"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/storage"
	"devicebridge/internal/transfer"
	"devicebridge/protocol"
)

const managedUploadEndpoint = "/v1/termux-files/upload"
const managedRemoveEndpoint = "/v1/termux-files/remove-verified"

type termuxFiles struct{ s *Server }

func (*termuxFiles) ID() string                           { return protocol.TermuxFilesFeature }
func (*termuxFiles) ProtocolVersion() int                 { return 1 }
func (*termuxFiles) RequiredGrants() []string             { return []string{"termux-files", "read(home)"} }
func (*termuxFiles) RequiredCapabilities() []string       { return []string{"termux-home"} }
func (*termuxFiles) FeatureFlags() []string               { return []string{"verified-copy", "verified-move"} }
func (*termuxFiles) RegisterUIActions() []features.Action { return nil }

func (m *termuxFiles) RegisterBackend(mux *http.ServeMux) {
	mux.HandleFunc("POST "+managedUploadEndpoint, m.upload)
	mux.HandleFunc("POST "+managedRemoveEndpoint, m.remove)
}

func (s *Server) termuxFilesAllowed(peer, root string, bytes int64) error {
	if !s.TermuxFiles || root != "home" {
		return storage.ErrDenied
	}
	allowed, err := s.Store.TermuxFilesAccess(peer, nil)
	if err != nil || !allowed {
		return storage.ErrDenied
	}
	return s.Store.Authorized(peer, root, "read", bytes)
}

func (m *termuxFiles) home(w http.ResponseWriter, peer, root, action, relative string) (*filesproviders.Native, bool) {
	if err := m.s.termuxFilesAllowed(peer, root, 0); err != nil {
		fail(w, http.StatusForbidden, "termux_file_management_denied")
		return nil, false
	}
	p, ok := m.s.Files.Get(root)
	native, nativeOK := p.(*filesproviders.Native)
	if !ok || !nativeOK {
		fail(w, http.StatusForbidden, "native_termux_home_required")
		return nil, false
	}
	if err := m.s.Store.Audit(peer, action, root+"/"+relative); err != nil {
		fail(w, http.StatusInternalServerError, "audit_unavailable")
		return nil, false
	}
	return native, true
}

func (m *termuxFiles) upload(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	peer, root, relative := peerID(r), q.Get("root"), q.Get("path")
	if filesproviders.ValidPath(relative) != nil {
		fail(w, http.StatusBadRequest, "unsafe_path")
		return
	}
	native, ok := m.home(w, peer, root, "termux-file-upload", relative)
	if !ok {
		return
	}
	folder, err := native.OpenSyncDirectory(r.Context(), relative)
	if err != nil {
		managedFileError(w, err)
		return
	}
	defer folder.Close()
	parent, err := os.OpenRoot(fmt.Sprintf("/proc/self/fd/%d", folder.Fd()))
	if err != nil {
		managedFileError(w, err)
		return
	}
	defer parent.Close()
	body, receiptReady := beginStreamUpload(w, r.Body)
	receipt, err := transfer.ReceiveManagedTree(r.Context(), parent, body, peer, q.Get("name"), func(bytes int64) error {
		return m.s.termuxFilesAllowed(peer, root, bytes)
	})
	receiptReady()
	if err != nil {
		managedFileError(w, err)
		return
	}
	send(w, http.StatusCreated, receipt)
}

func (m *termuxFiles) remove(w http.ResponseWriter, r *http.Request) {
	var request protocol.VerifiedRemoval
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil || decoder.Decode(new(any)) != io.EOF || filesproviders.ValidPath(request.Path) != nil {
		fail(w, http.StatusBadRequest, "invalid_move_receipt")
		return
	}
	excludes, err := files.ValidateExclusions(request.Excludes)
	if err != nil {
		managedFileError(w, err)
		return
	}
	peer := peerID(r)
	native, ok := m.home(w, peer, request.Root, "termux-remove-verified", request.Path)
	if !ok {
		return
	}
	shareDeadline(w, 15*time.Minute)
	remaining, err := transfer.RemoveVerified(r.Context(), native, request.Path, request.XXH64, excludes, func(int64) error {
		return m.s.termuxFilesAllowed(peer, request.Root, 0)
	})
	if err != nil {
		managedFileError(w, err)
		return
	}
	send(w, http.StatusOK, map[string]bool{"source_remaining": remaining})
}

func managedFileError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, storage.ErrDenied):
		fail(w, http.StatusForbidden, "termux_file_management_denied")
	case errors.Is(err, transfer.ErrSharedFileExists):
		send(w, http.StatusConflict, protocol.Error{Code: "destination_exists", Message: "Destination exists. Choose another folder or name."})
	default:
		send(w, http.StatusBadRequest, protocol.Error{Code: "termux_file_operation_failed", Message: err.Error()})
	}
}
