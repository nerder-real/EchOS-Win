import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'services/app_paths.dart';
import 'services/app_state.dart';
import 'services/kernel_manager.dart';
import 'services/system_proxy.dart';
import 'services/tray_service.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

/// 点右上角关闭 → 隐藏到托盘（进程继续），真正退出走托盘「退出应用」。
class _HideOnClose with WindowListener {
  @override
  void onWindowClose() {
    windowManager.hide();
  }
}

/// 强制居中：窗口尺寸变化后始终回到屏幕中央（最大化时不处理）。
class _KeepCentered with WindowListener {
  @override
  void onWindowResized() async {
    if (!(await windowManager.isMaximized())) {
      await windowManager.center();
    }
  }
}

/// 单实例锁 + 二次启动唤起的 IPC 端口（仅回环，防火墙不感知）。
/// 首次运行：监听该端口；此后双击桌面图标/再运行启动程序，
/// 新实例发现已有存活进程 → 连上端口让旧实例 show()+focus() 主窗口，然后自己退出。
const int _ipcPort = 45871;

/// 已有实例在跑时：让它把主窗口带到前台，本进程随后退出。
/// 返回 true 表示「本实例应退出」。
///
/// 判据必须是「锁里的 PID 确实属于本程序」，不能只看 PID 存活着：
/// **PID 会被系统复用**。旧实现只调 tasklist 按 PID 过滤，锁里残留的旧 PID
/// 一旦被别的进程占用（实测撞上 msedge.exe），就会被误判成「已有实例在跑」，
/// 于是唤起失败也照样退出 —— 表现为「双击图标完全没反应，应用起不来」，
/// 且会一直持续到 PID 再次变化。现在核对映像名，不匹配就接管锁。
Future<bool> _wakeExistingInstance() async {
  try {
    final dir = Directory(AppPaths.appDataDir.path)
      ..createSync(recursive: true);
    final lock = File('${dir.path}${Platform.pathSeparator}instance.lock');
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
Future<bool> _tryWake() async {
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
Future<void> _listenForWake() async {
  try {
    final server = await ServerSocket.bind('127.0.0.1', _ipcPort);
    server.listen((socket) async {
      try {
        await socket.first;
        await windowManager.show();
        await windowManager.focus();
        socket.write('ok');
        await socket.flush();
      } catch (_) {}
      socket.destroy();
    });
  } catch (_) {
    // 端口被其他程序占用时仅影响「二次启动唤起」，应用功能不受影响
  }
}

/// 判断 pid 对应的进程是不是本程序的可执行文件。
///
/// tasklist 的 `/fi "PID eq N"` 只按 PID 过滤，不告诉你是哪个程序；
/// 必须再用 `/fo csv` 取映像名比对，否则 PID 复用会让陈旧锁把应用锁死。
bool _isOwnProcess(int p) {
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


/// 监听安装器授权标记，收到后自动退出应用。
///
/// 使用 `File.watch`（底层 ReadDirectoryChangesW）完全异步，不阻塞 UI isolate；
/// 对比原 `Timer.periodic(500ms)` + `Process.runSync('tasklist')` 方案，
/// 彻底消除了每半秒 10-40ms 的 UI 卡顿。
///
/// 监听范围：%TEMP% 目录。安装器向导页勾选「自动退出」或静默安装时写入
/// `EchOS_Install_Go.marker`，本函数探测到即触发退出流程。
StreamSubscription? _installWatchSub;

void _watchForInstaller() {
  _installWatchSub?.cancel();
  final tempDir = Directory(Directory.systemTemp.path);
  // Windows 下 File.watch 监听的是目录级事件，过滤出目标文件名即可。
  _installWatchSub = tempDir.watch().listen((event) async {
    if (event is FileSystemCreateEvent ||
        event is FileSystemModifyEvent) {
      final name = event.path.split(Platform.pathSeparator).last;
      if (name == 'EchOS_Install_Go.marker') {
        _installWatchSub?.cancel();
        _installWatchSub = null;
        await _closeForInstall();
      }
    }
  }, onError: (_) {
    // 监听失败（如目录权限问题）静默放弃，不影响应用正常运行。
    _installWatchSub = null;
  });
}

/// 收到安装器授权后执行安全退出。
/// 收尾顺序：
///   1) 接管过系统代理 → shutdown() 还原；否则把「退出时在运行」状态落盘，
///      下次启动 restoreProxyIfNeeded 自动续接。绝不能让死内核挂着死代理。
///   2) 若磁盘上留有更早实例异常退出的代理接管备份 → restoreFromDisk() 一并还原。
///   3) x-tunnel.exe 是独立进程，直接 exit 不会带走它；安装器替换该文件会报
///      access denied / code 5，故先路径校验清理，仍有残留则按镜像名兜底强杀。
Future<void> _closeForInstall() async {
  try {
    final app = AppState.instance;
    if (app.isRunning || app.isStarting) {
      // shutdown() 已含完整收尾：还原系统代理 → 停内核 → 记录「退出时在
      // 运行」供下次启动自动恢复 → persist() → 关日志。绝不能让死内核
      // 挂着死代理。
      await app.shutdown();
    } else {
      // 未运行：仅清理上次异常退出可能残留的接管备份。必须用默认的
      // clear:true —— 还原后删除备份，否则下次启动 recoverFromUncleanExit()
      // 会再次发现备份、重复还原，并误报「检测到上次异常退出」。
      await SystemProxy.restoreFromDisk();
      app.persist();
    }
  } catch (_) {}
  try {
    // 兜底：无论是否成功接管过代理，都尝试清理一次残留内核。
    await KernelManager.instance.killLeftovers();
  } catch (_) {}
  exit(0);
}

/// 安装互斥体：应用存活期间持有 Local\EchOS_App_Install，安装器「正在运行的
/// 应用」页据此判定本次是否需要自动退出（CheckForMutexes 探测到才显示该页）。
/// 句柄长期持有即进程存活期间生效；win32 包未收录 CreateMutexW，用
/// dart:ffi + package:ffi 绑定，句柄不显式关闭即长期存活。
final ffi.DynamicLibrary _kernel32 = ffi.DynamicLibrary.open('kernel32.dll');

void _acquireInstallMutex() {
  try {
    final createMutexW = _kernel32.lookupFunction<
        ffi.Pointer<ffi.Void> Function(
            ffi.Pointer<ffi.NativeType> lpAttr,
            ffi.Int32 bInitialOwner,
            ffi.Pointer<ffi.Uint16> lpName),
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.NativeType> lpAttr,
            int bInitialOwner, ffi.Pointer<ffi.Uint16> lpName)>(
        'CreateMutexW');
    final name = 'Local\\EchOS_App_Install'.toNativeUtf16().cast<ffi.Uint16>();
    createMutexW(ffi.nullptr, 0, name);
  } catch (_) {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 已有实例：唤起其窗口后必须显式退出进程（Flutter 桌面端 main() return 不结束进程）
  if (await _wakeExistingInstance()) exit(0);
  _acquireInstallMutex(); // Inno AppMutex 探测用，仅首次存活实例持有
  _watchForInstaller();   // 监听安装器授权标记，收到后自动安全退出
  await windowManager.ensureInitialized();
  _listenForWake(); // fire-and-forget：此后双击图标/再启动即唤起主窗口
  const opts = WindowOptions(
    size: Size(796, 900),
    minimumSize: Size(796, 400),
    center: true,
  );
  windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.show();
    await windowManager.focus();
    // 标题栏无文字（任务栏悬停名来自 exe 资源 + 开始菜单快捷方式）
    await windowManager.setTitle('');
    // 恢复系统默认：可最小化/最大化（各平台原生标题栏按钮）
    await windowManager.setMinimizable(true);
    await windowManager.setMaximizable(true);
    await windowManager.setClosable(true);
    // 允许程序调整窗口大小
    await windowManager.setResizable(true);
    // 关闭按钮不再退出进程：拦截后隐藏到托盘
    windowManager.addListener(_HideOnClose());
    await windowManager.setPreventClose(true);
    // 强制居中：任何尺寸变化都回到屏幕中央
    windowManager.addListener(_KeepCentered());
  });
  await TrayService.instance.init();
  AppState.instance.persist();
  // 对齐 Mac onAppear：崩溃自愈 + 上次退出前代理状态自动恢复
  SystemProxy.initBackupDir(AppPaths.appDataDir.path);
  AppState.instance.recoverFromUncleanExit();
  AppState.instance.restoreProxyIfNeeded();
  // 对齐 Mac：启动 3 秒后静默检查更新（App 版本 + 分流数据）
  Future.delayed(const Duration(seconds: 3), () {
    AppState.instance.checkEverything(silent: true);
  });
  runApp(const EchOSApp());
}


class EchOSApp extends StatefulWidget {
  const EchOSApp({super.key});

  @override
  State<EchOSApp> createState() => _EchOSAppState();
}

class _EchOSAppState extends State<EchOSApp> with WidgetsBindingObserver {
  // 显式记录当前亮度，替代 ThemeMode.system：Windows 桌面端在系统明暗来回
  // 切换时 platformBrightness 偶尔不主动通知重建，导致残留旧的深/浅色。
  // 这里监听 didChangePlatformBrightness 强制 setState，切换即刷新。
  Brightness _brightness =
      WidgetsBinding.instance.platformDispatcher.platformBrightness;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    final b = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    if (b != _brightness) {
      setState(() => _brightness = b);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EchOS',
      debugShowCheckedModeBanner: false,
      theme: EchTheme.light(),
      darkTheme: EchTheme.dark(),
      themeMode: _brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      home: const HomePage(),
    );
  }
}
