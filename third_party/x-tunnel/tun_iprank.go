package main

// 优选 IP 存活 + 吞吐筛选。
//
// `-ip` 常填「优选域名」（多个逗号分隔；留空则直连解析服务器域名），背后是一组 Cloudflare
// 边缘 IP。真正要剔除的有两类：
//
//  1. **死边缘**：WebSocket 握手成功、CONNECTED 也回了，然后一个字节都不给
//     （实测某边缘 3 成连接 0 字节）。这种连接不报错，调用方只能干等到超时。
//  2. **慢边缘**：存活探测只要能吐 64 字节就算可用，被运营商 QoS 到
//     ~250KB/s 的边缘照样过筛，还占掉轮转份额 —— 2026-11-13 实录：同一
//     候选池里慢边缘隧道吞吐 249KB/s、好边缘 10–22MB/s，差近百倍，用户
//     看到的就是"整体很慢、时好时坏"。
//
// 两类各用一道筛：
//   - 存活：经每个候选 IP 走 Worker 打一次 Google 的 generate_204（请求和
//     响应都是字节级，目标又极稳，几秒内给出确定性的通/断结论）；
//   - 吞吐：直连边缘 TLS 测一次小下载（见 edgeThroughputKBps）。用绝对
//     门槛而不是排名 —— 早先按吞吐排过一版，20 分钟内好/坏完全互换；但
//     好/慢边缘差的是数量级，512KB/s 的绝对门槛拦的是病态慢，瞬时拥塞
//     碰不到门槛，5 分钟复测也能让恢复的边缘自动回来。
//
// 每个候选试 probeAttempts 次，两次全败才剔除，其余候选保持原来的轮转
// 次序不变；探测在后台周期重跑，结果原子替换（见 x-tunnel.go 的
// targetIPsMu）。复测始终从原始候选展开，被剔的边缘恢复后自动回归。
//
// 服务域名自己解析出的 IP 也加入候选 —— 它和优选域名给出的往往不是
// 同一批，好边缘经常只在这边出现。

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

// TUN 模式下探测前必须给候选补主机路由：TUN 劫持 0/1 路由后，没有主机
// 路由的候选 IP 会被吸进 TUN 黑洞 —— 直连测速超时，健康边缘被误判成
// "直连不可达"剔掉，池子塌成独苗（2026-11-13 TUN 实测：4 候选剔剩 1，
// 独苗还不一定有路由，表现为 TUN 整体没网）。ensureEdgeRoutes 由 darwin
// 侧注入 EnsureEdgeHostRoutes；其他平台无 TUN 设备层，nil 即跳过。
var (
	tunModeActive    atomic.Bool
	ensureEdgeRoutes func([]string)
)

// SetTunActive 由 main 在 TUN 模式下置位（probe 轮补路由用）。
func SetTunActive(v bool) { tunModeActive.Store(v) }

const (
	// 每个候选 IP 探测次数，一次成功即算可用。
	probeAttempts = 2
	// 同时探测多少个 IP。
	probeParallel = 6
	// 单次探测（WS 握手 + CONNECT + 收到响应）的总限时。
	probeTimeout = 5 * time.Second
	// 收到这么多字节才算"这条边能传数据"。
	probeMinBytes = 64
	// 后台复测周期。
	rerankInterval = 5 * time.Minute

	// 吞吐门槛（KB/s）：低于它的边缘视为病态慢，本轮剔除。
	thrFloorKBps = 512
	// 吞吐探测的限时（整段测量 3 秒封顶，含响应头）。
	thrDialTimeout  = 3 * time.Second
	thrTotalTimeout = 8 * time.Second

	// 隧道吞吐探针：经候选边缘走完整用户路径（边缘→Worker→外部测速源），
	// 测"这条链路的外部吞吐"——选边要选的就是它（见 edgeThroughputKBps）。
	tunnelProbeTarget = "proof.ovh.net:443"
	tunnelProbeHost   = "proof.ovh.net"
	tunnelProbePath   = "/files/10Mb.dat"
	tunnelProbeCap    = int64(1 << 20)   // 最多读 1MB
	tunnelProbeMin    = int64(256 << 10) // 样本低于 256KB 不可信
	tunnelProbeWindow = 3 * time.Second
)

