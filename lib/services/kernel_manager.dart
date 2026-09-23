// 内核管理：镜像 AppState 的 start/stop/端口就绪/冲突处理。
// 用 Process.start 拉起 x-tunnel 子进程，转发 stdout 日志。
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../models/config.dart';
import 'app_paths.dart';
import 'port_tools.dart';

// ---- 内核进程托管到 KILL_ON_JOB_CLOSE 作业对象 ----
// 让 x-tunnel 随主进程「陪葬」：无论主进程以何种方式结束（正常 exit、崩溃、
// 任务管理器强杀、注销），Windows 在本进程全部句柄关闭时自动终止作业内的内核
// 进程。否则会留下「echos 已退、x-tunnel 孤儿残留」锁住安装目标，覆盖安装报
// DeleteFile failed code5。创建后句柄长期持有（进程存活即有效）。
final ffi.DynamicLibrary _kernel32 =
    ffi.DynamicLibrary.open('kernel32.dll');

typedef _CreateJobObjectW = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void> lpJobAttributes, ffi.Pointer<ffi.Uint16> lpName);
typedef _SetInformationJobObjectFn = ffi.Int32 Function(
    ffi.Pointer<ffi.Void> hJob,
    ffi.Int32 jobObjectInformationClass,
    ffi.Pointer<ffi.Void> lpJobObjectInformation,
    ffi.Int32 cbJobObjectInformationLength);
typedef _OpenProcessFn = ffi.Pointer<ffi.Void> Function(
    ffi.Int32 dwDesiredAccess, ffi.Int32 bInheritHandle, ffi.Int32 dwProcessId);
typedef _AssignProcessToJobObjectFn = ffi.Int32 Function(
    ffi.Pointer<ffi.Void> hJob, ffi.Pointer<ffi.Void> hProcess);
typedef _CloseHandleFn = ffi.Int32 Function(ffi.Pointer<ffi.Void> hObject);

const int _jobObjectExtendedLimitInformation = 9;
const int _jobObjectLimitKillOnJobClose = 0x2000;
const int _processDesiredAccess = 0x0101; // PROCESS_SET_QUOTA | PROCESS_TERMINATE

ffi.Pointer<ffi.Void>? _jobHandle;

/// 惰性、幂等地创建带 KILL_ON_JOB_CLOSE 的作业对象（仅 Windows；失败无碍）。
/// JOBOBJECT_EXTENDED_LIMIT_INFORMATION 在 x64 下 LimitFlags 位于字节偏移 16
/// （两个 64 位时间限制在前），块清零后只写该 DWORD，缓冲取 160B ≥ 结构全长。
void _ensureKernelJobObject() {
  if (_jobHandle != null) return;
  try {
    final createJob = _kernel32.lookupFunction<_CreateJobObjectW,
        ffi.Pointer<ffi.Void> Function(
            ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint16>)>(
        'CreateJobObjectW');
    final name = 'Local\\EchOS_Kernel_Job'.toNativeUtf16().cast<ffi.Uint16>();
    final job = createJob(ffi.nullptr, name);
    if (job == ffi.nullptr) return;
    final setInfo = _kernel32.lookupFunction<_SetInformationJobObjectFn,
        int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Void>, int)>(
        'SetInformationJobObject');
    final buffer = calloc<ffi.Uint8>(160);
    try {
      (buffer.cast<ffi.Uint32>() + 4).value = _jobObjectLimitKillOnJobClose;
      if (setInfo(
              job, _jobObjectExtendedLimitInformation, buffer.cast(), 160) !=
          0) {
        _jobHandle = job;
      }
    } finally {
      calloc.free(buffer);
    }
  } catch (_) {}
}

/// 把已启动的内核进程挂进作业对象（失败静默：最坏退回现状，不影响运行）。
void _assignKernelToJob(int pid) {
  final job = _jobHandle;
  if (job == null) return;
  try {
    final openProcess = _kernel32.lookupFunction<_OpenProcessFn,
        ffi.Pointer<ffi.Void> Function(int, int, int)>('OpenProcess');
    final assign = _kernel32.lookupFunction<_AssignProcessToJobObjectFn,
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)>(
        'AssignProcessToJobObject');
    final closeHandle = _kernel32.lookupFunction<_CloseHandleFn,
        int Function(ffi.Pointer<ffi.Void>)>('CloseHandle');
    final h =
        openProcess(_processDesiredAccess, 0, pid);
    if (h != ffi.nullptr) {
      assign(job, h);
      closeHandle(h);
    }
  } catch (_) {}
}

