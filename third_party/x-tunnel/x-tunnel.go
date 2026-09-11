package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/binary"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"
	"github.com/xtaci/smux"
)

// physIfaceIndex 是物理网卡的接口索引，用于 IP_UNICAST_IF 绑定
// x-tunnel 自身的 WebSocket 连接通过此索引绕过 TUN
var physIfaceIndex int = -1
var physIfaceMu sync.RWMutex

func getPhysIfaceIndex() int {
	physIfaceMu.RLock()
	defer physIfaceMu.RUnlock()
	return physIfaceIndex
}

// bindSocketToPhysNIC 将 socket 绑定到物理网卡，使其绕过 TUN 路由。
//
// 物理网卡绑定（-tun 下 physIfaceIndex > 0 才生效）与 -ip 是两回事：
//   - -ip 只决定"目标服务器解析到哪个 IP"；
//   - 物理网卡绑定决定"出口接口"（TUN 模式下让控制连接绕开 TUN）。
//
// 但二者共用 dialContext 的拨号路径，当 -ip 指向 loopback（如本机
// 127.0.0.1）时，对 socket 套 IP_UNICAST_IF = WLAN 会让 Windows 在
// 物理网卡接口上去 connectex 一个回环地址，路由层直接拒绝并抛
// "connectex: The requested address is not valid in its context"。
// loopback 流量不经 TUN 也不经任何物理出口接口，物理绑定这一层对
// 回环目标必须跳过（这跟 -ip 无关，换成 -ip 1.2.3.4 时该绑的继续绑）。
func bindSocketToPhysNIC(network, address string, c syscall.RawConn) error {
	ifaceIndex := getPhysIfaceIndex()
	if ifaceIndex <= 0 {
		return nil
	}
	switch network {
	case "tcp4", "udp4", "tcp6", "udp6":
	default:
		return nil
	}
	// 回环目标免绑定：这是 -tun + -ip 127.0.0.1 同用时拨号报错的关键修正。
	// 非回环（含 -ip 1.2.3.4 这种公网定向）保持原绑定行为不变。
	if isLoopbackAddress(address) {
		return nil
	}
	isIPv6 := network == "tcp6" || network == "udp6"
	var sockErr error
	err := c.Control(func(fd uintptr) {
		sockErr = setUnicastIF(fd, ifaceIndex, isIPv6)
	})
	if err != nil {
		return err
	}
	return sockErr
}

// isLoopbackAddress 判断 host:port 形式的对端地址是否指向本机回环。
// 解析失败或非 IP 形式（域名）一律返回 false，保持原有绑定行为不变。
func isLoopbackAddress(address string) bool {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return false
	}
	// 容许带方括号的 IPv6 形式，例如 [::1]:443
	host = strings.Trim(host, "[]")
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback()
	}
	return false
}

type GlobalConfig struct {
	DialTimeout        time.Duration
	WSHandshakeTimeout time.Duration
	ReconnectDelay     time.Duration
	RTTProbeTimeout    time.Duration

	ReadBuf int
}

var cfg = GlobalConfig{
	DialTimeout:        3 * time.Second,
	WSHandshakeTimeout: 5 * time.Second,
	ReconnectDelay:     1 * time.Second,
	RTTProbeTimeout:    2 * time.Second,
	ReadBuf:            256 * 1024, // 对齐 Mac v1.2.9：64K→256K。读缓冲太小会放大每次读取的固定开销，压低大流量（YouTube）吞吐上限；io.CopyBuffer 侧早已是 256K
}

var bufPool = sync.Pool{New: func() any { b := make([]byte, 64*1024); return &b }}

// ======================== 全局参数 ========================

var (
	listenAddr       string
	forwardAddr      string
	ipAddr           string
	udpBlockPortsStr string
	certFile         string
	keyFile          string
	token            string
	cidrs            string
	connectionNum    int
	insecure         bool
	ips              string

	dnsServer string
	echDomain string
	fallback  bool

	echListMu sync.RWMutex
	echList   []byte
	refreshMu sync.Mutex

	echPool *ECHPool

	clientID      string
	udpBlockPorts map[int]struct{}

	socks5Config *SOCKS5Config
	ipStrategy   byte
)

const (
	IPStrategyDefault  byte = 0
	IPStrategyIPv4Only byte = 1
	IPStrategyIPv6Only byte = 2
	IPStrategyPv4Pv6   byte = 3
	IPStrategyPv6Pv4   byte = 4
)

type SOCKS5Config struct {
	Host     string
	Username string
	Password string
}

func init() {
	flag.StringVar(&listenAddr, "l", "", "监听地址 (支持多个，用逗号分隔)\n格式示例:\n  socks5://[user:pass@]0.0.0.0:1080\n  http://[user:pass@]0.0.0.0:8080\n  tcp://0.0.0.0:2000/1.2.3.4:22\n  ws://0.0.0.0:80/path (服务端模式)\n  wss://0.0.0.0:443/path (服务端模式)")
	flag.StringVar(&forwardAddr, "f", "", "服务地址/代理地址 (客户端模式: ws://host:port 或 wss://host:port | 服务端模式: socks5://[user:pass@]host:port)")
	flag.StringVar(&ipAddr, "ip", "", "指定解析的IP地址（仅客户端：将 ws/wss 主机名定向到该 IP 连接，多个IP用逗号分隔）")
	flag.StringVar(&udpBlockPortsStr, "block", "443", "客户端拦截 UDP 端口列表，逗号分隔，如 443,8443")
	flag.BoolVar(&insecure, "insecure", false, "客户端忽略证书校验（仅 wss 模式生效）")
	flag.StringVar(&certFile, "cert", "", "TLS证书文件路径（默认:自动生成，仅服务端）")
	flag.StringVar(&keyFile, "key", "", "TLS密钥文件路径（默认:自动生成，仅服务端）")
	flag.StringVar(&token, "token", "", "身份验证令牌（WebSocket 子协议）")
	flag.StringVar(&cidrs, "cidr", "0.0.0.0/0,::/0", "允许的来源 IP 范围 (CIDR),多个范围用逗号分隔")
	flag.StringVar(&dnsServer, "dns", "https://doh.pub/dns-query", "查询 ECH 公钥所用的 DNS 服务器 (支持 DoH 或 UDP，仅 wss 模式生效)")
	flag.StringVar(&echDomain, "ech", "cloudflare-ech.com", "用于查询 ECH 公钥的域名（仅 wss 模式生效）")
	flag.BoolVar(&fallback, "fallback", false, "是否禁用 ECH 并回落到普通 TLS 1.3（仅 wss 模式生效，默认 false）")
	flag.IntVar(&connectionNum, "n", 3, "每个IP建立的WebSocket连接数量")
	flag.StringVar(&ips, "ips", "", "IP 访问策略（TUN 默认双栈；域名出口按该策略解析）\n 4: 仅IPv4\n 6: 仅IPv6\n 4,6: 域名由服务端解析时 IPv4优先\n 6,4: 域名由服务端解析时 IPv6优先")
}

func main() {
	flag.Parse()

	if listenAddr == "" && !tunMode {
		flag.Usage()
		return
	}

	ipStrategy = parseIPStrategy(ips)
	if tunMode && strings.TrimSpace(ips) == "" {
		// 默认启用双栈：即使客户端没有 IPv6，代理模式仍可通过服务端访问 IPv6 站点。
		// 直连 IPv6 时若本地无公网 IPv6，会自动 fallback 到 IPv4 直连。
		ipStrategy = IPStrategyDefault
	}
	if ips != "" {
		log.Printf("[客户端] IP 访问策略: %s (code: %d)", ips, ipStrategy)
	}

	var targetIPs []string
	if ipAddr != "" {
		parts := strings.Split(ipAddr, ",")
		for _, p := range parts {
			trimmed := strings.TrimSpace(p)
			if trimmed != "" {
				targetIPs = append(targetIPs, trimmed)
			}
		}
	}

	listeners := strings.Split(listenAddr, ",")
	isServer := false
	for _, l := range listeners {
		l = strings.TrimSpace(l)
		if strings.HasPrefix(l, "ws://") || strings.HasPrefix(l, "wss://") {
			isServer = true
			listenAddr = l
			break
		}
	}

	// ================= 服务端模式 =================
	if isServer {
		if forwardAddr != "" {
			config, err := parseSOCKS5Addr(forwardAddr)
			if err != nil {
				log.Fatalf("[服务端] 解析SOCKS5代理地址失败: %v", err)
			}
			socks5Config = config
			log.Printf("[服务端] 使用SOCKS5前置代理: %s", config.Host)
			if config.Username != "" {
				log.Printf("[服务端] SOCKS5代理认证已启用")
			}
		} else {
			log.Printf("[服务端] 直连模式（未配置SOCKS5代理）")
		}
		runWebSocketServer(listenAddr)
		return
	}

	// ================= 客户端模式 =================
	if forwardAddr == "" {
		log.Fatalf("[客户端] 客户端模式必须指定服务地址 (-f ws:// 或 -f wss://)")
	}
	if connectionNum <= 0 {
		log.Fatalf("[客户端] 参数 -n 必须大于 0 (当前: %d)", connectionNum)
	}

	forwardURL, err := url.Parse(forwardAddr)
	if err != nil {
		log.Fatalf("[客户端] 无效的服务地址: %v", err)
	}
	scheme := strings.ToLower(forwardURL.Scheme)
	if scheme != "wss" && scheme != "ws" {
		log.Fatalf("[客户端] 仅支持 ws:// 或 wss:// 协议 (当前: %s)", forwardURL.Scheme)
	}

	if tunMode {
		// 先准备物理网卡索引，供 ECH 查询和首批 WebSocket 连接绑定使用。
		// 后续仅在当前索引失效时才重新探测，而不是每次重连都重探测。
		ensurePhysIfaceIndex()
		if idx := getPhysIfaceIndex(); idx > 0 {
			log.Printf("[客户端] 物理网卡接口索引: %d (WebSocket/ECH 连接将绕过 TUN)", idx)
		} else {
			log.Printf("[客户端] 探测物理网卡索引失败")
		}
	}

	if scheme == "wss" {
		if insecure {
			if !fallback {
				fallback = true
				log.Printf("[客户端] wss 模式且启用不校验证书（insecure）：已自动禁用 ECH（fallback）")
			} else {
				log.Printf("[客户端] wss 模式且启用不校验证书（insecure）")
			}
		}
		if !fallback {
			if err := prepareECH(); err != nil {
				log.Fatalf("[客户端] 获取 ECH 公钥失败: %v", err)
			}
		} else {
			log.Printf("[客户端] fallback 模式已启用：禁用 ECH，使用标准 TLS 1.3")
		}
	} else {
		if insecure {
			log.Printf("[客户端] ws 模式已忽略 insecure 参数")
		}
		if fallback {
			log.Printf("[客户端] ws 模式已忽略 fallback/ECH 参数")
		}
	}

	if udpBlockPortsStr != "" {
		udpBlockPorts = make(map[int]struct{})
		parts := strings.Split(udpBlockPortsStr, ",")
		for _, p := range parts {
			pp := strings.TrimSpace(p)
			if pp == "" {
				continue
			}
			var port int
			_, _ = fmt.Sscanf(pp, "%d", &port)
			if port > 0 && port < 65536 {
				udpBlockPorts[port] = struct{}{}
			}
		}
	}

	clientID = uuid.NewString()
	log.Printf("[客户端] 客户端ID: %s", clientID)

	echPool = NewECHPool(forwardAddr, connectionNum, targetIPs, clientID)
	// 本地分流 + 服务端协议判定（对齐 Mac v1.2.9）：本地代理也过 -route 规则，
	// 简易协议（Worker-ECH.js）→ 每连接新建 WS，不预热 smux 池。
	initLocalRouting()
	detectServerProtocol()
	if serverProtocol.Load() != protoSimple {
		echPool.Start()
	}

	// ================= TUN 模式（仅在 Windows 启用） =================
	if tunMode {
		// 等待至少一条通道就绪后再启动 TUN
		// 避免 TUN 路由建立后所有流量被劫持但 smux 通道又不可用
		log.Printf("[TUN] 等待 smux 通道就绪（最长 60 秒）...")
		if echPool.WaitForChannelReady(60 * time.Second) {
			log.Printf("[TUN] 通道已就绪，启动 TUN 模式")
		} else {
			log.Printf("[TUN] 通道就绪超时（60s），仍启动 TUN（后续流量将回退直连）")
		}

		// Load geo data from files specified by -geoip / -geosite flags
		loadGeoIP()
		loadGeoSite()

		if forwardAddr == "" {
			log.Fatalf("[TUN] TUN 模式必须指定服务地址 (-f ws:// 或 wss://)")
		}

		// Build TUN config
		routes := []string{"0.0.0.0/0"}
		tunGatewayCIDR, tunDNSIP := chooseTunIPv4Config()
		dnsServers := []string{tunDNSIP}
		gateways := []string{tunGatewayCIDR}

		// TUN 默认启用双栈；只有显式 -ips 4 才禁用 IPv6。
		enableIPv6 := ipStrategy != IPStrategyIPv4Only
		if enableIPv6 {
			gateways = append(gateways, "fdfe:dcba:9876::1/126")
			routes = append(routes, "::/0")
		}

		tunCfg := &TunConfig{
			Name:                   tunName,
			MTU:                    tunMTU,
			Gateway:                gateways,
			DNS:                    dnsServers,
			AutoSystemRoutingTable: routes,
		}
		log.Printf("[TUN] 配置: device=%s, mtu=%d, addr=%v, routes=%v",
			tunCfg.Name, tunCfg.MTU, tunCfg.Gateway, tunCfg.AutoSystemRoutingTable)

		// 在启动 TUN 之前，先启动 -l 指定的本地监听（socks5/http）
		// 因为 StartTun 内部 select{} 会永久阻塞，之后的代码不会执行
		for _, listenerRule := range listeners {
			rule := strings.TrimSpace(listenerRule)
			if rule == "" {
				continue
			}
			if strings.HasPrefix(rule, "socks5://") {
				go runSOCKS5Listener(rule)
			} else if strings.HasPrefix(rule, "http://") {
				go runHTTPListener(rule)
			} else if strings.HasPrefix(rule, "tcp://") {
				go runTCPListener(rule)
			}
		}

		if err := StartTun(tunCfg); err != nil {
			log.Fatalf("[TUN] TUN 启动失败: %v", err)
		}
	}

	// 非 TUN 模式的本地监听（TUN 模式的已在上面启动）
	if !tunMode {
		var wg sync.WaitGroup
		for _, listenerRule := range listeners {
			rule := strings.TrimSpace(listenerRule)
			if rule == "" {
				continue
			}

			if strings.HasPrefix(rule, "tcp://") {
				wg.Add(1)
				go func(r string) {
					defer wg.Done()
					runTCPListener(r)
				}(rule)
			} else if strings.HasPrefix(rule, "socks5://") {
				wg.Add(1)
				go func(r string) {
					defer wg.Done()
					runSOCKS5Listener(r)
				}(rule)
			} else if strings.HasPrefix(rule, "http://") {
				wg.Add(1)
				go func(r string) {
					defer wg.Done()
					runHTTPListener(r)
				}(rule)
			} else {
				log.Printf("[客户端] 忽略未知协议的监听地址: %s", rule)
			}
		}
		wg.Wait()
	} else {
		// TUN 模式下 StartTun 内部 select{} 阻塞，这里也阻塞主 goroutine
		select {}
	}
}

