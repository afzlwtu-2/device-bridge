package storage

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
)

func TestNetworkPolicyAndSSHApprovalStayIndependent(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	id := strings.Repeat("b", 64)
	if _, err = s.DB.Exec("INSERT INTO peers(id,name,status,expires) VALUES(?,?,?,0)", id, "phone", "paired"); err != nil {
		t.Fatal(err)
	}
	access, err := s.AgentSSHAccess(ctx, id, "request")
	if err != nil || access.Allowed || !access.Requested {
		t.Fatalf("paired shell must await approval: %+v %v", access, err)
	}
	if _, err = s.AgentSSHAccess(ctx, id, "allow"); err != nil {
		t.Fatal(err)
	}
	p, err := s.NetworkPolicy(ctx, map[string]bool{"network_agent_ssh": false})
	if err != nil || p["network_agent_ssh"] || !p["network_direct"] {
		t.Fatalf("independent policy: %v %v", p, err)
	}
	if _, err = s.NetworkPolicy(ctx, map[string]bool{"arbitrary_setting": true}); err == nil {
		t.Fatal("unknown setting accepted")
	}
	s.Close()
	s, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	p, err = s.NetworkPolicy(ctx, nil)
	if err != nil || p["network_agent_ssh"] {
		t.Fatal("policy lost after restart")
	}
	access, err = s.AgentSSHAccess(ctx, id, "")
	if err != nil || !access.Allowed {
		t.Fatal("service policy erased peer approval")
	}
	if err = s.Revoke(id); err != nil {
		t.Fatal(err)
	}
	if _, err = s.AgentSSHAccess(ctx, id, ""); err == nil {
		t.Fatal("revoked peer retained SSH access")
	}
	if _, err = s.DB.Exec("UPDATE peers SET status='paired' WHERE id=?", id); err != nil {
		t.Fatal(err)
	}
	access, err = s.AgentSSHAccess(ctx, id, "")
	if err != nil || access.Allowed {
		t.Fatal("re-pair resurrected old shell permission")
	}
}
func TestSSHHostPersistenceIsNotAgentPairing(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	h, err := s.SaveSSHHost(ctx, SSHHost{Version: 1, Name: "fixture", Host: "127.0.0.1", Port: 8022, User: "guest", Fingerprint: "SHA256:fixture", Transport: "direct"})
	if err != nil {
		t.Fatal(err)
	}
	hosts, err := s.SSHHosts(ctx)
	if err != nil || len(hosts) != 1 || hosts[0].ID != h.ID {
		t.Fatalf("host not persisted: %v %v", hosts, err)
	}
	peers, err := s.Peers()
	if err != nil || len(peers) != 0 {
		t.Fatal("SSH host created an Agent pairing")
	}
	if _, err = s.SSHHost(ctx, "../../escape"); err == nil {
		t.Fatal("invalid ID accepted")
	}
	if err = s.RemoveSSHHost(ctx, h.ID); err != nil {
		t.Fatal(err)
	}
	hosts, err = s.SSHHosts(ctx)
	if err != nil || len(hosts) != 0 {
		t.Fatal("host removal failed")
	}
}

func TestSSHAccountEditAndDetachClearOnlyInvalidSelections(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := t.Context()
	peer := strings.Repeat("a", 64)
	if err := s.TrustOutbound(peer, "laptop", "paired"); err != nil {
		t.Fatal(err)
	}
	host, err := s.SaveSSHHost(ctx, SSHHost{
		Version: 1, Name: "laptop", Host: "127.0.0.1", Port: 22,
		User: "owner", Fingerprint: "SHA256:fixture",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.AssociateSSHHost(ctx, host.ID, peer); err != nil {
		t.Fatal(err)
	}
	method := "ssh:" + host.ID
	if _, err := s.PeerSSHMethod(ctx, peer, &method); err != nil {
		t.Fatal(err)
	}
	host.Name = "alias"
	if saved, err := s.SaveSSHHost(ctx, host); err != nil || saved.AgentPeerID != peer {
		t.Fatalf("renaming broke the association: %v, %v", saved, err)
	}
	if _, err := s.AssociateSSHHost(ctx, host.ID, ""); err != nil {
		t.Fatal(err)
	}
	if got, err := s.PeerSSHMethod(ctx, peer, nil); err != nil || got != "auto" {
		t.Fatalf("detached account still selected: %s, %v", got, err)
	}
	if _, err := s.AssociateSSHHost(ctx, host.ID, peer); err != nil {
		t.Fatal(err)
	}
	if _, err := s.PeerSSHMethod(ctx, peer, &method); err != nil {
		t.Fatal(err)
	}
	host.Port = 8022
	if saved, err := s.SaveSSHHost(ctx, host); err != nil || saved.AgentPeerID != "" {
		t.Fatalf("editing the endpoint retained its association: %v, %v", saved, err)
	}
	if got, err := s.PeerSSHMethod(ctx, peer, nil); err != nil || got != "auto" {
		t.Fatalf("changed account still selected: %s, %v", got, err)
	}
}
