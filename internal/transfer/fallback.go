package transfer

import (
	"context"
	"devicebridge/protocol"
	"errors"
)

type RouteSwitch struct {
	RouteSwitched bool    `json:"route_switched"`
	From          string  `json:"from"`
	To            string  `json:"to"`
	Endpoint      string  `json:"endpoint"`
	MiBPerSecond  float64 `json:"mib_per_second"`
}

type AlternateSource struct {
	Name string
	Open func(context.Context) (Source, string, func(), error)
}

// ResumePullOnAlternates resumes an interrupted pull across explicitly approved
// alternate routes for the same authenticated peer without bypassing integrity
// or no-overwrite checks.
func ResumePullOnAlternates(
	ctx context.Context,
	fromRoute string,
	alternates []AlternateSource,
	peer string,
	m protocol.Manifest,
	destination string,
	initialErr error,
	progress func(Progress),
	onSwitch func(RouteSwitch),
) (Receipt, string, error) {
	if initialErr == nil || ctx.Err() != nil || errors.Is(initialErr, ErrNonRetriable) {
		return Receipt{}, fromRoute, initialErr
	}
	lastErr := initialErr
	current := fromRoute
	for _, alt := range alternates {
		if ctx.Err() != nil {
			return Receipt{}, current, ctx.Err()
		}
		src, ep, cleanup, err := alt.Open(ctx)
		if err != nil {
			lastErr = err
			continue
		}
		if onSwitch != nil {
			onSwitch(RouteSwitch{
				RouteSwitched: true,
				From:          current,
				To:            alt.Name,
				Endpoint:      ep,
			})
		}
		receipt, err := Pull(ctx, src, peer, m, destination, progress)
		if cleanup != nil {
			cleanup()
		}
		if err == nil {
			return receipt, alt.Name, nil
		}
		lastErr = err
		current = alt.Name
		if errors.Is(err, ErrNonRetriable) {
			return Receipt{}, current, err
		}
	}
	return Receipt{}, current, lastErr
}
