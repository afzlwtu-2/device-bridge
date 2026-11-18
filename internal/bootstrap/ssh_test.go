package bootstrap

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"

	"golang.org/x/crypto/ssh"
)

func TestHostKeyMismatchRejectedAndSystemdUnitValid(t *testing.T) {
	t.Parallel()
	unit := SystemdUnit("/home/user/.local/share/devicebridge/bin/bridge-agent", "/home/user/.local/share/devicebridge", "wlan0", "10.0.0.2/24", 8731, true)
	if !strings.Contains(unit, "--system-tailnet") || !strings.Contains(unit, "Restart=on-failure") {
		t.Fatalf("unexpected systemd unit:\n%s", unit)
	}

	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	cfg := &ssh.ServerConfig{
		PasswordCallback: func(c ssh.ConnMetadata, pass []byte) (*ssh.Permissions, error) {
			if c.User() == "testuser" && string(pass) == "secret" {
				return nil, nil
			}
			return nil, fmt.Errorf("denied")
		},
	}
	cfg.AddHostKey(signer)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	var cmds []string
	var mu sync.Mutex
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			raw, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				_, chans, reqs, err := ssh.NewServerConn(c, cfg)
				if err != nil {
					return
				}
				go ssh.DiscardRequests(reqs)
				for ch := range chans {
					if ch.ChannelType() != "session" {
						_ = ch.Reject(ssh.UnknownChannelType, "unsupported")
						continue
					}
					channel, creqs, err := ch.Accept()
					if err != nil {
						continue
					}
					go func() {
						defer channel.Close()
						for r := range creqs {
							if r.Type == "exec" && len(r.Payload) >= 4 {
								l := int(r.Payload[3])
								cmd := string(r.Payload[4 : 4+l])
								mu.Lock()
								cmds = append(cmds, cmd)
								mu.Unlock()
								_, _ = channel.Write([]byte("HOST=testbox\nHOME=/home/testuser\nHAS_AGENT=1\nHAS_CLI=1\n"))
								_, _ = channel.SendRequest("exit-status", false, []byte{0, 0, 0, 0})
								_ = r.Reply(true, nil)
								return
							}
							_ = r.Reply(false, nil)
						}
					}()
				}
			}(raw)
		}
	}()

	addr := ln.Addr().(*net.TCPAddr)
	probe, err := InspectHost(context.Background(), "127.0.0.1", addr.Port)
	if err != nil || probe.HostKeySHA256 == "" {
		t.Fatalf("InspectHost failed: probe=%+v err=%v", probe, err)
	}
	if _, err = Bootstrap(context.Background(), nil, nil, Request{
		Host:            "127.0.0.1",
		Port:            addr.Port,
		User:            "testuser",
		Password:        "secret",
		ExpectedHostKey: "SHA256:wrong",
	}); err == nil {
		t.Fatal("mismatched host key accepted")
	}
	res, err := Bootstrap(context.Background(), nil, nil, Request{
		Host:            "127.0.0.1",
		Port:            addr.Port,
		User:            "testuser",
		Password:        "secret",
		ExpectedHostKey: probe.HostKeySHA256,
		InstallSystemd:  true,
		OpenFirewall:    true,
	})
	if err != nil {
		t.Fatalf("Bootstrap failed: %v", err)
	}
	if res.RemoteHostname != "testbox" || !res.AgentInstalled {
		t.Fatalf("unexpected bootstrap result: %+v", res)
	}
	cmdRes, err := RunCommand(context.Background(), ExecRequest{
		Host:            "127.0.0.1",
		Port:            addr.Port,
		User:            "testuser",
		Password:        "secret",
		ExpectedHostKey: probe.HostKeySHA256,
		Command:         "echo ok",
	})
	if err != nil || cmdRes.ExitCode != 0 || !strings.Contains(cmdRes.Stdout, "HOST=testbox") {
		t.Fatalf("RunCommand failed: res=%+v err=%v", cmdRes, err)
	}
	_ = ln.Close()
	<-done
	mu.Lock()
	defer mu.Unlock()
	if len(cmds) < 3 {
		t.Fatalf("expected >=3 remote setup steps, got %d", len(cmds))
	}
}
