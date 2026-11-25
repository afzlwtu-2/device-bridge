// Package discovery implements the bounded DNS-SD subset DeviceBridge needs.
// Advertisements are hints only; callers must authenticate the pinned device key.
package discovery

import (
	"context"
	"devicebridge/internal/platform"
	"devicebridge/internal/transport"
	"devicebridge/internal/transport/direct"
	"devicebridge/protocol"
	"encoding/hex"
	"errors"
	"github.com/miekg/dns"
	"golang.org/x/net/ipv4"
	"net"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

const service = protocol.Service + ".local."

var multicast = &net.UDPAddr{IP: net.IPv4(224, 0, 0, 251), Port: 5353}

func records(id, name string, port int, ip net.IP) []dns.RR {
	instance := "db-" + id[:16] + "." + service
	host := "db-" + id[:16] + ".local."
	txt := []string{"v=1", "id=" + id}
	if name != "" && len(name) <= 128 && utf8.ValidString(name) {
		txt = append(txt, "name="+name)
	}
	return []dns.RR{
		&dns.PTR{Hdr: dns.RR_Header{Name: service, Rrtype: dns.TypePTR, Class: dns.ClassINET, Ttl: 30}, Ptr: instance},
		&dns.SRV{Hdr: dns.RR_Header{Name: instance, Rrtype: dns.TypeSRV, Class: dns.ClassINET, Ttl: 30}, Port: uint16(port), Target: host},
		&dns.TXT{Hdr: dns.RR_Header{Name: instance, Rrtype: dns.TypeTXT, Class: dns.ClassINET, Ttl: 30}, Txt: txt},
		&dns.A{Hdr: dns.RR_Header{Name: host, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 30}, A: ip},
	}
}
func listenMulticast(ctx context.Context, iface *net.Interface) (*net.UDPConn, error) {
	lc := net.ListenConfig{Control: func(network, address string, c syscall.RawConn) error {
		if err := platform.SocketControl(network, address, c); err != nil {
			return err
		}
		var reuseErr error
		err := c.Control(func(fd uintptr) {
			reuseErr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1)
		})
		if err != nil {
			return err
		}
		return reuseErr
	}}
	packet, err := lc.ListenPacket(ctx, "udp4", ":5353")
	if err != nil {
		return nil, err
	}
	conn := packet.(*net.UDPConn)
	pc := ipv4.NewPacketConn(conn)
	if err = pc.JoinGroup(iface, multicast); err != nil {
		conn.Close()
		return nil, err
	}
	if err = pc.SetMulticastInterface(iface); err != nil {
		conn.Close()
		return nil, err
	}
	_ = pc.SetMulticastTTL(255)
	return conn, nil
}

func Advertise(ctx context.Context, p *direct.Provider, id, name string, port int) (func(), error) {
	iface, err := networkInterface(p.Interface)
	if err != nil {
		return nil, err
	}
	conn, err := listenMulticast(ctx, iface)
	if err != nil {
		return nil, err
	}
	stop := func() { conn.Close() }
	go func() { <-ctx.Done(); stop() }()
	go func() {
		buf := make([]byte, 9000)
		for {
			n, src, e := conn.ReadFromUDP(buf)
			if e != nil {
				return
			}
			if !p.Prefix.Contains(src.AddrPort().Addr().Unmap()) {
				continue
			}
			var query dns.Msg
			if query.Unpack(buf[:n]) != nil || query.Response {
				continue
			}
			for _, q := range query.Question {
				if !strings.EqualFold(q.Name, service) || q.Qtype != dns.TypePTR {
					continue
				}
				msg := dns.Msg{MsgHdr: dns.MsgHdr{Id: query.Id, Response: true, Authoritative: true}, Answer: records(id, name, port, net.ParseIP(p.Address.String()))}
				data, e := msg.Pack()
				if e != nil {
					continue
				}
				dst := multicast
				if q.Qclass&0x8000 != 0 {
					dst = src
				}
				_, _ = conn.WriteToUDP(data, dst)
				break
			}
		}
	}()
	return stop, nil
}
func parseResponse(p *direct.Provider, src *net.UDPAddr, raw []byte, found map[string]transport.Candidate) {
	if !p.Prefix.Contains(src.AddrPort().Addr().Unmap()) {
		return
	}
	var msg dns.Msg
	if msg.Unpack(raw) != nil || !msg.Response {
		return
	}
	srv := map[string]uint16{}
	ids := map[string]string{}
	names := map[string]string{}
	ptrs := map[string]bool{}
	for _, rr := range append(msg.Answer, msg.Extra...) {
		switch r := rr.(type) {
		case *dns.PTR:
			if strings.EqualFold(r.Hdr.Name, service) {
				ptrs[r.Ptr] = true
			}
		case *dns.SRV:
			srv[r.Hdr.Name] = r.Port
		case *dns.TXT:
			for _, v := range r.Txt {
				if id, ok := strings.CutPrefix(v, "id="); ok {
					ids[r.Hdr.Name] = id
				} else if name, ok := strings.CutPrefix(v, "name="); ok && len(name) <= 128 && utf8.ValidString(name) {
					names[r.Hdr.Name] = protocol.DeviceDisplayName(name)
				}
			}
		}
	}
	for instance, id := range ids {
		rawID, e := hex.DecodeString(id)
		if e != nil || len(rawID) != 32 || srv[instance] == 0 || !ptrs[instance] {
			continue
		}
		endpoint := net.JoinHostPort(src.IP.String(), strconv.Itoa(int(srv[instance])))
		found[id+endpoint] = transport.Candidate{DeviceID: id, DeviceName: names[instance], Endpoint: endpoint, Interface: p.Interface, Transport: p.ID(), Observed: time.Now().UTC(), Cost: p.NetworkCost(transport.Candidate{}), Direct: true}
	}
}

