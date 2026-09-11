//go:build windows

package main

import (
	"log"
	"net/netip"
	"strings"
)

// RuleType identifies what kind of matching a rule performs.
type RuleType int

const (
	RuleTypeGeoSite RuleType = iota // geosite:xx
	RuleTypeGeoIP                   // geoip:xx
	RuleTypeDomain                  // domain:example.com
	RuleTypeCIDR                    // 1.2.3.0/24 or 2400:cb00::/32
)

// RouteRule is one entry from the flat routing rule list.
type RouteRule struct {
	Type     RuleType
	Value    string        // original string for logging
	Decision RouteDecision // direct, proxy, or block

	// Parsed data (populated after init)
	geoSiteCat string       // geosite category, e.g. "cn"
	geoIPCat   string       // geoip country code, e.g. "cn"
	domain     string       // exact domain or suffix for domain: rule
	cidr       netip.Prefix // parsed CIDR for CIDR rules
}

// RouteDecision is the result of route matching.
type RouteDecision int

const (
	DecisionDirect RouteDecision = iota
	DecisionProxy
	DecisionBlock // 阻断：直接断开连接
	DecisionAll   // 全局代理：不解析规则，所有流量走代理
	DecisionNone  // no rule matched
)

func (d RouteDecision) String() string {
	switch d {
	case DecisionDirect:
		return "direct"
	case DecisionProxy:
		return "proxy"
	case DecisionBlock:
		return "block"
	case DecisionAll:
		return "all"
	default:
		return "none"
	}
}

var (
	routeRules           []RouteRule   // 扁平规则列表，顺序匹配
	defaultRouteDecision RouteDecision // fallback when no rule matches
	ruleScope            string        // "all", "tcp", "udp" — which protocols follow rules
)

// parseRuleList parses a comma-separated rule string into RouteRule slice.
// Supported formats:
//
//	geosite:cn        -> RuleTypeGeoSite
//	geoip:cn          -> RuleTypeGeoIP
//	geoip:private     -> RuleTypeGeoIP (special: private ranges)
//	geosite:private   -> RuleTypeGeoSite
//	domain:example.com -> RuleTypeDomain (exact or suffix match)
//	1.2.3.0/24        -> RuleTypeCIDR
//	2400:cb00::/32    -> RuleTypeCIDR
//	1.2.3.4           -> RuleTypeCIDR (single IP, auto /32 or /128)
func parseRuleList(s string) []RouteRule {
	if s == "" {
		return nil
	}
	var rules []RouteRule
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		lower := strings.ToLower(part)

		if strings.HasPrefix(lower, "geosite:") {
			cat := part[strings.Index(part, ":")+1:]
			rules = append(rules, RouteRule{
				Type:       RuleTypeGeoSite,
				Value:      part,
				geoSiteCat: strings.ToLower(cat),
			})
		} else if strings.HasPrefix(lower, "geosite.") {
			// Alias: geosite.cn -> geosite:cn
			cat := part[strings.Index(part, ".")+1:]
			canonical := "geosite:" + strings.ToLower(cat)
			rules = append(rules, RouteRule{
				Type:       RuleTypeGeoSite,
				Value:      canonical,
				geoSiteCat: strings.ToLower(cat),
			})
		} else if strings.HasPrefix(lower, "geoip:") {
			cat := part[strings.Index(part, ":")+1:]
			rules = append(rules, RouteRule{
				Type:     RuleTypeGeoIP,
				Value:    part,
				geoIPCat: strings.ToLower(cat),
			})
		} else if strings.HasPrefix(lower, "geoip.") {
			// Alias: geoip.cn -> geoip:cn
			cat := part[strings.Index(part, ".")+1:]
			canonical := "geoip:" + strings.ToLower(cat)
			rules = append(rules, RouteRule{
				Type:     RuleTypeGeoIP,
				Value:    canonical,
				geoIPCat: strings.ToLower(cat),
			})
		} else if strings.HasPrefix(lower, "domain:") {
			d := part[strings.Index(part, ":")+1:]
			rules = append(rules, RouteRule{
				Type:   RuleTypeDomain,
				Value:  part,
				domain: strings.ToLower(d),
			})
		} else if strings.Contains(part, "/") {
			pfx, err := netip.ParsePrefix(part)
			if err != nil {
				log.Printf("[TUN] invalid CIDR rule: %s (%v)", part, err)
				continue
			}
			rules = append(rules, RouteRule{
				Type:  RuleTypeCIDR,
				Value: part,
				cidr:  pfx,
			})
		} else {
			// Try parsing as single IP -> auto-convert to /32 or /128
			addr, err := netip.ParseAddr(part)
			if err != nil {
				log.Printf("[TUN] invalid rule: %s (%v)", part, err)
				continue
			}
			bits := 32
			if addr.Is6() {
				bits = 128
			}
			rules = append(rules, RouteRule{
				Type:  RuleTypeCIDR,
				Value: part,
				cidr:  netip.PrefixFrom(addr, bits),
			})
		}
	}
	return rules
}

