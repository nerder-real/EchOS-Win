// 自检：镜像 Mac SelfCheck.swift。
// - 代理运行时：本地端口 + 国内网站 + 国外网站（经隧道）
// - 未运行时：服务端 TCP 预检 + DoH 预检
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/config.dart';
import 'port_tools.dart';

class SelfCheckResult {
  final String title;
  final bool ok;
  final String note;
  final bool dependsOnTunnel;
  const SelfCheckResult(
      this.title, this.ok, this.note, {this.dependsOnTunnel = false});
}

class SelfCheck {
  /// 完整自检（代理运行中）
  static Future<List<SelfCheckResult>> run(
      {required ({String host, int port}) socks}) async {
    final results = <SelfCheckResult>[];

    // 本地端口
    final portOK = !await PortTools.isFree(socks.port);
    results.add(SelfCheckResult(
        '本地代理端口 ${socks.port}',
        portOK,
        portOK ? '正在监听' : '没有监听，内核可能没启动成功'));
    if (!portOK) return results;

    // 国内/国外探针并行（超时 4s ×最多3次），网络波动时不再串行叠加 60s+
    final probes = await Future.wait<({bool ok, double cost, String note})>([
      _probeRobust(socks, 'https://www.baidu.com', 4),
      _probeAnyRobust(socks, [
        'https://www.gstatic.com/generate_204',
        'https://cp.cloudflare.com/generate_204',
      ], 4),
    ]);
    final cn = probes[0];
    results.add(SelfCheckResult(
        '国内网站（百度）',
        cn.ok,
        cn.ok
            ? '${(cn.cost * 1000).round()} 毫秒'
            : '失败：${cn.note}'));

    final fns = probes[1];
    results.add(SelfCheckResult('国外网站（经隧道）', fns.ok,
        fns.ok ? '${fns.note} · 隧道正常' : '失败：${fns.note}',
        dependsOnTunnel: true));

    return results;
  }

  /// 预检（代理未运行）
  static Future<List<SelfCheckResult>> runPreflight(ServerConfig cfg) async {
    final results = <SelfCheckResult>[];
    final serverHost = ServerConfig.cleanHost(cfg.server);
    if (serverHost.isEmpty) {
      results.add(const SelfCheckResult(
          '服务器地址', false, '未填写服务地址或优选IP/域名'));
      return results;
    }

    // 1) 服务器地址：TCP 可达即可。
    // 注意不能做标准 TLS 握手 —— ECH 隧道服务器（ech=cloudflare-ech.com）
    // 只接受 ECH 加密握手，裸 TLS 握手在 TLS 阶段就被服务端拒绝（reset），
    // 但那不代表服务器不可用（内核用 ECH 连能正常跑）。
    final tcp = await _tcpCheck(serverHost, cfg.serverPort, 4);
    results.add(SelfCheckResult('服务器地址', tcp.ok,
        tcp.ok ? 'TCP 端口可达（${cfg.serverPort}）' : tcp.note));

    // 2) Token 鉴权：仅当服务器接受标准 TLS 握手时才有意义（普通 CF Worker，
    //    根路径回 "WebSocket Proxy Server"）。ECH-only 服务器做不了，属正常，跳过。
    if (tcp.ok) {
      final banner = await serverBannerCheck(serverHost, cfg.serverPort, 4);
      if (banner.ok) {
        final ws = await tokenHandshakeCheck(
            serverHost, cfg.serverPort, cfg.token, 4);
        results.add(SelfCheckResult(
            'Token鉴权', ws.ok, ws.ok ? '服务端验证通过' : ws.note));
      } else {
        // 对齐 Mac：标准握手 banner 失败 → 该项判红并说明（可能是 ECH-only，
        // 无法完成标准预检），不再默认为“跳过、正常”。
        results.add(const SelfCheckResult(
            'Token鉴权', false, '服务器未返回标准握手标识（可能是 ECH-only，无法标准预检）'));
      }
    }

    final doh = _dohHost(ServerConfig.normalizedDoH(cfg.dns));
    if (doh != null) {
      final d = await _tcpCheck(doh, 443, 4);
      results.add(SelfCheckResult('DoH 服务器 $doh', d.ok,
          d.ok ? '${(d.cost * 1000).round()} 毫秒' : '失败：${d.note}'));
    } else {
      results.add(const SelfCheckResult(
          'DoH 服务器', true, 'UDP DNS 模式，无需预检'));
    }
    return results;
  }

