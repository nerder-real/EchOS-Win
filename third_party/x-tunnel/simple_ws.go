package main

import (
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

// 「简易 WebSocket 代理」协议。
//
// 社区里流传的 Cloudflare Worker 服务端（就是 `WebSocket Proxy Server` 那一版）
// 用的并不是 x-tunnel 的 smux 多路复用协议，而是一套朴素得多的东西：
//
//	客户端 → 服务端   文本  "CONNECT:example.com:443|"   建立到目标的连接
//	服务端 → 客户端   文本  "CONNECTED"                   连上了
//	双向              二进制 原始字节                      之后就是纯透传
//	任意方向          文本  "CLOSE" / "ERROR:xxx"         结束
//
// 关键差别是**一个 WebSocket 只服务一条 TCP 连接**，没有多路复用。
// 客户端如果按 smux 那套发帧，服务端因为没收到过 CONNECT，remoteWriter 是 null，
// 会把所有二进制帧默默丢掉 —— 表现就是"握手成功、认证通过、然后永远没有响应"。
//
// 这里实现这套协议，让 EchOS 能直连这类服务端。

const (
	simpleConnectTimeout = 4 * time.Second // 加快失败反馈

	// simpleFastFail 是「抢热实例」的建连阈值。
	//
	// 握手这一步 = TCP + TLS(ECH) + WS 升级 + CONNECT，再加上服务端 Worker 去
	// 连目标站点的时间。客户端能控制的前半段只有约 110ms（实测入口 RTT 22ms），
	// 后半段完全取决于服务端那一次调用。
	//
	// 实测：握手 >=600ms 的连接，后续传输中位只有 0.31 MB/s；握手正常的连接
	// 中位 4.68 MB/s —— 差 15 倍。也就是说「建连慢」和「传得慢」是同一次服务端
	// 调用慢的两个表现，硬等下去只会继续慢。与其干等，不如早点放弃换一条。
	simpleFastFail = 700 * time.Millisecond
)

// WebSocket 应用层保活。
//
// 播放器缓冲满之后，隧道可能几十秒都没有任何数据。实测这类空闲连接会在约
// 120 秒时被中间链路（Cloudflare 边缘）回收：内核里没有任何 120 秒超时，
// 日志里那批“存活时间正好 120 秒”的连接就是这么没的。TCP 保活（见
// physKeepAlive）只能刷新传输层的空闲计时器，中间的 WebSocket / HTTP 层
// 不一定认账；应用层 ping 才是中间设备一定计数的活动。
//
// 另一个好处：ping 写不出来基本等价于连接已经死了，这里直接关掉，让转发
// 循环立刻退出，而不是再挂两分钟才由对端超时暴露出来。
const (
	wsPingInterval = 30 * time.Second
	wsPingTimeout  = 10 * time.Second
)

// simpleWSConn 把一条「已 CONNECTED 的 WebSocket」包装成 net.Conn。
type simpleWSConn struct {
	ws     *websocket.Conn
	reader io.Reader

	readMu  sync.Mutex
	writeMu sync.Mutex

	closed   atomic.Bool
	closeErr error

	stopPing chan struct{}
}

func (c *simpleWSConn) Read(p []byte) (int, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()
	for {
		if c.reader == nil {
			mt, r, err := c.ws.NextReader()
			if err != nil {
				return 0, err
			}
			if mt == websocket.TextMessage {
				// 控制消息：CLOSE 表示对端结束，ERROR: 带出服务端的失败原因
				msg, _ := io.ReadAll(r)
				text := string(msg)
				switch {
				case text == "CLOSE":
					return 0, io.EOF
				case strings.HasPrefix(text, "ERROR:"):
					return 0, fmt.Errorf("服务端错误: %s", strings.TrimPrefix(text, "ERROR:"))
				default:
					// CONNECTED 之类的多余控制字，忽略继续读
					continue
				}
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
		return n, err
	}
}

func (c *simpleWSConn) Write(p []byte) (int, error) {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	// 一律走二进制帧：服务端那边 `data instanceof ArrayBuffer` 分支直接透传，
	// 不能用文本 DATA: 前缀 —— 那条路径会经过 TextEncoder，二进制数据会被 UTF-8 改写。
	if err := c.ws.WriteMessage(websocket.BinaryMessage, p); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (c *simpleWSConn) Close() error {
	if !c.closed.CompareAndSwap(false, true) {
		return c.closeErr
	}
	if c.stopPing != nil {
		close(c.stopPing)
	}
	c.writeMu.Lock()
	_ = c.ws.WriteMessage(websocket.TextMessage, []byte("CLOSE"))
	c.writeMu.Unlock()
	c.closeErr = c.ws.Close()
	return c.closeErr
}

func (c *simpleWSConn) LocalAddr() net.Addr  { return c.ws.LocalAddr() }
func (c *simpleWSConn) RemoteAddr() net.Addr { return c.ws.RemoteAddr() }

func (c *simpleWSConn) SetDeadline(t time.Time) error {
	_ = c.ws.SetReadDeadline(t)
	return c.ws.SetWriteDeadline(t)
}
func (c *simpleWSConn) SetReadDeadline(t time.Time) error  { return c.ws.SetReadDeadline(t) }
func (c *simpleWSConn) SetWriteDeadline(t time.Time) error { return c.ws.SetWriteDeadline(t) }

// startKeepAlive 起一个后台协程周期发 ping，直到连接关闭。
func (c *simpleWSConn) startKeepAlive() {
	if c.stopPing == nil {
		return
	}
	go func() {
		t := time.NewTicker(wsPingInterval)
		defer t.Stop()
		for {
			select {
			case <-c.stopPing:
				return
			case <-t.C:
				if c.closed.Load() {
					return
				}
				deadline := time.Now().Add(wsPingTimeout)
				if err := c.ws.WriteControl(websocket.PingMessage, []byte("k"), deadline); err != nil {
					_ = c.Close()
					return
				}
			}
		}
	}()
}

// ---- 边缘粘性主选与冷却（03-边缘优选）----
//
// 历史教训（2026-11-15 实测后撤除连接池）：曾实现「预热池 + 借出复用」，
// 但 CF Workers 平台在客户端首帧之前会终止空 WS 连接（约 10~20s，ctx.waitUntil
// 也保不住）——借出 10 次全部 CONNECTED 超时，池纯负贡献，已整体撤除。
// 保留的是与池无关、被实测验证的两件：边缘粘性主选 + 拨号失败冷却。
const edgeFailCooldown = 60 * time.Second // 边缘拨号失败冷却
// markEdgeFail / markEdgeOK：边缘冷却。拨号失败冷却该边缘 60s
// （粘性主选自动跳到次位），成功即解除。两函数各持 edgeMu，并发安全。
func (p *ECHPool) markEdgeFail(ip string) {
	if ip == "" {
		return
	}
	p.edgeMu.Lock()
	if p.edgeFailUntil == nil {
		p.edgeFailUntil = make(map[string]time.Time)
	}
	p.edgeFailUntil[ip] = time.Now().Add(edgeFailCooldown)
	p.edgeMu.Unlock()
}

func (p *ECHPool) markEdgeOK(ip string) {
	if ip == "" {
		return
	}
	p.edgeMu.Lock()
	delete(p.edgeFailUntil, ip)
	p.edgeMu.Unlock()
}

// pickIP 粘性主选：取第一个不在冷却期的边缘，主选拨号失败被 markEdgeFail
// 冷却后自动跳到次位，恢复（markEdgeOK）后回切。（03-边缘优选落地后
// targetIPs 会按吞吐降序排列，粘住的将是吞吐冠军。）
//
// 全部候选都在冷却期时，退回**冷却最早到期**的边缘——它是最可能先恢复的；
// 退回首项的话，候选被吞吐门槛剔到只剩 1~2 个时（2026-11-15 实测环境），
// 重试会连续撞同一个边缘，故障转移名存实亡。
func (p *ECHPool) pickIP() string {
	if len(p.targetIPs) == 0 {
		return ""
	}
	p.targetIPsMu.RLock()
	defer p.targetIPsMu.RUnlock()
	p.edgeMu.Lock()
	defer p.edgeMu.Unlock()
	best := p.targetIPs[0]
	var bestUntil time.Time
	for _, ip := range p.targetIPs {
		until, bad := p.edgeFailUntil[ip]
		if !bad || time.Now().After(until) {
			return ip // 未冷却：直接可用
		}
		if bestUntil.IsZero() || until.Before(bestUntil) {
			best, bestUntil = ip, until
		}
	}
	return best
}

// currentTargetIPs 返回当前候选的快照（边缘优选复测循环的输入）。
func (p *ECHPool) currentTargetIPs() []string {
	p.targetIPsMu.RLock()
	defer p.targetIPsMu.RUnlock()
	return append([]string(nil), p.targetIPs...)
}

// setTargetIPs 原子替换候选列表（复测结果非空时调用）。
func (p *ECHPool) setTargetIPs(ips []string) {
	p.targetIPsMu.Lock()
	p.targetIPs = ips
	p.targetIPsMu.Unlock()
}

// simpleWSHandshake 供边缘优选（tun_iprank）使用：在一条裸 WS 上完成
// CONNECT 握手，返回可读写的 net.Conn。与 finishSimpleConnect 同一条链，
// 不做慢握手日志（探针自己按样本计时）。
func simpleWSHandshake(ws *websocket.Conn, target string, timeout time.Duration) (net.Conn, error) {
	return finishSimpleConnect(ws, target, timeout, time.Now())
}

// finishSimpleConnect 在一条裸 WS 上发 CONNECT 并等 CONNECTED。
// timeout 是等 CONNECTED 的时限（调用方按 fast-fail 语义传入）。
// 失败时关闭 ws。
func finishSimpleConnect(ws *websocket.Conn, target string, timeout time.Duration, t0 time.Time) (net.Conn, error) {
	_ = ws.SetWriteDeadline(time.Now().Add(timeout))
	if err := ws.WriteMessage(websocket.TextMessage, []byte("CONNECT:"+target+"|")); err != nil {
		_ = ws.Close()
		return nil, fmt.Errorf("发送 CONNECT 失败: %w", err)
	}
	_ = ws.SetReadDeadline(time.Now().Add(timeout))
	for {
		mt, data, err := ws.ReadMessage()
		if err != nil {
			_ = ws.Close()
			return nil, fmt.Errorf("等待 CONNECTED 失败: %w", err)
		}
		if mt != websocket.TextMessage {
			// 理论上不该在 CONNECTED 之前收到二进制，收到就当它是数据，继续等
			continue
		}
		text := string(data)
		switch {
		case text == "CONNECTED":
			// 建连耗时 = TCP + TLS(ECH) + WS 升级 + CONNECT 四个往返。慢只打日志：
			// 正常连接几十毫秒，全是几百毫秒说明入口或链路有问题。
			if el := time.Since(t0); el >= 600*time.Millisecond {
				log.Printf("[建连] %s 慢握手 %dms", target, el.Milliseconds())
			}
			_ = ws.SetReadDeadline(time.Time{})
			_ = ws.SetWriteDeadline(time.Time{})
			c := &simpleWSConn{ws: ws, stopPing: make(chan struct{})}
			c.startKeepAlive()
			return c, nil
		case strings.HasPrefix(text, "ERROR:"):
			_ = ws.Close()
			return nil, fmt.Errorf("服务端拒绝: %s", strings.TrimPrefix(text, "ERROR:"))
		case text == "CLOSE":
			_ = ws.Close()
			return nil, errors.New("服务端主动关闭")
		}
	}
}

func dialSimpleWSTimeout(target string, timeout time.Duration) (net.Conn, error) {
	if echPool == nil {
		return nil, errors.New("连接池未初始化")
	}
	t0 := time.Now()

	// 全新拨号（2026-11-15 终态：连接池已撤除——CF Workers 平台在客户端
	// 首帧之前终止空 WS 连接，预热借出模式在平台上不可行，见
	// 「边缘粘性主选与冷却」注释块的历史教训）。
	ip := echPool.pickIP()
	ws, err := echPool.dialWebSocketWithECH(echPool.wsServerAddr, 2, ip, "", 0)
	if err != nil {
		echPool.markEdgeFail(ip)
		return nil, err
	}
	conn, err := finishSimpleConnect(ws, target, timeout, t0)
	if err != nil {
		echPool.markEdgeFail(ip)
		return nil, err
	}
	echPool.markEdgeOK(ip)
	return conn, nil
}

// probeSimpleProtocol 探测服务端是不是这种「简易 WebSocket 代理」。
// 拿一个必然存在的目标试一次 CONNECT，能收到 CONNECTED 就说明是。
func probeSimpleProtocol() bool {
	if echPool == nil {
		return false
	}
	ws, err := echPool.dialWebSocketWithECH(echPool.wsServerAddr, 1, echPool.pickIP(), "", 0)
	if err != nil {
		return false
	}
	defer ws.Close()

	// 探测目标特意避开 Cloudflare 自家网段：Worker 的 connect() 不允许连回 CF，
	// 拿 1.1.1.1 去探会稳定收到 ERROR，白白误导判断。
	// 超时给足 10s：ECH 查询 + TLS 握手 + WS 升级可能就要好几秒，
	// 之前 4s 在 DoH 刚恢复/链路慢时不够，探测误判成 smux → simple 服务端黑洞。
	_ = ws.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if err := ws.WriteMessage(websocket.TextMessage, []byte("CONNECT:8.8.8.8:53|")); err != nil {
		return false
	}

	_ = ws.SetReadDeadline(time.Now().Add(10 * time.Second))
	mt, data, err := ws.ReadMessage()
	if err != nil {
		// 没有任何回应 —— x-tunnel 服务端就是这个反应，它在等 smux 帧
		return false
	}
	if mt != websocket.TextMessage {
		return false
	}
	text := string(data)
	// CONNECTED 固然是肯定答复，ERROR: 同样说明服务端读懂了 CONNECT 指令，
	// 只是那个目标它连不上而已 —— 两者都足以判定这是简易 WebSocket 代理。
	return text == "CONNECTED" || strings.HasPrefix(text, "ERROR:")
}
