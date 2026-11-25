package client

import (
	"context"
	"io"
	"net/http"
	"net/url"
	"sync/atomic"
	"time"
)

// openDownload uses an idle timeout rather than a total request timeout so that
// large transfers can run as long as the stream continues to deliver bytes.
func (c *Client) openDownload(ctx context.Context, path string, q url.Values) (*http.Response, error) {
	ctx, cancel := context.WithCancelCause(ctx)
	res, err := c.doRequest(c.StreamHTTP, ctx, http.MethodGet, path, q, nil)
	if err != nil {
		cancel(nil)
		return nil, err
	}
	res.Body = watchDownload(ctx, cancel, res.Body, 10*time.Second)
	return res, nil
}

type downloadBody struct {
	io.ReadCloser
	ctx      context.Context
	cancel   context.CancelCauseFunc
	activity atomic.Bool
	reading  atomic.Bool
}

func watchDownload(ctx context.Context, cancel context.CancelCauseFunc, r io.ReadCloser, interval time.Duration) *downloadBody {
	body := &downloadBody{ReadCloser: r, ctx: ctx, cancel: cancel}
	ticker := time.NewTicker(interval)
	go func() {
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if !body.activity.Swap(false) && body.reading.Load() {
					cancel(context.DeadlineExceeded)
					return
				}
			}
		}
	}()
	return body
}

func (b *downloadBody) Read(p []byte) (int, error) {
	b.activity.Store(true)
	b.reading.Store(true)
	n, err := b.ReadCloser.Read(p)
	b.reading.Store(false)
	if err != nil && context.Cause(b.ctx) == context.DeadlineExceeded {
		err = context.DeadlineExceeded
	}
	return n, err
}

func (b *downloadBody) Close() error {
	defer b.cancel(nil)
	return b.ReadCloser.Close()
}
