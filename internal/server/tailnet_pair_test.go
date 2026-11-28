package server

import (
	"context"
	"devicebridge/internal/auth"
	"devicebridge/internal/client"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/storage"
	"devicebridge/internal/transport"
	"devicebridge/internal/transport/direct"
	"devicebridge/protocol"
	"net"
	"path/filepath"
	"strings"
	"testing"
)

func TestTailnetPairRequiresVerifiedAllowedTagAndWorksOnDirect(t *testing.T) {
	ctx := t.Context()
	dir := t.TempDir()
	stores := make([]*storage.Store, 2)
	identities := make([]*auth.Identity, 2)
	for index, name := range []string{"Nearby receiver", "Nearby sender"} {
		store, err := storage.Open(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = store.Close() })
		id, err := auth.Load(store, name)
		if err != nil {
			t.Fatal(err)
		}
		stores[index], identities[index] = store, id
	}
	receiver, sender := identities[0], identities[1]
	srv := New(stores[0], receiver, &filesproviders.Registry{})
	provider, err := direct.NewCIDR("lo", "127.0.0.1/8")
	if err != nil {
		t.Fatal(err)
	}
	onRoute := func(source TailnetTagSource) *client.Client {
		t.Helper()
		listener, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		serveCtx, cancel := context.WithCancel(ctx)
		done := make(chan struct{})
		go func() {
			defer close(done)
			_ = srv.ServeWithTailnetTags(serveCtx, listener, source)
		}()
		cl := client.New(sender, stores[1], provider, transport.Candidate{
			DeviceID: receiver.ID, Endpoint: listener.Addr().String(),
		})
		t.Cleanup(func() {
			cl.Close()
			cancel()
			<-done
		})
		return cl
	}
	lan := onRoute(nil)
	untrusted := onRoute(func(context.Context, net.Conn) []string { return []string{"tag:guest"} })
	trusted := onRoute(func(context.Context, net.Conn) []string { return []string{"tag:trusted"} })
	pair := func(cl *client.Client) error {
		var result protocol.PairStatus
		return cl.PostJSON(ctx, "/v1/pair/tailnet", map[string]string{"name": sender.Name}, &result)
	}
	for _, cl := range []*client.Client{lan, untrusted} {
		if err := pair(cl); err == nil || !strings.Contains(err.Error(), "tailnet_pairing_denied") {
			t.Fatalf("unexpected pairing result over %s: %v", cl.Endpoint, err)
		}
	}
	policy, err := stores[0].ACLPolicy(ctx)
	if err != nil {
		t.Fatal(err)
	}
	policy.TailnetPairTags = []string{}
	if _, err := stores[0].SaveACLPolicy(ctx, policy); err != nil {
		t.Fatal(err)
	}
	if err := pair(trusted); err == nil {
		t.Fatal("empty allowlist accepted a trusted tag")
	}
	policy.TailnetPairTags = []string{"tag:trusted"}
	if _, err := stores[0].SaveACLPolicy(ctx, policy); err != nil {
		t.Fatal(err)
	}
	if err := pair(trusted); err != nil {
		t.Fatal(err)
	}
	if err := stores[1].CompleteTailnetPair(ctx, receiver.ID, receiver.Name); err != nil {
		t.Fatal(err)
	}
	var device protocol.Device
	if err := lan.JSON(ctx, "/v1/device", nil, &device); err != nil || device.ID != receiver.ID {
		t.Fatalf("paired identity failed on Direct: %+v, %v", device, err)
	}
	for _, resource := range storage.AllACLResources {
		if enabled, allowed, err := stores[0].CheckPeerACL(ctx, sender.ID, resource); err != nil || !enabled || !allowed {
			t.Fatalf("trusted ACL for %q: enabled %v, allowed %v, error %v", resource, enabled, allowed, err)
		}
	}
	policy.Enabled = true
	policy.Rules = []storage.ACLRule{
		{ID: "deny-ssh", Action: "deny", Src: []string{"tag:trusted"}, Dst: []string{"ssh"}},
	}
	if _, err := stores[0].SaveACLPolicy(ctx, policy); err != nil {
		t.Fatal(err)
	}
	if _, allowed, err := stores[0].CheckPeerACL(ctx, sender.ID, "ssh"); err != nil || allowed {
		t.Fatalf("explicit deny must override trusted default: allowed %v, error %v", allowed, err)
	}
	if err := stores[0].Revoke(sender.ID); err != nil {
		t.Fatal(err)
	}
	if err := pair(trusted); err == nil {
		t.Fatal("revoked peer re-paired")
	}
	if err := lan.JSON(ctx, "/v1/device", nil, &device); err == nil {
		t.Fatal("revoked peer accessed Direct")
	}
}
