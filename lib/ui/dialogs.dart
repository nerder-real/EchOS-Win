// 分享导出（多选）、WebDAV 设置、导入/备份/还原等对话框（对齐 Wails/Mac 行为）。
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/config.dart';
import '../services/app_state.dart';
import '../services/platform_drivers.dart';
import '../services/share_backup.dart';
import '../services/updater.dart';
import 'theme.dart';
import 'widgets/app_text_field.dart';

/// 分享导出：多选服务器 → 保存 json 文件
Future<void> showShareDialog(BuildContext context) async {
  final app = AppState.instance;
  final savable = app.config.servers
      .where((s) => app.isServerSaved(s.id))
      .toList();
  if (savable.isEmpty) {
    _alert(context, '导出失败', '没有已保存的服务器可导出');
    return;
  }

  final sel = <String>{for (final s in savable) s.id};
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setSt) => EchDialog(
        title: '选择并导出服务器',
        content: SizedBox(
          width: 380,
          height: 260,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('已选 ${sel.length} / ${savable.length}',
                  style: TextStyle(
                      fontSize: EchTheme.fsSmall,
                      fontWeight: EchTheme.fwContent,
                      color: EchTheme.textMuted(Theme.of(c)))),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: savable.length,
                  itemBuilder: (c, i) {
                    final s = savable[i];
                    final checked = sel.contains(s.id);
                    return CheckboxListTile(
                      dense: true,
                      value: checked,
                      title: Text(s.name.isEmpty ? '未命名 ${i + 1}' : s.name,
                          style: TextStyle(
                              fontSize: EchTheme.fsBody,
                              fontWeight: EchTheme.fwContent)),
                      subtitle: Text(
                          '${s.server.trim()} :${s.serverPort}',
                          style: TextStyle(
                              fontSize: EchTheme.fsCaption,
                              fontWeight: EchTheme.fwContent,
                              fontFamily: EchTheme.monoFont)),
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: (v) {
                        setSt(() {
                          if (v == true) {
                            sel.add(s.id);
                          } else {
                            sel.remove(s.id);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          EchDialog.cancel(c, onPressed: () => Navigator.pop(c)),
          EchDialog.confirm(c,
              label: '导出…', onPressed: () => Navigator.pop(c, true)),
        ],
      ),
    ),
  );
  if (confirmed != true || sel.isEmpty) return;

  final data = ShareBackup.buildServersJson(sel.toList());
  final r = await _saveFile('EchOS-servers.json', ['json'], data.json);
  if (!r.ok) {
    if (r.err == null) return; // 用户取消
    if (!context.mounted) return;
    _alert(context, '导出失败', r.err!);
    return;
  }
  app.log('已导出 ${data.count} 个服务器');
  if (!context.mounted) return;
  _alert(context, '导出成功', '已导出 ${data.count} 台服务器');
}

/// 导入服务器（选 json 文件）
Future<void> showImportDialog(BuildContext context) async {
  final path = await _openFile(['json']);
  if (path == null) return;
  final msg = await ShareBackup.importServers(path);
  if (!context.mounted) return;
  if (msg == null) {
    _alert(context, '导入失败', '不是有效的服务器分享文件');
    return;
  }
  _alert(context, '导入结果', msg);
}

/// 本地备份：保存整份配置
Future<void> showBackupDialog(BuildContext context) async {
  // 4-2：与 Mac 一致，文件名带时间戳避免覆盖
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp = '${now.year}${two(now.month)}${two(now.day)}-'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  final r = await _saveFile(
      'EchOS-备份-$stamp.json', ['json'], ShareBackup.buildConfigJson());
  if (!r.ok) {
    if (r.err == null) return; // 用户取消
    if (!context.mounted) return;
    _alert(context, '本地备份失败', r.err!);
    return;
  }
  if (!context.mounted) return;
  _alert(context, '本地备份成功', '已备份到本机');
}

/// 本地还原：选备份文件并确认
Future<void> showRestoreDialog(BuildContext context) async {
  final path = await _openFile(['json']);
  if (path == null) return;
  if (!context.mounted) return;
  final ok = await _confirm(
      context, '从本地文件还原配置？', '当前全部配置都会被这份备份覆盖。\n代理运行中会先停止。');
  if (!ok) return;
  final err = await ShareBackup.restoreConfigLocal(path);
  if (!context.mounted) return;
  _alert(context, err == null ? '本地还原成功' : '本地还原失败', err ?? '配置已还原');
}

/// WebDAV 设置弹窗
Future<void> showWebDAVSettings(BuildContext context) async {
  final app = AppState.instance;
  final w = app.config.webdav ?? WebDAVConfig();

  var url = w.url;
  var username = w.username;
  var password = '';
  var directory = w.directory;

  // 已保存过的服务器，回显存储的密码（掩码展示），方便直接保存
  final existing = await SecretStore.read(w.username);
  if (existing != null) password = existing;
  if (!context.mounted) return;

  final action = await showDialog<String>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setSt) => EchDialog(
        title: 'WebDAV 设置',
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppTextField(
                url,
                hint: '服务器地址',
                monospace: false,
                onChanged: (v) => setSt(() => url = v),
              ),
              const SizedBox(height: 10),
              AppTextField(
                username,
                hint: '用户名',
                monospace: false,
                onChanged: (v) => setSt(() => username = v),
              ),
              const SizedBox(height: 10),
              AppTextField(
                password,
                hint: '密码（存系统凭据）',
                monospace: false,
                obscure: true,
                onChanged: (v) => setSt(() => password = v),
              ),
              const SizedBox(height: 10),
              AppTextField(
                directory,
                hint: '备份目录（留空默认 EchOS_Backup）',
                monospace: false,
                onChanged: (v) => setSt(() => directory = v),
              ),
            ],
          ),
        ),
        actions: [
          if (app.config.webdav != null)
            EchDialog.confirm(c,
                label: '移除',
                danger: true,
                onPressed: () => Navigator.pop(c, 'delete')),
          EchDialog.cancel(c, onPressed: () => Navigator.pop(c)),
          Builder(builder: (bc) {
            final canSave = url.trim().isNotEmpty;
            return EchDialog.confirm(c,
                label: '保存',
                onPressed: canSave ? () => Navigator.pop(c, 'save') : null);
          }),
        ],
      ),
    ),
  );
  if (action == 'delete') {
    if (!context.mounted) return;
    await showWebDAVRemoveServer(context);
    return;
  }
  if (action != 'save') return;

  final err = await ShareBackup.saveWebDAVConfig(
    url.trim(),
    username.trim(),
    password,
    directory.trim(),
  );
  if (!context.mounted) return;
  _alert(context, err == null ? 'WebDAV 设置已保存' : 'WebDAV 设置', err ?? '已保存');
}

