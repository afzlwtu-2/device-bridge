package syncthing

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"slices"
	"time"
)

type restClient struct {
	http *http.Client
	key  string
}

func newREST(socket, key string) *restClient {
	dialer := &net.Dialer{Timeout: time.Second}
	return &restClient{
		http: &http.Client{
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
					return dialer.DialContext(ctx, "unix", socket)
				},
			},
			Timeout: 3 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
		key: key,
	}
}

func (c *restClient) call(ctx context.Context, method, path string, body, result any) error {
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, "http://localhost"+path, reader)
	if err != nil {
		return err
	}
	req.Header.Set("X-API-Key", c.key)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	res, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return fmt.Errorf("Syncthing API %s returned HTTP %d", req.URL.Path, res.StatusCode)
	}
	if result != nil {
		return json.NewDecoder(io.LimitReader(res.Body, 4<<20)).Decode(result)
	}
	_, err = io.Copy(io.Discard, io.LimitReader(res.Body, 4096))
	return err
}

func (c *restClient) awaitReady(ctx context.Context, exited <-chan struct{}, listen string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	var status struct {
		ID string `json:"myID"`
	}
	for {
		if err := c.call(ctx, http.MethodGet, "/rest/system/status", nil, &status); err == nil {
			if !devicePattern.MatchString(status.ID) {
				return "", errors.New("Syncthing returned an invalid device ID")
			}
			return status.ID, c.checkPolicy(ctx, listen)
		}
		select {
		case <-ctx.Done():
			return "", errors.New("the private Syncthing REST API did not become ready")
		case <-exited:
			return "", errors.New("the managed Syncthing process exited during startup")
		case <-tick.C:
		}
	}
}

func (c *restClient) checkPolicy(ctx context.Context, listen string) error {
	var options struct {
		Listen        []string `json:"listenAddresses"`
		Global        *bool    `json:"globalAnnounceEnabled"`
		Local         *bool    `json:"localAnnounceEnabled"`
		Relays        *bool    `json:"relaysEnabled"`
		NAT           *bool    `json:"natEnabled"`
		CrashReports  *bool    `json:"crashReportingEnabled"`
		AnnounceLAN   *bool    `json:"announceLANAddresses"`
		STUNInterval  *int     `json:"stunKeepaliveStartS"`
		UpgradeHours  *int     `json:"autoUpgradeIntervalH"`
		UsageAccepted *int     `json:"urAccepted"`
	}
	if err := c.call(ctx, http.MethodGet, "/rest/config/options", nil, &options); err != nil {
		return err
	}
	for _, option := range []*bool{options.Global, options.Local, options.Relays, options.NAT, options.CrashReports, options.AnnounceLAN} {
		if option == nil || *option {
			return errors.New("the managed Syncthing daemon could not prove its direct-only policy")
		}
	}
	if !slices.Equal(options.Listen, []string{listen}) ||
		options.STUNInterval == nil || *options.STUNInterval != 0 ||
		options.UpgradeHours == nil || *options.UpgradeHours != 0 ||
		options.UsageAccepted == nil || *options.UsageAccepted != -1 {
		return errors.New("the managed Syncthing daemon could not prove its listener and reporting policy")
	}
	return nil
}
