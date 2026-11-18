// Package tailnetipc defines the private, versioned app-local tsnet sidecar API.
// The Unix socket and node state live under a 0700 directory, never a LAN port.
package tailnetipc

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"time"
)

type Request struct {
	Version        int    `json:"version"`
	Operation      string `json:"operation"`
	Target         string `json:"target,omitempty"`
	RemoteApproved bool   `json:"remote_approved,omitempty"`
}
type Path struct {
	Kind         string    `json:"kind"`
	Endpoint     string    `json:"endpoint,omitempty"`
	Relay        string    `json:"relay,omitempty"`
	RTTSeconds   float64   `json:"rtt_seconds"`
	Observed     time.Time `json:"observed"`
	TxBytes      int64     `json:"tx_bytes"`
	RxBytes      int64     `json:"rx_bytes"`
	MiBPerSecond float64   `json:"mib_per_second"`
}
type Peer struct {
	Name   string   `json:"name"`
	IPs    []string `json:"ips"`
	Online bool     `json:"online"`
	Path   Path     `json:"path"`
}
type Response struct {
	Mode      string   `json:"mode,omitempty"`
	Version   int      `json:"version"`
	Error     string   `json:"error,omitempty"`
	State     string   `json:"state,omitempty"`
	LoginURL  string   `json:"login_url,omitempty"`
	IPs       []string `json:"ips,omitempty"`
	Peers     []Peer   `json:"peers,omitempty"`
	Path      *Path    `json:"path,omitempty"`
	Userspace bool     `json:"userspace"`
}
type Client struct{ Socket string }
type bufferedConn struct {
	net.Conn
	reader *bufio.Reader
}

func (c *bufferedConn) Read(p []byte) (int, error) { return c.reader.Read(p) }
func (c Client) Exchange(ctx context.Context, req Request) (Response, net.Conn, error) {
	var out Response
	d := net.Dialer{Timeout: 3 * time.Second}
	conn, err := d.DialContext(ctx, "unix", c.Socket)
	if err != nil {
		return out, nil, errors.New("app-only Tailscale is not running")
	}
	deadline := time.Now().Add(20 * time.Second)
	if v, ok := ctx.Deadline(); ok && v.Before(deadline) {
		deadline = v
	}
	_ = conn.SetDeadline(deadline)
	req.Version = 1
	if err = json.NewEncoder(conn).Encode(req); err != nil {
		conn.Close()
		return out, nil, err
	}
	reader := bufio.NewReaderSize(conn, 16<<10)
	line, err := reader.ReadBytes('\n')
	if err != nil || len(line) > 2<<20 {
		conn.Close()
		return out, nil, errors.New("invalid tailnet control response")
	}
	if err = json.Unmarshal(line, &out); err != nil {
		conn.Close()
		return out, nil, err
	}
	if out.Version != 1 || out.Error != "" {
		conn.Close()
		return out, nil, errors.New("tailnet: " + out.Error)
	}
	if req.Operation == "stream" {
		_ = conn.SetDeadline(time.Time{})
		return out, &bufferedConn{Conn: conn, reader: reader}, nil
	}
	conn.Close()
	return out, nil, nil
}

var _ io.Reader = (*bufferedConn)(nil)