// 探测目标：Google 的连通性检查端点，响应 204 无正文。
// 不能用 Cloudflare 自家域名：Worker 的 connect() 拒绝连回 CF 网段。
var probeTargetHost = "www.google.com"

// probeOnce 经指定 IP 走 Worker 做一次连通性探测。
func probeOnce(serverAddr, ip string) bool {
	if echPool == nil {
		return false
	}
	ws, err := echPool.dialWebSocketWithECH(echPool.wsServerAddr, 1, ip, "", 0)
	if err != nil {
		return false
	}
	defer ws.Close()

	_ = ws.SetWriteDeadline(time.Now().Add(probeTimeout))
	if err := ws.WriteMessage(websocket.TextMessage,
		[]byte("CONNECT:"+net.JoinHostPort(probeTargetHost, "80")+"|")); err != nil {
		return false
	}

	connected := false
	_ = ws.SetReadDeadline(time.Now().Add(probeTimeout))
	for {
		mt, data, err := ws.ReadMessage()
		if err != nil {
			return false
		}
		if mt != websocket.TextMessage {
			continue
		}
		text := string(data)
		if text == "CONNECTED" {
			connected = true
			break
		}
		if strings.HasPrefix(text, "ERROR:") || text == "CLOSE" {
			return false
		}
	}
	if !connected {
		return false
	}

	req := "GET /generate_204 HTTP/1.1\r\nHost: " + probeTargetHost +
		"\r\nUser-Agent: EchOS-probe\r\nConnection: close\r\n\r\n"
	_ = ws.SetWriteDeadline(time.Now().Add(probeTimeout))
	if err := ws.WriteMessage(websocket.BinaryMessage, []byte(req)); err != nil {
		return false
	}

	var got int
	_ = ws.SetReadDeadline(time.Now().Add(probeTimeout))
	for got < probeMinBytes {
		mt, data, err := ws.ReadMessage()
		if mt == websocket.BinaryMessage {
			got += len(data)
		}
		if err != nil {
			break
		}
	}
	return got >= probeMinBytes
}

// resolveCandidates 把 IP / 域名展开成具体 IPv4 列表（保序去重）。
func resolveCandidates(candidates []string) []string {
	out := make([]string, 0, len(candidates)*2)
	seen := map[string]bool{}
	add := func(ip string) {
		if ip == "" || seen[ip] {
			return
		}
		seen[ip] = true
		out = append(out, ip)
	}
	for _, c := range candidates {
		c = strings.TrimSpace(c)
		if c == "" {
			continue
		}
		if net.ParseIP(c) != nil {
			add(c)
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*probeTimeout)
		addrs, err := net.DefaultResolver.LookupIPAddr(ctx, c)
		cancel()
		if err != nil {
			log.Printf("[优选] 解析 %s 失败：%v", c, err)
			continue
		}
		for _, a := range addrs {
			if a.IP.To4() != nil {
				add(a.IP.String())
			}
		}
	}
	return out
}

// serverHost 从 `wss://host:443` 这类地址里取出主机名。
func serverHost(serverAddr string) string {
	h := serverAddr
	if i := strings.Index(h, "://"); i >= 0 {
		h = h[i+3:]
	}
	if i := strings.IndexAny(h, "/?#"); i >= 0 {
		h = h[:i]
	}
	if host, _, err := net.SplitHostPort(h); err == nil {
		h = host
	}
	return strings.Trim(h, "[]")
}