func parseIPStrategy(s string) byte {
	s = strings.ReplaceAll(strings.TrimSpace(s), " ", "")
	switch s {
	case "4":
		return IPStrategyIPv4Only
	case "6":
		return IPStrategyIPv6Only
	case "4,6":
		return IPStrategyPv4Pv6
	case "6,4":
		return IPStrategyPv6Pv4
	default:
		return IPStrategyDefault
	}
}

type wsNetConn struct {
	ws       *websocket.Conn
	readMu   sync.Mutex
	writeMu  sync.Mutex
	reader   io.Reader
	deadCh   chan struct{}
	deadMu   sync.Mutex
	deadErr  error
	deadOnce sync.Once
}

func newWSNetConn(ws *websocket.Conn) *wsNetConn {
	return &wsNetConn{ws: ws, deadCh: make(chan struct{})}
}

func (c *wsNetConn) signalDead(err error) {
	if err == nil {
		return
	}
	c.deadMu.Lock()
	if c.deadErr == nil {
		c.deadErr = err
	}
	c.deadMu.Unlock()
	c.deadOnce.Do(func() {
		close(c.deadCh)
	})
}

func (c *wsNetConn) Dead() <-chan struct{} { return c.deadCh }

func (c *wsNetConn) DeadErr() error {
	c.deadMu.Lock()
	defer c.deadMu.Unlock()
	return c.deadErr
}

func (c *wsNetConn) Read(p []byte) (int, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()
	for {
		if c.reader == nil {
			mt, r, err := c.ws.NextReader()
			if err != nil {
				c.signalDead(err)
				return 0, err
			}
			if mt != websocket.BinaryMessage {
				continue
			}
			c.reader = r
		}
		n, err := c.reader.Read(p)
		if errors.Is(err, io.EOF) {
			c.reader = nil
			if n > 0 {
				return n, nil
			}
			continue
		}
		if err != nil {
			c.signalDead(err)
		}
		return n, err
	}
}

func (c *wsNetConn) Write(p []byte) (int, error) {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	w, err := c.ws.NextWriter(websocket.BinaryMessage)
	if err != nil {
		c.signalDead(err)
		return 0, err
	}
	n, writeErr := w.Write(p)
	closeErr := w.Close()
	if writeErr != nil {
		c.signalDead(writeErr)
		return n, writeErr
	}
	if closeErr != nil {
		c.signalDead(closeErr)
		return n, closeErr
	}
	return n, nil
}

func (c *wsNetConn) Close() error {
	err := c.ws.Close()
	if err != nil {
		c.signalDead(err)
	} else {
		c.signalDead(io.EOF)
	}
	return err
}

func (c *wsNetConn) LocalAddr() net.Addr {
	if nc := c.ws.UnderlyingConn(); nc != nil {
		return nc.LocalAddr()
	}
	return nil
}

func (c *wsNetConn) RemoteAddr() net.Addr {
	if nc := c.ws.UnderlyingConn(); nc != nil {
		return nc.RemoteAddr()
	}
	return nil
}

func (c *wsNetConn) SetDeadline(t time.Time) error {
	if err := c.ws.SetReadDeadline(t); err != nil {
		return err
	}
	return c.ws.SetWriteDeadline(t)
}

func (c *wsNetConn) SetReadDeadline(t time.Time) error { return c.ws.SetReadDeadline(t) }

func (c *wsNetConn) SetWriteDeadline(t time.Time) error { return c.ws.SetWriteDeadline(t) }

const (
	streamKindTCP  byte = 1
	streamKindUDP  byte = 2
	streamKindPing byte = 3
)

// ======================== SOCKS5 辅助函数 ========================

func parseSOCKS5Addr(addr string) (*SOCKS5Config, error) {
	addr = strings.TrimPrefix(addr, "socks5://")
	config := &SOCKS5Config{}

	if strings.Contains(addr, "@") {
		parts := strings.SplitN(addr, "@", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("无效的SOCKS5地址格式")
		}
		auth := parts[0]
		if strings.Contains(auth, ":") {
			authParts := strings.SplitN(auth, ":", 2)
			config.Username = authParts[0]
			config.Password = authParts[1]
		}
		config.Host = parts[1]
	} else {
		config.Host = addr
	}
	return config, nil
}

func dialViaSocks5(network, addr string) (net.Conn, error) {
	if socks5Config == nil {
		return net.DialTimeout(network, addr, cfg.DialTimeout)
	}
	proxyConn, err := net.DialTimeout("tcp", socks5Config.Host, cfg.DialTimeout)
	if err != nil {
		return nil, fmt.Errorf("连接SOCKS5代理失败: %v", err)
	}
	if err := socks5Handshake(proxyConn, socks5Config); err != nil {
		proxyConn.Close()
		return nil, fmt.Errorf("SOCKS5握手失败: %v", err)
	}
	if err := socks5Connect(proxyConn, addr); err != nil {
		proxyConn.Close()
		return nil, fmt.Errorf("SOCKS5 CONNECT失败: %v", err)
	}
	return proxyConn, nil
}

func socks5Handshake(conn net.Conn, config *SOCKS5Config) error {
	var methods []byte
	if config.Username != "" && config.Password != "" {
		methods = []byte{0x00, 0x02}
	} else {
		methods = []byte{0x00}
	}
	greeting := make([]byte, 2+len(methods))
	greeting[0], greeting[1] = 0x05, byte(len(methods))
	copy(greeting[2:], methods)

	if _, err := conn.Write(greeting); err != nil {
		return err
	}
	response := make([]byte, 2)
	if _, err := io.ReadFull(conn, response); err != nil {
		return err
	}
	if response[0] != 0x05 {
		return fmt.Errorf("SOCKS 版本错误: %d", response[0])
	}
	switch response[1] {
	case 0x00:
		return nil
	case 0x02:
		return socks5UserPassAuthSrv(conn, config.Username, config.Password)
	case 0xFF:
		return errors.New("服务器不接受认证")
	default:
		return fmt.Errorf("认证方法错误: %d", response[1])
	}
}

func socks5UserPassAuthSrv(conn net.Conn, username, password string) error {
	authReq := make([]byte, 3+len(username)+len(password))
	authReq[0], authReq[1] = 0x01, byte(len(username))
	copy(authReq[2:], username)
	authReq[2+len(username)] = byte(len(password))
	copy(authReq[3+len(username):], password)

	if _, err := conn.Write(authReq); err != nil {
		return err
	}
	response := make([]byte, 2)
	if _, err := io.ReadFull(conn, response); err != nil {
		return err
	}
	if response[1] != 0x00 {
		return errors.New("认证失败")
	}
	return nil
}

func socks5Connect(conn net.Conn, addr string) error {
	host, portStr, err := net.SplitHostPort(addr)
	if err != nil {
		return err
	}
	port := 0
	fmt.Sscanf(portStr, "%d", &port)

	var request []byte
	ip := net.ParseIP(host)
	if ip != nil {
		if ip4 := ip.To4(); ip4 != nil {
			request = make([]byte, 10)
			request[0], request[1], request[2], request[3] = 0x05, 0x01, 0x00, 0x01
			copy(request[4:8], ip4)
			request[8], request[9] = byte(port>>8), byte(port)
		} else {
			request = make([]byte, 22)
			request[0], request[1], request[2], request[3] = 0x05, 0x01, 0x00, 0x04
			copy(request[4:20], ip)
			request[20], request[21] = byte(port>>8), byte(port)
		}
	} else {
		request = make([]byte, 7+len(host))
		request[0], request[1], request[2], request[3] = 0x05, 0x01, 0x00, 0x03
		request[4] = byte(len(host))
		copy(request[5:], host)
		request[5+len(host)], request[6+len(host)] = byte(port>>8), byte(port)
	}

	if _, err := conn.Write(request); err != nil {
		return err
	}
	response := make([]byte, 4)
	if _, err := io.ReadFull(conn, response); err != nil {
		return err
	}
	if response[1] != 0x00 {
		return fmt.Errorf("状态码: %d", response[1])
	}
	switch response[3] {
	case 0x01:
		_, _ = io.ReadFull(conn, make([]byte, 6))
	case 0x03:
		lenBuf := make([]byte, 1)
		if _, err := io.ReadFull(conn, lenBuf); err != nil {
			return err
		}
		_, _ = io.ReadFull(conn, make([]byte, int(lenBuf[0])+2))
	case 0x04:
		_, _ = io.ReadFull(conn, make([]byte, 18))
	}
	return nil
}

// ======================== UDP Relayer (服务端用) ========================

type UDPRelayer interface {
	Read(buffer []byte) (int, *net.UDPAddr, error)
	Write(data []byte) (int, error)
	SetReadDeadline(t time.Time) error
	Close() error
}

type DirectUDPRelayer struct {
	conn   *net.UDPConn
	target *net.UDPAddr
}

func (d *DirectUDPRelayer) Read(buffer []byte) (int, *net.UDPAddr, error) {
	return d.conn.ReadFromUDP(buffer)
}
func (d *DirectUDPRelayer) Write(data []byte) (int, error)    { return d.conn.WriteToUDP(data, d.target) }
func (d *DirectUDPRelayer) SetReadDeadline(t time.Time) error { return d.conn.SetReadDeadline(t) }
func (d *DirectUDPRelayer) Close() error                      { return d.conn.Close() }

type SOCKS5UDPRelay struct {
	tcpConn    net.Conn
	udpConn    *net.UDPConn
	relayAddr  *net.UDPAddr
	targetAddr *net.UDPAddr
	mu         sync.Mutex
	closed     bool
}

