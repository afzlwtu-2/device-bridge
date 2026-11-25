package synccontrol

import (
	"context"
	"devicebridge/internal/platform"
	"errors"
	"io"
	"net"
	"net/netip"
	"sync"
	"time"
)

// endpointTunnel is local to a transferring endpoint, never a controller relay.
// Android's standalone engine cannot consume our socket-control callback, so
// its encrypted streams cross this endpoint-owned adapter. Every physical
// socket is bound to the approved Android Network; no VPN/root is needed.
type endpointTunnel struct {
	EngineListen, EnginePeer string
	public, outbound         net.Listener
	cancel                   context.CancelFunc
	mu                       sync.Mutex
	connections              map[net.Conn]bool
	closed                   bool
}

func newEndpointTunnel(ctx context.Context, listen, peer string) (*endpointTunnel, error) {
	local, e1 := netip.ParseAddrPort(listen)
	remote, e2 := netip.ParseAddrPort(peer)
	if e1 != nil || e2 != nil {
		return nil, errors.New("invalid endpoint adapter addresses")
	}
	engine, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	engineAddress := engine.Addr().String()
	defer engine.Close()
	ctx, cancel := context.WithCancel(ctx)
	tunnel := &endpointTunnel{EngineListen: engineAddress, cancel: cancel, connections: map[net.Conn]bool{}}
	configuration := net.ListenConfig{Control: platform.SocketControl}
	tunnel.public, err = configuration.Listen(ctx, "tcp4", listen)
	if err != nil {
		cancel()
		return nil, err
	}
	tunnel.outbound, err = net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		tunnel.Close()
		return nil, err
	}
	tunnel.EnginePeer = tunnel.outbound.Addr().String()
	forward := func(listener net.Listener, inbound bool) {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			if inbound {
				address, e := netip.ParseAddrPort(connection.RemoteAddr().String())
				if e != nil || address.Addr() != remote.Addr() {
					connection.Close()
					continue
				}
			}
			go func() {
				defer connection.Close()
				target := engineAddress
				dialer := net.Dialer{Timeout: 3 * time.Second}
				if !inbound {
					target = peer
					dialer.LocalAddr = &net.TCPAddr{IP: net.IP(local.Addr().AsSlice())}
					dialer.Control = platform.SocketControl
				}
				other, err := dialer.DialContext(ctx, "tcp4", target)
				if err != nil {
					return
				}
				defer other.Close()
				tunnel.mu.Lock()
				if tunnel.closed {
					tunnel.mu.Unlock()
					return
				}
				tunnel.connections[connection] = true
				tunnel.connections[other] = true
				tunnel.mu.Unlock()
				defer func() {
					tunnel.mu.Lock()
					delete(tunnel.connections, connection)
					delete(tunnel.connections, other)
					tunnel.mu.Unlock()
				}()
				finished := make(chan struct{}, 2)
				copyStream := func(destination, source net.Conn) {
					_, _ = io.Copy(destination, source)
					if tcp, ok := destination.(*net.TCPConn); ok {
						_ = tcp.CloseWrite()
					}
					finished <- struct{}{}
				}
				go copyStream(connection, other)
				go copyStream(other, connection)
				select {
				case <-finished:
				case <-ctx.Done():
					return
				}
				select {
				case <-finished:
				case <-ctx.Done():
				}
			}()
		}
	}
	go forward(tunnel.public, true)
	go forward(tunnel.outbound, false)
	go func() { <-ctx.Done(); tunnel.Close() }()
	return tunnel, nil
}

func (t *endpointTunnel) Close() {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return
	}
	t.closed = true
	t.cancel()
	if t.public != nil {
		t.public.Close()
	}
	if t.outbound != nil {
		t.outbound.Close()
	}
	for connection := range t.connections {
		connection.Close()
	}
}
