package server

import (
	"context"
	"devicebridge/protocol"
	"encoding/json"
	"io"
	"net"
	"net/http"
)

type tailnetTagsKey struct{}

// TailnetTagSource is attached only to a listener whose ingress is authenticated by Tailscale.
type TailnetTagSource func(context.Context, net.Conn) []string

func (s *Server) tailnetPair(w http.ResponseWriter, r *http.Request) {
	source, _ := r.Context().Value(tailnetTagsKey{}).(func(context.Context) []string)
	policy, err := s.Store.NetworkPolicy(r.Context(), nil)
	if err != nil || !policy["network_tailnet"] || source == nil {
		fail(w, http.StatusForbidden, "tailnet_pairing_denied")
		return
	}
	if r.Method == http.MethodGet {
		send(w, http.StatusOK, struct {
			Name string `json:"name"`
		}{s.Identity.Name})
		return
	}
	var req struct {
		Name string `json:"name"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if dec.Decode(&req) != nil || dec.Decode(new(any)) != io.EOF {
		fail(w, http.StatusBadRequest, "invalid_pairing_identity")
		return
	}
	id := peerID(r)
	if id == s.Identity.ID || s.Store.PairFromTailnet(r.Context(), id, req.Name, source(r.Context())) != nil {
		fail(w, http.StatusForbidden, "tailnet_pairing_denied")
		return
	}
	send(w, http.StatusOK, protocol.PairStatus{ID: id, Status: "paired"})
}
