//go:build windows

package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"log"
	"net/netip"
	"os"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"google.golang.org/protobuf/encoding/protowire"
)

const (
	domainTypePlain      = 0
	domainTypeRegex      = 1
	domainTypeRootDomain = 2
	domainTypeFull       = 3
)

type GeoSiteMatcher struct {
	mu        sync.RWMutex
	domains   map[string]bool
	suffixes  []string
	suffixSet map[string]bool // O(1) exact suffix lookup
	keywords  []string
	keywordAC *ahoCorasick // multi-pattern substring matcher
	regexps   []*regexp.Regexp
}

// ahoCorasick is a minimal Aho-Corasick automaton for multi-pattern
// substring matching. Build cost is O(sum of keyword lengths); query
// cost is O(len(text) + num_matches), independent of keyword count.
type ahoCorasick struct {
	gotoFn map[int]map[byte]int
	fail   []int
	output [][]int
}

func buildAhoCorasick(patterns []string) *ahoCorasick {
	if len(patterns) == 0 {
		return nil
	}
	ac := &ahoCorasick{
		gotoFn: make(map[int]map[byte]int),
		fail:   []int{0},
		output: [][]int{nil},
	}
	// Build trie (goto function)
	for _, p := range patterns {
		if len(p) == 0 {
			continue
		}
		cur := 0
		for j := 0; j < len(p); j++ {
			c := p[j]
			if _, ok := ac.gotoFn[cur]; !ok {
				ac.gotoFn[cur] = make(map[byte]int)
			}
			nxt, ok := ac.gotoFn[cur][c]
			if !ok {
				nxt = len(ac.fail)
				ac.gotoFn[cur][c] = nxt
				ac.fail = append(ac.fail, 0)
				ac.output = append(ac.output, nil)
				cur = nxt
			} else {
				cur = nxt
			}
		}
		// Mark end of pattern: any non-nil output means this node completes a keyword
		if len(ac.output[cur]) == 0 {
			ac.output[cur] = []int{1}
		} else {
			ac.output[cur] = append(ac.output[cur], 1)
		}
	}
	// Build failure function (BFS)
	queue := []int{}
	for _, child := range ac.gotoFn[0] {
		queue = append(queue, child)
		ac.fail[child] = 0
	}
	for len(queue) > 0 {
		r := queue[0]
		queue = queue[1:]
		for c, u := range ac.gotoFn[r] {
			queue = append(queue, u)
			f := ac.fail[r]
			for {
				if nxt, ok := ac.gotoFn[f][c]; ok && nxt != u {
					f = nxt
					break
				}
				if f == 0 {
					break
				}
				f = ac.fail[f]
			}
			if nxt, ok := ac.gotoFn[f][c]; ok && nxt != u {
				ac.fail[u] = nxt
			} else {
				ac.fail[u] = 0
			}
			ac.output[u] = append(ac.output[u], ac.output[ac.fail[u]]...)
		}
	}
	return ac
}

// contains returns true if any pattern is a substring of text.
func (ac *ahoCorasick) contains(text string) bool {
	if ac == nil {
		return false
	}
	cur := 0
	for i := 0; i < len(text); i++ {
		c := text[i]
		for {
			if nxt, ok := ac.gotoFn[cur][c]; ok {
				cur = nxt
				break
			}
			if cur == 0 {
				break
			}
			cur = ac.fail[cur]
		}
		if len(ac.output[cur]) > 0 {
			return true
		}
	}
	return false
}

var geoSiteMatcher *GeoSiteMatcher

var (
	geoSiteMatchers   = map[string]*GeoSiteMatcher{}
	geoSiteMatchersMu sync.RWMutex
)

func resetGeoSiteMatcherCache() {
	geoSiteMatchersMu.Lock()
	geoSiteMatchers = map[string]*GeoSiteMatcher{}
	if geoSiteMatcher != nil {
		geoSiteMatchers["cn"] = geoSiteMatcher
	}
	geoSiteMatchersMu.Unlock()
}

