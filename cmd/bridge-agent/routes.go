package main

import (
	"context"
	"devicebridge/internal/server"
	"devicebridge/internal/tailnetipc"
	"devicebridge/internal/transport/tailscaled"
	"encoding/json"
	"net"
	"net/netip"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

func wireGuardAddresses(ctx context.Context) []netip.Addr {
	query, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	raw, err := exec.CommandContext(query, "ip", "-j", "address", "show", "type", "wireguard").Output()
	if err != nil {
		return nil
	}
	var links []struct {
		Addresses []struct {
			Local netip.Addr `json:"local"`
		} `json:"addr_info"`
	}
	if json.Unmarshal(raw, &links) != nil {
		return nil
	}
	var addresses []netip.Addr
	for _, link := range links {
		for _, addr := range link.Addresses {
			if privateOverlayAddress(addr.Local) {
				addresses = append(addresses, addr.Local)
			}
		}
	}
	return addresses
}

func privateOverlayAddress(ip netip.Addr) bool {
	return ip.IsPrivate() || netip.MustParsePrefix("100.64.0.0/10").Contains(ip)
}

// Sidecars announce only their application listener address to already paired peers.
func sidecarRoute(ctx context.Context, state, role string) string {
	query, cancel := context.WithTimeout(ctx, 350*time.Millisecond)
	defer cancel()
	control := tailnetipc.Client{Socket: filepath.Join(state, role, "control.sock")}
	status, _, err := control.Exchange(query, tailnetipc.Request{Operation: "status"})
	if err != nil || !strings.HasPrefix(status.State, "Running") {
		return ""
	}
	for _, raw := range status.IPs {
		ip, err := netip.ParseAddr(raw)
		if err != nil {
			prefix, err := netip.ParsePrefix(raw)
			if err != nil {
				continue
			}
			ip = prefix.Addr()
		}
		if ip.Is4() && privateOverlayAddress(ip) {
			return net.JoinHostPort(ip.String(), "8731")
		}
	}
	return ""
}

type overlayBinding struct {
	transport string
	listener  net.Listener
}

type overlayListeners struct {
	mu          sync.Mutex
	port        string
	useTailnet  bool
	lastRefresh time.Time
	bindings    map[string]overlayBinding
}

func newOverlayListeners(port int, useTailnet bool) *overlayListeners {
	return &overlayListeners{
		port:       strconv.Itoa(port),
		useTailnet: useTailnet,
		bindings:   make(map[string]overlayBinding),
	}
}

func (r *overlayListeners) refresh(ctx context.Context, primary string, serve func(net.Listener, server.TailnetTagSource)) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if time.Since(r.lastRefresh) < 8*time.Second {
		return
	}
	r.lastRefresh = time.Now()
	wanted := make(map[string]string)
	if r.useTailnet {
		query, stop := context.WithTimeout(ctx, 500*time.Millisecond)
		status, err := (&tailscaled.Provider{}).Status(query)
		stop()
		if err == nil && status.State == "Running" {
			for _, raw := range status.IPs {
				if ip, err := netip.ParseAddr(raw); err == nil && ip.Is4() {
					wanted[net.JoinHostPort(ip.String(), r.port)] = "tailnet"
					break
				}
			}
		}
	}
	for _, ip := range wireGuardAddresses(ctx) {
		wanted[net.JoinHostPort(ip.String(), r.port)] = "wireguard"
	}
	for address, bound := range r.bindings {
		transport, exists := wanted[address]
		if !exists || (bound.listener == nil) != (address == primary) || bound.transport != transport {
			if bound.listener != nil {
				_ = bound.listener.Close()
			}
			delete(r.bindings, address)
		}
	}
	for address, transport := range wanted {
		if _, exists := r.bindings[address]; exists {
			continue
		}
		bound := overlayBinding{transport: transport}
		if address != primary {
			var ln net.Listener
			var source server.TailnetTagSource
			var err error
			if transport == "tailnet" {
				ln, source, err = systemTailnetListener(ctx, address)
			} else {
				ln, err = net.Listen("tcp", address)
			}
			if err != nil {
				continue
			}
			bound.listener = ln
			serve(ln, source)
		}
		r.bindings[address] = bound
	}
}

func (r *overlayListeners) endpoints() (tailnet string, wireguard []string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for address, bound := range r.bindings {
		if bound.transport == "tailnet" {
			tailnet = address
		} else {
			wireguard = append(wireguard, address)
		}
	}
	slices.Sort(wireguard)
	return
}

func (r *overlayListeners) close() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for address, bound := range r.bindings {
		if bound.listener != nil {
			_ = bound.listener.Close()
		}
		delete(r.bindings, address)
	}
}
