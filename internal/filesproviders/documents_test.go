package filesproviders

import (
	"bufio"
	"context"
	"devicebridge/protocol"
	"encoding/json"
	"io"
	"net"
	"strings"
	"testing"
)

func TestDocumentsAdapterScopeUnicodeAndSeek(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	token := strings.Repeat("a", 64)
	data := []byte("native Android document bytes")
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				var request struct {
					Version   int    `json:"version"`
					Token     string `json:"token"`
					Path      string `json:"path"`
					Operation string `json:"operation"`
					Offset    int64  `json:"offset"`
				}
				if json.NewDecoder(bufio.NewReader(conn)).Decode(&request) != nil {
					return
				}
				if request.Token != token || request.Path != "space λ.txt" {
					json.NewEncoder(conn).Encode(map[string]any{"ok": false})
					return
				}
				switch request.Operation {
				case "stat":
					json.NewEncoder(conn).Encode(documentReply{OK: true, Entry: protocol.Entry{Name: "space λ.txt", Path: request.Path, Kind: "file", Size: int64(len(data))}})
				case "read":
					json.NewEncoder(conn).Encode(documentReply{OK: true, Bytes: int64(len(data)) - request.Offset})
					conn.Write(data[request.Offset:])
				}
			}()
		}
	}()
	provider, err := NewDocuments("saf", "saf", listener.Addr().String(), token)
	if err != nil {
		t.Fatal(err)
	}
	reader, err := provider.OpenRead(context.Background(), "space λ.txt")
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	if _, err = reader.Seek(7, io.SeekStart); err != nil {
		t.Fatal(err)
	}
	actual, err := io.ReadAll(reader)
	if err != nil || string(actual) != string(data[7:]) {
		t.Fatalf("seek result: %q %v", actual, err)
	}
	if _, err = provider.OpenRead(context.Background(), "../outside"); err == nil {
		t.Fatal("accepted traversal")
	}
	denied, _ := NewDocuments("saf", "saf", listener.Addr().String(), strings.Repeat("b", 64))
	if _, err = denied.Stat(context.Background(), "space λ.txt"); err == nil {
		t.Fatal("accepted invalid adapter token")
	}
	if _, err = NewDocuments("saf", "saf", "10.0.0.1:1234", token); err == nil {
		t.Fatal("accepted non-loopback adapter")
	}
}
