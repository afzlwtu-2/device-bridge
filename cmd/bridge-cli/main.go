package main

import (
	"context"
	"devicebridge/internal/auth"
	"devicebridge/internal/client"
	"devicebridge/internal/discovery"
	"devicebridge/internal/storage"
	"devicebridge/internal/transfer"
	"devicebridge/internal/transport"
	"devicebridge/internal/transport/direct"
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
func (c *command) connect(id string, authenticate bool) (*client.Client, transport.Candidate, error) {
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
	state := flag.String("state", "", "private state directory (required)")
	iface := flag.String("interface", "wlan0", "approved unmetered LAN interface")
	cidr := flag.String("lan-cidr", "", "this device's approved local LAN IPv4/CIDR")
	endpoint := flag.String("endpoint", "", "diagnostic explicit endpoint (normal use discovers by identity)")
	flag.Parse()
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
	}
	p, err := direct.NewCIDR(*iface, *cidr)
	if err != nil {
		return err
	}
	p.Discovery = func(ctx context.Context) ([]transport.Candidate, error) { return discovery.Browse(ctx, p) }
	reg := &transport.Registry{}
	if err = reg.Register(p); err != nil {
		return err
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	c := &command{state: s, identity: id, provider: p, endpoint: *endpoint, ctx: ctx}
	if a[0] == "discover" {
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
	case "pull":
		if len(a) != 5 {
			return errors.New("pull PEER ROOT RELATIVE_PATH DESTINATION (must not exist)")
		}
		var manifest protocol.Manifest
		if err = cl.JSON(ctx, "/v1/files/manifest", url.Values{"root": {a[2]}, "path": {a[3]}}, &manifest); err != nil {
			return err
		}
		receipt, err := transfer.Pull(ctx, cl, peer.ID, manifest, a[4], func(v transfer.Progress) { _ = json.NewEncoder(os.Stderr).Encode(v) })
		if err != nil {
			return err
		}
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
