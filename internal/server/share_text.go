package server

import (
	"devicebridge/internal/features"
	"devicebridge/internal/storage"
	"devicebridge/protocol"
	"encoding/json"
	"errors"
	"io"
	"net/http"
)

type shareText struct{ s *Server }

func (*shareText) ID() string                           { return protocol.TextShareFeature }
func (*shareText) ProtocolVersion() int                 { return 1 }
func (*shareText) RequiredGrants() []string             { return []string{"share_receive(text)"} }
func (*shareText) RequiredCapabilities() []string       { return nil }
func (*shareText) FeatureFlags() []string               { return []string{"text"} }
func (*shareText) RegisterUIActions() []features.Action { return nil }

func (m *shareText) RegisterBackend(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/share/text", m.receive)
}

func (m *shareText) receive(w http.ResponseWriter, r *http.Request) {
	var req protocol.TextShareRequest
	decoder := json.NewDecoder(r.Body)
	if err := decoder.Decode(&req); err != nil || decoder.Decode(new(any)) != io.EOF {
		fail(w, http.StatusBadRequest, "invalid_text_share")
		return
	}
	message, err := m.s.Store.ReceiveText(peerID(r), req)
	switch {
	case errors.Is(err, storage.ErrDenied):
		fail(w, http.StatusForbidden, "text_sharing_not_allowed")
	case errors.Is(err, storage.ErrInvalidSharedText):
		fail(w, http.StatusBadRequest, "invalid_text_share")
	case errors.Is(err, storage.ErrTextShareConflict):
		fail(w, http.StatusConflict, "text_message_id_conflict")
	case err != nil:
		fail(w, http.StatusInternalServerError, "text_inbox_write_failed")
	default:
		send(w, http.StatusOK, struct {
			ID string `json:"id"`
		}{message.ID})
	}
}
