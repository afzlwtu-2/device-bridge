package sshserver

import (
	"context"
	"net"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"
)

func TestHandleMTLSConnExecAndPTY(t *testing.T) {
	dir := t.TempDir()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	srvErr := make(chan error, 1)
	go func() {
		srvConn, aErr := ln.Accept()
		if aErr != nil {
			srvErr <- aErr
			return
		}
		srvErr <- HandleMTLSConn(ctx, srvConn, dir, "peer-1")
	}()

	cliConn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	conn, chans, reqs, err := ssh.NewClientConn(cliConn, "peer-1", &ssh.ClientConfig{
		User:            "devicebridge",
		Auth:            []ssh.AuthMethod{},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
	})
	if err != nil {
		_ = cliConn.Close()
		t.Fatalf("NewClientConn: %v", err)
	}
	client := ssh.NewClient(conn, chans, reqs)
	defer client.Close()

	sess, err := client.NewSession()
	if err != nil {
		t.Fatalf("NewSession: %v", err)
	}
	defer sess.Close()
	out, err := sess.CombinedOutput("printf hello-agent-ssh")
	if err != nil {
		t.Fatalf("CombinedOutput: %v (%s)", err, out)
	}
	if strings.TrimSpace(string(out)) != "hello-agent-ssh" {
		t.Fatalf("unexpected output %q", out)
	}
	_ = client.Close()
	if err := <-srvErr; err != nil {
		t.Fatalf("HandleMTLSConn error: %v", err)
	}
}
