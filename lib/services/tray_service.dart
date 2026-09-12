// 托盘/菜单栏：镜像 Mac StatusBar。
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app_state.dart';
import 'app_temp.dart';

class TrayService with TrayListener {
  static final TrayService instance = TrayService._();
  TrayService._() {
    trayManager.addListener(this);
  }

  AppState get _app => AppState.instance;

  /// 已写入临时目录的图标路径（蓝=已接管，橙=未接管）
  String? _trayBlueIcon;
  String? _trayOraIcon;

  Future<void> init() async {
    await _writeIcons();
    _lastReady = _app.proxyReady;
    await _applyIcon(_app.proxyReady);
    await trayManager.setToolTip('EchOS');
    _lastDockIcon = _app.config.showDockIcon;
    _applyDockIcon();
    await _rebuildMenu();
    _app.addListener(_onState);
  }

  /// 上次同步给原生的状态，用于跳过无变化的 platform channel 往返。
  /// AppState 的 notifyListeners() 调用点很多（日志、状态、配置…），
  /// 而每次都会走到这里；无条件重发 IPC 会在高频日志下持续占用 UI 线程，
  /// 表现为右键托盘菜单的 hover 药丸不跟手。
  bool? _lastReady;
  bool? _lastDockIcon;

  void _onState() {
    _rebuildMenu(); // 内部自带内容指纹去重，无变化时直接返回
    final ready = _app.proxyReady;
    if (ready != _lastReady) {
      _lastReady = ready;
      _applyIcon(ready);
    }
    // 配置变化时同步任务栏图标可见性（勾选「在任务栏显示图标」后立即生效）
    final dock = _app.config.showDockIcon;
    if (dock != _lastDockIcon) {
      _lastDockIcon = dock;
      _applyDockIcon();
    }
  }

  /// 任务栏图标可见性：用 window_manager 的 setSkipTaskbar 控制任务栏按钮
  /// （tray_manager 的 setDockIconVisible 是 macOS 专用，Windows 上是空操作）。
  void _applyDockIcon() {
    windowManager.setSkipTaskbar(!_app.config.showDockIcon);
  }

  /// 原生托盘菜单点击分发（动作语义与 Mac 版/面板一致）
  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final app = _app;
    switch (menuItem.key) {
      case 'show':
        windowManager.show();
        windowManager.focus();
        break;
      case 'toggle':
        app.toggle();
        break;
      case 'update':
        // 先把主窗口带到前台，更新弹窗才不会被埋在不可见的托盘状态下
        windowManager.show();
        windowManager.focus();
        app.checkEverything();
        break;
      case 'dock':
        app.setShowDockIcon(!app.config.showDockIcon);
        break;
      case 'quit':
        _quit();
        break;
      default:
        final key = menuItem.key ?? '';
        if (key.startsWith('server-')) {
          final i = int.tryParse(key.substring(7));
          if (i != null && i >= 0 && i < app.config.servers.length) {
            app.select(app.config.servers[i].id);
          }
        }
    }
  }

  /// 真正退出：先停代理恢复系统网络（否则系统代理残留），再结束进程。
  /// 窗口的关闭按钮已被拦截为「隐藏到托盘」，destroy 也会走同一条路，
  /// 所以退出进程必须直接 exit。
  Future<void> _quit() async {
    final app = _app;
    if (app.isRunning || app.isStarting) {
      await app.stop();
    }
    exit(0);
  }

  /// 上次 setContextMenu 的内容指纹；内容没变就跳过重建。
  /// 原来每次状态变更都重建原生菜单：若重建恰逢菜单已打开，会清空
  /// 自绘标签表导致「只有底色、无文字」，稍等/重开才恢复。
  String? _menuSig;

  Future<void> _rebuildMenu() async {
    final app = _app;
    // v2rayN 风格：运行状态用行首实心圆点表达（开=有点，关=无点），文案固定
    final running = app.isRunning || app.isStarting;
    final servers = app.config.servers;
    final sig = [
      running,
      app.config.showDockIcon,
      servers.length,
      app.selected?.id,
      ...servers.map((s) => '${s.id}:${s.name}'),
    ].join('|');
    if (sig == _menuSig) return;
    _menuSig = sig;
    final items = <MenuItem>[
      MenuItem(key: 'show', label: '显示应用'),
      MenuItem(type: 'separator'),
      MenuItem(key: 'toggle', label: 'ECH 代理', checked: running),
      MenuItem.submenu(
          key: 'servers',
          label: '代理服务器',
          submenu: Menu(items: [
            for (var i = 0; i < app.config.servers.length; i++)
              MenuItem(
                key: 'server-$i',
                label: app.config.servers[i].name.isEmpty
                    ? '未命名'
                    : app.config.servers[i].name,
                checked: app.selected?.id == app.config.servers[i].id,
              ),
          ])),
      MenuItem(type: 'separator'),
      MenuItem(key: 'update', label: '检查更新'),
      MenuItem(type: 'separator'),
      MenuItem(
          key: 'dock', label: '任务栏显示图标', checked: app.config.showDockIcon),
      MenuItem(key: 'quit', label: '退出应用'),
    ];
    try {
      await trayManager.setContextMenu(Menu(items: items));
    } catch (_) {}
  }

  /// 对齐 Mac 菜单栏：代理已接管（proxyReady）→ 蓝；否则 → 橙。
  Future<void> _applyIcon(bool ready) async {
    if (ready) {
      if (_trayBlueIcon != null) {
        await trayManager.setIcon(_trayBlueIcon!);
      }
    } else {
      if (_trayOraIcon != null) {
        await trayManager.setIcon(_trayOraIcon!);
      }
    }
  }

  @override
  void onTrayIconMouseDown() {
    // 左键单击：显示主窗口（Windows 托盘惯例；菜单留给右键）
    windowManager.show();
    windowManager.focus();
  }

  // 右键托盘：菜单由原生侧在收到 WM_RBUTTONUP 时直接弹出（跟随鼠标位置），
  // 不再经 Dart 往返，因此这里无需覆写 onTrayIconRightMouseDown。

  /// 把打包的托盘图标写为临时文件供托盘显示（蓝=已接管，橙=未接管）
  Future<void> _writeIcons() async {
    final dir = appTempSubDir('echos-tray');

    final blue = File('${dir.path}${Platform.pathSeparator}tray-blue.ico');
    final blueData = await rootBundle.load('assets/tray-blue.ico');
    blue.writeAsBytesSync(blueData.buffer.asUint8List());
    _trayBlueIcon = blue.path;

    final ora = File('${dir.path}${Platform.pathSeparator}tray-ora.ico');
    final oraData = await rootBundle.load('assets/tray-ora.ico');
    ora.writeAsBytesSync(oraData.buffer.asUint8List());
    _trayOraIcon = ora.path;
  }
}
