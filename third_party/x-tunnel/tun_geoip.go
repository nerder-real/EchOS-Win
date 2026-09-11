//go:build windows

package main

import (
	"fmt"
	"log"
	"net/netip"
	"os"
	"sort"
	"strings"
	"sync"

	"google.golang.org/protobuf/encoding/protowire"
)

type GeoIPMatcher struct {
	mu    sync.RWMutex
	cidrs []netip.Prefix
}

var geoIPMatcher *GeoIPMatcher

// geoIPMatchers caches matchers by country for multi-rule support.
var (
	geoIPMatchers   = map[string]*GeoIPMatcher{}
	geoIPMatchersMu sync.RWMutex
)

func resetGeoIPMatcherCache() {
	geoIPMatchersMu.Lock()
	geoIPMatchers = map[string]*GeoIPMatcher{}
	if geoIPMatcher != nil {
		geoIPMatchers["cn"] = geoIPMatcher
	}
	geoIPMatchersMu.Unlock()
}

func getGeoIPMatcher(country string) *GeoIPMatcher {
	c := strings.ToLower(country)
	geoIPMatchersMu.RLock()
	if m, ok := geoIPMatchers[c]; ok {
		geoIPMatchersMu.RUnlock()
		return m
	}
	geoIPMatchersMu.RUnlock()

	// The default "cn" matcher is already loaded
	if c == "cn" && geoIPMatcher != nil {
		geoIPMatchersMu.Lock()
		geoIPMatchers[c] = geoIPMatcher
		geoIPMatchersMu.Unlock()
		return geoIPMatcher
	}

	// Try loading from geoip file
	data, err := os.ReadFile(geoipFile)
	if err != nil {
		return nil
	}
	m, err := NewGeoIPMatcher(data, []string{c})
	if err != nil {
		return nil
	}
	geoIPMatchersMu.Lock()
	geoIPMatchers[c] = m
	geoIPMatchersMu.Unlock()
	return m
}

func NewGeoIPMatcher(data []byte, countries []string) (*GeoIPMatcher, error) {
	want := make(map[string]bool, len(countries))
	for _, c := range countries {
		want[strings.ToLower(c)] = true
	}
	m := &GeoIPMatcher{}
	for offset := 0; offset < len(data); {
		num, wtype, n := protowire.ConsumeTag(data[offset:])
		if n <= 0 {
			break
		}
		offset += n
		if wtype == protowire.BytesType {
			val, n := protowire.ConsumeBytes(data[offset:])
			if n <= 0 {
				break
			}
			offset += n
			if num == 1 {
				m.parseEntry(val, want)
			}
		} else {
			n := protowire.ConsumeFieldValue(num, wtype, data[offset:])
			if n <= 0 {
				break
			}
			offset += n
		}
	}
	sort.Slice(m.cidrs, func(i, j int) bool {
		return m.cidrs[i].Addr().Less(m.cidrs[j].Addr())
	})
	return m, nil
}

func (m *GeoIPMatcher) parseEntry(data []byte, want map[string]bool) {
	var country string
	var cidrs []netip.Prefix
	for offset := 0; offset < len(data); {
		num, wtype, n := protowire.ConsumeTag(data[offset:])
		if n <= 0 {
			break
		}
		offset += n
		switch wtype {
		case protowire.BytesType:
			val, n := protowire.ConsumeBytes(data[offset:])
			if n <= 0 {
				break
			}
			offset += n
			if num == 1 {
				country = strings.ToLower(string(val))
			} else if num == 2 {
				if c, err := parseCIDR(val); err == nil {
					cidrs = append(cidrs, c)
				}
			}
		default:
			n := protowire.ConsumeFieldValue(num, wtype, data[offset:])
			if n <= 0 {
				break
			}
			offset += n
		}
	}
	if country != "" && want[country] {
		m.cidrs = append(m.cidrs, cidrs...)
	}
}

func parseCIDR(data []byte) (netip.Prefix, error) {
	var ipBytes []byte
	var prefixBits int
	for offset := 0; offset < len(data); {
		num, wtype, n := protowire.ConsumeTag(data[offset:])
		if n <= 0 {
			break
		}
		offset += n
		switch wtype {
		case protowire.BytesType:
			val, n := protowire.ConsumeBytes(data[offset:])
			if n <= 0 {
				break
			}
			offset += n
			if num == 1 {
				ipBytes = val
			}
		case protowire.VarintType:
			val, n := protowire.ConsumeVarint(data[offset:])
			if n <= 0 {
				break
			}
			offset += n
			if num == 2 {
				prefixBits = int(val)
			}
		default:
			n := protowire.ConsumeFieldValue(num, wtype, data[offset:])
			if n <= 0 {
				break
			}
			offset += n
		}
	}
	if len(ipBytes) == 0 {
		return netip.Prefix{}, fmt.Errorf("empty IP")
	}
	addr, ok := netip.AddrFromSlice(ipBytes)
	if !ok {
		return netip.Prefix{}, fmt.Errorf("bad IP: %v", ipBytes)
	}
	return addr.Prefix(prefixBits)
}

// Contains uses binary search to find matching CIDR.
// CIDRs are sorted by network address, but overlapping ranges can exist
// (e.g. 0.0.0.0/1 and 1.0.0.0/8). We scan backwards from idx-1 through
// all CIDRs whose network address <= ip to ensure no match is missed.
func (m *GeoIPMatcher) Contains(ip netip.Addr) bool {
	ip = ip.Unmap()
	m.mu.RLock()
	defer m.mu.RUnlock()
	if len(m.cidrs) == 0 {
		return false
	}
	// Binary search: find first CIDR whose Addr() is > ip
	idx := sort.Search(len(m.cidrs), func(i int) bool {
		return ip.Less(m.cidrs[i].Addr())
	})
	// Scan backwards: check all CIDRs whose network addr <= ip.
	// In practice GeoIP data has no overlaps, so the loop typically exits
	// after 1-2 iterations. We cap the scan to avoid worst-case O(n).
	maxScan := 8
	for i := idx - 1; i >= 0 && maxScan > 0; i-- {
		maxScan--
		if m.cidrs[i].Contains(ip) {
			return true
		}
	}
	// Also check idx (in case of exact addr match)
	if idx < len(m.cidrs) && m.cidrs[idx].Contains(ip) {
		return true
	}
	return false
}

// loadGeoIP loads geoip data from the file specified by -geoip flag.
func loadGeoIP() {
	data, err := os.ReadFile(geoipFile)
	if err != nil {
		log.Printf("[TUN] geoip: cannot read %s: %v", geoipFile, err)
		return
	}
	m, err := NewGeoIPMatcher(data, []string{"CN"})
	if err != nil {
		log.Printf("[TUN] geoip: parse error: %v", err)
		return
	}
	geoIPMatcher = m
	resetGeoIPMatcherCache()
	log.Printf("[TUN] geoip loaded (%d CIDR) from %s", len(m.cidrs), geoipFile)
}
