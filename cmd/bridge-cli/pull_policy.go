package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"time"

	"devicebridge/internal/transfer"
	"devicebridge/internal/transport"
	"devicebridge/internal/transport/tailnet"
)

type pullPolicy struct{ snapshot string }

func (p pullPolicy) allowTailnet() (string, error) {
	var policy struct {
		Handle    string `json:"tailnet_handle"`
		Cost      string `json:"tailnet_cost"`
		AllowOnce bool   `json:"metered_approved"`
	}
	data, err := os.ReadFile(p.snapshot)
	if err != nil || json.Unmarshal(data, &policy) != nil || policy.Handle == "" {
		return "", transfer.ErrRouteChanged
	}
	switch policy.Cost {
	case "metered":
		if !policy.AllowOnce {
			return "", transfer.ErrMeteredPull
		}
	case "unmetered":
	default:
		return "", transfer.ErrRouteChanged
	}
	return policy.Handle, nil
}

func (p pullPolicy) bind(provider transport.Provider) error {
	if p.snapshot == "" {
		return nil
	}
	appNode, ok := provider.(*tailnet.Provider)
	if !ok {
		return errors.New("download requires the app-private Tailscale network")
	}
	appNode.PullNetwork = p.allowTailnet
	return nil
}

// guard checks policy while an overlay stream is active, including a metering
// change on the same Android network. New dials also pin the network handle at
// the sidecar, so a restart onto cellular cannot race the next download.
func (p pullPolicy) guard(parent context.Context) (context.Context, func(), error) {
	handle, err := p.allowTailnet()
	if err != nil {
		return nil, nil, err
	}
	ctx, cancel := context.WithCancelCause(parent)
	go func() {
		tick := time.NewTicker(250 * time.Millisecond)
		defer tick.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
				current, err := p.allowTailnet()
				if err != nil {
					cancel(err)
					return
				}
				if handle != current {
					cancel(transfer.ErrRouteChanged)
					return
				}
			}
		}
	}()
	return ctx, func() { cancel(nil) }, nil
}

func (p pullPolicy) wait(ctx context.Context, report func(transfer.RecoveryEvent)) error {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	tick := time.NewTicker(250 * time.Millisecond)
	defer tick.Stop()
	last := ""
	for {
		_, err := p.allowTailnet()
		if err == nil {
			if last != "" {
				report(transfer.RecoveryEvent{State: "resuming", Transport: "tailnet"})
			}
			return nil
		}
		state := "waiting"
		if errors.Is(err, transfer.ErrMeteredPull) {
			state = "metered"
		}
		if state != last {
			report(transfer.RecoveryEvent{State: state, Transport: "tailnet"})
			last = state
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-tick.C:
		}
	}
}
