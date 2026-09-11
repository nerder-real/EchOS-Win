
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
	simpleConnectTimeout = 4 * time.Second  // 加快失败反馈

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

// pickIP 从优选 IP 列表里轮流取一个，没配就返回空串（直接解析服务器域名）。
var simpleIPCounter uint64

func (p *ECHPool) pickIP() string {
	if len(p.targetIPs) == 0 {
		return ""
	}
	n := atomic.AddUint64(&simpleIPCounter, 1)
	return p.targetIPs[int(n)%len(p.targetIPs)]
}

// dialSimpleWS 为一个目标地址开一条新的 WebSocket 并完成 CONNECT 握手。
func dialSimpleWS(target string) (net.Conn, error) {
	// 直连模式：每次新建 WebSocket（与 ech-wk 客户端行为一致）。
	// 预热池（含 dialGate 并发闸门）在 CF 简易服务端下既可能发出
	// "已被服务端悄悄关掉的死连接"，又会把并发握手限死在 6 条 ——
	// YouTube 这种多连接大流量一上来就被卡在并发闸门上，吞吐上不去。
	return dialSimpleWSTimeout(target, simpleConnectTimeout)
}

func dialSimpleWSTimeout(target string, timeout time.Duration) (net.Conn, error) {
	if echPool == nil {
		return nil, errors.New("连接池未初始化")
	}
	t0 := time.Now()

	// 完全绕过预热池与并发闸门，每次全新建连（ech-wk 等价路径）。
	ws, err := echPool.dialWebSocketWithECH(echPool.wsServerAddr, 2, echPool.pickIP(), "", 0)
	if err != nil {
		return nil, err
	}

	// 首帧留空：那个字段在服务端会过 TextEncoder，塞二进制进去必然被改写。
	// 真正的数据等 CONNECTED 之后用二进制帧发。
	_ = ws.SetWriteDeadline(time.Now().Add(timeout))
	if err := ws.WriteMessage(websocket.TextMessage, []byte("CONNECT:"+target+"|")); err != nil {
		_ = ws.Close()
		return nil, fmt.Errorf("发送 CONNECT 失败: %w", err)
	}

	// 等服务端确认。服务端在这一步可能直接回 ERROR:（目标连不上等）
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
