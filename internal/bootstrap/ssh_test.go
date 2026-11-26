package bootstrap

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"

	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"devicebridge/internal/auth"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/server"
	"devicebridge/internal/storage"
	"devicebridge/internal/tailnetipc"
	"devicebridge/protocol"

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

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	localStore, err := storage.Open(filepath.Join(t.TempDir(), "caller"))
	if err != nil {
		t.Fatal(err)
	}
	defer localStore.Close()
	remoteStore, err := storage.Open(filepath.Join(t.TempDir(), "target"))
	if err != nil {
		t.Fatal(err)
	}
	defer remoteStore.Close()
	localID, err := auth.Load(localStore, "caller")
	if err != nil {
		t.Fatal(err)
	}
	remoteID, err := auth.Load(remoteStore, "target")
	if err != nil {
		t.Fatal(err)
	}
	if err := localStore.TrustOutbound(remoteID.ID, remoteID.Name, "paired"); err != nil {
		t.Fatal(err)
	}
	if err := remoteStore.TrustOutbound(localID.ID, localID.Name, "paired"); err != nil {
		t.Fatal(err)
	}
	pairListener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer pairListener.Close()
	go func() { _ = server.New(remoteStore, remoteID, &filesproviders.Registry{}).Serve(ctx, pairListener) }()

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
							var request struct{ Command string }
							if r.Type == "exec" && ssh.Unmarshal(r.Payload, &request) == nil {
								cmd := request.Command
								mu.Lock()
								cmds = append(cmds, cmd)
								mu.Unlock()
								result := []byte("HOST=testbox\nHOME=/home/testuser\nHAS_AGENT=1\nHAS_CLI=1\n1: lo inet 127.0.0.1/8\n")
								if strings.HasSuffix(cmd, " identity") {
									result, _ = json.Marshal(protocol.Device{Version: 1, ID: remoteID.ID, Name: remoteID.Name})
								}
								_, _ = channel.Write(result)
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
	setup := Request{
		Host: "127.0.0.1", Port: addr.Port, User: "testuser", Password: "secret",
		ExpectedHostKey: probe.HostKeySHA256, BridgePort: pairListener.Addr().(*net.TCPAddr).Port,
		AutoPair: true, AllowSyncControl: true,
	}
	res, err = Bootstrap(ctx, localStore, localID, setup)
	if err != nil || res.PairedPeerID != remoteID.ID {
		t.Fatalf("existing-pair setup: %+v %v", res, err)
	}
	if err = remoteStore.Revoke(localID.ID); err != nil {
		t.Fatal(err)
	}
	if _, err = Bootstrap(ctx, localStore, localID, setup); err == nil {
		t.Fatal("setup accepted a revoked remote relationship")
	}
	_ = ln.Close()
	<-done
	mu.Lock()
	defer mu.Unlock()
	approvals := 0
	for _, command := range cmds {
		if strings.HasSuffix(command, " invite") || strings.Contains(command, " approve ") {
			t.Fatalf("setup attempted to re-pair: %s", command)
		}
		if strings.Contains(command, " sync-control-access ") {
			approvals++
		}
	}
	if approvals != 1 {
		t.Fatalf("wanted one sync grant for the verified pairing, got %d", approvals)
	}
	if len(cmds) < 3 {
		t.Fatalf("expected >=3 remote setup steps, got %d", len(cmds))
	}
}