  /// 请求服务端根路径，验证回的是标准 Worker 标识 "WebSocket Proxy Server"。
  /// 直连（不走系统代理、走 HTTPS），body 含标识即通过。
  static Future<({bool ok, String note})> serverBannerCheck(
      String host, int port, int timeout) async {
    try {
      final raw = await Socket.connect(host, port,
          timeout: Duration(seconds: timeout));
      final tls = await SecureSocket.secure(raw,
          host: host,
          context: SecurityContext.defaultContext,
          onBadCertificate: (cert) => true)
          .timeout(Duration(seconds: timeout));
      final buf = _ProxySocket(tls);
      buf.add('GET / HTTP/1.1\r\n'
          'Host: $host:$port\r\n'
          'Connection: close\r\n'
          '\r\n'
          .codeUnits);
      final head = await buf.readLine().timeout(Duration(seconds: timeout));
      final body = await _readBody(buf).timeout(Duration(seconds: timeout));
      tls.destroy();
      if (body.contains('WebSocket Proxy Server')) {
        return (ok: true, note: '');
      }
      return (ok: false, note: '返回异常内容（HTTP ${head.split(' ').take(2).join(' ')}）');
    } catch (e) {
      return (ok: false, note: '连接失败：请检查服务地址/优选IP/域名（$e）');
    }
  }

  /// 最小 WebSocket 升级握手：带/不带 token（Sec-WebSocket-Protocol）各测一次，
  /// 服务端回 101/200 = 一致，401/403 = 不一致（对齐 Mac tokenHandshakeCheck）。
  static Future<({bool ok, String note})> tokenHandshakeCheck(
      String host, int port, String token, int timeout) async {
    try {
      final raw = await Socket.connect(host, port,
          timeout: Duration(seconds: timeout));
      final tls = await SecureSocket.secure(raw,
          host: host,
          context: SecurityContext.defaultContext,
          onBadCertificate: (cert) => true)
          .timeout(Duration(seconds: timeout));
      final buf = _ProxySocket(tls);
      final proto = token.isEmpty ? '' : 'Sec-WebSocket-Protocol: $token\r\n';
      buf.add(('GET / HTTP/1.1\r\n'
              'Host: $host:$port\r\n'
              'Upgrade: websocket\r\n'
              'Connection: Upgrade\r\n'
              'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
              'Sec-WebSocket-Version: 13\r\n'
              '$proto'
              '\r\n')
          .codeUnits);
      final line = await buf.readLine().timeout(Duration(seconds: timeout));
      tls.destroy();
      final code = _statusCode(line);
      if (code == 401 || code == 403) return (ok: false, note: '与服务端TOKEN不一致');
      if (code == 200 || code == 101) return (ok: true, note: '');
      return (ok: false, note: '客户端与服务端不一致');
    } catch (e) {
      return (ok: false, note: '握手失败：$e');
    }
  }

  static int _statusCode(String statusLine) {
    final parts = statusLine.split(' ');
    if (parts.length >= 2 && parts[0].startsWith('HTTP/')) {
      return int.tryParse(parts[1]) ?? 0;
    }
    return 0;
  }

  static Future<String> _readBody(_ProxySocket buf) async {
    final sb = StringBuffer();
    final limit = 4096;
    while (sb.length < limit) {
      try {
        final line = await buf.readLine()
            .timeout(const Duration(milliseconds: 800));
        if (line.isEmpty) break;
        sb.write(line);
      } catch (_) {
        break;
      }
    }
    return sb.toString();
  }

