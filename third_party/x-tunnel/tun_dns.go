//go:build windows

package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	dnsTypeA    uint16 = 1
	dnsTypeAAAA uint16 = 28
)

// DNSHandler manages TUN DNS processing
type DNSHandler struct {
	handler    *tunConnHandler
	ipStrategy byte
	pool       *ECHPool

	dnsMu          sync.Mutex
	dnsServers     []string
	dnsServersTime time.Time
	dnsIfaceIndex  int

	// DoH 长连接（见 dohClient 注释）
	dohMu           sync.Mutex
	dohClientCache  *http.Client
	dohDisableUntil time.Time // 长连接确认异常后的冷静期截止时刻
}

var dnsHandlerInstance *DNSHandler

func newDNSHandler(handler *tunConnHandler) *DNSHandler {
	dnsHandlerInstance = &DNSHandler{
		handler:    handler,
		ipStrategy: ipStrategy,
		pool:       handler.pool,
	}
	return dnsHandlerInstance
}

func (d *DNSHandler) currentPhysIface() *net.Interface {
	if d == nil || d.handler == nil {
		return nil
	}
	return d.handler.getPhysicalInterface()
}

// ProcessDNSQuery processes a DNS query packet and returns the response.
func ProcessDNSQuery(q []byte) []byte {
	if dnsHandlerInstance == nil {
		return nil
	}
	t0 := time.Now()
	domain := extractDNSName(q)
	if domain == "?" || domain == "." {
		return nil
	}

	var reply []byte

	decision, matchedRule := dnsRouteForDomain(domain)
	route := dnsRouteLabel(decision, matchedRule)
	if decision == DecisionBlock {
		log.Printf("[DNS][block] %s %s -> BLOCKED (%s)", domain, dnsQuestionTypeName(q), matchedRule)
		return servfailReply(q)
	}

	// Fast path: check DNS cache first
	if cached := lookupDNSCache(domain, q); cached != nil {
		cached[0], cached[1] = q[0], q[1] // match query ID
		cached = dnsHandlerInstance.applyIPStrategyToDNS(domain, q, cached, decision)
		cached[0], cached[1] = q[0], q[1]
		logDNSResult(domain, q, cached, "cache", time.Since(t0))
		return cached
	}

	if decision == DecisionDirect {
		reply = dnsHandlerInstance.resolveLocal(q)
	} else {
		reply = dnsHandlerInstance.resolveRemote(q)
	}
	if reply == nil {
		reply = servfailReply(q)
		logDNSServFail(domain, q, route, time.Since(t0))
	} else {
		reply = dnsHandlerInstance.applyIPStrategyToDNS(domain, q, reply, decision)
		reply[0], reply[1] = q[0], q[1]
		cacheDNSReply(domain, reply)
		logDNSResult(domain, q, reply, route, time.Since(t0))
	}
	return reply
}

func findQuestionEnd(q []byte) int {
	qEnd := 12
	for qEnd < len(q) {
		if q[qEnd] == 0 {
			qEnd += 5
			break
		}
		if q[qEnd]&0xC0 == 0xC0 {
			qEnd += 6
			break
		}
		qEnd += int(q[qEnd]) + 1
	}
	return qEnd
}

// runDNSListener starts DNS listeners on TUN gateway addresses
func runDNSListener(cfg *TunConfig, handler *tunConnHandler) {
	dnsH := newDNSHandler(handler)
	// 预热 DoH 长连接，避免用户打开的第一个网页为首个域名付一次完整握手
	go func() {
		time.Sleep(500 * time.Millisecond)
		dnsH.warmupDoH()
	}()
	seen := make(map[string]bool)
	for _, gw := range cfg.Gateway {
		host := strings.TrimSpace(gw)
		if host == "" {
			continue
		}
		if p, err := netip.ParsePrefix(host); err == nil {
			host = p.Addr().String()
		} else if strings.Contains(host, "/") {
			host = strings.Split(host, "/")[0]
		}
		addr := net.JoinHostPort(host, "53")
		if seen[addr] {
			continue
		}
		seen[addr] = true
		go dnsH.start(addr)
	}
}

