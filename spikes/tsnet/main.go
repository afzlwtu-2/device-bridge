// App-only Android/Linux tsnet sidecar. Never uses TUN, VPNService, system daemon
// state, authentication keys from the environment, exit nodes, Funnel or SSH.
package main

import (
	"bufio"
	"context"
	"devicebridge/internal/platform"
	"devicebridge/internal/tailnetipc"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"golang.org/x/sys/unix"
	"io"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"tailscale.com/client/local"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
	"time"
)

func classify(p *ipnstate.PingResult) tailnetipc.Path {
	v := tailnetipc.Path{Kind: "unknown", Observed: time.Now().UTC()}
	if p == nil || p.Err != "" {
		return v
	}
	v.RTTSeconds = p.LatencySeconds
	switch {
	case p.PeerRelay != "":
		v.Kind = "peer-relay"
		v.Relay = p.PeerRelay
	case p.Endpoint != "":
		v.Kind = "direct"
		v.Endpoint = p.Endpoint
	case p.DERPRegionID != 0:
		v.Kind = "derp"
		v.Relay = p.DERPRegionCode
	}
	return v
}
func target(value string) (netip.Addr, error) {
	host, _, err := net.SplitHostPort(value)
	if err != nil {
		host = value
	}
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return ip, errors.New("select a numeric tailnet IP")
	}
	if !netip.MustParsePrefix("100.64.0.0/10").Contains(ip) && !netip.MustParsePrefix("fd7a:115c:a1e0::/48").Contains(ip) {
		return ip, errors.New("only tailnet node IPs are supported")
	}
	return ip, nil
}

type broker struct {
	node     *tsnet.Server
	local    *local.Client
	mu       sync.Mutex
	upstream string
	cancel   context.CancelFunc
}

