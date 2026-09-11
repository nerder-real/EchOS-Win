// 更新器：镜像 Mac Updater.swift。
// - 检查 GitHub release 新版本
// - 更新 geoip/geosite 分流数据（Loyalsoldier/v2ray-rules-dat）
// - 下载更新包（带进度回调与取消，镜像 Mac downloadDMG）
import 'dart:convert';
import 'dart:io';

import 'app_paths.dart';

class ReleaseInfo {
  final String tag;
  final String version;
  final String? assetName;
  final String? assetUrl;
  final String htmlUrl;
  ReleaseInfo(this.tag, this.version, this.assetName, this.assetUrl, this.htmlUrl);
}

/// 下载结果（镜像 Mac DMGDownloader 成功/取消/失败三态）。
class DownloadOutcome {
  final bool ok;
  final bool cancelled;
  final String path;
  DownloadOutcome(this.ok, this.cancelled, this.path);
}

class Updater {
  // 更新源（owner/repo）。构建期经 --dart-define=ECHOS_REPO=... 注入；
  // CI 传 github.repository，Fork 后自动指向 Fork 仓库，无需改代码。
  // 未注入时留空 → 界面提示「未配置更新源」，可正常检查 geo 数据。
  static String repo = const String.fromEnvironment('ECHOS_REPO');
  static const geoRepo = 'Loyalsoldier/v2ray-rules-dat';

  static List<int> parseVersion(String v) {
    var t = v.trim();
    if (t.startsWith('v') || t.startsWith('V')) t = t.substring(1);
    return t.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  }

