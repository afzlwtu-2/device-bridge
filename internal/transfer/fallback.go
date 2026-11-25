package transfer

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"syscall"
	"time"

	"devicebridge/protocol"
)

type RecoveryEvent struct {
	State     string `json:"transfer_state"`
	Transport string `json:"transport,omitempty"`
	Endpoint  string `json:"endpoint,omitempty"`
}

type Route struct {
	Name  string
	Open  func(context.Context) (Source, string, func(), error)
	Guard func(context.Context) (context.Context, func(), error)
}

var (
	ErrMeteredPull  = errors.New("this download needs permission to use mobile or metered data")
	ErrRouteChanged = errors.New("download network changed or is unavailable")
)

// Interrupted recognizes a broken stream. Authorization, integrity and
// destination errors must reach the caller without entering route recovery.
func Interrupted(err error) bool {
	if err == nil || errors.Is(err, ErrNonRetriable) || errors.Is(err, context.Canceled) {
		return false
	}
	var op *net.OpError
	return errors.As(err, &op) ||
		errors.Is(err, ErrMeteredPull) || errors.Is(err, ErrRouteChanged) ||
		errors.Is(err, context.DeadlineExceeded) ||
		errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) ||
		errors.Is(err, syscall.ECONNRESET) || errors.Is(err, syscall.EPIPE)
}

// RecoverPull keeps one destination and manifest while redialing authenticated
// routes. An interrupted tar attempt can continue via the ordinary file stream
// using the files and byte offsets already written to the same staging area.
func RecoverPull(
	ctx context.Context,
	routes []Route,
	peer string,
	m protocol.Manifest,
	destination string,
	initialErr error,
	committed int64,
	progress func(Progress),
	report func(RecoveryEvent),
) (Receipt, string, error) {
	return recoverPull(ctx, routes, peer, m, destination, initialErr, committed, progress, report, 2*time.Minute, time.Second)
}

func recoverPull(
	ctx context.Context, routes []Route, peer string, m protocol.Manifest, destination string,
	lastErr error, committed int64, progress func(Progress), report func(RecoveryEvent),
	waitBudget, initialDelay time.Duration,
) (Receipt, string, error) {
	if ctx.Err() != nil {
		return Receipt{}, "", ctx.Err()
	}
	if !Interrupted(lastErr) || len(routes) == 0 {
		return Receipt{}, "", lastErr
	}
	deadline := time.Now().Add(waitBudget)
	delay := initialDelay
	var lastEvent RecoveryEvent
	emit := func(event RecoveryEvent) {
		if event != lastEvent && report != nil {
			report(event)
		}
		lastEvent = event
	}
	emit(RecoveryEvent{State: "waiting"})
	for {
		var meteredRoute string
		for _, route := range routes {
			if ctx.Err() != nil {
				return Receipt{}, "", ctx.Err()
			}
			if time.Now().After(deadline) {
				break
			}
			probe, cancel := context.WithDeadline(ctx, minTime(deadline, time.Now().Add(6*time.Second)))
			src, endpoint, cleanup, err := route.Open(probe)
			cancel()
			if err != nil {
				if errors.Is(err, ErrMeteredPull) {
					meteredRoute = route.Name
				}
				if errors.Is(err, ErrNonRetriable) {
					return Receipt{}, "", err
				}
				continue
			}
			attempt, release := ctx, func() {}
			if route.Guard != nil {
				attempt, release, err = route.Guard(ctx)
				if err != nil {
					if errors.Is(err, ErrMeteredPull) {
						meteredRoute = route.Name
					}
					if cleanup != nil {
						cleanup()
					}
					continue
				}
			}
			emit(RecoveryEvent{State: "resuming", Transport: route.Name, Endpoint: endpoint})
			var highWater = committed
			receipt, err := Pull(attempt, src, peer, m, destination, func(p Progress) {
				highWater = max(highWater, p.VerifiedBytes)
				p.Transport = route.Name
				if progress != nil {
					progress(p)
				}
			})
			if cleanup != nil {
				cleanup()
			}
			if (errors.Is(err, context.Canceled) || Interrupted(err)) && Interrupted(context.Cause(attempt)) {
				err = context.Cause(attempt)
			}
			release()
			if ctx.Err() != nil {
				return Receipt{}, "", ctx.Err()
			}
			if err == nil || !Interrupted(err) {
				return receipt, route.Name, err
			}
			lastErr = err
			if highWater > committed {
				committed = highWater
				deadline = time.Now().Add(waitBudget)
				delay = initialDelay
			}
			if errors.Is(err, ErrMeteredPull) {
				meteredRoute = route.Name
			}
		}
		if meteredRoute != "" {
			emit(RecoveryEvent{State: "metered", Transport: meteredRoute})
			delay = min(delay, time.Second)
		} else {
			emit(RecoveryEvent{State: "waiting"})
		}
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return Receipt{}, "", fmt.Errorf("connection did not recover; partial download kept: %w", lastErr)
		}
		timer := time.NewTimer(min(remaining, delay))
		select {
		case <-ctx.Done():
			timer.Stop()
			return Receipt{}, "", ctx.Err()
		case <-timer.C:
		}
		delay = min(delay*2, 8*time.Second)
	}
}

func minTime(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}
