// Package client uses an injected byte-stream transport, never feature-specific sockets.
package client

import (
	"bytes"
	"context"
	"devicebridge/internal/auth"
	"devicebridge/internal/storage"
	"devicebridge/internal/transport"
	"devicebridge/protocol"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/cespare/xxhash/v2"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"time"
)

type Client struct {
	HTTP             *http.Client
	StreamHTTP       *http.Client
	Endpoint, PeerID string
	Store            *storage.Store
}

func New(id *auth.Identity, s *storage.Store, p transport.Provider, c transport.Candidate) *Client {
	h := &http.Transport{Proxy: nil, TLSClientConfig: id.ClientTLS(c.DeviceID), ForceAttemptHTTP2: false, MaxIdleConnsPerHost: 2, IdleConnTimeout: 15 * time.Second, ResponseHeaderTimeout: 30 * time.Second, ExpectContinueTimeout: 2 * time.Second, DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
		if addr != c.Endpoint {
			return nil, errors.New("endpoint redirect denied")
		}
		return p.Dial(ctx, c)
	}}
	noRedirect := func(*http.Request, []*http.Request) error { return errors.New("redirect denied") }
	return &Client{
		HTTP:       &http.Client{Transport: h, Timeout: 3 * time.Minute, CheckRedirect: noRedirect},
		StreamHTTP: &http.Client{Transport: h, CheckRedirect: noRedirect},
		Endpoint:   c.Endpoint,
		PeerID:     c.DeviceID,
		Store:      s,
	}
}
func (c *Client) Close() { c.HTTP.CloseIdleConnections() }
func (c *Client) request(ctx context.Context, method, path string, query url.Values, body any) (*http.Response, error) {
	return c.doRequest(c.HTTP, ctx, method, path, query, body)
}
func (c *Client) doRequest(httpClient *http.Client, ctx context.Context, method, path string, query url.Values, body any) (*http.Response, error) {
	if path != "/v1/pair" && path != "/v1/pair/tailnet" {
		p, err := c.Store.Peer(c.PeerID)
		if err != nil || p.Status != "paired" {
			return nil, storage.ErrDenied
		}
	}
	var b io.Reader
	if body != nil {
		v, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		b = bytes.NewReader(v)
	}
	u := url.URL{Scheme: "https", Host: c.Endpoint, Path: path, RawQuery: query.Encode()}
	req, err := http.NewRequestWithContext(ctx, method, u.String(), b)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-DeviceBridge-Version", "1")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	res, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	return expectDeviceResponse(res)
}

func expectDeviceResponse(res *http.Response) (*http.Response, error) {
	if res.StatusCode < 200 || res.StatusCode > 299 {
		defer res.Body.Close()
		var e protocol.Error
		_ = json.NewDecoder(io.LimitReader(res.Body, 4096)).Decode(&e)
		if e.Message != "" && e.Message != e.Code {
			return nil, fmt.Errorf("remote %d: %s (%s)", res.StatusCode, e.Message, e.Code)
		}
		return nil, fmt.Errorf("remote %d: %s", res.StatusCode, e.Code)
	}
	if res.Header.Get("X-DeviceBridge-Version") != "1" {
		res.Body.Close()
		return nil, errors.New("unsupported response protocol")
	}
	return res, nil
}

func (c *Client) SendSharedFile(ctx context.Context, name, digest string, size int64, payload io.Reader, out any) error {
	query := url.Values{"name": {name}, "xxh64": {digest}}
	if size == 0 {
		payload = http.NoBody
	}
	return c.uploadShare(ctx, "/v1/share/file", query, size, payload, out)
}

func (c *Client) SendSharedFolder(ctx context.Context, name, codec string, payload io.Reader, out any) error {
	query := url.Values{"name": {name}, "codec": {codec}}
	return c.uploadShare(ctx, "/v1/share/folder", query, -1, payload, out)
}

func (c *Client) SendManagedTree(ctx context.Context, root, folder, name string, payload io.Reader, out any) error {
	query := url.Values{"root": {root}, "path": {folder}, "name": {name}}
	return c.uploadShare(ctx, "/v1/termux-files/upload", query, -1, payload, out)
}

func (c *Client) RemoveVerifiedTermuxFiles(ctx context.Context, request protocol.VerifiedRemoval) (map[string]bool, error) {
	res, err := c.doRequest(c.StreamHTTP, ctx, http.MethodPost, "/v1/termux-files/remove-verified", nil, request)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	var result map[string]bool
	err = json.NewDecoder(io.LimitReader(res.Body, 4096)).Decode(&result)
	return result, err
}