func (d *DNSHandler) start(addr string) {
	ua, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		log.Printf("[DNS] resolve %s failed: %v", addr, err)
		return
	}
	c, err := net.ListenUDP("udp", ua)
	if err != nil {
		log.Printf("[DNS] listen %s failed: %v", addr, err)
		return
	}
	defer c.Close()
	log.Printf("[DNS] listener started %s", addr)

	b := make([]byte, 1500)
	for {
		n, ca, err := c.ReadFromUDP(b)
		if err != nil || n < 12 {
			continue
		}
		q := make([]byte, n)
		copy(q, b[:n])
		go d.handle(c, q, ca)
	}
}

func (d *DNSHandler) handle(c *net.UDPConn, q []byte, ca *net.UDPAddr) {
	t0 := time.Now()
	domain := extractDNSName(q)
	if domain == "?" || domain == "." {
		return
	}

	var reply []byte

	decision, matchedRule := dnsRouteForDomain(domain)
	route := dnsRouteLabel(decision, matchedRule)
	if decision == DecisionBlock {
		log.Printf("[DNS][block] %s %s -> BLOCKED (%s)", domain, dnsQuestionTypeName(q), matchedRule)
		c.WriteToUDP(servfailReply(q), ca)
		return
	}

	// Fast path: check DNS cache first
	if cached := lookupDNSCache(domain, q); cached != nil {
		cached[0], cached[1] = q[0], q[1]
		cached = d.applyIPStrategyToDNS(domain, q, cached, decision)
		cached[0], cached[1] = q[0], q[1]
		c.WriteToUDP(cached, ca)
		logDNSResult(domain, q, cached, "cache", time.Since(t0))
		return
	}

	if decision == DecisionDirect {
		reply = d.resolveLocal(q)
	} else {
		reply = d.resolveRemote(q)
	}
	if reply == nil {
		c.WriteToUDP(servfailReply(q), ca)
		logDNSServFail(domain, q, route, time.Since(t0))
		return
	}

	reply = d.applyIPStrategyToDNS(domain, q, reply, decision)
	reply[0], reply[1] = q[0], q[1]
	cacheDNSReply(domain, reply)
	c.WriteToUDP(reply, ca)
	logDNSResult(domain, q, reply, route, time.Since(t0))
}

func (d *DNSHandler) applyIPStrategyToDNS(domain string, q, reply []byte, decision RouteDecision) []byte {
	// 严格单栈模式全局生效。
	switch d.ipStrategy {
	case IPStrategyIPv4Only:
		return filterDNSReply(reply, IPStrategyIPv4Only)
	case IPStrategyIPv6Only:
		return filterDNSReply(reply, IPStrategyIPv6Only)
	}

	// 非严格模式下只对 direct 域名按本地物理网卡能力过滤。
	// proxy 域名不能按本地能力过滤，否则会破坏 VPS 侧 IPv4/IPv6 访问能力。
	if decision == DecisionDirect {
		if iface := d.currentPhysIface(); iface != nil {
			keepIPv4 := hasIPv4(iface)
			keepIPv6 := hasGlobal6(iface)
			if !keepIPv4 || !keepIPv6 {
				return filterDNSReplyFamilies(reply, keepIPv4, keepIPv6)
			}
		}
	}
	return reply
}

// resolveLocal sends DNS query through physical NIC to system DNS servers.
// Queries all servers concurrently and returns the first valid response.
func (d *DNSHandler) resolveLocal(q []byte) []byte {
	iface := d.currentPhysIface()
	if iface == nil {
		return nil
	}
	dnsServers := d.getSystemDNSServersCached()
	if len(dnsServers) == 0 {
		return nil
	}
	type result struct {
		data []byte
	}
	ch := make(chan result, len(dnsServers))
	for _, srv := range dnsServers {
		go func(srv string) {
			host, portStr, err := net.SplitHostPort(srv)
			if err != nil {
				ch <- result{}
				return
			}
			port := 53
			if portStr != "" {
				fmt.Sscanf(portStr, "%d", &port)
			}
			conn, err := directDialUDP(host, port, iface)
			if err != nil {
				ch <- result{}
				return
			}
			defer conn.Close()
			conn.SetDeadline(time.Now().Add(3 * time.Second))
			if _, err := conn.Write(q); err != nil {
				ch <- result{}
				return
			}
			resp := make([]byte, 1500)
			n, err := conn.Read(resp)
			if err == nil && n > 12 {
				ch <- result{resp[:n]}
				return
			}
			ch <- result{}
		}(srv)
	}
	// Wait for first valid response or all to fail
	for range dnsServers {
		r := <-ch
		if r.data != nil {
			return r.data
		}
	}
	return nil
}

