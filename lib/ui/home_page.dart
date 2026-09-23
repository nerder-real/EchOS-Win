// 主界面：对齐 Mac ContentView（单窗口三卡片 + 底部操作/日志）。
// 重构：标签列宽统一、输入框各自持 controller、规则动作可改、日志级别可选、
//      命名弹窗改按钮触发、分享/备份/WebDAV 全接线。
import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../models/config.dart';
import '../services/app_state.dart';
import '../services/log_service.dart';
import 'dialogs.dart';
import 'frosted.dart';
import 'theme.dart';
import 'widgets/app_button.dart';
import 'widgets/app_dropdown.dart';
import 'widgets/app_row.dart';
import 'widgets/app_text_field.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WindowListener {
  final GlobalKey _contentBox = GlobalKey();
  final GlobalKey _topKey = GlobalKey(); // 配置区（三张卡）自然高度基准
  final GlobalKey _bottomKey = GlobalKey(); // 底部卡（不含日志）自然高度基准
  bool _rulesExpanded = false;
  bool _syncing = false;
  bool _enforcing = false;
  double _bottomBaseH = 132; // 底部卡折叠时自然高（实测校准）
  double _targetWinH = 0; // 当前状态的目标窗口高度（用于软锁定）

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    AppState.instance.addListener(_onAppChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 服务器列表为空（全新安装）：直接建一个待起名的服务器并弹命名框（对齐 Mac onAppear）
      if (AppState.instance.config.servers.isEmpty) {
        AppState.instance.addServer();
      }
      _syncHeight();
    });
    // 首帧布局可能未稳定，延迟再同步一次确保高度正确、窗口居中
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) _syncHeight();
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    AppState.instance.removeListener(_onAppChanged);
    super.dispose();
  }

  // 软锁定：窗口被拖小于当前状态最小值时弹回（不依赖 setMinimumSize 时序）
  @override
  void onWindowResized() {
    if (mounted && !_syncing && _targetWinH > 0) {
      _enforceMinHeight();
    }
  }

  Future<void> _enforceMinHeight() async {
    if (_enforcing) return;
    _enforcing = true;
    try {
      final size = await windowManager.getSize();
      // 折叠时无日志区吃多余高度 → 锁定（拉大也弹回）；
      // 展开时仅阻止小于最小值，拉大 → 日志区增高
      if (size.height < _targetWinH ||
          !AppState.instance.config.logVisible) {
        await windowManager.setSize(Size(796, _targetWinH));
        windowManager.center();
      }
    } catch (_) {} finally {
      _enforcing = false;
    }
  }

  // 日志展开/折叠等配置变化 → 窗口高度随内容贴合
  void _onAppChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncHeight();
      _maybeShowAlerts();
    });
  }

  bool _alertShowing = false;

  /// 全局弹窗监听：端口冲突确认 / 错误提示（对齐 Mac 的一串 `.alert`）
  void _maybeShowAlerts() {
    if (_alertShowing || !mounted) return;
    final app = AppState.instance;
    final conflict = app.pendingPortConflict;
    if (conflict != null) {
      _alertShowing = true;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (c) => EchDialog(
          title: '端口被占用',
          message:
              '${conflict.label} 端口 ${conflict.port} 被 ${conflict.name}(PID ${conflict.pid}) 占用。\n强制结束该进程后将继续启动代理，该进程会立即退出。',
          actions: [
            EchDialog.cancel(c, onPressed: () {
              Navigator.pop(c);
              app.cancelPortConflict();
              _alertShowing = false;
            }),
            EchDialog.confirm(c,
                label: '强制结束并启动',
                danger: true,
                onPressed: () {
                  Navigator.pop(c);
                  app.resolvePortConflictByKilling();
                  _alertShowing = false;
                }),
          ],
        ),
      );
return;
    }
    // TUN 模式需要管理员权限：开关点开、或启动时发现 TUN 已开启但不是管理员
    // （典型是开机自启起的普通权限进程）→ 询问是否提权重启。
    if (app.pendingElevation) {
      _alertShowing = true;
      final fromStart = app.elevationReason == 'tunStart';
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (c) => EchDialog(
          title: 'TUN 模式需要管理员权限',
          message: fromStart
              ? '当前不是以管理员身份运行，TUN 模式无法生效。\n\n'
                  'Windows 不允许运行中的程序提升权限，所以要以管理员身份重启。\n'
                  '重启后会自动恢复代理并继续启动。'
              : 'TUN 模式要创建虚拟网卡、修改路由表和网卡 DNS，需要管理员权限。\n\n'
                  'Windows 不允许运行中的程序提升权限，所以要以管理员身份重启 EchOS。\n'
                  '重启后会自动恢复代理，TUN 模式立即生效。',
          actions: [
            EchDialog.cancel(c, onPressed: () {
              Navigator.pop(c);
              app.cancelElevation();
              _alertShowing = false;
              _maybeShowAlerts();
            }),
            EchDialog.confirm(c,
                label: '以管理员身份重启',
                onPressed: () {
                  Navigator.pop(c);
                  _alertShowing = false;
                  app.confirmElevation();
                }),
          ],
        ),
      );
      return;
    }
    final pending = app.pendingUpdate;
    if (pending != null) {
      // 发现新版本 → 与 Mac 一致：图标 + 版本 + 「下载并更新」确认框
      _alertShowing = true;
      showUpdatePromptDialog(context, pending).whenComplete(() {
        if (mounted) _alertShowing = false;
        _maybeShowAlerts();
      });
      return;
    }
    if (app.isDownloadingUpdate) {
      // 下载进度面板（镜像 Mac showDownloadProgress 小窗）
      _alertShowing = true;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _UpdateProgressDialog(app: app),
      ).then((_) {
        if (mounted) _alertShowing = false;
        _maybeShowAlerts();
      });
      return;
    }
    final msg = app.alertMessage;
    if (msg != null) {
      _alertShowing = true;
      final title = app.alertTitle ?? '提示';
      app.alertMessage = null;
      showDialog<void>(
        context: context,
        builder: (c) => EchDialog(
          // 「检查更新」的结果（已是最新/失败/未配置源）带 App 图标，镜像 Mac
          icon: title == '检查更新' ? const AssetImage('assets/icon.png') : null,
          title: title,
          message: msg,
          actions: [
            EchDialog.confirm(c, label: '好', onPressed: () {
              Navigator.pop(c);
              _alertShowing = false;
            }),
          ],
        ),
      );
    }
  }
  // 窗口与可视区(去任务栏/菜单栏/Dock)边缘的留白量（逻辑像素）。
  // 全展开状态外框 989 需要 maxH ≥ 989：工作区 1032 − 20×2 = 992 可容纳。
  static const double _edgeMargin = 20;

  // 窗口最大高度：不超过当前显示器可视区高度 − 上下边距（保证两侧都有留白、真正居中）。
  Future<double> _maxCompatWindowH() async {
    final workH = (await _workHeight()) - _edgeMargin * 2;
    return workH;
  }

  // 窗口高度按状态 + 屏幕限制：内容 = 标题 + 配置区(实测) + 底部卡。
  // 折叠锁定 min=max；展开时 min=贴合高、max=屏幕高（拉大 → 日志区 Expanded 增高，底边距固定 12）。
  Future<void> _syncHeight() async {
    if (_syncing) return;
    _syncing = true;
    try {
      final maxH = await _maxCompatWindowH();
      // await 之后可能已卸载，后续要读 BuildContext（findRenderObject），先挡一道
      if (!mounted) return;
      // 配置区（三张卡）自然高度：非 flex，不受窗口撑满影响，测量准确
      var topH = 0.0;
      final ctx = _topKey.currentContext;
      if (ctx != null && ctx.mounted) {
        final ro = ctx.findRenderObject();
        if (ro is RenderBox) topH = ro.size.height;
      }
      // 日志折叠时实测底部卡自然高（展开时 Padding 在 Expanded 内测不到，用缓存）
      if (!AppState.instance.config.logVisible) {
        final bctx = _bottomKey.currentContext;
        if (bctx != null && bctx.mounted) {
          final bro = bctx.findRenderObject();
          if (bro is RenderBox) _bottomBaseH = bro.size.height;
        }
      }
      // 标题栏(80) + 间隔(6) + 配置区 + 间隔(12) + 底部卡
      var clientH = 80 + 6 + topH + 12 + _bottomBaseH;
      if (clientH <= 0) clientH = 760; // 首帧兜底
      if (AppState.instance.config.logVisible) {
        // 全部展开（规则+日志）：内容区高度固定 970（不含外框），日志整 2 行
        if (_rulesExpanded) {
          clientH = 970;
        } else {
          // 日志展开（规则收起）：内容区高度固定 870（不含外框），日志整 4 行
          // 行高随窗口伸缩（≥fsLog×1.25），行距吸收全部余量，无死区
          clientH = 870;
        }
      }
      var winH = clientH + 39; // 内容区(Client)到窗口外框(Win)完整差：标题栏32 + 边框7
      if (winH > maxH) winH = maxH;
      if (winH < 400) winH = 400; // 兜底下限（各状态真实最小值由 setMinimumSize 锁定）
      _targetWinH = winH; // 记录当前状态最小高度，供软锁定弹回
      // 最小高度 = 当前状态贴合高：拉伸不得小于此值（折叠/展开各自下限）
      await windowManager.setMinimumSize(Size(796, winH));
      await windowManager.setSize(Size(796, winH));
      windowManager.center();
    } finally {
      _syncing = false;
    }
  }

  // 当前显示器（光标所在显示器，与 window_manager.center 一致）的可视区高度。
  Future<double> _workHeight() async {
    try {
      final cursor = await screenRetriever.getCursorScreenPoint();
      final displays = await screenRetriever.getAllDisplays();
      final primary = await screenRetriever.getPrimaryDisplay();
      Display cur = primary;
      for (final d in displays) {
        if (d.visiblePosition != null &&
            Rect.fromLTWH(
                    d.visiblePosition!.dx,
                    d.visiblePosition!.dy,
                    d.size.width,
                    d.size.height)
                .contains(cursor)) {
          cur = d;
          break;
        }
      }
      if (cur.visibleSize != null) return cur.visibleSize!.height;
      return cur.size.height;
    } catch (_) {
      return 1080.0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scaffold = AnimatedBuilder(
      animation: AppState.instance,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: LiquidBackground(
            child: Column(
              key: _contentBox,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 页面顶部 LOGO + 名称（原生标题栏在更外层，只显示系统按钮）
                const _TitleBar(),
                const SizedBox(height: 6),
                // 配置区：固定自然高度，三张卡间距 12（不滚动、不占满）
                Padding(
                  key: _topKey,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _ServerGroup(),
                      const SizedBox(height: 12),
                      _CoreGroup(),
                      const SizedBox(height: 12),
                      _AdvancedGroup(
                        rulesExpanded: _rulesExpanded,
                        onRulesExpandedChanged: (v) => setState(() {
                          _rulesExpanded = v;
                          WidgetsBinding.instance
                              .addPostFrameCallback((_) => _syncHeight());
                        }),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // 底部操作+日志卡：日志展开时占剩余高度（日志区吃额外空间 → 拉伸窗口日志增高）；
                // 日志折叠时不撑满（避免日志按钮下方出现空白），自然贴合内容。
                if (AppState.instance.config.logVisible)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: CardBox(
                        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                        child: _BottomBlock(),
                      ),
                    ),
                  )
                else
                  Padding(
                    key: _bottomKey,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: CardBox(
                      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                      child: _BottomBlock(),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
    return scaffold;
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 立体云 LOGO（000 构图：橙渐变 + 云朵，圆弧云底无平直带）。满幅直角
          // 位图 + 矢量圆角裁剪——位图不带圆角，四角由 Clip.antiAlias 渲染，任何
          // DPI 都锐利。云朵满幅居中（与桌面图标同款构图）。
          Container(
            width: 44,
            height: 44,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(8.5)),
            child: Image.asset('assets/logo.png',
                fit: BoxFit.cover, filterQuality: FilterQuality.high),
          ),
          const SizedBox(width: 14),
          const Text('EchOS',
              style: TextStyle(
                  fontSize: 26,
                  fontWeight: EchTheme.fwTitle)),
        ],
      ),
    );
  }
}

/// 分组卡片：渐变芯片标题 + 玻璃内容卡
class _GroupCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Gradient gradient;
  final Widget child;
  const _GroupCard(
      {required this.title,
      required this.icon,
      required this.gradient,
      required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            gradient: gradient,
            borderRadius: BorderRadius.circular(11),
            boxShadow: [
              BoxShadow(
                color: _gradStart(gradient).withValues(alpha: 0.35),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: Colors.white),
            const SizedBox(width: 7),
            Text(title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: EchTheme.fsGroupTitle,
                    fontWeight: EchTheme.fwTitle,
                    letterSpacing: EchTheme.letterSpacing)),
          ]),
        ),
        const SizedBox(height: 5),
        CardBox(
          padding: const EdgeInsets.all(10),
          child: SizedBox(width: double.infinity, child: child),
        ),
      ],
    );
  }

  static Color _gradStart(Gradient g) =>
      (g is LinearGradient && g.colors.isNotEmpty) ? g.colors.first : const Color(0xFF0A84FF);
}