// edgeThroughputKBps 经指定边缘的完整隧道链路测外部吞吐（KB/s）。
//
// 2026-11-14 改版：旧探针 TLS 直连边缘 IP 下载 speed.cloudflare（CF 内部），
// 测的是"本机→边缘"段。但真实瓶颈在 Worker→外部出口（免费版小时级限流，
// 2026-11-14 实录：探针报 11.5MB/s 的池，经隧道到外部站实测只有 168KB/s）
// ——直连探针对这个维度是盲的，按它选边等于闭眼排。改走完整真实路径：
//
//	本机 → 边缘(WS) → Worker → CONNECT 外部测速源 → 下载
//
// 测得即用户实际会得到的稳态吞吐，选边直接按"哪条链路外部快"来。
// 测速源 proof.ovh.net（非 CF、大容量、多年稳定），10MB 文件读满 1MB 或
// 3 秒封顶，按已收响应体计速率——快边缘瞬间读完，慢边缘也有足够样本。
//
// 返回 (KB/s, 是否测得)。WS 拨号/CONNECT/TLS 失败返回 false；响应体过小
// （测速源异常/被拦）同样返回 false，当轮按死边缘处理（复测自动回评）。
func edgeThroughputKBps(ip string) (int, bool, string) {
	fail := func(reason string) (int, bool, string) { return 0, false, reason }
	if echPool == nil {
		return fail("连接池未初始化")
	}
	// 1. 经该边缘建 WebSocket：dialWebSocketWithECH 的 ip 参数把出口钉在
	//    这条边缘上（TUN 下 NetDialContext 走物理网卡绑定逃逸，不会绕回
	//    隧道测出错误路径——旧探针吃过这个亏，这里沿用同一条出站路径）。
	ws, err := echPool.dialWebSocketWithECH(echPool.wsServerAddr, 1, ip, "", 0)
	if err != nil {
		return fail("WS 拨号失败: " + shortErr(err))
	}
	defer ws.Close()
	// 2. CONNECT 到外部测速源
	conn, ferr := simpleWSHandshake(ws, tunnelProbeTarget, thrDialTimeout)
	if ferr != nil {
		return fail("CONNECT 失败: " + shortErr(ferr))
	}
	defer conn.Close()
	// 3. 隧道上做 TLS
	tc := tls.Client(conn, &tls.Config{ServerName: tunnelProbeHost})
	tc.SetDeadline(time.Now().Add(thrTotalTimeout))
	if err := tc.Handshake(); err != nil {
		return fail("TLS 失败: " + shortErr(err))
	}
	// 4. GET + 读满 1MB 或 3 秒封顶，吞吐只按响应体计
	req := "GET " + tunnelProbePath + " HTTP/1.1\r\nHost: " + tunnelProbeHost +
		"\r\nUser-Agent: EchOS-iprank\r\nAccept: */*\r\nConnection: close\r\n\r\n"
	if _, err := tc.Write([]byte(req)); err != nil {
		return fail("GET 发送失败: " + shortErr(err))
	}
	_ = tc.SetDeadline(time.Now().Add(tunnelProbeWindow))
	buf := make([]byte, 32*1024)
	var read int64
	var inBody bool
	start := time.Now()
	for {
		n, err := tc.Read(buf)
		read += int64(n)
		if err != nil {
			// 读满 1MB（对端 close）/ 3 秒窗口到 / 对端断开：按已收字节计速率
			break
		}
		if !inBody {
			if i := bytes.Index(buf[:n], []byte("\r\n\r\n")); i >= 0 {
				inBody = true
				read -= int64(i + 4) // 速率只按响应体计
				start = time.Now()
			}
		}
		if read >= tunnelProbeCap {
			break
		}
	}
	if !inBody {
		return fail("响应头未读完（3 秒窗口耗尽）")
	}
	if read < tunnelProbeMin {
		// 样本过小 = 深度限流窗口/测速源异常——不是边缘的错，但样本不可信
		return fail(fmt.Sprintf("样本 %dKB < %dKB（窗口 %.1fs）", read/1024, tunnelProbeMin/1024, time.Since(start).Seconds()))
	}
	elapsed := time.Since(start)
	if elapsed <= 0 {
		elapsed = time.Millisecond
	}
	return int(float64(read) / elapsed.Seconds() / 1024), true, ""
}

// shortErr 单行化错误信息，供探针失败日志用。
func shortErr(err error) string {
	s := strings.ReplaceAll(err.Error(), "\n", " ")
	if len(s) > 120 {
		s = s[:120] + "…"
	}
	return s
}

// edgeThroughputOK 测边缘吞吐，两次机会（波动型劣化边缘常是单次抽风）。
// 任一次达标即通过。返回 (KB/s, 是否达标, 末次失败原因)。
func edgeThroughputOK(ip string) (int, bool, string) {
	var kbps int
	var reason string
	for attempt := 0; attempt < 2; attempt++ {
		if attempt > 0 {
			time.Sleep(500 * time.Millisecond)
		}
		k, ok, r := edgeThroughputKBps(ip)
		reason = r
		if ok {
			kbps = k
			if kbps >= thrFloorKBps {
				return kbps, true, ""
			}
			reason = fmt.Sprintf("吞吐 %dKB/s 低于门槛 %dKB/s", kbps, thrFloorKBps)
		}
	}
	return kbps, false, reason
}

