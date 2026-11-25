package server

import (
	"context"
	"encoding/json"
	"net/http"
	"time"
)

func (s *Server) commitConnection(w http.ResponseWriter, r *http.Request) {
	if !s.paired(r) {
		fail(w, 403, "unpaired_device")
		return
	}
	if aclEnabled, aclAllowed, err := s.Store.CheckPeerACL(r.Context(), peerID(r), "link"); err != nil || (aclEnabled && !aclAllowed) {
		fail(w, 403, "acl_denied")
		return
	}
	var req struct {
		ID string `json:"operation_id"`
	}
	if json.NewDecoder(r.Body).Decode(&req) != nil {
		fail(w, 400, "invalid_request")
		return
	}
	lease, err := s.Store.ChangeLinkLease(r.Context(), peerID(r), req.ID, "commit", 0)
	if err != nil {
		fail(w, 409, "link_commit_denied")
		return
	}
	send(w, 200, lease)
}

// The local Agent owns the deadline; losing the network/control client does not
// cancel rollback. On process restart the persisted lease is checked again.
func (s *Server) watchLinkLease(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		lease, err := s.Store.LinkLease(ctx)
		if err == nil && lease.ID != "" && lease.Stage == "preparing" && lease.Deadline <= time.Now().Unix() {
			claimed, claimErr := s.Store.ChangeLinkLease(ctx, "", "", "claim-expired", 0)
			if claimErr == nil {
				restore, stop := context.WithTimeout(ctx, 20*time.Second)
				stage := "needs_recovery"
				if s.RestoreLink != nil {
					if result, err := s.RestoreLink(restore); err == nil && result.OK {
						stage = "restored"
					}
				}
				_, _ = s.Store.ChangeLinkLease(restore, claimed.Peer, claimed.ID, stage, 0)
				stop()
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
