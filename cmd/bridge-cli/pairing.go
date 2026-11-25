package main

import (
	"context"
	"devicebridge/internal/client"
	"devicebridge/internal/transport"
	"devicebridge/internal/transport/direct"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

func invitationLANEndpoint(state, iface, cidr string) string {
	for _, name := range []string{"agent-direct-status.json", "agent-status.json"} {
		raw, err := os.ReadFile(filepath.Join(state, name))
		if err != nil {
			continue
		}
		var status struct {
			Running   bool   `json:"running"`
			PID       int    `json:"pid"`
			Endpoint  string `json:"endpoint"`
			Interface string `json:"interface"`
			CIDR      string `json:"cidr"`
		}
		if json.Unmarshal(raw, &status) != nil || !status.Running || status.PID <= 0 {
			continue
		}
		listenerLAN, err := netip.ParsePrefix(status.CIDR)
		host, port, endpointErr := net.SplitHostPort(status.Endpoint)
		address, addressErr := netip.ParseAddr(host)
		if err != nil || endpointErr != nil || addressErr != nil ||
			!address.Is4() || !address.IsPrivate() || !listenerLAN.Contains(address) {
			continue
		}
		provider, err := direct.NewCIDR(status.Interface, netip.PrefixFrom(address, listenerLAN.Bits()).String())
		if err != nil || provider.Check(net.JoinHostPort(host, port)) != nil {
			continue
		}
		if cidr != "" {
			selected, err := netip.ParsePrefix(cidr)
			if err != nil || selected.Addr() != address || selected.Masked() != listenerLAN.Masked() || status.Interface != iface {
				continue
			}
		}
		if err := syscall.Kill(status.PID, 0); err == nil || errors.Is(err, syscall.EPERM) {
			return status.Endpoint
		}
	}
	return ""
}

func (c *command) withPairingRoute(id, lanHint string, exchange func(context.Context, *client.Client, transport.Candidate) error) error {
	ctx, cancel := context.WithTimeout(c.ctx, 15*time.Second)
	defer cancel()
	attempt := *c
	attempt.ctx = ctx

	connect := func() error {
		cl, v, err := attempt.connect(id, false)
		if err != nil {
			return err
		}
		defer cl.Close()
		return exchange(ctx, cl, v)
	}
	if c.selectedTransport == "lan" && c.endpoint == "" && lanHint != "" &&
		c.provider.Check(lanHint) == nil {
		attempt.endpoint = lanHint
		err := connect()
		var dialErr *net.OpError
		if err == nil || !errors.As(err, &dialErr) || dialErr.Op != "dial" {
			return err
		}
		// A closed or moved listener may advertise a new port. Retry only
		// after a dial failure, before the invitation could be consumed.
		attempt.endpoint = ""
		attempt.skipSavedLAN = true
	}
	return connect()
}