class KernelManager {
  static final KernelManager instance = KernelManager._();
  KernelManager._();

  // kernel.log 的上限，超过就轮转成 kernel.prev.log（只留一份）。
  // 这个文件的写入量远大于其他日志：内核 stdout/stderr 每一行都落盘，且不受
  // 「日志级别」设置控制（级别只能关掉界面日志）。实测播放视频时约 480 KB/h，
  // 1MB 撑不到 3 小时就轮转一次，排障时历史早被冲掉了。4MB 可覆盖高峰约 8 小时、
  // 日常使用约一天，加上 prev 一份共约 8MB，单文件用记事本打开也不卡。
  static const int kernelLogMaxBytes = 4 * 1024 * 1024; // 4MB

  Process? _process;
  bool _processAlive = false;
  bool isRunning = false;
  bool isStarting = false;
  ({String host, int port})? activeSocks;
  ({String host, int port})? activeHTTP;

  String? kernelPath() {
    // 打包后与可执行文件同目录的 x-tunnel.exe。
    const exe = 'x-tunnel.exe';
    final candidates = <String>[];
    final resolved = Platform.resolvedExecutable;
    final dir = File(resolved).parent.path;
    candidates.add('$dir${Platform.pathSeparator}$exe');
    candidates.add('${Directory.current.path}${Platform.pathSeparator}$exe');
    for (final c in candidates) {
      final f = File(c);
      if (f.existsSync()) return f.path;
    }
    return null;
  }

  /// 内核程序所在目录（打包后 = echos.exe 同目录）。找不到内核返回 null。
  String? kernelDir() {
    final p = kernelPath();
    return p == null ? null : File(p).parent.path;
  }

  /// TUN 模式的硬依赖：wintun.dll 必须和内核同目录。
  ///
  /// 内核用 `LoadLibraryEx("wintun.dll", …, LOAD_LIBRARY_SEARCH_APPLICATION_DIR
  /// | LOAD_LIBRARY_SEARCH_SYSTEM32)` 加载它，只认「程序目录」和 System32；
  /// 放别处等于没有。所以这里也按同一个口径检查。
  bool wintunDllPresent() {
    final dir = kernelDir();
    if (dir == null) return false;
    return File('$dir${Platform.pathSeparator}wintun.dll').existsSync();
  }

