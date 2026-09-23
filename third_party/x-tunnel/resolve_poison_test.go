package main

import (
	"encoding/binary"
	"testing"
)

// testAnswer 拼一条 answer 记录：名字统一用压缩指针 0xC00C（指向 question 里的域名）。
// 解析器不关心 owner 到底是谁，只按「跳名字 → 读 type/rdlen/rdata」走位，
// 所以这里不必严格复刻「CNAME 的 rdata 名才是后续 A 记录的 owner」。
func testAnswer(rtype uint16, rdata []byte) []byte {
	b := []byte{0xC0, 0x0C}
	b = append(b, byte(rtype>>8), byte(rtype))
	b = append(b, 0x00, 0x01) // class IN
	b = append(b, 0x00, 0x00, 0x00, 0x3C)
	b = append(b, byte(len(rdata)>>8), byte(len(rdata)))
	return append(b, rdata...)
}

// testDNSResponse 拼一个带 question 的响应报文。
func testDNSResponse(answers ...[]byte) []byte {
	q := buildDNSQuery("cdns.doon.eu.org", dnsTypeA)
	q[2], q[3] = 0x81, 0x80 // QR=1, RD=1, RA=1
	binary.BigEndian.PutUint16(q[6:8], uint16(len(answers)))
	for _, a := range answers {
		q = append(q, a...)
	}
	return q
}

// cnameRData 把域名编成未压缩的名字（CNAME 的 rdata）。
func cnameRData(name string) []byte {
	var b []byte
	label := []byte{}
	for _, c := range name {
		if c == '.' {
			b = append(b, byte(len(label)))
			b = append(b, label...)
			label = label[:0]
			continue
		}
		label = append(label, byte(c))
	}
	if len(label) > 0 {
		b = append(b, byte(len(label)))
		b = append(b, label...)
	}
	return append(b, 0x00)
}

// TestParseARecordsSkipsCNAME 钉住「优选域名是 CNAME 到 CF 站点」这个真实形态：
// 答案里第一条是 CNAME，后面才是 A 记录 —— 解析器必须跳过 CNAME 取到 A。
//
// 真机事故背景：cdns.doon.eu.org 实际 CNAME 到 www.nexusmods.com，
// 正确解析是 [104.18.42.54, 172.64.145.202]；运营商 DNS 却污染成 8.134.121.112。
func TestParseARecordsSkipsCNAME(t *testing.T) {
	resp := testDNSResponse(
		testAnswer(5, cnameRData("www.nexusmods.com")), // CNAME，必须被跳过
		testAnswer(1, []byte{104, 18, 42, 54}),         // A
		testAnswer(1, []byte{172, 64, 145, 202}),       // A
	)
	got := parseARecords(resp)
	want := []string{"104.18.42.54", "172.64.145.202"}
	if len(got) != len(want) {
		t.Fatalf("解析出 %d 条记录 %v，期望 %d 条 %v", len(got), got, len(want), want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("第 %d 条 = %q，期望 %q（完整结果 %v）", i, got[i], want[i], got)
		}
	}
}

// TestParseARecordsAAAA 覆盖 AAAA 分支（16 字节 rdata）。
func TestParseARecordsAAAA(t *testing.T) {
	resp := testDNSResponse(
		testAnswer(5, cnameRData("www.nexusmods.com")),
		testAnswer(28, []byte{0x26, 0x06, 0x47, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01}),
	)
	got := parseARecords(resp)
	if len(got) != 1 || got[0] != "2606:4700::1" {
		t.Fatalf("AAAA 解析结果 = %v，期望 [2606:4700::1]", got)
	}
}

// TestParseARecordsEmptyAndTruncated 空答案 / 截断报文不能 panic，只能返回空。
func TestParseARecordsEmptyAndTruncated(t *testing.T) {
	if got := parseARecords(nil); got != nil {
		t.Fatalf("nil 报文应返回 nil，实际 %v", got)
	}
	if got := parseARecords([]byte{0, 1, 2}); got != nil {
		t.Fatalf("过短报文应返回 nil，实际 %v", got)
	}
	// 声明有 2 条 answer，但只给半条 —— 必须安全截断。
	resp := testDNSResponse(testAnswer(1, []byte{1, 2, 3, 4}))
	binary.BigEndian.PutUint16(resp[6:8], 2)
	resp = resp[:len(resp)-2]
	_ = parseARecords(resp) // 不 panic 即通过
}

// TestSameIPSet 顺序无关、去重、解析失败的值忽略。
func TestSameIPSet(t *testing.T) {
	cases := []struct {
		a, b []string
		want bool
	}{
		{[]string{"1.1.1.1", "2.2.2.2"}, []string{"2.2.2.2", "1.1.1.1"}, true},
		{[]string{"1.1.1.1"}, []string{"1.1.1.1", "2.2.2.2"}, false},
		{[]string{"1.1.1.1"}, []string{"1.1.1.1"}, true},
		{nil, nil, true},
		{[]string{"not-an-ip"}, nil, true}, // 解析失败的项被忽略 → 两个空集相等
		{[]string{"104.18.42.54", "172.64.145.202"}, []string{"8.134.121.112"}, false},
	}
	for i, c := range cases {
		if got := sameIPSet(c.a, c.b); got != c.want {
			t.Fatalf("用例 %d: sameIPSet(%v, %v) = %v，期望 %v", i, c.a, c.b, got, c.want)
		}
	}
}

// TestResolveServerIPv4FallsBackWhenNoControlPlaneDNS 钉住兜底：
// dnsServer 为空（单元测试环境）时必须退回系统解析器，而不是直接返回 nil
// —— 否则「DoH 没配好」会变成「服务器域名完全解析不出来」。
func TestResolveServerIPv4FallsBackWhenNoControlPlaneDNS(t *testing.T) {
	old := dnsServer
	oldFallback := builtinDoHFallbacks
	dnsServer = ""
	// 兜底列表置空：否则这个单元测试会真的去打公共 DoH（既慢又依赖网络）。
	builtinDoHFallbacks = nil
	defer func() {
		dnsServer = old
		builtinDoHFallbacks = oldFallback
	}()

	if ips := resolveViaControlPlaneDNS("localhost"); ips != nil {
		t.Fatalf("dnsServer 为空时不应走控制面 DNS，实际 %v", ips)
	}
	ips := resolveServerIPv4("localhost")
	if len(ips) == 0 {
		t.Fatal("dnsServer 为空时必须退回系统解析器，localhost 至少应解析出 127.0.0.1")
	}
	for _, ip := range ips {
		if ip != "127.0.0.1" {
			t.Fatalf("localhost 解析出 %v，期望只含 127.0.0.1", ips)
		}
	}
}
