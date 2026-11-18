package main

import (
	"context"
	"devicebridge/internal/transport/wireguard"
	"io"
	"net"
	"testing"
	"time"
)

func TestUserspaceWireGuardTunnelHandshakeAndTCPStream(t *testing.T) {
	privA, pubA, err := wireguard.GenerateKeyPair()
	if err != nil {
		t.Fatal(err)
	}
	privB, pubB, err := wireguard.GenerateKeyPair()
	if err != nil {
		t.Fatal(err)
	}
	portA, portB := 51921, 51922
	cfgA := wireguard.Config{
		Backend:       wireguard.BackendUserspace,
		PrivateKey:    privA,
		PublicKey:     pubA,
		LocalTunnelIP: "10.77.0.1/24",
		ListenPort:    portA,
		Peers: []wireguard.PeerConfig{{
			PeerID:         "nodeB",
			PublicKey:      pubB,
			TunnelIP:       "10.77.0.2",
			ServerEndpoint: "127.0.0.1:51922",
		}},
	}
	cfgB := wireguard.Config{
		Backend:       wireguard.BackendUserspace,
		PrivateKey:    privB,
		PublicKey:     pubB,
		LocalTunnelIP: "10.77.0.2/24",
		ListenPort:    portB,
		Peers: []wireguard.PeerConfig{{
			PeerID:         "nodeA",
			PublicKey:      pubA,
			TunnelIP:       "10.77.0.1",
			ServerEndpoint: "127.0.0.1:51921",
		}},
	}
	devA, netA, err := startUserspaceNode(cfgA)
	if err != nil {
		t.Fatal(err)
	}
	defer devA.Close()
	devB, netB, err := startUserspaceNode(cfgB)
	if err != nil {
		t.Fatal(err)
	}
	defer devB.Close()

	ln, err := netB.ListenTCP(&net.TCPAddr{Port: 8731})
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		_, _ = c.Write([]byte("wireguard-userspace-ok"))
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, err := netA.DialContext(ctx, "tcp", "10.77.0.2:8731")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	got, err := io.ReadAll(conn)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "wireguard-userspace-ok" {
		t.Fatalf("unexpected wireguard tunnel payload: %q", string(got))
	}
}