func (d *DNSHandler) getSystemDNSServersCached() []string {
	iface := d.currentPhysIface()
	if iface == nil {
		return nil
	}
	d.dnsMu.Lock()
	defer d.dnsMu.Unlock()
	if d.dnsIfaceIndex == iface.Index && !d.dnsServersTime.IsZero() && time.Since(d.dnsServersTime) < 30*time.Second {
		return append([]string(nil), d.dnsServers...)
	}
	servers := getSystemDNSServers(iface)
	d.dnsServers = append([]string(nil), servers...)
	d.dnsServersTime = time.Now()
	d.dnsIfaceIndex = iface.Index
	return servers
}

// getSystemDNSServers reads DNS server addresses from the physical interface
func getSystemDNSServers(iface *net.Interface) []string {
	if iface == nil {
		return nil
	}
	var size uint32
	err := windows.GetAdaptersAddresses(windows.AF_UNSPEC, windows.GAA_FLAG_SKIP_ANYCAST|windows.GAA_FLAG_SKIP_MULTICAST|windows.GAA_FLAG_SKIP_FRIENDLY_NAME, 0, nil, &size)
	if err != nil && err != windows.ERROR_BUFFER_OVERFLOW {
		return nil
	}
	buf := make([]byte, size)
	addr := (*windows.IpAdapterAddresses)(unsafe.Pointer(&buf[0]))
	err = windows.GetAdaptersAddresses(windows.AF_UNSPEC, windows.GAA_FLAG_SKIP_ANYCAST|windows.GAA_FLAG_SKIP_MULTICAST|windows.GAA_FLAG_SKIP_FRIENDLY_NAME, 0, addr, &size)
	if err != nil {
		return nil
	}
	var result []string
	seen := make(map[string]bool)
	for a := addr; a != nil; a = a.Next {
		if a.IfIndex != uint32(iface.Index) && a.Ipv6IfIndex != uint32(iface.Index) {
			continue
		}
		for dns := a.FirstDnsServerAddress; dns != nil; dns = dns.Next {
			ip := dns.Address.IP()
			if ip == nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() {
				continue
			}
			addr := net.JoinHostPort(ip.String(), "53")
			if seen[addr] {
				continue
			}
			seen[addr] = true
			result = append(result, addr)
		}
	}
	return result
}

const (
	dohURL        = "https://cloudflare-dns.com/dns-query"
	dohHost       = "cloudflare-dns.com:443"
	dohServerName = "cloudflare-dns.com"

	// 单次解析的总预算。改造前每条查询是 SetDeadline(5s) 的硬上限，这里必须
	// 保持同量级：长连接一旦半开（对端单方面断开、WebSocket 重连后 smux 会话
	// 失效等），请求会一直挂到超时，预算过大就会把所有域名解析拖成十几秒，
	// 浏览器侧直接表现为「网页打不开」。
	dohQueryTimeout = 6 * time.Second
	// 长连接分到的预算，剩余时间留给一次性连接兜底
	dohPersistentTimeout = 3 * time.Second
	// 长连接确认异常后的冷静期，期间直接走一次性连接
	dohCoolDown = 30 * time.Second
)

