package client

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestDownloadStallCancelsBodyRead(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer s.Close()

	limit, stop := context.WithTimeout(context.Background(), 3*time.Second)
	defer stop()
	ctx, cancel := context.WithCancelCause(limit)
	defer cancel(nil)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.URL, nil)
	if err != nil {
		t.Fatal(err)
	}
	res, err := s.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body := watchDownload(ctx, cancel, res.Body, 10*time.Millisecond)
	defer body.Close()
	if _, err := body.Read(make([]byte, 1)); !errors.Is(err, context.DeadlineExceeded) || limit.Err() != nil {
		t.Fatalf("read should time out before the parent context, got %v (parent %v)", err, limit.Err())
	}
}