// matchDomain checks if a domain matches the given rule.
func matchDomain(rule RouteRule, domain string) bool {
	switch rule.Type {
	case RuleTypeGeoSite:
		matcher := getGeoSiteMatcher(rule.geoSiteCat)
		return matcher != nil && matcher.Match(domain)
	case RuleTypeDomain:
		d := strings.ToLower(domain)
		r := rule.domain
		return d == r || strings.HasSuffix(d, "."+r)
	}
	return false
}

// matchIP checks if an IP matches the given rule.
func matchIP(rule RouteRule, ip netip.Addr) bool {
	switch rule.Type {
	case RuleTypeGeoIP:
		matcher := getGeoIPMatcher(rule.geoIPCat)
		return matcher != nil && matcher.Contains(ip)
	case RuleTypeCIDR:
		return rule.cidr.Contains(ip)
	}
	return false
}

// routeDomain decides direct/proxy for a domain.
// Priority: direct rules (in order) > proxy rules (in order).
// Returns DecisionNone when no rule matches; callers apply defaultRouteDecision.
// When defaultRouteDecision is DecisionAll, returns DecisionProxy directly.
func routeDomain(domain string) (RouteDecision, string) {
	if defaultRouteDecision == DecisionAll {
		return DecisionProxy, "all"
	}
	// 扁平规则列表，顺序匹配，第一条命中的规则决定行为
	for _, r := range routeRules {
		if matchDomain(r, domain) {
			return r.Decision, r.Value
		}
	}
	return DecisionNone, ""
}

// routeIP decides direct/proxy for an IP.
// Priority: direct rules (in order) > proxy rules (in order).
// Returns DecisionNone when no rule matches; callers apply defaultRouteDecision.
// When defaultRouteDecision is DecisionAll, returns DecisionProxy directly.
func routeIP(ip netip.Addr) (RouteDecision, string) {
	if defaultRouteDecision == DecisionAll {
		return DecisionProxy, "all"
	}
	// 扁平规则列表，顺序匹配
	for _, r := range routeRules {
		if matchIP(r, ip) {
			return r.Decision, r.Value
		}
	}
	return DecisionNone, ""
}

// routeIPStr decides direct/proxy for an IP string.
func routeIPStr(ipStr string) (RouteDecision, string) {
	ip, err := netip.ParseAddr(ipStr)
	if err != nil {
		return DecisionNone, ""
	}
	return routeIP(ip)
}

