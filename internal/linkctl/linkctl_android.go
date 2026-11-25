//go:build android

package linkctl

import (
	"bytes"
	"context"
	"devicebridge/protocol"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

func DetectCapabilities(ctx context.Context) *protocol.DeviceCapabilities {
	if c := envCapabilities(); c != nil {
		return c
	}
	return &protocol.DeviceCapabilities{OS: "android"}
}

func WifiLinkDetails(ctx context.Context, _ string) *protocol.WifiLinkInfo {
	if c := envCapabilities(); c != nil && c.Link != nil {
		return c.Link
	}
	return nil
}

func callAndroidLinkctl(ctx context.Context, path string, body any) (protocol.ConnectionPrepareResult, error) {
	var res protocol.ConnectionPrepareResult
	ep := strings.TrimSpace(os.Getenv(EnvLinkctlEndpoint))
	tok := strings.TrimSpace(os.Getenv(EnvLinkctlToken))
	if ep == "" || tok == "" {
		return res, errors.New("Android direct-link controller is unavailable")
	}
	var r io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return res, err
		}
		r = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, "POST", ep+path, r)
	if err != nil {
		return res, err
	}
	req.Header.Set("X-DeviceBridge-Token", tok)
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 25 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return res, err
	}
	defer resp.Body.Close()
	if err := json.NewDecoder(io.LimitReader(resp.Body, 16384)).Decode(&res); err != nil {
		return res, err
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		if res.Message != "" {
			return res, errors.New(res.Message)
		}
		return res, fmt.Errorf("android linkctl HTTP %d", resp.StatusCode)
	}
	return res, nil
}

func Prepare(ctx context.Context, _ string, req protocol.ConnectionPrepareRequest, _ func(string, string)) (protocol.ConnectionPrepareResult, error) {
	return callAndroidLinkctl(ctx, "/prepare", req)
}

func JoinWifiNetwork(ctx context.Context, _ string, req protocol.ConnectionPrepareRequest, _ func(string, string)) (protocol.ConnectionPrepareResult, error) {
	req.Kind = "wifi_join"
	return callAndroidLinkctl(ctx, "/prepare", req)
}

func Restore(ctx context.Context, _ string) (protocol.ConnectionPrepareResult, error) {
	return callAndroidLinkctl(ctx, "/restore", map[string]any{})
}

func ActiveDirectLink(_ context.Context, _ string) map[string]any {
	return map[string]any{"active": false}
}

func CloseWifiDirect() bool { return false }
