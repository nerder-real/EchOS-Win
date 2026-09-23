package main

import (
	"net"
	"testing"
)

// nilAddrConn 模拟 RemoteAddr() 返回 nil 的 TUN 连接 —— gonet.TCPConn
// 在连接尚未完全建立、或已被关闭时就是这种情况。
type nilAddrConn struct{ net.Conn }

func (nilAddrConn) RemoteAddr() net.Addr { return nil }

// TestTunPeerAddrNilSafe 断言远端地址为 nil 时不会打出 `%!s(<nil>)`。
//
// 真机日志里出现过 `[TUN][TCP][proxy] %!s(<nil>) -> 183.60.15.198:443`，
// 就是 conn.RemoteAddr() 返回 nil 之后被直接塞进 %s 的结果。
func TestTunPeerAddrNilSafe(t *testing.T) {
	if got := tunPeerAddr(nilAddrConn{}); got != "?" {
		t.Errorf("nil 远端地址应格式化为 \"?\"，实际得到 %q", got)
	}
}
