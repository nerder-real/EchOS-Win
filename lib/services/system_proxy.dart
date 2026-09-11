// 系统代理驱动：Windows 注册表（HKCU Internet Settings）。
import 'dart:convert';
import 'dart:io';

const String _regKey =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

/// 接管前系统代理备份文件（持久化，崩溃/强杀后仍可还原）
const String _backupFileName = 'sysproxy-backup.json';

class SystemProxy {
  static bool isActive = false;
  static bool _savedProxyEnable = false;
  static String _savedProxyServer = '';
  // 2-4：备份绕过列表与 PAC，还原时按原值写回（原无则删除，不留接管残留）
  static String? _savedProxyOverride;
  static String? _savedAutoConfig;

  /// 备份持久化目录（AppData/EchOS）
  static String? _backupDir;

  static void initBackupDir(String dir) => _backupDir = dir;

  static File _backupFile() {
    final dir = _backupDir ?? Directory.systemTemp.path;
    return File('$dir/$_backupFileName');
  }

  /// 接管：设置 HTTP 系统代理（注册表 + 广播生效）
  static Future<({bool ok, List<String> warns})> enable(
      {String? socksHost,
      int? socksPort,
      String? httpHost,
      int? httpPort}) async {
    final warns = <String>[];
    try {
      await _backup();
      // 与其他代理工具冲突防御：若系统代理当前指向非目标端口（如 v2rayN/
      // Clash 的 10808），先提示，避免无声覆盖后两工具打架。
      final occupied = await _regQuerySz(_regKey, 'ProxyServer');
      final targetPort = httpPort ?? 30001;
      final expected = '127.0.0.1:$targetPort';
      if (occupied != null && occupied.isNotEmpty && occupied != expected) {
        warns.add('检测到系统代理当前指向 $occupied（可能由其他代理工具设置），继续操作将覆盖它');
      }
      final host = httpHost ?? '127.0.0.1';
      final port = targetPort;
      final e1 = await _regSet(_regKey, 'ProxyEnable', 1);
      final e2 = await _regSetSz(_regKey, 'ProxyServer', '$host:$port');
      await _regSetSz(_regKey, 'ProxyOverride', '<local>');
      // 2-4：接管期间禁用 PAC（AutoConfigURL），避免与手动代理冲突；还原时恢复
      if (_savedAutoConfig != null) await _regDelete(_regKey, 'AutoConfigURL');
      await _notifySettingChange();
      // 读回验证：ProxyEnable=1 且 ProxyServer 实际写回才算接管成功
      final r = await Process.run(
          'reg', ['query', _regKey, '/v', 'ProxyEnable'], runInShell: true);
      final serverNow = await _regQuerySz(_regKey, 'ProxyServer') ?? '';
      final ok = (r.stdout as String).contains('0x1') &&
          e1 == 0 && e2 == 0 && serverNow == '$host:$port';
      if (!ok) {
        warns.add('系统代理设置没有生效，请手动到系统设置检查');
      }
      isActive = ok;
      return (ok: ok, warns: warns);
    } catch (e) {
      isActive = false;
      warns.add('设置系统代理失败：$e');
      return (ok: false, warns: warns);
    }
  }

  /// 还原系统代理到接管前的状态
  static Future<List<String>> restore() async {
    await _regSet(_regKey, 'ProxyEnable', _savedProxyEnable ? 1 : 0);
    if (_savedProxyServer.isNotEmpty) {
      await _regSetSz(_regKey, 'ProxyServer', _savedProxyServer);
    }
    // 2-4：恢复用户原有绕过列表；原无则删除（避免残留 <local>）
    if (_savedProxyOverride != null) {
      await _regSetSz(_regKey, 'ProxyOverride', _savedProxyOverride!);
    } else {
      await _regDelete(_regKey, 'ProxyOverride');
    }
    // 2-4：恢复用户原有 PAC；原无则删除
    if (_savedAutoConfig != null) {
      await _regSetSz(_regKey, 'AutoConfigURL', _savedAutoConfig!);
    } else {
      await _regDelete(_regKey, 'AutoConfigURL');
    }
    await _notifySettingChange();
    isActive = false;
    await clearBackup();
    return const [];
  }

  /// 当前系统代理摘要
  static Future<String> summary() async {
    final r = await Process.run(
        'reg', ['query', _regKey, '/v', 'ProxyEnable'], runInShell: true);
    if ((r.stdout as String).contains('0x1')) return '已接管（系统代理已开启）';
    return '未启用';
  }

