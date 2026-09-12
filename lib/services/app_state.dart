// AppState：镜像 Mac AppState.swift 的状态机。
import 'dart:async';
import 'dart:io'
    show Directory, File, Platform, Process, ProcessStartMode, exit, pid;

import 'package:flutter/foundation.dart';

import '../models/config.dart';
import 'config_store.dart';
import 'kernel_manager.dart';
import 'log_service.dart';
import 'network_probe.dart';
import 'platform_drivers.dart';
import 'port_tools.dart';
import 'self_check.dart';
import 'system_proxy.dart';
import 'app_version.dart';
import 'updater.dart';

enum CheckStateKind { idle, running, ok, failed }

class CheckState {
  final CheckStateKind kind;
  final String detail; // ok/failed 时的摘要
  const CheckState.idle()
      : kind = CheckStateKind.idle,
        detail = '';
  const CheckState.running()
      : kind = CheckStateKind.running,
        detail = '';
  const CheckState.ok(this.detail) : kind = CheckStateKind.ok;
  const CheckState.failed(this.detail) : kind = CheckStateKind.failed;
}

class PortConflict {
  final String label;
  final int port;
  final String name;
  final int pid;
  const PortConflict({
    required this.label,
    required this.port,
    required this.name,
    required this.pid,
  });
}

class AppState extends ChangeNotifier {
  static final AppState instance = AppState._();
  AppState._() {
    config = ConfigStore.instance.load();
    // 已保存副本：从磁盘配置初始化（磁盘上的都是已保存的）
    for (final s in config.servers) {
      _saved[s.id] = ServerConfig.fromJson(s.toJson());
    }
    LogService.instance.startNewSession();
  }

  AppConfig config = AppConfig();
  final Map<String, ServerConfig> _saved = {};

  bool isRunning = false;
  bool isStarting = false;
  CheckState checkState = const CheckState.idle();
  bool checking = false;
  bool proxyTakenOver = false;
  bool proxyReady = false;
  // 仅对「启动/切换后自动跑的那次自检」置位：隧道探针失败即视为启动失败，关闭代理。
  // 手动自检/预检不带动这开关，保持和 Mac 一致（不打扰已正在跑的代理）。
  bool _autoStartCheckCloses = false;
  String systemProxySummary = '';
  String statusText = '已停止';
  bool needsNameInput = false;
  bool rulesDirty = false;
  bool webdavBusy = false;
  String updateStatus = '';
  String geoStatus = '';
  PortConflict? pendingPortConflict;
  String? alertTitle;
  String? alertMessage;

  // ---- 更新（镜像 Mac updateInfo / updateStatus / downloadProgress）----

  /// 发现的新版本（有值 → home_page 弹「下载并更新」确认框）。
  ReleaseInfo? pendingUpdate;

  /// 最近一次发现的新版本信息。
  ReleaseInfo? updateInfo;

  /// 正在下载更新包（显示进度面板）。
  bool isDownloadingUpdate = false;
  bool _cancelDownload = false;
  double updateProgress = 0;
  String get currentAppVersion => _currentAppVersion;

  // ---- 选中/脏标记 ----

  ServerConfig? get selected {
    final id = config.selectedID;
    if (id != null) {
      for (final s in config.servers) {
        if (s.id == id) return s;
      }
    }
    return config.servers.isEmpty ? null : config.servers.first;
  }

  int get selectedIndex =>
      config.servers.indexWhere((s) => s.id == selected?.id);

  bool get hasUncommittedServer =>
      config.servers.any((s) => !_saved.containsKey(s.id));

  bool isServerSaved(String id) => _saved.containsKey(id);

  void markSaved(String id, ServerConfig s) {
    _saved[id] = ServerConfig.fromJson(s.toJson());
    notifyListeners();
  }

  bool isServerDirty(String id) {
    for (final s in config.servers) {
      if (s.id == id) {
        final saved = _saved[id];
        return saved != null && !_equal(s, saved);
      }
    }
    return false;
  }

  static bool _equal(ServerConfig a, ServerConfig b) {
    return a.id == b.id &&
        a.name == b.name &&
        a.server == b.server &&
        a.serverPort == b.serverPort &&
        a.listen == b.listen &&
        a.listenPort == b.listenPort &&
        a.ip == b.ip &&
        a.ech == b.ech &&
        a.dns == b.dns &&
        a.token == b.token &&
        a.connections == b.connections &&
        a.block == b.block &&
        a.ips == b.ips &&
        a.fallback == b.fallback &&
        a.insecure == b.insecure &&
        _rulesEqual(a.customRules, b.customRules);
  }

