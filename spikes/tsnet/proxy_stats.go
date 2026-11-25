package main

import (
	"context"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"unicode"

	"devicebridge/internal/tailnetipc"
)

const proxyDestinationLimit = 16

type proxyBytes struct {
	rx atomic.Uint64
	tx atomic.Uint64
}

// A proxy listener owns its telemetry and client sockets. Closing it ends the
// client sessions as well as accepting new ones.
type monitoredProxy struct {
	net.Listener
	mu           sync.Mutex
	closed       bool
	clients      map[*proxyClient]struct{}
	upstreams    map[*proxyUpstream]struct{}
	destinations map[string]*proxyBytes
	recent       []string
	connections  uint64
	total        proxyBytes
}

func newMonitoredProxy(listener net.Listener) *monitoredProxy {
	return &monitoredProxy{
		Listener: listener, clients: make(map[*proxyClient]struct{}),
		upstreams:    make(map[*proxyUpstream]struct{}),
		destinations: make(map[string]*proxyBytes),
	}
}

func (p *monitoredProxy) Accept() (net.Conn, error) {
	conn, err := p.Listener.Accept()
	if err != nil {
		return nil, err
	}
	peer, _ := conn.RemoteAddr().(*net.TCPAddr)
	client := &proxyClient{Conn: conn, proxy: p}
	if peer != nil {
		client.port = peer.Port
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		conn.Close()
		return nil, net.ErrClosed
	}
	p.clients[client] = struct{}{}
	p.connections++
	return client, nil
}

func (p *monitoredProxy) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return nil
	}
	p.closed = true
	err := p.Listener.Close()
	for client := range p.clients {
		client.Conn.Close()
	}
	for upstream := range p.upstreams {
		upstream.Conn.Close()
	}
	clear(p.clients)
	clear(p.upstreams)
	return err
}

type proxyClient struct {
	net.Conn
	proxy *monitoredProxy
	port  int
}

func (c *proxyClient) Close() error {
	c.proxy.mu.Lock()
	delete(c.proxy.clients, c)
	c.proxy.mu.Unlock()
	return c.Conn.Close()
}

func halfCloseWrite(conn net.Conn) error {
	if half, ok := conn.(interface{ CloseWrite() error }); ok {
		return half.CloseWrite()
	}
	return nil
}

func (c *proxyClient) CloseWrite() error { return halfCloseWrite(c.Conn) }

func (p *monitoredProxy) dial(ctx context.Context, network, address string, dial func(context.Context, string, string) (net.Conn, error)) (net.Conn, error) {
	conn, err := dial(ctx, network, address)
	if err != nil {
		return nil, err
	}
	host, port, _ := net.SplitHostPort(address)
	host = strings.ToValidUTF8(host, "?")
	host = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) {
			return '?'
		}
		return unicode.ToLower(r)
	}, host)
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		conn.Close()
		return nil, net.ErrClosed
	}
	upstream := &proxyUpstream{Conn: conn, proxy: p, row: p.destinationLocked(host), endpoint: net.JoinHostPort(host, port)}
	p.upstreams[upstream] = struct{}{}
	return upstream, nil
}

func (p *monitoredProxy) destinationLocked(host string) *proxyBytes {
	row := p.destinations[host]
	if row == nil {
		row = new(proxyBytes)
		if len(p.recent) == proxyDestinationLimit {
			delete(p.destinations, p.recent[0])
			p.recent = p.recent[1:]
		}
		p.destinations[host] = row
	} else {
		for i, name := range p.recent {
			if name == host {
				p.recent = append(p.recent[:i], p.recent[i+1:]...)
				break
			}
		}
	}
	p.recent = append(p.recent, host)
	return row
}

func (p *monitoredProxy) snapshot() *tailnetipc.ProxyStats {
	p.mu.Lock()
	defer p.mu.Unlock()
	result := &tailnetipc.ProxyStats{
		Connections: p.connections, Active: len(p.clients),
		RxBytes: p.total.rx.Load(), TxBytes: p.total.tx.Load(),
	}
	for c := range p.clients {
		if c.port != 0 && len(result.ClientPorts) < 64 {
			result.ClientPorts = append(result.ClientPorts, c.port)
		}
	}
	for connection := range p.upstreams {
		result.ActiveConnections = append(result.ActiveConnections, tailnetipc.ProxyDestination{Host: connection.endpoint, RxBytes: connection.bytes.rx.Load(), TxBytes: connection.bytes.tx.Load()})
	}
	for i := len(p.recent) - 1; i >= 0; i-- {
		host := p.recent[i]
		row := p.destinations[host]
		result.Destinations = append(result.Destinations, tailnetipc.ProxyDestination{
			Host: host, RxBytes: row.rx.Load(), TxBytes: row.tx.Load(),
		})
	}
	return result
}

type proxyUpstream struct {
	net.Conn
	proxy    *monitoredProxy
	row      *proxyBytes
	bytes    proxyBytes
	endpoint string
}

func (c *proxyUpstream) Read(buf []byte) (int, error) {
	n, err := c.Conn.Read(buf)
	c.proxy.total.rx.Add(uint64(n))
	c.row.rx.Add(uint64(n))
	c.bytes.rx.Add(uint64(n))
	return n, err
}

func (c *proxyUpstream) Write(buf []byte) (int, error) {
	n, err := c.Conn.Write(buf)
	c.proxy.total.tx.Add(uint64(n))
	c.row.tx.Add(uint64(n))
	c.bytes.tx.Add(uint64(n))
	return n, err
}

func (c *proxyUpstream) CloseWrite() error { return halfCloseWrite(c.Conn) }

func (c *proxyUpstream) Close() error {
	c.proxy.mu.Lock()
	delete(c.proxy.upstreams, c)
	c.proxy.mu.Unlock()
	return c.Conn.Close()
}
