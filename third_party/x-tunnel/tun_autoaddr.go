//go:build windows

package main

import (
	"log"
	"net"
	"net/netip"
	"strings"
)

var tunIPv4Candidates = []string{
	"172.18.0.1/30",
	"172.19.0.1/30",
	"172.20.0.1/30",
	"172.21.0.1/30",
	"172.22.0.1/30",
	"172.23.0.1/30",
	"172.24.0.1/30",
	"172.25.0.1/30",
	"172.26.0.1/30",
	"172.27.0.1/30",
	"172.28.0.1/30",
	"172.29.0.1/30",
	"172.30.0.1/30",
	"172.31.0.1/30",
	"198.18.0.1/30",
	"198.19.0.1/30",
	"10.255.255.1/30",
}

// chooseTunIPv4Config chooses a TUN IPv4 /30 that does not overlap the current
// active local interface prefixes. If no better candidate exists, it falls back
// to the historical default 172.18.0.1/30.
func chooseTunIPv4Config() (gatewayCIDR string, dnsIP string) {
	occupied := collectLocalPrefixes()
	defaultCIDR := tunIPv4Candidates[0]
	defaultPrefix := netip.MustParsePrefix(defaultCIDR)
	defaultConflict, conflictWith := prefixConflicts(defaultPrefix, occupied)
	if !defaultConflict {
		log.Printf("[TUN] 选定 IPv4 网段: %s", defaultCIDR)
		return defaultCIDR, defaultPrefix.Addr().String()
	}

	for _, cidr := range tunIPv4Candidates[1:] {
		candidate, err := netip.ParsePrefix(cidr)
		if err != nil {
			continue
		}
		if ok, _ := prefixConflicts(candidate, occupied); ok {
			continue
		}
		log.Printf("[TUN] 检测到默认 TUN 网段与本地网段冲突（%s），自动切换为 %s", conflictWith, cidr)
		log.Printf("[TUN] 选定 IPv4 网段: %s", cidr)
		return cidr, candidate.Addr().String()
	}

	log.Printf("[TUN] 未找到无冲突的 TUN IPv4 网段，仍使用默认 %s", defaultCIDR)
	log.Printf("[TUN] 选定 IPv4 网段: %s", defaultCIDR)
	return defaultCIDR, defaultPrefix.Addr().String()
}

func collectLocalPrefixes() []netip.Prefix {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var prefixes []netip.Prefix
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		if isVirtualInterface(strings.ToLower(iface.Name)) {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ipNet, ok := addr.(*net.IPNet)
			if !ok {
				continue
			}
			ip, ok := netip.AddrFromSlice(ipNet.IP)
			if !ok || !ip.Is4() {
				continue
			}
			ones, _ := ipNet.Mask.Size()
			prefixes = append(prefixes, netip.PrefixFrom(ip.Unmap(), ones).Masked())
		}
	}
	return prefixes
}

func prefixConflicts(candidate netip.Prefix, occupied []netip.Prefix) (bool, string) {
	candidate = candidate.Masked()
	for _, p := range occupied {
		p = p.Masked()
		if p.Contains(candidate.Addr()) || candidate.Contains(p.Addr()) {
			return true, p.String()
		}
	}
	return false, ""
}