/// WebDAV 备份 / 还原（无本地文件，直接调服务）
Future<void> showWebDAVBackup(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => EchDialog(
      title: '备份到远程 WebDAV？',
      message: '将把当前配置上传到 WebDAV 服务器，覆盖远程已有的备份。',
      actions: [
        EchDialog.cancel(c, onPressed: () => Navigator.pop(c, false)),
        EchDialog.confirm(c,
            label: '备份',
            onPressed: () => Navigator.pop(c, true)),
      ],
    ),
  );
  if (ok != true) return;
  final err = await ShareBackup.backupToWebDAV();
  if (!context.mounted) return;
  _alert(context, err == null ? 'WebDAV 备份' : 'WebDAV 备份失败',
      err ?? '已备份到 WebDAV');
}

Future<void> showWebDAVRestore(BuildContext context) async {
  final ok = await _confirm(
      context, '从 WebDAV 还原配置？', '当前全部配置都会被 WebDAV 上的备份覆盖。\n代理运行中会先停止。');
  if (!ok) return;
  final err = await ShareBackup.restoreFromWebDAV();
  if (!context.mounted) return;
  _alert(context, err == null ? 'WebDAV 还原' : 'WebDAV 还原失败',
      err ?? '已从 WebDAV 还原');
}

/// 删除 WebDAV 服务器上的备份文件
Future<void> showWebDAVDeleteBackup(BuildContext context) async {
  final ok = await _dangerConfirm(
      context,
      '删除远程 WebDAV 备份？',
      '将删除 WebDAV 服务器上的备份文件，本地配置不受影响。\n备份文件不存在时视为已删除。');
  if (!ok) return;
  final err = await ShareBackup.deleteWebDAVBackup();
  if (!context.mounted) return;
  _alert(context, err == null ? '删除远程 WebDAV 备份' : '删除远程 WebDAV 备份失败',
      err ?? '已删除 WebDAV 上的备份');
}

