package main

import (
	"testing"
	"time"
)

// badDoHForECHTest 是一个必定解析失败的 DoH 地址：
// 不含 http(s):// 前缀 → 走 queryDNSUDP → 补 :53 后 lookup 失败（no such host）。
// 失败得很快，不用等网络超时。
const badDoHForECHTest = "nonexistent.invalid"

// withBadECH 临时把全局 DoH 换成必定失败的地址，跑完还原。
// 注意 dnsServer / echDomain / echUnavailable 都是包级变量，测试之间会互相污染。
func withBadECH(t *testing.T, fn func()) {
	t.Helper()
	oldDNS, oldDomain := dnsServer, echDomain
	oldUnavailable := echUnavailable.Load()
	defer func() {
		dnsServer, echDomain = oldDNS, oldDomain
		echUnavailable.Store(oldUnavailable)
	}()

	dnsServer = badDoHForECHTest
	echDomain = "cloudflare-ech.com"
	echUnavailable.Store(false)

	fn()
}

// TestPrepareECHStartupDegradesButStarts 钉住启动路径的语义：
// 预算用尽后**降级**（置位 echUnavailable）并返回 nil —— 内核必须起得来。
//
// 回归背景：prepareECH 原本是 `for {}` 无退出条件，DoH 配错时内核永远卡在
// 这一步，端口永不监听，界面只报「内核可能启动失败」。
func TestPrepareECHStartupDegradesButStarts(t *testing.T) {
	withBadECH(t, func() {
		err := prepareECH(time.Millisecond, true) // degradeOnFail=true → 启动路径
		if err != nil {
			t.Fatalf("启动路径预算用尽后必须降级并返回 nil（否则内核起不来），实际: %v", err)
		}
		if !echUnavailable.Load() {
			t.Fatal("启动路径预算用尽后必须置位 echUnavailable")
		}
	})
}

// TestPrepareECHRefreshMustNotDegrade 钉住刷新路径的语义：
// 失败时**只返回 error**，绝不置位 echUnavailable、也绝不覆盖已有的 echList。
//
// 回归背景：refreshECH 由「建连失败」触发。若它也能降级，那么一次瞬时 DoH
// 抖动就会把整个会话永久降级；而降级后错误信息里不再含 "ECH"，refreshECH
// 再也不会被调用 —— 本会话内无法恢复。
func TestPrepareECHRefreshMustNotDegrade(t *testing.T) {
	withBadECH(t, func() {
		// 预置一份「旧配置」，刷新失败后必须原样保留。
		const stale = "stale-ech-config"
		echListMu.Lock()
		echList = []byte(stale)
		echListMu.Unlock()
		defer func() {
			echListMu.Lock()
			echList = nil
			echListMu.Unlock()
		}()

		err := prepareECH(time.Millisecond, false) // degradeOnFail=false → 刷新路径
		if err == nil {
			t.Fatal("刷新路径失败必须返回 error（不能静默成功）")
		}
		if echUnavailable.Load() {
			t.Fatal("刷新路径失败绝不能置位 echUnavailable —— 那会把整个会话永久降级且无法恢复")
		}

		echListMu.RLock()
		got := string(echList)
		echListMu.RUnlock()
		if got != stale {
			t.Fatalf("刷新失败必须保留原 echList，实际变成 %q", got)
		}
	})
}

// TestPrepareECHBudgetBoundsStartup 钉住「按墙钟预算收尾」这个契约。
//
// 为什么关键：单次查询自身最长要 3 秒（DoH）或 4 秒（UDP），若只限次数，
// 10 次重试最坏要 60 秒；而 Dart 侧 `_waitPortsReady` 非 TUN 只等 25 秒 ——
// 内核还在重试、Dart 已判「内核可能启动失败」把它杀掉，降级路径走不到。
//
// 断言：总耗时 ≤ budget + 单次查询上限（留 4 秒余量）。
func TestPrepareECHBudgetBoundsStartup(t *testing.T) {
	withBadECH(t, func() {
		const budget = 3 * time.Second
		start := time.Now()
		_ = prepareECH(budget, true)
		elapsed := time.Since(start)

		// budget 3s + 单次查询上限 4s = 7s；再宽一点给调度留余量。
		if limit := budget + 4*time.Second; elapsed > limit {
			t.Fatalf("总耗时 %v 超出「预算 %v + 单次查询上限 4s = %v」——"+
				"预算没有真正封住启动时间，Dart 侧会把内核误判为启动失败", elapsed, budget, limit)
		}
		// 预算 3s / 间隔 2s → 至少应尝试 2 次（t=0 与 t=2s），不能一次就放弃。
		if elapsed < 2*time.Second {
			t.Fatalf("总耗时仅 %v，看起来只尝试了 1 次 —— 预算内应充分利用重试机会", elapsed)
		}
	})
}