// ===========================================================================
// 服务器管理
// ===========================================================================

class _ServerGroup extends StatelessWidget {
  const _ServerGroup();
  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final s = app.selected;
    if (app.needsNameInput && s != null && s.name.isEmpty) {
      // 延迟到首帧后弹命名框（不在 build 内直接弹）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (app.needsNameInput) {
          app.needsNameInput = false;
          app.refresh();
          _promptName(context, app, s);
        }
      });
    }

    final t = Theme.of(context);
    return _GroupCard(
      title: '服务器管理',
      icon: Icons.dns_rounded,
      gradient: EchTheme.blueGradient(),
      child: Row(
          children: [
            // 选择服务器标签（与其它行的标签列宽一致）
            SizedBox(
              width: AppRow.labelWidth,
              child: Text('选择服务器',
                  style: EchTheme.labelStyle(EchTheme.textSoft(t))),
            ),
          // 服务器下拉
          AppDropdown<String>(
            width: 118,
            value: s?.id ?? '',
            items: [for (final x in app.config.servers) x.id],
            labelOf: (id) {
              final i = app.config.servers.indexWhere((x) => x.id == id);
              if (i < 0) return '';
              final n = app.config.servers[i].name;
              return n.isEmpty ? '未命名 ${i + 1}' : n;
            },
            onChanged: app.select,
          ),
          const SizedBox(width: 10),
          AppButton('新增',
            fontSize: EchTheme.fsTool,
            enabled: !app.isRunning, // 对齐 Mac：运行中整体禁用
            onPressed: () {
              if (!app.hasUncommittedServer) {
                app.addServer();
              } else {
                app.alertTitle = '当前服务器状态未确认';
                app.alertMessage = '请填写完整参数后「保存」。\n如不需要，请「删除」当前服务器。';
                app.refresh();
              }
            }),
          const SizedBox(width: 6),
          AppButton('重命名',
            fontSize: EchTheme.fsTool,
            enabled: s != null && !app.isRunning, // 对齐 Mac：运行中禁用
            onPressed: () {
              if (s != null) {
                _promptName(context, app, s, rename: true);
              }
            }),
          const SizedBox(width: 6),
          AppButton('保存',
              fontSize: EchTheme.fsTool,
              enabled: !app.isRunning, // 对齐 Mac：运行中禁用（保存会重启代理）
              gradient: app.isServerDirty(s?.id ?? '')
                  ? EchTheme.orangeGradient()
                  : EchTheme.greenGradient(),
              onPressed: () {
                final err = app.saveCurrentServer();
                if (err == 'restart') {
                  // 代理运行中：参数已保存，提示需要重启才生效（可选立即重启）
                  showDialog<void>(
                    context: context,
                    builder: (c) => EchDialog(
                      title: '配置已保存',
                      message: '代理正在运行，新参数需重启后才生效。',
                      actions: [
                        EchDialog.cancel(c,
                            label: '稍后', onPressed: () => Navigator.pop(c)),
                        EchDialog.confirm(c,
                            label: '重启代理',
                            onPressed: () async {
                              Navigator.pop(c);
                              await app.restartProxy();
                            }),
                      ],
                    ),
                  );
                } else {
                  app.alertTitle = err == null ? '配置已保存' : '保存失败';
                  app.alertMessage = err ?? '配置已写入本地。';
                  app.refresh();
                }
              }),
          const SizedBox(width: 6),
          AppButton('删除',
              fontSize: EchTheme.fsTool,
              gradient: EchTheme.redGradient(),
              enabled: !app.isRunning, // 对齐 Mac：运行中禁用
              onPressed: () {
                if (s == null) return;
                final last = app.config.servers.length <= 1;
                _confirmDelete(context, app, s, last);
              }),
          const Spacer(),
          AppMenuButton('分享', fontSize: EchTheme.fsTool,
              icon: Icons.ios_share,
              items: [
                PopupMenuItem(value: 'export', child: const Text('导出为服务器…')),
                PopupMenuItem(value: 'import', child: const Text('导入服务器…')),
              ],
              onSelected: (v) {
                if (v == 'export') {
                  showShareDialog(context);
                } else {
                  showImportDialog(context);
                }
              }),
          const SizedBox(width: 6),
          AppMenuButton('备份', fontSize: EchTheme.fsTool,
              icon: Icons.sd_storage,
              iconColor: EchTheme.orange,
              items: [
                PopupMenuItem(value: 'bl', child: const Text('备份到本地文件…')),
                PopupMenuItem(value: 'rl', child: const Text('从本地文件还原…')),
                const PopupMenuDivider(),
                PopupMenuItem(value: 'ws', child: const Text('WebDAV 设置…')),
                PopupMenuItem(value: 'bw', child: const Text('「备份」到远程WebDAV')),
                PopupMenuItem(value: 'rw', child: const Text('从远程WebDAV「还原」备份')),
                PopupMenuItem(value: 'dw', child: const Text('「删除」远程WebDAV备份')),
              ],
              onSelected: (v) {
                switch (v) {
                  case 'bl':
                    showBackupDialog(context);
                  case 'rl':
                    showRestoreDialog(context);
                  case 'ws':
                    showWebDAVSettings(context);
                  case 'bw':
                    showWebDAVBackup(context);
                  case 'rw':
                    showWebDAVRestore(context);
                  case 'dw':
                    showWebDAVDeleteBackup(context);
                }
              }),
          const SizedBox(width: 6),
          AppButton('自检', fontSize: EchTheme.fsTool,
              leading: Icon(Icons.verified_outlined,
                  size: 15,
                  color: switch (app.checkState.kind) {
                    CheckStateKind.running => EchTheme.yellow,
                    CheckStateKind.ok => EchTheme.green,
                    CheckStateKind.failed => EchTheme.red,
                    CheckStateKind.idle => EchTheme.blue,
                  }),
              onPressed: () => app.runSelfCheck()),
        ],
      ),
    );
  }
}

