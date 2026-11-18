package filesproviders

import (
	"bufio"
	"context"
	"devicebridge/protocol"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strconv"
	"time"
)

// Documents delegates scoped SAF/Termux reads to the Android application UID.
// No system/root access, remote shell, or copied Termux private state is used.
type Documents struct{ rootID, kind, endpoint, token string }

func NewDocuments(id, kind, endpoint, token string) (*Documents, error) {
	host, port, err := net.SplitHostPort(endpoint)
	if err != nil || host != "127.0.0.1" || port == "" || len(token) != 64 || (kind != "saf" && kind != "termux") {
		return nil, errors.New("invalid app-private documents adapter")
	}
	return &Documents{id, kind, endpoint, token}, nil
}
func (p *Documents) ID() string { return p.rootID }
func (p *Documents) Scope() Scope {
	return Scope{Version: ContractVersion, RootID: p.rootID, Kind: "android-documents-v1", Read: true}
}
func (p *Documents) Close() error { return nil }

type documentReply struct {
	OK      bool             `json:"ok"`
	Error   string           `json:"error"`
	Entry   protocol.Entry   `json:"entry"`
	Listing protocol.Listing `json:"listing"`
	Bytes   int64            `json:"bytes"`
}

func (p *Documents) request(ctx context.Context, rel, operation string, offset int64, limit int) (documentReply, net.Conn, *bufio.Reader, error) {
	var reply documentReply
	if err := ValidPath(rel); err != nil {
		return reply, nil, nil, err
	}
	d := net.Dialer{Timeout: 5 * time.Second}
	conn, err := d.DialContext(ctx, "tcp4", p.endpoint)
	if err != nil {
		return reply, nil, nil, err
	}
	cancel := context.AfterFunc(ctx, func() { conn.Close() })
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
	err = json.NewEncoder(conn).Encode(map[string]any{"version": 1, "token": p.token, "kind": p.kind, "path": rel, "operation": operation, "offset": offset, "limit": limit})
	reader := bufio.NewReaderSize(conn, 1<<20)
	var line []byte
	if err == nil {
		line, err = reader.ReadSlice('\n')
	}
	if err == nil {
		err = json.Unmarshal(line, &reply)
	}
	if err == nil && !reply.OK {
		err = errors.New("Android document permission missing or source changed")
	}
	if err != nil {
		cancel()
		conn.Close()
		return reply, nil, nil, err
	}
	// Reading remains cancellable through its connection; stop the context hook
	// when this request's connection is explicitly closed.
	return reply, &documentConn{Conn: conn, stop: cancel}, reader, nil
}

type documentConn struct {
	net.Conn
	stop func() bool
}

func (c *documentConn) Close() error { c.stop(); return c.Conn.Close() }
func (p *Documents) List(ctx context.Context, rel, token string, limit int) (protocol.Listing, error) {
	offset := int64(0)
	var err error
	if token != "" {
		offset, err = strconv.ParseInt(token, 10, 64)
		if err != nil || offset < 0 {
			return protocol.Listing{}, errors.New("invalid page token")
		}
	}
	result, c, _, err := p.request(ctx, rel, "list", offset, limit)
	if err != nil {
		return protocol.Listing{}, err
	}
	c.Close()
	return result.Listing, nil
}
func (p *Documents) Stat(ctx context.Context, rel string) (protocol.Entry, error) {
	r, c, _, err := p.request(ctx, rel, "stat", 0, 0)
	if err != nil {
		return protocol.Entry{}, err
	}
	c.Close()
	return r.Entry, nil
}
func (p *Documents) OpenWriteStaged(context.Context, string) (StagedWrite, error) {
	return nil, ErrReadOnly
}
func (p *Documents) OpenRead(ctx context.Context, rel string) (io.ReadSeekCloser, error) {
	meta, err := p.Stat(ctx, rel)
	if err != nil {
		return nil, err
	}
	if meta.Kind != "file" {
		return nil, errors.New("not a regular document")
	}
	return &documentReader{ctx: ctx, p: p, path: rel, size: meta.Size}, nil
}

type documentReader struct {
	ctx       context.Context
	p         *Documents
	path      string
	size, pos int64
	conn      net.Conn
	reader    io.Reader
	closed    bool
}

func (r *documentReader) Read(b []byte) (int, error) {
	if r.closed {
		return 0, errors.New("document reader closed")
	}
	if r.pos >= r.size {
		return 0, io.EOF
	}
	if r.conn == nil {
		reply, c, reader, err := r.p.request(r.ctx, r.path, "read", r.pos, 0)
		if err != nil {
			return 0, err
		}
		if reply.Bytes != r.size-r.pos {
			c.Close()
			return 0, errors.New("document size changed")
		}
		r.conn = c
		r.reader = io.LimitReader(reader, reply.Bytes)
	}
	_ = r.conn.SetReadDeadline(time.Now().Add(30 * time.Second))
	n, err := r.reader.Read(b)
	r.pos += int64(n)
	return n, err
}
func (r *documentReader) Seek(offset int64, whence int) (int64, error) {
	position := offset
	switch whence {
	case io.SeekStart:
	case io.SeekCurrent:
		position += r.pos
	case io.SeekEnd:
		position += r.size
	default:
		return 0, errors.New("invalid seek mode")
	}
	if position < 0 || position > r.size {
		return 0, errors.New("invalid document offset")
	}
	if r.conn != nil {
		r.conn.Close()
		r.conn = nil
	}
	r.pos = position
	return position, nil
}
func (r *documentReader) Close() error {
	r.closed = true
	if r.conn != nil {
		return r.conn.Close()
	}
	return nil
}
