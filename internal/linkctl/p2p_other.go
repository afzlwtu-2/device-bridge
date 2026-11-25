//go:build !linux && !android

package linkctl

import (
	"context"
	"errors"

	"devicebridge/protocol"
)

func canHostWifiDirect(string) bool { return false }
func CloseWifiDirect() bool         { return false }

func activeWifiDirect() (protocol.ConnectionPrepareResult, bool) {
	return protocol.ConnectionPrepareResult{}, false
}

func startWifiDirect(_ context.Context, req protocol.ConnectionPrepareRequest, _ func(string, string)) (protocol.ConnectionPrepareResult, error) {
	return protocol.ConnectionPrepareResult{Kind: req.Kind}, errors.New("Wi-Fi Direct hosting requires Linux")
}