Future<void> _promptName(BuildContext context, AppState app, ServerConfig s,
    {bool rename = false}) async {
  final controller = TextEditingController(text: rename ? s.name : '');

  // 命名框可能因为输入无效被反复弹回，所以整段放进循环：
  //   取消     → 跳出循环，走「默认名兜底 / 保持原名」
  //   名字无效 → 弹提示，然后回到命名框让用户重填
  //   名字有效 → 落名后直接返回
  //
  // 关键：「确定但空名」和「取消」是两回事，不能合并处理 ——
  //   取消       = 用户主动放弃命名 → 替他兜个默认名
  //   确定但空名 = 输入无效         → 应该让他重填，而不是替他起名
  // 早先把两者都并进「默认名兜底」，等于把「确定」变成了「取消」。
  while (true) {
    final input = await showDialog<String>(
      context: context,
      builder: (c) => EchDialog(
        title: rename ? '重命名服务器' : '新建服务器名称',
        message: '服务器名称最多支持 8 个汉字 / 16 个英文数字符号',
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(
              fontSize: EchTheme.fsBody,
              fontWeight: EchTheme.fwContent,
              color: EchTheme.inputText(Theme.of(context))),
          decoration: InputDecoration(
            hintText: '例如：xx服务器',
            isDense: true,
            filled: true,
            fillColor: EchTheme.inputBg(Theme.of(c)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide:
                  const BorderSide(color: Color(0xFF0A84FF), width: 1.3),
            ),
          ),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          EchDialog.cancel(c, onPressed: () => Navigator.pop(c)),
          EchDialog.confirm(c,
              label: '确定',
              onPressed: () => Navigator.pop(c, controller.text.trim())),
        ],
      ),
    );

    if (input == null) break; // 取消
    // rename() 只在校验全通过之后才改状态，失败时原样返回错误文案，可反复调用
    final err = app.rename(input);
    if (err == null) {
      controller.dispose();
      return;
    }
    if (!context.mounted) {
      controller.dispose();
      return;
    }
    // 名字不能用（空 / 太长 / 重名）→ 提示后回到命名框重填
    await showDialog<void>(
      context: context,
      builder: (c) => EchDialog(
        title: '无法使用这个名字',
        message: err,
        actions: [
          EchDialog.confirm(c, label: '好', onPressed: () => Navigator.pop(c)),
        ],
      ),
    );
    if (!context.mounted) {
      controller.dispose();
      return;
    }
  }

  controller.dispose();
  // 取消 = 放弃命名，用「未命名 N」兜底。
  //
  // 这里千万不能走 app.delete()：delete() 在把服务器删光后会立刻重建一个空名
  // 服务器、并把 needsNameInput 置回 true，于是「点取消 → 弹窗关掉又马上重开」，
  // 命名框永远关不掉（实测复现：连点取消，弹窗一直在）。
  // 改名场景取消 = 保持原名，什么都不做。
  if (!rename) app.useDefaultName(s);
}