func TestInspectHostAndRunCommandOverTsnetSocket(t *testing.T) {
	t.Parallel()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	expectedFP := hostKeyFingerprint(signer.PublicKey())

	cfg := &ssh.ServerConfig{
		PasswordCallback: func(c ssh.ConnMetadata, pass []byte) (*ssh.Permissions, error) {
			if c.User() == "afzl" && string(pass) == "pw" {
				return nil, nil
			}
			return nil, fmt.Errorf("denied")
		},
	}
	cfg.AddHostKey(signer)
	sshLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer sshLn.Close()
	sshPort := sshLn.Addr().(*net.TCPAddr).Port

	go func() {
		for {
			raw, err := sshLn.Accept()
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
							if r.Type == "exec" {
								_, _ = channel.Write([]byte("tsnet-ok\n"))
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

	stateDir := t.TempDir()
	tailnetDir := filepath.Join(stateDir, "tailnet")
	if err := os.MkdirAll(tailnetDir, 0700); err != nil {
		t.Fatal(err)
	}
	sockPath := filepath.Join(tailnetDir, "control.sock")
	unixLn, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatal(err)
	}
	defer unixLn.Close()

	go func() {
		for {
			c, err := unixLn.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				line, err := bufio.NewReader(conn).ReadBytes('\n')
				if err != nil {
					return
				}
				var req tailnetipc.Request
				if err := json.Unmarshal(line, &req); err != nil {
					return
				}
				switch req.Operation {
				case "status":
					_ = json.NewEncoder(conn).Encode(tailnetipc.Response{
						Version: 1,
						State:   "Running",
						IPs:     []string{"100.127.71.119"},
						Peers: []tailnetipc.Peer{
							{
								Name:    "probook-450-g9",
								DNSName: "probook-450-g9.tailnet.ts.net",
								IPs:     []string{"100.100.78.84"},
								Online:  true,
							},
						},
					})
				case "stream":
					expectedTarget := fmt.Sprintf("100.100.78.84:%d", sshPort)
					if !req.RemoteApproved || req.Purpose != "ssh" || req.Target != expectedTarget {
						_ = json.NewEncoder(conn).Encode(tailnetipc.Response{Version: 1, Error: "unexpected stream request"})
						return
					}
					upstream, err := net.Dial("tcp", sshLn.Addr().String())
					if err != nil {
						_ = json.NewEncoder(conn).Encode(tailnetipc.Response{Version: 1, Error: err.Error()})
						return
					}
					defer upstream.Close()
					_ = json.NewEncoder(conn).Encode(tailnetipc.Response{Version: 1, State: "Running"})
					done := make(chan struct{})
					go func() {
						_, _ = io.Copy(upstream, conn)
						close(done)
					}()
					_, _ = io.Copy(conn, upstream)
					<-done
				}
			}(c)
		}
	}()

	opts := TailnetOptions{StateDir: stateDir, Mode: "app"}
	for _, hostQuery := range []string{"probook", "probook-450-g9", "probook-450-g9.tailnet.ts.net", "100.100.78.84"} {
		probe, err := InspectHostWithOptions(context.Background(), hostQuery, sshPort, opts)
		if err != nil {
			t.Fatalf("InspectHostWithOptions(%q) failed: %v", hostQuery, err)
		}
		if !probe.ViaTailnet || probe.ResolvedHost != "100.100.78.84" || probe.HostKeySHA256 != expectedFP {
			t.Fatalf("unexpected probe for %q: %+v", hostQuery, probe)
		}
	}

	cmdRes, err := RunCommand(context.Background(), ExecRequest{
		Host:            "probook",
		Port:            sshPort,
		User:            "afzl",
		Password:        "pw",
		ExpectedHostKey: expectedFP,
		Command:         "echo tsnet-ok",
		Tailnet:         opts,
	})
	if err != nil || cmdRes.ExitCode != 0 || cmdRes.Stdout != "tsnet-ok" {
		t.Fatalf("RunCommand over tsnet failed: res=%+v err=%v", cmdRes, err)
	}

	if _, _, _, err := matchTailnetPeer("probook", []tailnetipc.Peer{
		{Name: "probook-450-g9", IPs: []string{"100.100.78.84"}, Online: true},
		{Name: "probook-g10", IPs: []string{"100.100.78.85"}, Online: true},
	}); err == nil {
		t.Fatal("expected ambiguous prefix error")
	}
}

func TestBootstrapUploadsBundledPlatformBinaries(t *testing.T) {
	t.Parallel()
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
			if c.User() == "afzl" && string(pass) == "secret" {
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

	var mu sync.Mutex
	uploaded := 0
	go func() {
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
								cmd := string(r.Payload[4:])
								if strings.Contains(cmd, "devicebridge/bin/") {
									_ = r.Reply(true, nil)
									buf, _ := io.ReadAll(channel)
									mu.Lock()
									if len(buf) > 0 {
										uploaded++
									}
									mu.Unlock()
									_, _ = channel.SendRequest("exit-status", false, []byte{0, 0, 0, 0})
									return
								}
								_, _ = channel.Write([]byte("HOST=probook\nHOME=/home/afzl\nTARGET_PLATFORM=Linux/x86_64\nHAS_AGENT=0\nHAS_CLI=0\n"))
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

	arts := t.TempDir()
	platDir := filepath.Join(arts, "linux-x86_64")
	if err := os.MkdirAll(platDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(platDir, "bridge-agent"), []byte("agent-elf"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(platDir, "bridge-cli"), []byte("cli-elf"), 0755); err != nil {
		t.Fatal(err)
	}

	addr := ln.Addr().(*net.TCPAddr)
	probe, err := InspectHost(context.Background(), "127.0.0.1", addr.Port)
	if err != nil {
		t.Fatal(err)
	}
	res, err := Bootstrap(context.Background(), nil, nil, Request{
		Host:            "127.0.0.1",
		Port:            addr.Port,
		User:            "afzl",
		Password:        "secret",
		ExpectedHostKey: probe.HostKeySHA256,
		LocalArtifacts:  arts,
		InstallSystemd:  true,
	})
	if err != nil {
		t.Fatalf("Bootstrap with bundled artifacts failed: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if !res.AgentInstalled || uploaded != 2 {
		t.Fatalf("expected 2 uploaded binaries, got uploaded=%d res=%+v", uploaded, res)
	}
}

func TestSSHAuthMethodsNormalizesCRLFAndPassphrase(t *testing.T) {
	t.Parallel()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalECPrivateKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der})
	crlfPem := strings.ReplaceAll(string(pemBytes), "\n", "\r\n")
	methods, err := sshAuthMethods("", crlfPem, "", false)
	if err != nil || len(methods) != 1 {
		t.Fatalf("expected CRLF PEM to parse cleanly, got methods=%d err=%v", len(methods), err)
	}
	encBlock, err := ssh.MarshalPrivateKeyWithPassphrase(priv, "", []byte("top-secret-pass"))
	if err != nil {
		t.Fatal(err)
	}
	encPem := string(pem.EncodeToMemory(encBlock))
	if _, err := sshAuthMethods("", encPem, "", false); err == nil {
		t.Fatal("expected encrypted PEM without passphrase to error")
	}
	methods, err = sshAuthMethods("", encPem, "top-secret-pass", false)
	if err != nil || len(methods) != 1 {
		t.Fatalf("expected passphrase-protected PEM to parse cleanly, got methods=%d err=%v", len(methods), err)
	}
	autoUnit := SystemdUnit("/bin/bridge-agent", "/state", "", "", 8731, false)
	if !strings.Contains(autoUnit, "--lan-cidr auto") {
		t.Fatalf("expected --lan-cidr auto in systemd unit:\n%s", autoUnit)
	}
	sysUnit := SystemdSystemUnit("/bin/bridge-agent", "/home/afzl/.local/share/devicebridge", "afzl", "/home/afzl", "wlan0", "auto", 8731, true)
	if !strings.Contains(sysUnit, "User=root") ||
		!strings.Contains(sysUnit, "Environment=HOME=/home/afzl") ||
		!strings.Contains(sysUnit, "Environment=ANDROID_USER_HOME=/home/afzl/.android") ||
		strings.Contains(sysUnit, "CapabilityBoundingSet=") ||
		!strings.Contains(sysUnit, "WantedBy=multi-user.target") {
		t.Fatalf("unexpected SystemdSystemUnit:\n%s", sysUnit)
	}
}

func TestDialTargetTCPHonorsSelectedTransports(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	if _, _, _, err := dialTargetTCP(ctx, TailnetOptions{SSHTransport: "wireguard", RemoteApproved: false}, "10.99.0.2", 22); err == nil || !strings.Contains(err.Error(), "WireGuard SSH requires route approval") {
		t.Fatalf("expected WireGuard approval error, got %v", err)
	}
	if _, _, _, err := dialTargetTCP(ctx, TailnetOptions{SSHTransport: "adb"}, "192.168.1.50", 22); err == nil || !strings.Contains(err.Error(), "loopback mapping") {
		t.Fatalf("expected ADB loopback enforcement error, got %v", err)
	}
	if _, _, _, err := dialTargetTCP(ctx, TailnetOptions{SSHTransport: "tailnet", RemoteApproved: true}, "192.168.1.50", 22); err == nil || !strings.Contains(err.Error(), "tailnet address") {
		t.Fatalf("expected tailnet IP check error, got %v", err)
	}
}