func Browse(ctx context.Context, p *direct.Provider) ([]transport.Candidate, error) {
	lc := net.ListenConfig{Control: platform.SocketControl}
	packet, err := lc.ListenPacket(ctx, "udp4", net.JoinHostPort(p.Address.String(), "0"))
	if err != nil {
		return nil, err
	}
	conn := packet.(*net.UDPConn)
	defer conn.Close()
	iface, err := networkInterface(p.Interface)
	if err != nil {
		return nil, err
	}
	pc := ipv4.NewPacketConn(conn)
	if err = pc.SetMulticastInterface(iface); err != nil {
		return nil, err
	}
	_ = pc.SetMulticastTTL(255)

	mcast, mcastErr := listenMulticast(ctx, iface)
	if mcastErr == nil {
		defer mcast.Close()
	}

	qmData, err := (&dns.Msg{Question: []dns.Question{{Name: service, Qtype: dns.TypePTR, Qclass: dns.ClassINET}}}).Pack()
	if err != nil {
		return nil, err
	}
	quData, err := (&dns.Msg{Question: []dns.Question{{Name: service, Qtype: dns.TypePTR, Qclass: dns.ClassINET | 0x8000}}}).Pack()
	if err != nil {
		return nil, err
	}
	sendQueries := func() error {
		if mcast != nil {
			if _, e := conn.WriteToUDP(qmData, multicast); e != nil {
				return e
			}
		}
		_, e := conn.WriteToUDP(quData, multicast)
		return e
	}
	if err = sendQueries(); err != nil {
		return nil, err
	}
	deadline := time.Now().Add(3 * time.Second)
	if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
		deadline = d
	}
	_ = conn.SetReadDeadline(deadline)
	if mcast != nil {
		_ = mcast.SetReadDeadline(deadline)
	}
	done := make(chan struct{})
	defer close(done)
	go func() {
		ticker := time.NewTicker(400 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ctx.Done():
				return
			case <-ticker.C:
				_ = sendQueries()
			}
		}
	}()
	go func() {
		select {
		case <-ctx.Done():
			conn.Close()
			if mcast != nil {
				mcast.Close()
			}
		case <-done:
		}
	}()
	type pkt struct {
		src *net.UDPAddr
		raw []byte
		err error
	}
	packets := make(chan pkt, 16)
	readLoop := func(c *net.UDPConn, reportErr bool) {
		buf := make([]byte, 9000)
		for {
			n, src, e := c.ReadFromUDP(buf)
			if e != nil {
				var ne net.Error
				if errors.As(e, &ne) && ne.Timeout() {
					packets <- pkt{}
					return
				}
				if reportErr {
					packets <- pkt{err: e}
				} else {
					packets <- pkt{}
				}
				return
			}
			cp := make([]byte, n)
			copy(cp, buf[:n])
			packets <- pkt{src: src, raw: cp}
		}
	}
	readers := 1
	go readLoop(conn, true)
	if mcast != nil {
		readers++
		go readLoop(mcast, false)
	}
	found := map[string]transport.Candidate{}
	for readers > 0 {
		pck := <-packets
		if pck.err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			return nil, pck.err
		}
		if pck.src == nil {
			readers--
			continue
		}
		parseResponse(p, pck.src, pck.raw, found)
	}
	out := []transport.Candidate{}
	for _, c := range found {
		out = append(out, c)
	}
	return out, nil
}
