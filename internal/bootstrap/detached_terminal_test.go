package bootstrap

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestParseTerminalGroupsAndIdentityChecks(t *testing.T) {
	groups, err := ParseTerminalGroups("3003 10123 3003")
	if err != nil {
		t.Fatalf("ParseTerminalGroups failed: %v", err)
	}
	if !slices.Equal(groups, []int{3003, 10123, 3003}) {
		t.Fatalf("unexpected groups: %v", groups)
	}
	if _, err := ParseTerminalGroups("1000 -1"); err == nil {
		t.Fatal("expected negative group rejection")
	}
	if err := CheckDetachedTerminalIdentity(0, 0, nil, "selinux-disabled"); err == nil {
		t.Fatal("expected root UID rejection")
	}
	if os.Getuid() >= 10000 {
		g, _ := os.Getgroups()
		if err := CheckDetachedTerminalIdentity(os.Getuid(), os.Getgid(), g, "invalid-context"); err == nil {
			t.Fatal("expected non-untrusted_app context rejection")
		}
	}
	if !matchesRestoredGroups(10146, []int{3003, 9997, 10146, 20146, 50146}, []int{3003, 9997, 20146, 50146}) {
		t.Fatal("expected primary GID inclusion from MagiskSU to match")
	}
	if !matchesRestoredGroups(10146, []int{3003, 9997, 20146, 50146}, []int{3003, 9997, 20146, 50146}) {
		t.Fatal("expected exact supplementary groups to match")
	}
	if matchesRestoredGroups(10146, []int{0, 3003, 9997, 10146, 20146, 50146}, []int{3003, 9997, 20146, 50146}) {
		t.Fatal("expected extra root GID 0 to be rejected")
	}
	if matchesRestoredGroups(10146, []int{3003, 10146}, []int{3003, 9997}) {
		t.Fatal("expected missing supplementary group to be rejected")
	}
}

func TestDetachedTerminalReattachAndStop(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	state := t.TempDir()
	done := make(chan error, 1)
	go func() { done <- ServeDetachedTerminal(ctx, state, "session") }()
	socket := filepath.Join(state, "pt", "session.sock")
	connect := func(operation string) (*net.UnixConn, *bufio.Scanner) {
		t.Helper()
		var conn *net.UnixConn
		for ctx.Err() == nil {
			var err error
			conn, err = net.DialUnix("unix", nil, &net.UnixAddr{Name: socket, Net: "unix"})
			if err == nil {
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
		if conn == nil {
			t.Fatal("terminal socket unavailable")
		}
		t.Cleanup(func() { conn.Close() })
		conn.SetDeadline(time.Now().Add(3 * time.Second))
		err := json.NewEncoder(conn).Encode(terminalAttachRequest{
			Version: 1, Operation: operation,
			Request: LocalTerminalRequest{Columns: 80, Rows: 24, Shell: "/bin/sh"},
		})
		if err != nil {
			t.Fatal(err)
		}
		return conn, bufio.NewScanner(conn)
	}
	expectOutput := func(frames *bufio.Scanner, expected string) {
		t.Helper()
		var output strings.Builder
		for frames.Scan() {
			var frame TerminalFrame
			if err := json.Unmarshal(frames.Bytes(), &frame); err != nil {
				t.Fatal(err)
			}
			output.Write(frame.Data)
			if strings.Contains(output.String(), expected) {
				return
			}
		}
		t.Fatalf("expected %q in %q: %v", expected, output.String(), frames.Err())
	}
	send := func(conn net.Conn, command string) {
		t.Helper()
		if err := json.NewEncoder(conn).Encode(TerminalFrame{Data: []byte(command + "\n")}); err != nil {
			t.Fatal(err)
		}
	}
	first, frames := connect("attach")
	send(first, "DB_TEST=retained; printf '\\n%s%s\\n' BEFORE _DETACH")
	expectOutput(frames, "\r\nBEFORE_DETACH\r\n")
	first.Close()

	second, replay := connect("attach")
	expectOutput(replay, "\r\nBEFORE_DETACH\r\n")
	send(second, "printf '\\n%s\\n' \"$DB_TEST\"")
	expectOutput(replay, "\r\nretained\r\n")

	connect("stop")
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("Stop did not end the terminal")
	}
}