Future<void> _confirmDelete(
    BuildContext context, AppState app, ServerConfig s, bool last) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => EchDialog(
      title: '删除服务器？',
      message: last
          ? '将清空「${s.name}」的配置并重建一个空白服务器，不可撤销。'
          : '将删除「${s.name}」及其配置，不可撤销。',
      actions: [
        EchDialog.cancel(c, onPressed: () => Navigator.pop(c, false)),
        EchDialog.confirm(c,
            label: '删除',
            danger: true,
            onPressed: () => Navigator.pop(c, true)),
      ],
    ),
  );
  if (ok == true) app.deleteSelected();
}

// ===========================================================================
// 核心配置
// ===========================================================================

class _CoreGroup extends StatelessWidget {
  const _CoreGroup();
  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final s = app.selected;
    final locked = app.isBusy; // 运行/启动/停止中锁定配置修改
    return _GroupCard(
      title: '核心配置',
      icon: Icons.settings_rounded,
      gradient: EchTheme.indigoGradient(),
      child: Column(children: [
        AppRow(
          label: '服务器地址',
          child: Row(children: [
            Expanded(
              child: AppTextField(
                s?.server ?? '',
                hint: 'xxx.workers.dev',
                obscureWhenUnfocused: true,
                fontWeight: EchTheme.fwContent,
                enabled: !locked,
                onChanged: (v) => app.update((x) => x.server = v),
              ),
            ),
            const SizedBox(width: 18),
            Text('端口',
                style: EchTheme.labelStyle(
                    EchTheme.textSoft(Theme.of(context)))),
            const SizedBox(width: 18),
            SizedBox(
              width: 120,
              child: AppTextField(
                '${s?.serverPort ?? 443}',
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                fontWeight: EchTheme.fwContent,
                enabled: !locked,
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null) app.update((x) => x.serverPort = n);
                },
              ),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        AppRow(
          label: 'TOKEN（可选）',
          child: AppTextField(s?.token ?? '',
              monospace: false,
              obscureWhenUnfocused: true,
              fontWeight: EchTheme.fwContent,
              enabled: !locked,
              onChanged: (v) => app.update((x) => x.token = v)),
        ),
        const SizedBox(height: 10),
        AppRow(
          label: '监听地址',
          child: Row(children: [
            Expanded(
              child: AppTextField(
                () {
                  final h = ServerConfig.cleanHost(s?.listen ?? '');
                  return h.isEmpty ? '127.0.0.1' : h;
                }(),
                hint: '127.0.0.1',
                fontWeight: EchTheme.fwContent,
                enabled: !locked,
                onChanged: (v) => app.update((x) => x.listen = v),
              ),
            ),
            const SizedBox(width: 18),
            Text('端口',
                style: EchTheme.labelStyle(
                    EchTheme.textSoft(Theme.of(context)))),
            const SizedBox(width: 18),
            SizedBox(
              width: 120,
              child: AppTextField(
                '${s?.listenPort ?? 30000}',
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                fontWeight: EchTheme.fwContent,
                enabled: !locked,
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null) app.update((x) => x.listenPort = n);
                },
              ),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        AppRow(
          label: '优选IP（域名）',
          child: AppTextField(s?.ip ?? '',
              hint: '104.16.xx.xx',
              fontWeight: EchTheme.fwContent,
              enabled: !locked,
              onChanged: (v) => app.update((x) => x.ip = v)),
        ),
      ]),
    );
  }
}

class _ModeSegment extends StatelessWidget {
  // 分流模式（绕过中国大陆/黑名单/全局）在代理运行期间也允许切换，切换后
  // AppState.switchRouteMode 会自动重启代理，因此这里没有「运行中锁定」。
  const _ModeSegment();
  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    // 必须自己订阅 AppState：本控件以 const 实例挂在主页上，父级重建时 Flutter
    // 会因为 widget 实例相同（identical）而跳过它，导致切换分流模式后高亮不跟随
    // （看起来像「点了没反应」）。用 AnimatedBuilder 订阅后，任何来源的状态
    // 变化都能刷新这里，不必依赖父级恰好重建。
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final t = Theme.of(context);
        return Container(
          height: 34,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            color: EchTheme.inputBg(t),
            border: Border.all(color: EchTheme.cardBorder(t)),
          ),
          child: Row(children: [
            for (final m in RouteMode.values) ...[
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => app.switchRouteMode(m),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(7),
                      gradient: app.config.routeMode == m
                          ? EchTheme.blueGradient()
                          : null,
                      boxShadow: app.config.routeMode == m
                          ? [
                              BoxShadow(
                                color: EchTheme.blue.withValues(alpha: 0.35),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : [],
                    ),
                    child: Center(
                      child: Text(m.title,
                          style: TextStyle(
                              fontSize: EchTheme.fsSegment,
                              color: app.config.routeMode == m
                                  ? Colors.white
                                  : EchTheme.inputText(t),
                              fontWeight: app.config.routeMode == m
                                  ? EchTheme.fwTitle
                                  : EchTheme.fwContent,
                              letterSpacing: EchTheme.letterSpacing)),
                    ),
                  ),
                ),
              ),
            ],
          ]),
        );
      },
    );
  }
}

