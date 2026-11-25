package server

import (
	"devicebridge/internal/features"
	"devicebridge/internal/storage"
	"devicebridge/internal/transfer"
	"errors"
	"net/http"
	"time"
)

const fileShareEndpoint = "/v1/share/file"
const folderShareEndpoint = "/v1/share/folder"

type shareFile struct{ s *Server }

func (*shareFile) ID() string                           { return "quick-share-file-v1" }
func (*shareFile) ProtocolVersion() int                 { return 1 }
func (*shareFile) RequiredGrants() []string             { return []string{"share_receive(file)"} }
func (*shareFile) RequiredCapabilities() []string       { return []string{"filesystem.write"} }
func (*shareFile) FeatureFlags() []string               { return []string{"single-file", "folder-tar", "xxh64"} }
func (*shareFile) RegisterUIActions() []features.Action { return nil }
func (m *shareFile) RegisterBackend(mux *http.ServeMux) {
	mux.HandleFunc("POST "+fileShareEndpoint, m.receive)
	mux.HandleFunc("POST "+folderShareEndpoint, m.receiveFolder)
}

func (m *shareFile) access(sender string) func() error {
	return func() error {
		allowed, err := m.s.Store.FileShareAccess(sender, nil)
		if err != nil {
			return err
		}
		if !allowed {
			return storage.ErrDenied
		}
		return nil
	}
}

func shareDeadline(w http.ResponseWriter, timeout time.Duration) {
	deadline := time.Now().Add(timeout)
	control := http.NewResponseController(w)
	_ = control.SetReadDeadline(deadline)
	_ = control.SetWriteDeadline(deadline)
}

func (m *shareFile) receive(w http.ResponseWriter, r *http.Request) {
	authorize := m.access(peerID(r))
	if err := authorize(); err != nil {
		fail(w, http.StatusForbidden, "file_sharing_not_allowed")
		return
	}
	if r.ContentLength < 0 || r.ContentLength > transfer.MaxSharedFileBytes {
		fail(w, http.StatusRequestEntityTooLarge, "invalid_shared_file_length")
		return
	}
	body, receiptReady := beginStreamUpload(w, r.Body)
	meta := transfer.SharedFile{
		Name: r.URL.Query().Get("name"), Size: r.ContentLength,
		XXH64: r.URL.Query().Get("xxh64"),
	}
	err := transfer.ReceiveSharedFile(r.Context(), m.s.SharedFiles, body, meta, authorize)
	receiptReady()
	respondSharedPayload(w, meta, err)
}

func (m *shareFile) receiveFolder(w http.ResponseWriter, r *http.Request) {
	sender := peerID(r)
	authorize := m.access(sender)
	if err := authorize(); err != nil {
		fail(w, http.StatusForbidden, "file_sharing_not_allowed")
		return
	}
	body, receiptReady := beginStreamUpload(w, r.Body)
	query := r.URL.Query()
	receipt, err := transfer.ReceiveSharedFolder(r.Context(), m.s.SharedFiles, body, sender, query.Get("name"), query.Get("codec"), authorize)
	receiptReady()
	respondSharedPayload(w, receipt, err)
}

func respondSharedPayload(w http.ResponseWriter, receipt any, err error) {
	switch {
	case errors.Is(err, storage.ErrDenied):
		fail(w, http.StatusForbidden, "file_sharing_not_allowed")
	case errors.Is(err, transfer.ErrInvalidSharedFile), errors.Is(err, transfer.ErrSharedFileContent):
		fail(w, http.StatusBadRequest, "invalid_shared_file")
	case errors.Is(err, transfer.ErrSharedFileExists):
		fail(w, http.StatusConflict, "shared_file_already_exists")
	case err != nil:
		fail(w, http.StatusInternalServerError, "shared_file_write_failed")
	default:
		send(w, http.StatusCreated, receipt)
	}
}
