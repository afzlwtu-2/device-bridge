package main

import (
	"context"
	"devicebridge/internal/auth"
	"devicebridge/internal/client"
	"devicebridge/internal/discovery"
	"devicebridge/internal/platform"
	"devicebridge/internal/storage"
	"devicebridge/internal/tailnetipc"
	"devicebridge/internal/transfer"
	"devicebridge/internal/transport"
	"devicebridge/internal/transport/direct"
	"devicebridge/internal/transport/tailnet"
	"devicebridge/internal/transport/tailscaled"
	"devicebridge/protocol"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
)

type command struct {
	state    *storage.Store
	identity *auth.Identity
	provider *direct.Provider
	endpoint string
	ctx      context.Context
	overlay  transport.Provider
}

func output(v any) error { return json.NewEncoder(os.Stdout).Encode(v) }
func (c *command) peer(name string) (storage.Peer, error) {
	peers, err := c.state.Peers()
	if err != nil {
		return storage.Peer{}, err
	}
	var found []storage.Peer
	for _, p := range peers {
		if p.ID == name || p.Name == name {
			found = append(found, p)
		}
	}
	if len(found) != 1 {
		return storage.Peer{}, errors.New("peer unknown or ambiguous; use the full device id")
	}
	if found[0].Status == "revoked" {
		return storage.Peer{}, storage.ErrDenied
	}
	return found[0], nil
}
func openOverlay(ctx context.Context, stateDir, controlSocket, tailnetMode string, remoteApproved bool) (transport.Provider, error) {
	socket := controlSocket
	if socket == "" {
		socket = filepath.Join(stateDir, "tailnet", "control.sock")
	}
	if runtime.GOOS != "android" && tailnetMode != "app" {
		sys := &tailscaled.Provider{RemoteApproved: remoteApproved}
		st, e := sys.Status(ctx)
		if e == nil && st.State == "Running" {
			return sys, nil
		} else if tailnetMode == "system" {
			return nil, errors.New("system Tailscale unavailable")
		}
	}
	return &tailnet.Provider{Control: tailnetipc.Client{Socket: socket}, RemoteApproved: remoteApproved}, nil
}