  static String? _dohHost(String raw) {
    final lower = raw.toLowerCase();
    if (lower.startsWith('https://') || lower.startsWith('http://')) {
      final rest = raw.substring(raw.indexOf('://') + 3);
      final slash = rest.indexOf('/');
      return slash >= 0 ? rest.substring(0, slash) : rest;
    }
    return null;
  }

  static Future<({bool ok, double cost, String note})> _probeRobust(
      ({String host, int port}) socks, String url, int timeout) async {
    var last = await _probe(socks, url, timeout);
    if (last.ok) return last;
    await Future.delayed(const Duration(seconds: 1));
    last = await _probe(socks, url, timeout);
    if (last.ok) return last;
    await Future.delayed(const Duration(seconds: 3));
    last = await _probe(socks, url, timeout);
    return last;
  }

  static Future<({bool ok, double cost, String note})> _probeAnyRobust(
      ({String host, int port}) socks, List<String> urls, int timeout) async {
    final first = await _probeAny(socks, urls, timeout);
    if (first.ok) return first;
    await Future.delayed(const Duration(seconds: 1));
    final second = await _probeAny(socks, urls, timeout);
    if (second.ok) return second;
    await Future.delayed(const Duration(seconds: 3));
    final third = await _probeAny(socks, urls, timeout);
    return third;
  }

  static Future<({bool ok, double cost, String note})> _probeAny(
      ({String host, int port}) socks, List<String> urls, int timeout) async {
    final failures = <String>[];
    // 多站点并发探测，任一成功即返回（不再串行逐站累加超时）
    final rs = await Future.wait<({bool ok, double cost, String note})>([
      for (final u in urls) _probe(socks, u, timeout),
    ]);
    for (var i = 0; i < rs.length; i++) {
      final r = rs[i];
      final u = urls[i];
      if (r.ok) {
        final host = Uri.tryParse(u)?.host ?? u;
        return (ok: true,
            cost: r.cost,
            note: '$host · ${(r.cost * 1000).round()} 毫秒');
      }
      failures.add('${Uri.tryParse(u)?.host ?? u}：${_shortError(r.note)}');
    }
    return (ok: false, cost: 0.0, note: failures.join('；'));
  }

  /// 通过 SOCKS5 代理发起 HTTPS HEAD（镜像 Mac URLSession probe）。
  /// 内核隧道走 TLS：先手写 SOCKS5 CONNECT 建立隧道，再用
  /// SecureSocket.secure 在隧道内升级 TLS，最后发 HTTP/1.1 HEAD。
  static Future<({bool ok, double cost, String note})> _probe(
      ({String host, int port}) socks, String url, int timeout) async {
    final sw = Stopwatch()..start();
    try {
      final host = Uri.parse(url).host;
      final path = Uri.parse(url).path.isEmpty ? '/' : Uri.parse(url).path;
      final raw = await Socket.connect(socks.host, socks.port,
          timeout: Duration(seconds: timeout));
      final buf = _ProxySocket(raw);
      final handshake =
          await _socks5Connect(buf, host, 443).timeout(Duration(seconds: timeout));
      if (!handshake) {
        raw.destroy();
        return (ok: false,
            cost: sw.elapsedMilliseconds / 1000,
            note: 'SOCKS5 握手失败');
      }
      // 隧道上做 TLS
      final tls = await SecureSocket.secure(raw,
          host: host, onBadCertificate: (cert) => true)
          .timeout(Duration(seconds: timeout));
      final tlsBuf = _ProxySocket(tls);
      tls.write('HEAD $path HTTP/1.1\r\n'
          'Host: $host\r\n'
          'Connection: close\r\n\r\n');
      await tls.flush();
      final line =
          await tlsBuf.readLine().timeout(Duration(seconds: timeout));
      raw.destroy();
      final ok = line.startsWith('HTTP/1.');
      return (ok: ok,
          cost: sw.elapsedMilliseconds / 1000,
          note: line.isEmpty ? '无响应' : line.split(' ').take(2).join(' '));
    } catch (e) {
      return (ok: false, cost: sw.elapsedMilliseconds / 1000, note: '$e');
    }
  }