  /// 启动内核；返回错误提示（空=成功启动流程）
  ///
  /// [tun] = true 时以 TUN 模式启动（追加 `-tun`）。调用方负责先确认管理员
  /// 权限与 wintun.dll —— 这两条内核自己只会报一句加载失败，说不清原因。
  Future<String?> start(ServerConfig cfg, RouteMode mode,
      {required void Function(String line) log,
      List<CustomRule>? rules,
      bool tun = false,
      void Function(int code)? onExit}) async {
    if (isRunning || isStarting) return null;

    final path = kernelPath();
    if (path == null) return '找不到内核程序，请确认 App 完整';

    // 端口预检
    final socks = ServerConfig.socksEndpoint(cfg.expandedListen);
    final http = ServerConfig.httpEndpoint(cfg.expandedListen);
    for (final ep in [
      ('SOCKS5', socks),
      ('HTTP', http),
    ]) {
      if (ep.$2 == null) continue;
      var free = await PortTools.isFree(ep.$2!.port);
      for (var i = 0; i < 10 && !free; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        free = await PortTools.isFree(ep.$2!.port);
      }
      if (!free) {
        final occ = await PortTools.occupant(ep.$2!.port);
        if (occ != null) {
          log('[系统] ${ep.$1} 端口 ${ep.$2!.port} 被 ${occ.label} 占用，等待用户确认…');
          pendingConflict = PortConflict(
              label: ep.$1, port: ep.$2!.port, name: occ.name, pid: occ.pid);
          return null;
        }
        log('[系统] ${ep.$1} 端口 ${ep.$2!.port} 预检查未通过，但没有进程在监听，继续启动');
      }
    }

    activeSocks = socks;
    activeHTTP = http;

    // 分流数据
    var geoip = AppPaths.geoipPath ?? AppPaths.builtinGeoipPath();
    var geosite = AppPaths.geositePath ?? AppPaths.builtinGeositePath();
    if (mode.needsGeoData && (geoip == null || geosite == null)) {
      return 'App 内缺少分流数据文件（geoip.dat / geosite.dat），请改用「全局代理」模式或重新安装完整版本';
    }

    final args = cfg.arguments(
        listen: null,
        geoip: geoip,
        geosite: geosite,
        mode: mode,
        rules: rules,
        tun: tun);

    isStarting = true;
    log('[系统] 正在启动内核进程…');
    if (tun) {
      log('[系统] TUN 模式：内核将创建虚拟网卡接管全部流量（不再设置系统代理）');
    }
    try {
      final proc = await Process.start(path, args,
          mode: ProcessStartMode.normal,
          environment: Platform.environment);
      // 挂进 KILL_ON_JOB_CLOSE 作业：主进程无论怎么死，内核都跟着终止。
      _ensureKernelJobObject();
      _assignKernelToJob(proc.pid);
      _process = proc;
      _processAlive = true;
      proc.stdout.transform(utf8.decoder).transform(LineSplitter()).listen(
          (l) {
        _remember(l);
        _persist(l);
        log(l);
      }, onError: (_) {});
      proc.stderr.transform(utf8.decoder).transform(LineSplitter()).listen(
          (l) {
        _remember(l);
        _persist(l);
        log(l);
      }, onError: (_) {});
      proc.exitCode.then((code) {
        _onExit(proc, code, cfg, log);
        onExit?.call(code);
      });
    } catch (e) {
      isStarting = false;
      _process = null;
      return '启动内核失败：$e';
    }

    log('[系统] 内核进程已启动');
    if (activeSocks != null) {
      log('[系统] 本地端口 SOCKS5 ${activeSocks!.host}:${activeSocks!.port}');
    }
    log('[系统] 正在等待代理端口就绪…');
    await _waitPortsReady(log, tun: tun);
    return null;
  }