func newSOCKS5UDPRelay(targetAddr string) (*SOCKS5UDPRelay, error) {
	if socks5Config == nil {
		return nil, errors.New("SOCKS5配置为空")
	}
	tcpConn, err := net.DialTimeout("tcp", socks5Config.Host, cfg.DialTimeout)
	if err != nil {
		return nil, err
	}
	if err := socks5Handshake(tcpConn, socks5Config); err != nil {
		tcpConn.Close()
		return nil, err
	}
	req := []byte{0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0}
	if _, err := tcpConn.Write(req); err != nil {
		tcpConn.Close()
		return nil, err
	}
	resp := make([]byte, 4)
	if _, err := io.ReadFull(tcpConn, resp); err != nil {
		tcpConn.Close()
		return nil, err
	}
	if resp[1] != 0x00 {
		tcpConn.Close()
		return nil, fmt.Errorf("UDP ASSOCIATE拒绝: %d", resp[1])
	}
	var relayHost string
	switch resp[3] {
	case 0x01:
		ipBuf := make([]byte, 4)
		if _, err := io.ReadFull(tcpConn, ipBuf); err != nil {
			tcpConn.Close()
			return nil, err
		}
		relayHost = net.IP(ipBuf).String()
	case 0x03:
		lenBuf := make([]byte, 1)
		if _, err := io.ReadFull(tcpConn, lenBuf); err != nil {
			tcpConn.Close()
			return nil, err
		}
		domainBuf := make([]byte, lenBuf[0])
		if _, err := io.ReadFull(tcpConn, domainBuf); err != nil {
			tcpConn.Close()
			return nil, err
		}
		relayHost = string(domainBuf)
	case 0x04:
		ipBuf := make([]byte, 16)
		if _, err := io.ReadFull(tcpConn, ipBuf); err != nil {
			tcpConn.Close()
			return nil, err
		}
		relayHost = net.IP(ipBuf).String()
	}
	portBuf := make([]byte, 2)
	if _, err := io.ReadFull(tcpConn, portBuf); err != nil {
		tcpConn.Close()
		return nil, err
	}
	relayPort := int(portBuf[0])<<8 | int(portBuf[1])

	if relayHost == "0.0.0.0" || relayHost == "::" {
		h, _, _ := net.SplitHostPort(socks5Config.Host)
		relayHost = h
	}
	rAddr, errResolve := net.ResolveUDPAddr("udp", fmt.Sprintf("%s:%d", relayHost, relayPort))
	if errResolve != nil {
		tcpConn.Close()
		return nil, errResolve
	}

	tAddr, errResolve := net.ResolveUDPAddr("udp", targetAddr)
	if errResolve != nil {
		tcpConn.Close()
		return nil, errResolve
	}

	localUDP, errListen := net.ListenUDP("udp", nil)
	if errListen != nil {
		tcpConn.Close()
		return nil, errListen
	}

	log.Printf("[服务端UDP] SOCKS5 UDP中继: %s -> %s", rAddr, targetAddr)
	return &SOCKS5UDPRelay{
		tcpConn:    tcpConn,
		udpConn:    localUDP,
		relayAddr:  rAddr,
		targetAddr: tAddr,
	}, nil
}

func (r *SOCKS5UDPRelay) Write(data []byte) (int, error) {
	if r == nil || r.udpConn == nil || r.relayAddr == nil || r.targetAddr == nil {
		return 0, errors.New("SOCKS5 UDP relay 未初始化")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return 0, errors.New("closed")
	}
	pkt := buildSOCKS5UDPPacketData(r.targetAddr, data)
	return r.udpConn.WriteToUDP(pkt, r.relayAddr)
}

func (r *SOCKS5UDPRelay) Read(buffer []byte) (int, *net.UDPAddr, error) {
	if r == nil || r.udpConn == nil {
		return 0, nil, errors.New("SOCKS5 UDP relay 未初始化")
	}
	if r.closed {
		return 0, nil, errors.New("closed")
	}
	tmpPtr := bufPool.Get().(*[]byte)
	tmp := *tmpPtr
	defer bufPool.Put(tmpPtr)

	n, _, err := r.udpConn.ReadFromUDP(tmp)
	if err != nil {
		return 0, nil, err
	}
	srcAddr, payload, err := parseSOCKS5UDPResp(tmp[:n])
	if err != nil {
		return 0, nil, err
	}
	copy(buffer, payload)
	return len(payload), srcAddr, nil
}

func (r *SOCKS5UDPRelay) SetReadDeadline(t time.Time) error {
	if r == nil || r.udpConn == nil {
		return errors.New("SOCKS5 UDP relay 未初始化")
	}
	return r.udpConn.SetReadDeadline(t)
}

func (r *SOCKS5UDPRelay) Close() error {
	if r == nil {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return nil
	}
	r.closed = true
	_ = r.udpConn.Close()
	_ = r.tcpConn.Close()
	return nil
}

func buildSOCKS5UDPPacketData(target *net.UDPAddr, data []byte) []byte {
	packet := []byte{0x00, 0x00, 0x00}
	if ip4 := target.IP.To4(); ip4 != nil {
		packet = append(packet, 0x01)
		packet = append(packet, ip4...)
	} else {
		packet = append(packet, 0x04)
		packet = append(packet, target.IP...)
	}
	portBytes := make([]byte, 2)
	binary.BigEndian.PutUint16(portBytes, uint16(target.Port))
	packet = append(packet, portBytes...)
	packet = append(packet, data...)
	return packet
}

func parseSOCKS5UDPResp(packet []byte) (*net.UDPAddr, []byte, error) {
	if len(packet) < 10 {
		return nil, nil, fmt.Errorf("数据包过短")
	}
	atyp := packet[3]
	offset := 4
	var host string
	switch atyp {
	case 0x01:
		if offset+4 > len(packet) {
			return nil, nil, fmt.Errorf("IPv4地址长度过短")
		}
		host = net.IP(packet[offset : offset+4]).String()
		offset += 4
	case 0x03:
		if offset+1 > len(packet) {
			return nil, nil, fmt.Errorf("域名长度字段过短")
		}
		l := int(packet[offset])
		offset++
		if offset+l > len(packet) {
			return nil, nil, fmt.Errorf("域名长度不足")
		}
		host = string(packet[offset : offset+l])
		offset += l
	case 0x04:
		if offset+16 > len(packet) {
			return nil, nil, fmt.Errorf("IPv6地址长度过短")
		}
		host = net.IP(packet[offset : offset+16]).String()
		offset += 16
	default:
		return nil, nil, fmt.Errorf("地址类型无效: %d", atyp)
	}
	if offset+2 > len(packet) {
		return nil, nil, fmt.Errorf("端口字段过短")
	}
	port := int(packet[offset])<<8 | int(packet[offset+1])
	offset += 2
	addr, _ := net.ResolveUDPAddr("udp", fmt.Sprintf("%s:%d", host, port))
	if addr == nil {
		return nil, nil, fmt.Errorf("解析地址失败")
	}
	return addr, packet[offset:], nil
}

// ======================== ECH 相关（客户端） ========================

const typeHTTPS = 65

func prepareECH() error {
	for {
		log.Printf("[客户端] DNS查询 ECH: %s -> %s", dnsServer, echDomain)
		echBase64, err := queryHTTPSRecord(echDomain, dnsServer)
		if err != nil {
			log.Printf("[客户端] DNS 查询失败: %v，重试...", err)
			time.Sleep(2 * time.Second)
			continue
		}
		if echBase64 == "" {
			log.Printf("[客户端] 未找到 ECH 参数，重试...")
			time.Sleep(2 * time.Second)
			continue
		}
		raw, err := base64.StdEncoding.DecodeString(echBase64)
		if err != nil {
			log.Printf("[客户端] ECH Base64 解码失败: %v，重试...", err)
			time.Sleep(2 * time.Second)
			continue
		}
		echListMu.Lock()
		echList = raw
		echListMu.Unlock()
		log.Printf("[客户端] ECHConfigList 长度: %d 字节", len(raw))
		return nil
	}
}

func refreshECH() error {
	if fallback {
		return nil
	}

	refreshMu.Lock()
	defer refreshMu.Unlock()
	log.Printf("[客户端] 刷新 ECH 配置...")
	return prepareECH()
}

func getECHList() ([]byte, error) {
	if fallback {
		return nil, nil
	}
	echListMu.RLock()
	defer echListMu.RUnlock()
	if len(echList) == 0 {
		return nil, errors.New("ECH 配置尚未加载")
	}
	return echList, nil
}

// 系统根证书池只加载一次：simple 每连新建时避免每条都重新加载证书。
var cachedRootPool = func() *x509.CertPool {
	roots, err := x509.SystemCertPool()
	if err != nil {
		return nil
	}
	return roots
}()

// TLS 会话缓存（v1.2.9 提速）：同一服务端多条连接复用 TLS 1.3 票证，建连更快。
var tlsSessionCache = tls.NewLRUClientSessionCache(64)

func buildTLSConfigWithECH(serverName string, echList []byte) (*tls.Config, error) {
	roots := cachedRootPool
	if roots == nil {
		var err error
		roots, err = x509.SystemCertPool()
		if err != nil {
			return nil, err
		}
	}
	return &tls.Config{
		MinVersion:                     tls.VersionTLS13,
		ServerName:                     serverName,
		EncryptedClientHelloConfigList: echList,
		EncryptedClientHelloRejectionVerify: func(cs tls.ConnectionState) error {
			return errors.New("服务器拒绝 ECH")
		},
		RootCAs:            roots,
		ClientSessionCache: tlsSessionCache,
	}, nil
}

func buildStandardTLSConfig(serverName string) (*tls.Config, error) {
	roots := cachedRootPool
	if roots == nil {
		var err error
		roots, err = x509.SystemCertPool()
		if err != nil {
			return nil, err
		}
	}
	return &tls.Config{
		MinVersion:         tls.VersionTLS13,
		ServerName:         serverName,
		RootCAs:            roots,
		ClientSessionCache: tlsSessionCache,
		InsecureSkipVerify: insecure, // 修正：fallback/标准TLS也要支持 -insecure
	}, nil
}

func buildUnifiedTLSConfig(serverName string) (*tls.Config, error) {
	if fallback {
		return buildStandardTLSConfig(serverName)
	}
	ech, e := getECHList()
	if e != nil {
		return nil, e
	}
	cfgTLS, err := buildTLSConfigWithECH(serverName, ech)
	if err != nil {
		return nil, err
	}
	cfgTLS.InsecureSkipVerify = insecure
	return cfgTLS, nil
}

// physDNSServers 缓存物理网卡的系统 DNS 服务器，供上游 WebSocket
// 拨号器的 PreferGo 解析器使用。这样解析器只向物理网卡真实 DNS 发起
// 查询，避免 TUN 适配器通过 SetDNS 推入全局列表的网关地址污染 Go
// 解析器的迭代顺序，从而消除三通道断开后重连 i/o timeout 的死锁。
var (
	physDNSMu       sync.Mutex
	physDNSServers  []string
	physDNSIfaceIdx int
	physDNSStamp    time.Time
)

// physicalDNSServers 返回与 physIfaceIndex 对应物理网卡的系统 DNS 服务器
// 列表（"ip:53" 形式），带 30 秒缓存。ifaceIndex <= 0 或取不到任何服务器
// 时返回 nil，调用方应回退到 Go 的默认行为。
func physicalDNSServers() []string {
	idx := getPhysIfaceIndex()
	if idx <= 0 {
		return nil
	}
	physDNSMu.Lock()
	defer physDNSMu.Unlock()
	if physDNSIfaceIdx == idx && !physDNSStamp.IsZero() && time.Since(physDNSStamp) < 30*time.Second {
		return append([]string(nil), physDNSServers...)
	}
	iface, err := net.InterfaceByIndex(idx)
	if err != nil || iface == nil {
		return nil
	}
	servers := getSystemDNSServers(iface)
	physDNSServers = append([]string(nil), servers...)
	physDNSIfaceIdx = idx
	physDNSStamp = time.Now()
	return servers
}

// dialPhysDNS 建立一条绑定到物理网卡、连向给定 DNS 服务器的连接，
// 交给 Go 的 PreferGo 解析器在其上发送/接收 DNS 报文。
//
// 注意：Go 的 PreferGo 解析器在调用 Resolver.Dial 时传入的 network
// 通常是裸 "udp"/"tcp"，而 bindSocketToPhysNIC 的 IP_UNICAST_IF 绑定
// 只对 "udp4"/"udp6"/"tcp4"/"tcp6" 生效。这里按 DNS 服务器地址族把
// network 规范化成带版本的形式，确保真正绑定到物理网卡、绕过 TUN。
func dialPhysDNS(ctx context.Context, network, server string, control func(string, string, syscall.RawConn) error) (net.Conn, error) {
	host, _, err := net.SplitHostPort(server)
	if err != nil {
		return nil, err
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return nil, errors.New("invalid DNS server: " + server)
	}
	v6 := ip.To4() == nil
	if strings.HasPrefix(network, "tcp") {
		if v6 {
			network = "tcp6"
		} else {
			network = "tcp4"
		}
	} else {
		if v6 {
			network = "udp6"
		} else {
			network = "udp4"
		}
	}
	d := &net.Dialer{Timeout: 3 * time.Second, Control: control}
	return d.DialContext(ctx, network, server)
}

// physKeepAlive 是物理出口 TCP 连接的保活周期。
//
// 隧道连接（WSS）在播放器缓冲满之后会长时间没有任何数据。实测这类空闲连接
// 会在约 120 秒时被中间链路（Cloudflare 边缘）回收：内核里并没有任何 120 秒
// 超时，日志里那批“存活时间正好 120 秒”的连接就是这么没的。连接被回收后再
// 拖动进度，就得重新走一遍 DNS + TCP + TLS + WS + CONNECT，体感就是“拖动要
// 等好几秒”。打开保活后，探测包会持续刷新中间设备的空闲计时器。
const physKeepAlive = 30 * time.Second