func getGeoSiteMatcher(category string) *GeoSiteMatcher {
	cat := strings.ToLower(category)
	geoSiteMatchersMu.RLock()
	if m, ok := geoSiteMatchers[cat]; ok {
		geoSiteMatchersMu.RUnlock()
		return m
	}
	geoSiteMatchersMu.RUnlock()

	if cat == "cn" && geoSiteMatcher != nil {
		geoSiteMatchersMu.Lock()
		geoSiteMatchers[cat] = geoSiteMatcher
		geoSiteMatchersMu.Unlock()
		return geoSiteMatcher
	}

	data, err := os.ReadFile(geositeFile)
	if err != nil {
		return nil
	}
	m, err := parseGeoSiteByScan(data, cat)
	if err != nil {
		return nil
	}
	geoSiteMatchersMu.Lock()
	geoSiteMatchers[cat] = m
	geoSiteMatchersMu.Unlock()
	return m
}

func parseGeoSiteByScan(data []byte, category string) (*GeoSiteMatcher, error) {
	code := strings.ToUpper(category)
	codeB := []byte(code)
	codeLen := len(codeB)
	if codeLen == 0 {
		return nil, fmt.Errorf("empty category")
	}
	need := 2 + codeLen

	m := &GeoSiteMatcher{domains: make(map[string]bool), suffixSet: make(map[string]bool)}
	offset := 0
	for offset < len(data) {
		_, wtype, n := protowire.ConsumeTag(data[offset:])
		if n <= 0 {
			break
		}
		offset += n
		if wtype != protowire.BytesType {
			n := protowire.ConsumeFieldValue(1, wtype, data[offset:])
			if n <= 0 {
				break
			}
			offset += n
			continue
		}

		bodyLen, n := protowire.ConsumeVarint(data[offset:])
		if n <= 0 {
			break
		}
		offset += n

		bodyStart := offset
		offset += int(bodyLen)
		if offset > len(data) {
			break
		}
		body := data[bodyStart : bodyStart+int(bodyLen)]

		if len(body) >= need && body[0] == 0x0a && int(body[1]) == codeLen && bytes.Equal(body[2:need], codeB) {
			m.parseGeoSiteDomains(body)
		}
	}
	return m, nil
}

func (m *GeoSiteMatcher) parseGeoSiteDomains(data []byte) {
	offset := 0
	for offset < len(data) {
		num, wtype, n := protowire.ConsumeTag(data[offset:])
		if n <= 0 {
			break
		}
		offset += n

		if wtype == protowire.BytesType && num == 2 {
			val, n := protowire.ConsumeBytes(data[offset:])
			if n <= 0 {
				break
			}
			offset += n
			m.parseOneDomain(val)
		} else {
			n := protowire.ConsumeFieldValue(num, wtype, data[offset:])
			if n <= 0 {
				break
			}
			offset += n
		}
	}
}

func (m *GeoSiteMatcher) parseOneDomain(data []byte) {
	var value string
	kind := domainTypePlain

	offset := 0
	for offset < len(data) {
		num, wtype, n := protowire.ConsumeTag(data[offset:])
		if n <= 0 {
			break
		}
		offset += n

		switch {
		case wtype == protowire.VarintType && num == 1:
			val, n := protowire.ConsumeVarint(data[offset:])
			if n <= 0 {
				break
			}
			offset += n
			kind = int(val)
		case wtype == protowire.BytesType && num == 2:
			val, n := protowire.ConsumeBytes(data[offset:])
			if n <= 0 {
				break
			}
			offset += n
			value = strings.ToLower(string(val))
		default:
			n := protowire.ConsumeFieldValue(num, wtype, data[offset:])
			if n <= 0 {
				break
			}
			offset += n
		}
	}

	if value == "" {
		return
	}
	switch kind {
	case domainTypeFull:
		m.domains[value] = true
	case domainTypeRootDomain:
		// Standard geosite.dat may store RootDomain with or without a leading "."
		// (e.g. ".baidu.com" vs "baidu.com"). Strip the dot so both forms match.
		sv := strings.TrimPrefix(value, ".")
		m.suffixes = append(m.suffixes, sv)
		m.suffixSet[sv] = true
	case domainTypeRegex:
		re, err := regexp.Compile(value)
		if err == nil {
			m.regexps = append(m.regexps, re)
		}
	default:
		m.keywords = append(m.keywords, value)
	}
}

