package main

// TunConfig holds TUN mode configuration.
// Matches Xray's Config struct (proxy/tun/config.proto) but without protobuf dependency.
type TunConfig struct {
	// Name of the TUN interface (e.g. "xray_tun")
	Name string

	// MTU for the TUN interface (default 9000)
	MTU int

	// Gateway IP addresses to assign to the TUN interface (e.g. "172.18.0.1/30")
	Gateway []string

	// DNS servers to push via DHCP on Windows
	DNS []string

	// AutoSystemRoutingTable contains CIDR prefixes that will be routed through the TUN
	// (e.g. "0.0.0.0/0" for full tunnel, or specific subnets for split tunnel)
	AutoSystemRoutingTable []string
}