// routeDomainOrIP first tries domain-based rules, then IP-based.
// This is the main entry point for TCP/UDP routing decisions.
// Returns (decision, matchedRule, isDomainMatch).
func routeDomainOrIP(domain string, ipStr string) (RouteDecision, string, bool) {
	if defaultRouteDecision == DecisionAll {
		return DecisionProxy, "all", false
	}
	// 1. Try domain rules first (if we have a domain from SNI sniffing)
	if domain != "" {
		if d, rule := routeDomain(domain); d != DecisionNone {
			return d, rule, true
		}
	}
	// 2. Try IP rules
	if d, rule := routeIPStr(ipStr); d != DecisionNone {
		return d, rule, false
	}
	// 3. Default
	return defaultRouteDecision, "", false // uses -default flag (proxy or direct)
}

// dnsRouteForDomain decides which DNS resolver to use for a domain.
// If any direct rule matches the domain -> local DNS (direct).
// Otherwise -> remote DNS (proxy).
func dnsRouteForDomain(domain string) (RouteDecision, string) {
	if defaultRouteDecision == DecisionAll {
		return DecisionProxy, "all"
	}
	// 扁平规则列表，顺序匹配
	for _, r := range routeRules {
		if matchDomain(r, domain) {
			// block 规则的 DNS 也返回 block，由调用方决定如何处理
			if r.Decision == DecisionBlock {
				return DecisionBlock, r.Value
			}
			return r.Decision, r.Value
		}
	}
	// Default: use -default flag
	if defaultRouteDecision == DecisionDirect {
		return DecisionDirect, "default"
	}
	return DecisionProxy, "default"
}

// shouldDirectTCP decides if a TCP connection should go direct.
// Returns (shouldDirect, reason).
func shouldDirectTCP(domain string, targetHost string) (bool, string) {
	decision, reason := routeTCP(domain, targetHost)
	return decision == DecisionDirect, reason
}

// routeTCP decides TCP route and returns a normalized log reason.
func routeTCP(domain string, targetHost string) (RouteDecision, string) {
	// -rule udp: TCP 不走规则，直接直连
	if ruleScope == "udp" {
		return DecisionDirect, "rule:udp"
	}
	// -rule tcp: TCP 走规则
	// -rule all: TCP 走规则
	decision, rule, isDomain := routeDomainOrIP(domain, targetHost)
	if rule != "" {
		if isDomain {
			return decision, "domain:" + rule
		}
		return decision, "ip:" + rule
	}
	return decision, "default"
}

// routeUDP decides UDP route and returns a normalized log reason.
func routeUDP(ipStr string) (RouteDecision, string) {
	// -rule tcp: UDP 不走规则，直接直连
	if ruleScope == "tcp" {
		return DecisionDirect, "rule:tcp"
	}
	// -rule udp: UDP 走规则
	// -rule all: UDP 走规则
	decision, rule := routeIPStr(ipStr)
	if decision == DecisionNone {
		decision = defaultRouteDecision
		if decision == DecisionAll {
			return DecisionProxy, "all"
		}
		return decision, "default"
	}
	if rule != "" {
		return decision, "ip:" + rule
	}
	return decision, "default"
}

// shouldDirectUDP decides if a UDP packet should go direct.
func shouldDirectUDP(ipStr string) (bool, string) {
	decision, reason := routeUDP(ipStr)
	return decision == DecisionDirect, reason
}

