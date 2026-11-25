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
	Version             int     `json:"version"`
	Operation           string  `json:"operation"`
	Target              string  `json:"target,omitempty"`
	RemoteApproved      bool    `json:"remote_approved,omitempty"`
	Purpose             string  `json:"purpose,omitempty"`
	NetworkHandle       string  `json:"network_handle,omitempty"`
	TimeoutMS           int     `json:"timeout_ms,omitempty"`
	Socks5Enabled       *bool   `json:"socks5_enabled,omitempty"`
	Socks5Port          int     `json:"socks5_port,omitempty"`
	ExitNodeID          *string `json:"exit_node_id,omitempty"`
	TailscaleSSHEnabled *bool   `json:"tailscale_ssh_enabled,omitempty"`
	OpenSSHEnabled      *bool   `json:"openssh_enabled,omitempty"`
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
	ID             string   `json:"id,omitempty"`
	Name           string   `json:"name"`
	DNSName        string   `json:"dns_name,omitempty"`
	IPs            []string `json:"ips"`
	Online         bool     `json:"online"`
	Tags           []string `json:"tags,omitempty"`
	ExitNodeOption bool     `json:"exit_node_option,omitempty"`
	Path           Path     `json:"path"`
}
type SSHSession struct {
	User    string `json:"user,omitempty"`
	Peer    string `json:"peer,omitempty"`
	Remote  string `json:"remote,omitempty"`
	RxBytes uint64 `json:"rx_bytes"`
	TxBytes uint64 `json:"tx_bytes"`
}

type ProxyDestination struct {
	Host    string `json:"host"`
	RxBytes uint64 `json:"rx_bytes"`
	TxBytes uint64 `json:"tx_bytes"`
}

type ProxyStats struct {
	RxBytes           uint64             `json:"rx_bytes"`
	TxBytes           uint64             `json:"tx_bytes"`
	Connections       uint64             `json:"connections"`
	Active            int                `json:"active_clients"`
	ClientPorts       []int              `json:"client_ports,omitempty"`
	Destinations      []ProxyDestination `json:"destinations,omitempty"`
	ActiveConnections []ProxyDestination `json:"active_connections,omitempty"`
}

type Response struct {
	Mode                string       `json:"mode,omitempty"`
	Version             int          `json:"version"`
	Error               string       `json:"error,omitempty"`
	State               string       `json:"state,omitempty"`
	Hostname            string       `json:"hostname,omitempty"`
	LoginURL            string       `json:"login_url,omitempty"`
	IPs                 []string     `json:"ips,omitempty"`
	Peers               []Peer       `json:"peers,omitempty"`
	Path                *Path        `json:"path,omitempty"`
	Userspace           bool         `json:"userspace"`
	NetworkHandle       string       `json:"network_handle,omitempty"`
	Socks5Enabled       bool         `json:"socks5_enabled,omitempty"`
	Socks5Addr          string       `json:"socks5_addr,omitempty"`
	ProxyStats          *ProxyStats  `json:"proxy_stats,omitempty"`
	ExitNodeID          string       `json:"exit_node_id,omitempty"`
	TailscaleSSHEnabled bool         `json:"tailscale_ssh_enabled"`
	OpenSSHEnabled      bool         `json:"openssh_enabled,omitempty"`
	ActiveSSHConns      int          `json:"active_ssh_conns"`
	SSHSessions         []SSHSession `json:"ssh_sessions,omitempty"`
}

var ErrNetworkBinding = errors.New("Tailscale stream network binding changed or is unsupported")

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
	if out.Version == 1 && req.Operation == "stream" && req.NetworkHandle != "" && out.NetworkHandle != req.NetworkHandle {
		conn.Close()
		return out, nil, ErrNetworkBinding
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