// ===========================================================================
// 高级选项 + 自定义规则
// ===========================================================================

class _AdvancedGroup extends StatelessWidget {
  final bool rulesExpanded;
  final ValueChanged<bool> onRulesExpandedChanged;
  const _AdvancedGroup({
    required this.rulesExpanded,
    required this.onRulesExpandedChanged,
  });
  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final s = app.selected;
    final locked = app.isBusy; // 运行/启动/停止中锁定配置修改
    return _GroupCard(
      title: '高级选项',
      icon: Icons.tune_rounded,
      gradient: EchTheme.orangeGradient(),
      child: Column(children: [
        AppRow(
          label: 'ECH域名',
          child: _PresetEdit(
            s?.ech ?? 'cloudflare-ech.com',
            options: EchPresets.echDomains,
            enabled: !locked,
            onChanged: (v) => app.update((x) => x.ech = v),
          ),
        ),
        const SizedBox(height: 10),
        AppRow(
          label: 'DOH服务器',
          child: _PresetEdit(
            s?.dns ?? 'dns.alidns.com/dns-query',
            options: EchPresets.dnsServers,
            enabled: !locked,
            onChanged: (v) => app.update((x) => x.dns = v),
          ),
        ),
        const SizedBox(height: 10),
        // 分流模式运行中也可切换：switchRouteMode 内部 stop→start 自动生效。
        // 与「服务器配置运行中锁定」性质不同——后者是多字段、需保存、重启
        // 链路复杂；分流模式是单一枚举，一次切换即完整生效。
        AppRow(label: '分流模式', child: const _ModeSegment()),
        const SizedBox(height: 10),
        _RulesSection(
          expanded: rulesExpanded,
          locked: locked,
          onExpandedChanged: onRulesExpandedChanged,
        ),
      ]),
    );
  }
}

/// 带预设下拉的输入框
class _PresetEdit extends StatefulWidget {
  final String value;
  final List<PresetOption> options;
  final bool enabled;
  final ValueChanged<String> onChanged;
  const _PresetEdit(this.value,
      {required this.options, required this.enabled, required this.onChanged});

  @override
  State<_PresetEdit> createState() => _PresetEditState();
}

class _PresetEditState extends State<_PresetEdit> {
  OverlayEntry? _menu;

  @override
  void dispose() {
    _closeMenu();
    super.dispose();
  }

  void _closeMenu() {
    _menu?.remove();
    _menu = null;
  }

  // 无动画预设弹层：PopupMenuButton 的 Material scale/fade 动画在按钮旁
  // 表现为“弹出跳动”，这里用 Overlay 立即显示/关闭，列表零动画零跳动。
  void _toggleMenu() {
    if (!widget.enabled) return;
    if (_menu != null) {
      _closeMenu();
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final target = box.localToGlobal(Offset.zero) & box.size;
    final overlay = Overlay.of(context);
    final t = Theme.of(context);
    const panelW = 268.0;
    const itemH = 34.0;
    final count = widget.options.length.clamp(1, 12);
    final panelH = count * itemH + 16; // 上下各 8px 留白，弹层不再顶格紧凑
    final screen = MediaQuery.of(context).size;
    double left = target.right - panelW;
    if (left < 8) left = 8;
    double top = target.bottom + 4;
    if (top + panelH > screen.height - 8) top = target.top - panelH - 4;
    if (top < 8) top = 8;
    _menu = OverlayEntry(
      builder: (_) => Stack(children: [
        Positioned.fill(
          child: GestureDetector(
              behavior: HitTestBehavior.translucent, onTap: _closeMenu),
        ),
        Positioned(
          left: left,
          top: top,
          width: panelW,
          height: panelH,
          child: Material(
            color: EchTheme.card(t),
            elevation: 8,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(children: [
              for (final o in widget.options)
                InkWell(
                  onTap: () {
                    _closeMenu();
                    widget.onChanged(o.value);
                  },
                  child: SizedBox(
                    height: itemH,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(children: [
                        if (o.value == widget.value)
                          Icon(Icons.check_rounded,
                              size: 14, color: EchTheme.blue)
                        else
                          const SizedBox(width: 14),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(o.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 13,
                                  color: EchTheme.text(t))),
                        ),
                      ]),
                    ),
                  ),
                ),
            ]),
            ),
          ),
        ),
      ]),
    );
    overlay.insert(_menu!);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(children: [
      Expanded(
        child: AppTextField(widget.value,
            fontWeight: EchTheme.fwContent,
            enabled: widget.enabled,
            onChanged: widget.onChanged),
      ),
      const SizedBox(width: 4),
      SizedBox(
        width: 32,
        height: 30,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: _toggleMenu,
            borderRadius: BorderRadius.circular(8),
            hoverColor: widget.enabled ? EchTheme.hover(t) : Colors.transparent,
            child: Icon(Icons.format_list_bulleted,
                size: 16,
                color: widget.enabled
                    ? EchTheme.blue
                    : EchTheme.textMuted(t)),
          ),
        ),
      ),
    ]);
  }
}

class _RulesSection extends StatefulWidget {
  final bool expanded;
  final bool locked; // 运行中锁定：禁止添加/编辑/删除规则
  final ValueChanged<bool> onExpandedChanged;
  const _RulesSection(
      {required this.expanded,
      required this.locked,
      required this.onExpandedChanged});
  @override
  State<_RulesSection> createState() => _RulesSectionState();
}