// sysResolverLogOnce 保证「交回系统解析器」只在首次打印，避免每条连接刷屏。
var sysResolverLogOnce sync.Once

func newPhysicalNetDialer(timeout time.Duration) *net.Dialer {
	control := func(network, address string, rawC syscall.RawConn) error {
		return bindSocketToPhysNIC(network, address, rawC)
	}
	// 非 TUN 模式下 physIfaceIndex 恒为 -1，physicalDNSServers() 恒为空，
	// 自定义解析器实际退化成“把每次查询固定打到 Go 传入的那一个地址上”。
	// 实测那个地址是 IPv6 DNS（2409:8057:2000:6::8），而这台机器的 IPv6
	// 路由并不通 —— 每次查询都要等超时才回退，首包延迟被白白拉长。
	// 物理 DNS 不可用（即非 TUN）时直接交回系统解析器：Windows 走
	// getaddrinfo，自带 IPv4/IPv6 排序与系统 DNS 缓存，比强行走 IPv6 稳得多。
	if getPhysIfaceIndex() <= 0 {
		sysResolverLogOnce.Do(func() {
			log.Printf("[客户端] 未启用 TUN：DNS 交回系统解析器（不再固定走单一 DNS）")
		})
		return &net.Dialer{Timeout: timeout, Control: control, KeepAlive: physKeepAlive}
	}
	resolver := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			// 忽略 Go 从系统全局 DNS 列表传入的 address（可能被 TUN 网关
			// 地址污染），改为显式向物理网卡上发现的 DNS 服务器发起查询。
			servers := physicalDNSServers()
			if len(servers) == 0 {
				// 探测失败或物理网卡未确定，回退到默认行为，避免彻底断网。
				d := &net.Dialer{Timeout: timeout, Control: control}
				return d.DialContext(ctx, network, address)
			}
			var firstErr error
			for _, srv := range servers {
				conn, err := dialPhysDNS(ctx, network, srv, control)
				if err == nil {
					return conn, nil
				}
				if firstErr == nil {
					firstErr = err
				}
			}
			// 全部物理 DNS 都失败：最后再退回一次 Go 原本想用的地址，给
			// 系统全局 DNS（含 DoH/等）一次机会，而不是直接报错。
			d := &net.Dialer{Timeout: timeout, Control: control}
			if conn, err := d.DialContext(ctx, network, address); err == nil {
				return conn, nil
			}
			if firstErr != nil {
				return nil, firstErr
			}
			return nil, errors.New("no physical DNS server available")
		},
	}
	return &net.Dialer{Timeout: timeout, Resolver: resolver, Control: control, KeepAlive: physKeepAlive}
}

func queryHTTPSRecord(domain, dnsServer string) (string, error) {
	if strings.HasPrefix(dnsServer, "http://") || strings.HasPrefix(dnsServer, "https://") {
		return queryDoH(domain, dnsServer)
	}
	return queryDNSUDP(domain, dnsServer)
}

func queryDNSUDP(domain, dnsServer string) (string, error) {
	if !strings.Contains(dnsServer, ":") {
		dnsServer = dnsServer + ":53"
	}

	query := buildDNSQuery(domain, typeHTTPS)

	dialer := newPhysicalNetDialer(2 * time.Second)
	conn, err := dialer.DialContext(context.Background(), "udp", dnsServer)
	if err != nil {
		return "", fmt.Errorf("连接 DNS 服务器失败: %v", err)
	}
	defer conn.Close()

	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))

	if _, err = conn.Write(query); err != nil {
		return "", fmt.Errorf("发送查询失败: %v", err)
	}

	response := make([]byte, 4096)
	n, err := conn.Read(response)
	if err != nil {
		if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
			return "", fmt.Errorf("DNS 查询超时")
		}
		return "", fmt.Errorf("读取 DNS 响应失败: %v", err)
	}
	return parseDNSResponse(response[:n])
}

// dialPhysicalIPv4First 拨号时优先走 IPv4，IPv6 失败/不可达时才退回。
//
// 双栈主机名（如 cloudflare-dns.com 同时有 A / AAAA 记录）在 IPv6 路由
// 不通的网络里，按默认顺序拨号会先连 IPv6 地址——TCP 可能连得上但读数据时被
// 对端 reset（connection reset by peer），DoH 查询就失败了。先强制解析 A 记录
// 拨 IPv4，能绕开这类「半坏」的 IPv6 链路。（移植自 Mac v1.2.9）
func dialPhysicalIPv4First(dialer *net.Dialer, ctx context.Context, network, addr string) (net.Conn, error) {
	// 纯 IP 字面量：不涉及解析，保持原样（IPv6 字面量也能拨）。
	if host, _, err := net.SplitHostPort(addr); err == nil {
		if ip := net.ParseIP(host); ip != nil {
			return dialer.DialContext(ctx, network, addr)
		}
	}
	// 主机名：先尝试强制 IPv4 地址族（tcp4/udp4 只解析 A 记录）。
	if strings.HasPrefix(network, "tcp") {
		if conn, err := dialer.DialContext(ctx, "tcp4", addr); err == nil {
			return conn, nil
		}
	} else if strings.HasPrefix(network, "udp") {
		if conn, err := dialer.DialContext(ctx, "udp4", addr); err == nil {
			return conn, nil
		}
	}
	// IPv4 不可达时退回默认（允许 IPv6）。
	return dialer.DialContext(ctx, network, addr)
}

func queryDoH(domain, dohURL string) (string, error) {
	u, err := url.Parse(dohURL)
	if err != nil {
		return "", err
	}
	q := u.Query()
	dnsQuery := buildDNSQuery(domain, typeHTTPS)
	dnsBase64 := base64.RawURLEncoding.EncodeToString(dnsQuery)
	q.Set("dns", dnsBase64)
	u.RawQuery = q.Encode()

	req, err := http.NewRequest("GET", u.String(), nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Accept", "application/dns-message")
	req.Header.Set("Content-Type", "application/dns-message")
	dialer := newPhysicalNetDialer(3 * time.Second)
	transport := &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return dialPhysicalIPv4First(dialer, ctx, network, addr)
		},
		TLSHandshakeTimeout: 3 * time.Second,
		// 自定义 DialContext 会让 Go 默认关闭 HTTP/2；显式打开，
		// 否则只支持 HTTP/2 的 DoH（如 doh.onedns.net）会返回
		// HTTP/1.x malformed 报错。（移植自 Mac v1.2.9）
		ForceAttemptHTTP2: true,
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Timeout: 3 * time.Second, Transport: transport}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("DoH 状态码: %d", resp.StatusCode)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	return parseDNSResponse(body)
}

func buildDNSQuery(domain string, qtype uint16) []byte {
	query := make([]byte, 0, 512)
	query = append(query, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
	for _, label := range strings.Split(domain, ".") {
		query = append(query, byte(len(label)))
		query = append(query, []byte(label)...)
	}
	query = append(query, 0x00)
	query = append(query, byte(qtype>>8), byte(qtype), 0x00, 0x01)
	return query
}

func parseDNSResponse(response []byte) (string, error) {
	if len(response) < 12 {
		return "", fmt.Errorf("响应过短")
	}
	ancount := binary.BigEndian.Uint16(response[6:8])
	if ancount == 0 {
		return "", fmt.Errorf("无答案记录")
	}
	offset := 12
	for offset < len(response) && response[offset] != 0 {
		offset += int(response[offset]) + 1
	}
	offset += 5
	for i := 0; i < int(ancount); i++ {
		if offset >= len(response) {
			break
		}
		if response[offset]&0xC0 == 0xC0 {
			offset += 2
		} else {
			for offset < len(response) && response[offset] != 0 {
				offset += int(response[offset]) + 1
			}
			offset++
		}
		if offset+10 > len(response) {
			break
		}
		rrType := binary.BigEndian.Uint16(response[offset : offset+2])
		offset += 8
		dataLen := binary.BigEndian.Uint16(response[offset : offset+2])
		offset += 2
		if offset+int(dataLen) > len(response) {
			break
		}
		data := response[offset : offset+int(dataLen)]
		offset += int(dataLen)
		if rrType == typeHTTPS {
			if ech := parseHTTPSRecord(data); ech != "" {
				return ech, nil
			}
		}
	}
	return "", nil
}

func parseHTTPSRecord(data []byte) string {
	if len(data) < 2 {
		return ""
	}
	offset := 2
	if offset < len(data) && data[offset] == 0 {
		offset++
	} else {
		for offset < len(data) && data[offset] != 0 {
			offset += int(data[offset]) + 1
		}
		offset++
	}
	for offset+4 <= len(data) {
		key := binary.BigEndian.Uint16(data[offset : offset+2])
		length := binary.BigEndian.Uint16(data[offset+2 : offset+4])
		offset += 4
		if offset+int(length) > len(data) {
			break
		}
		value := data[offset : offset+int(length)]
		offset += int(length)
		if key == 5 {
			return base64.StdEncoding.EncodeToString(value)
		}
	}
	return ""
}

// ======================== WebSocket 服务端 ========================

var serverSessions sync.Map // map[string]*ClientSession

type WSChannel struct {
	id      uint64
	conn    *websocket.Conn
	session *ClientSession
}

type ClientSession struct {
	nextChanID uint64

	clientID string

	mu       sync.RWMutex
	channels map[uint64]*WSChannel
}

func getOrCreateClientSession(clientID string) *ClientSession {
	if v, ok := serverSessions.Load(clientID); ok {
		if cs, okType := v.(*ClientSession); okType && cs != nil {
			return cs
		}
		serverSessions.Delete(clientID)
	}
	s := &ClientSession{
		clientID: clientID,
		channels: make(map[uint64]*WSChannel),
	}
	actual, _ := serverSessions.LoadOrStore(clientID, s)
	if cs, ok := actual.(*ClientSession); ok && cs != nil {
		return cs
	}
	serverSessions.Store(clientID, s)
	return s
}

func (s *ClientSession) addChannel(wsConn *websocket.Conn, preferredID uint64) *WSChannel {
	newID := preferredID
	if newID == 0 {
		newID = atomic.AddUint64(&s.nextChanID, 1)
	}
	ch := &WSChannel{
		id:      newID,
		conn:    wsConn,
		session: s,
	}
	var replaced *WSChannel
	s.mu.Lock()
	if old, ok := s.channels[ch.id]; ok {
		replaced = old
	}
	s.channels[ch.id] = ch
	s.mu.Unlock()
	if replaced != nil {
		_ = replaced.conn.Close()
	}
	return ch
}

func (s *ClientSession) removeChannel(id uint64, current *WSChannel) {
	s.mu.Lock()
	if ch, ok := s.channels[id]; ok && ch == current {
		delete(s.channels, id)
	}
	empty := len(s.channels) == 0
	s.mu.Unlock()

	if empty {
		log.Printf("[服务端] 客户端会话 %s 断开", s.clientID)
		serverSessions.Delete(s.clientID)
	}
}

func generateSelfSignedCert() (tls.Certificate, error) {
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return tls.Certificate{}, err
	}
	template := x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{Organization: []string{"SelfSigned"}},
		NotBefore:             time.Now(),
		NotAfter:              time.Now().Add(10 * 365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	derBytes, err := x509.CreateCertificate(rand.Reader, &template, &template, &privateKey.PublicKey, privateKey)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.X509KeyPair(
		pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: derBytes}),
		pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(privateKey)}),
	)
}

