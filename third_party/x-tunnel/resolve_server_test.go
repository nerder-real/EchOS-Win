package main

import (
	"net"
	"testing"
)

// TestResolveServerIPv4NoIPv6InPool 断言「IPv4 优先」是**真的**优先：
// 只要解析出了 IPv4，候选池里就不能混入 IPv6。
//
// 背景：cachedServerIP 按 srvRotate 在池子里**轮转**选入口。池里混进一个
// 连不上的 v6，就会每轮转到它一次、白白超时一次 —— 真机日志里成串的
// `dial tcp [2406:cb42:0:f00e::49bd]:443: i/o timeout` 正是这么来的
// （池 = [104.18.42.54, 172.64.145.202, 2406:cb42:...]，每 3 次必中一次 v6）。
//
// 这个断言是防回归的：谁把 return 改回 `append(v4s, v6s...)`，这里就会红。
func TestResolveServerIPv4NoIPv6InPool(t *testing.T) {
	// localhost 是稳定可用的双栈样本；cdns.doon.eu.org 是真机上实际用的
	// 优选域名（实测同时有 A 和 AAAA）。解析不到就跳过，不让离线环境挂测试。
	for _, host := range []string{"localhost", "cdns.doon.eu.org"} {
		ips := resolveServerIPv4(host)
		if len(ips) == 0 {
			t.Logf("%-20s -> 解析不到地址（离线？），跳过", host)
			continue
		}
		t.Logf("%-20s -> %v", host, ips)

		hasV4 := false
		for _, s := range ips {
			ip := net.ParseIP(s)
			if ip == nil {
				t.Errorf("%s: 返回了非 IP 值 %q", host, s)
				continue
			}
			if ip.To4() != nil {
				hasV4 = true
			}
		}
		if !hasV4 {
			t.Logf("%-20s -> 只有 IPv6（兜底路径），跳过断言", host)
			continue
		}
		for _, s := range ips {
			if ip := net.ParseIP(s); ip != nil && ip.To4() == nil {
				t.Errorf("%s: 候选池里混入了 IPv6 %s —— 轮转到它必然超时", host, s)
			}
		}
	}
}