// applyThroughputGate 吞吐门槛：存活 ≠ 能用。双档筛选：
//
//		绝对档 —— 低于 thrFloorKBps 或隧道测速未成：病态慢/死边缘（探针走
//	         完整用户路径（边缘→Worker→外部），探测超时的边缘隧道内 10MB
//		          下载 0 字节 —— 2026-11-13 实录）；
//		相对档 —— 低于本轮最优值 1/4："次慢"边缘。实测同一池里可并存
//		          33MB/s 与 2.4MB/s 的边缘，后者过得了绝对档，却把轮转
//		          平均拉低一个数量级。
//
// 早期"按吞吐排名"失败在 20 分钟内好/坏互换 —— 相对档只剔数量级差的
// 边缘，瞬时波动碰不到 4 倍线；复测从原始候选展开，被剔边缘恢复后自动
// 回归。全部剔除时返回 nil（保持原候选）：集体不达标更可能是本机网络
// 环境问题（如拦直连 CF IP），不能因此剔光。
func applyThroughputGate(ranked []string) []string {
	type edgeMeasure struct {
		ip     string
		kbps   int
		dead   bool   // 两次尝试都没测得
		reason string // 末次失败原因（日志用）
	}
	measured := make([]edgeMeasure, 0, len(ranked))
	results := make([]edgeMeasure, len(ranked))
	var wg sync.WaitGroup
	sem := make(chan struct{}, probeParallel)
	for i, ip := range ranked {
		wg.Add(1)
		go func(i int, ip string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			kbps, ok, reason := edgeThroughputOK(ip)
			results[i] = edgeMeasure{ip: ip, kbps: kbps, dead: !ok, reason: reason}
		}(i, ip)
	}
	wg.Wait()
	best := 0
	for _, m := range results {
		if !m.dead && m.kbps > best {
			best = m.kbps
		}
		measured = append(measured, m)
	}

	// 相对档剔除的（边缘活着，只是吞吐不足 best/4）单独记录：
	// 存活不足 minKeepCandidates 时按吞吐降序回补。
	var relativeCulled []edgeMeasure

	kept := make([]string, 0, len(ranked))
	for _, m := range measured {
		switch {
		case m.dead:
			log.Printf("[优选] %s: 隧道测速未成（%s），剔除（复测轮自动回评）", m.ip, m.reason)
			goldenRemove(m.ip)
		case m.kbps < thrFloorKBps:
			log.Printf("[优选] %s: 吞吐 %dKB/s 低于门槛 %dKB/s，剔除", m.ip, m.kbps, thrFloorKBps)
			goldenRemove(m.ip)
		case best > 0 && m.kbps < best/4:
			log.Printf("[优选] %s: 吞吐 %dKB/s 不足本轮最优 %dKB/s 的 1/4，剔除", m.ip, m.kbps, best)
			goldenRemove(m.ip)
			relativeCulled = append(relativeCulled, m)
		default:
			goldenAdd(m.ip)
			kept = append(kept, m.ip)
		}
	}
	if len(kept) == 0 {
		log.Printf("[优选] 全部候选未达吞吐门槛，保持原候选不变")
		return nil
	}

	// 2026-11-13 TUN 实录：相对档两轮把 5 个候选剔到剩 1 个，整条隧道挂在
	// 单一边缘上，边缘质量随时段波动 → TUN 通信全停（IPv4 12 秒黑洞）。
	// 相对档的本意是防止慢边缘拉低轮转平均，不是清场：存活不足 minKeep
	// 时从相对档按吞吐降序回补。绝对档（低于 512KB/s）与「隧道测速未成」
	// 的真死边缘不回补。
	const minKeepCandidates = 3
	if len(kept) < minKeepCandidates && len(relativeCulled) > 0 {
		sort.Slice(relativeCulled, func(i, j int) bool { return relativeCulled[i].kbps > relativeCulled[j].kbps })
		for _, m := range relativeCulled {
			if len(kept) >= minKeepCandidates {
				break
			}
			log.Printf("[优选] %s: 回补（存活候选 %d < %d，防单边缘单点）", m.ip, len(kept), minKeepCandidates)
			goldenAdd(m.ip)
			kept = append(kept, m.ip)
		}
	}

	// 首位 = 吞吐冠军（粘性主选，视频大流量走它），其余按吞吐降序为
	// 主选冷却 60 秒时的接管序。见 simple_ws.go pickIP 的粘性说明。
	kbpsOf := make(map[string]int, len(measured))
	for _, m := range measured {
		if m.kbps > kbpsOf[m.ip] {
			kbpsOf[m.ip] = m.kbps
		}
	}
	sort.Slice(kept, func(i, j int) bool { return kbpsOf[kept[i]] > kbpsOf[kept[j]] })
	return kept
}