func (m *GeoSiteMatcher) Match(domain string) bool {
	if m == nil {
		return false
	}
	m.mu.RLock()
	defer m.mu.RUnlock()
	domain = strings.ToLower(domain)
	if m.domains[domain] {
		return true
	}
	// O(labels) suffix match: try domain, then strip leftmost label repeatedly
	// e.g. for "a.b.baidu.com": try "a.b.baidu.com", "b.baidu.com", "baidu.com", "com"
	d := domain
	for {
		if m.suffixSet[d] {
			return true
		}
		dot := strings.IndexByte(d, '.')
		if dot < 0 || dot >= len(d)-1 {
			break
		}
		d = d[dot+1:]
	}
	if m.keywordAC != nil {
		if m.keywordAC.contains(domain) {
			return true
		}
	} else if len(m.keywords) > 0 {
		// Fallback for safety (should not happen if buildAC was called)
		for _, k := range m.keywords {
			if strings.Contains(domain, k) {
				return true
			}
		}
	}
	for _, re := range m.regexps {
		if re.MatchString(domain) {
			return true
		}
	}
	return false
}

// ======================== Domain Cache ========================

type cacheEntry struct {
	ips      []netip.Addr
	expireAt time.Time
}

type dnsReplyCacheEntry struct {
	reply    []byte
	expireAt time.Time
}

var (
	dcMu       sync.RWMutex
	dc         = map[string]*cacheEntry{}
	dcr        = map[string]*dnsReplyCacheEntry{}
	dcCleanups atomic.Int64
)

func lookupIPsByDomainFamily(domain string, wantIPv6 bool) []string {
	qtype := dnsTypeA
	if wantIPv6 {
		qtype = dnsTypeAAAA
	}
	key := dnsReplyCacheKey(domain, qtype)
	dcMu.RLock()
	defer dcMu.RUnlock()
	e, ok := dc[key]
	if !ok || time.Now().After(e.expireAt) {
		return nil
	}
	var out []string
	for _, ip := range e.ips {
		ip = ip.Unmap()
		if wantIPv6 {
			if ip.Is6() {
				out = append(out, ip.String())
			}
			continue
		}
		if ip.Is4() {
			out = append(out, ip.String())
		}
	}
	return out
}

func lookupIPv4ByDomain(domain string) string {
	ips := lookupIPsByDomainFamily(domain, false)
	if len(ips) > 0 {
		return ips[0]
	}
	return ""
}

func lookupIPv6ByDomain(domain string) string {
	ips := lookupIPsByDomainFamily(domain, true)
	if len(ips) > 0 {
		return ips[0]
	}
	return ""
}

func dnsReplyCacheKey(domain string, qtype uint16) string {
	domain = strings.ToLower(strings.TrimSuffix(domain, "."))
	return fmt.Sprintf("%s|%d", domain, qtype)
}

// lookupDNSCache returns a cached DNS reply for the given domain+qtype,
// or nil if not cached/expired. The caller must set the transaction ID.
func lookupDNSCache(domain string, q []byte) []byte {
	key := dnsReplyCacheKey(domain, dnsQuestionType(q))
	dcMu.RLock()
	defer dcMu.RUnlock()
	e, ok := dcr[key]
	if !ok || time.Now().After(e.expireAt) || len(e.reply) == 0 {
		return nil
	}
	return append([]byte(nil), e.reply...)
}

