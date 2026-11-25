package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"time"

	"devicebridge/internal/client"
	"devicebridge/internal/discovery"
	"devicebridge/internal/files"
	"devicebridge/internal/platform"
	"devicebridge/internal/storage"
	"devicebridge/internal/tailnetipc"
	"devicebridge/internal/transfer"
	"devicebridge/internal/transport"
	"devicebridge/internal/transport/direct"
	"devicebridge/internal/transport/wireguard"
	"devicebridge/protocol"
)

type pullRoutes struct {
	stateDir, iface, cidr, controlSocket, tailnetMode, wgBackend string
	allowFallback, manualLAN, wgTunnelOnly                       bool
	policy                                                       pullPolicy
}

func (c *command) runPull(args []string, peer string, options pullRoutes) error {
	if len(args) < 5 {
		return errors.New("pull|pull-tar PEER ROOT RELATIVE_PATH DESTINATION (must not exist)")
	}
	excludes, err := files.ValidateExclusions(args[5:])
	if err != nil {
		return err
	}
	events := json.NewEncoder(os.Stderr)
	report := func(event transfer.RecoveryEvent) { _ = events.Encode(event) }
	initial := *c
	release := func() {}
	if c.selectedTransport == "tailnet" && options.policy.snapshot != "" {
		if err := options.policy.bind(initial.overlay); err != nil {
			return err
		}
		if err := options.policy.wait(c.ctx, report); err != nil {
			return err
		}
		initial.ctx, release, err = options.policy.guard(c.ctx)
		if err != nil {
			return err
		}
	}
	defer release()
	cl, candidate, err := initial.connect(peer, true)
	if err != nil {
		return err
	}
	defer cl.Close()
	var manifest protocol.Manifest
	q := url.Values{"root": {args[2]}, "path": {args[3]}, "exclude": excludes}
	if err := cl.JSON(initial.ctx, "/v1/files/manifest", q, &manifest); err != nil {
		return err
	}
	if !slices.Equal(manifest.Excludes, excludes) {
		return errors.New("remote device did not honor requested exclusions; update both devices")
	}
	return c.pull(initial.ctx, release, cl, candidate, peer, manifest, args[4], args[0] == "pull-tar", options)
}

func (c *command) pull(initial context.Context, release func(), cl *client.Client, candidate transport.Candidate, peer string, manifest protocol.Manifest, destination string, forceTar bool, options pullRoutes) error {
	events := json.NewEncoder(os.Stderr)
	var staged int64
	progress := func(p transfer.Progress) {
		staged = max(staged, p.VerifiedBytes)
		if p.Transport == "" {
			p.Transport = candidate.Transport
		}
		_ = events.Encode(p)
	}

	var receipt transfer.Receipt
	var err error
	_, stageErr := os.Lstat(destination + ".devicebridge-part")
	if errors.Is(stageErr, os.ErrNotExist) && (forceTar || transfer.ShouldUseTar(manifest)) {
		var useFileStream bool
		stream, codec, openErr := cl.OpenTar(initial, manifest.Root, manifest.Path, "adaptive", manifest.Excludes...)
		switch {
		case openErr == nil:
			receipt, err = transfer.PullTar(initial, stream, codec, peer, manifest, destination, progress)
		case !forceTar && strings.Contains(openErr.Error(), "remote 404"):
			useFileStream = true
		default:
			err = openErr
		}
		if useFileStream {
			receipt, err = transfer.Pull(initial, cl, peer, manifest, destination, progress)
		}
	} else {
		receipt, err = transfer.Pull(initial, cl, peer, manifest, destination, progress)
	}
	if (errors.Is(err, context.Canceled) || transfer.Interrupted(err)) && transfer.Interrupted(context.Cause(initial)) {
		err = context.Cause(initial)
	}
	if errors.Is(err, tailnetipc.ErrNetworkBinding) {
		err = transfer.ErrRouteChanged
	}
	release()

	usedTransport := candidate.Transport
	if transfer.Interrupted(err) {
		cl.Close()
		receipt, usedTransport, err = transfer.RecoverPull(c.ctx, c.pullRecoveryRoutes(options, peer, candidate.Endpoint), peer, manifest, destination, err, staged,
			progress, func(event transfer.RecoveryEvent) { _ = events.Encode(event) })
	}
	if err != nil {
		return err
	}
	receipt.Transport = usedTransport
	receipt.SourceXXH64 = files.ContentXXH64(manifest)
	_ = c.state.RecordRate(peer, usedTransport, receipt.MiBPerSecond)
	return output(receipt)
}

func (c *command) pullRecoveryRoutes(options pullRoutes, peer, originalEndpoint string) []transfer.Route {
	order := []string{c.selectedTransport}
	if options.allowFallback {
		for _, name := range []string{"lan", "tailnet", "wireguard"} {
			if name != c.selectedTransport && (name != "lan" || !options.manualLAN) {
				order = append(order, name)
			}
		}
	}
	routes := make([]transfer.Route, 0, len(order))
	for _, name := range order {
		route := transfer.Route{Name: name, Open: func(ctx context.Context) (transfer.Source, string, func(), error) {
			cl, endpoint, err := c.reconnectPull(ctx, options, peer, name, originalEndpoint)
			if err != nil {
				return nil, "", nil, err
			}
			return cl, endpoint, cl.Close, nil
		}}
		if name == "tailnet" && options.policy.snapshot != "" {
			route.Guard = options.policy.guard
		}
		routes = append(routes, route)
	}
	return routes
}