func runWebSocketServer(addr string) {
	u, err := url.Parse(addr)
	if err != nil {
		log.Fatalf("[服务端] WS 地址无效: %v", err)
	}
	path := u.Path
	if path == "" {
		path = "/"
	}
	var allowedNets []*net.IPNet
	for _, cidr := range strings.Split(cidrs, ",") {
		_, allowedNet, err := net.ParseCIDR(strings.TrimSpace(cidr))
		if err != nil {
			log.Fatalf("[服务端] CIDR 解析失败: %v", err)
		}
		allowedNets = append(allowedNets, allowedNet)
	}

	upgrader := websocket.Upgrader{
		CheckOrigin:     func(r *http.Request) bool { return true },
		ReadBufferSize:  cfg.ReadBuf,
		WriteBufferSize: cfg.ReadBuf,
	}
	if token != "" {
		upgrader.Subprotocols = []string{token}
	}

	http.HandleFunc(path, func(w http.ResponseWriter, r *http.Request) {
		clientIP, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			http.Error(w, "错误的请求", http.StatusBadRequest)
			return
		}
		ip := net.ParseIP(clientIP)
		allowed := false
		for _, n := range allowedNets {
			if n.Contains(ip) {
				allowed = true
				break
			}
		}
		if !allowed {
			http.Error(w, "禁止访问", http.StatusForbidden)
			return
		}
		if token != "" {
			if r.Header.Get("Sec-WebSocket-Protocol") != token {
				log.Printf("[服务端] Token 认证失败，来源 IP: %s", clientIP)
				http.Error(w, "未授权", http.StatusUnauthorized)
				return
			}
		}
		wsConn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		cid := r.URL.Query().Get("client_id")
		if cid == "" {
			cid = uuid.NewString()
		}
		channelID := uint64(0)
		if v := r.URL.Query().Get("channel_id"); v != "" {
			if parsed, parseErr := strconv.ParseUint(v, 10, 64); parseErr == nil {
				channelID = parsed
			}
		}
		session := getOrCreateClientSession(cid)
		ch := session.addChannel(wsConn, channelID)
		log.Printf("[服务端] 客户端通道 %d 连接, 客户端ID: %s, IP: %s", ch.id, cid, clientIP)
		go handleWebSocketChannel(ch)
	})

	if u.Scheme == "wss" {
		server := &http.Server{Addr: u.Host}
		if certFile != "" && keyFile != "" {
			server.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS13}
			if err := server.ListenAndServeTLS(certFile, keyFile); err != nil {
				log.Fatalf("[服务端] WSS 启动失败: %v", err)
			}
		} else {
			cert, err := generateSelfSignedCert()
			if err != nil {
				log.Fatalf("[服务端] 生成自签名证书失败: %v", err)
			}
			server.TLSConfig = &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS13}
			log.Printf("[服务端] WSS 启动 %s%s", u.Host, path)
			if err := server.ListenAndServeTLS("", ""); err != nil {
				log.Fatalf("[服务端] WSS 启动失败: %v", err)
			}
		}
	} else {
		log.Printf("[服务端] WS 启动 %s%s", u.Host, path)
		if err := http.ListenAndServe(u.Host, nil); err != nil {
			log.Fatalf("[服务端] WS 启动失败: %v", err)
		}
	}
}

// 根据 IP 策略拨号 TCP
func dialTCPWithStrategy(addr string, strategy byte) (net.Conn, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return net.DialTimeout("tcp", addr, cfg.DialTimeout)
	}

	if ip := net.ParseIP(host); ip != nil {
		return net.DialTimeout("tcp", addr, cfg.DialTimeout)
	}

	if strategy == IPStrategyIPv4Only {
		return net.DialTimeout("tcp4", addr, cfg.DialTimeout)
	}
	if strategy == IPStrategyIPv6Only {
		return net.DialTimeout("tcp6", addr, cfg.DialTimeout)
	}

	if strategy == IPStrategyPv4Pv6 || strategy == IPStrategyPv6Pv4 {
		resolver := &net.Resolver{}
		ctx, cancel := context.WithTimeout(context.Background(), cfg.DialTimeout)
		defer cancel()
		addrs, err := resolver.LookupIPAddr(ctx, host)
		if err != nil {
			return nil, err
		}

		var v4, v6 net.IP
		for _, a := range addrs {
			if a.IP.To4() != nil {
				if v4 == nil {
					v4 = a.IP
				}
			} else {
				if v6 == nil {
					v6 = a.IP
				}
			}
			if v4 != nil && v6 != nil {
				break
			}
		}

		var selected net.IP
		if strategy == IPStrategyPv4Pv6 {
			if v4 != nil {
				selected = v4
			} else {
				selected = v6
			}
		} else {
			if v6 != nil {
				selected = v6
			} else {
				selected = v4
			}
		}

		if selected == nil {
			return nil, fmt.Errorf("未找到可用IP: %s", host)
		}

		target := net.JoinHostPort(selected.String(), port)
		return net.DialTimeout("tcp", target, cfg.DialTimeout)
	}

	return net.DialTimeout("tcp", addr, cfg.DialTimeout)
}

func resolveUDPWithStrategy(addr string, strategy byte) (*net.UDPAddr, error) {
	host, portStr, err := net.SplitHostPort(addr)
	if err != nil {
		return net.ResolveUDPAddr("udp", addr)
	}
	port := 0
	fmt.Sscanf(portStr, "%d", &port)

	if ip := net.ParseIP(host); ip != nil {
		return &net.UDPAddr{IP: ip, Port: port}, nil
	}

	if strategy == IPStrategyIPv4Only {
		return net.ResolveUDPAddr("udp4", addr)
	}
	if strategy == IPStrategyIPv6Only {
		return net.ResolveUDPAddr("udp6", addr)
	}

	if strategy == IPStrategyPv4Pv6 || strategy == IPStrategyPv6Pv4 {
		resolver := &net.Resolver{}
		ctx, cancel := context.WithTimeout(context.Background(), cfg.DialTimeout)
		defer cancel()
		addrs, err := resolver.LookupIPAddr(ctx, host)
		if err != nil {
			return nil, err
		}

		var v4, v6 net.IP
		for _, a := range addrs {
			if a.IP.To4() != nil {
				if v4 == nil {
					v4 = a.IP
				}
			} else {
				if v6 == nil {
					v6 = a.IP
				}
			}
			if v4 != nil && v6 != nil {
				break
			}
		}

		var selected net.IP
		if strategy == IPStrategyPv4Pv6 {
			if v4 != nil {
				selected = v4
			} else {
				selected = v6
			}
		} else {
			if v6 != nil {
				selected = v6
			} else {
				selected = v4
			}
		}

		if selected == nil {
			return nil, fmt.Errorf("未找到可用IP: %s", host)
		}
		return &net.UDPAddr{IP: selected, Port: port}, nil
	}

	return net.ResolveUDPAddr("udp", addr)
}

// smuxConfig 返回隧道多路复用的会话配置。
//
// 关键：MaxStreamBuffer 会通过 cmdUPD 帧广播给对端，成为「对端发往本端」的
// 发送窗口（发送侧 win = peerWindow - inflight，n = min(len(b), win)）。
// 默认值只有 64KB，意味着单条流最多 64KB 在途数据，吞吐上限约为
// 64KB / RTT —— 典型 RTT 下正好对应十几 Mbps 的封顶，下载速度因此上不去。
//
// 调到 1MB 后单流窗口放大 16 倍。因为这个值由本端广播，只改客户端一侧
// 就能提升下载速度，对端无需同步升级。
func smuxConfig() *smux.Config {
	cfg := &smux.Config{
		Version:           1,
		KeepAliveInterval: 10 * time.Second,
		KeepAliveTimeout:  30 * time.Second,
		// 只影响本端发送分片大小，接收侧不校验；加大收益极小，保持默认
		MaxFrameSize: 32768,
		// 会话级接收令牌池，需 >= MaxStreamBuffer
		MaxReceiveBuffer: 8 << 20,
		// 单流窗口 64KB -> 512KB（8x），决定下载吞吐上限。
		// 不取 1MB：缓冲越大 bufferbloat 越明显，拖动视频进度这类
		// 需要快速丢弃旧数据的场景反而更慢。
		MaxStreamBuffer: 512 << 10,
	}
	smuxConfigLogOnce.Do(func() {
		log.Printf("[通道] smux: 单流窗口=%dKB 会话接收池=%dMB 帧长=%dB（单流窗口由本端广播，决定下行窗口）",
			cfg.MaxStreamBuffer/1024, cfg.MaxReceiveBuffer>>20, cfg.MaxFrameSize)
	})
	return cfg
}

var smuxConfigLogOnce sync.Once

// ======================== WebSocket 处理逻辑 ========================

func handleWebSocketChannel(ch *WSChannel) {
	wsConn := ch.conn
	session := ch.session

	defer func() {
		_ = wsConn.Close()
		session.removeChannel(ch.id, ch)
	}()
	netConn := newWSNetConn(wsConn)
	sess, err := smux.Server(netConn, smuxConfig())
	if err != nil {
		log.Printf("[服务端] 通道 %d smux 初始化失败: %v", ch.id, err)
		return
	}
	defer sess.Close()
	for {
		stream, err := sess.AcceptStream()
		if err != nil {
			log.Printf("[服务端] 客户端通道 %d 断开", ch.id)
			return
		}
		go handleSmuxStream(session, ch, stream)
	}
}

func readSmuxOpenHeader(r io.Reader) (byte, byte, string, error) {
	head := make([]byte, 4)
	if _, err := io.ReadFull(r, head); err != nil {
		return 0, 0, "", err
	}
	kind := head[0]
	strategy := head[1]
	targetLen := int(binary.BigEndian.Uint16(head[2:4]))
	targetRaw := make([]byte, targetLen)
	if targetLen > 0 {
		if _, err := io.ReadFull(r, targetRaw); err != nil {
			return 0, 0, "", err
		}
	}
	return kind, strategy, string(targetRaw), nil
}

func handleSmuxStream(session *ClientSession, ch *WSChannel, stream *smux.Stream) {
	defer stream.Close()
	kind, strategy, target, err := readSmuxOpenHeader(stream)
	if err != nil {
		return
	}
	switch kind {
	case streamKindPing:
		payload := make([]byte, 8)
		if _, err := io.ReadFull(stream, payload); err != nil {
			return
		}
		_, _ = stream.Write(payload)
	case streamKindTCP:
		log.Printf("[服务端] 客户ID:%s TCP 打开: %s, 通道:%d", shortID(session.clientID), target, ch.id)
		var tcpConn net.Conn
		if socks5Config != nil {
			tcpConn, err = dialViaSocks5("tcp", target)
		} else {
			tcpConn, err = dialTCPWithStrategy(target, strategy)
		}
		if err != nil {
			return
		}
		proxyConnStream(tcpConn, stream, target)
		log.Printf("[服务端] 客户ID:%s TCP 关闭: %s, 通道:%d", shortID(session.clientID), target, ch.id)
	case streamKindUDP:
		log.Printf("[服务端] 客户ID:%s SOCKS5 UDP 访问: %s, 通道:%d", shortID(session.clientID), target, ch.id)
		var relay UDPRelayer
		if socks5Config != nil {
			var socksRelay *SOCKS5UDPRelay
			socksRelay, err = newSOCKS5UDPRelay(target)
			if err != nil {
				log.Printf("[服务端] 客户ID:%s SOCKS5 UDP中继创建失败: %v, 通道:%d", shortID(session.clientID), err, ch.id)
				return
			}
			relay = socksRelay
		} else {
			addr, errResolve := resolveUDPWithStrategy(target, strategy)
			if errResolve != nil {
				return
			}
			udpConn, errListen := net.ListenUDP("udp", nil)
			if errListen != nil {
				return
			}
			relay = &DirectUDPRelayer{conn: udpConn, target: addr}
		}
		if relay == nil {
			return
		}
		defer relay.Close()
		done := make(chan struct{})
		go func() {
			defer close(done)
			for {
				packet, e := readChunk(stream)
				if e != nil {
					return
				}
				if len(packet) == 0 {
					continue
				}
				if _, e = relay.Write(packet); e != nil {
					return
				}
			}
		}()
		bufPtr := bufPool.Get().(*[]byte)
		buf := *bufPtr
		defer bufPool.Put(bufPtr)
		for {
			_ = relay.SetReadDeadline(time.Now().Add(1 * time.Second))
			n, addr, e := relay.Read(buf)
			if e != nil {
				if netErr, ok := e.(net.Error); ok && netErr.Timeout() {
					select {
					case <-done:
						return
					default:
						continue
					}
				}
				return
			}
			if err := writeUDPReply(stream, addr.String(), buf[:n]); err != nil {
				return
			}
		}
	}
}

// ======================== 多通道客户端池 ========================

type ECHPool struct {
	wsServerAddr  string
	connectionNum int
	targetIPs     []string
	clientID      string

	wsConnsMu     sync.RWMutex
	smuxConns     []*smux.Session
	channelRTT    []int64
	selectCounter uint64
	readyCh       chan struct{}
	readyOnce     sync.Once
}

func NewECHPool(addr string, n int, ips []string, clientID string) *ECHPool {
	total := n
	if len(ips) > 0 {
		total = len(ips) * n
	}
	p := &ECHPool{
		wsServerAddr:  addr,
		connectionNum: n,
		targetIPs:     ips,
		clientID:      clientID,
		smuxConns:     make([]*smux.Session, total),
		channelRTT:    make([]int64, total),
		readyCh:       make(chan struct{}, 1),
	}
	return p
}

