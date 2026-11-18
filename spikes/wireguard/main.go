// App-only userspace WireGuard (wireguard-go + netstack) & kernel (rooted wg) coordinator sidecar.
// Never uses VpnService on Android; works on non-rooted (userspace) and rooted (kernel) devices,
// selecting direct same-LAN peer endpoints over server relays whenever reachable.
package main

import (
	"bufio"
	"context"
	"devicebridge/internal/platform"
	"devicebridge/internal/tailnetipc"
	"devicebridge/internal/transport/wireguard"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"golang.org/x/sys/unix"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
	"io"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

func b64ToHex(b64 string) (string, error) {
	b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil || len(b) != 32 {
		return "", errors.New("invalid 32-byte WireGuard key")
	}
	return hex.EncodeToString(b), nil
}

func resolveEndpoint(p wireguard.PeerConfig) (string, string) {
	// Prefer same-LAN direct peer endpoint before hopping through an external server/relay.
	if p.DirectLANEndpoint != "" {
		host, _, err := net.SplitHostPort(p.DirectLANEndpoint)
		if err == nil {
			// Check UDP/TCP local reachability on same LAN
			d := net.Dialer{Timeout: 300 * time.Millisecond}
			if c, e := d.Dial("tcp", p.DirectLANEndpoint); e == nil {
				_ = c.Close()
				return net.JoinHostPort(host, "51820"), "direct-lan"
			}
		}
	}
	if p.ServerEndpoint != "" {
		return p.ServerEndpoint, "wireguard-server"
	}
	return "", "unknown"
}

func buildUAPI(cfg wireguard.Config) (string, error) {
	privHex, err := b64ToHex(cfg.PrivateKey)
	if err != nil {
		return "", err
	}
	var sb strings.Builder
	fmt.Fprintf(&sb, "private_key=%s\n", privHex)
	if cfg.ListenPort > 0 {
		fmt.Fprintf(&sb, "listen_port=%d\n", cfg.ListenPort)
	}
	sb.WriteString("replace_peers=true\n")
	for _, p := range cfg.Peers {
		pubHex, err := b64ToHex(p.PublicKey)
		if err != nil {
			continue
		}
		fmt.Fprintf(&sb, "public_key=%s\n", pubHex)
		if p.TunnelIP != "" {
			allowed := p.TunnelIP
			if !strings.Contains(allowed, "/") {
				allowed += "/32"
			}
			fmt.Fprintf(&sb, "allowed_ip=%s\n", allowed)
		}
		if ep, _ := resolveEndpoint(p); ep != "" {
			fmt.Fprintf(&sb, "endpoint=%s\n", ep)
		}
		sb.WriteString("persistent_keepalive_interval=25\n")
	}
	return sb.String(), nil
}

type wgBroker struct {
	stateDir string
	cfg      wireguard.Config
	tnet     *netstack.Net
	dev      *device.Device
	backend  string
	mu       sync.Mutex
	upstream string
	cancel   context.CancelFunc
}

func (b *wgBroker) handle(ctx context.Context, c net.Conn) {
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(25 * time.Second))
	line, err := bufio.NewReader(io.LimitReader(c, 8192)).ReadBytes('\n')
	if err != nil {
		return
	}
	var req tailnetipc.Request
	res := tailnetipc.Response{Version: 1, Userspace: b.backend == wireguard.BackendUserspace}
	reply := func() { _ = json.NewEncoder(c).Encode(res) }
	if json.Unmarshal(line, &req) != nil || req.Version != 1 {
		res.Error = "unsupported control request"
		reply()
		return
	}
	switch req.Operation {
	case "status":
		res.State = "Running (" + b.backend + ")"
		res.IPs = []string{b.cfg.LocalTunnelIP}
		for _, p := range b.cfg.Peers {
			_, kind := resolveEndpoint(p)
			res.Peers = append(res.Peers, tailnetipc.Peer{
				Name:   p.Name,
				IPs:    []string{p.TunnelIP},
				Online: true,
				Path:   tailnetipc.Path{Kind: kind, Observed: time.Now().UTC()},
			})
		}
	case "probe", "stream":
		host, port, err := net.SplitHostPort(req.Target)
		if err != nil || port == "" {
			res.Error = "invalid target host:port"
			break
		}
		var matched *wireguard.PeerConfig
		for i := range b.cfg.Peers {
			if b.cfg.Peers[i].TunnelIP == host {
				matched = &b.cfg.Peers[i]
				break
			}
		}
		if matched == nil {
			res.Error = "WireGuard peer not configured"
			break
		}
		ep, kind := resolveEndpoint(*matched)
		res.Path = &tailnetipc.Path{Kind: kind, Endpoint: ep, Observed: time.Now().UTC()}
		if req.Operation == "stream" {
			if !req.RemoteApproved {
				res.Error = "explicit remote transfer approval required"
				break
			}
			callCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
			peer, err := b.tnet.DialContext(callCtx, "tcp", req.Target)
			cancel()
			if err != nil {
				res.Error = err.Error()
				break
			}
			defer peer.Close()
			reply()
			_ = c.SetDeadline(time.Time{})
			done := make(chan struct{})
			go func() {
				_, _ = io.Copy(peer, c)
				if cw, ok := peer.(interface{ CloseWrite() error }); ok {
					_ = cw.CloseWrite()
				}
				close(done)
			}()
			_, _ = io.Copy(c, peer)
			_ = c.Close()
			<-done
			return
		}
	case "upstream":
		b.mu.Lock()
		b.upstream = req.Target
		b.mu.Unlock()
	case "stop":
		b.cancel()
	default:
		res.Error = "unknown control operation"
	}
	reply()
}

