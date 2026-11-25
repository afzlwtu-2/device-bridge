package server_test

import (
	"context"
	"devicebridge/internal/auth"
	"devicebridge/internal/client"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/server"
	"devicebridge/internal/storage"
	"devicebridge/internal/transport"
	"devicebridge/internal/transport/direct"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

func TestAgentSSHMTLSStream(t *testing.T) {
	srvDir := filepath.Join(t.TempDir(), "state")
	srvStore, err := storage.Open(srvDir)
	if err != nil {
		t.Fatal(err)
	}
	defer srvStore.Close()
	srvID, err := auth.Load(srvStore, "server")
	if err != nil {
		t.Fatal(err)
	}

	cliDir := filepath.Join(t.TempDir(), "state")
	cliStore, err := storage.Open(cliDir)
	if err != nil {
		t.Fatal(err)
	}
	defer cliStore.Close()
	cliID, err := auth.Load(cliStore, "client")
	if err != nil {
		t.Fatal(err)
	}

	srv := server.New(srvStore, srvID, &filesproviders.Registry{})
	srv.StateDir = srvDir

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = srv.Serve(ctx, ln) }()

	prov, err := direct.NewCIDR("lo", "127.0.0.1/8")
	if err != nil {
		t.Fatal(err)
	}
	cand := transport.Candidate{DeviceID: srvID.ID, Endpoint: ln.Addr().String(), Interface: "lo", Transport: "lan", Direct: true}
	if _, err := cliStore.DB.Exec(`INSERT INTO peers(id,name,status,expires) VALUES(?,?,?,0)`, srvID.ID, "server", "paired"); err != nil {
		t.Fatal(err)
	}

	// Unpaired peer on server must be rejected with 403.
	if _, err := client.DialAgentSSH(ctx, cliID, cliStore, prov, cand); err == nil || !strings.Contains(err.Error(), "403") {
		t.Fatalf("expected 403 for unpaired peer, got %v", err)
	}

	// Pair client on server, then verify upgrade check & SSH command execution.
	if _, err := srvStore.DB.Exec(`INSERT INTO peers(id,name,status,expires) VALUES(?,?,?,0)`, cliID.ID, "client", "paired"); err != nil {
		t.Fatal(err)
	}

	// Missing Upgrade header must return 426.
	httpClient := &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: cliID.ClientTLS(srvID.ID),
		},
		Timeout: 5 * time.Second,
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, "https://"+ln.Addr().String()+"/v1/ssh", nil)
	req.Header.Set("X-DeviceBridge-Version", "1")
	res, err := httpClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = res.Body.Close()
	if res.StatusCode != http.StatusUpgradeRequired {
		t.Fatalf("expected 426 without Upgrade header, got %d", res.StatusCode)
	}

	// Paired identity alone does not grant shell access. No SSH credentials are needed.
	if _, err := client.DialAgentSSH(ctx, cliID, cliStore, prov, cand); err == nil || !strings.Contains(err.Error(), "403") {
		t.Fatalf("expected approval gate: %v", err)
	}
	if _, err := srvStore.AgentSSHAccess(ctx, cliID.ID, "allow"); err != nil {
		t.Fatal(err)
	}
	// Dial mTLS agent SSH stream and execute command over SSH.
	sshRawConn, err := client.DialAgentSSH(ctx, cliID, cliStore, prov, cand)
	if err != nil {
		t.Fatalf("DialAgentSSH: %v", err)
	}
	if _, ok := sshRawConn.(interface{ Read([]byte) (int, error) }); !ok {
		t.Fatal("unexpected conn")
	}
	sshConn, chans, reqs, err := ssh.NewClientConn(sshRawConn, cand.Endpoint, &ssh.ClientConfig{
		User:            "devicebridge",
		Auth:            []ssh.AuthMethod{},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
	})
	if err != nil {
		_ = sshRawConn.Close()
		t.Fatalf("ssh.NewClientConn: %v", err)
	}
	sshClient := ssh.NewClient(sshConn, chans, reqs)
	defer sshClient.Close()

	if srv.Stats.Snapshot().ActiveSSH != 1 {
		t.Fatalf("expected ActiveSSH=1 during session, got %d", srv.Stats.Snapshot().ActiveSSH)
	}

	sess, err := sshClient.NewSession()
	if err != nil {
		t.Fatalf("NewSession: %v", err)
	}
	defer sess.Close()
	out, err := sess.CombinedOutput("printf mtls-ssh-ok")
	if err != nil {
		t.Fatalf("CombinedOutput: %v (%s)", err, out)
	}
	if strings.TrimSpace(string(out)) != "mtls-ssh-ok" {
		t.Fatalf("unexpected output %q", out)
	}

	// Disabling only SSH closes a hijacked session and leaves the Agent HTTP API usable.
	if _, err := srvStore.NetworkPolicy(ctx, map[string]bool{"network_agent_ssh": false}); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- sshClient.Wait() }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("disabled Agent SSH left session alive")
	}
	req, _ = http.NewRequestWithContext(ctx, http.MethodGet, "https://"+ln.Addr().String()+"/v1/device", nil)
	req.Header.Set("X-DeviceBridge-Version", "1")
	res, err = httpClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != 200 {
		t.Fatalf("disabling SSH broke Agent API: %d", res.StatusCode)
	}
	if _, err := client.DialAgentSSH(ctx, cliID, cliStore, prov, cand); err == nil {
		t.Fatal("disabled SSH accepted new session")
	}
	_ = sshClient.Close()
}
