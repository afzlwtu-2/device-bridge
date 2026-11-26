package bootstrap

import (
	"bufio"
	"context"
	"devicebridge/internal/auth"
	"devicebridge/internal/storage"
	"devicebridge/internal/tailnetipc"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDiscoverSSHOverTsnetFiltersAlreadyPairedPeers(t *testing.T) {
	t.Parallel()
	sshLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer sshLn.Close()
	sshPort := sshLn.Addr().(*net.TCPAddr).Port

	go func() {
		for {
			c, err := sshLn.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				_, _ = conn.Write([]byte("SSH-2.0-OpenSSH_9.9\r\n"))
			}(c)
		}
	}()

	stateDir := filepath.Join(t.TempDir(), "state")
	s, err := storage.Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := auth.Load(s, "phone"); err != nil {
		t.Fatal(err)
	}

	pairedID := strings.Repeat("a", 64)
	if err := s.TrustOutbound(pairedID, "old-box", "paired"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Connection(pairedID, &storage.Connection{
		Transport:       "tailnet",
		Endpoint:        "100.100.78.99:8731",
		TailnetEndpoint: "100.100.78.99:8731",
		RemoteApproved:  true,
	}); err != nil {
		t.Fatal(err)
	}

	tailnetDir := filepath.Join(stateDir, "tailnet")
	if err := os.MkdirAll(tailnetDir, 0700); err != nil {
		t.Fatal(err)
	}
	unixLn, err := net.Listen("unix", filepath.Join(tailnetDir, "control.sock"))
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
						Peers: []tailnetipc.Peer{
							{Name: "old-box", IPs: []string{"100.100.78.99"}, Online: true},
							{Name: "probook", IPs: []string{"100.100.78.84"}, Online: true},
						},
					})
				case "stream":
					if !strings.HasPrefix(req.Target, "100.100.78.84:") {
						_ = json.NewEncoder(conn).Encode(tailnetipc.Response{Version: 1, Error: "unexpected target"})
						return
					}
					up, err := net.Dial("tcp", sshLn.Addr().String())
					if err != nil {
						_ = json.NewEncoder(conn).Encode(tailnetipc.Response{Version: 1, Error: err.Error()})
						return
					}
					defer up.Close()
					_ = json.NewEncoder(conn).Encode(tailnetipc.Response{Version: 1, State: "Running"})
					done := make(chan struct{})
					go func() { _, _ = io.Copy(up, conn); close(done) }()
					_, _ = io.Copy(conn, up)
					<-done
				}
			}(c)
		}
	}()

	results, err := DiscoverSSH(context.Background(), s, DiscoverRequest{
		Ports:   []int{sshPort},
		Tailnet: TailnetOptions{StateDir: stateDir, Mode: "app"},
	})
	if err != nil {
		t.Fatal(err)
	}
	var foundProbook bool
	for _, r := range results {
		if r.Source == "tailnet" {
			if r.Host == "old-box" {
				t.Fatalf("already-paired tailnet peer should be filtered from new tsnet devices: %+v", r)
			}
			if r.Host == "probook" && r.Port == sshPort && r.SSHEnabled && strings.HasPrefix(r.Banner, "SSH-2.0") {
				foundProbook = true
			}
		}
	}
	if !foundProbook {
		t.Fatalf("expected new tsnet device probook with SSH enabled, got %+v", results)
	}
}