/// 删除已保存的 WebDAV 服务器（含本地凭据）
Future<void> showWebDAVRemoveServer(BuildContext context) async {
  final app = AppState.instance;
  if (app.config.webdav == null) {
    _alert(context, 'WebDAV 设置', '尚未设置 WebDAV 服务器');
    return;
  }
  final ok = await _dangerConfirm(
      context, '移除 WebDAV 服务器？', '将移除已保存的 WebDAV 服务器设置，并清除存储的密码，不可撤销。',
      actionLabel: '移除');
  if (!ok) return;
  await ShareBackup.removeWebDAVServer();
  if (!context.mounted) return;
  _alert(context, 'WebDAV 设置', '已移除 WebDAV 服务器');
}

// ---------------------------------------------------------------------------
// 底层：文件对话框 + 提示
// ---------------------------------------------------------------------------

/// 弹出「另存为」对话框并落盘。
/// file_picker 12 起 saveFile 必须直接给出内容、由插件负责写文件（Windows 实现里
/// 就是 writeAsBytes），不再返回路径让调用方自己写；所以内容要先在调用方生成。
/// 用户取消时 ok=false 且 err=null；写入出错时 err 为失败原因。
Future<({bool ok, String? err})> _saveFile(
    String fileName, List<String> extensions, String content) async {
  try {
    final uri = await FilePicker.saveFile(
      dialogTitle: '保存文件',
      fileName: fileName,
      bytes: utf8.encode(content),
      type: FileType.custom,
      allowedExtensions: extensions,
    );
    return (ok: uri != null, err: null);
  } catch (e) {
    return (ok: false, err: '未能写入文件：$e');
  }
}

/// 弹出「打开」对话框，返回所选文件路径；用户取消返回 null。
Future<String?> _openFile(List<String> extensions) async {
  final f = await FilePicker.pickFile(
    dialogTitle: '选择文件',
    type: FileType.custom,
    allowedExtensions: extensions,
  );
  return f?.path;
}

Future<bool> _confirm(BuildContext context, String title, String message) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => EchDialog(
      title: title,
      message: message,
      actions: [
        EchDialog.cancel(c, onPressed: () => Navigator.pop(c, false)),
        EchDialog.confirm(c,
            label: '还原',
            danger: true,
            onPressed: () => Navigator.pop(c, true)),
      ],
    ),
  );
  return r == true;
}

/// 危险操作二次确认，动作按钮文案可定制（默认「删除」）。
Future<bool> _dangerConfirm(
    BuildContext context, String title, String message,
    {String actionLabel = '删除'}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => EchDialog(
      title: title,
      message: message,
      actions: [
        EchDialog.cancel(c, onPressed: () => Navigator.pop(c, false)),
        EchDialog.confirm(c,
            label: actionLabel,
            danger: true,
            onPressed: () => Navigator.pop(c, true)),
      ],
    ),
  );
  return r == true;
}

void _alert(BuildContext context, String title, String message) {
  showDialog(
    context: context,
    builder: (c) => EchDialog(
      title: title,
      message: message,
      actions: [
        EchDialog.confirm(c, label: '好', onPressed: () => Navigator.pop(c)),
      ],
    ),
  );
}

/// 发现新版本确认框（镜像 Mac promptUpdateDialog）：
/// 左侧 App 图标 +「EchOS 版本：x」标题 +「发现新版本 vX」正文，
/// 按钮 = 以后再说 / 下载并更新。
Future<void> showUpdatePromptDialog(
    BuildContext context, ReleaseInfo info) async {
  final app = AppState.instance;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => EchDialog(
      icon: const AssetImage('assets/icon.png'),
      title: 'EchOS 版本：${app.currentAppVersion}',
      message: '发现新版本 ${info.tag}',
      actions: [
        EchDialog.cancel(c, label: '以后再说', onPressed: () {
          Navigator.pop(c);
          app.dismissPendingUpdate();
        }),
        EchDialog.confirm(c,
            label: '下载并更新',
            onPressed: () {
              Navigator.pop(c);
              app.dismissPendingUpdate();
              app.downloadUpdate();
            }),
      ],
    ),
  );
}