// WaitForChannelReady 阻塞直到至少一条 smux 通道就绪或超时。
func (p *ECHPool) WaitForChannelReady(timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for {
		if p.HasHealthyChannel() {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		select {
		case <-ticker.C:
		case <-p.readyCh:
			return true
		}
	}
}

func (p *ECHPool) Start() {
	for i := 0; i < len(p.smuxConns); i++ {
		ip := ""
		if len(p.targetIPs) > 0 {
			if idx := i / p.connectionNum; idx < len(p.targetIPs) {
				ip = p.targetIPs[idx]
			}
		}
		go p.dialAndServe(i, ip)
	}
}

func (p *ECHPool) dialAndServe(idx int, ip string) {
	chID := idx + 1
	ipLabel := ip
	if strings.TrimSpace(ipLabel) == "" {
		ipLabel = "自动解析"
	}
	for {
		if tunMode {
			ensurePhysIfaceIndex()
		}
		wsConn, err := p.dialWebSocketWithECH(p.wsServerAddr, 3, ip, p.clientID, chID)
		if err != nil {
			log.Printf("[客户端] 通道 %d (IP:%s) 连接失败: %v", chID, ipLabel, err)
			time.Sleep(3 * time.Second)
			continue
		}
		wsNet := newWSNetConn(wsConn)
		sess, err := smux.Client(wsNet, smuxConfig())
		if err != nil {
			_ = wsConn.Close()
			log.Printf("[客户端] 通道 %d (IP:%s) smux 初始化失败: %v", chID, ipLabel, err)
			time.Sleep(cfg.ReconnectDelay)
			continue
		}
		p.wsConnsMu.Lock()
		p.smuxConns[idx] = sess
		p.channelRTT[idx] = 0
		p.wsConnsMu.Unlock()
		p.readyOnce.Do(func() {
			select {
			case p.readyCh <- struct{}{}:
			default:
			}
		})
		log.Printf("[客户端] 通道 %d (IP:%s) 就绪 (smux)", chID, ipLabel)
		if rtt, err := p.probeChannelRTTOnce(sess, cfg.RTTProbeTimeout); err == nil {
			atomic.StoreInt64(&p.channelRTT[idx], rtt)
		}

		done := make(chan error, 1)
		go p.probeChannelRTT(sess, idx, done)
		var probeErr error
		select {
		case probeErr = <-done:
		case <-wsNet.Dead():
			_ = sess.Close()
			<-done
			probeErr = wsNet.DeadErr()
			if probeErr == nil {
				probeErr = io.EOF
			}
		}

		_ = sess.Close()
		_ = wsConn.Close()

		p.wsConnsMu.Lock()
		p.smuxConns[idx] = nil
		p.channelRTT[idx] = 0
		p.wsConnsMu.Unlock()
		if probeErr != nil {
			log.Printf("[客户端] 通道 %d 断开原因: %v", chID, probeErr)
		}
		log.Printf("[客户端] 通道 %d 断开，重连中...", chID)
		time.Sleep(cfg.ReconnectDelay)
	}
}

func (p *ECHPool) probeChannelRTT(sess *smux.Session, idx int, done chan error) {
	var exitErr error
	defer func() {
		done <- exitErr
		close(done)
	}()
	ticker := time.NewTicker(cfg.RTTProbeTimeout)
	defer ticker.Stop()
	for {
		rtt, err := p.probeChannelRTTOnce(sess, cfg.RTTProbeTimeout)
		if err != nil {
			atomic.StoreInt64(&p.channelRTT[idx], int64(cfg.RTTProbeTimeout.Nanoseconds()))
			if sess.IsClosed() {
				exitErr = err
				return
			}
			<-ticker.C
			continue
		}
		oldRTT := atomic.LoadInt64(&p.channelRTT[idx])
		atomic.StoreInt64(&p.channelRTT[idx], rtt)
		// 首次探测或变化超过 50% 才记，避免日志刷屏
		if oldRTT <= 0 || rtt > oldRTT*3/2 || rtt < oldRTT*2/3 {
			log.Printf("[通道] %d RTT=%dms", idx+1, rtt/int64(time.Millisecond))
		}
		<-ticker.C
	}
}

func (p *ECHPool) probeChannelRTTOnce(sess *smux.Session, timeout time.Duration) (int64, error) {
	start := time.Now()
	s, err := sess.OpenStream()
	if err != nil {
		return 0, err
	}
	defer s.Close()
	_ = s.SetDeadline(time.Now().Add(timeout))
	if err := writeSmuxOpenHeader(s, streamKindPing, 0, ""); err != nil {
		return 0, err
	}
	payload := make([]byte, 8)
	binary.BigEndian.PutUint64(payload, uint64(start.UnixNano()))
	if _, err := s.Write(payload); err != nil {
		return 0, err
	}
	ack := make([]byte, 8)
	if _, err := io.ReadFull(s, ack); err != nil {
		return 0, err
	}
	if !bytes.Equal(ack, payload) {
		return 0, fmt.Errorf("ping ack mismatch")
	}
	return time.Since(start).Nanoseconds(), nil
}

func shortID(id string) string {
	if len(id) >= 8 {
		return id[:8]
	}
	return id
}

// countWriter 统计写入字节数，用于连接结束时输出该连接的实际吞吐。
// 注意：smux.Stream 只实现了 io.WriterTo、没有 ReadFrom，所以包一层不会
// 改变 io.Copy 的分派路径（下行仍走 stream.WriteTo）。
type countWriter struct {
	w io.Writer
	n int64
}

func (c *countWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.n += int64(n)
	return n, err
}

func humanRate(n int64, d time.Duration) string {
	if d <= 0 {
		return "-"
	}
	mb := float64(n) / (1024 * 1024) / d.Seconds()
	if mb >= 1 {
		return fmt.Sprintf("%.2f MB/s", mb)
	}
	return fmt.Sprintf("%.0f KB/s", float64(n)/1024/d.Seconds())
}

// proxyConnStream 双向转发。结束时若传输量较大则输出该连接的实际吞吐，
// 用于判断瓶颈究竟在窗口（窗口/RTT）还是别处。
func proxyConnStream(c net.Conn, stream *smux.Stream, target string) {
	start := time.Now()
	up := &countWriter{w: stream}
	down := &countWriter{w: c}
	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(up, c)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(down, stream)
		done <- struct{}{}
	}()
	<-done

	// 立即关闭双方，强制中断另一方向的 io.Copy
	_ = stream.Close()
	_ = c.Close()

	<-done // 等待另一方向退出

	// 只记录有体量的连接，避免日志被大量小连接淹没
	if down.n+up.n >= 512*1024 {
		el := time.Since(start)
		log.Printf("[转发][吞吐] %s 下行 %.2fMB 上行 %.2fMB 用时 %.1fs → 下行 %s",
			target,
			float64(down.n)/(1024*1024),
			float64(up.n)/(1024*1024),
			el.Seconds(),
			humanRate(down.n, el))
	}
}

func clientSourceAddr(c net.Conn) string {
	if ra := c.RemoteAddr(); ra != nil {
		return ra.String()
	}
	return "-"
}

func logClientConnEvent(c net.Conn, reqType, target string, chID int, opened bool) {
	arrow := "关闭"
	if opened {
		arrow = "打开"
	}
	log.Printf("[客户端] %s %s %s %s 通道 %d", clientSourceAddr(c), reqType, arrow, target, chID)
}

func (p *ECHPool) openBestStream() (*smux.Stream, int, int, error) {
	p.wsConnsMu.RLock()
	type candidate struct {
		idx int
		rtt int64
	}
	cands := make([]candidate, 0, len(p.smuxConns))
	for i, sess := range p.smuxConns {
		if sess == nil || sess.IsClosed() {
			continue
		}
		rtt := atomic.LoadInt64(&p.channelRTT[i])
		if rtt <= 0 {
			rtt = int64(cfg.RTTProbeTimeout.Nanoseconds())
		}
		cands = append(cands, candidate{idx: i, rtt: rtt})
	}
	p.wsConnsMu.RUnlock()
	if len(cands) == 0 {
		return nil, 0, 0, fmt.Errorf("无可用 smux 通道")
	}
	minRTT := cands[0].rtt
	for _, c := range cands[1:] {
		if c.rtt < minRTT {
			minRTT = c.rtt
		}
	}
	tieWindow := int64((10 * time.Millisecond).Nanoseconds())
	near := make([]candidate, 0, len(cands))
	for _, c := range cands {
		if c.rtt <= minRTT+tieWindow {
			near = append(near, c)
		}
	}
	pick := int(atomic.AddUint64(&p.selectCounter, 1)-1) % len(near)
	best := near[pick]
	p.wsConnsMu.RLock()
	sess := p.smuxConns[best.idx]
	p.wsConnsMu.RUnlock()
	if sess == nil || sess.IsClosed() {
		return nil, 0, 0, fmt.Errorf("通道不可用")
	}
	decision := best.idx + 1
	s, err := sess.OpenStream()
	if err != nil {
		return nil, 0, 0, err
	}
	return s, best.idx + 1, decision, nil
}

// HasHealthyChannel returns true if at least one smux connection is alive.
// Used by routing logic to decide whether proxy is available.
func (p *ECHPool) HasHealthyChannel() bool {
	p.wsConnsMu.RLock()
	defer p.wsConnsMu.RUnlock()
	for _, sess := range p.smuxConns {
		if sess != nil && !sess.IsClosed() {
			return true
		}
	}
	return false
}

func writeSmuxOpenHeader(w io.Writer, kind byte, strategy byte, target string) error {
	if len(target) > 65535 {
		return fmt.Errorf("目标地址过长")
	}
	head := make([]byte, 4)
	head[0] = kind
	head[1] = strategy
	binary.BigEndian.PutUint16(head[2:4], uint16(len(target)))
	if _, err := w.Write(head); err != nil {
		return err
	}
	if len(target) == 0 {
		return nil
	}
	_, err := w.Write([]byte(target))
	return err
}

func (p *ECHPool) openTCPStream(target string) (*smux.Stream, int, int, error) {
	s, chID, decision, err := p.openBestStream()
	if err != nil {
		return nil, 0, 0, err
	}
	if err := writeSmuxOpenHeader(s, streamKindTCP, ipStrategy, target); err != nil {
		_ = s.Close()
		return nil, 0, 0, err
	}
	return s, chID, decision, nil
}

func (p *ECHPool) openUDPStream(target string) (*smux.Stream, int, int, error) {
	s, chID, decision, err := p.openBestStream()
	if err != nil {
		return nil, 0, 0, err
	}
	if err := writeSmuxOpenHeader(s, streamKindUDP, ipStrategy, target); err != nil {
		_ = s.Close()
		return nil, 0, 0, err
	}
	return s, chID, decision, nil
}

func writeChunk(w io.Writer, b []byte) error {
	if len(b) > 65535 {
		return fmt.Errorf("数据块过大")
	}
	h := make([]byte, 2)
	binary.BigEndian.PutUint16(h, uint16(len(b)))
	if _, err := w.Write(h); err != nil {
		return err
	}
	if len(b) == 0 {
		return nil
	}
	_, err := w.Write(b)
	return err
}

func readChunk(r io.Reader) ([]byte, error) {
	h := make([]byte, 2)
	if _, err := io.ReadFull(r, h); err != nil {
		return nil, err
	}
	n := int(binary.BigEndian.Uint16(h))
	if n == 0 {
		return nil, nil
	}
	b := make([]byte, n)
	_, err := io.ReadFull(r, b)
	return b, err
}

func writeUDPReply(w io.Writer, addr string, payload []byte) error {
	if len(addr) > 65535 {
		return fmt.Errorf("地址过长")
	}
	head := make([]byte, 4)
	binary.BigEndian.PutUint16(head[0:2], uint16(len(addr)))
	binary.BigEndian.PutUint16(head[2:4], uint16(len(payload)))
	if _, err := w.Write(head); err != nil {
		return err
	}
	if len(addr) > 0 {
		if _, err := w.Write([]byte(addr)); err != nil {
			return err
		}
	}
	if len(payload) > 0 {
		if _, err := w.Write(payload); err != nil {
			return err
		}
	}
	return nil
}

func readUDPReply(r io.Reader) (string, []byte, error) {
	head := make([]byte, 4)
	if _, err := io.ReadFull(r, head); err != nil {
		return "", nil, err
	}
	addrLen := int(binary.BigEndian.Uint16(head[0:2]))
	dataLen := int(binary.BigEndian.Uint16(head[2:4]))
	addrRaw := make([]byte, addrLen)
	if addrLen > 0 {
		if _, err := io.ReadFull(r, addrRaw); err != nil {
			return "", nil, err
		}
	}
	data := make([]byte, dataLen)
	if dataLen > 0 {
		if _, err := io.ReadFull(r, data); err != nil {
			return "", nil, err
		}
	}
	return string(addrRaw), data, nil
}

// ======================== TCP Forwarder ========================

func runTCPListener(rule string) {
	rule = strings.TrimPrefix(rule, "tcp://")
	parts := strings.Split(rule, "/")
	if len(parts) != 2 {
		return
	}
	lAddr, tAddr := strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1])
	l, err := net.Listen("tcp", lAddr)
	if err != nil {
		log.Fatalf("[客户端] TCP监听失败: %v", err)
	}
	log.Printf("[客户端] TCP转发: %s -> %s", lAddr, tAddr)
	for {
		c, err := l.Accept()
		if err != nil {
			continue
		}
		go handleLocalTCP(c, tAddr)
	}
}

func handleLocalTCP(c net.Conn, target string) {
	// Mac 版改动：出站前先过一遍分流规则
	ob, err := dialTargetWithRoute(target)
	if err != nil {
		_ = c.Close()
		return
	}
	logRouteEvent(c, "TCP转发", target, ob, true)
	defer logRouteEvent(c, "TCP转发", target, ob, false)
	relayOutbound(c, ob, target)
}