// dohClient 返回（必要时新建）DoH 长连接客户端。
//
// 改造前每个未命中缓存的域名都要：新建一条 smux 流 → 完整 TLS 握手 → 发一个
// DoH 请求 → 立刻关闭（req.Close = true）。打开 Google / YouTube 这类要解析
// 十几个域名的页面时，握手是串行叠加的，这是「首次打开慢」的主因。
//
// 现在改为维护一个长连接客户端：优先 HTTP/2 多路复用，并发的 A / AAAA 以及
// 不同域名的查询共享同一条连接；即使对端不协商 h2，也会退化成 HTTP/1.1
// keep-alive 复用。注意调用方必须给每次请求单独设超时，这里不设 client.Timeout。
func (d *DNSHandler) dohClient() *http.Client {
	d.dohMu.Lock()
	defer d.dohMu.Unlock()
	if d.dohClientCache != nil {
		return d.dohClientCache
	}
	if d.pool == nil {
		return nil
	}
	pool := d.pool
	d.dohClientCache = &http.Client{
		Transport: &http.Transport{
			Proxy: nil,
			// 自定义拨号：在隧道的 smux 流上完成 TLS，连接交由上层复用
			DialTLSContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				s, _, _, err := pool.openTCPStream(dohHost)
				if err != nil {
					return nil, err
				}
				tc := tls.Client(s, &tls.Config{
					ServerName: dohServerName,
					MinVersion: tls.VersionTLS12,
					// 使用自定义 DialTLSContext 时 transport 不会代劳，
					// 必须自己声明 h2，否则永远协商不到 HTTP/2。
					NextProtos: []string{"h2", "http/1.1"},
				})
				if err := tc.HandshakeContext(ctx); err != nil {
					s.Close()
					return nil, err
				}
				return tc, nil
			},
			ForceAttemptHTTP2:     true,
			TLSHandshakeTimeout:   5 * time.Second,
			MaxIdleConns:          8,
			MaxConnsPerHost:       4,
			MaxIdleConnsPerHost:   2,
			IdleConnTimeout:       60 * time.Second,
			ExpectContinueTimeout: 1 * time.Second,
		},
	}
	return d.dohClientCache
}

// resetDohClient 丢弃当前长连接，下一次查询会重新建连。
func (d *DNSHandler) resetDohClient() {
	d.dohMu.Lock()
	c := d.dohClientCache
	d.dohClientCache = nil
	d.dohMu.Unlock()
	if c != nil {
		c.CloseIdleConnections()
	}
}

// dohPersistentAllowed 报告长连接是否处于可用期（不在冷静期内）。
func (d *DNSHandler) dohPersistentAllowed() bool {
	d.dohMu.Lock()
	defer d.dohMu.Unlock()
	return time.Now().After(d.dohDisableUntil)
}

// markDohBroken 让长连接在冷静期内停用，改用一次性连接。
func (d *DNSHandler) markDohBroken() {
	d.dohMu.Lock()
	d.dohDisableUntil = time.Now().Add(dohCoolDown)
	d.dohMu.Unlock()
}

// warmupDoH 在 TUN 启动后提前把 DoH 连接建好，避免首个域名解析付一次冷启动。
// 预热失败不进冷静期（此时隧道可能还没就绪，属正常现象）。
func (d *DNSHandler) warmupDoH() {
	q := buildDNSQuery(dohServerName, dnsTypeA)
	if len(q) == 0 {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), dohQueryTimeout)
	defer cancel()
	if _, err := d.dohViaPersistent(ctx, q); err == nil {
		log.Printf("[DNS] DoH 长连接预热完成")
	} else {
		d.resetDohClient()
	}
}

// resolveRemote resolves DNS via tunnel DoH to cloudflare-dns.com
func (d *DNSHandler) resolveRemote(q []byte) []byte {
	if d.pool == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), dohQueryTimeout)
	defer cancel()

	// 优先走长连接，但它只拿到总预算的一部分，超时立刻放弃换兜底路径
	if d.dohPersistentAllowed() {
		pctx, pcancel := context.WithTimeout(ctx, dohPersistentTimeout)
		body, err := d.dohViaPersistent(pctx, q)
		pcancel()
		if err == nil {
			return body
		}
		if pctx.Err() != nil {
			// 超时：可能只是这一次慢，丢弃连接让下次重建即可
			d.resetDohClient()
		} else {
			// 连接级错误：长连接确实坏了，进冷静期避免每条查询都空等一遍
			log.Printf("[DNS] DoH 长连接异常（%v），%.0fs 内改用一次性连接", err, dohCoolDown.Seconds())
			d.resetDohClient()
			d.markDohBroken()
		}
	}
	if ctx.Err() != nil {
		return nil
	}
	return d.dohSingleShot(ctx, q)
}