  static Future<bool> _socks5Connect(
      _ProxySocket buf, String host, int port) async {
    buf.add([0x05, 0x01, 0x00]); // version 5, 1 method, no-auth
    final r1 = await buf.readN(2);
    if (r1.length < 2 || r1[1] != 0x00) return false;
    final hostBytes =
        <int>[0x05, 0x01, 0x00, 0x03, host.length, ...host.codeUnits];
    final portBytes = [(port >> 8) & 0xFF, port & 0xFF];
    buf.add([...hostBytes, ...portBytes]);
    final head = await buf.readN(4);
    if (head.length < 4 || head[1] != 0x00) return false;
    final atyp = head[3];
    if (atyp == 0x01) {
      await buf.readN(6); // IPv4(4) + port(2)
    } else if (atyp == 0x03) {
      final lenB = await buf.readN(1);
      if (lenB.isEmpty) return false;
      await buf.readN(lenB[0] + 2); // domain(len) + port(2)
    } else if (atyp == 0x04) {
      await buf.readN(18); // IPv6(16) + port(2)
    }
    return true;
  }

  static Future<({bool ok, double cost, String note})> _tcpCheck(
      String host, int port, int timeout) async {
    final sw = Stopwatch()..start();
    try {
      final s = await Socket.connect(host, port,
          timeout: Duration(seconds: timeout));
      s.destroy();
      return (ok: true, cost: sw.elapsedMilliseconds / 1000, note: '已连通');
    } catch (e) {
      final msg = '$e';
      return (ok: false,
          cost: sw.elapsedMilliseconds / 1000,
          note: msg.contains('timed out') || msg.contains('Timeout')
              ? '连接超时'
              : msg.contains('Failed host lookup')
                  ? '域名解析失败'
                  : '连接失败');
    }
  }

  static String _shortError(String s) {
    var t = s.replaceAll('\n', ' ');
    if (t.length > 48) t = '${t.substring(0, 48)}…';
    return t;
  }
}

/// 单次订阅（Socket/SecureSocket），按需读 N 字节 / 读一行。
/// 避免对 single-subscription Stream 重复 listen。
class _ProxySocket {
  final Stream<List<int>> _stream;
  final IOSink _sink;
  final List<int> _buf = [];
  final Completer<void> _closed = Completer<void>();
  Object? _error;

  _ProxySocket(Socket s)
      : _stream = s,
        _sink = s {
    _sub = _stream.listen(_collect,
        onDone: () {
          if (!_closed.isCompleted) _closed.complete();
        },
        onError: (Object e) {
          _error = e;
          if (!_closed.isCompleted) _closed.complete();
        });
  }

  // ignore: unused_field
  late final StreamSubscription<List<int>> _sub; // 持有订阅，防 GC 回收流

  void _collect(List<int> d) {
    _buf.addAll(d);
  }

  void add(List<int> bytes) {
    _sink.add(bytes);
    _sink.flush();
  }

  Future<List<int>> readN(int n) async {
    while (_buf.length < n) {
      if (_closed.isCompleted) break;
      await _closed.future
          .timeout(const Duration(milliseconds: 40), onTimeout: () {});
    }
    if (_buf.isEmpty && _error != null) {
      throw _error!;
    }
    final out = _buf.take(n).toList();
    _buf.removeRange(0, out.length);
    return out;
  }

  Future<String> readLine() async {
    while (true) {
      for (var i = 0; i + 1 < _buf.length; i++) {
        if (_buf[i] == 0x0D && _buf[i + 1] == 0x0A) {
          final line = _buf.sublist(0, i);
          _buf.removeRange(0, i + 2);
          return utf8.decode(line, allowMalformed: true);
        }
      }
      if (_closed.isCompleted) {
        if (_buf.isEmpty) {
          if (_error != null) throw _error!;
          return '';
        }
        return utf8.decode(_buf, allowMalformed: true);
      }
      await _closed.future
          .timeout(const Duration(milliseconds: 40), onTimeout: () {});
    }
  }
}