// dialWebSocketWithECH：支持 ws:// 与 wss://；仅 wss 使用 TLS/ECH 逻辑
// detectPhysIfaceIndex 选择一个可用的非 TUN 物理网卡索引（跳过 loopback 和虚拟网卡）
func detectPhysIfaceIndex() int {
	// 优先用 GetAdaptersAddresses 原生字段硬判定：必须有默认网关、物理类 IfType、
	// 非隧道、非环回/link-local、非 ICS 虚拟网关段 192.168.137.x。这样能精准排除
	// 开启 Wi-Fi 共享(ICS)后出现的 Microsoft Wi-Fi Direct Virtual Adapter。
	if idx := detectPhysIfaceIndexAPI(); idx > 0 {
		return idx
	}
	// API 不可用或无候选，退回名字启发式兜底。
	ifaces, err := net.Interfaces()
	if err != nil {
		return -1
	}
	for _, iface := range ifaces {
		if !isPhysIfaceUsable(&iface) {
			continue
		}
		return iface.Index
	}
	return -1
}

func isPhysIfaceUsable(iface *net.Interface) bool {
	if iface == nil {
		return false
	}
	if iface.Flags&net.FlagUp == 0 {
		return false
	}
	if iface.Flags&net.FlagLoopback != 0 {
		return false
	}
	name := strings.ToLower(iface.Name)
	if isVirtualInterface(name) || strings.Contains(name, "tap") {
		return false
	}
	addrs, err := iface.Addrs()
	if err != nil || len(addrs) == 0 {
		return false
	}
	for _, a := range addrs {
		if ipNet, ok := a.(*net.IPNet); ok && ipNet.IP.To4() != nil && !ipNet.IP.IsLoopback() {
			return true
		}
	}
	return false
}

func ensurePhysIfaceIndex() {
	physIfaceMu.Lock()
	defer physIfaceMu.Unlock()

	if physIfaceIndex > 0 {
		if iface, err := net.InterfaceByIndex(physIfaceIndex); err == nil && isPhysIfaceUsable(iface) {
			return
		}
		prev := physIfaceIndex
		physIfaceIndex = -1
		log.Printf("[客户端] 物理网卡接口索引 %d 已失效，重新探测", prev)
	}
	newIdx := detectPhysIfaceIndex()
	if newIdx <= 0 {
		return
	}
	if newIdx != physIfaceIndex {
		physIfaceIndex = newIdx
		if iface, err := net.InterfaceByIndex(physIfaceIndex); err == nil {
			log.Printf("[客户端] 物理网卡接口索引更新: %d (%s)", physIfaceIndex, iface.Name)
		} else {
			log.Printf("[客户端] 物理网卡接口索引更新: %d", physIfaceIndex)
		}
	}
}

// 服务器地址解析缓存。
//
// 「简易 WebSocket 代理」协议下，每来一条浏览器连接就要新建一条 WebSocket，
// 而 WebSocket 的目标正是代理服务器自己的域名。若把解析交给 net.Dialer，
// 每建一条连接都要多付 1~2 次 DNS 往返 —— 实测 97 条连接触发了 184 次 DNS
// 查询，这些往返全部叠加在首包延迟上，网页打开慢、拖动进度恢复慢有一部分
// 账就记在这里。缓存后只有首次和缓存过期才真正查询。
var (
	srvIPMu    sync.Mutex
	srvIPCache = map[string]srvIPEntry{}
)

type srvIPEntry struct {
	ips []string
	at time.Time
}

const (
	srvIPTTL       = 5 * time.Minute
	srvIPResolveTO = 3 * time.Second
)

// cachedServerIP 返回 host 的缓存解析结果（IPv4 优先），拿不到时返回空串，
// 交给调用方按原样走 net.Dialer 的解析（即缓存前的老行为）。
// srvRotate 是入口 IP 的轮转下标。正常情况所有连接都粘在同一个 IP 上
// （优选域名解析出多个 IP 时，粘住比来回跳更稳）；只有建连失败时才由
// rotateServerIP 推进，让下一次尝试真正换一个入口 —— 否则 dialViaTunnel
// 那三次重试解析到的还是同一个 IP，等于白重试。
var srvRotate uint64

// rotateServerIP 在一条连接建连失败后调用，把后续连接切到池里的下一个入口。
func rotateServerIP() { atomic.AddUint64(&srvRotate, 1) }

// cachedServerIP 返回 host 当前应连的 IP，拿不到时返回空串，
// 交给调用方按原样走 net.Dialer 的解析（即缓存前的老行为）。
func cachedServerIP(host string) string {
	now := time.Now()
	srvIPMu.Lock()
	e, ok := srvIPCache[host]
	srvIPMu.Unlock()
	if ok && now.Sub(e.at) < srvIPTTL && len(e.ips) > 0 {
		return e.ips[atomic.LoadUint64(&srvRotate)%uint64(len(e.ips))]
	}

	ips := resolveServerIPv4(host)
	if len(ips) == 0 {
		// 本次解析失败但手里还有旧值：继续用旧的，避免一次网络抖动就把建连
		// 打回「每条一次 DNS」的老路。
		if ok && len(e.ips) > 0 {
			return e.ips[atomic.LoadUint64(&srvRotate)%uint64(len(e.ips))]
		}
		return ""
	}
	srvIPMu.Lock()
	srvIPCache[host] = srvIPEntry{ips: ips, at: now}
	srvIPMu.Unlock()
	log.Printf("[客户端] 服务器地址解析缓存: %s → %v (缓存 %v)", host, ips, srvIPTTL)
	return ips[atomic.LoadUint64(&srvRotate)%uint64(len(ips))]
}

// resolveServerIPv4 解析代理服务器域名，IPv4 优先。
//
// 这里解析的是「代理服务器自己的域名」，属于控制面，必须走本地系统解析器
// （不能走隧道，否则成了鸡生蛋问题）。IPv4 优先是因为实测部分网络下 IPv6
// DNS 路由不通，解析会先卡一轮超时。
func resolveServerIPv4(host string) []string {
	ctx, cancel := context.WithTimeout(context.Background(), srvIPResolveTO)
	defer cancel()
	addrs, err := net.DefaultResolver.LookupIPAddr(ctx, host)
	if err != nil || len(addrs) == 0 {
		return nil
	}
	var v4s, v6s []string
	for _, a := range addrs {
		if v4 := a.IP.To4(); v4 != nil {
			v4s = append(v4s, v4.String())
		} else {
			v6s = append(v6s, a.IP.String())
		}
	}
	// IPv4 优先：实测部分网络下 IPv6 路由不通，解析出来也连不上。
	// IPv6 结果保留在后面当兜底，只有完全没有 IPv4 时才用得上。
	return append(v4s, v6s...)
}

func (p *ECHPool) dialWebSocketWithECH(addr string, retries int, ip string, clientID string, channelID int) (*websocket.Conn, error) {
	u, err := url.Parse(addr)
	if err != nil {
		return nil, err
	}
	scheme := strings.ToLower(u.Scheme)
	if scheme != "wss" && scheme != "ws" {
		return nil, fmt.Errorf("仅支持 ws:// 或 wss:// (当前: %s)", u.Scheme)
	}

	dialURL := *u
	q := dialURL.Query()
	if clientID != "" {
		q.Set("client_id", clientID)
	}
	if channelID > 0 {
		q.Set("channel_id", strconv.Itoa(channelID))
	}
	dialURL.RawQuery = q.Encode()
	dialAddr := dialURL.String()

	newDialer := func() websocket.Dialer {
		dialer := websocket.Dialer{
			HandshakeTimeout: cfg.WSHandshakeTimeout,
			ReadBufferSize:   cfg.ReadBuf,
			WriteBufferSize:  cfg.ReadBuf,
		}
		if token != "" {
			dialer.Subprotocols = []string{token}
		}
		// 自定义 dialer：WebSocket 控制连接必须绕过 TUN。
		dialContext := func(ctx context.Context, network, address string) (net.Conn, error) {
			// 如果指定了 -ip，直接用该 IP 连接（目标服务器 IP，非本地绑定）
			if ip != "" {
				_, port, _ := net.SplitHostPort(address)
				if host, p, err := net.SplitHostPort(ip); err == nil {
					address = net.JoinHostPort(host, p)
				} else {
					address = net.JoinHostPort(ip, port)
				}
			}
			// 到这一步 address 里可能仍是域名：没配优选 IP 时是服务器域名，配了但填
			// 的是「优选域名」（如 cdns.doon.eu.org）时也是域名 —— 后者同样每条连接
			// 都要解析一次。统一在这里换成缓存里的 IP，net.Dialer 就跳过解析直接连，
			// 省掉每条连接 1~2 次 DNS 往返。只改 TCP 目标地址，TLS 的 SNI / ECH 仍
			// 用原域名，不影响证书校验与 ECH 加密。
			if h, port, e := net.SplitHostPort(address); e == nil && net.ParseIP(h) == nil {
				if cached := cachedServerIP(h); cached != "" {
					address = net.JoinHostPort(cached, port)
				}
			}

			// 回环目标（-ip 127.0.0.1 / [::1]）既不经 TUN 也不经物理出口接口，
			// 物理网卡绑定这一层必须跳过；非回环目标（含 -ip 1.2.3.4 公网定向）
			// 在 -tun 下继续走物理 dialer 绕 TUN，保持原行为。
			if isLoopbackAddress(address) {
				nd := &net.Dialer{Timeout: cfg.DialTimeout}
				return nd.DialContext(ctx, network, address)
			}
			d := newPhysicalNetDialer(cfg.DialTimeout)
			return d.DialContext(ctx, network, address)
		}
		dialer.NetDialContext = dialContext
		dialer.NetDial = func(network, address string) (net.Conn, error) {
			return dialContext(context.Background(), network, address)
		}
		return dialer
	}

	if scheme == "ws" {
		dialer := newDialer()
		conn, resp, err := dialer.Dial(dialAddr, nil)
		if err != nil {
			if resp != nil && resp.StatusCode == http.StatusUnauthorized {
				return nil, fmt.Errorf("认证失败：Token 不匹配或未提供")
			}
			return nil, err
		}
		return conn, nil
	}

	serverName := u.Hostname()
	for i := 1; i <= retries; i++ {
		tlsCfg, e := buildUnifiedTLSConfig(serverName)
		if e != nil {
			if i < retries {
				_ = refreshECH()
				time.Sleep(1 * time.Second)
				continue
			}
			return nil, e
		}

		dialer := newDialer()
		dialer.TLSClientConfig = tlsCfg

		conn, resp, err := dialer.Dial(dialAddr, nil)
		if err != nil {
			if resp != nil && resp.StatusCode == http.StatusUnauthorized {
				return nil, fmt.Errorf("认证失败：Token 不匹配或未提供")
			}
			if !fallback && (strings.Contains(err.Error(), "ECH") || strings.Contains(err.Error(), "ech")) && i < retries {
				_ = refreshECH()
				time.Sleep(1 * time.Second)
				continue
			}
			return nil, err
		}
		return conn, nil
	}
	return nil, fmt.Errorf("连接失败")
}

// ======================== SOCKS5 / HTTP Proxy ========================

type ProxyConfig struct {
	Username, Password, Host string
}

type UDPAssociation struct {
	tcpConn       net.Conn
	udpListener   *net.UDPConn
	clientUDPAddr *net.UDPAddr
	pool          *ECHPool

	mu        sync.Mutex
	closed    bool
	receiving bool
	channelID int
	target    string
	stream    *smux.Stream
}

func parseAuthAndAddr(full string) (string, string, string, error) {
	u, p, h := "", "", full
	if strings.Contains(full, "@") {
		parts := strings.SplitN(full, "@", 2)
		if len(parts) != 2 {
			return "", "", "", fmt.Errorf("格式错误")
		}
		auth := parts[0]
		if strings.Contains(auth, ":") {
			ap := strings.SplitN(auth, ":", 2)
			u, p = ap[0], ap[1]
		}
		h = parts[1]
	}
	return h, u, p, nil
}

func runSOCKS5Listener(addr string) {
	h, u, p, err := parseAuthAndAddr(strings.TrimPrefix(addr, "socks5://"))
	if err != nil {
		log.Fatalf("[客户端] SOCKS5地址解析失败: %v", err)
	}
	l, err := net.Listen("tcp", h)
	if err != nil {
		log.Fatalf("[客户端] SOCKS5监听失败: %v", err)
	}
	log.Printf("[客户端] SOCKS5 代理: %s", h)
	cfgp := &ProxyConfig{u, p, h}
	for {
		c, err := l.Accept()
		if err != nil {
			continue
		}
		go handleSOCKS5(c, cfgp)
	}
}