// ================= 黄金集：历轮过门槛边缘的跨轮记忆 =================
//
// 优选域名的 DNS 每次解析轮换着给不同的边缘集合 —— 上一轮测出 11MB/s
// 的好边缘，下一轮可能根本不在候选里，池子瞬间整体降为 mediocre（2026-11-13
// 实录：02:09 轮池内 11MB/s，02:14 轮候选全是 ~1MB/s）。黄金集记住过门槛
// 的边缘，每轮并回候选宇宙；边缘被剔（死/慢）才除名，TTL 到期自然淘汰。
var (
	goldenMu      sync.Mutex
	goldenIPs     = map[string]time.Time{} // IP → 最近一次通过门槛的时刻
	goldenMaxKeep = 8                      // 上限，防候选宇宙无限膨胀
)

const goldenTTL = 30 * time.Minute

// 黄金集落盘：跨内核重启保留"已知好边缘"。优选域名的 DNS 每次解析给的
// 边缘集合是抽奖（2026-11-13 实录：02:09 轮含 16MB/s 好边缘，02:42 轮
// 全是 ~500KB/s，同分钟该好边缘裸连/隧道都 16-22MB/s）——只存内存的话
// 每次重启都清零重抽。落盘后新内核第一轮就带着历史好边缘参选；6 小时
// 内见过的都给一轮重新证明的机会，证不上门槛自然除名。
const goldenPersistTTL = 6 * time.Hour

var (
	goldenPath     string
	goldenLoadOnce sync.Once
)

func init() {
	if dir, err := os.UserConfigDir(); err == nil {
		goldenPath = filepath.Join(dir, "EchOS", "edge-golden.json")
	}
}

func goldenLoadFromDisk() {
	if goldenPath == "" {
		return
	}
	data, err := os.ReadFile(goldenPath)
	if err != nil {
		return
	}
	var saved map[string]int64
	if json.Unmarshal(data, &saved) != nil {
		return
	}
	now := time.Now()
	restored := make([]string, 0, len(saved))
	goldenMu.Lock()
	for ip, ts := range saved {
		t := time.Unix(ts, 0)
		if ts > 0 && now.Sub(t) < goldenPersistTTL {
			// 时间戳刷新为 now：给它完整的一轮探测去重新证明自己
			goldenIPs[ip] = now
			restored = append(restored, ip)
		}
	}
	goldenMu.Unlock()
	if len(restored) > 0 {
		log.Printf("[优选] 黄金集从磁盘恢复 %d 个: %v", len(restored), restored)
	}
}

func goldenSaveToDisk() {
	if goldenPath == "" {
		return
	}
	goldenMu.Lock()
	snap := make(map[string]int64, len(goldenIPs))
	for k, t := range goldenIPs {
		snap[k] = t.Unix()
	}
	goldenMu.Unlock()
	data, err := json.Marshal(snap)
	if err != nil {
		return
	}
	_ = os.MkdirAll(filepath.Dir(goldenPath), 0755)
	// 0666：TUN 内核以 root 写过之后，普通权限的代理内核还能继续写
	_ = os.WriteFile(goldenPath, data, 0666)
}