class _RulesSectionState extends State<_RulesSection> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final t = Theme.of(context);
    final locked = widget.locked;
    final rules = app.customRules;
    final shadowed = shadowedRuleIds(rules);
    final filtered = _search.isEmpty
        ? rules
        : rules.where((r) {
            final label =
                RuleCategory.all.where((c) => c.value == r.target).firstOrNull
                    ?.label ??
                    '';
            return r.target.toLowerCase().contains(_search.toLowerCase()) ||
                label.contains(_search);
          }).toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () => widget.onExpandedChanged(!widget.expanded),
          borderRadius: BorderRadius.circular(6),
          child: Row(children: [
            Icon(widget.expanded ? Icons.expand_more : Icons.chevron_right, size: 17),
            Text('自定义分流规则',
                style: EchTheme.labelStyle(EchTheme.textSoft(t))),
            if (rules.isNotEmpty)
              Text(' ${rules.length} 条',
                  style: TextStyle(
                      fontSize: EchTheme.fsCaption,
                      fontWeight: EchTheme.fwContent,
                      color: EchTheme.textMuted(t))),
            if (shadowed.isNotEmpty)
              Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.warning_amber_rounded, size: 12, color: EchTheme.orange),
                Text(' ${shadowed.length} 条重复',
                    style: TextStyle(
                        fontSize: EchTheme.fsCaption,
                        fontWeight: EchTheme.fwContent,
                        color: EchTheme.orange)),
              ]),
            if (app.rulesDirty)
              Text('  待重启',
                  style: TextStyle(
                      fontSize: EchTheme.fsCaption,
                      fontWeight: EchTheme.fwContent,
                      color: EchTheme.red)),
            const Spacer(),
            AppTextButton('添加规则',
                icon: Icons.add,
                fontSize: EchTheme.fsTool,
                enabled: !locked,
                onPressed: () {
                  widget.onExpandedChanged(true);
                  app.addRule();
                }),
          ]),
        ),
      ),
      if (widget.expanded)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(children: [
            if (rules.length > 2)
              AppTextField(
                _search,
                monospace: false,
                hint: '搜索规则',
                enabled: !locked,
                onChanged: (v) => setState(() => _search = v),
              ),
            if (rules.length > 2 && filtered.isNotEmpty)
              const SizedBox(height: 6),
            if (filtered.isNotEmpty)
              SizedBox(
                height: (filtered.length.clamp(1, 2)) * 38.0,
                child: ListView(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  physics: filtered.length > 2
                      ? const ClampingScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  children: [
                    for (final r in filtered)
                      _RuleRow(r: r, isShadowed: shadowed.contains(r.id), locked: locked),
                  ],
                ),
              ),
            if (rules.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 4),
                child: Text('点右上角「添加规则」，选类型后填域名，或直接挑一个网站分类',
                    style: TextStyle(
                        fontSize: EchTheme.fsCaption,
                        fontWeight: EchTheme.fwContent,
                        color: EchTheme.textMuted(t))),
              ),
          ]),
        ),
    ]);
  }
}

class _RuleRow extends StatelessWidget {
  final CustomRule r;
  final bool isShadowed;
  final bool locked;
  const _RuleRow(
      {required this.r, required this.isShadowed, required this.locked});

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final t = Theme.of(context);
    return Container(
      height: 34,
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        color: EchTheme.inputBg(t),
      ),
      child: Row(children: [
        SizedBox(
          width: 92,
          child: _KindDropdown(r, app, locked),
        ),
        Expanded(
          child: r.kind == RuleKind.category
              ? _CategoryDropdown(r, app, locked)
              : AppTextField(
                  r.target,
                  enabled: !locked,
                  onChanged: (v) => app.updateRule(r.id, target: v),
                ),
        ),
        const SizedBox(width: 8),
        SizedBox(width: 84, child: _ActionDropdown(r, app, locked)),
        const SizedBox(width: 4),
        Material(
            type: MaterialType.transparency,
            child: IconButton(
              icon: const Icon(Icons.close, size: 16, color: EchTheme.red),
              visualDensity: VisualDensity.compact,
              onPressed:
                  locked ? null : () => app.removeRule(r.id),
            ),
          ),
      ]),
    );
  }
}

class _KindDropdown extends StatelessWidget {
  final CustomRule r;
  final AppState app;
  final bool locked;
  const _KindDropdown(this.r, this.app, this.locked);

  @override
  Widget build(BuildContext context) {
    return _ChipDropdown<RuleKind>(
      value: r.kind,
      items: [
        for (final k in RuleKind.values)
          DropdownMenuItem(value: k, child: Text(k.title)),
      ],
      enabled: !locked,
      onChanged: (v) {
        if (v != null) app.updateRule(r.id, kind: v);
      },
    );
  }
}

class _CategoryDropdown extends StatelessWidget {
  final CustomRule r;
  final AppState app;
  final bool locked;
  const _CategoryDropdown(this.r, this.app, this.locked);

  @override
  Widget build(BuildContext context) {
    return _ChipDropdown<String>(
      value: r.target.isEmpty ? RuleCategory.all.first.value : r.target,
      expanded: true,
      items: [
        for (final c in RuleCategory.all)
          DropdownMenuItem(value: c.value, child: Text(c.label)),
      ],
      enabled: !locked,
      onChanged: (v) {
        if (v != null) app.updateRule(r.id, target: v);
      },
    );
  }
}

class _ActionDropdown extends StatelessWidget {
  final CustomRule r;
  final AppState app;
  final bool locked;
  const _ActionDropdown(this.r, this.app, this.locked);

  @override
  Widget build(BuildContext context) {
    const values = [('direct', '直连'), ('proxy', '代理'), ('block', '拦截')];
    return _ChipDropdown<String>(
      value: r.action,
      items: [
        for (final (val, label) in values)
          DropdownMenuItem(value: val, child: Text(label)),
      ],
      enabled: !locked,
      onChanged: (v) {
        if (v != null) app.updateRule(r.id, action: v);
      },
    );
  }
}

/// 规则行用的胶囊下拉：浅底 + 圆角边框
class _ChipDropdown<T> extends StatelessWidget {
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final bool expanded;
  final bool enabled;
  const _ChipDropdown(
      {required this.value,
      required this.items,
      required this.onChanged,
      this.expanded = false,
      this.enabled = true});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        color: EchTheme.inputBg(t),
        border: Border.all(color: EchTheme.cardBorder(t)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: expanded,
          isDense: true,
          style: TextStyle(
              fontSize: EchTheme.fsBody,
              fontWeight: EchTheme.fwContent,
              color: enabled ? EchTheme.text(t) : EchTheme.textMuted(t)),
          icon: Icon(Icons.arrow_drop_down,
              size: 18, color: EchTheme.textMuted(t)),
          items: items,
          onChanged: enabled ? onChanged : null,
        ),
      ),
    );
  }
}

