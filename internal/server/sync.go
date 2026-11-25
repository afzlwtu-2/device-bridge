package server

import (
	"encoding/json"
	"io"
	"net/http"

	"devicebridge/internal/features"
	"devicebridge/protocol"
)

type folderSync struct{ s *Server }

func (*folderSync) ID() string                     { return protocol.SyncControlFeature }
func (*folderSync) ProtocolVersion() int           { return features.ContractVersion }
func (*folderSync) RequiredGrants() []string       { return []string{"sync-control", "read(root)"} }
func (*folderSync) RequiredCapabilities() []string { return []string{"folder-sync"} }
func (*folderSync) FeatureFlags() []string {
	return []string{"endpoint-to-endpoint", "bounded-session", "no-controller-relay"}
}
func (*folderSync) RegisterUIActions() []features.Action {
	return []features.Action{{ID: "sync-folder", Label: "Sync folder", Icon: "sync", Location: "file-manager"}}
}
func (m *folderSync) RegisterBackend(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/sync/control", m.control)
}
func (m *folderSync) control(w http.ResponseWriter, r *http.Request) {
	if !m.s.paired(r) {
		fail(w, http.StatusForbidden, "unpaired_device")
		return
	}
	var request protocol.SyncControl
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil || decoder.Decode(new(any)) != io.EOF {
		fail(w, http.StatusBadRequest, "invalid_sync_control")
		return
	}
	if err := m.s.Store.Audit(peerID(r), "folder-sync-control", request.Operation+":"+request.Group); err != nil {
		fail(w, http.StatusInternalServerError, "audit_unavailable")
		return
	}
	result, err := m.s.Sync.Handle(r.Context(), peerID(r), request)
	if err != nil {
		send(w, http.StatusForbidden, protocol.Error{Code: "sync_control_denied", Message: err.Error()})
		return
	}
	send(w, http.StatusOK, result)
}