  // ---- Windows 注册表操作 ----

  static Future<int> _regSet(String key, String value, int data) async {
    final r = await Process.run(
        'reg', ['add', key, '/v', value, '/t', 'REG_DWORD', '/d', '$data', '/f'],
        runInShell: true);
    return r.exitCode;
  }

  static Future<int> _regSetSz(String key, String value, String data) async {
    final r = await Process.run(
        'reg', ['add', key, '/v', value, '/t', 'REG_SZ', '/d', data, '/f'],
        runInShell: true);
    return r.exitCode;
  }

  /// 读取 REG_SZ 值；不存在返回 null（区分“原本无此键”与“空串”）
  static Future<String?> _regQuerySz(String key, String value) async {
    try {
      final r = await Process.run(
          'reg', ['query', key, '/v', value], runInShell: true);
      if (r.exitCode != 0) return null;
      final line = (r.stdout as String)
          .split('\n')
          .where((l) => l.contains('REG_SZ'))
          .firstOrNull;
      return line?.split('REG_SZ').last.trim();
    } catch (_) {
      return null;
    }
  }

  static Future<int> _regDelete(String key, String value) async {
    final r = await Process.run(
        'reg', ['delete', key, '/v', value, '/f'], runInShell: true);
    return r.exitCode;
  }

  static Future<void> _backup() async {
    try {
      final r = await Process.run(
          'reg', ['query', _regKey, '/v', 'ProxyEnable'], runInShell: true);
      _savedProxyEnable = (r.stdout as String).contains('0x1');
      final r2 = await Process.run(
          'reg', ['query', _regKey, '/v', 'ProxyServer'], runInShell: true);
      final line = (r2.stdout as String)
          .split('\n')
          .where((l) => l.contains('REG_SZ'))
          .firstOrNull;
      _savedProxyServer = line != null ? line.split('REG_SZ').last.trim() : '';
      _savedProxyOverride = await _regQuerySz(_regKey, 'ProxyOverride');
      _savedAutoConfig = await _regQuerySz(_regKey, 'AutoConfigURL');
    } catch (_) {}
    // 持久化到磁盘，崩溃/强杀后仍可还原
    try {
      await _backupFile().parent.create(recursive: true);
      await _backupFile().writeAsString(
          jsonEncode({
            'enable': _savedProxyEnable,
            'server': _savedProxyServer,
            'override': _savedProxyOverride,
            'autoconfig': _savedAutoConfig,
          }),
          flush: true);
    } catch (_) {}
  }

  /// 判断磁盘上是否有未还原的接管备份（上次异常退出）
  static bool hasPendingBackup() {
    try {
      return _backupFile().existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 从磁盘备份还原（启动自愈）：有备份则写回，防止「假接管残留」
  static Future<List<String>> restoreFromDisk({bool clear = true}) async {
    final f = _backupFile();
    final warns = <String>[];
    try {
      if (!f.existsSync()) return warns;
      final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final wasOn = data['enable'] == true;
      final server = data['server'] as String? ?? '';
      final override = data['override'] as String?;
      final autoconfig = data['autoconfig'] as String?;
      await _regSet(_regKey, 'ProxyEnable', wasOn ? 1 : 0);
      if (wasOn) {
        await _regSetSz(_regKey, 'ProxyServer', server.isNotEmpty ? server : '127.0.0.1:1080');
      }
      if (override != null) {
        await _regSetSz(_regKey, 'ProxyOverride', override);
      } else {
        await _regDelete(_regKey, 'ProxyOverride');
      }
      if (autoconfig != null) {
        await _regSetSz(_regKey, 'AutoConfigURL', autoconfig);
      } else {
        await _regDelete(_regKey, 'AutoConfigURL');
      }
      await _notifySettingChange();
      isActive = wasOn;
      if (clear) {
        try {
          await f.delete();
        } catch (_) {}
      }
    } catch (e) {
      warns.add('还原系统代理备份失败：$e');
    }
    return warns;
  }

  /// 清除磁盘备份（正常接管已被还原/证伪时调用）
  static Future<void> clearBackup() async {
    try {
      final f = _backupFile();
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }

  /// 广播设置变更让系统立即生效
  static Future<void> _notifySettingChange() async {
    try {
      await Process.run(
          'rundll32.exe', ['user32.dll,UpdatePerUserSystemParameters'],
          runInShell: true);
    } catch (_) {}
  }

}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
