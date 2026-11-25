package server

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"devicebridge/internal/actions"
	"devicebridge/internal/features"
	"devicebridge/internal/storage"
)

type agentActions struct{ s *Server }

func (*agentActions) ID() string                     { return actions.Feature }
func (*agentActions) ProtocolVersion() int           { return features.ContractVersion }
func (*agentActions) RequiredGrants() []string       { return []string{"approved-action-request"} }
func (*agentActions) RequiredCapabilities() []string { return []string{"agent-diagnostics"} }
func (*agentActions) FeatureFlags() []string         { return []string{"audited", "single-use"} }

func (*agentActions) RegisterUIActions() []features.Action {
	return []features.Action{{
		ID: actions.Feature, Label: "Agent actions", Icon: "fact_check", Location: "device-commands",
		RequiredGrants: []string{"approved-action-request"}, RequiredCapabilities: []string{"agent-diagnostics"},
	}}
}

func (m *agentActions) RegisterBackend(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/actions/presets", m.presets)
	mux.HandleFunc("POST /v1/actions/request", m.request)
}

func (m *agentActions) presets(w http.ResponseWriter, r *http.Request) {
	if !m.s.paired(r) {
		fail(w, http.StatusForbidden, "unpaired_device")
		return
	}
	if aclEnabled, aclAllowed, err := m.s.Store.CheckPeerACL(r.Context(), peerID(r), "actions"); err != nil || (aclEnabled && !aclAllowed) {
		fail(w, http.StatusForbidden, "acl_denied")
		return
	}
	send(w, http.StatusOK, actions.Presets())
}

func (m *agentActions) request(w http.ResponseWriter, r *http.Request) {
	if !m.s.paired(r) {
		fail(w, http.StatusForbidden, "unpaired_device")
		return
	}
	if aclEnabled, aclAllowed, err := m.s.Store.CheckPeerACL(r.Context(), peerID(r), "actions"); err != nil || (aclEnabled && !aclAllowed) {
		fail(w, http.StatusForbidden, "acl_denied")
		return
	}
	var payload struct {
		Preset string `json:"preset"`
		ID     string `json:"id"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&payload); err != nil || decoder.Decode(new(any)) != io.EOF || !actions.Known(payload.Preset) {
		fail(w, http.StatusBadRequest, "invalid_action_request")
		return
	}
	ctx, peer := r.Context(), peerID(r)
	state, run, err := m.s.Store.ActionRequestState(ctx, peer, payload.Preset, payload.ID)
	switch {
	case errors.Is(err, storage.ErrActionBusy):
		fail(w, http.StatusConflict, "action_request_already_pending")
		return
	case errors.Is(err, storage.ErrDenied):
		fail(w, http.StatusForbidden, "action_approval_expired_or_revoked")
		return
	case err != nil:
		fail(w, http.StatusBadRequest, "invalid_action_request")
		return
	}
	if run {
		if err := m.s.Store.Audit(peer, "agent-action", state.Preset+":"+state.ID); err != nil {
			fail(w, http.StatusInternalServerError, "audit_unavailable")
			return
		}
		output, runErr := actions.Run(ctx, m.s.Store, m.s.ActionState, peer, state.Preset)
		if runErr != nil {
			output = "The approved diagnostic could not complete."
		}
		state, err = m.s.Store.CompleteAction(ctx, peer, state.Preset, state.ID, output, runErr == nil)
		if errors.Is(err, storage.ErrDenied) {
			fail(w, http.StatusForbidden, "action_approval_expired_or_revoked")
			return
		}
		if err != nil {
			fail(w, http.StatusInternalServerError, "action_result_unavailable")
			return
		}
	}
	state.Peer = ""
	status := http.StatusOK
	if state.State == "pending" || state.State == "running" {
		status = http.StatusAccepted
	}
	send(w, status, state)
}