func (c *command) connect(id string, authenticate bool) (*client.Client, transport.Candidate, error) {
	if c.overlay != nil {
		if c.endpoint == "" {
			return nil, transport.Candidate{}, errors.New("select this device's verified tailnet endpoint first")
		}
		v, err := c.overlay.Probe(c.ctx, transport.Candidate{DeviceID: id, Endpoint: c.endpoint, Transport: c.overlay.ID()})
		if err != nil {
			return nil, v, err
		}
		cl := client.New(c.identity, c.state, c.overlay, v)
		if authenticate {
			var device protocol.Device
			if err = cl.JSON(c.ctx, "/v1/device", nil, &device); err != nil {
				cl.Close()
				return nil, v, err
			}
			if device.ID != id {
				cl.Close()
				return nil, v, errors.New("tailnet endpoint DeviceBridge key mismatch")
			}
		}
		return cl, v, nil
	}

	candidates := []transport.Candidate{}
	network := c.provider.Interface + ":" + c.provider.Address.String() + ":" + c.provider.Prefix.String()
	if authenticate && c.endpoint == "" {
		cached, err := c.state.CachedEndpoints(id, network)
		if err != nil {
			return nil, transport.Candidate{}, err
		}
		for _, ep := range cached {
			v := transport.Candidate{DeviceID: id, Endpoint: ep, Interface: c.provider.Interface, Transport: c.provider.ID(), Direct: true, Observed: time.Now(), Cost: c.provider.NetworkCost(transport.Candidate{})}
			cl := client.New(c.identity, c.state, c.provider, v)
			var device protocol.Device
			start := time.Now()
			err := cl.JSON(c.ctx, "/v1/device", nil, &device)
			if err == nil && device.ID == id && device.Version == 1 {
				v.RTT = time.Since(start)
				return cl, v, nil
			}
			cl.Close()
		}
	}
	if c.endpoint != "" {
		candidates = append(candidates, transport.Candidate{DeviceID: id, Endpoint: c.endpoint, Interface: c.provider.Interface, Transport: c.provider.ID(), Direct: true, Observed: time.Now(), Cost: c.provider.NetworkCost(transport.Candidate{})})
	} else {
		all, err := c.provider.DiscoverCandidates(c.ctx)
		if err != nil {
			return nil, transport.Candidate{}, err
		}
		for _, v := range all {
			if v.DeviceID == id {
				candidates = append(candidates, v)
			}
		}
	}
	var last error
	for _, v := range candidates {
		cl := client.New(c.identity, c.state, c.provider, v)
		if authenticate {
			var device protocol.Device
			start := time.Now()
			err := cl.JSON(c.ctx, "/v1/device", nil, &device)
			if err != nil {
				last = err
				cl.Close()
				continue
			}
			if device.ID != id || device.Version != 1 {
				last = errors.New("authenticated identity mismatch")
				cl.Close()
				continue
			}
			v.RTT = time.Since(start)
			if err = c.state.CacheEndpoint(id, network, v.Endpoint); err != nil {
				cl.Close()
				return nil, transport.Candidate{}, err
			}
		}
		return cl, v, nil
	}
	if last != nil {
		return nil, transport.Candidate{}, last
	}
	return nil, transport.Candidate{}, errors.New("device not discovered on the approved LAN; no relay fallback")
}
func run() error {
	if err := platform.BindApprovedNetwork(); err != nil {
		return err
	}
	state := flag.String("state", "", "private state directory (required)")
	iface := flag.String("interface", "wlan0", "approved unmetered LAN interface")
	cidr := flag.String("lan-cidr", "", "this device's approved local LAN IPv4/CIDR")
	endpoint := flag.String("endpoint", "", "diagnostic explicit endpoint (normal use discovers by identity)")
	transportID := flag.String("transport", "lan", "lan, adb, ssh, or explicitly selected tailnet")
	controlSocket := flag.String("tailnet-socket", "", "private app-only tsnet control socket")
	tailnetMode := flag.String("tailnet-mode", "auto", "auto prefers existing system tailscaled; app explicitly selects tsnet")
	remoteApproved := flag.Bool("approve-remote", false, "explicitly allow internet/relay data for this request")
	allowFallback := flag.Bool("allow-route-fallback", false, "allow approved alternate-route resume on disruption")
	flag.Parse()
	_ = *allowFallback
	a := flag.Args()
	if *state == "" || len(a) == 0 {
		return errors.New("usage: bridge-cli --state DIR [--interface wlan0 --lan-cidr LOCAL/24] init|identity|export|invite|peers|approve|revoke|discover|pair|finish|roots|list|stat|pull|resolve")
	}
	s, err := storage.Open(*state)
	if err != nil {
		return err
	}
	defer s.Close()
	name := ""
	if a[0] == "init" {
		if len(a) != 2 {
			return errors.New("init NAME")
		}
		name = a[1]
	}
	id, err := auth.Load(s, name)
	if err != nil {
		return err
	}
	switch a[0] {
	case "connection":
		if len(a) < 2 || len(a) > 5 {
			return errors.New("connection PEER_ID [-|lan|tailnet|adb|ssh ENDPOINT [allow-internet-and-relays]]")
		}
		var change *storage.Connection
		if len(a) > 2 {
			if a[2] == "-" {
				data, e := io.ReadAll(io.LimitReader(os.Stdin, 8192))
				if e != nil {
					return e
				}
				var parsed storage.Connection
				if e = json.Unmarshal(data, &parsed); e != nil {
					return e
				}
				change = &parsed
			} else {
				change = &storage.Connection{Transport: a[2]}
				if a[2] == "tailnet" {
					if len(a) != 5 || a[4] != "allow-internet-and-relays" {
						return errors.New("explicit internet/relay approval required")
					}
					change.Endpoint = a[3]
					change.RemoteApproved = true
				} else if a[2] == "adb" || a[2] == "ssh" {
					if len(a) < 4 {
						return errors.New("ADB/SSH connection requires 127.0.0.1:port")
					}
					change.Endpoint = a[3]
				}
			}
		}
		v, e := s.Connection(a[1], change)
		if e != nil {
			return e
		}
		return output(v)
	case "tailnet":
		if len(a) < 2 || len(a) > 3 {
			return errors.New("tailnet status|login|logout|probe|stop [TAILNET_IP]")
		}
		if runtime.GOOS != "android" && *tailnetMode != "app" {
			sys := &tailscaled.Provider{}
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			st, e := sys.Status(ctx)
			cancel()
			if e == nil {
				if a[1] != "status" {
					return errors.New("existing system Tailscale is managed externally; DeviceBridge only reads/probes it")
				}
				return output(st)
			}
			if *tailnetMode == "system" {
				return e
			}
		}
		socket := *controlSocket
		if socket == "" {
			socket = filepath.Join(*state, "tailnet", "control.sock")
		}
		target := ""
		if len(a) == 3 {
			target = a[2]
		}
		v, _, err := (tailnetipc.Client{Socket: socket}).Exchange(context.Background(), tailnetipc.Request{Operation: a[1], Target: target})
		if err != nil {
			return err
		}
		return output(v)
	case "theme":
		if len(a) > 2 {
			return errors.New("theme [system|light|dark|amoled|amoled-green|amoled-red|matte]")
		}
		value := ""
		if len(a) == 2 {
			value = a[1]
		}
		selected, e := s.Theme(value)
		if e != nil {
			return e
		}
		return output(map[string]string{"theme": selected})
	case "init", "identity":
		return output(protocol.Device{Version: 1, ID: id.ID, Name: id.Name, Features: []string{"remote-files-v1"}})
	case "networks":
		interfaces, e := net.Interfaces()
		if e != nil {
			return e
		}
		out := []map[string]string{}
		for _, i := range interfaces {
			if i.Flags&net.FlagUp == 0 || i.Flags&net.FlagLoopback != 0 {
				continue
			}
			addrs, e := i.Addrs()
			if e != nil {
				continue
			}
			for _, a := range addrs {
				ip, _, e := net.ParseCIDR(a.String())
				if e == nil && ip.To4() != nil && ip.IsPrivate() {
					out = append(out, map[string]string{"interface": i.Name, "cidr": a.String(), "metered": "unknown; explicit approval required"})
				}
			}
		}
		return output(out)
	case "export":
		if len(a) != 3 {
			return errors.New("export ROOT_ID DIRECTORY (restart agent to apply)")
		}
		if err = s.Export(a[1], a[2]); err != nil {
			return err
		}
		return output(map[string]string{"status": "export_registered", "root": a[1]})
	case "invite":
		inv, e := id.Invite(s)
		if e != nil {
			return e
		}
		return output(inv)
	case "peers":
		peers, e := s.Peers()
		if e != nil {
			return e
		}
		for i := range peers {
			peers[i].Addresses, e = s.EndpointRecords(peers[i].ID)
			if e != nil {
				return e
			}
		}
		return output(peers)
	case "approve":
		if len(a) < 2 || len(a) > 5 {
			return errors.New("approve FULL_DEVICE_ID [ROOT_IDS_COMMA_SEPARATED] [TTL=24h] [BYTE_QUOTA=10737418240]")
		}
		roots := []string{}
		if len(a) > 2 && a[2] != "" {
			roots = strings.Split(a[2], ",")
		}
		ttl := 24 * time.Hour
		if len(a) > 3 {
			ttl, err = time.ParseDuration(a[3])
			if err != nil {
				return err
			}
		}
		quota := int64(10 << 30)
		if len(a) > 4 {
			if _, err = fmt.Sscan(a[4], &quota); err != nil {
				return err
			}
		}
		if err = s.Approve(a[1], roots, ttl, quota); err != nil {
			return err
		}
		return output(map[string]string{"status": "approved", "id": a[1]})
	case "revoke":
		if len(a) != 2 {
			return errors.New("revoke FULL_DEVICE_ID")
		}
		if err = s.Revoke(a[1]); err != nil {
			return err
		}
		return output(map[string]string{"status": "revoked"})
	case "remove":
		if len(a) != 2 {
			return errors.New("remove FULL_DEVICE_ID")
		}
		if err = s.RemovePeer(a[1]); err != nil {
			return err
		}
		return output(map[string]string{"status": "removed"})
	}
	var p *direct.Provider
	switch *transportID {
	case "lan":
		p, err = direct.NewCIDR(*iface, *cidr)
		if err != nil {
			return err
		}
		p.Discovery = func(ctx context.Context) ([]transport.Candidate, error) { return discovery.Browse(ctx, p) }
	case "adb", "ssh":
		p, err = direct.NewCIDR("lo", "127.0.0.1/8")
		if err != nil {
			return err
		}
	case "tailnet":
	default:
		return errors.New("unsupported selected transport")
	}
	reg := &transport.Registry{}
	if p != nil {
		if err = reg.Register(p); err != nil {
			return err
		}
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	c := &command{state: s, identity: id, provider: p, endpoint: *endpoint, ctx: ctx}
	if *transportID == "tailnet" {
		c.overlay, err = openOverlay(ctx, *state, *controlSocket, *tailnetMode, *remoteApproved)
		if err != nil {
			return err
		}
		if err = reg.Register(c.overlay); err != nil {
			return err
		}
	}
	if a[0] == "discover" {
		if p == nil {
			return errors.New("LAN discovery requires a selected local network")
		}
		all, e := p.DiscoverCandidates(ctx)
		if e != nil {
			return e
		}
		return output(all)
	}
	if a[0] == "pair" {
		if len(a) != 2 {
			return errors.New("pair INVITATION_JSON_FILE (or - for stdin)")
		}
		var data []byte
		if a[1] == "-" {
			data, err = io.ReadAll(io.LimitReader(os.Stdin, 4096))
		} else {
			data, err = os.ReadFile(a[1])
		}
		if err != nil {
			return err
		}
		var inv protocol.Invitation
		if err = json.Unmarshal(data, &inv); err != nil {
			return err
		}
		cl, _, err := c.connect(inv.ID, false)
		if err != nil {
			return err
		}
		defer cl.Close()
		status, err := cl.RequestPair(ctx, inv, id.Name)
		if err != nil {
			return err
		}
		return output(status)
	}
	if len(a) < 2 {
		return errors.New("device name or full id required")
	}
	peer, err := c.peer(a[1])
	if err != nil {
		return err
	}
	if c.endpoint == "" && (*transportID == "adb" || *transportID == "ssh") {
		if savedConn, ce := s.Connection(peer.ID, nil); ce == nil {
			if *transportID == "adb" && savedConn.AdbEndpoint != "" {
				c.endpoint = savedConn.AdbEndpoint
			} else if *transportID == "ssh" && savedConn.SshEndpoint != "" {
				c.endpoint = savedConn.SshEndpoint
			} else if savedConn.Transport == *transportID && savedConn.Endpoint != "" {
				c.endpoint = savedConn.Endpoint
			}
		}
	}
	cl, candidate, err := c.connect(peer.ID, a[0] != "finish")
	if err != nil {
		return err
	}
	defer cl.Close()
	switch a[0] {
	case "finish":
		if err = cl.FinishPair(ctx); err != nil {
			return err
		}
		return output(map[string]string{"status": "paired", "id": peer.ID})
	case "resolve":
		if conn, e := s.Connection(peer.ID, nil); e == nil && conn.LastMiBPerSecond > 0 {
			candidate.MiBPerSecond = conn.LastMiBPerSecond
			candidate.BytesPerSecond = conn.LastMiBPerSecond * 1024 * 1024
		}
		return output(candidate)
	case "roots":
		var roots []protocol.Root
		if err = cl.JSON(ctx, "/v1/files/roots", nil, &roots); err != nil {
			return err
		}
		return output(roots)
	case "list", "stat":
		if len(a) < 3 || len(a) > 5 {
			return errors.New("list|stat PEER ROOT [RELATIVE_PATH] [PAGE]")
		}
		rel := "."
		if len(a) > 3 {
			rel = a[3]
		}
		q := url.Values{"root": {a[2]}, "path": {rel}}
		if len(a) > 4 {
			q.Set("page", a[4])
		}
		var v any
		if err = cl.JSON(ctx, "/v1/files/"+a[0], q, &v); err != nil {
			return err
		}
		return output(v)
	case "pull", "pull-tar":
		if len(a) != 5 {
			return errors.New("pull|pull-tar PEER ROOT RELATIVE_PATH DESTINATION (must not exist)")
		}
		var manifest protocol.Manifest
		if err = cl.JSON(ctx, "/v1/files/manifest", url.Values{"root": {a[2]}, "path": {a[3]}}, &manifest); err != nil {
			return err
		}
		emitProgress := func(v transfer.Progress) {
			if v.Transport == "" {
				v.Transport = *transportID
			}
			_ = json.NewEncoder(os.Stderr).Encode(v)
		}
		useTar := a[0] == "pull-tar" || transfer.ShouldUseTar(manifest)
		var receipt transfer.Receipt
		if useTar {
			stream, codec, e := cl.OpenTar(ctx, a[2], a[3], "adaptive")
			if e == nil {
				receipt, err = transfer.PullTar(ctx, stream, codec, peer.ID, manifest, a[4], emitProgress)
			} else if a[0] == "pull" && strings.Contains(e.Error(), "remote 404") {
				receipt, err = transfer.Pull(ctx, cl, peer.ID, manifest, a[4], emitProgress)
			} else {
				err = e
			}
		} else {
			receipt, err = transfer.Pull(ctx, cl, peer.ID, manifest, a[4], emitProgress)
		}
		usedTransport := candidate.Transport
		if err != nil && ctx.Err() == nil && !errors.Is(err, transfer.ErrNonRetriable) {
			if savedConn, ce := s.Connection(peer.ID, nil); ce == nil && savedConn.FallbackApproved {
				var alts []transfer.AlternateSource
				seenRoute := map[string]bool{*transportID: true}
				order := append([]string{}, savedConn.FallbackTransports...)
				if len(order) == 0 {
					order = []string{"lan", "adb", "ssh"}
					if savedConn.RemoteApproved && savedConn.Endpoint != "" {
						order = append(order, "tailnet")
					}
				}
				for _, routeName := range order {
					if seenRoute[routeName] {
						continue
					}
					seenRoute[routeName] = true
					switch routeName {
					case "lan":
						if *cidr == "" {
							continue
						}
						alts = append(alts, transfer.AlternateSource{
							Name: "lan",
							Open: func(actx context.Context) (transfer.Source, string, func(), error) {
								lp, e := direct.NewCIDR(*iface, *cidr)
								if e != nil {
									return nil, "", nil, e
								}
								lp.Discovery = func(dctx context.Context) ([]transport.Candidate, error) { return discovery.Browse(dctx, lp) }
								ac := &command{state: s, identity: id, provider: lp, ctx: actx}
								acl, cand, e := ac.connect(peer.ID, true)
								if e != nil {
									return nil, "", nil, e
								}
								return acl, cand.Endpoint, acl.Close, nil
							},
						})
					case "adb", "ssh":
						ep := savedConn.AdbEndpoint
						if routeName == "ssh" {
							ep = savedConn.SshEndpoint
						}
						if ep == "" && savedConn.Transport == routeName {
							ep = savedConn.Endpoint
						}
						if ep == "" {
							continue
						}
						rName, rEp := routeName, ep
						alts = append(alts, transfer.AlternateSource{
							Name: rName,
							Open: func(actx context.Context) (transfer.Source, string, func(), error) {
								lp, e := direct.NewCIDR("lo", "127.0.0.1/8")
								if e != nil {
									return nil, "", nil, e
								}
								ac := &command{state: s, identity: id, provider: lp, endpoint: rEp, ctx: actx}
								acl, cand, e := ac.connect(peer.ID, true)
								if e != nil {
									return nil, "", nil, e
								}
								return acl, cand.Endpoint, acl.Close, nil
							},
						})
					case "tailnet":
						if !savedConn.RemoteApproved || savedConn.Endpoint == "" {
							continue
						}
						tEp := savedConn.Endpoint
						alts = append(alts, transfer.AlternateSource{
							Name: "tailnet",
							Open: func(actx context.Context) (transfer.Source, string, func(), error) {
								ov, e := openOverlay(actx, *state, *controlSocket, *tailnetMode, true)
								if e != nil {
									return nil, "", nil, e
								}
								ac := &command{state: s, identity: id, overlay: ov, endpoint: tEp, ctx: actx}
								acl, cand, e := ac.connect(peer.ID, true)
								if e != nil {
									return nil, "", nil, e
								}
								return acl, cand.Endpoint, acl.Close, nil
							},
						})
					}
				}
				if len(alts) > 0 {
					var switched string
					receipt, switched, err = transfer.ResumePullOnAlternates(ctx, *transportID, alts, peer.ID, manifest, a[4], err, emitProgress, func(sw transfer.RouteSwitch) {
						_ = json.NewEncoder(os.Stderr).Encode(sw)
					})
					if err == nil {
						usedTransport = switched
					}
				}
			}
		}
		if err != nil {
			return err
		}
		receipt.Transport = usedTransport
		_ = s.RecordRate(peer.ID, usedTransport, receipt.MiBPerSecond)
		return output(receipt)
	default:
		return errors.New("unknown command")
	}
}
func main() {
	if err := run(); err != nil {
		_ = json.NewEncoder(os.Stderr).Encode(protocol.Error{Code: "command_failed", Message: err.Error()})
		os.Exit(1)
	}
}