func handleSOCKS5(c net.Conn, cfgp *ProxyConfig) {
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(cfg.DialTimeout))
	buf := make([]byte, 2)
	if _, err := io.ReadFull(c, buf); err != nil || buf[0] != 0x05 {
		return
	}
	methods := make([]byte, buf[1])
	_, _ = io.ReadFull(c, methods)
	if cfgp.Username != "" {
		_, _ = c.Write([]byte{0x05, 0x02})
		if err := handleSOCKS5UserPassAuth(c, cfgp); err != nil {
			return
		}
	} else {
		_, _ = c.Write([]byte{0x05, 0x00})
	}

	head := make([]byte, 4)
	if _, err := io.ReadFull(c, head); err != nil {
		return
	}
	var target string
	switch head[3] {
	case 0x01:
		b := make([]byte, 4)
		_, _ = io.ReadFull(c, b)
		target = net.IP(b).String()
	case 0x03:
		b := make([]byte, 1)
		_, _ = io.ReadFull(c, b)
		addr := make([]byte, b[0])
		_, _ = io.ReadFull(c, addr)
		target = string(addr)
	case 0x04:
		b := make([]byte, 16)
		_, _ = io.ReadFull(c, b)
		target = net.IP(b).String()
	}
	pb := make([]byte, 2)
	_, _ = io.ReadFull(c, pb)
	port := int(pb[0])<<8 | int(pb[1])
	target = net.JoinHostPort(target, fmt.Sprintf("%d", port))

	// 增强过滤逻辑：解析 host 判断是否为 IP，从而覆盖 ATYP=0x03 但内容为 IP 的情况
	host, _, _ := net.SplitHostPort(target)
	ip := net.ParseIP(host)

	if head[1] == 0x01 {
		if ipStrategy == IPStrategyIPv4Only {
			if head[3] == 0x04 || (ip != nil && ip.To4() == nil) {
				_, _ = c.Write([]byte{0x05, 0x02, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
				return
			}
		}
		if ipStrategy == IPStrategyIPv6Only {
			if head[3] == 0x01 || (ip != nil && ip.To4() != nil) {
				_, _ = c.Write([]byte{0x05, 0x02, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
				return
			}
		}
	}

	_ = c.SetDeadline(time.Time{})

	switch head[1] {
	case 0x01:
		handleSOCKS5Connect(c, target)
	case 0x03:
		handleSOCKS5UDP(c, cfgp)
	}
}

func handleSOCKS5UserPassAuth(c net.Conn, cfgp *ProxyConfig) error {
	b := make([]byte, 2)
	_, _ = io.ReadFull(c, b)
	u := make([]byte, b[1])
	_, _ = io.ReadFull(c, u)
	_, _ = io.ReadFull(c, b[:1])
	p := make([]byte, b[0])
	_, _ = io.ReadFull(c, p)
	if string(u) == cfgp.Username && string(p) == cfgp.Password {
		_, _ = c.Write([]byte{0x01, 0x00})
		return nil
	}
	_, _ = c.Write([]byte{0x01, 0x01})
	return errors.New("认证失败")
}

func handleSOCKS5Connect(c net.Conn, target string) {
	_, err := c.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
	if err != nil {
		_ = c.Close()
		return
	}
	// Mac 版改动：出站前先过一遍分流规则（Windows 上这层由 v2rayN 负责）
	ob, err := dialTargetWithRoute(target)
	if err != nil {
		_ = c.Close()
		return
	}
	logRouteEvent(c, "SOCKS5", target, ob, true)
	defer logRouteEvent(c, "SOCKS5", target, ob, false)
	relayOutbound(c, ob, target)
}

func handleSOCKS5UDP(c net.Conn, cfgp *ProxyConfig) {
	host, _, _ := net.SplitHostPort(cfgp.Host)
	uAddr, _ := net.ResolveUDPAddr("udp", net.JoinHostPort(host, "0"))
	ul, err := net.ListenUDP("udp", uAddr)
	if err != nil {
		_ = c.Close()
		return
	}
	defer ul.Close()

	actual, ok := ul.LocalAddr().(*net.UDPAddr)
	if !ok || actual == nil {
		_ = c.Close()
		return
	}
	resp := []byte{0x05, 0x00, 0x00}
	if ip4 := actual.IP.To4(); ip4 != nil {
		resp = append(resp, 0x01)
		resp = append(resp, ip4...)
	} else {
		resp = append(resp, 0x04)
		resp = append(resp, actual.IP...)
	}
	resp = append(resp, byte(actual.Port>>8), byte(actual.Port))
	if _, err := c.Write(resp); err != nil {
		_ = c.Close()
		return
	}

	assoc := &UDPAssociation{
		tcpConn:     c,
		udpListener: ul,
		pool:        echPool,
		channelID:   -1,
	}

	go assoc.loop()
	b := make([]byte, 1)
	for {
		if _, err := c.Read(b); err != nil {
			assoc.Close()
			return
		}
	}
}

func (a *UDPAssociation) loop() {
	bufPtr := bufPool.Get().(*[]byte)
	buf := *bufPtr
	defer bufPool.Put(bufPtr)

	for {
		n, addr, err := a.udpListener.ReadFromUDP(buf)
		if err != nil {
			return
		}
		a.mu.Lock()
		if a.clientUDPAddr == nil {
			a.clientUDPAddr = addr
		} else if a.clientUDPAddr.String() != addr.String() {
			a.mu.Unlock()
			continue
		}
		a.mu.Unlock()

		tgt, data, err := parseSOCKS5UDPPacket(buf[:n])
		if err == nil {
			h, ps, _ := net.SplitHostPort(tgt)
			if ip := net.ParseIP(h); ip != nil {
				if ipStrategy == IPStrategyIPv4Only && ip.To4() == nil {
					continue
				}
				if ipStrategy == IPStrategyIPv6Only && ip.To4() != nil {
					continue
				}
			}
			var prt int
			_, _ = fmt.Sscanf(ps, "%d", &prt)
			if _, ok := udpBlockPorts[prt]; ok {
				continue
			}
			a.send(tgt, data)
		}
	}
}

func (a *UDPAssociation) send(target string, data []byte) {
	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		return
	}
	needStart := !a.receiving
	if needStart {
		a.receiving = true
		a.target = target
	}
	stream := a.stream
	a.mu.Unlock()

	if needStart {
		s, id, decision, err := a.pool.openUDPStream(target)
		if err != nil {
			a.Close()
			return
		}
		a.mu.Lock()
		a.stream = s
		a.channelID = id
		stream = s
		a.mu.Unlock()
		logClientConnEvent(a.tcpConn, "SOCKS5-UDP", target, decision, true)
		go func() {
			for {
				addrStr, payload, e := readUDPReply(s)
				if e != nil {
					a.Close()
					return
				}
				a.handleUDPResponse(addrStr, payload)
			}
		}()
	} else {
		if target != "" && target != a.target {
			a.mu.Lock()
			a.target = target
			a.mu.Unlock()
		}
	}
	if stream == nil {
		a.Close()
		return
	}
	if err := writeChunk(stream, data); err != nil {
		a.Close()
	}
}

func (a *UDPAssociation) handleUDPResponse(addrStr string, data []byte) {
	host, portStr, _ := net.SplitHostPort(addrStr)
	port := 0
	fmt.Sscanf(portStr, "%d", &port)
	pkt, _ := buildSOCKS5UDPPacket(host, port, data)
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.clientUDPAddr != nil {
		_, _ = a.udpListener.WriteToUDP(pkt, a.clientUDPAddr)
	}
}

func (a *UDPAssociation) Close() {
	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		return
	}
	stream := a.stream
	target := a.target
	chID := a.channelID
	a.closed = true
	a.stream = nil
	a.mu.Unlock()
	if stream != nil {
		_ = stream.Close()
	}
	if chID > 0 && target != "" {
		logClientConnEvent(a.tcpConn, "SOCKS5-UDP", target, chID, false)
	}
	_ = a.udpListener.Close()
	if a.tcpConn != nil {
		_ = a.tcpConn.Close()
	}
}

func parseSOCKS5UDPPacket(b []byte) (string, []byte, error) {
	if len(b) < 10 || b[2] != 0 {
		return "", nil, errors.New("数据不合法")
	}
	off := 4
	var h string
	switch b[3] {
	case 0x01:
		if off+4 > len(b) {
			return "", nil, errors.New("IPv4地址长度过短")
		}
		h = net.IP(b[off : off+4]).String()
		off += 4
	case 0x03:
		if off+1 > len(b) {
			return "", nil, errors.New("域名长度不足")
		}
		l := int(b[off])
		off++
		if off+l > len(b) {
			return "", nil, errors.New("域名长度不足")
		}
		h = string(b[off : off+l])
		off += l
	case 0x04:
		if off+16 > len(b) {
			return "", nil, errors.New("IPv6地址长度过短")
		}
		h = net.IP(b[off : off+16]).String()
		off += 16
	default:
		return "", nil, errors.New("地址类型无效")
	}
	if off+2 > len(b) {
		return "", nil, errors.New("端口字段过短")
	}
	p := int(b[off])<<8 | int(b[off+1])
	off += 2
	t := fmt.Sprintf("%s:%d", h, p)
	if b[3] == 0x04 {
		t = fmt.Sprintf("[%s]:%d", h, p)
	}
	return t, b[off:], nil
}

func buildSOCKS5UDPPacket(h string, p int, d []byte) ([]byte, error) {
	buf := []byte{0, 0, 0}
	ip := net.ParseIP(h)
	if ip4 := ip.To4(); ip4 != nil {
		buf = append(buf, 0x01)
		buf = append(buf, ip4...)
	} else if ip != nil {
		buf = append(buf, 0x04)
		buf = append(buf, ip...)
	} else {
		buf = append(buf, 0x03, byte(len(h)))
		buf = append(buf, h...)
	}
	buf = append(buf, byte(p>>8), byte(p))
	buf = append(buf, d...)
	return buf, nil
}

func runHTTPListener(addr string) {
	h, u, p, _ := parseAuthAndAddr(strings.TrimPrefix(addr, "http://"))
	l, err := net.Listen("tcp", h)
	if err != nil {
		log.Fatalf("[客户端] HTTP监听失败: %v", err)
	}
	log.Printf("[客户端] HTTP 代理: %s", h)
	cfgp := &ProxyConfig{u, p, h}
	for {
		c, err := l.Accept()
		if err != nil {
			continue
		}
		go handleHTTP(c, cfgp)
	}
}

func handleHTTP(c net.Conn, cfgp *ProxyConfig) {
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(cfg.DialTimeout))
	br := bufio.NewReader(c)
	req, err := http.ReadRequest(br)
	if err != nil {
		return
	}
	_ = c.SetDeadline(time.Time{})
	if cfgp.Username != "" {
		auth := req.Header.Get("Proxy-Authorization")
		ok := false
		if strings.HasPrefix(auth, "Basic ") {
			p, _ := base64.StdEncoding.DecodeString(strings.TrimPrefix(auth, "Basic "))
			pair := strings.SplitN(string(p), ":", 2)
			if len(pair) == 2 && pair[0] == cfgp.Username && pair[1] == cfgp.Password {
				ok = true
			}
		}
		if !ok {
			_, _ = c.Write([]byte("HTTP/1.1 407 需要认证\r\nProxy-Authenticate: Basic realm=\"代理\"\r\n\r\n"))
			return
		}
	}

	target := req.Host
	if !strings.Contains(target, ":") {
		if req.Method == "CONNECT" {
			target += ":443"
		} else {
			target += ":80"
		}
	}

	var first []byte

	if req.Method != "CONNECT" {
		req.RequestURI = ""
		req.URL.Scheme = ""
		req.URL.Host = ""
		var buf bytes.Buffer
		_ = req.Write(&buf)
		first = buf.Bytes()
	}

	// Mac 版改动：出站前先过一遍分流规则
	ob, err := dialTargetWithRoute(target)
	if err != nil {
		// CONNECT 隧道失败不能回 200（浏览器会以为通了开始发 TLS 数据，
		// 而隧道根本没建起来）—— 必须回 502 让浏览器走重试/报错。
		if req.Method == "CONNECT" {
			_, _ = c.Write([]byte("HTTP/1.1 502 Bad Gateway\r\n\r\n"))
		}
		return
	}

	// CONNECT 在隧道建好（CONNECTED）后才回 200：浏览器收到 200 时隧道
	// 已经能收数据，首包不会因为"先回 200 后建隧道"的空窗期而超时。
	if req.Method == "CONNECT" {
		_, _ = c.Write([]byte("HTTP/1.1 200 连接已建立\r\n\r\n"))
	}
	if len(first) > 0 {
		if _, err := ob.rw.Write(first); err != nil {
			_ = ob.rw.Close()
			return
		}
	}
	// bufio 可能已预读了后续字节（个别客户端不等 200 就发数据）。
	// 这些字节不能丢，否则隧道看似通、TLS 握手却永远完不成：
	// 把它们作为首帧一并喂给隧道。
	if br.Buffered() > 0 {
		buffered, _ := br.Peek(br.Buffered())
		if len(buffered) > 0 {
			if _, err := ob.rw.Write(buffered); err != nil {
				_ = ob.rw.Close()
				return
			}
		}
	}
	logRouteEvent(c, "HTTP", target, ob, true)
	defer logRouteEvent(c, "HTTP", target, ob, false)
	relayOutbound(c, ob, target)
}
