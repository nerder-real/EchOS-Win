//go:build windows

package main

import (
	"flag"
)

const defaultRouteRules = "proxy,geosite:google;proxy,geosite:geolocation-!cn;direct,geoip:private;direct,geosite:private;direct,geosite:cn;direct,geoip:cn"

var (
	tunMode    bool
	tunName    string
	tunMTU     int

	// Custom routing rules
	defaultRouteStr  string
	ruleMode         string // "all", "tcp", "udp"
	routeStr         string              // -route "direct,geosite:cn;direct,geoip:cn"

	// Geo data file paths
	geoipFile   string
	geositeFile string
)



func init() {
	flag.BoolVar(&tunMode, "tun", false, "启用 TUN 模式（仅 Windows）")
	flag.StringVar(&tunName, "tun-name", "xtun", "TUN 网卡名称")
	flag.IntVar(&tunMTU, "tun-mtu", 9000, "TUN 接口 MTU")

	flag.StringVar(&routeStr, "route", defaultRouteRules, "有序路由规则，用分号分隔多条。格式: behavior,condition;behavior,condition...\n行为: direct / proxy / block\n条件: geosite:xx / geoip:xx / domain:xx / cidr")
	flag.StringVar(&defaultRouteStr, "default", "proxy", "规则未命中时的默认路由：proxy、direct 或 all（全局代理，跳过规则解析）")
	flag.StringVar(&ruleMode, "rule", "all", "规则生效的协议：tcp（仅TCP走规则，UDP直连）、udp（仅UDP走规则，TCP直连）、all（都走规则）")

	flag.StringVar(&geoipFile, "geoip", "geoip.dat", "GeoIP 数据文件路径")
	flag.StringVar(&geositeFile, "geosite", "geosite.dat", "GeoSite 数据文件路径")
}