func (b *broker) probe(ctx context.Context, ip netip.Addr) (tailnetipc.Path, error) {
	var last tailnetipc.Path
	for i := 0; i < 4; i++ {
		p, err := b.local.Ping(ctx, ip, tailcfg.PingDisco)
		if err != nil {
			return last, err
		}
		last = classify(p)
		if last.Kind == "direct" || last.Kind == "peer-relay" {
			return last, nil
		}
	}
	return last, nil
}
func (b *broker) handle(ctx context.Context, conn net.Conn) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(25 * time.Second))
	reader := bufio.NewReader(io.LimitReader(conn, 8192))
	line, err := reader.ReadBytes('\n')
	if err != nil {
		return
	}
	var req tailnetipc.Request
	res := tailnetipc.Response{Version: 1, Userspace: true}
	reply := func() { _ = json.NewEncoder(conn).Encode(res) }
	if json.Unmarshal(line, &req) != nil || req.Version != 1 {
		res.Error = "unsupported control request"
		reply()
		return
	}
	call, cancel := context.WithTimeout(ctx, 18*time.Second)
	defer cancel()
	switch req.Operation {
	case "status":
		st, e := b.local.Status(call)
		if e != nil {
			res.Error = e.Error()
			break
		}
		res.State = st.BackendState
		res.LoginURL = st.AuthURL
		for _, ip := range st.TailscaleIPs {
			res.IPs = append(res.IPs, ip.String())
		}
		res.Peers = []tailnetipc.Peer{}
		for _, p := range st.Peer {
			v := tailnetipc.Peer{Name: p.HostName, Online: p.Online, Path: tailnetipc.Path{Kind: "unknown", TxBytes: p.TxBytes, RxBytes: p.RxBytes}}
			for _, ip := range p.TailscaleIPs {
				v.IPs = append(v.IPs, ip.String())
			}
			res.Peers = append(res.Peers, v)
		}
	case "login":
		err = b.local.StartLoginInteractive(call)
	case "logout":
		err = b.local.Logout(call)
	case "probe", "stream":
		ip, e := target(req.Target)
		if e != nil {
			err = e
			break
		}
		st, e := b.local.Status(call)
		if e != nil {
			err = e
			break
		}
		known := false
		for _, p := range st.Peer {
			for _, a := range p.TailscaleIPs {
				if a == ip {
					known = true
				}
			}
		}
		if !known {
			err = errors.New("node not in authenticated tailnet map")
			break
		}
		path, e := b.probe(call, ip)
		if e != nil {
			err = e
			break
		}
		res.Path = &path
		if req.Operation == "stream" {
			if !req.RemoteApproved {
				err = errors.New("explicit internet/relay data approval required")
				break
			}
			_, port, e := net.SplitHostPort(req.Target)
			if e != nil || port != "8731" {
				err = errors.New("only the DeviceBridge service port is enabled")
				break
			}
			peer, e := b.node.Dial(call, "tcp", req.Target)
			if e != nil {
				err = e
				break
			}
			defer peer.Close()
			reply()
			_ = conn.SetDeadline(time.Time{})
			_ = peer.SetDeadline(time.Time{})
			done := make(chan struct{})
			go func() {
				io.Copy(peer, conn)
				if p, ok := peer.(interface{ CloseWrite() error }); ok {
					p.CloseWrite()
				}
				close(done)
			}()
			io.Copy(conn, peer)
			conn.Close()
			<-done
			return
		}
	case "upstream":
		if req.Target != "" {
			host, _, e := net.SplitHostPort(req.Target)
			ip, ie := netip.ParseAddr(host)
			if e != nil || ie != nil || (!ip.IsPrivate() && !ip.IsLoopback()) {
				err = errors.New("upstream must be an app-local approved address")
				break
			}
		}
		b.mu.Lock()
		b.upstream = req.Target
		b.mu.Unlock()
	case "stop":
		b.cancel()
	default:
		err = errors.New("unknown control operation")
	}
	if err != nil {
		res.Error = err.Error()
	}
	reply()
}
func run() error {
	state := flag.String("state", "", "private sidecar state directory")
	name := flag.String("name", "devicebridge-phone", "app node hostname")
	flag.Parse()
	if *state == "" {
		return errors.New("--state required")
	}
	if err := platform.BindApprovedNetwork(); err != nil {
		return err
	}
	if err := configureNetworkMonitor(); err != nil {
		return err
	}
	os.Unsetenv("TS_AUTHKEY")
	os.Unsetenv("TSNET_FORCE_LOGIN")
	os.Unsetenv("TS_CLIENT_ID")
	os.Unsetenv("TS_CLIENT_SECRET")
	if err := os.MkdirAll(*state, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(*state)
	if err != nil || !info.IsDir() || info.Mode()&0077 != 0 {
		return errors.New("tailnet state must be a private real directory")
	}
	owner, err := os.OpenFile(filepath.Join(*state, "owner.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer owner.Close()
	if err = unix.Flock(int(owner.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		return errors.New("a live sidecar owns this state")
	}
	defer unix.Flock(int(owner.Fd()), unix.LOCK_UN)
	socket := filepath.Join(*state, "control.sock")
	if existing, e := os.Lstat(socket); e == nil {
		if existing.Mode()&os.ModeSocket == 0 {
			return errors.New("unexpected non-socket control path")
		}
		if e = os.Remove(socket); e != nil {
			return e
		}
	}
	ln, err := net.Listen("unix", socket)
	if err != nil {
		return err
	}
	defer ln.Close()
	defer os.Remove(socket)
	os.Chmod(socket, 0600)
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	node := &tsnet.Server{Dir: filepath.Join(*state, "node"), Hostname: *name, UserLogf: func(string, ...any) {}, Logf: func(string, ...any) {}}
	if err = node.Start(); err != nil {
		return err
	}
	defer node.Close()
	lc, err := node.LocalClient()
	if err != nil {
		return err
	}
	b := &broker{node: node, local: lc, cancel: cancel}
	go func() { <-ctx.Done(); ln.Close() }()
	go func() {
		remote, e := node.Listen("tcp", ":8731")
		if e != nil {
			return
		}
		defer remote.Close()
		for {
			incoming, e := remote.Accept()
			if e != nil {
				return
			}
			go func() {
				defer incoming.Close()
				b.mu.Lock()
				addr := b.upstream
				b.mu.Unlock()
				if addr == "" {
					return
				}
				c, e := net.DialTimeout("tcp", addr, 3*time.Second)
				if e != nil {
					return
				}
				defer c.Close()
				go io.Copy(c, incoming)
				io.Copy(incoming, c)
			}()
		}
	}()
	fmt.Println(`{"version":1,"ready":true,"userspace":true}`)
	for {
		conn, e := ln.Accept()
		if e != nil {
			if ctx.Err() != nil {
				return nil
			}
			return e
		}
		go b.handle(ctx, conn)
	}
}
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
