package bootstrap

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

// StreamSSHClientTerminal attaches a PTY shell over an already-connected ssh.Client
// and exchanges JSON TerminalFrame lines over input and output.
func StreamSSHClientTerminal(
	ctx context.Context,
	client *ssh.Client,
	columns, rows int,
	input *bufio.Scanner,
	output interface{ Write([]byte) (int, error) },
	leaseCheck func() error,
) error {
	setup, setupCancel := context.WithTimeout(ctx, 15*time.Second)
	defer setupCancel()
	stopSetup := context.AfterFunc(setup, func() { _ = client.Close() })
	defer stopSetup()

	session, err := client.NewSession()
	if err != nil {
		return err
	}
	defer session.Close()

	sink := &terminalOutput{encoder: json.NewEncoder(output)}
	session.Stdout, session.Stderr = sink, sink
	writer, err := session.StdinPipe()
	if err != nil {
		return err
	}
	defer writer.Close()

	cols, rws := terminalSize(columns, rows)
	if err := session.RequestPty("xterm-256color", rws, cols, nil); err != nil {
		return err
	}
	if err := session.Shell(); err != nil {
		return err
	}
	stopSetup()
	if err := sink.emit(TerminalFrame{State: "ready"}); err != nil {
		return err
	}

	exited := make(chan error, 1)
	go func() { exited <- session.Wait() }()
	inputDone := make(chan error, 1)
	go func() {
		defer writer.Close()
		for input.Scan() {
			var frame TerminalFrame
			if err := json.Unmarshal(input.Bytes(), &frame); err != nil {
				inputDone <- err
				return
			}
			if len(frame.Data) > 0 {
				if _, err := writer.Write(frame.Data); err != nil {
					inputDone <- err
					return
				}
			}
			if frame.Columns > 0 && frame.Rows > 0 {
				c, r := terminalSize(frame.Columns, frame.Rows)
				if err := session.WindowChange(r, c); err != nil {
					inputDone <- err
					return
				}
			}
		}
		inputDone <- input.Err()
	}()

	var watch *time.Ticker
	var watchCh <-chan time.Time
	if leaseCheck != nil {
		watch = time.NewTicker(time.Second)
		defer watch.Stop()
		watchCh = watch.C
	}
	for {
		select {
		case err := <-exited:
			return err
		case err := <-inputDone:
			return err
		case <-ctx.Done():
			return ctx.Err()
		case <-watchCh:
			if err := leaseCheck(); err != nil {
				return err
			}
		}
	}
}

// NewAgentSSHClient wraps a raw mTLS SSH stream into an ssh.Client.
// The underlying net.Conn MUST already be authenticated via mTLS to the target peer.
func NewAgentSSHClient(ctx context.Context, conn net.Conn, endpoint string) (*ssh.Client, error) {
	var once sync.Once
	closeConn := func() { once.Do(func() { _ = conn.Close() }) }
	stop := context.AfterFunc(ctx, closeConn)
	defer stop()

	sshConn, chans, reqs, err := ssh.NewClientConn(conn, endpoint, &ssh.ClientConfig{
		User:            "devicebridge",
		Auth:            []ssh.AuthMethod{},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
	})
	if err != nil {
		closeConn()
		return nil, err
	}
	return ssh.NewClient(sshConn, chans, reqs), nil
}