// initRules initializes the routing rules from the parsed flags.
// This must be called after geoip.dat and geosite.dat are loaded.
func initRules(routeStr, defaultStr, ruleModeStr string) {
	// 将 routeStr 按分号拆分为多条规则
	orderedRules := strings.Split(routeStr, ";")
	// Parse default route
	switch strings.ToLower(strings.TrimSpace(defaultStr)) {
	case "direct":
		defaultRouteDecision = DecisionDirect
	case "proxy":
		defaultRouteDecision = DecisionProxy
	case "all":
		defaultRouteDecision = DecisionAll
	default:
		log.Printf("[TUN] invalid -default value %q, using proxy", defaultStr)
		defaultRouteDecision = DecisionProxy
	}

	// 从 -route 参数构建扁平规则列表
	routeRules = nil
	for _, r := range orderedRules {
		rule := parseOrderedRule(r)
		if rule != nil {
			routeRules = append(routeRules, *rule)
		} else {
			log.Printf("[TUN] invalid -route rule: %q", r)
		}
	}

	// 当用户没有指定任何规则时，应用默认规则
	if len(routeRules) == 0 && defaultRouteDecision != DecisionAll {
		routeRules = []RouteRule{
			{Type: RuleTypeGeoSite, Value: "geosite:cn", geoSiteCat: "cn", Decision: DecisionDirect},
			{Type: RuleTypeGeoIP, Value: "geoip:cn", geoIPCat: "cn", Decision: DecisionDirect},
			{Type: RuleTypeGeoSite, Value: "geosite:private", geoSiteCat: "private", Decision: DecisionDirect},
			{Type: RuleTypeGeoIP, Value: "geoip:private", geoIPCat: "private", Decision: DecisionDirect},
		}
	}

	// Parse rule scope
	switch strings.ToLower(strings.TrimSpace(ruleModeStr)) {
	case "all", "tcp", "udp":
		ruleScope = strings.ToLower(strings.TrimSpace(ruleModeStr))
	default:
		log.Printf("[TUN] invalid -rule value %q, using all", ruleModeStr)
		ruleScope = "all"
	}

	log.Printf("[TUN] route rules: %s", ruleListSummary(routeRules))
	log.Printf("[TUN] default route: %s", defaultRouteDecision)
	log.Printf("[TUN] rule scope: %s", ruleScope)
}

// parseOrderedRule parses a single ordered rule in the format:
//
//	"direct,geosite:cn"     -> Decision=Direct, Type=GeoSite
//	"proxy,domain:google.com" -> Decision=Proxy, Type=Domain
//	"block,geoip:cn"         -> Decision=Block, Type=GeoIP
func parseOrderedRule(s string) *RouteRule {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	comma := strings.IndexByte(s, ',')
	if comma < 0 {
		return nil
	}
	behavior := strings.TrimSpace(s[:comma])
	condition := strings.TrimSpace(s[comma+1:])
	if condition == "" {
		return nil
	}

	var decision RouteDecision
	switch strings.ToLower(behavior) {
	case "direct":
		decision = DecisionDirect
	case "proxy":
		decision = DecisionProxy
	case "block":
		decision = DecisionBlock
	default:
		return nil
	}

	// Now parse the condition part (same as parseRuleList for each entry)
	lower := strings.ToLower(condition)
	var rule RouteRule
	rule.Decision = decision
	rule.Value = condition

	if strings.HasPrefix(lower, "geosite:") {
		rule.Type = RuleTypeGeoSite
		rule.geoSiteCat = strings.ToLower(condition[strings.Index(condition, ":")+1:])
	} else if strings.HasPrefix(lower, "geoip:") {
		rule.Type = RuleTypeGeoIP
		rule.geoIPCat = strings.ToLower(condition[strings.Index(condition, ":")+1:])
	} else if strings.HasPrefix(lower, "domain:") {
		rule.Type = RuleTypeDomain
		rule.domain = strings.ToLower(condition[strings.Index(condition, ":")+1:])
	} else if strings.Contains(condition, "/") {
		if pfx, err := netip.ParsePrefix(condition); err == nil {
			rule.Type = RuleTypeCIDR
			rule.cidr = pfx
		} else {
			return nil
		}
	} else if ip, err := netip.ParseAddr(condition); err == nil {
		rule.Type = RuleTypeCIDR
		bits := 32
		if ip.Is6() {
			bits = 128
		}
		rule.cidr = netip.PrefixFrom(ip, bits)
	} else {
		return nil
	}
	return &rule
}

func ruleListSummary(rules []RouteRule) string {
	if len(rules) == 0 {
		return "(none)"
	}
	var vals []string
	for _, r := range rules {
		vals = append(vals, r.Value)
	}
	return strings.Join(vals, ", ")
}
