package main

import (
	"context"
	"devicebridge/internal/auth"
	"devicebridge/internal/client"
	"devicebridge/internal/storage"
	"devicebridge/internal/tailnetipc"
	"devicebridge/internal/transport"
	"devicebridge/internal/transport/tailnet"
	"devicebridge/internal/transport/tailscaled"
	"devicebridge/protocol"
	"encoding/hex"
	"errors"
	"net"
	"net/netip"
	"sync"
	"time"
)

type tailnetPairMatch struct {
	Endpoint    string `json:"endpoint"`
	Name        string `json:"name"`
	TailnetName string `json:"tailnet_name,omitempty"`
}

func tailnetPairCommand(s *storage.Store, id *auth.Identity, state, socket, mode, endpoint string, args []string) error {
	if len(args) != 2 || (args[0] == "tailnet-pair" && endpoint == "") {
		return errors.New("tailnet-pair-match DEVICE_ID or --endpoint TAILNET_IP:8731 tailnet-pair DEVICE_ID")
	}
	peer := args[1]
	raw, err := hex.DecodeString(peer)
	if err != nil || len(raw) != 32 || peer == id.ID {
		return errors.New("expected a different DeviceBridge public-key fingerprint")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 14*time.Second)
	defer cancel()
	policy, err := s.NetworkPolicy(ctx, nil)
	if err != nil || !policy["network_tailnet"] {
		return errors.New("Tailscale is disabled in Networks")
	}
	p, err := openOverlay(ctx, state, socket, mode, true)
	if err != nil {
		return err
	}
	newClient := func(endpoint string) *client.Client {
		return client.New(id, s, p, transport.Candidate{DeviceID: peer, Endpoint: endpoint})
	}
	if args[0] == "tailnet-pair" {
		if existing, err := s.Peer(peer); err == nil && existing.Status == "revoked" {
			return storage.ErrDenied
		}
		cl := newClient(endpoint)
		defer cl.Close()
		var remote tailnetPairMatch
		if err := cl.JSON(ctx, "/v1/pair/tailnet", nil, &remote); err != nil {
			return err
		}
		var status protocol.PairStatus
		if err := cl.PostJSON(ctx, "/v1/pair/tailnet", map[string]string{"name": id.Name}, &status); err != nil {
			return err
		}
		if status.ID != id.ID || status.Status != "paired" {
			return errors.New("unexpected Tailscale pairing response")
		}
		if err := s.CompleteTailnetPair(ctx, peer, remote.Name); err != nil {
			return err
		}
		if err := s.RecordVerifiedEndpoint(peer, "tailnet", endpoint); err != nil {
			return err
		}
		return output(map[string]string{"id": peer, "status": status.Status})
	}
	var status tailnetipc.Response
	switch p := p.(type) {
	case *tailscaled.Provider:
		status, err = p.Status(ctx)
	case *tailnet.Provider:
		status, _, err = p.Control.Exchange(ctx, tailnetipc.Request{Operation: "status"})
	}
	targets := make(chan string, 128)
	seen := make(map[string]bool)
	tailnetNames := make(map[string]string)
	if endpoint != "" {
		targets <- endpoint
		seen[endpoint] = true
	}
	if err == nil {
		for _, node := range status.Peers {
			if !node.Online {
				continue
			}
			for _, address := range node.IPs {
				ip, err := netip.ParseAddr(address)
				if err != nil || !ip.Is4() {
					continue
				}
				target := net.JoinHostPort(ip.String(), "8731")
				if node.DNSName != "" {
					tailnetNames[target] = node.DNSName
				} else {
					tailnetNames[target] = node.Name
				}
				if !seen[target] && len(targets) < cap(targets) {
					targets <- target
					seen[target] = true
				}
			}
		}
	}
	close(targets)
	match := make(chan tailnetPairMatch, 1)
	var workers sync.WaitGroup
	for range min(8, len(targets)) {
		workers.Go(func() {
			for target := range targets {
				if ctx.Err() != nil {
					return
				}
				probe, stop := context.WithTimeout(ctx, 2*time.Second)
				cl := newClient(target)
				var result tailnetPairMatch
				err := cl.JSON(probe, "/v1/pair/tailnet", nil, &result)
				cl.Close()
				stop()
				if err == nil && result.Name != "" {
					result.Endpoint = target
					result.TailnetName = tailnetNames[target]
					select {
					case match <- result:
						cancel()
					default:
					}
					return
				}
			}
		})
	}
	workers.Wait()
	select {
	case result := <-match:
		return output(result)
	default:
		return output(nil)
	}
}