// dohViaPersistent 复用长连接完成一次 DoH 查询。ctx 由调用方限定。
func (d *DNSHandler) dohViaPersistent(ctx context.Context, q []byte) ([]byte, error) {
	client := d.dohClient()
	if client == nil {
		return nil, errors.New("隧道未就绪")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, dohURL, bytes.NewReader(q))
	if err != nil {
		return nil, err
	}
	req.ContentLength = int64(len(q))
	req.Header.Set("Content-Type", "application/dns-message")
	req.Header.Set("Accept", "application/dns-message")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if body, ok := readDoHResponse(resp); ok {
		return body, nil
	}
	return nil, fmt.Errorf("响应异常 status=%d", resp.StatusCode)
}

// dohSingleShot 兜底路径，行为与改造前一致：新建一条流完成一次查询后立即关闭。
func (d *DNSHandler) dohSingleShot(ctx context.Context, q []byte) []byte {
	s, _, _, err := d.pool.openTCPStream(dohHost)
	if err != nil {
		return nil
	}
	defer s.Close()
	tc := tls.Client(s, &tls.Config{ServerName: dohServerName, MinVersion: tls.VersionTLS12})
	if dl, ok := ctx.Deadline(); ok {
		tc.SetDeadline(dl)
	} else {
		tc.SetDeadline(time.Now().Add(dohQueryTimeout))
	}
	if err := tc.Handshake(); err != nil {
		return nil
	}
	defer tc.Close()
	req, err := http.NewRequest(http.MethodPost, dohURL, bytes.NewReader(q))
	if err != nil {
		return nil
	}
	req.ContentLength = int64(len(q))
	req.Header.Set("Content-Type", "application/dns-message")
	req.Header.Set("Accept", "application/dns-message")
	req.Host = dohServerName
	req.Close = true
	if err := req.Write(tc); err != nil {
		return nil
	}
	resp, err := http.ReadResponse(bufio.NewReader(tc), req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	body, _ := readDoHResponse(resp)
	return body
}

// readDoHResponse 读取并校验一次 DoH 响应，返回报文体。
func readDoHResponse(resp *http.Response) ([]byte, bool) {
	if resp.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil, false
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil || len(body) < 12 {
		return nil, false
	}
	return body, true
}

// ====== DNS protocol utility functions ======

func extractDNSName(q []byte) string {
	if len(q) < 12 {
		return "?"
	}
	var p []byte
	pos := 12
	for pos < len(q) {
		b := q[pos]
		if b == 0 {
			break
		}
		if b&0xC0 == 0xC0 {
			break
		}
		l := int(b)
		pos++
		if pos+l > len(q) {
			return string(p)
		}
		if len(p) > 0 {
			p = append(p, '.')
		}
		p = append(p, q[pos:pos+l]...)
		pos += l
	}
	if len(p) == 0 {
		return "."
	}
	return string(p)
}

func unpackDNSHeader(q []byte) (id uint16, flags uint16, qdcount uint16) {
	if len(q) < 12 {
		return
	}
	id = binary.BigEndian.Uint16(q[0:2])
	flags = binary.BigEndian.Uint16(q[2:4])
	qdcount = binary.BigEndian.Uint16(q[4:6])
	return
}

func dnsQuestionType(q []byte) uint16 {
	if len(q) < 12 {
		return 0
	}
	pos := 12
	for pos < len(q) {
		if q[pos] == 0 {
			pos++
			break
		}
		if q[pos]&0xC0 == 0xC0 {
			pos += 2
			break
		}
		l := int(q[pos])
		pos++
		if pos+l > len(q) {
			return 0
		}
		pos += l
	}
	if pos+4 > len(q) {
		return 0
	}
	return binary.BigEndian.Uint16(q[pos : pos+2])
}

func dnsQuestionTypeName(q []byte) string {
	switch dnsQuestionType(q) {
	case dnsTypeA:
		return "A"
	case dnsTypeAAAA:
		return "AAAA"
	default:
		return fmt.Sprintf("TYPE%d", dnsQuestionType(q))
	}
}

func servfailReply(q []byte) []byte {
	qEnd := findQuestionEnd(q)
	sf := make([]byte, qEnd)
	copy(sf, q[:qEnd])
	sf[2] = 0x81
	sf[3] = 0x82
	for i := 6; i < 12; i += 2 {
		sf[i] = 0
		sf[i+1] = 0
	}
	return sf
}

func dnsTypeName(rrType uint16) string {
	switch rrType {
	case dnsTypeA:
		return "A"
	case dnsTypeAAAA:
		return "AAAA"
	default:
		return fmt.Sprintf("TYPE%d", rrType)
	}
}

func logDNSResult(domain string, q, reply []byte, route string, elapsed time.Duration) {
	answers := extractDNSAnswerIPs(reply)
	action, reason := dnsLogParts(route)
	log.Printf("[DNS][%s] %s %s -> %s (%s, %v)", action, domain, dnsQuestionTypeName(q), answers, reason, elapsed)
}

func logDNSServFail(domain string, q []byte, route string, elapsed time.Duration) {
	action, reason := dnsLogParts(route)
	log.Printf("[DNS][%s] %s %s -> SERVFAIL (%s, %v)", action, domain, dnsQuestionTypeName(q), reason, elapsed)
}

func dnsRouteLabel(decision RouteDecision, matchedRule string) string {
	if matchedRule == "" {
		matchedRule = "default"
	}
	if decision == DecisionDirect {
		return "direct:" + matchedRule
	}
	return "proxy:" + matchedRule
}

func dnsLogParts(route string) (action string, reason string) {
	switch {
	case route == "cache":
		return "cache", "hit"
	case strings.HasPrefix(route, "direct:"):
		return "direct", strings.TrimPrefix(route, "direct:")
	case strings.HasPrefix(route, "proxy:"):
		return "proxy", strings.TrimPrefix(route, "proxy:")
	case route == "remote":
		return "proxy", "remote"
	case route != "":
		return "proxy", route
	default:
		return "proxy", "default"
	}
}

func refreshDirectDomainFamily(domain string, rrType uint16) []string {
	if dnsHandlerInstance == nil || domain == "" {
		return nil
	}
	q := buildDNSQuery(domain, rrType)
	if len(q) == 0 {
		return nil
	}
	reply := dnsHandlerInstance.resolveLocal(q)
	if len(reply) < 12 {
		return nil
	}
	cacheDNSReply(domain, reply)
	return lookupIPsByDomainFamily(domain, rrType == dnsTypeAAAA)
}

func skipDNSName(msg []byte, pos int) (int, bool) {
	for pos < len(msg) {
		b := msg[pos]
		if b == 0 {
			return pos + 1, true
		}
		if b&0xC0 == 0xC0 {
			if pos+2 > len(msg) {
				return 0, false
			}
			return pos + 2, true
		}
		pos++
		if pos+int(b) > len(msg) {
			return 0, false
		}
		pos += int(b)
	}
	return 0, false
}

func skipDNSQuestions(msg []byte, pos int, qdcount int) (int, bool) {
	for i := 0; i < qdcount; i++ {
		var ok bool
		pos, ok = skipDNSName(msg, pos)
		if !ok || pos+4 > len(msg) {
			return 0, false
		}
		pos += 4
	}
	return pos, true
}

func extractDNSAnswerIPs(reply []byte) string {
	if len(reply) < 12 {
		return "?"
	}
	qdcount := int(binary.BigEndian.Uint16(reply[4:6]))
	pos, ok := skipDNSQuestions(reply, 12, qdcount)
	if !ok {
		return "?"
	}
	var ips []string
	totalRR := int(binary.BigEndian.Uint16(reply[6:8])) +
		int(binary.BigEndian.Uint16(reply[8:10])) +
		int(binary.BigEndian.Uint16(reply[10:12]))
	rrCount := 0
	for i := 0; i < totalRR; i++ {
		if pos+12 > len(reply) {
			break
		}
		if reply[pos]&0xC0 == 0xC0 {
			pos += 2
		} else {
			for pos < len(reply) && reply[pos] != 0 {
				l := int(reply[pos])
				pos++
				if pos+l > len(reply) {
					return "?"
				}
				pos += l
			}
			pos++
		}
		if pos+10 > len(reply) {
			break
		}
		atype := binary.BigEndian.Uint16(reply[pos:])
		dlen := int(binary.BigEndian.Uint16(reply[pos+8:]))
		pos += 10
		if pos+dlen > len(reply) {
			break
		}
		rrCount++
		if atype == 1 && dlen == 4 {
			ips = append(ips, net.IP(reply[pos:pos+4]).String())
		} else if atype == 28 && dlen == 16 {
			ips = append(ips, net.IP(reply[pos:pos+16]).String())
		}
		pos += dlen
	}
	if len(ips) > 0 {
		return strings.Join(ips, ",")
	}
	if rrCount > 0 {
		return fmt.Sprintf("rr=%d", rrCount)
	}
	return "no-answer"
}

func filterDNSReply(reply []byte, strategy byte) []byte {
	switch strategy {
	case IPStrategyIPv4Only:
		return filterDNSReplyFamilies(reply, true, false)
	case IPStrategyIPv6Only:
		return filterDNSReplyFamilies(reply, false, true)
	default:
		return reply
	}
}

func filterDNSReplyFamilies(reply []byte, hasIPv4, hasIPv6 bool) []byte {
	if len(reply) < 12 {
		return reply
	}

	out := make([]byte, len(reply))
	copy(out, reply)

	pos := 12
	for pos < len(out) {
		if out[pos] == 0 {
			pos++
			break
		}
		if out[pos]&0xC0 == 0xC0 {
			pos += 2
			break
		}
		l := int(out[pos])
		pos++
		if pos+l > len(out) {
			return reply
		}
		pos += l
	}
	if pos+4 > len(out) {
		return reply
	}
	pos += 4

	origAncount := int(binary.BigEndian.Uint16(out[6:8]))
	if origAncount == 0 {
		return reply
	}

	var newAnswers []byte
	newAncount := uint16(0)
	for i := 0; i < origAncount; i++ {
		if pos+12 > len(out) {
			break
		}
		answerStart := pos
		if out[pos]&0xC0 == 0xC0 {
			pos += 2
		} else {
			for pos < len(out) && out[pos] != 0 {
				l := int(out[pos])
				pos++
				if pos+l > len(out) {
					return reply
				}
				pos += l
			}
			pos++
		}
		if pos+10 > len(out) {
			break
		}
		atype := binary.BigEndian.Uint16(out[pos:])
		dlen := int(binary.BigEndian.Uint16(out[pos+8:]))
		pos += 10
		if pos+dlen > len(out) {
			break
		}
		keep := false
		if atype == 1 {
			keep = hasIPv4
		} else if atype == 28 {
			keep = hasIPv6
		} else {
			keep = true
		}
		if keep {
			seg := make([]byte, pos+dlen-answerStart)
			copy(seg, out[answerStart:pos+dlen])
			newAnswers = append(newAnswers, seg...)
			newAncount++
		}
		pos += dlen
	}

	hdr := make([]byte, 12)
	copy(hdr, out[:12])
	binary.BigEndian.PutUint16(hdr[6:8], newAncount)
	binary.BigEndian.PutUint16(hdr[8:10], 0)
	binary.BigEndian.PutUint16(hdr[10:12], 0)

	qpos := 12
	for qpos < len(out) {
		if out[qpos] == 0 {
			qpos += 5
			break
		}
		if out[qpos]&0xC0 == 0xC0 {
			qpos += 6
			break
		}
		l := int(out[qpos])
		qpos++
		qpos += l
	}

	var result []byte
	result = append(result, hdr...)
	result = append(result, out[12:qpos]...)
	result = append(result, newAnswers...)
	return result
}