// ===========================================================================
// 底部操作 + 日志
// ===========================================================================

class _BottomBlock extends StatelessWidget {
  const _BottomBlock();
  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
            Row(children: [
            _ModernCheck(
                value: app.launchAtLogin,
                label: '开机启动',
                onChanged: (v) => app.setLaunchAtLogin(v),
              ),
            const SizedBox(width: 18),
            // 这一项在 TUN 开启时不再置灰：两者允许同时开着，TUN 优先级更高 ——
            // 生效期间自动系统代理只是「让位」（不接管系统代理），配置原样保留，
            // 关掉 TUN 后自动恢复接管。状态栏会标注「系统代理已让位」。
            _ModernCheck(
              value: app.config.autoSystemProxy,
              label: '自动设置系统代理',
              onChanged: (v) => app.setAutoSystemProxy(v),
            ),
            const SizedBox(width: 18),
            // 位置：放在「自动设置系统代理」之后而不是两者中间 ——
            // 两种放法下「系统代理 / TUN」本来就是相邻的，分组效果一样；
            // 区别只在谁在前。系统代理默认开启、零门槛、是主路径，TUN 需要
            // 管理员权限且会建虚拟网卡，属于进阶选项，按「常用 → 进阶」排；
            // 顺带也不动老用户对第 2 项位置的肌肉记忆。
            _ModernCheck(
              value: app.config.tunMode,
              label: '启用 TUN 模式',
              onChanged: (v) => app.setTunMode(v),
            ),
            const Spacer(),
            // 按钮可用性统一走 AppState.canStart / canStop：
            //   启动 —— 只有完全空闲（未运行、未启动中、未停止中）才可点；
            //   停止 —— 只在代理真正跑起来后可点；启动中/停止中都灰着。
            // 启动中的状态由左侧状态灯（黄）+「启动中…」文案表达，不靠按钮高亮。
            AppButton('启动代理',
                gradient: EchTheme.blueGradient(),
                minWidth: 120,
                height: 36,
                fontSize: EchTheme.fsAction,
                enabled: app.canStart,
                onPressed: app.start),
            const SizedBox(width: 8),
            AppButton('停止代理',
                gradient: EchTheme.redGradient(),
                minWidth: 120,
                height: 36,
                fontSize: EchTheme.fsAction,
                enabled: app.canStop,
                onPressed: () => app.stop()),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                  color: _statusColor(context, app),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                        color: _statusColor(context, app).withValues(alpha: 0.5),
                        blurRadius: 6,
                        spreadRadius: 1),
                  ]),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(app.statusText,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: EchTheme.fsSmall,
                      fontWeight: EchTheme.fwInput,
                      letterSpacing: EchTheme.letterSpacing,
                      color: EchTheme.textSoft(Theme.of(context)))),
            ),
            Text(_checkLabel(app),
                style: TextStyle(
                    fontSize: EchTheme.fsCaption,
                    fontWeight: EchTheme.fwContent,
                    letterSpacing: EchTheme.letterSpacing,
                    color: EchTheme.textMuted(Theme.of(context)))),
          ]),
          const SizedBox(height: 10),
          _LogHeader(),
          // 日志区：Expanded 吃掉窗口多余高度（拉大窗口 → 日志增高，底边距固定）；
          // 不设最小高度，窗口高度由 _syncHeight 保证，避免同步瞬间被压缩产生 overflow 黄条
          if (AppState.instance.config.logVisible)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: LayoutBuilder(
                    builder: (context, cons) {
                      // 视口吃满 Expanded（无死区）：k = 向下取整的行数，
                      // 每行高 = 可用高度/k（≥ lineHeight），行距随窗口伸缩；
                      // 任意滚动 / 任意窗口高度都只见整 k 行，且无半行、无底部空白带
                      final available = cons.maxHeight;
                      var k = (available / _LogList.lineHeight).floor();
                      if (k < 1) {
                        k = 1;
                        final row = available < _LogList.lineHeight
                            ? available
                            : _LogList.lineHeight;
                        return SizedBox(
                          width: double.infinity,
                          height: available,
                          child: _LogList(row: row),
                        );
                      }
                      final row = available / k;
                      return SizedBox(
                        width: double.infinity,
                        height: available,
                        child: _LogList(row: row),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        );
  }

  Color _statusColor(BuildContext context, AppState app) {
    // 对齐 Mac statusDotColor：先看运行状态，未运行一律橙（即使自检通过过）；
    // 运行中才用自检结果着色。
    if (app.isStopping) return EchTheme.cloud; // 停止中：灰，和「已停止」同色系
    if (app.isStarting) return EchTheme.yellow;
    if (!app.isRunning) return EchTheme.cloud;
    switch (app.checkState.kind) {
      case CheckStateKind.running:
        return EchTheme.yellow;
      case CheckStateKind.ok:
        return EchTheme.green;
      case CheckStateKind.failed:
        return EchTheme.red;
      default:
        return EchTheme.orange; // idle → 已运行但还没自检结果 → 橙
    }
  }

  String _checkLabel(AppState app) {
    if (app.isStopping) return '· 停止中…';
    if (app.isStarting) return '· 启动中…';
    switch (app.checkState.kind) {
      case CheckStateKind.running:
        return '· 检测中…';
      case CheckStateKind.ok:
        return '· 自检通过';
      case CheckStateKind.failed:
        return '· 自检未通过';
      default:
        return '· 待检测';
    }
  }
}

/// 日志区头部
class _LogHeader extends StatelessWidget {
  const _LogHeader();
  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final isCheckOnly = app.config.logLevel == LogLevel.checkOnly;
    final title = isCheckOnly ? '自检记录' : '运行日志';
    return Row(children: [
      Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () {
            app.config.logVisible = !app.config.logVisible;
            app.persist();
            app.refresh();
          },
          borderRadius: BorderRadius.circular(6),
          child: Row(children: [
            Icon(app.config.logVisible ? Icons.expand_more : Icons.chevron_right,
                size: 15),
            Text(title,
                style: EchTheme.labelStyle(EchTheme.inputText(Theme.of(context)))),
          ]),
        ),
      ),
      if (app.config.logVisible) ...[
        const Spacer(),
        AppDropdown<LogLevel>(
          width: 96,
          value: app.config.logLevel,
          items: LogLevel.values,
          labelOf: (l) => l.title,
          fontSize: EchTheme.fsLabel - 0.5,
          onChanged: (v) async {
            app.config.logLevel = v;
            await LogService.instance.loadView(v); // 切换级别 → 读对应日志文件内容
            app.persist();
            app.refresh();
          },
        ),
        const SizedBox(width: 8),
        AppTextButton('日志文件',
            icon: Icons.folder_open,
            fontSize: EchTheme.fsTool - 0.5,
            onPressed: () =>
                LogService.instance.openLogFile(app.config.logLevel)),
        const SizedBox(width: 8),
        AppTextButton('清空',
          icon: Icons.delete_outline,
          fontSize: EchTheme.fsTool - 0.5,
          onPressed: app.clearLog),
      ],
    ]);
  }
}

