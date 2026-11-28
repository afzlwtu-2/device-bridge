package tailnet

import (
	"context"
	"devicebridge/internal/tailnetipc"
	"devicebridge/internal/transport"
	"errors"
	"net"
	"time"
)

// Provider wraps app-only tsnet byte streams. Remote data (including potential
// relay use) requires explicit session approval. It is never a LAN fallback.
type Provider struct {
	Control        tailnetipc.Client
	RemoteApproved bool
	PullNetwork    func() (string, error)
	SystemVPN      *AndroidVPN
}

func (*Provider) ID() string { return "tsnet-v1" }
func (*Provider) Capabilities() transport.Capabilities {
	return transport.Capabilities{Version: 1, Streams: true}
}
func (*Provider) DiscoverCandidates(context.Context) ([]transport.Candidate, error) {
	return nil, errors.New("select a tailnet endpoint and verify its DeviceBridge key")
}
func (p *Provider) Probe(ctx context.Context, c transport.Candidate) (transport.Candidate, error) {
	if p.SystemVPN.canReach(c.Endpoint) {
		c.PathKind = "unknown"
		c.Cost = p.NetworkCost(c)
		return c, nil
	}
	v, _, err := p.Control.Exchange(ctx, tailnetipc.Request{Operation: "probe", Target: c.Endpoint})
	if err != nil {
		return c, err
	}
	if v.Path == nil {
		return c, errors.New("path status unavailable")
	}
	c.Direct = v.Path.Kind == "direct"
	c.PathKind = v.Path.Kind
	c.Relay = v.Path.Relay
	c.Cost = transport.NetworkCost{Known: v.Path.Kind != "unknown", Internet: true, Relayed: v.Path.Kind == "derp" || v.Path.Kind == "peer-relay"}
	c.RTT = time.Duration(v.Path.RTTSeconds * float64(time.Second))
	c.Observed = v.Path.Observed
	return c, nil
}
func (p *Provider) Dial(ctx context.Context, c transport.Candidate) (net.Conn, error) {
	if !p.RemoteApproved {
		return nil, errors.New("remote data requires explicit approval; relay paths can change")
	}
	req := tailnetipc.Request{Operation: "stream", Target: c.Endpoint, RemoteApproved: true}
	if p.PullNetwork != nil {
		handle, err := p.PullNetwork()
		if err != nil {
			return nil, err
		}
		req.NetworkHandle = handle
	}
	if p.SystemVPN.canReach(c.Endpoint) {
		if req.NetworkHandle != "" && req.NetworkHandle != p.SystemVPN.handle {
			return nil, &net.OpError{Op: "dial", Net: "tailscale", Err: tailnetipc.ErrNetworkBinding}
		}
		return p.SystemVPN.dial(ctx, c.Endpoint)
	}
	_, conn, err := p.Control.Exchange(ctx, req)
	if errors.Is(err, tailnetipc.ErrNetworkBinding) {
		err = &net.OpError{Op: "dial", Net: "tailscale", Err: err}
	}
	return conn, err
}
func (*Provider) Listen(context.Context, string) (net.Listener, error) {
	return nil, errors.New("the tsnet sidecar owns the listener")
}
func (*Provider) NetworkCost(transport.Candidate) transport.NetworkCost {
	return transport.NetworkCost{Internet: true}
}
func (*Provider) Close() error { return nil }
