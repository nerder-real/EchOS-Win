//go:build windows

package main

import (
	"crypto/md5"
	"fmt"
	"net/netip"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wintun"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
)

// WindowsTun wraps a Wintun adapter with IP/route/DNS configuration.
// Ported from Xray-core proxy/tun/tun_windows.go
type WindowsTun struct {
	mu      sync.RWMutex
	cfg     *TunConfig
	adapter *wintun.Adapter
	session wintun.Session
	luid    winipcfg.LUID
	closed  bool
}

// NewTun creates a Wintun interface with the given config.
// If an adapter with the same name exists, it is reused.
func NewTun(cfg *TunConfig) (*WindowsTun, error) {
	if cfg.Name == "" {
		cfg.Name = "xtun"
	}
	if cfg.MTU <= 0 {
		cfg.MTU = 9000
	}

	// Generate deterministic GUID from name (same as Xray)
	sum := md5.Sum([]byte(cfg.Name))
	guid := (*windows.GUID)(unsafe.Pointer(&sum[0]))

	adapter, err := wintun.CreateAdapter(cfg.Name, "X-Tunnel", guid)
	if err != nil {
		return nil, err
	}

	// Ring buffer capacity: 8 MiB (same as Xray)
	session, err := adapter.StartSession(0x800000)
	if err != nil {
		adapter.Close()
		return nil, err
	}

	tun := &WindowsTun{
		cfg:     cfg,
		adapter: adapter,
		session: session,
		luid:    winipcfg.LUID(adapter.LUID()),
	}

	return tun, nil
}

// Start brings the TUN interface up: sets IP, routes, DNS, MTU.
func (t *WindowsTun) Start() error {
	var has4, has6 bool

	allowedIPs := make([]netip.Prefix, 0, len(t.cfg.AutoSystemRoutingTable))
	for _, route := range t.cfg.AutoSystemRoutingTable {
		p, err := netip.ParsePrefix(route)
		if err != nil {
			continue
		}
		allowedIPs = append(allowedIPs, p)
	}

	routesMap := make(map[winipcfg.RouteData]struct{})
	for _, ip := range allowedIPs {
		masked := ip.Masked()
		route := winipcfg.RouteData{
			Destination: masked,
			Metric:      0,
		}
		if ip.Addr().Is4() {
			has4 = true
			route.NextHop = netip.IPv4Unspecified()
		} else {
			has6 = true
			route.NextHop = netip.IPv6Unspecified()
		}
		routesMap[route] = struct{}{}
	}

	routesData := make([]*winipcfg.RouteData, 0, len(routesMap))
	for route := range routesMap {
		r := route
		routesData = append(routesData, &r)
	}

	if err := t.luid.SetRoutes(routesData); err != nil {
		return err
	}

	if len(t.cfg.Gateway) > 0 {
		addresses := make([]netip.Prefix, 0, len(t.cfg.Gateway))
		for _, addr := range t.cfg.Gateway {
			p, err := netip.ParsePrefix(addr)
			if err != nil {
				continue
			}
			addresses = append(addresses, p)
		}
		if err := t.luid.SetIPAddresses(addresses); err != nil {
			return err
		}
	}

	if has4 {
		ipif, err := t.luid.IPInterface(windows.AF_INET)
		if err != nil {
			return err
		}
		ipif.RouterDiscoveryBehavior = winipcfg.RouterDiscoveryDisabled
		ipif.DadTransmits = 0
		ipif.ManagedAddressConfigurationSupported = false
		ipif.OtherStatefulConfigurationSupported = false
		ipif.NLMTU = uint32(t.cfg.MTU)
		ipif.UseAutomaticMetric = false
		ipif.Metric = 0
		if err = ipif.Set(); err != nil {
			return err
		}
	}
	if has6 {
		ipif, err := t.luid.IPInterface(windows.AF_INET6)
		if err != nil {
			return err
		}
		ipif.RouterDiscoveryBehavior = winipcfg.RouterDiscoveryDisabled
		ipif.DadTransmits = 0
		ipif.ManagedAddressConfigurationSupported = false
		ipif.OtherStatefulConfigurationSupported = false
		ipif.NLMTU = uint32(t.cfg.MTU)
		ipif.UseAutomaticMetric = false
		ipif.Metric = 0
		if err = ipif.Set(); err != nil {
			return err
		}
	}

	if len(t.cfg.DNS) > 0 {
		dns4 := make([]netip.Addr, 0, len(t.cfg.DNS))
		dns6 := make([]netip.Addr, 0, len(t.cfg.DNS))
		for _, ip := range t.cfg.DNS {
			addr, err := netip.ParseAddr(ip)
			if err != nil {
				continue
			}
			if addr.Is4() || addr.Is4In6() {
				dns4 = append(dns4, addr.Unmap())
			} else if addr.Is6() {
				dns6 = append(dns6, addr)
			}
		}
		if len(dns4) > 0 {
			if err := t.luid.SetDNS(windows.AF_INET, dns4, nil); err != nil {
				return err
			}
		}
		if len(dns6) > 0 {
			if err := t.luid.SetDNS(windows.AF_INET6, dns6, nil); err != nil {
				return err
			}
		}
	}

	return nil
}

// Close shuts down the TUN interface.
func (t *WindowsTun) Close() error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return nil
	}
	t.closed = true
	t.session.End()
	return t.adapter.Close()
}

// ReadPacket reads one IP packet from the TUN device.
func (t *WindowsTun) ReadPacket() ([]byte, error) {
	packet, err := t.session.ReceivePacket()
	if err != nil {
		return nil, err
	}
	buf := make([]byte, len(packet))
	copy(buf, packet)
	t.session.ReleaseReceivePacket(packet)
	return buf, nil
}

// WritePacket writes one IP packet to the TUN device.
func (t *WindowsTun) WritePacket(data []byte) error {
	packet, err := t.session.AllocateSendPacket(len(data))
	if err != nil {
		return err
	}
	copy(packet, data)
	t.session.SendPacket(packet)
	return nil
}

// ReadWaitEvent returns the event handle for waiting on data availability.
func (t *WindowsTun) ReadWaitEvent() windows.Handle {
	return t.session.ReadWaitEvent()
}

// Index returns the network interface index.
func (t *WindowsTun) Index() (int, error) {
	row, err := t.luid.Interface()
	if err != nil {
		return 0, err
	}
	return int(row.InterfaceIndex), nil
}

// EnsureWintunLoaded checks if wintun.dll is available.
func EnsureWintunLoaded() error {
	ver := wintun.Version()
	if ver != "" {
		return nil
	}
	dll := windows.NewLazyDLL("wintun.dll")
	if err := dll.Load(); err != nil {
		return fmt.Errorf("load wintun.dll: %w", err)
	}
	if ver = wintun.Version(); ver == "" {
		return fmt.Errorf("wintun.dll loaded but version unavailable")
	}
	return nil
}
