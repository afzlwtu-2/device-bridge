// Package tailscaled uses an already-running system daemon through its public
// local API. It never changes daemon configuration, login, keys or routes.
package tailscaled

import (
	"context"
	"devicebridge/internal/tailnetipc"
	"devicebridge/internal/transport"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"time"
)

type peerStatus struct {
	HostName         string
	DNSName          string
	TailscaleIPs     []string
	Online           bool
	TxBytes, RxBytes int64
}
type status struct {
	BackendState string
	TailscaleIPs []string
	TUN          bool
	Self         *peerStatus
	Peer         map[string]peerStatus
}
type ping struct {
	Endpoint, PeerRelay, DERPRegionCode, Err string
	DERPRegionID                             int
	LatencySeconds                           float64
}
type Provider struct {
	Socket         string
	RemoteApproved bool
}

func (p *Provider) api(ctx context.Context, method, path string, out any) error {
	socket := p.Socket
	if socket == "" {
		socket = "/run/tailscale/tailscaled.sock"
	}
	h := &http.Transport{Proxy: nil, DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socket)
	}}
	defer h.CloseIdleConnections()
	req, err := http.NewRequestWithContext(ctx, method, "http://local-tailscaled.sock"+path, nil)
	if err != nil {
		return err
	}
	res, err := (&http.Client{Transport: h, Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		return errors.New("existing Tailscale daemon unavailable")
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return errors.New("existing Tailscale daemon denied this read/probe")
	}
	return json.NewDecoder(io.LimitReader(res.Body, 4<<20)).Decode(out)
}
func (p *Provider) Status(ctx context.Context) (tailnetipc.Response, error) {
	var s status
	err := p.api(ctx, "GET", "/localapi/v0/status", &s)
	out := tailnetipc.Response{Version: 1, State: s.BackendState, IPs: s.TailscaleIPs, Userspace: !s.TUN, Mode: "system", Peers: []tailnetipc.Peer{}}
	if s.Self != nil {
		out.Hostname = s.Self.HostName
	}
	for _, v := range s.Peer {
		out.Peers = append(out.Peers, tailnetipc.Peer{Name: v.HostName, DNSName: strings.TrimSuffix(v.DNSName, "."), IPs: v.TailscaleIPs, Online: v.Online, Path: tailnetipc.Path{Kind: "unknown", TxBytes: v.TxBytes, RxBytes: v.RxBytes}})
	}
	return out, err
}
func (*Provider) ID() string { return "tailscaled-v1" }
func (*Provider) Capabilities() transport.Capabilities {
	return transport.Capabilities{Version: 1, Streams: true}
}
func (*Provider) DiscoverCandidates(context.Context) ([]transport.Candidate, error) {
	return nil, errors.New("select a tailnet peer and authenticate its DeviceBridge key")
}
func (p *Provider) Probe(ctx context.Context, c transport.Candidate) (transport.Candidate, error) {
	host, _, err := net.SplitHostPort(c.Endpoint)
	if err != nil {
		return c, err
	}
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return c, err
	}
	st, err := p.Status(ctx)
	if err != nil || st.State != "Running" {
		return c, errors.New("existing Tailscale daemon is not running")
	}
	known := false
	for _, peer := range st.Peers {
		for _, a := range peer.IPs {
			if a == ip.String() {
				known = true
			}
		}
	}
	if !known {
		return c, errors.New("peer not in authenticated system tailnet map")
	}
	var result ping
	for i := 0; i < 4; i++ {
		q := url.Values{"ip": {host}, "type": {"disco"}, "size": {"0"}}
		if err = p.api(ctx, "POST", "/localapi/v0/ping?"+q.Encode(), &result); err != nil {
			return c, err
		}
		if result.Endpoint != "" || result.PeerRelay != "" {
			break
		}
	}
	c.PathKind = "unknown"
	switch {
	case result.Err != "":
		return c, errors.New("Tailscale path probe failed")
	case result.PeerRelay != "":
		c.PathKind = "peer-relay"
		c.Relay = result.PeerRelay
	case result.Endpoint != "":
		c.PathKind = "direct"
	case result.DERPRegionID != 0:
		c.PathKind = "derp"
		c.Relay = result.DERPRegionCode
	}
	c.Direct = c.PathKind == "direct"
	c.RTT = time.Duration(result.LatencySeconds * float64(time.Second))
	c.Observed = time.Now().UTC()
	c.Transport = p.ID()
	c.Cost = transport.NetworkCost{Internet: true, Relayed: c.PathKind == "derp" || c.PathKind == "peer-relay", Known: c.PathKind != "unknown"}
	return c, nil
}
func (p *Provider) Dial(ctx context.Context, c transport.Candidate) (net.Conn, error) {
	if !p.RemoteApproved {
		return nil, errors.New("explicit internet/relay data approval is required")
	}
	host, port, err := net.SplitHostPort(c.Endpoint)
	if err != nil || port != "8731" {
		return nil, errors.New("only DeviceBridge's tailnet service port is enabled")
	}
	st, err := p.Status(ctx)
	if err != nil || st.State != "Running" {
		return nil, errors.New("existing Tailscale daemon unavailable")
	}
	known := false
	for _, peer := range st.Peers {
		for _, ip := range peer.IPs {
			if ip == host {
				known = true
			}
		}
	}
	if !known {
		return nil, errors.New("unknown tailnet node")
	}
	var local net.IP
	for _, ip := range st.IPs {
		if parsed := net.ParseIP(ip); parsed != nil && parsed.To4() != nil {
			local = parsed
			break
		}
	}
	if local == nil {
		return nil, errors.New("system Tailscale has no IPv4 address")
	}
	return (&net.Dialer{Timeout: 8 * time.Second, LocalAddr: &net.TCPAddr{IP: local}}).DialContext(ctx, "tcp4", c.Endpoint)
}
func (*Provider) Listen(context.Context, string) (net.Listener, error) {
	return nil, errors.New("use an explicitly bound agent listener on the existing tailnet IP")
}
func (*Provider) NetworkCost(transport.Candidate) transport.NetworkCost {
	return transport.NetworkCost{Internet: true}
}
func (*Provider) Close() error { return nil }