func TestDiscoverSSHOverTsnetIncludesPairedWhenRequested(t *testing.T) {
	t.Parallel()
	sshLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer sshLn.Close()
	sshPort := sshLn.Addr().(*net.TCPAddr).Port

	go func() {
		for {
			c, err := sshLn.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				_, _ = conn.Write([]byte("SSH-2.0-Tailscale\r\n"))
			}(c)
		}
	}()

	stateDir := filepath.Join(t.TempDir(), "state")
	s, err := storage.Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := auth.Load(s, "phone"); err != nil {
		t.Fatal(err)
	}

	pairedID := strings.Repeat("a", 64)
	if err := s.TrustOutbound(pairedID, "old-box", "paired"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Connection(pairedID, &storage.Connection{
		Transport:       "tailnet",
		Endpoint:        "100.100.78.99:8731",
		TailnetEndpoint: "100.100.78.99:8731",
		RemoteApproved:  true,
	}); err != nil {
		t.Fatal(err)
	}

	tailnetDir := filepath.Join(stateDir, "tailnet")
	if err := os.MkdirAll(tailnetDir, 0700); err != nil {
		t.Fatal(err)
	}
	unixLn, err := net.Listen("unix", filepath.Join(tailnetDir, "control.sock"))
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
						Peers: []tailnetipc.Peer{
							{Name: "old-box", IPs: []string{"100.100.78.99"}, Online: true},
							{Name: "probook", IPs: []string{"100.100.78.84"}, Online: true},
						},
					})
				case "stream":
					up, err := net.Dial("tcp", sshLn.Addr().String())
					if err != nil {
						_ = json.NewEncoder(conn).Encode(tailnetipc.Response{Version: 1, Error: err.Error()})
						return
					}
					defer up.Close()
					_ = json.NewEncoder(conn).Encode(tailnetipc.Response{Version: 1, State: "Running"})
					done := make(chan struct{})
					go func() { _, _ = io.Copy(up, conn); close(done) }()
					_, _ = io.Copy(conn, up)
					<-done
				}
			}(c)
		}
	}()

	allTailnet, err := DiscoverSSH(context.Background(), s, DiscoverRequest{
		Ports:                []int{sshPort},
		TailnetOnly:          true,
		IncludePairedTailnet: true,
		Tailnet:              TailnetOptions{StateDir: stateDir, Mode: "app"},
	})
	if err != nil {
		t.Fatal(err)
	}
	var seenOldBox, seenNewProbook bool
	for _, r := range allTailnet {
		if r.Source == "tailnet" && r.Host == "old-box" && r.AlreadyPaired && r.SSHEnabled && r.TailscaleSSH {
			seenOldBox = true
		}
		if r.Source == "tailnet" && r.Host == "probook" && !r.AlreadyPaired && r.SSHEnabled && r.TailscaleSSH {
			seenNewProbook = true
		}
	}
	if !seenOldBox || !seenNewProbook {
		t.Fatalf("expected both paired and unpaired Tailscale SSH devices, got %+v", allTailnet)
	}
}

func TestDiscoverSSHDeduplicatesTailnetPeerPorts(t *testing.T) {
	t.Parallel()
	listenBanner := func(banner string) (net.Listener, int) {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		go func() {
			for {
				c, err := ln.Accept()
				if err != nil {
					return
				}
				go func(conn net.Conn) {
					defer conn.Close()
					_, _ = conn.Write([]byte(banner + "\r\n"))
				}(c)
			}
		}()
		return ln, ln.Addr().(*net.TCPAddr).Port
	}
	openLn, openPort := listenBanner("SSH-2.0-OpenSSH_9.9")
	defer openLn.Close()
	tsLn, tsPort := listenBanner("SSH-2.0-Tailscale")
	defer tsLn.Close()

	stateDir := filepath.Join(t.TempDir(), "state")
	s, err := storage.Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := auth.Load(s, "phone"); err != nil {
		t.Fatal(err)
	}
	tailnetDir := filepath.Join(stateDir, "tailnet")
	if err := os.MkdirAll(tailnetDir, 0700); err != nil {
		t.Fatal(err)
	}
	unixLn, err := net.Listen("unix", filepath.Join(tailnetDir, "control.sock"))
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
						Peers: []tailnetipc.Peer{
							{Name: "probook", IPs: []string{"100.100.78.84"}, Online: true},
						},
					})
				case "stream":
					addr := ""
					switch req.Target {
					case "100.100.78.84:" + strings.TrimSpace(strings.Split(openLn.Addr().String(), ":")[1]):
						addr = openLn.Addr().String()
					case "100.100.78.84:" + strings.TrimSpace(strings.Split(tsLn.Addr().String(), ":")[1]):
						addr = tsLn.Addr().String()
					default:
						_ = json.NewEncoder(conn).Encode(tailnetipc.Response{Version: 1, Error: "unexpected target"})
						return
					}
					up, err := net.Dial("tcp", addr)
					if err != nil {
						_ = json.NewEncoder(conn).Encode(tailnetipc.Response{Version: 1, Error: err.Error()})
						return
					}
					defer up.Close()
					_ = json.NewEncoder(conn).Encode(tailnetipc.Response{Version: 1, State: "Running"})
					done := make(chan struct{})
					go func() { _, _ = io.Copy(up, conn); close(done) }()
					_, _ = io.Copy(conn, up)
					<-done
				}
			}(c)
		}
	}()

	results, err := DiscoverSSH(context.Background(), s, DiscoverRequest{
		Ports:   []int{openPort, tsPort},
		Tailnet: TailnetOptions{StateDir: stateDir, Mode: "app"},
	})
	if err != nil {
		t.Fatal(err)
	}
	var tailnetEntries []DiscoveredTarget
	for _, r := range results {
		if r.Source == "tailnet" {
			tailnetEntries = append(tailnetEntries, r)
		}
	}
	if len(tailnetEntries) != 1 {
		t.Fatalf("expected 1 deduplicated tailnet entry for probook, got %d: %+v", len(tailnetEntries), tailnetEntries)
	}
	if tailnetEntries[0].Port != tsPort || !tailnetEntries[0].TailscaleSSH {
		t.Fatalf("expected Tailscale SSH port %d (TailscaleSSH=true), got %+v", tsPort, tailnetEntries[0])
	}
}