func goldenAdd(ip string) {
	goldenMu.Lock()
	goldenIPs[ip] = time.Now()
	// 超上限：淘汰最久没过门槛的
	if len(goldenIPs) > goldenMaxKeep {
		type kv struct {
			k string
			t time.Time
		}
		items := make([]kv, 0, len(goldenIPs))
		for k, t := range goldenIPs {
			items = append(items, kv{k, t})
		}
		sort.Slice(items, func(i, j int) bool { return items[i].t.Before(items[j].t) })
		for _, it := range items[:len(items)-goldenMaxKeep] {
			delete(goldenIPs, it.k)
		}
	}
	goldenMu.Unlock()
	go goldenSaveToDisk()
}

func goldenRemove(ip string) {
	goldenMu.Lock()
	delete(goldenIPs, ip)
	goldenMu.Unlock()
	go goldenSaveToDisk()
}

func goldenCandidates() []string {
	goldenLoadOnce.Do(goldenLoadFromDisk)
	goldenMu.Lock()
	defer goldenMu.Unlock()
	now := time.Now()
	out := make([]string, 0, len(goldenIPs))
	for k, t := range goldenIPs {
		if now.Sub(t) < goldenTTL {
			out = append(out, k)
		} else {
			delete(goldenIPs, k)
		}
	}
	return out
}

// rankCandidateIPs 探测各候选 IP 的连通性，返回剔除死边缘后的列表
// （保持原顺序）。一个都探不通时返回 nil，由调用方保持原候选。
func rankCandidateIPs(serverAddr string, candidates []string) []string {
	expanded := resolveCandidates(candidates)

	// 服务域名自己解析出的 IP 也加入候选。
	if host := serverHost(serverAddr); host != "" && net.ParseIP(host) == nil {
		for _, ip := range resolveCandidates([]string{host}) {
			if !containsString(expanded, ip) {
				expanded = append(expanded, ip)
			}
		}
	}
	// 黄金集回池：历轮过门槛的边缘参与本轮竞选，DNS 轮换挤不掉。
	if g := goldenCandidates(); len(g) > 0 {
		log.Printf("[优选] 黄金集回池 %d 个: %v", len(g), g)
		for _, ip := range g {
			if !containsString(expanded, ip) {
				expanded = append(expanded, ip)
			}
		}
	}
	// TUN 模式：探测前先给全部候选补主机路由（见上方 tunModeActive 注释）。
	if tunModeActive.Load() && ensureEdgeRoutes != nil {
		ensureEdgeRoutes(expanded)
	}
	if len(expanded) == 0 {
		return nil
	}
	// 只有一个候选时没得选，探测也不影响结果，省下这轮流量。
	if len(expanded) == 1 {
		return expanded
	}

	log.Printf("[优选] 探测 %d 个候选 IP 的连通性（每个 %d 次）…", len(expanded), probeAttempts)

	oks := make([]int, len(expanded))
	var wg sync.WaitGroup
	sem := make(chan struct{}, probeParallel)
	for i, ip := range expanded {
		wg.Add(1)
		go func(i int, ip string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			for k := 0; k < probeAttempts; k++ {
				if probeOnce(serverAddr, ip) {
					oks[i]++
				}
			}
		}(i, ip)
	}
	wg.Wait()

	ranked := make([]string, 0, len(expanded))
	dropped := make([]string, 0)
	for i, ip := range expanded {
		if oks[i] > 0 {
			ranked = append(ranked, ip)
		} else {
			dropped = append(dropped, ip)
			goldenRemove(ip) // 死边缘不配黄金
		}
	}
	if len(ranked) == 0 {
		// 一个都探不通：可能是探测端点被整网封锁，也可能是链路整体故障
		// —— 保持原候选，不因探测失败而剔光。
		log.Printf("[优选] 全部候选探测失败，保持原候选不变")
		return nil
	}
	for _, ip := range dropped {
		log.Printf("[优选] %s: %d 次探测全败，已剔除", ip, probeAttempts)
	}
	log.Printf("[优选] 可用 %d 个候选，轮转次序保持不变", len(ranked))

	// 吞吐门槛：只在有得挑时做（单候选剔了也没人顶上，白费 1MB 流量）。
	if len(ranked) > 1 {
		if gated := applyThroughputGate(ranked); gated != nil {
			ranked = gated
			log.Printf("[优选] 吞吐门槛后可用 %d 个候选", len(ranked))
		}
	}
	return ranked
}

func containsString(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}
