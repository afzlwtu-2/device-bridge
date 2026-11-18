// Package direct implements only explicitly selected on-link TCP networks.
package direct

import (
	"context"
	"devicebridge/internal/platform"
	"devicebridge/internal/transport"
	"errors"
	"net"
	"net/netip"
	"strconv"
	"time"
)

type Provider struct {
	Interface string
	Prefix    netip.Prefix
	Address   netip.Addr
	Discovery func(context.Context) ([]transport.Candidate, error)
}

// NewCIDR is an explicit user declaration of an approved unmetered LAN. It also
// works on Android versions that prohibit Go's netlink interface enumeration.
func NewCIDR(iface, cidr string) (*Provider, error) {
	p, err := netip.ParsePrefix(cidr)
	if err != nil || !p.Addr().Is4() {
		return nil, errors.New("an explicit IPv4 LAN interface/address CIDR is required")
	}
	if iface == "" || p.Bits() < 8 || (!p.Addr().IsPrivate() && !p.Addr().IsLoopback()) {
		return nil, errors.New("only approved private LAN or loopback networks supported")
	}
	return &Provider{Interface: iface, Prefix: p.Masked(), Address: p.Addr()}, nil
}
func (p *Provider) ID() string { return "direct-lan-v1" }
func (p *Provider) Capabilities() transport.Capabilities {
	return transport.Capabilities{Version: 1, Streams: true, Discovery: true}
}
func (p *Provider) NetworkCost(transport.Candidate) transport.NetworkCost {
	return transport.NetworkCost{Known: true}
}
func (p *Provider) DiscoverCandidates(ctx context.Context) ([]transport.Candidate, error) {
	if p.Discovery == nil {
		return nil, errors.New("discovery not configured")
	}
	return p.Discovery(ctx)
}
func (p *Provider) Check(endpoint string) error {
	host, port, err := net.SplitHostPort(endpoint)
	if err != nil {
		return err
	}
	a, err := netip.ParseAddr(host)
	if err != nil || !p.Prefix.Contains(a) {
		return errors.New("endpoint is outside approved on-link LAN")
	}
	n, err := strconv.Atoi(port)
	if err != nil || n < 1 || n > 65535 {
		return errors.New("invalid endpoint port")
	}
	return nil
}
func (p *Provider) Dial(ctx context.Context, c transport.Candidate) (net.Conn, error) {
	if err := p.Check(c.Endpoint); err != nil {
		return nil, err
	}
	if c.Cost.Metered || c.Cost.Internet || c.Cost.Relayed {
		return nil, errors.New("route policy denies bulk connection")
	}
	d := net.Dialer{Timeout: 8 * time.Second, LocalAddr: &net.TCPAddr{IP: net.ParseIP(p.Address.String())}, Control: platform.SocketControl}
	return d.DialContext(ctx, "tcp4", c.Endpoint)
}
func (p *Provider) Listen(ctx context.Context, endpoint string) (net.Listener, error) {
	host, _, err := net.SplitHostPort(endpoint)
	if err != nil {
		return nil, err
	}
	if host != p.Address.String() {
		return nil, errors.New("listener must bind the approved local address")
	}
	lc := net.ListenConfig{Control: platform.SocketControl}
	return lc.Listen(ctx, "tcp4", endpoint)
}
func (p *Provider) Probe(ctx context.Context, c transport.Candidate) (transport.Candidate, error) {
	start := time.Now()
	conn, err := p.Dial(ctx, c)
	if err != nil {
		return c, err
	}
	conn.Close()
	c.RTT = time.Since(start)
	return c, nil
}
func (p *Provider) Close() error { return nil }
