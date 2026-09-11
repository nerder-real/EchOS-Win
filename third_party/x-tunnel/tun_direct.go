//go:build windows

package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Windows socket options not defined in x/sys/windows
const (
	_IP_UNICAST_IF   = 31 // IP_UNICAST_IF at IPPROTO_IP level
	_IPV6_UNICAST_IF = 31 // IPV6_UNICAST_IF at IPPROTO_IPV6 level
)

func findPhysicalInterface() *net.Interface {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	for i := range ifaces {
		if ifaces[i].Flags&net.FlagUp == 0 || ifaces[i].Flags&net.FlagLoopback != 0 {
			continue
		}
		name := strings.ToLower(ifaces[i].Name)
		if isVirtualInterface(name) {
			continue
		}
		addrs, err := ifaces[i].Addrs()
		if err != nil || len(addrs) == 0 {
			continue
		}
		if strings.Contains(name, "eth") || strings.Contains(name, "enp") ||
			strings.Contains(name, "wlan") || strings.Contains(name, "wi-fi") ||
			strings.Contains(name, "ethernet") ||
			strings.Contains(name, "以太网") || // Chinese: 以太网
			strings.Contains(name, "本地连接") || // Chinese: 本地连接
			strings.Contains(name, "宽带") || // Chinese: 宽带
			strings.Contains(name, "局域网") || // Chinese: 局域网
			strings.Contains(name, "无线") || // Chinese: 无线
			strings.Contains(name, "网络") { // Chinese: 网络 (broad match)
			return &ifaces[i]
		}
	}
	for i := range ifaces {
		if ifaces[i].Flags&net.FlagUp == 0 || ifaces[i].Flags&net.FlagLoopback != 0 {
			continue
		}
		name := strings.ToLower(ifaces[i].Name)
		if isVirtualInterface(name) {
			continue
		}
		addrs, err := ifaces[i].Addrs()
		if err != nil || len(addrs) == 0 {
			continue
		}
		return &ifaces[i]
	}
	return nil
}

func isVirtualInterface(name string) bool {
	virtual := []string{"xtun", "xray_tun", "xray0", "singbox_tun", "wintun",
		"vethernet", "vswitch", "docker", "bluetooth", "pseudo",
		"vbox", "vmnet", "hyper-v", "loopback", "isatap", "teredo",
		"6to4", "nlas", "npcap", "npcaps", "wsl", "tailscale"}
	for _, v := range virtual {
		if strings.Contains(name, v) {
			return true
		}
	}
	return false
}

// getLocalIPFromInterface returns the first IPv4 or IPv6 address of the given interface.
func getLocalIPFromInterface(iface *net.Interface, wantIPv6 bool) (net.IP, error) {
	if iface == nil {
		return nil, errors.New("nil interface")
	}
	addrs, err := iface.Addrs()
	if err != nil {
		return nil, err
	}
	for _, addr := range addrs {
		ipNet, ok := addr.(*net.IPNet)
		if !ok {
			continue
		}
		ip := ipNet.IP
		if wantIPv6 {
			if ip.To4() == nil && len(ip) == 16 && !ip.IsLinkLocalUnicast() && !ip.IsLinkLocalMulticast() {
				return ip, nil
			}
		} else {
			if v4 := ip.To4(); v4 != nil {
				return v4, nil
			}
		}
	}
	if wantIPv6 {
		return nil, fmt.Errorf("no global IPv6 on %s", iface.Name)
	}
	return nil, fmt.Errorf("no IPv4 on %s", iface.Name)
}

// setUnicastIF sets IP_UNICAST_IF (IPv4) or IPV6_UNICAST_IF (IPv6) on a socket fd.
func setUnicastIF(fd uintptr, ifaceIdx int, isIPv6 bool) error {
	if isIPv6 {
		// IPV6_UNICAST_IF: interface index in host byte order
		return windows.SetsockoptInt(windows.Handle(fd), windows.IPPROTO_IPV6, _IPV6_UNICAST_IF, ifaceIdx)
	}
	// IP_UNICAST_IF: interface index in network byte order (big-endian)
	var idx [4]byte
	binary.BigEndian.PutUint32(idx[:], uint32(ifaceIdx))
	idxVal := *(*int32)(unsafe.Pointer(&idx[0]))
	return windows.SetsockoptInt(windows.Handle(fd), windows.IPPROTO_IP, _IP_UNICAST_IF, int(idxVal))
}