class _LogList extends StatefulWidget {
  // [row] = 每行实际高度（≥ lineHeight），由外层按「可用高度/k 行」算出，行距随窗口伸缩
  final double row;
  const _LogList({required this.row});
  // 行内文字框最小高度 = fsLog × 1.25（字形安全、不贴边）
  static const double lineHeight = EchTheme.fsLog * 1.25;
  @override
  State<_LogList> createState() => _LogListState();
}

class _LogListState extends State<_LogList> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final lines = LogService.instance.displayedLines(app.config.logLevel);
    return CardBox(
      radius: 9, // 与其他文本框圆角一致
      padding: const EdgeInsets.all(8),
      child: ListView.builder(
        controller: _scroll,
        itemExtent: widget.row,
        itemCount: lines.length,
        itemBuilder: (c, i) {
          if (i == lines.length - 1) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_scroll.hasClients) {
                _scroll.jumpTo(_scroll.position.maxScrollExtent);
              }
            });
          }
          // 文字框随行高居中：行距随窗口伸缩，多余空间全部分给行与行之间的呼吸，
          // 不落到视口下方死区
          final padV = (widget.row - _LogList.lineHeight) / 2;
          return Padding(
            padding: EdgeInsets.symmetric(
                vertical: padV < 0 ? 0 : padV),
            child: Text(
              lines[i],
              style: TextStyle(
                  fontSize: EchTheme.fsLog,
                  fontFamily: EchTheme.monoFont,
                  fontWeight: EchTheme.fwContent,
                  height: 1.25, // 行距紧凑充足，行与行、末行与视口底边不挨挤
                  letterSpacing: EchTheme.letterSpacing,
                  color: _lineColor(lines[i], Theme.of(c))),
            ),
          );
        },
      ),
    );
  }

  Color _lineColor(String line, ThemeData t) {
    final lower = line.toLowerCase();
    if (lower.contains('失败') || lower.contains('错误') || lower.contains('error')) {
      return EchTheme.red;
    }
    if (line.contains('[系统代理]')) return EchTheme.orange;
    if (line.contains('[系统]')) return EchTheme.blue;
    return EchTheme.textSoft(t);
  }
}

/// 现代开关风格勾选：彩色圆形勾 + 标签
class _ModernCheck extends StatelessWidget {
  final bool value;
  final String label;
  final ValueChanged<bool> onChanged;
  // 曾经有过 enabled 参数（TUN 开启时把「自动设置系统代理」置灰）。
  // 改成「可共存、TUN 优先让位」后不再需要置灰，已移除。
  const _ModernCheck(
      {required this.value, required this.label, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(6),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: value ? EchTheme.blueGradient() : null,
            border: value
                ? null
                : Border.all(color: EchTheme.cardBorder(t), width: 1.5),
            boxShadow: value
                ? [
                    BoxShadow(
                        color: EchTheme.blue.withValues(alpha: 0.35),
                        blurRadius: 5)
                  ]
                : [],
          ),
          child: value
              ? const Icon(Icons.check, size: 12, color: Colors.white)
              : null,
        ),
        const SizedBox(width: 7),
        Text(label,
            style: TextStyle(
                fontSize: EchTheme.fsBody,
                fontWeight: EchTheme.fwContent,
                color: EchTheme.textSoft(t))),
        ]),
      ),
    );
  }
}


/// 下载更新进度面板（镜像 Mac showDownloadProgress：label + 进度条 + 取消）。
/// 随 AppState 刷新进度；`isDownloadingUpdate` 变 false（成功/失败/取消）
/// 时自动关闭，由 home_page 继续弹结果提示。
class _UpdateProgressDialog extends StatefulWidget {
  final AppState app;
  const _UpdateProgressDialog({required this.app});

  @override
  State<_UpdateProgressDialog> createState() => _UpdateProgressDialogState();
}

class _UpdateProgressDialogState extends State<_UpdateProgressDialog> {
  @override
  void initState() {
    super.initState();
    widget.app.addListener(_maybeClose);
  }

  @override
  void dispose() {
    widget.app.removeListener(_maybeClose);
    super.dispose();
  }

  void _maybeClose() {
    if (!widget.app.isDownloadingUpdate && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return AnimatedBuilder(
      animation: widget.app,
      builder: (context, _) {
        final app = widget.app;
        final p = app.updateProgress;
        final name = app.updateInfo?.assetName ?? '新版本';
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(horizontal: 40),
          child: Container(
            width: 360,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: EchTheme.card(t),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: EchTheme.cardBorder(t)),
              boxShadow: EchTheme.cardShadow(t),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('正在下载更新',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: EchTheme.fwTitle,
                        letterSpacing: EchTheme.letterSpacing,
                        color: EchTheme.titleText(t))),
                const SizedBox(height: 14),
                Text('正在下载 $name…',
                    style: TextStyle(
                        fontSize: EchTheme.fsSmall,
                        fontWeight: EchTheme.fwContent,
                        color: EchTheme.textMuted(t))),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (p > 0 && p < 1) ? p : null,
                    minHeight: 8,
                    backgroundColor: EchTheme.isDark(t)
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.black.withValues(alpha: 0.06),
                    color: EchTheme.blue,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  (p > 0 && p < 1)
                      ? '${(p * 100).toStringAsFixed(0)}%'
                      : '正在连接…',
                  style: TextStyle(
                      fontSize: EchTheme.fsSmall,
                      fontWeight: EchTheme.fwContent,
                      color: EchTheme.textMuted(t)),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    const Spacer(),
                    SizedBox(
                      width: 120,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: EchTheme.isDark(t)
                              ? Colors.white.withValues(alpha: 0.10)
                              : Colors.black.withValues(alpha: 0.06),
                          foregroundColor: EchTheme.titleText(t),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          textStyle: const TextStyle(
                              fontSize: EchTheme.fsBody,
                              fontWeight: EchTheme.fwContent,
                              letterSpacing: EchTheme.letterSpacing),
                        ),
                        onPressed: () => app.cancelDownloadUpdate(),
                        child: const Text('取消'),
                      ),
                    ),
                    const Spacer(),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