  static bool isNewer(List<int> a, List<int> b) {
    final len = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < len; i++) {
      final av = i < a.length ? a[i] : 0;
      final bv = i < b.length ? b[i] : 0;
      if (av != bv) return av > bv;
    }
    return false;
  }

  // 1-3：更新网络策略——先走系统代理，失败降级直连（对齐 Mac Updater）
  static String? _systemProxyAddr() {
    try {
      final r1 = Process.runSync('reg',
          [
            'query',
            r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
            '/v', 'ProxyEnable'
          ],
          runInShell: true);
      if (!(r1.stdout as String).contains('0x1')) return null;
      final r2 = Process.runSync('reg',
          [
            'query',
            r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
            '/v', 'ProxyServer'
          ],
          runInShell: true);
      final line = (r2.stdout as String)
          .split('\n')
          .where((l) => l.contains('REG_SZ'))
          .firstOrNull;
      final v = line?.split('REG_SZ').last.trim() ?? '';
      return v.isEmpty ? null : v;
    } catch (_) {
      return null;
    }
  }

  static HttpClient _client({required bool viaProxy}) {
    final c = HttpClient();
    c.connectionTimeout = const Duration(seconds: 12);
    if (viaProxy) {
      final p = _systemProxyAddr();
      c.findProxy = (uri) => p == null ? 'DIRECT' : 'PROXY $p';
    } else {
      c.findProxy = (uri) => 'DIRECT';
    }
    return c;
  }

  /// 抓取文本：先系统代理，失败（网络/代理不可达）降级直连重试一次。
  static Future<String> _getBody(String url,
      {int timeoutSec = 15}) async {
    Object? last;
    for (final viaProxy in [true, false]) {
      final c = _client(viaProxy: viaProxy);
      try {
        final req =
            await c.getUrl(Uri.parse(url)).timeout(Duration(seconds: timeoutSec));
        final r = await req.close().timeout(Duration(seconds: timeoutSec));
        return await r.transform(utf8.decoder).join();
      } catch (e) {
        last = e;
      } finally {
        c.close();
      }
    }
    throw last ?? Exception('请求失败');
  }

  /// 抓取最新 release；repo 为空返回 null。
  /// [preferPortable] 为 true 时优先选 `-Portable.exe`，否则优先 `-Setup.exe`。
  static Future<ReleaseInfo?> fetchLatestRelease(
      {bool preferPortable = false}) async {
    if (repo.trim().isEmpty) return null;
    final url = 'https://api.github.com/repos/${repo.trim()}/releases/latest';
    try {
      final body = await _getBody(url);
      final j = jsonDecode(body) as Map<String, dynamic>;
      final tag = (j['tag_name'] as String?) ?? '';
      final version = tag.replaceFirst(RegExp(r'^[vV]'), '');
      final html = (j['html_url'] as String?) ?? 'https://github.com/${repo.trim()}';
      String? assetName, assetUrl;
      String? firstExe, firstExeUrl, setupExe, setupUrl, portableExe, portableUrl,
          zip, zipUrl;
      final assets = (j['assets'] as List?) ?? [];
      for (final a in assets) {
        final m = a as Map<String, dynamic>;
        final n = (m['name'] as String?) ?? '';
        final u = m['browser_download_url'] as String?;
        if (n.endsWith('.exe')) {
          if (firstExe == null) {
            firstExe = n;
            firstExeUrl = u;
          }
          if (n.contains('-Setup')) {
            setupExe = n;
            setupUrl = u;
          } else if (n.contains('-Portable')) {
            portableExe = n;
            portableUrl = u;
          }
        } else if (n.endsWith('.zip') && zip == null) {
          zip = n;
          zipUrl = u;
        }
      }
      if (preferPortable && portableUrl != null) {
        assetName = portableExe;
        assetUrl = portableUrl;
      } else if (!preferPortable && setupUrl != null) {
        assetName = setupExe;
        assetUrl = setupUrl;
      } else if (firstExe != null) {
        assetName = firstExe;
        assetUrl = firstExeUrl;
      } else if (zip != null) {
        assetName = zip;
        assetUrl = zipUrl;
      }
      return ReleaseInfo(tag, version, assetName, assetUrl, html);
    } catch (_) {
      return null;
    }
  }

  /// 下载更新包到「下载」文件夹（不存在则退回数据目录）。
  /// 进度回调：progress ∈ [0,1]；未知大小时不回调。
  /// 镜像 Mac downloadDMG：可取消、写临时文件、完成后原子改名。
  static Future<DownloadOutcome> downloadAsset(
    ReleaseInfo info,
    void Function(double progress) onProgress, {
    bool Function()? isCancelled,
  }) async {
    final url = info.assetUrl;
    if (url == null) return DownloadOutcome(false, false, '');
    final base = (info.assetName == null || info.assetName!.trim().isEmpty)
        ? 'EchOS-update'
        : info.assetName!;
    final dir = downloadDir();
    try {
      dir.createSync(recursive: true);
    } catch (_) {}
    final sep = Platform.pathSeparator;
    final target = File('${dir.path}$sep$base');
    final tmp = File('${target.path}.part');
    try {
      // 1-3：先系统代理，失败降级直连
      HttpClientResponse? resp;
      for (final viaProxy in [true, false]) {
        final c = _client(viaProxy: viaProxy);
        try {
          final req = await c.getUrl(Uri.parse(url));
          resp = await req.close().timeout(const Duration(seconds: 30));
          break;
        } catch (_) {
          c.close();
          resp = null;
        }
      }
      if (resp == null || resp.statusCode != 200) {
        return DownloadOutcome(false, false, '');
      }
      final total = resp.contentLength;
      final sink = tmp.openWrite();
      var written = 0;
      await for (final chunk in resp) {
        if (isCancelled != null && isCancelled()) {
          await sink.close();
          if (tmp.existsSync()) tmp.deleteSync();
          return DownloadOutcome(false, true, '');
        }
        sink.add(chunk);
        written += chunk.length;
        if (total > 0) onProgress(written / total);
      }
      await sink.close();
      if (target.existsSync()) target.deleteSync();
      tmp.renameSync(target.path);
      onProgress(1);
      return DownloadOutcome(true, false, target.path);
    } catch (_) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      return DownloadOutcome(false, false, '');
    }
  }

  static Directory downloadDir() {
    final home = Platform.environment['USERPROFILE'] ?? 'C:\\Users\\Default';
    final dd = Directory('$home${Platform.pathSeparator}Downloads');
    try {
      if (!dd.existsSync()) dd.createSync(recursive: true);
      return dd;
    } catch (_) {
      return AppPaths.dataDir;
    }
  }

  /// 更新分流数据；返回结果文案
  static Future<String> updateGeoData({bool force = false}) async {
    final releaseUrl =
        'https://api.github.com/repos/$geoRepo/releases/latest';
    try {
      final r = await HttpClient()
          .getUrl(Uri.parse(releaseUrl))
          .then((h) => h.close())
          .timeout(const Duration(seconds: 15));
      final j = jsonDecode(await r.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      final tag = (j['tag_name'] as String?) ?? '';
      final local = localGeoVersion();
      if (!force && local == tag && hasLocalGeoData()) {
        return '分流数据：已是最新（v$tag）';
      }
      final ok1 = await _downloadGeo('geoip.dat', tag);
      final ok2 = await _downloadGeo('geosite.dat', tag);
      if (ok1 && ok2) {
        _writeMeta(tag);
        return '分流数据：已更新到 v$tag';
      }
      return '分流数据：下载失败，已保留原有数据';
    } catch (_) {
      return '分流数据：检查失败（网络不通或 GitHub 不可达）';
    }
  }

  /// 下载分流数据文件。
  ///
  /// 与 `_getBody` 保持一致的通道策略：**先走系统代理，失败再降级直连**。
  /// 此前这里用的是裸 `HttpClient`（不带代理），而分流数据恰恰是首次启动、
  /// 代理还没配好时最需要的东西 —— 一旦 GitHub 直连不通就只能退回全局模式。
  static Future<bool> _downloadGeo(String name, String tag) async {
    final dir = AppPaths.dataDir;
    final url =
        'https://github.com/$geoRepo/releases/download/$tag/$name';
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    final tmp = File('${file.path}.tmp');
    for (final viaProxy in [true, false]) {
      final c = _client(viaProxy: viaProxy);
      try {
        final req = await c
            .getUrl(Uri.parse(url))
            .timeout(const Duration(seconds: 30));
        final resp = await req.close().timeout(const Duration(seconds: 120));
        if (resp.statusCode != 200) continue;
        final sink = tmp.openWrite();
        await resp.pipe(sink);
        await sink.close();
        // 太小说明拿到的是错误页/重定向，不是真正的 .dat
        if (tmp.lengthSync() <= 100000) {
          tmp.deleteSync();
          continue;
        }
        if (file.existsSync()) file.deleteSync();
        tmp.renameSync(file.path);
        return true;
      } catch (_) {
        if (tmp.existsSync()) {
          try {
            tmp.deleteSync();
          } catch (_) {}
        }
        // 换下一种通道重试
      } finally {
        c.close();
      }
    }
    return false;
  }

  static String localGeoVersion() {
    final f = File('${AppPaths.dataDir.path}${Platform.pathSeparator}meta.json');
    if (!f.existsSync()) return '';
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return (j['version'] as String?) ?? '';
    } catch (_) {
      return '';
    }
  }

  static bool hasLocalGeoData() =>
      AppPaths.geoipPath != null && AppPaths.geositePath != null;

  static void _writeMeta(String tag) {
    final meta = {
      'source': 'loyalsoldier',
      'version': tag,
      'updatedAt': DateTime.now().toIso8601String(),
    };
    File('${AppPaths.dataDir.path}${Platform.pathSeparator}meta.json')
        .writeAsStringSync(jsonEncode(meta), flush: true);
  }
}
