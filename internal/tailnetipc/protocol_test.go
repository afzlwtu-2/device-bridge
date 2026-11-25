package tailnetipc

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"path/filepath"
	"testing"
	"time"
)

func TestGuardedStreamRejectsChangedOrLegacyBinding(t *testing.T) {
	for _, actual := range []string{"", "42", "24"} {
		t.Run("handle-"+actual, func(t *testing.T) {
			socket := filepath.Join(t.TempDir(), "control")
			l, err := net.Listen("unix", socket)
			if err != nil {
				t.Fatal(err)
			}
			defer l.Close()
			served := make(chan error, 1)
			go func() {
				conn, err := l.Accept()
				if err == nil {
					defer conn.Close()
					var req Request
					_ = conn.SetDeadline(time.Now().Add(time.Second))
					err = json.NewDecoder(conn).Decode(&req)
					if err == nil {
						err = json.NewEncoder(conn).Encode(Response{Version: req.Version, NetworkHandle: actual})
					}
				}
				served <- err
			}()
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			_, conn, err := (Client{Socket: socket}).Exchange(ctx, Request{Operation: "stream", NetworkHandle: "42"})
			if conn != nil {
				conn.Close()
			}
			if serverErr := <-served; serverErr != nil {
				t.Fatal(serverErr)
			}
			if actual == "42" {
				if err != nil || conn == nil {
					t.Fatalf("bound route refused: %v", err)
				}
			} else if !errors.Is(err, ErrNetworkBinding) || conn != nil {
				t.Fatalf("a changed or older sidecar must never get a payload, got %v", err)
			}
		})
	}
}