  static bool _rulesEqual(List<CustomRule> a, List<CustomRule> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id ||
          a[i].kind != b[i].kind ||
          a[i].target != b[i].target ||
          a[i].action != b[i].action) {
        return false;
      }
    }
    return true;
  }

  // ---- 配置持久化 ----

  /// 备份前的"干净配置"：取内存当前配置，但 servers 换成已点「保存」的副本，
  /// 未保存的草稿不进备份。对齐 Mac cleanConfig（用内存值，而非重读磁盘，
  /// 否则还没落盘的全局规则/路由模式等最新改动会被备份丢掉）。
  AppConfig get cleanConfig {
    final out = AppConfig.fromJson(config.toJson());
    out.servers = config.servers
        .where((s) => _saved.containsKey(s.id))
        .map((s) => _saved[s.id]!)
        .toList();
    return out;
  }

  void persist() {
    final out = AppConfig.fromJson(config.toJson());
    out.servers = config.servers
        .where((s) => _saved.containsKey(s.id))
        .map((s) => _saved[s.id]!)
        .toList();
    ConfigStore.instance.save(out);
  }

  /// 字段编辑入口（对齐 Mac update{}）
  void update(void Function(ServerConfig s) mutate) {
    var idx = selectedIndex;
    // 未显式选中时回退第一个服务器，避免操作静默失败
    if (idx < 0 && config.servers.isNotEmpty) idx = 0;
    if (idx < 0) return;
    mutate(config.servers[idx]);
    notifyListeners();
  }

  // ---- 服务器生命周期 ----

  void addServer() {
    final s = ServerConfig(name: '');
    config.servers.add(s);
    config.selectedID = s.id;
    needsNameInput = true;
    notifyListeners();
  }

  /// 保存当前服务器；返回错误文案，空=成功
  String? saveCurrentServer() {
    final s = selected;
    if (s == null) return '没有选中的服务器';
    final n = s.name.trim();
    if (n.isEmpty) return '请先给服务器起个名字';
    if (n.displayWidth > 16) {
      return '名字太长：最多 8 个汉字或 16 个英文/数字/符号';
    }
    for (final x in config.servers) {
      if (x.id != s.id && x.name.trim() == n) {
        return '已存在该名称服务器，请重试。';
      }
    }
    final err = s.validate();
    if (err != null) {
      _log('保存失败：$err');
      return err;
    }
    _saved[s.id] = ServerConfig.fromJson(s.toJson());
    persist();
    _log('服务器配置已保存');
    notifyListeners();
    return isRunning ? 'restart' : null;
  }

  /// 保存后一键重启（参数已写入磁盘，重启读取新值生效）
  Future<void> restartProxy() async {
    if (!isRunning && !isStarting) return;
    _log('参数已保存，正在重启代理以应用新配置…');
    await stop();
    await start();
  }

  /// 起名/改名；返回错误文案
  String? rename(String newName) {
    final n = newName.trim();
    if (n.isEmpty) return '服务器名称不能为空';
    if (n.displayWidth > 16) {
      return '名字太长：最多 8 个汉字或 16 个英文/数字/符号';
    }
    final s = selected;
    if (s == null) return '没有选中的服务器';
    for (final x in config.servers) {
      if (x.id != s.id && x.name.trim() == n) {
        return '已存在该服务器名称，请重试。';
      }
    }
    s.name = n;
    if (_saved.containsKey(s.id)) {
      final saved = _saved[s.id]!;
      saved.name = n;
      persist();
    }
    notifyListeners();
    return null;
  }

  void delete(String id) {
    config.servers.removeWhere((s) => s.id == id);
    _saved.remove(id);
    if (config.servers.isEmpty) {
      // 删光 → 重建空白服务器 + 命名
      final fresh = ServerConfig(name: '');
      config.servers.add(fresh);
      config.selectedID = fresh.id;
      needsNameInput = true;
    }
    if (!config.servers.any((s) => s.id == config.selectedID)) {
      config.selectedID = config.servers.first.id;
    }
    persist();
    notifyListeners();
  }

  void deleteSelected() {
    final s = selected;
    if (s != null) delete(s.id);
  }

  Future<void> select(String id) async {
    if (config.selectedID == id) return;
    config.selectedID = id;
    // isStarting 也要拦：旧服务器还在启动中（内核未就绪）就切换，必须把在途
    // 的内核停掉再用新服务器重启 —— 否则 UI 已切到新服务器，跑起来的却是旧服务器。
    if ((isRunning || isStarting) && selected != null) {
      _log('已切换服务器，正在重启代理（会短暂断开）…');
      await stop();
      await start();
    } else {
      notifyListeners();
    }
  }

  void duplicateSelected() {
    final cur = selected;
    if (cur == null) return;
    final copy = ServerConfig.fromJson(cur.toJson())..id = _newUuid();
    var base = '${cur.name} 副本';
    var n = base;
    var i = 2;
    while (config.servers.any((s) => s.name == n)) {
      n = '$base ${i++}';
    }
    copy.name = n;
    config.servers.add(copy);
    config.selectedID = copy.id;
    _saved[copy.id] = ServerConfig.fromJson(copy.toJson());
    persist();
    notifyListeners();
  }

  // ---- 启动/停止 ----

  Future<void> start() async {
    if (isRunning || isStarting) return;
    final s = selected;
    if (s == null) {
      notify('请先新增一个服务器');
      return;
    }
    final err = s.validate();
    if (err != null) {
      notify(err);
      return;
    }
    final saved = _saved[s.id];
    if (saved == null || !_equal(s, saved)) {
      notify(saved == null
          ? '这台服务器还没有保存过，请先点「保存」再启动。'
          : '服务器配置已修改但未保存，请先点「保存」再启动。',
          title: '启动失败');
      return;
    }

    void onLog(String line) {
      final lvl = LogLevel.classify(line);
      LogService.instance.log(line, level: lvl, uiRank: config.logLevel.rank);
    }

    _log('正在启动内核进程…');
    final startErr = await KernelManager.instance.start(s, config.routeMode,
        log: onLog, rules: config.customRules, onExit: (code) {
      // 内核退出 → 同步 App 状态（灯/文案/系统代理），避免 UI 仍显示运行中
      isRunning = false;
      isStarting = false;
      if (proxyTakenOver) {
        proxyTakenOver = false;
        proxyReady = false;
        disableSystemProxy();
      }
      checkState = const CheckState.idle();
      _refreshStatusText();
      notifyListeners();
    });
    if (startErr != null) {
      notify(startErr, title: '启动失败');
      return;
    }
    if (KernelManager.instance.pendingConflict != null) {
      pendingPortConflict = PortConflict(
        label: KernelManager.instance.pendingConflict!.label,
        port: KernelManager.instance.pendingConflict!.port,
        name: KernelManager.instance.pendingConflict!.name,
        pid: KernelManager.instance.pendingConflict!.pid,
      );
      notifyListeners();
      return;
    }
    // 端口一直未就绪 → 内核启动失败：从内核日志尾部归因弹窗（对齐 Mac serverFailureHint）。
    // 注意：判定用 KernelManager 的实时状态（isRunning/isStarting），不能用 AppState
    // 缓存的 isRunning——它在成功路径尾部才同步，首次启动时还是初始 false，
    // 内核实际已就绪也会被误判失败。
    final km = KernelManager.instance;
    if (!km.isRunning && !km.isStarting) {
      _log('[系统] 代理端口未就绪，内核可能启动失败，正在清理残留内核进程…');
      await KernelManager.instance.stop();
      final hint = km.serverFailureHint();
      if (hint != null) {
        notify(hint, title: '启动失败');
      } else {
        notify('请查看运行日志', title: '启动失败');
      }
      checkState = const CheckState.failed('本地代理端口未监听，内核可能未启动成功');
      notifyListeners();
      return;
    }
    isStarting = KernelManager.instance.isStarting;
    isRunning = KernelManager.instance.isRunning;
    if (isStarting || isRunning) {
      checkState = const CheckState.running(); // 启动中清掉上次自检残留
      notifyListeners();
    }
    if (isRunning) {
      rulesDirty = false;
      _refreshStatusText();
      // 对齐 Mac：端口就绪先标记运行中，但暂不接管系统代理（proxyReady=false，
      // 托盘保持橙）。自检通过后（见 _presentCheckResults）才接管 → 托盘变蓝，
      // 避免"隧道其实不通却已把浏览器流量导入"的假成功。
      if (checking == false) {
        // 启动后自动跑的自检：隧道探针失败 → 视为启动失败，由 _presentCheckResults
        // 关闭代理（否则「端口就绪但隧道不通」会一直挂着个死代理）。
        _autoStartCheckCloses = true;
        runSelfCheck(silent: true);
      }
    }
    notifyListeners();
  }

  Future<void> stop() async {
    isStarting = false;
    _autoStartCheckCloses = false; // 启动被中止后不再消费“关闭代理”标记
    if (proxyTakenOver) await disableSystemProxy();
    await KernelManager.instance.stop();
    isRunning = false;
    checkState = const CheckState.idle();
    _refreshStatusText();
    notifyListeners();
  }

  Future<void> toggle() async {
    if (isRunning || isStarting) {
      await stop();
    } else {
      await start();
    }
  }

  /// 退出前清理（对齐 Mac shutdown）：停代理、还原系统代理、持久化、关日志文件
  Future<void> shutdown() async {
    final wasRunningBeforeStop = isRunning || isStarting;
    try {
      if (proxyTakenOver) await disableSystemProxy();
      await KernelManager.instance.stop();
    } catch (_) {}
    isRunning = false;
    isStarting = false;
    // 记录「退出时代理是否在运行」，供下次启动自动恢复（对齐 Mac proxyWasRunning）
    _writeLastProxyState(wasRunning: wasRunningBeforeStop);
    if (_saved.isNotEmpty) persist();
    LogService.instance.close();
  }

  /// 崩溃/强杀自愈（对齐 Mac recoverFromUncleanExit）：
  /// 1) 清理残留内核进程；2) 若系统代理仍有接管残留（备份文件在），还原回原样。
  Future<void> recoverFromUncleanExit() async {
    // 系统代理接管备份文件存在 → 上次异常退出，先还原；读取前判断
    if (SystemProxy.hasPendingBackup()) {
      _log('[系统代理] 检测到上次异常退出的代理接管残留，正在还原…');
      final warns = await SystemProxy.restoreFromDisk();
      if (warns.isEmpty) {
        _log('[系统代理] 残留系统代理接管已还原');
      }
      for (final w in warns) {
        _log('[系统代理] $w');
      }
    }
    // 清理残留内核进程
    await KernelManager.instance.killLeftovers();
  }

  /// 上次退出前代理在运行 → 启动后自动恢复（对齐 Mac restoreProxyIfNeeded）
  Future<void> restoreProxyIfNeeded() async {
    final wasRunning = _readLastProxyState();
    if (wasRunning) {
      _log('[系统] 检测到上次退出时代理正在运行，自动恢复…');
      await start();
    }
  }

  static String _lastStateFile() {
    final dir = Platform.environment['APPDATA'] ?? '';
    final base = dir.isNotEmpty ? dir : Directory.systemTemp.path;
    return '$base/EchOS/proxy-state.json';
  }

  static bool _readLastProxyState() {
    try {
      final f = File(_lastStateFile());
      if (!f.existsSync()) return false;
      final s = f.readAsStringSync();
      f.deleteSync();
      return s == 'running';
    } catch (_) {
      return false;
    }
  }

  static void _writeLastProxyState({required bool wasRunning}) {
    try {
      final f = File(_lastStateFile());
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(wasRunning ? 'running' : 'stopped');
    } catch (_) {}
  }

  Future<void> switchRouteMode(RouteMode mode) async {
    if (config.routeMode == mode) return;
    config.routeMode = mode;
    persist();
    _log('分流模式已切换为「${mode.title}」');
    // 先通知：重启期间 UI 立即高亮新模式，不等 stop/start 跑完。
    notifyListeners();
    // 运行中或启动中都必须重启，否则新路由不生效。只判 isRunning 会漏掉
    // 启动中切换——在途的 start() 可能已按旧模式读走路由，须重启落地新模式。
    if (!isRunning && !isStarting) return;
    _log('[系统] 正在按「${mode.title}」重启代理…');
    await stop();
    await start();
  }

  Future<void> resolvePortConflictByKilling() async {
    final c = pendingPortConflict;
    if (c == null) return;
    pendingPortConflict = null;
    KernelManager.instance.pendingConflict = null; // 清内核侧冲突，避免 start 再命中
    notifyListeners(); // 先关弹窗
    _log('正在结束占用端口的进程 ${c.name}(PID ${c.pid})…');
    final ok = await PortTools.kill(c.pid);
    if (!ok) {
      notify('无法结束进程 ${c.name}(PID ${c.pid})，请手动关闭后再启动',
          title: '启动失败');
      return;
    }
    // 等端口真正释放（最长 3 秒），避免 TIME_WAIT/残留导致 start 又报冲突
    var freed = false;
    for (var i = 0; i < 30; i++) {
      final occ = await PortTools.occupant(c.port);
      if (occ == null && await PortTools.isFree(c.port)) {
        freed = true;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (!freed) {
      notify('端口 ${c.port} 释放失败，请手动检查占用进程后再启动',
          title: '启动失败');
      return;
    }
    _log('${c.label} 端口 ${c.port} 已释放，重新启动代理');
    await start();
  }

  void cancelPortConflict() {
    pendingPortConflict = null;
    _log('已取消启动');
    notifyListeners();
  }

  // ---- 系统代理 ----

  Future<void> enableSystemProxy() async {
    proxyTakenOver = true;
    proxyReady = false;
    // 2-5：接管前记录网络出口与 VPN 状态（不改变行为，供诊断/决策）
    try {
      final snap = await NetworkProbe.snapshot();
      final def = snap.defaultInterface;
      final info = def == null
          ? '未识别默认出口接口'
          : '${def.name}（${def.description}）';
      _log('[网络] 默认出口：$info${snap.vpnActive ? '；检测到 VPN/虚拟接口' : ''}');
    } catch (_) {}
    final socks = KernelManager.instance.activeSocks;
    final http = KernelManager.instance.activeHTTP;
    final r = await SystemProxy.enable(
      socksHost: socks?.host,
      socksPort: socks?.port,
      httpHost: http?.host,
      httpPort: http?.port,
    );
    for (final w in r.warns) {
      _log('[系统代理] $w');
    }
    proxyReady = r.ok;
    if (r.ok) {
      _log('浏览器等程序已自动走本工具');
    }
    _refreshProxySummary();
    notifyListeners();
  }

  Future<void> disableSystemProxy() async {
    proxyTakenOver = false;
    proxyReady = false;
    final warns = await SystemProxy.restore();
    for (final w in warns) {
      _log('[系统代理] $w');
    }
    _log('已还原为你原来的设置');
    _refreshProxySummary();
    notifyListeners();
  }

  void setAutoSystemProxy(bool on) {
    config.autoSystemProxy = on;
    persist();
    if (!isRunning) {
      _log('[系统代理] 已${on ? '开启' : '关闭'}自动设置，下次启动代理时生效');
      notifyListeners();
      return;
    }
    if (on) {
      enableSystemProxy();
    } else {
      disableSystemProxy();
    }
  }

  Future<void> refreshProxySummary() async {
    systemProxySummary = await SystemProxy.summary();
    _refreshStatusText();
    notifyListeners();
  }

  void _refreshProxySummary() {
    SystemProxy.summary().then((v) {
      systemProxySummary = v;
      _refreshStatusText();
      notifyListeners();
    });
  }

  void _refreshStatusText() {
    if (!isRunning) {
      statusText = isStarting ? '启动中…' : '已停止';
      return;
    }
    var t = '运行中';
    final s = KernelManager.instance.activeSocks;
    if (s != null) t += ' · 本地端口 ${s.port}';
    t += proxyReady ? ' · 已接管系统代理' : ' · 未接管系统代理';
    statusText = t;
  }

  // ---- 规则（全局，对所有服务器生效）----

  void addRule() {
    customRules.add(CustomRule());
    if (isRunning) rulesDirty = true;
    notifyListeners();
  }

  void removeRule(String id) {
    customRules.removeWhere((r) => r.id == id);
    if (isRunning) rulesDirty = true;
    notifyListeners();
  }

  void updateRule(String id,
      {RuleKind? kind, String? target, String? action}) {
    for (final r in customRules) {
      if (r.id != id) continue;
      if (kind != null) {
        r.kind = kind;
        r.target = kind == RuleKind.category ? RuleCategory.all.first.value : '';
      }
      if (target != null) r.target = target;
      if (action != null) r.action = action;
    }
    if (isRunning) rulesDirty = true;
    notifyListeners();
  }

  List<CustomRule> get customRules => config.customRules;

  Future<void> applyRules() async {
    if (!isRunning) {
      rulesDirty = false;
      notifyListeners();
      return;
    }
    _log('应用新的分流规则，正在重启代理（会短暂断开）…');
    await stop();
    await start();
    rulesDirty = false;
    notifyListeners();
  }

  // ---- 自检（连通性/代理接管检查）----

  Future<void> runSelfCheck({bool silent = false}) async {
    if (checking) return;
    checking = true;
    checkState = const CheckState.running();
    notifyListeners();
    if (!silent) _log('[自检] 开始检测…');

    // 一次性消费「启动后自检」标记：只有这轮真的在测运行中的代理才可能关代理。
    final closeOnFail = _autoStartCheckCloses;
    _autoStartCheckCloses = false;

    List<SelfCheckResult> results;
    final s = selected;
    final socks = KernelManager.instance.activeSocks;
    if (socks != null && isRunning) {
      results = await SelfCheck.run(socks: socks);
    } else if (s != null) {
      final err = s.validate();
      if (err != null) {
        checkState = CheckState.failed(err);
        if (!silent) _log('[自检] ✗ 配置不完整：$err');
        checking = false;
        notifyListeners();
        return;
      }
      if (!silent) _log('[自检] 代理未启动，预检服务端连通性…');
      results = await SelfCheck.runPreflight(s);
    } else {
      results = [];
      if (!silent) _log('[自检] 请先添加并选中服务器');
    }

    await Future.delayed(const Duration(milliseconds: 800)); // 最低展示时长
    await _presentCheckResults(results, silent, closeOnFail: closeOnFail);
    checking = false;
    notifyListeners();
  }

  Future<void> _presentCheckResults(List<SelfCheckResult> results, bool silent,
      {bool closeOnFail = false}) async {
    for (final r in results) {
      _log('[自检] ${r.ok ? '✓' : '✗'} ${r.title}：${r.note}');
    }
    final failed = results.where((r) => !r.ok).toList();
    if (failed.isEmpty) {
      checkState = CheckState.ok(results.map((r) => '${r.title}：${r.note}').join('\n'));
      // 对齐 Mac：自检通过后才接管系统代理（proxyReady=true → 托盘变蓝）。
      // 仅当代理在运行且配置开启自动接管时接管，避免代理未启动的预检误接管。
      if (isRunning && config.autoSystemProxy && !proxyTakenOver) {
        _log('[系统] 自检通过，正在接管系统代理…');
        enableSystemProxy();
      }
      return;
    }
    checkState = CheckState.failed(
        failed.map((r) => '${r.title}：${r.note}').join('\n'));
    _log('[系统] 隧道自检未完全通过，请查看上方运行日志');
    // 只信"必须经隧道"的探针：国内直连/本地端口的失败可能只是网络本身问题。
    final tunnelFailed = results.any((r) => r.dependsOnTunnel && !r.ok);
    if (!tunnelFailed) return;
    // 对齐 Mac：探针发现隧道其实不通 → 浏览器继续走"死隧道"只会全挂。
    // 必须彻底关闭（停内核 + 还原系统代理 + 清状态），不能只撤系统代理
    // 留着内核跑 —— 否则下次启动撞端口占用，界面状态也对不上。
    if (proxyTakenOver) {
      _log('[系统] 隧道自检失败，为避免浏览器全挂，正在关闭代理…');
      await stop();
    } else if (closeOnFail && isRunning) {
      // 启动/切换后自动跑的那次自检失败：内核刚起来（端口已就绪）但隧道不通，
      // 属于「启动失败」。此时还没接管系统代理（proxyTakenOver=false），
      // 原逻辑不会关代理 → 会一直挂着个死代理。这里必须关掉。
      // 但服务端约 30s 掐断空闲通道：探针恰逢重建窗口会误判“隧道不通”，
      // 先等一个重建周期（6s）重试一次，仍失败才按启动失败关闭。
      _log('[系统] 自检未通过，等 6s 重建窗口后重试…');
      await Future.delayed(const Duration(seconds: 6));
      if (!isRunning) {
        _log('[系统] 重试期间代理已被停止');
        return;
      }
      final ros = KernelManager.instance.activeSocks;
      if (ros == null) {
        await stop();
        notify('服务器连接失败，已停止代理。请检查服务器配置后再启动。',
            title: '启动失败');
        return;
      }
      final retry = await SelfCheck.run(socks: ros);
      final tunnelOk = !retry.any((r) => r.dependsOnTunnel && !r.ok);
      if (tunnelOk) {
        _log('[系统] 重试自检通过，代理继续运行');
        checkState = CheckState.ok(
            retry.map((r) => '${r.title}：${r.note}').join('\n'));
        return;
      }
      _log('[系统] 代理启动失败（服务器连接不通），正在关闭代理…');
      await stop();
      notify('服务器连接失败，已停止代理。请检查服务器配置后再启动。',
          title: '启动失败');
    }
  }

  // ---- 工具 ----

  bool get launchAtLogin => Autostart.enabled;

  Future<String?> setLaunchAtLogin(bool on) async {
    final ok = await Autostart.set(on);
    if (!ok) return '设置开机自启动失败';
    _log('开机自启动已${on ? '开启' : '关闭'}');
    notifyListeners();
    return null;
  }

  /// 是否在任务栏显示图标（托盘右键勾选；对应 Mac 程序坞图标）
  void setShowDockIcon(bool show) {
    config.showDockIcon = show;
    persist();
    log('程序坞图标已${show ? '显示' : '隐藏'}');
    notifyListeners();
  }

  /// 检查更新（App 版本 + 分流数据，对齐 Mac checkEverything）；
  /// silent=true 时不弹窗，只记日志和 UI 状态。
  Future<void> checkEverything({bool silent = false}) async {
    _log('EchOS v$kAppVersion'); // _log 自动带 [系统] 前缀
    await checkAppUpdate(silent: silent);
    // 分流数据（对齐 Mac updateGeoData(force:false, silent:)）
    geoStatus = '正在检查分流数据…';
    notifyListeners();
    final geoResult = await Updater.updateGeoData();
    geoStatus = geoResult;
    // silent 启动检查不把失败刷进运行日志（对齐 Mac：只更新状态，不打断）
    if (!silent || !geoResult.contains('失败') && !geoResult.contains('不通')) {
      _log(geoResult);
    }
    notifyListeners();
  }

/// 检查 App 是否有新版本（对齐 Mac checkAppUpdate）。结果：
  /// 未配置源 / 检查失败 / 已是最新 → alertTitle='检查更新' 弹窗；
  /// 发现新版本 → pendingUpdate 交给界面弹「下载并更新」确认框。
  Future<void> checkAppUpdate({bool silent = false}) async {
    updateStatus = '正在检查更新…';
    notifyListeners();
    if (Updater.repo.trim().isEmpty) {
      updateStatus = '未配置更新源，无法检查更新';
      _log(updateStatus);
      if (!silent) {
        alertTitle = '检查更新';
        alertMessage = '未配置更新源，无法检查更新';
        notifyListeners();
      }
      return;
    }
    _log('正在检查新版本…');
    final inTemp = Platform.resolvedExecutable
        .replaceAll('\\', '/')
        .toLowerCase()
        .startsWith(
            Directory.systemTemp.path.replaceAll('\\', '/').toLowerCase());
    final info = await Updater.fetchLatestRelease(preferPortable: inTemp);
    if (info == null) {
      updateStatus = '检查失败（网络或 GitHub 不可达）';
      _log('检查失败：网络或 GitHub 不可达');
      if (!silent) {
        alertTitle = '检查更新';
        alertMessage = '检查更新失败，请检查网络';
        notifyListeners();
      }
      return;
    }
    if (Updater.isNewer(Updater.parseVersion(info.version),
        Updater.parseVersion(_currentAppVersion))) {
      updateStatus = '发现新版本 ${info.tag}';
      _log('[更新] 发现新版本 ${info.tag}（当前 v$_currentAppVersion）');
      updateInfo = info;
      // 发现新版本一律提示，不受 silent 影响。
      // silent 只用于屏蔽「已是最新 / 检查失败 / 未配置源」这类噪音弹窗；
      // 若把这里也关掉，启动时的静默检查（main.dart 的 silent:true）查到更新
      // 就永远弹不出确认框 —— 自动更新等于失效。
      pendingUpdate = info;
      refresh();
    } else {
      updateStatus = '已是最新版本';
      _log('[更新] 已是最新版本（v$_currentAppVersion）');
      if (!silent) {
        alertTitle = '检查更新';
        alertMessage = '已是最新版本（v$_currentAppVersion）';
        notifyListeners();
      }
    }
  }

  /// 关闭「下载并更新」确认框。
  void dismissPendingUpdate() {
    pendingUpdate = null;
    notifyListeners();
  }

  /// 下载更新包（镜像 Mac downloadUpdate → downloadDMG）。
  /// 进度经 notifyListeners 驱动 home_page 的进度面板；取消置 _cancelDownload。
  Future<void> downloadUpdate() async {
    final info = updateInfo;
    if (info == null) return;
    _cancelDownload = false;
    updateProgress = 0;
    isDownloadingUpdate = true;
    notifyListeners();
    final result = await Updater.downloadAsset(
      info,
      (p) {
        updateProgress = p;
        notifyListeners();
      },
      isCancelled: () => _cancelDownload,
    );
    isDownloadingUpdate = false;
    updateProgress = 0;
    if (result.cancelled) {
      updateStatus = '下载已取消';
      _log('[更新] 下载已取消');
    } else if (result.ok) {
      updateStatus = '下载完成';
      _log('[更新] 下载完成：${result.path}');
      try {
        await _installWindowsUpdate(result.path);
        return; // 启动安装程序并退出，安装器完成后再自动拉起新版
      } catch (_) {
        _log('[更新] 自动安装失败，转手动');
      }
      try {
        // 资源管理器定位下载的文件
        await Process.start('explorer.exe', ['/select,', result.path]);
      } catch (_) {}
      alertTitle = '更新';
      alertMessage = '更新包已下载到：\n${result.path}\n\n'
          '请关闭 EchOS 后运行（或解压替换）对应文件完成更新。';
    } else {
      updateStatus = '下载失败';
      _log('[更新] 下载失败，请稍后重试');
      alertTitle = '更新';
      alertMessage = '下载失败，请稍后重试';
    }
    notifyListeners();
  }

  /// 取消下载更新（进度面板「取消」按钮 → 镜像 Mac cancelDownload）。
  void cancelDownloadUpdate() {
    _cancelDownload = true;
  }

  /// Windows 自动更新入口。
  /// 安装版：静默运行 Setup.exe 就地覆盖（配置在 %APPDATA%，不受影响）。
  /// 便携版：替换用户真正双击的 Portable.exe（经「退出后替换」脚本）。
  /// 失败抛异常，由调用方降级为「打开下载目录 + 提示手动替换」。
  Future<void> _installWindowsUpdate(String setupPath) async {
    persist();
    if (isRunning || isStarting) await stop();
    final exePath = Platform.resolvedExecutable;
    final inTemp = exePath
        .replaceAll('\\', '/')
        .toLowerCase()
        .startsWith(Directory.systemTemp.path.replaceAll('\\', '/').toLowerCase());
    if (inTemp) {
      final ok = await _selfReplacePortable(setupPath);
      if (!ok) throw StateError('便携版就地替换失败');
      exit(0);
    } else {
      await _runSetupSilently(setupPath, exePath);
      exit(0);
    }
  }

  /// 便携版：查找用户真正双击的宿主 exe（Portable.exe）。
  ///
  /// 便携版是 7z SFX：用户双击 Portable.exe → 解压到 %TEMP%\7zSxxxx\ → 运行
  /// 其中的 echos.exe。因此 `Platform.resolvedExecutable` 指向**临时目录**，
  /// 不是用户真正的 Portable.exe（临时目录在退出时会被 SFX 清理掉）。
  /// SFX 进程正是本进程的父进程，其 ExecutablePath 即宿主 exe。
  /// 返回 'pid|path'，失败返回 null。
  Future<String?> _findPortableHost() async {
    final selfPid = pid;
    // $selfPid 由 Dart 插值；其余 $ 需转义，交给 PowerShell 原样解析。
    // ExecutablePath 对受保护/已退出进程会返回 null，故再用 Get-Process
    // 兜底取一次；两者都拿不到就返回 null，由调用方降级为手动更新。
    final script = '''
\$me = Get-CimInstance Win32_Process -Filter "ProcessId = $selfPid"
if (-not \$me) { exit 1 }
\$ppid = \$me.ParentProcessId
\$path = \$null
\$parent = Get-CimInstance Win32_Process -Filter "ProcessId = \$ppid"
if (\$parent) { \$path = \$parent.ExecutablePath }
if (-not \$path) {
  try { \$path = (Get-Process -Id \$ppid -ErrorAction Stop).Path } catch { \$path = \$null }
}
if (\$path) { Write-Output ("{0}|{1}" -f \$ppid, \$path) }
''';
    try {
      final r = await Process.run('powershell',
          ['-NoProfile', '-NonInteractive', '-Command', script]);
      final out = (r.stdout as String).trim();
      if (out.contains('|')) return out;
    } catch (_) {}
    return null;
  }

  /// 安装版：静默运行 Setup.exe 就地覆盖，配置在 APPDATA 不受影响。
  ///
  /// 注意：**绝不能手写引号**。Dart 在 Windows 上会把参数列表拼成命令行
  /// 并为含空格的参数自动加引号；若参数里已经写了 `"`，Dart 会再转义成 `\"`，
  /// 子进程收到 `/DIR=\"D:\Program Files\EchOS\"`，Inno 认为 `"` 是非法字符
  /// 直接中止安装（表现为「更新了但没装上」，日志里是「文件夹名称不能包含下列
  /// 任何字符」+ aborting）。
  ///
  /// 另外起一个看门狗批处理：等 Setup 退出后若 echos.exe 没起来就重新拉起。
  /// 这样即使安装失败（权限/文件占用等），旧版也能回来并再次提示更新，
  /// 不会留下「应用没了、也没任何提示」的死局。
  Future<void> _runSetupSilently(String setupPath, String exePath) async {
    var dir = File(exePath).parent.path;
    // 结尾反斜杠会和 Dart 补上的引号粘成 `\"`，同样触发 Inno 的非法字符校验。
    while (dir.endsWith(Platform.pathSeparator) && dir.length > 3) {
      dir = dir.substring(0, dir.length - 1);
    }
    final args = [
      '/DIR=$dir', // 不要加引号，Dart 会处理
      '/VERYSILENT',
      '/SUPPRESSMSGBOXES',
      '/NORESTART',
      '/SP-',
      '/NOCANCEL',
      '/MERGETASKS=!desktopicon',
    ];
    final proc = await Process.start(setupPath, args,
        mode: ProcessStartMode.detachedWithStdio);
    await _spawnUpdateWatchdog(proc.pid, exePath);
  }

  /// 更新看门狗：等 Setup 进程退出 → 等新进程起来 → 没起来就重新拉起 exePath。
  ///
  /// 用 PowerShell 而不是批处理。批处理在这里有两个躲不开的坑：
  ///   1) `%%~dpF` 取到的目录**带结尾反斜杠**，`start "" /D "%DIR%" "%APP%"` 里
  ///      的 `\"` 会转义掉闭合引号，整行被拆坏（实测报 `'hos.exe"'`、`'o'` 等）；
  ///   2) 写出去的文件是 UTF-8，cmd 按 GBK 解析，中文注释变乱码甚至产生杂字符。
  /// 改成 PowerShell + 参数列表后，引号一律由 Dart 负责，两条都规避掉了。
  Future<void> _spawnUpdateWatchdog(int setupPid, String exePath) async {
    try {
      final dir = File(exePath).parent.path;
      final name = exePath
          .split(Platform.pathSeparator)
          .last
          .replaceAll(RegExp(r'\.exe$', caseSensitive: false), '');
      // 纯 ASCII：不写中文注释，避免任何代码页问题。
      final script = r'''
$ErrorActionPreference = 'SilentlyContinue'
Wait-Process -Id __PID__ -ErrorAction SilentlyContinue
Start-Sleep -Seconds 8
if (-not (Get-Process -Name '__NAME__' -ErrorAction SilentlyContinue)) {
  Start-Process -FilePath '__EXE__' -WorkingDirectory '__DIR__'
}
'''
          .replaceAll('__PID__', '$setupPid')
          .replaceAll('__NAME__', name)
          .replaceAll('__EXE__', exePath)
          .replaceAll('__DIR__', dir);
      // 必须用 normal，不能用 detached：powershell 是控制台程序，Dart 的 detached
      // 以「无控制台」方式创建进程，powershell 起不来（实测 detached 与
      // detachedWithStdio 均不执行，normal 正常）。Windows 上子进程独立于父进程，
      // 主进程 exit(0) 后子进程照常跑完 —— 已实测确认。
      await Process.start(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-Command',
          script,
        ],
        mode: ProcessStartMode.normal,
      );
    } catch (_) {
      // 看门狗失败不影响安装本身
    }
  }

  /// 便携版就地替换：把新版写给用户真正的 Portable.exe。
  ///
  /// 关键：目标是**宿主 exe**（用户双击的 Portable.exe），不是 resolvedExecutable
  /// 指向的临时目录副本（那个退出即被 SFX 删除，替换它毫无意义）。
  ///
  /// 流程：
  ///   1) 经父进程查到宿主 exe 路径与 PID
  ///   2) 把新版复制到宿主同目录，命名为 `<原名>.new.exe`
  ///   3) 写批处理：等待本进程退出 → 等待 SFX 父进程退出 → 替换 → 启动新版
  ///   4) 用 `cmd /c start /min` 启动脚本后本进程 exit(0)
  ///
  /// 必须等两个进程：SFX 父进程持有 Portable.exe 的句柄，只有它退出后文件才
  /// 可写；而它又要等本进程退出后才清理并退出。
  ///
  /// 批处理用 `if not errorlevel 1` 判「仍存活」——等价于 errorlevel==0，
  /// 在标签跳转场景下比 `%errorlevel%` 展开更可靠。
  Future<bool> _selfReplacePortable(String newPath) async {
    final host = await _findPortableHost();
    if (host == null) return false;
    final idx = host.indexOf('|');
    if (idx <= 0) return false;
    final hostPid = host.substring(0, idx).trim();
    final hostPath = host.substring(idx + 1).trim();
    if (!hostPath.toLowerCase().endsWith('.exe')) return false;

    final hostFile = File(hostPath);
    final dir = hostFile.parent.path;
    final base = hostFile.uri.pathSegments.last;
    final newFile = '$dir${Platform.pathSeparator}$base.new.exe';
    await File(newPath).copy(newFile);

    final selfPid = pid;
    final batPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}EchOS_Replace.bat';
    final bat = File(batPath);
    await bat.writeAsString('''@echo off
setlocal
set "TARGET=$hostPath"
set "NEW=$newFile"
set "SELF=$selfPid"
set "HOST=$hostPid"
:waitSelf
ping 127.0.0.1 -n 2 >nul
tasklist /FI "PID eq %SELF%" 2>nul | findstr "%SELF%" >nul
if not errorlevel 1 goto waitSelf
:waitHost
ping 127.0.0.1 -n 2 >nul
tasklist /FI "PID eq %HOST%" 2>nul | findstr "%HOST%" >nul
if not errorlevel 1 goto waitHost
move /Y "%NEW%" "%TARGET%" >nul 2>&1
if not errorlevel 1 start "" "%TARGET%"
del "%~f0"
''', flush: true);
    await Process.start('cmd.exe', ['/c', 'start', '/min', batPath],
        mode: ProcessStartMode.detached);
    return true;
  }

  String get _currentAppVersion => kAppVersion;

  void notify(String text, {String title = '出错'}) {
    _log(text);
    alertTitle = title;
    alertMessage = text;
    notifyListeners();
  }

  /// 供外部（非子类）请求重建界面
  void refresh() => notifyListeners();

  void _log(String text) {
    LogService.instance
        .log('[系统] $text',
            level: LogLevel.classify(text), uiRank: config.logLevel.rank);
  }

  void log(String text) => _log(text);

  /// 还原整个配置（镜像 Mac applyRestored）
  void applyRestored(AppConfig cfg) {
    if (isRunning || isStarting) {
      stop();
    }
    // 只保留参数完整的服务器
    final valid = cfg.servers.where((s) => s.validate() == null).toList();
    if (valid.isEmpty) {
      valid.add(ServerConfig(name: '服务器 1'));
    }
    config = AppConfig.fromJson(cfg.toJson());
    config.servers = valid;
    if (!config.servers.any((s) => s.id == config.selectedID)) {
      config.selectedID = config.servers.first.id;
    }
    _saved.clear();
    for (final s in config.servers) {
      _saved[s.id] = ServerConfig.fromJson(s.toJson());
    }
    persist();
    rulesDirty = false;
    notifyListeners();
  }

  void clearLog() {
    LogService.instance.clear();
    refresh(); // 界面立即清空（LogService 只清数据，需重建 UI）
  }

  static String _newUuid() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${DateTime.now().millisecond}';
}
