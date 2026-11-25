package main

import (
	"context"
	"io"
	"net"
	"testing"
	"time"

	"golang.org/x/net/proxy"
	"tailscale.com/net/socks5"
)

func TestMonitoredProxyRelaysAndCountsTraffic(t *testing.T) {
	echo, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		conn, err := echo.Accept()
		if err == nil {
			defer conn.Close()
			io.Copy(conn, conn)
		}
	}()

	raw, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	monitored := newMonitoredProxy(raw)
	defer monitored.Close()
	server := &socks5.Server{
		Dialer: func(ctx context.Context, network, address string) (net.Conn, error) {
			return monitored.dial(ctx, network, address, (&net.Dialer{}).DialContext)
		},
	}
	go server.Serve(monitored)

	client, err := proxy.SOCKS5("tcp", raw.Addr().String(), nil, &net.Dialer{Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	conn, err := client.Dial("tcp", echo.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(time.Second))
	_, err = conn.Write([]byte("hello"))
	if err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, 5)
	if _, err := io.ReadFull(conn, reply); err != nil || string(reply) != "hello" {
		t.Fatalf("echo got %q, err %v", reply, err)
	}
	stats := monitored.snapshot()
	if stats.Active != 1 || stats.Connections != 1 || stats.RxBytes != 5 || stats.TxBytes != 5 {
		t.Fatalf("wrong proxy totals: %+v", stats)
	}
	if len(stats.ClientPorts) != 1 || len(stats.Destinations) != 1 ||
		stats.Destinations[0].Host != "127.0.0.1" || stats.Destinations[0].TxBytes != 5 {
		t.Fatalf("wrong proxy details: %+v", stats)
	}
	if err := monitored.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Read(reply); err != io.EOF {
		t.Fatalf("closing the listener left a client connected: %v", err)
	}
}