func startUserspaceNode(cfg wireguard.Config) (*device.Device, *netstack.Net, error) {
	prefix, err := netip.ParsePrefix(cfg.LocalTunnelIP)
	if err != nil {
		return nil, nil, err
	}
	tunDev, tnet, err := netstack.CreateNetTUN([]netip.Addr{prefix.Addr()}, nil, 1420)
	if err != nil {
		return nil, nil, err
	}
	dev := device.NewDevice(tunDev, conn.NewDefaultBind(), device.NewLogger(device.LogLevelSilent, ""))
	uapi, err := buildUAPI(cfg)
	if err != nil {
		dev.Close()
		return nil, nil, err
	}
	if err = dev.IpcSet(uapi); err != nil {
		dev.Close()
		return nil, nil, err
	}
	if err = dev.Up(); err != nil {
		dev.Close()
		return nil, nil, err
	}
	return dev, tnet, nil
}

func run() error {
	state := flag.String("state", "", "DeviceBridge state directory")
	backendFlag := flag.String("backend", wireguard.BackendAuto, "auto | userspace | kernel")
	flag.Parse()
	if *state == "" {
		return errors.New("--state required")
	}
	if err := platform.BindApprovedNetwork(); err != nil {
		return err
	}
	cfg, err := wireguard.LoadOrInitConfig(*state, "", 0)
	if err != nil {
		return err
	}
	wgDir := filepath.Join(*state, "wireguard")
	owner, err := os.OpenFile(filepath.Join(wgDir, "owner.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer owner.Close()
	if err = unix.Flock(int(owner.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		return errors.New("WireGuard sidecar already running")
	}
	defer unix.Flock(int(owner.Fd()), unix.LOCK_UN)

	dev, tnet, err := startUserspaceNode(cfg)
	if err != nil {
		return err
	}
	defer dev.Close()

	sock := filepath.Join(wgDir, "control.sock")
	_ = os.Remove(sock)
	ln, err := net.Listen("unix", sock)
	if err != nil {
		return err
	}
	defer ln.Close()
	defer os.Remove(sock)
	_ = os.Chmod(sock, 0600)

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	b := &wgBroker{stateDir: *state, cfg: cfg, tnet: tnet, dev: dev, backend: wireguard.DetectBackend(*backendFlag), cancel: cancel}

	go func() {
		tunLn, e := tnet.ListenTCP(&net.TCPAddr{Port: 8731})
		if e != nil {
			return
		}
		defer tunLn.Close()
		for {
			inc, e := tunLn.Accept()
			if e != nil {
				return
			}
			go func() {
				defer inc.Close()
				b.mu.Lock()
				up := b.upstream
				b.mu.Unlock()
				if up == "" {
					return
				}
				c, e := net.DialTimeout("tcp", up, 3*time.Second)
				if e != nil {
					return
				}
				defer c.Close()
				go io.Copy(c, inc)
				io.Copy(inc, c)
			}()
		}
	}()

	go func() { <-ctx.Done(); _ = ln.Close() }()
	fmt.Printf(`{"version":1,"ready":true,"backend":%q,"public_key":%q,"tunnel_ip":%q}`+"\n", b.backend, cfg.PublicKey, cfg.LocalTunnelIP)
	for {
		c, e := ln.Accept()
		if e != nil {
			if ctx.Err() != nil {
				return nil
			}
			return e
		}
		go b.handle(ctx, c)
	}
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