/// 统一的玻璃风格对话框：圆角大卡片 + 柔和阴影，与主界面 CardBox 同语言。
/// 传 icon 时（检查更新等，镜像 Mac NSAlert 左侧 App 图标）改为
/// 「图标 + 标题/正文」左对齐布局；否则保持标题居中。
class EchDialog extends StatelessWidget {
  final String title;
  final String? message;
  final Widget? content;
  final List<Widget> actions;
  final ImageProvider? icon;
  const EchDialog({
    super.key,
    required this.title,
    this.message,
    this.content,
    required this.actions,
    this.icon,
  });

  /// 左侧浅灰取消按钮。
  static Widget cancel(BuildContext context,
      {String label = '取消', VoidCallback? onPressed}) {
    final t = Theme.of(context);
    return _EchDialogButton(
      label: label,
      onPressed: onPressed,
      bg: EchTheme.isDark(t)
          ? Colors.white.withValues(alpha: 0.10)
          : Colors.black.withValues(alpha: 0.06),
      fg: EchTheme.titleText(t),
    );
  }

  /// 右侧品牌蓝（或危险红色）确认按钮。
  static Widget confirm(BuildContext context,
      {required String label, VoidCallback? onPressed, bool danger = false}) {
    return _EchDialogButton(
      label: label,
      onPressed: onPressed,
      bg: danger ? EchTheme.red : EchTheme.blue,
      fg: Colors.white,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40),
      child: Container(
        width: 350,
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
        decoration: BoxDecoration(
          color: EchTheme.card(t),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: EchTheme.cardBorder(t)),
          boxShadow: EchTheme.cardShadow(t),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
if (icon != null) ...[
              // LOGO 顶部居中（镜像 macOS NSAlert applicationIconImage 样式）
              Center(
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: Image(image: icon!, filterQuality: FilterQuality.high),
                ),
              ),
              const SizedBox(height: 14),
              Center(
                child: Text(title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: EchTheme.fsGroupTitle,
                        fontWeight: EchTheme.fwTitle,
                        letterSpacing: EchTheme.letterSpacing,
                        color: EchTheme.titleText(t))),
              ),
              if (message != null) ...[
                const SizedBox(height: 8),
                Center(
                  child: Text(message!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: EchTheme.fsSmall,
                          fontWeight: EchTheme.fwContent,
                          letterSpacing: EchTheme.letterSpacing,
                          height: 1.6,
                          color: EchTheme.textMuted(t))),
                ),
              ],
              if (content != null) ...[
                const SizedBox(height: 12),
                content!,
              ],
            ] else ...[
              Center(
                child: Text(title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: EchTheme.fwTitle,
                        letterSpacing: EchTheme.letterSpacing,
                        color: EchTheme.titleText(t))),
              ),
              if (message != null) ...[
                const SizedBox(height: 16),
                Center(
                  child: Text(message!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: EchTheme.fsSmall,
                          fontWeight: EchTheme.fwContent,
                          letterSpacing: EchTheme.letterSpacing,
                          height: 1.6,
                          color: EchTheme.textMuted(t))),
                ),
              ],
              if (content != null) ...[
                const SizedBox(height: 16),
                content!,
              ],
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(child: actions[i]),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EchDialogButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final Color bg;
  final Color fg;
  const _EchDialogButton({
    required this.label,
    this.onPressed,
    required this.bg,
    required this.fg,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(label,
                style: TextStyle(
                    fontSize: EchTheme.fsTool,
                    fontWeight: EchTheme.fwContent,
                    color: fg,
                    letterSpacing: EchTheme.letterSpacing,
                    height: 1.3)),
          ),
        ),
      ),
    );
  }
}