func (c *command) reconnectPull(ctx context.Context, options pullRoutes, peer, route, originalEndpoint string) (*client.Client, string, error) {
	saved, err := c.state.Connection(peer, nil)
	if errors.Is(err, storage.ErrDenied) {
		return nil, "", errors.Join(transfer.ErrNonRetriable, err)
	}
	if err != nil {
		return nil, "", err
	}
	same := route == c.selectedTransport
	if !same && !saved.FallbackApproved {
		return nil, "", errors.New("alternate route not approved")
	}

	next := &command{state: c.state, identity: c.identity, ctx: ctx, selectedTransport: route}
	switch route {
	case "lan":
		if !same && (saved.ActiveLink != "" || options.manualLAN) {
			return nil, "", errors.New("automatic LAN unavailable during a manual link")
		}
		next.provider, err = options.recoveryLAN()
		if err != nil {
			return nil, "", err
		}
		next.provider.Discovery = func(ctx context.Context) ([]transport.Candidate, error) {
			return discovery.Browse(ctx, next.provider)
		}
		next.skipCachedEndpoints = true
		// Try the last authenticated endpoint briefly, then rediscover by ID.
		// Preserve an explicit endpoint for manually selected links.
		target := saved.LanEndpoint
		if same {
			target = originalEndpoint
		}
		if target != "" && next.provider.Check(target) == nil {
			next.endpoint = target
			fast, cancel := context.WithTimeout(ctx, time.Second)
			next.ctx = fast
			cl, candidate, err := next.connect(peer, true)
			cancel()
			if err == nil {
				return cl, candidate.Endpoint, nil
			}
		}
		if same && c.endpoint != "" {
			return nil, "", errors.New("explicit LAN endpoint unavailable")
		}
		next.endpoint, next.ctx = "", ctx
	case "tailnet":
		next.endpoint = saved.TailnetEndpoint
		if same && next.endpoint == "" {
			next.endpoint = originalEndpoint
		}
		if !saved.RemoteApproved || next.endpoint == "" {
			return nil, "", errors.New("Tailscale bulk route not approved or configured")
		}
		if options.policy.snapshot != "" {
			if _, err := options.policy.allowTailnet(); err != nil {
				return nil, "", err
			}
		}
		next.overlay, err = openOverlay(ctx, options.stateDir, options.controlSocket, options.tailnetMode, true)
		if err != nil {
			return nil, "", err
		}
		if err = options.policy.bind(next.overlay); err != nil {
			return nil, "", err
		}
	case "wireguard":
		next.endpoint = saved.WireGuardEndpoint
		if same && next.endpoint == "" {
			next.endpoint = originalEndpoint
		}
		if !saved.RemoteApproved || next.endpoint == "" {
			return nil, "", errors.New("WireGuard bulk route not approved or configured")
		}
		next.overlay = &wireguard.Provider{
			StateDir: options.stateDir, Control: tailnetipc.Client{Socket: filepath.Join(options.stateDir, "wireguard", "control.sock")},
			RemoteApproved: true, BackendMode: options.wgBackend, TunnelOnly: !same || options.wgTunnelOnly,
		}
	case "adb", "ssh":
		next.provider, next.endpoint = c.provider, originalEndpoint
	}

	cl, candidate, err := next.connect(peer, true)
	return cl, candidate.Endpoint, err
}

func (options pullRoutes) recoveryLAN() (*direct.Provider, error) {
	if file := os.Getenv("DEVICEBRIDGE_PULL_LAN"); file != "" && !options.manualLAN {
		var route struct {
			Interface string `json:"interface"`
			CIDR      string `json:"cidr"`
			Handle    string `json:"network_handle"`
		}
		data, err := os.ReadFile(file)
		if err != nil || json.Unmarshal(data, &route) != nil || route.Handle == "" {
			return nil, errors.New("approved Wi-Fi is unavailable")
		}
		p, err := direct.NewCIDR(route.Interface, route.CIDR)
		if err != nil {
			return nil, err
		}
		if err = platform.RebindApprovedNetwork(route.Handle); err != nil {
			return nil, err
		}
		return p, nil
	}

	p, err := direct.NewCIDR(options.iface, options.cidr)
	if err != nil || runtime.GOOS != "linux" || options.manualLAN {
		return p, err
	}
	// On Linux the approved interface can get a new address on the same
	// subnet. Never infer approval for a different network from the name.
	iface, err := net.InterfaceByName(p.Interface)
	if err != nil {
		return nil, err
	}
	if iface.Flags&net.FlagUp == 0 {
		return nil, errors.New("approved LAN interface is down")
	}
	addrs, err := iface.Addrs()
	if err != nil {
		return nil, err
	}
	var replacement netip.Prefix
	for _, addr := range addrs {
		prefix, err := netip.ParsePrefix(addr.String())
		if err == nil && prefix.Masked() == p.Prefix {
			if prefix.Addr() == p.Address {
				return p, nil
			}
			replacement = prefix
		}
	}
	if !replacement.IsValid() {
		return nil, errors.New("approved LAN address is unavailable")
	}
	return direct.NewCIDR(p.Interface, replacement.String())
}