func (c *Client) uploadShare(ctx context.Context, path string, query url.Values, size int64, payload io.Reader, out any) error {
	if p, err := c.Store.Peer(c.PeerID); err != nil || p.Status != "paired" {
		return storage.ErrDenied
	}
	target := url.URL{Scheme: "https", Host: c.Endpoint, Path: path, RawQuery: query.Encode()}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target.String(), payload)
	if err != nil {
		return err
	}
	req.ContentLength = size
	req.Header.Set("X-DeviceBridge-Version", "1")
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Expect", "100-continue")
	res, err := c.StreamHTTP.Do(req)
	if err != nil {
		return err
	}
	res, err = expectDeviceResponse(res)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	return json.NewDecoder(io.LimitReader(res.Body, 4096)).Decode(out)
}
func (c *Client) JSON(ctx context.Context, path string, q url.Values, out any) error {
	res, err := c.request(ctx, "GET", path, q, nil)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	return json.NewDecoder(io.LimitReader(res.Body, 16<<20)).Decode(out)
}
func (c *Client) PostJSON(ctx context.Context, path string, reqBody, out any) error {
	res, err := c.request(ctx, "POST", path, nil, reqBody)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if out == nil {
		return nil
	}
	return json.NewDecoder(io.LimitReader(res.Body, 16<<20)).Decode(out)
}

type SpeedTestResult struct {
	Bytes        int64   `json:"bytes"`
	MiB          float64 `json:"mib"`
	Seconds      float64 `json:"seconds"`
	MiBPerSecond float64 `json:"mib_per_second"`
}

// SpeedTest streams data over the active mTLS route for `seconds` seconds and calculates MiB/s.
func (c *Client) SpeedTest(ctx context.Context, seconds int) (SpeedTestResult, error) {
	if seconds < 1 {
		seconds = 5
	}
	if seconds > 15 {
		seconds = 15
	}
	q := url.Values{"seconds": {strconv.Itoa(seconds)}}
	res, err := c.doRequest(c.StreamHTTP, ctx, "GET", "/v1/speedtest", q, nil)
	if err != nil {
		return SpeedTestResult{}, err
	}
	defer res.Body.Close()
	buf := make([]byte, 128<<10)
	start := time.Now()
	n, err := io.CopyBuffer(io.Discard, res.Body, buf)
	if err != nil {
		return SpeedTestResult{}, err
	}
	elapsed := time.Since(start).Seconds()
	if elapsed <= 0.001 {
		elapsed = float64(seconds)
	}
	mib := float64(n) / (1024 * 1024)
	return SpeedTestResult{
		Bytes:        n,
		MiB:          mib,
		Seconds:      elapsed,
		MiBPerSecond: mib / elapsed,
	}, nil
}
func (c *Client) RequestPair(ctx context.Context, inv protocol.Invitation, name string) (protocol.PairStatus, error) {
	var status protocol.PairStatus
	if inv.Version != 1 || inv.ID != c.PeerID || time.Now().After(inv.Expires) {
		return status, errors.New("invitation expired or invalid")
	}
	res, err := c.request(ctx, "POST", "/v1/pair", nil, protocol.PairRequest{Token: inv.Token, Name: name})
	if err != nil {
		return status, err
	}
	defer res.Body.Close()
	err = json.NewDecoder(io.LimitReader(res.Body, 4096)).Decode(&status)
	if err != nil {
		return status, err
	}
	if err = c.Store.TrustOutbound(inv.ID, inv.Name, "outbound"); err != nil {
		return status, err
	}
	return status, nil
}
func (c *Client) FinishPair(ctx context.Context) error {
	res, err := c.request(ctx, "GET", "/v1/pair", nil, nil)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	var v protocol.PairStatus
	if err = json.NewDecoder(io.LimitReader(res.Body, 4096)).Decode(&v); err != nil {
		return err
	}
	if v.Status != "paired" {
		return errors.New("remote approval still pending")
	}
	p, err := c.Store.Peer(c.PeerID)
	if err != nil {
		return err
	}
	return c.Store.TrustOutbound(c.PeerID, p.Name, "paired")
}
func (c *Client) ReadRange(ctx context.Context, root, path string, offset, length int64) ([]byte, error) {
	q := url.Values{"root": {root}, "path": {path}, "offset": {strconv.FormatInt(offset, 10)}, "length": {strconv.FormatInt(length, 10)}}
	res, err := c.request(ctx, "GET", "/v1/files/range", q, nil)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, length+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) != length {
		return nil, errors.New("range size mismatch; source changed")
	}
	hash := xxhash.New()
	hash.Write(data)
	if hex.EncodeToString(hash.Sum(nil)) != res.Header.Get("X-Chunk-XXH64") {
		return nil, errors.New("chunk checksum mismatch")
	}
	return data, nil
}
func (c *Client) OpenTar(ctx context.Context, root, path, codec string, excludes ...string) (io.ReadCloser, string, error) {
	if codec == "" {
		codec = "adaptive"
	}
	q := url.Values{"root": {root}, "path": {path}, "codec": {codec}}
	for _, excluded := range excludes {
		q.Add("exclude", excluded)
	}
	res, err := c.openDownload(ctx, "/v1/files/tar", q)
	if err != nil {
		return nil, "", err
	}
	actualCodec := res.Header.Get("X-Archive-Codec")
	if actualCodec == "" {
		actualCodec = "none"
	}
	return res.Body, actualCodec, nil
}
func (c *Client) OpenStream(ctx context.Context, root, path string, offset int64) (io.ReadCloser, error) {
	q := url.Values{"root": {root}, "path": {path}, "offset": {strconv.FormatInt(offset, 10)}}
	res, err := c.openDownload(ctx, "/v1/files/stream", q)
	if err != nil {
		return nil, err
	}
	return res.Body, nil
}
