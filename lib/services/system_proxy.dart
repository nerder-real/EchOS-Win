// 系统代理驱动：Windows 注册表（HKCU Internet Settings）。
import 'dart:convert';
import 'dart:ffi';
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
  /// TUN 让位清空标记：系统代理当前是「为 TUN 清空」的状态，注册表里的值
  /// **不是用户原值**——备份必须保持为清空前的原样（退出/关 TUN 时按原值还原），
  /// 且此状态下不能再做新备份（会用空值覆盖原始备份）。
  static bool tunCleared = false;

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
      final host = httpHost ?? '127.0.0.1';
      final port = targetPort;
      // expected 用与下方写入完全相同的 host:port：自定义监听地址（0.0.0.0
      // 等）时，上次崩溃残留的自己的值不该被当成「其他工具」误警告。
      final expected = '$host:$port';
      if (occupied != null && occupied.isNotEmpty && occupied != expected) {
        warns.add('检测到系统代理当前指向 $occupied（可能由其他代理工具设置），继续操作将覆盖它');
      }
      final e1 = await _regSet(_regKey, 'ProxyEnable', 1);
      final e2 = await _regSetSz(_regKey, 'ProxyServer', '$host:$port');
      // 记住本工具写入的地址：运行期被抢占检测（stolenBy）靠它判定
      // 「系统代理还是不是我们的」。
      _ourServer = '$host:$port';
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

  /// 接管前系统代理是否处于启用状态（仅供日志/提示使用）
  static bool get savedWasEnabled => _savedProxyEnable;

  /// 还原系统代理到接管前的状态
  static Future<List<String>> restore() async {
    final warns = <String>[];
    // 还原前验活：接管前的代理设置多半来自别的代理工具（v2rayN/Clash 的
    // 127.0.0.1:10808）。那个工具若已退出，还原回去就是一个指向死端口的
    // 系统代理——全机直接断网（弹激活页切断、正常停止、异常退出自愈
    // 都会走到这里）。TCP 探一下：死的就不还原，宁可直连。
    bool restoreEnabled = _savedProxyEnable;
    if (restoreEnabled &&
        _savedProxyServer.isNotEmpty &&
        !await _proxyAlive(_savedProxyServer)) {
      restoreEnabled = false;
      warns.add('原系统代理 $_savedProxyServer 已无响应'
          '（对应工具可能已退出），已还原为直连而不是指回死端口');
    }
    await _regSet(_regKey, 'ProxyEnable', restoreEnabled ? 1 : 0);
    if (restoreEnabled && _savedProxyServer.isNotEmpty) {
      // 只有「接管前确实开着代理」才写回地址 —— 那是用户真在用的配置。
      await _regSetSz(_regKey, 'ProxyServer', _savedProxyServer);
    } else {
      // 接管前代理本来就是关的（或验活判死）：注册表里那个 ProxyServer
      // 多半是别的代理工具（v2rayN / Clash 等）退出时留下的僵尸值，
      // 比如 127.0.0.1:10808。代理关着时它不生效，但留着有两个坏处：
      //   1) 日志和系统设置里看起来像「还原到了一个陌生地址」，平白引起误解；
      //   2) 用户日后手动打开系统代理开关时，会意外连到这个早就不存在的地址。
      // 所以这里删掉，还原成「干净的未启用」状态。
      await _regDelete(_regKey, 'ProxyServer');
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
    return warns;
  }

  /// TUN 让位：把系统代理**清空**（全部关闭），不是还原备份。
  ///
  /// 为什么是清空而不是还原：还原会把备份里的第三方代理（v2rayN 的
  /// 127.0.0.1:10808）写回去，浏览器流量在**应用层**被它截走、根本不进
  /// TUN 的 IP 层接管——用户感知「TUN 开了网页打不开」（Mac 同病实录，
  /// TUN 存活 77 秒仅 3 条 TCP、461 条 DNS 全部绕行）。
  ///
  /// 语义：①清空前确保有备份（否则清空不可逆地丢掉第三方代理原值）；
  /// ②备份原样保留，关 TUN / 退出时按原值还原；③写完必须读回验证
  /// （注册表偶发「返回成功却没写」），失败重试一次，仍失败留醒目警告。
  static Future<({bool ok, List<String> warns})> clearForTun() async {
    final warns = <String>[];
    try {
      await _backup();
      for (var attempt = 1; attempt <= 2; attempt++) {
        await _regSet(_regKey, 'ProxyEnable', 0);
        await _regDelete(_regKey, 'ProxyServer');
        // PAC 与手动代理并存时 PAC 会抢答，TUN 期间一并清掉（原值在备份里）
        if (_savedAutoConfig != null) {
          await _regDelete(_regKey, 'AutoConfigURL');
        }
        await _notifySettingChange();
        final r = await Process.run(
            'reg', ['query', _regKey, '/v', 'ProxyEnable'], runInShell: true);
        if (!(r.stdout as String).contains('0x1')) {
          tunCleared = true;
          return (ok: true, warns: warns);
        }
        if (attempt == 1) warns.add('TUN 清空系统代理第一次未生效，已重试');
      }
      tunCleared = false;
      warns.add('TUN 清空系统代理失败：系统代理仍处于启用状态，'
          '浏览器流量可能不经过隧道');
      return (ok: false, warns: warns);
    } catch (e) {
      warns.add('TUN 清空系统代理失败：$e');
      return (ok: false, warns: warns);
    }
  }

  /// TUN 巡逻专用：系统代理被任何工具重新启用时返回其地址，否则 null。
  /// 与 [stolenBy] 的区别：不要求 isActive（TUN 让位后本工具没接管系统代理），
  /// 且任何 ProxyEnable=1 都算残留——TUN 生效期间系统代理必须为空，
  /// 否则应用层代理会截走本该进 TUN 的流量。
  static Future<String?> tunResidue() async {
    final r = await Process.run(
        'reg', ['query', _regKey, '/v', 'ProxyEnable'], runInShell: true);
    if (!(r.stdout as String).contains('0x1')) return null;
    final server = await _regQuerySz(_regKey, 'ProxyServer') ?? '';
    return server.isEmpty ? '(已启用，未设地址)' : server;
  }

  /// 代理地址（host:port 形式）是否还有进程在监听。
  ///
  /// 只对「IPv4/主机名:端口」这种无歧义形态真正探活；其余写法——分协议
  /// 多段（http=..;https=..）、带认证串、IPv6 带方括号——解析歧义太大，
  /// 探错对象会把用户**活着的**代理误判成死代理，restore 悄悄改成直连，
  /// 比不验活更糟（2026-10-10 审计）。一律按「活着」处理。
  static Future<bool> _proxyAlive(String server) async {
    final v = server.trim();
    if (RegExp(r'^[A-Za-z0-9._-]+:\d{1,5}$').firstMatch(v) == null) {
      return true;
    }
    final parts = v.split(':');
    final host = parts.first;
    final port = int.parse(parts.last);
    if (port < 1 || port > 65535) return true;
    try {
      final s = await Socket.connect(host, port,
          timeout: const Duration(milliseconds: 800));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 当前系统代理摘要
  static Future<String> summary() async {
    final r = await Process.run(
        'reg', ['query', _regKey, '/v', 'ProxyEnable'], runInShell: true);
    if ((r.stdout as String).contains('0x1')) return '已接管（系统代理已开启）';
    return '未启用';
  }

  /// 本工具接管时写入的代理地址（「127.0.0.1:端口」）。
  static String _ourServer = '';

  /// 运行期被抢占检测：接管期间系统代理若已不再指向本工具，返回抢占者
  /// 写入的地址（如 v2rayN 的 127.0.0.1:10808）；仍在自己手里返回 null。
  ///
  /// v2rayN / Clash 等工具会在自己的生命周期里回写系统代理（哪怕它界面
  /// 上没开「系统代理」），抢占后浏览器流量被引向那个（常常没在服务的）
  /// 端口——用户看到的就是「EchOS 开着却上不了网」。只报告、不自动抢回：
  /// 自动抢回会跟对方工具乒乓互写注册表，越抢越乱；提示用户处理才是解。
  static Future<String?> stolenBy() async {
    if (!isActive || _ourServer.isEmpty) return null;
    final r = await Process.run(
        'reg', ['query', _regKey, '/v', 'ProxyEnable'], runInShell: true);
    if (!(r.stdout as String).contains('0x1')) return null;
    final server = await _regQuerySz(_regKey, 'ProxyServer') ?? '';
    if (server.isEmpty || server == _ourServer) return null;
    return server;
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
    if (tunCleared) {
      // TUN 清空态的注册表不是用户原值：此时重新备份会用「空」覆盖原始备份，
      // 之后 restore 就再也还原不回用户真正的配置了。
      return;
    }
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
      var wasOn = data['enable'] == true;
      final server = data['server'] as String? ?? '';
      final override = data['override'] as String?;
      final autoconfig = data['autoconfig'] as String?;
      // 与 restore() 同一套验活：异常退出自愈时，备份里的代理同样可能
      // 已随其工具退出而变成死端口，照写回就是「开机即断网」。
      if (wasOn && server.isNotEmpty && !await _proxyAlive(server)) {
        wasOn = false;
        warns.add('备份中的系统代理 $server 已无响应（对应工具可能已退出），'
            '本次自愈还原为直连而不是指回死端口');
      }
      await _regSet(_regKey, 'ProxyEnable', wasOn ? 1 : 0);
      if (wasOn) {
        if (server.isNotEmpty) {
          await _regSetSz(_regKey, 'ProxyServer', server);
        } else {
          // enable=1 但 ProxyServer 为空的备份组合：没有可还原的地址，
          // 按关闭处理——凭空捏造 127.0.0.1:1080 之类的默认值等于开机
          // 指向一个从未存在过的端口。
          await _regSet(_regKey, 'ProxyEnable', 0);
          await _regDelete(_regKey, 'ProxyServer');
        }
      } else {
        await _regDelete(_regKey, 'ProxyServer');
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

  /// 广播设置变更让系统立即生效。
  ///
  /// wininet 的 InternetSetOption（SETTINGS_CHANGED + REFRESH）才是 Win8+
  /// 上刷新 WinINET 代理缓存的正道；rundll32 的 UpdatePerUserSystemParameters
  /// 是 XP 时代手法——注册表写了但运行中的浏览器收不到通知，「接管了浏览器
  /// 却不换代理」的偶发报告源于此。两条通知都发。
  static Future<void> _notifySettingChange() async {
    try {
      final wininet = DynamicLibrary.open('wininet.dll');
      final setOption = wininet.lookupFunction<
          Int32 Function(IntPtr, Int32, Pointer<Void>, Int32),
          int Function(int, int, Pointer<Void>, int)>('InternetSetOptionW');
      const internetOptionSettingsChanged = 39;
      const internetOptionRefresh = 37;
      setOption(0, internetOptionSettingsChanged, nullptr, 0);
      setOption(0, internetOptionRefresh, nullptr, 0);
    } catch (_) {}
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
