//go:build windows

package main

import (
	"net"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Windows IfType 取值（ipifcons.h）
const (
	winIfTypeEthernet uint32 = 6   // 以太网
	winIfTypeWiFi     uint32 = 71  // IEEE 802.11
	winIfTypeLoopback uint32 = 24  // 环回
	winIfTypeTunnel   uint32 = 131 // HostedNetwork / 软隧道
)

// Windows GetAdaptersAddresses flag bits
const (
	gaaSkipAnycast     = 0x0002
	gaaSkipMulticast   = 0x0004
	gaaSkipFriendly    = 0x0040
	gaaIncludePrefix   = 0x0010
	gaaIncludeGateways = 0x0080
)

// physCandidate 是 API 判定阶段挑出的候选物理网卡。
type physCandidate struct {
	ifIndex  uint32
	ifType   uint32
	name     string // AdapterName（GUID）
	friendly string // FriendlyName
	metric   uint32
}

// detectPhysIfaceIndexAPI 用 GetAdaptersAddresses 的原生字段硬判定物理出口网卡，
// 避免误选 Microsoft Wi-Fi Direct Virtual Adapter（ICS 共享虚拟 AP）等虚拟网卡。
// 仅在 Windows 构建时存在；无候选时返回 -1，上层可退回旧启发式。
func detectPhysIfaceIndexAPI() int {
	flags := uint32(gaaSkipAnycast | gaaSkipMulticast | gaaSkipFriendly | gaaIncludePrefix | gaaIncludeGateways)

	var size uint32
	err := windows.GetAdaptersAddresses(windows.AF_UNSPEC, flags, 0, nil, &size)
	if err != nil && err != windows.ERROR_BUFFER_OVERFLOW {
		return -1
	}
	buf := make([]byte, size)
	root := (*windows.IpAdapterAddresses)(unsafe.Pointer(&buf[0]))
	if err := windows.GetAdaptersAddresses(windows.AF_UNSPEC, flags, 0, root, &size); err != nil {
		return -1
	}

	var best *physCandidate
	for a := root; a != nil; a = a.Next {
		// 1. 在线
		if a.OperStatus != windows.IfOperStatusUp {
			continue
		}
		// 2. 物理类：以太网 / Wi-Fi（排除环回、软隧道、PPP 等）
		if a.IfType != winIfTypeEthernet && a.IfType != winIfTypeWiFi {
			continue
		}
		// 3. 非隧道（挡 Teredo/ISATAP/IPHTTPS 等）
		if a.TunnelType != 0 {
			continue
		}
		// 4. 必须有上游默认网关 —— 这条精准排除 Wi-Fi Direct 虚拟 AP、
		//    蓝牙 PAN、vEthernet(Default Switch/WSL) 等无出口网关的虚拟/本地段网卡。
		if a.FirstGatewayAddress == nil {
			continue
		}
		// 5. 取首个单播 IPv4 并据此二次过滤
		ip4 := firstUnicastIPv4(a)
		if ip4 == nil {
			continue
		}
		if ip4.IsLoopback() || ip4.IsLinkLocalUnicast() {
			continue // 排除 169.254/127.0.0.1
		}
		if isICSRouterAddress(ip4) {
			continue // 排除 ICS 虚拟网关 192.168.137.x（双保险）
		}
		friendly := utf16PtrToGoString(a.FriendlyName)
		name := asciiPtrToGoString(a.AdapterName)
		// 6. 排除名字层面仍能识别的虚拟/回环网卡（Hyper-V vSwitch、xtun 等）
		if looksVirtualByName(friendly, name) {
			continue
		}

		c := &physCandidate{
			ifIndex:  a.IfIndex,
			ifType:   a.IfType,
			name:     name,
			friendly: friendly,
			metric:   a.Ipv4Metric,
		}
		// 多候选时：优先有更高带宽概念（这里用 metric 兜底，越小越优）。
		if best == nil || c.metric < best.metric {
			best = c
		}
	}
	if best == nil {
		return -1
	}
	return int(best.ifIndex)
}

func firstUnicastIPv4(a *windows.IpAdapterAddresses) net.IP {
	for u := a.FirstUnicastAddress; u != nil; u = u.Next {
		ip := u.Address.IP()
		if ip == nil {
			continue
		}
		if v4 := ip.To4(); v4 != nil {
			return v4
		}
	}
	return nil
}

// isICSRouterAddress 判断是否为 Windows ICS 默认虚拟网关网段 192.168.137.0/24。
// ICS 共享开启时，负责"广播"那张虚拟 AP 会固定拿到 192.168.137.1，DHCP 段也是 192.168.137.0/24。
func isICSRouterAddress(ip net.IP) bool {
	v4 := ip.To4()
	if v4 == nil {
		return false
	}
	return v4[0] == 192 && v4[1] == 168 && v4[2] == 137
}

// looksVirtualByName 对 API 判定兜不住的虚拟网卡做名字二次排除。
// 主要防 Hyper-V vEthernet、xtun/wintun、Wi-Fi Direct（本地名/连接*）误标。
func looksVirtualByName(friendly, adapterName string) bool {
	f := strings.ToLower(friendly)
	n := strings.ToLower(adapterName)
	virtual := []string{
		"vethernet", "virtual", "xtun", "wintun", "xray", "singbox", "docker",
		"hyper-v", "vbox", "vmnet", "wsl", "npcap", "teredo", "isatap", "6to4",
	}
	for _, v := range virtual {
		if strings.Contains(f, v) || strings.Contains(n, v) {
			return true
		}
	}
	// Windows 把 Wi-Fi Direct 虚拟卡显示成 "本地连接* N" / "Local Area Connection* N"
	if strings.Contains(f, "本地连接*") || strings.Contains(f, "local area connection*") {
		return true
	}
	return false
}

func asciiPtrToGoString(p *byte) string {
	if p == nil {
		return ""
	}
	var bs []byte
	for i := uintptr(0); ; i++ {
		b := *(*byte)(unsafe.Pointer(uintptr(unsafe.Pointer(p)) + i))
		if b == 0 {
			break
		}
		bs = append(bs, b)
	}
	return string(bs)
}

func utf16PtrToGoString(p *uint16) string {
	if p == nil {
		return ""
	}
	var r []rune
	for i := uintptr(0); ; i++ {
		u := *(*uint16)(unsafe.Pointer(uintptr(unsafe.Pointer(p)) + i*2))
		if u == 0 {
			break
		}
		r = append(r, rune(u))
	}
	return string(r)
}