func cacheDNSReply(domain string, reply []byte) {
	if domain == "" || len(reply) < 12 {
		return
	}
	domain = strings.ToLower(strings.TrimSuffix(domain, "."))
	qtype := dnsQuestionType(reply)
	if qtype != dnsTypeA && qtype != dnsTypeAAAA {
		return
	}
	var ips []netip.Addr
	var minTTL uint32 = 60
	_, _, qdcount := unpackDNSHeader(reply)
	pos := 12
	for i := 0; i < int(qdcount); i++ {
		for pos < len(reply) {
			if reply[pos] == 0 {
				pos += 5
				break
			}
			if reply[pos]&0xC0 == 0xC0 {
				pos += 2
				if pos+4 <= len(reply) {
					pos += 4
				}
				break
			}
			pos += int(reply[pos]) + 1
		}
	}
	ancount := int(binary.BigEndian.Uint16(reply[6:8]))
	for i := 0; i < ancount && pos+12 <= len(reply); i++ {
		if reply[pos]&0xC0 == 0xC0 {
			pos += 2
		} else {
			for pos < len(reply) && reply[pos] != 0 {
				pos += int(reply[pos]) + 1
			}
			pos++
		}
		if pos+10 > len(reply) {
			break
		}
		rtype := int(reply[pos])<<8 | int(reply[pos+1])
		ttl := uint32(reply[pos+4])<<24 | uint32(reply[pos+5])<<16 | uint32(reply[pos+6])<<8 | uint32(reply[pos+7])
		rdlen := int(reply[pos+8])<<8 | int(reply[pos+9])
		rs := pos + 10
		if qtype == dnsTypeA && rtype == int(dnsTypeA) && rdlen == 4 && rs+4 <= len(reply) {
			if ip, ok := netip.AddrFromSlice(reply[rs : rs+4]); ok {
				ips = append(ips, ip.Unmap())
			}
		} else if qtype == dnsTypeAAAA && rtype == int(dnsTypeAAAA) && rdlen == 16 && rs+16 <= len(reply) {
			if ip, ok := netip.AddrFromSlice(reply[rs : rs+16]); ok {
				ips = append(ips, ip.Unmap())
			}
		}
		pos += 10 + rdlen
		if ttl > 0 && ttl < minTTL {
			minTTL = ttl
		}
	}
	if len(ips) > 0 {
		key := dnsReplyCacheKey(domain, qtype)
		exp := time.Now().Add(time.Duration(minTTL) * time.Second)
		dcMu.Lock()
		dc[key] = &cacheEntry{append([]netip.Addr(nil), ips...), exp}
		dcr[key] = &dnsReplyCacheEntry{append([]byte(nil), reply...), exp}
		// Periodic cleanup: only run every 64 writes to avoid O(n) on every DNS reply
		if dcCleanups.Add(1) >= 64 {
			dcCleanups.Store(0)
			now := time.Now()
			for d, e := range dc {
				if now.After(e.expireAt) {
					delete(dc, d)
				}
			}
			for k, e := range dcr {
				if now.After(e.expireAt) {
					delete(dcr, k)
				}
			}
		}
		dcMu.Unlock()
	}
}

func loadGeoSite() {
	data, err := os.ReadFile(geositeFile)
	if err != nil {
		log.Printf("[TUN] geosite: cannot read %s: %v", geositeFile, err)
		return
	}
	m, err := parseGeoSiteByScan(data, "CN")
	if err != nil {
		log.Printf("[TUN] geosite: parse error: %v", err)
		return
	}
	geoSiteMatcher = m
	resetGeoSiteMatcherCache()
	m.keywordAC = buildAhoCorasick(m.keywords)
	log.Printf("[TUN] geosite loaded (%d suffixes, %d domains, %d keywords, %d regexps) from %s",
		len(m.suffixes), len(m.domains), len(m.keywords), len(m.regexps), geositeFile)
}