  Future<void> _waitPortsReady(void Function(String) log,
      {bool tun = false}) async {
    if (activeSocks == null) {
      isStarting = false;
      return;
    }
    final port = activeSocks!.port;
    // 25 次×1s：境外 DoH/UDP DNS 时通时不通，ECH+通道建立可能超过 10s，
    // 只要进程还活着且正在推进，就多等一会，别把"慢但能成"的启动杀掉。
    //
    // ★ 与内核的 ECH 启动预算**耦合**（x-tunnel.go 的 echStartupBudget = 12s）：
    //   内核取 ECH 公钥最多花「预算 + 单次查询上限 4s」≈ 16s，之后才开始监听
    //   端口。这里的等待必须明显大于它，否则内核还在重试、这边已经判「内核可能
    //   启动失败」把进程杀掉 —— 内核那条「取不到 ECH 就降级为普通 TLS 1.3」的
    //   兜底就永远走不到，用户看到的就是「内核起不来」而不是「ECH 降级了」。
    //   改任何一边都要同步核对另一边。
    //
    // TUN 模式要等更久：内核刻意**先等 smux 通道就绪（最长 60 秒）再建 TUN**，
    // 因为一旦路由把全部流量劫持进去、通道却不可用，就是彻底断网。这段时间
    // 本地监听也还没起来（内核把它们的启动放在 StartTun 之前、通道就绪之后），
    // 所以按非 TUN 的 20 秒口径会把「正常但慢」的 TUN 启动误判成失败。
    // （ECH 预算 ≈16s + 通道最长 60s = 76s，90s 仍有余量。）
    final maxAttempts = tun ? 90 : 25;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (!isStarting || !_processAlive) {
        isStarting = false;
        return;
      }
      if (!await PortTools.isFree(port)) {
        isRunning = true;
        isStarting = false;
        log('[系统] 代理端口已就绪');
        return;
      }
      log('[系统] 代理端口尚未就绪，1 秒后重试（第 $attempt 次）…');
      await Future.delayed(const Duration(seconds: 1));
    }
    // 未就绪
    isStarting = false;
    log('[系统] 代理端口未就绪，内核可能启动失败，正在清理残留内核进程…');
    await stop();
  }

  Future<void> _onExit(
      Process p, int code, ServerConfig cfg, void Function(String) log) async {
    try {
      await p.exitCode;
    } catch (_) {}
    // 退出回调可能来自已被替换的旧进程（stop→start 竞态）：旧进程 exit 晚到，
    // 此时 _process 已指向新进程。只有退出的是当前进程才清理状态，否则忽略，
    // 避免把新启动的内核误判成失败。
    final isCurrent = identical(p, _process);
    if (isCurrent) {
      isRunning = false;
      isStarting = false;
      _processAlive = false;
      _process = null;
    }
    log('[系统] 内核已退出（状态码 $code）');
    if (isCurrent && code != 0) {
      // 端口占用检测
      if (activeSocks != null) {
        final o = await PortTools.occupant(activeSocks!.port);
        if (o != null) {
          log('[系统] 端口 ${activeSocks!.port} 被 ${o.label} 占用，等待用户确认…');
          pendingConflict = PortConflict(
              label: 'SOCKS5',
              port: activeSocks!.port,
              name: o.name,
              pid: o.pid);
        } else {
          log('[系统] 启动失败，请查看运行日志');
        }
      }
    }
  }

  Future<void> stop() async {
    isStarting = false;
    _processAlive = false;
    final p = _process;
    _process = null;
    if (p != null) {
      // 先走「关闭 stdin」的优雅路径，再兜底强杀。
      //
      // 为什么不能直接 kill：Windows 上 Process.kill 就是 TerminateProcess，
      // 进程内收不到任何通知。非 TUN 模式下无非是 socket 被系统收走，无所谓；
      // **TUN 模式下会留下 Wintun 虚拟网卡和它设的路由/DNS**，轻则网卡列表里
      // 多一个「xtun」，重则路由还指着已死的网卡。内核读到 stdin EOF 会先
      // 关闭 TUN 网卡再 exit(0)，所以这一步不能省。
      //
      // 旧内核（不认识 stdin EOF）在这里会白等满 3 秒才被强杀 —— 可接受：
      // 应用与内核同包发布，不存在长期错配。
      try {
        await p.stdin.close();
      } catch (_) {}
      var exited = await p.exitCode
          .timeout(const Duration(seconds: 3), onTimeout: () => -1);
      if (exited < 0) {
        try {
          p.kill(ProcessSignal.sigterm);
        } catch (_) {}
        exited = await p.exitCode
            .timeout(const Duration(seconds: 3), onTimeout: () => -1);
      }
      // 仍不退则强杀
      if (exited < 0) {
        try {
          p.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
    }
    isRunning = false;
    // 等端口真正释放再返回（对齐 Mac stop）：进程退出和内核放开监听端口
    // 之间还有延迟，紧接着的 start() 会撞上尚未释放的端口。SOCKS+HTTP 都要等。
    final pendingPorts = [activeSocks?.port ?? 0, activeHTTP?.port ?? 0]
        .where((p) => p > 0)
        .toSet();
    for (final port in pendingPorts) {
      for (var i = 0; i < 40; i++) {
        if (await PortTools.isFree(port)) break;
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
    activeSocks = null;
    activeHTTP = null;
  }

  /// 清理残留内核进程（对齐 Mac killLeftover）：
  /// 1) 找出所有 x-tunnel.exe；2) 核对可执行路径确实来自内核所在目录，防 PID 复用误杀。
  Future<void> killLeftovers() async {
    try {
      const names = 'x-tunnel.exe';
      final path = kernelPath();
      final baseDir = path != null ? File(path).parent.path : null;
      final r = await Process.run(
          'tasklist', ['/FI', 'IMAGENAME eq $names', '/FO', 'CSV'],
          runInShell: true);
      // CSV 格式："PID","计数","内存"…逐行解析，归属校验交给 PID→路径查询
      final lines = (r.stdout as String)
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      for (final line in lines.skip(1)) {
        // CSV: "image","pid","session",... 直接按逗号拆，剥掉引号
        final cols = line.split(',');
        if (cols.length < 2) continue;
        final pid = cols[1].replaceAll('"', '').trim();
        final n = int.tryParse(pid);
        if (n == null) continue;
        // 用 wmic 取得可执行路径，核对来自内核目录（防误杀同名单进程）
        if (baseDir != null) {
          final w = await Process.run(
              'wmic',
              ['process', 'where', 'ProcessId=$n', 'get', 'ExecutablePath'],
              runInShell: true);
          final wPath = (w.stdout as String)
              .split('\n')
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty && !l.toUpperCase().contains('PATH'))
              .firstOrNull;
          if (wPath == null ||
              !wPath
                  .replaceAll('/', '\\')
                  .toLowerCase()
                  .startsWith(baseDir.replaceAll('/', '\\').toLowerCase())) {
            continue;
          }
        }
        // 终止残留
        await Process.run('taskkill', ['/F', '/PID', '$n'], runInShell: true);
      }
    } catch (_) {}
  }

  PortConflict? pendingConflict;

  // ---- 失败归因（对齐 Mac serverFailureHint）：记住最近 30 行内核日志 ----
  final List<String> _lastLines = [];

  void _remember(String l) {
    _lastLines.add(l);
    if (_lastLines.length > 30) _lastLines.removeAt(0);
  }

  /// 把内核日志落盘到 logs/kernel.log（超过 kernelLogMaxBytes 轮转到
  /// kernel.prev.log），便于事后诊断隧道/通道问题。
  void _persist(String l) {
    try {
      final dir = Directory(
          '${AppPaths.appDataDir.path}${Platform.pathSeparator}logs');
      dir.createSync(recursive: true);
      final f = File('${dir.path}${Platform.pathSeparator}kernel.log');
      if (f.existsSync() && f.lengthSync() > kernelLogMaxBytes) {
        final prev = File('${dir.path}${Platform.pathSeparator}kernel.prev.log');
        if (prev.existsSync()) prev.deleteSync();
        f.renameSync(prev.path);
      }
      final raf = f.openSync(mode: FileMode.append);
      try {
        raf.writeStringSync('$l\n');
      } finally {
        raf.closeSync();
      }
    } catch (_) {}
  }

  /// 从最近的内核日志里识别「服务器侧」的失败原因，返回给用户看的简短说明。
  /// 识别不出来返回 null（本地原因走通用提示）。
  String? serverFailureHint() {
    final hints = _lastLines.join('\n').toLowerCase();
    if (hints.contains('认证失败') ||
        hints.contains('token 不匹配') ||
        hints.contains('unauthorized') ||
        hints.contains('401')) {
      return 'TOKEN 与服务器端不一致';
    }
    if (hints.contains('no such host') ||
        hints.contains('lookup') ||
        hints.contains('找不到主机')) {
      final m = RegExp(r'\(IP:[^)]*\)').firstMatch(hints);
      if (m != null) {
        final label = m.group(0)!;
        return label.contains('自动解析')
            ? '服务地址解析失败，请检查「服务地址」'
            : '优选IP/域名解析失败，请检查「优选IP/域名」';
      }
      return '服务器连接失败';
    }
    if (hints.contains('connection refused') ||
        hints.contains('i/o timeout') ||
        hints.contains('deadline exceeded') ||
        hints.contains('timed out') ||
        hints.contains('bad handshake') ||
        hints.contains('handshake failure') ||
        hints.contains('handshake 失败') ||
        hints.contains('reset by peer')) {
      return '服务器连接失败';
    }
    return null;
  }
}

class PortConflict {
  final String label;
  final int port;
  final String name;
  final int pid;
  const PortConflict(
      {required this.label,
      required this.port,
      required this.name,
      required this.pid});
}
