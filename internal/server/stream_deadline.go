package server

import (
	"io"
	"net/http"
	"time"
)

const streamIdle = 30 * time.Second

// Renew a stream's I/O budget while bytes move, without updating the socket's
// timer on every small read or write.
type streamDeadline struct {
	set     func(time.Time) error
	refresh time.Time
}

func (d *streamDeadline) renew() {
	now := time.Now()
	if !now.Before(d.refresh) {
		_ = d.set(now.Add(streamIdle))
		d.refresh = now.Add(streamIdle / 2)
	}
}

type streamReader struct {
	io.Reader
	deadline streamDeadline
}

func (r *streamReader) Read(p []byte) (int, error) {
	r.deadline.renew()
	return r.Reader.Read(p)
}

func beginStreamUpload(w http.ResponseWriter, body io.Reader) (io.Reader, func()) {
	control := http.NewResponseController(w)
	// The upload has a bounded read deadline. Start a separate write deadline
	// when its final receipt is ready.
	_ = control.SetWriteDeadline(time.Time{})
	reader := &streamReader{Reader: body, deadline: streamDeadline{set: control.SetReadDeadline}}
	return reader, func() { _ = control.SetWriteDeadline(time.Now().Add(streamIdle)) }
}

type streamWriter struct {
	io.Writer
	deadline streamDeadline
}

func beginStreamDownload(w http.ResponseWriter) io.Writer {
	out := &streamWriter{
		Writer:   w,
		deadline: streamDeadline{set: http.NewResponseController(w).SetWriteDeadline},
	}
	out.deadline.renew()
	return out
}

func (w *streamWriter) Write(p []byte) (int, error) {
	var total int
	for len(p) > 0 {
		// Keep a single write bounded even on a slow link. The larger
		// authorization and disk-read windows can stay intact.
		block := p[:min(len(p), 64<<10)]
		w.deadline.renew()
		n, err := w.Writer.Write(block)
		total += n
		if err != nil {
			return total, err
		}
		if n != len(block) {
			return total, io.ErrShortWrite
		}
		p = p[n:]
	}
	return total, nil
}