// directDialTCP dials a TCP connection bound to the physical interface.
// Uses IP_UNICAST_IF/IPV6_UNICAST_IF to force traffic through the physical NIC
// instead of the TUN interface. LocalAddr is intentionally not pinned so the OS
// can choose the current address on that NIC after WiFi↔有线切换.
func directDialTCP(target string, iface *net.Interface) (net.Conn, error) {
	if iface == nil {
		return net.DialTimeout("tcp", target, 10*time.Second)
	}
	host, _, err := net.SplitHostPort(target)
	if err != nil {
		return nil, err
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return net.DialTimeout("tcp", target, 10*time.Second)
	}
	isIPv6 := ip.To4() == nil

	ifaceIdx := iface.Index
	network := "tcp4"
	if isIPv6 {
		network = "tcp6"
	}

	d := &net.Dialer{
		Timeout: 5 * time.Second,
		Control: func(network, address string, c syscall.RawConn) error {
			var sockErr error
			err := c.Control(func(fd uintptr) {
				sockErr = setUnicastIF(fd, ifaceIdx, isIPv6)
			})
			if err != nil {
				return err
			}
			return sockErr
		},
	}
	return d.Dial(network, target)
}

// directDialUDP creates a UDP connection bound to the physical interface.
func directDialUDP(host string, port int, iface *net.Interface) (*net.UDPConn, error) {
	ip := net.ParseIP(host)
	if ip == nil {
		return nil, errors.New("invalid IP: " + host)
	}
	isIPv6 := ip.To4() == nil

	network := "udp4"
	if isIPv6 {
		network = "udp6"
	}
	target := net.JoinHostPort(host, fmt.Sprintf("%d", port))
	if iface == nil {
		raddr := &net.UDPAddr{IP: ip, Port: port}
		return net.DialUDP(network, nil, raddr)
	}
	d := &net.Dialer{
		Timeout: 5 * time.Second,
		Control: func(network, address string, c syscall.RawConn) error {
			var sockErr error
			err := c.Control(func(fd uintptr) {
				sockErr = setUnicastIF(fd, iface.Index, isIPv6)
			})
			if err != nil {
				return err
			}
			return sockErr
		},
	}
	conn, err := d.Dial(network, target)
	if err != nil {
		return nil, err
	}
	udpConn, ok := conn.(*net.UDPConn)
	if !ok {
		_ = conn.Close()
		return nil, fmt.Errorf("unexpected UDP conn type %T", conn)
	}
	return udpConn, nil
}

func directProxyStream(c1, c2 net.Conn) {
	done := make(chan struct{}, 2)
	activity := make(chan struct{}, 1)
	go func() {
		buf := make([]byte, 32*1024)
		for {
			n, err := c1.Read(buf)
			if n > 0 {
				if _, werr := c2.Write(buf[:n]); werr != nil {
					done <- struct{}{}
					return
				}
				select {
				case activity <- struct{}{}:
				default:
				}
			}
			if err != nil {
				done <- struct{}{}
				return
			}
		}
	}()
	go func() {
		buf := make([]byte, 32*1024)
		for {
			n, err := c2.Read(buf)
			if n > 0 {
				if _, werr := c1.Write(buf[:n]); werr != nil {
					done <- struct{}{}
					return
				}
				select {
				case activity <- struct{}{}:
				default:
				}
			}
			if err != nil {
				done <- struct{}{}
				return
			}
		}
	}()
	timer := time.NewTimer(5 * time.Minute)
	defer timer.Stop()
	for {
		select {
		case <-done:
			c1.Close()
			c2.Close()
			<-done
			return
		case <-activity:
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(5 * time.Minute)
		case <-timer.C:
			c1.Close()
			c2.Close()
			<-done
			return
		}
	}
}

func hasGlobal6(iface *net.Interface) bool {
	if iface == nil {
		return false
	}
	a, _ := iface.Addrs()
	for _, ad := range a {
		ip, ok := ad.(*net.IPNet)
		if !ok {
			continue
		}
		v := ip.IP.To16()
		if len(v) == 16 && (v[0]&0xE0) == 0x20 {
			return true
		}
	}
	return false
}

func hasIPv4(iface *net.Interface) bool {
	if iface == nil {
		return false
	}
	a, _ := iface.Addrs()
	for _, ad := range a {
		ip, ok := ad.(*net.IPNet)
		if !ok {
			continue
		}
		if ip.IP.To4() != nil {
			return true
		}
	}
	return false
}

// hasPublicIPv6OnAnyNIC checks whether any non-virtual physical NIC
// has a global-scope IPv6 address (2000::/3).
