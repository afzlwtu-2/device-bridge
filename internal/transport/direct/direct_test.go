package direct

import (
	"context"
	"devicebridge/internal/transport"
	"testing"
)

func TestDirectPolicyRejectsRemoteAndRelayedCandidates(t *testing.T) {
	t.Parallel()
	p, err := NewCIDR("test0", "192.168.50.2/24")
	if err != nil {
		t.Fatal(err)
	}
	for _, endpoint := range []string{"example.com:8731", "8.8.8.8:8731", "100.64.0.1:8731", "192.168.51.2:8731", "192.168.50.3:0"} {
		if p.Check(endpoint) == nil {
			t.Fatalf("accepted %s", endpoint)
		}
	}
	if p.Check("192.168.50.3:8731") != nil {
		t.Fatal("on-link endpoint rejected")
	}
	for _, cost := range []transport.NetworkCost{{Metered: true}, {Internet: true}, {Relayed: true}} {
		if _, err = p.Dial(context.Background(), transport.Candidate{Endpoint: "192.168.50.3:8731", Cost: cost}); err == nil {
			t.Fatal("unapproved network cost accepted")
		}
	}
}
