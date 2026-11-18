// Package discovery implements the bounded DNS-SD subset DeviceBridge needs.
// Advertisements are hints only; callers must authenticate the pinned device key.
package discovery

import (
	"context"
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
	"time"
)

const service = protocol.Service + ".local."

var multicast = &net.UDPAddr{IP: net.IPv4(224, 0, 0, 251), Port: 5353}

func records(id string, port int, ip net.IP) []dns.RR {
	instance := "db-" + id[:16] + "." + service
	host := "db-" + id[:16] + ".local."
	return []dns.RR{&dns.PTR{Hdr: dns.RR_Header{Name: service, Rrtype: dns.TypePTR, Class: dns.ClassINET, Ttl: 30}, Ptr: instance}, &dns.SRV{Hdr: dns.RR_Header{Name: instance, Rrtype: dns.TypeSRV, Class: dns.ClassINET, Ttl: 30}, Port: uint16(port), Target: host}, &dns.TXT{Hdr: dns.RR_Header{Name: instance, Rrtype: dns.TypeTXT, Class: dns.ClassINET, Ttl: 30}, Txt: []string{"v=1", "id=" + id}}, &dns.A{Hdr: dns.RR_Header{Name: host, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 30}, A: ip}}
}
func Advertise(ctx context.Context, p *direct.Provider, id string, port int) (func(), error) {
	iface, err := networkInterface(p.Interface)
	if err != nil {
		return nil, err
	}
	conn, err := net.ListenMulticastUDP("udp4", iface, multicast)
	if err != nil {
		return nil, err
	}
	pc := ipv4.NewPacketConn(conn)
	if err = pc.SetMulticastInterface(iface); err != nil {
		conn.Close()
		return nil, err
	}
	_ = pc.SetMulticastTTL(255)
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
				msg := dns.Msg{MsgHdr: dns.MsgHdr{Id: query.Id, Response: true, Authoritative: true}, Answer: records(id, port, net.ParseIP(p.Address.String()))}
				data, e := msg.Pack()
				if e != nil {
					continue
				}
				dst := multicast
				if src.Port != 5353 || q.Qclass&0x8000 != 0 {
					dst = src
				}
				conn.WriteToUDP(data, dst)
				break
			}
		}
	}()
	return stop, nil
}
func Browse(ctx context.Context, p *direct.Provider) ([]transport.Candidate, error) {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP(p.Address.String()), Port: 0})
	if err != nil {
		return nil, err
	}
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
	query := dns.Msg{Question: []dns.Question{{Name: service, Qtype: dns.TypePTR, Qclass: dns.ClassINET | 0x8000}}}
	data, err := query.Pack()
	if err != nil {
		return nil, err
	}
	if _, err = conn.WriteToUDP(data, multicast); err != nil {
		return nil, err
	}
	deadline := time.Now().Add(3 * time.Second)
	if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
		deadline = d
	}
	_ = conn.SetReadDeadline(deadline)
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
				_, _ = conn.WriteToUDP(data, multicast)
			}
		}
	}()
	go func() {
		select {
		case <-ctx.Done():
			conn.Close()
		case <-done:
		}
	}()
	found := map[string]transport.Candidate{}
	buf := make([]byte, 9000)
	for {
		n, src, e := conn.ReadFromUDP(buf)
		if e != nil {
			var ne net.Error
			if errors.As(e, &ne) && ne.Timeout() {
				break
			}
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			return nil, e
		}
		if !p.Prefix.Contains(src.AddrPort().Addr().Unmap()) {
			continue
		}
		var msg dns.Msg
		if msg.Unpack(buf[:n]) != nil || !msg.Response {
			continue
		}
		srv := map[string]uint16{}
		ids := map[string]string{}
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
					if strings.HasPrefix(v, "id=") {
						ids[r.Hdr.Name] = strings.TrimPrefix(v, "id=")
					}
				}
			}
		}
		for instance, id := range ids {
			raw, e := hex.DecodeString(id)
			if e != nil || len(raw) != 32 || srv[instance] == 0 || !ptrs[instance] {
				continue
			}
			endpoint := net.JoinHostPort(src.IP.String(), strconv.Itoa(int(srv[instance])))
			found[id+endpoint] = transport.Candidate{DeviceID: id, Endpoint: endpoint, Interface: p.Interface, Transport: p.ID(), Observed: time.Now().UTC(), Cost: p.NetworkCost(transport.Candidate{}), Direct: true}
		}
	}
	out := []transport.Candidate{}
	for _, c := range found {
		out = append(out, c)
	}
	return out, nil
}
