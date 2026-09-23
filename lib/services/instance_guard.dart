// 单实例守卫：锁文件 + 「二次启动唤起主窗口」的本地 IPC 端口。
//
// 原先这段逻辑直接写在 main.dart 里。抽出来的唯一原因是「以管理员身份重启」：
// 提权重启是「旧实例让位 → 新实例接管」的交接，旧实例必须先放开锁和端口，
// 否则新实例会看到旧锁、去唤起旧实例、然后自己退出 —— 表现就是
// 「点了开关，窗口闪一下，什么都没发生」。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_paths.dart';

/// 二次启动唤起的 IPC 端口（仅回环，防火墙不感知）。
const int _defaultIpcPort = 45871;

/// 实际使用的端口。可用环境变量 `ECHOS_IPC_PORT` 覆盖。
///
/// 留这个逃生阀有两个实际用途：
///   1. 自动化测试 —— 本机常驻着一个真实实例时，它会一直占着 45871，
///      测试实例 `bind` 会失败（下面刻意吞掉该异常），于是「connect 成功」
///      会被误判成本实例的监听生效，测出来全是假阳性；
///   2. 真实端口冲突 —— 45871 被别的程序占用时，用户有办法绕开。
int get _ipcPort {
  final raw = Platform.environment['ECHOS_IPC_PORT'];
  final v = raw == null ? null : int.tryParse(raw.trim());
  return (v != null && v > 0 && v < 65536) ? v : _defaultIpcPort;
}

class InstanceGuard {
  static ServerSocket? _wakeServer;

  /// 唤起主窗口的动作。由 main.dart 注入（这里不依赖 window_manager），
  /// 提权失败回滚时也要用它把监听重新拉起来。
  static Future<void> Function()? _onShow;

  static File _lockFile() => File(
      '${AppPaths.appDataDir.path}${Platform.pathSeparator}instance.lock');

  /// 已有实例在跑时：让它把主窗口带到前台，本进程随后退出。
  /// 返回 true 表示「本实例应退出」。
  ///
  /// 判据必须是「锁里的 PID 确实属于本程序」，不能只看 PID 存活着：
  /// **PID 会被系统复用**。旧实现只调 tasklist 按 PID 过滤，锁里残留的旧 PID
  /// 一旦被别的进程占用（实测撞上 msedge.exe），就会被误判成「已有实例在跑」，
  /// 于是唤起失败也照样退出 —— 表现为「双击图标完全没反应，应用起不来」，
  /// 且会一直持续到 PID 再次变化。现在核对映像名，不匹配就接管锁。
  static Future<bool> claimOrWake() async {
    try {
      final dir = Directory(AppPaths.appDataDir.path)
        ..createSync(recursive: true);
      final lock = File(
          '${dir.path}${Platform.pathSeparator}instance.lock');
      if (lock.existsSync()) {
        final ownerPid = int.tryParse(lock.readAsStringSync().trim());
        // ownerPid == pid 只在极端复用下出现，一并排除避免自己把自己挡住。
        if (ownerPid != null && ownerPid != pid && _isOwnProcess(ownerPid)) {
          await _tryWake();
          return true;
        }
      }
      // 无锁 / 解析失败 / 该 PID 不是本程序 → 视为陈旧锁，接管
      lock.writeAsStringSync('$pid');
    } catch (_) {
      // 锁文件异常不影响启动
    }
    return false;
  }

  /// 连接运行中的实例，请求显示主窗口；成功返回 true。
  static Future<bool> _tryWake() async {
    try {
      final socket = await Socket.connect('127.0.0.1', _ipcPort,
          timeout: const Duration(milliseconds: 1500));
      socket.add(utf8.encode('show'));
      await socket.flush();
      await socket.first; // 等旧实例应答，确保窗口已拉起再退
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 首个实例常驻监听：新实例唤起 → 显示主窗口并聚焦。
  /// [onShow] 由 main.dart 注入（避免这里依赖 window_manager）。
  static Future<void> startWakeListener(
      Future<void> Function() onShow) async {
    _onShow = onShow;
    await _bindWakeServer();
  }

  static Future<void> _bindWakeServer() async {
    final onShow = _onShow;
    if (onShow == null || _wakeServer != null) return;
    try {
      final server = await ServerSocket.bind('127.0.0.1', _ipcPort);
      _wakeServer = server;
      server.listen((socket) async {
        try {
          await socket.first;
          await onShow();
          socket.write('ok');
          await socket.flush();
        } catch (_) {}
        socket.destroy();
      });
    } catch (_) {
      // 端口被其他程序占用时仅影响「二次启动唤起」，应用功能不受影响
    }
  }

  /// 提权重启前的让位：关掉 IPC 端口、删掉锁文件。
  ///
  /// 顺序很重要 —— **必须在 ShellExecuteW 之前做完**。新（提升的）实例是同步
  /// 起来的，若那时锁文件还在且旧 PID 仍存活，新实例会走进「唤起旧实例」分支
  /// 并自我退出；旧实例随后也退出，于是两个都没了。
  static Future<void> releaseForRelaunch() async {
    try {
      await _wakeServer?.close();
    } catch (_) {}
    _wakeServer = null;
    try {
      final f = _lockFile();
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// UAC 被取消 / 提权失败时回滚 [releaseForRelaunch]，让本实例继续正常当主人。
  static Future<void> restoreAfterFailedRelaunch() async {
    try {
      _lockFile().writeAsStringSync('$pid');
    } catch (_) {}
    await _bindWakeServer();
  }

  /// 判断 pid 对应的进程是不是本程序的可执行文件。
  ///
  /// tasklist 的 `/fi "PID eq N"` 只按 PID 过滤，不告诉你是哪个程序；
  /// 必须再用 `/fo csv` 取映像名比对，否则 PID 复用会让陈旧锁把应用锁死。
  static bool _isOwnProcess(int p) {
    try {
      final selfName = Platform.resolvedExecutable
          .split(Platform.pathSeparator)
          .last
          .toLowerCase();
      if (selfName.isEmpty) return false;
      final r = Process.runSync(
          'tasklist', ['/fi', 'PID eq $p', '/fo', 'csv', '/nh']);
      return r.stdout.toString().toLowerCase().contains(selfName);
    } catch (_) {
      return false;
    }
  }
}
