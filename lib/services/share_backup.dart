// 分享/导入 + 本地备份/还原 + WebDAV 备份（镜像 Mac ServerShare / WebDAVClient）
import 'dart:convert';
import 'dart:io';

import '../models/config.dart';
import 'app_state.dart';
import 'platform_drivers.dart';

class ServerShareFile {
  static const format = 'echos-servers';
  final List<ServerConfig> servers;
  ServerShareFile(this.servers);

  Map<String, dynamic> toJson() => {
        'format': format,
        'version': 1,
        'servers': servers.map((s) => s.toJson()).toList(),
      };

  static ServerShareFile? fromJson(Map<String, dynamic> j) {
    if (j['format'] != format) return null;
    final list = (j['servers'] as List?) ?? [];
    return ServerShareFile(
        list.map((e) => ServerConfig.fromJson(e as Map<String, dynamic>)).toList());
  }
}

/// WebDAV 客户端操作结果：成功返回 null；失败返回可展示的中文原因。
/// 对齐 Mac 的 describeWebDAVError 分类（认证失败 / 网络不通 / 服务器问题 / 其他）。
class WebDAVError {
  String message;
  WebDAVError(this.message);
}

class WebDAVClient {
  static const defaultDirectory = 'EchOS_Backup';
  static const fileName = 'EchOS-config.json';

  static String? endpoint(String raw, String directory) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    if (t.toLowerCase().endsWith('.json')) return t;
    try {
      final base = Uri.parse(t.endsWith('/') ? t : '$t/');
      final dir = directory.trim().isEmpty ? defaultDirectory : directory.trim();
      // 逐段 appendPath，保证各段都被正确编码、且不产生双斜杠。
      var url = base;
      for (final seg in dir.split('/').where((s) => s.isNotEmpty)) {
        url = url.resolve('${Uri.encodeComponent(seg)}/');
      }
      return url.resolve(fileName).toString();
    } catch (_) {
      return null;
    }
  }

  static Future<WebDAVError?> upload(
      String url, String username, String password, String body) async {
    final err = await _mkcol(url, username, password);
    if (err != null) return err;
    try {
      final req = HttpClient().putUrl(Uri.parse(url));
      final r = await req;
      r.headers.contentType = ContentType.json;
      _auth(r, username, password);
      r.write(body);
      final resp = await r.close();
      return _statusError(resp.statusCode);
    } catch (_) {
      return WebDAVError('网络不通：无法连接到服务器（检查网络或地址）');
    }
  }

  /// 逐级 MKCOL 创建目标目录。目录已存在（405）或父级不存在重试时容忍；
  /// 返回 null 表示目录可用（已存在或创建成功）。
  static Future<WebDAVError?> _mkcol(
      String fileUrl, String username, String password) async {
    final u = Uri.parse(fileUrl);
    try {
      final client = HttpClient();
      var path = u.path;
      final parts = path.split('/').where((s) => s.isNotEmpty).toList();
      if (parts.isEmpty || parts.length < 2) return null; // 根目录或只有文件名
      parts.removeLast(); // 去掉文件名，剩下各级目录
      var acc = <String>[];
      for (final seg in parts) {
        acc.add(seg);
        final dirUrl = u.replace(path: '/${acc.join('/')}/').toString();
        final err = await _mkcolOne(client, dirUrl, username, password);
        if (err != null) return err;
      }
      return null;
    } catch (_) {
      return WebDAVError('网络不通：无法连接到服务器（检查网络或地址）');
    }
  }

  static Future<WebDAVError?> _mkcolOne(HttpClient client, String url,
      String username, String password) async {
    try {
      final req = await client.openUrl('MKCOL', Uri.parse(url));
      req.contentLength = 0;
      _auth(req, username, password);
      final resp = await req.close();
      final code = resp.statusCode;
      if (code >= 200 && code < 300) return null;
      // 405 = 目录已存在（或服务器不支持 MKCOL），视为成功继续。
      if (code == 405 || code == 301 || code == 409) return null;
      // 404 = 父目录尚未创建，也容忍（继续上传时客户端可能仍有问题，但至少不因 MKCOL 中断）。
      if (code == 404) return null;
      return _statusError(code);
    } catch (_) {
      return WebDAVError('网络不通：无法连接到服务器（检查网络或地址）');
    }
  }

  static Future<String?> download(
      String url, String username, String password, {WebDAVError? outErr}) async {
    try {
      final req = HttpClient().getUrl(Uri.parse(url));
      final r = await req;
      _auth(r, username, password);
      final resp = await r.close();
      final err = _statusError(resp.statusCode);
      if (err != null) {
        if (outErr != null) outErr.message = err.message;
        return null;
      }
      return await resp.transform(utf8.decoder).join();
    } catch (_) {
      if (outErr != null) {
        outErr.message = '网络不通：无法连接到服务器（检查网络或地址）';
      }
      return null;
    }
  }

  /// 删除远端备份文件（HTTP DELETE）。404 视为已删除。
  static Future<WebDAVError?> delete(
      String url, String username, String password) async {
    try {
      final req = HttpClient().deleteUrl(Uri.parse(url));
      final r = await req;
      _auth(r, username, password);
      final resp = await r.close();
      if (resp.statusCode == 404) return null;
      return _statusError(resp.statusCode);
    } catch (_) {
      return WebDAVError('网络不通：无法连接到服务器（检查网络或地址）');
    }
  }

  static void _auth(HttpClientRequest r, String username, String password) {
    final auth = base64Encode(utf8.encode('$username:$password'));
    r.headers.set(HttpHeaders.authorizationHeader, 'Basic $auth');
  }

  /// 按 HTTP 状态分类成可读文案；2xx 返回 null（成功）。
  static WebDAVError? _statusError(int code) {
    if (code >= 200 && code < 300) return null;
    switch (code) {
      case 401:
      case 403:
        return WebDAVError('认证失败：用户名 / 密码不正确，或服务器要求登录');
      case 404:
        return WebDAVError('服务器问题：文件或目录不存在（检查地址与目录）');
      case 405:
        return WebDAVError('服务器问题：不支持写入，可能不是 WebDAV 服务');
      case 507:
        return WebDAVError('服务器问题：存储空间不足');
      default:
        return WebDAVError('服务器问题：返回 HTTP $code');
    }
  }
}

/// 分享/导入/备份/还原的编排（由 UI 调用）
class ShareBackup {
  static AppState get _app => AppState.instance;

  /// 生成服务器分享文件的 JSON 文本。
  /// file_picker 12 起落盘由文件对话框负责（saveFile 必须传入内容本身），
  /// 所以这里只做序列化，返回 json 文本与实际导出的条数。
  static ({String json, int count}) buildServersJson(List<String> ids) {
    final saved = _app.config.servers
        .where((s) => ids.contains(s.id) && _app.isServerSaved(s.id))
        .toList();
    final enc = const JsonEncoder.withIndent('  ');
    return (
      json: enc.convert(ServerShareFile(saved).toJson()),
      count: saved.length,
    );
  }

  /// 导入服务器（对齐 Mac importServers 逻辑）
  static Future<String?> importServers(String path) async {
    try {
      final j = jsonDecode(File(path).readAsStringSync());
      if (j is! Map<String, dynamic>) return null;
      final file = ServerShareFile.fromJson(j);
      if (file == null) return null;

      final savedNames = _app.config.servers
          .where((s) => _app.isServerSaved(s.id))
          .map((s) => s.name.trim())
          .toSet();
      var imported = 0, skippedInvalid = 0, skippedDup = 0, renamed = 0;
      for (var s in file.servers) {
        if (s.validate() != null) {
          skippedInvalid++;
          continue;
        }
        final name = s.name.trim();
        final dup = _app.config.servers.firstWhere(
            (x) =>
                x.name.trim() == name &&
                x.server.trim() == s.server.trim() &&
                x.serverPort == s.serverPort,
            orElse: () => ServerConfig(name: ''));
        if (dup.name.isNotEmpty) {
          skippedDup++;
          continue;
        }
        if (savedNames.contains(name)) {
          final nn = _availableName(name, savedNames);
          s.name = nn;
          renamed++;
        }
        final ns = ServerConfig.fromJson(s.toJson())..id = _newUuid();
        _app.config.servers.add(ns);
        _app.markSaved(ns.id, ns);
        savedNames.add(ns.name.trim());
        imported++;
      }
      // 清理未保存空壳
      final drafts =
          _app.config.servers.where((s) => !_app.isServerSaved(s.id)).toList();
      for (final d in drafts) {
        _app.config.servers.removeWhere((s) => s.id == d.id);
      }
      if (_app.config.selectedID == null ||
          !_app.config.servers.any((s) => s.id == _app.config.selectedID)) {
        _app.config.selectedID =
            _app.config.servers.isEmpty ? null : _app.config.servers.first.id;
      }
      _app.persist();
      final parts = <String>['已导入 $imported 个服务器'];
      if (skippedInvalid > 0) parts.add('跳过无效 $skippedInvalid');
      if (skippedDup > 0) parts.add('跳过重复 $skippedDup');
      if (renamed > 0) parts.add('自动改名 $renamed');
      return parts.join('；');
    } catch (_) {
      return null;
    }
  }

  /// 本地备份（整份配置）：只生成 JSON 文本，落盘交给文件对话框
  static String buildConfigJson() =>
      const JsonEncoder.withIndent('  ').convert(_app.cleanConfig.toJson());

  /// 保存 WebDAV 设置（含密码，空密码不覆盖已有）
  static Future<String?> saveWebDAVConfig(
      String url, String username, String password, String directory) async {
    final app = _app;
    app.config.webdav = WebDAVConfig(
      url: url,
      username: username,
      directory: directory,
    );
    app.persist();
    if (password.isNotEmpty && username.isNotEmpty) {
      final ok = await SecretStore.write(username, password);
      if (!ok) return '密码保存失败';
    }
    app.log('WebDAV 设置已保存');
    return null;
  }

  /// WebDAV 备份
  static Future<String?> backupToWebDAV() async {
    final app = _app;
    final w = app.config.webdav;
    if (w == null || w.url.trim().isEmpty) return '请先填写 WebDAV 地址';
    final url = WebDAVClient.endpoint(w.url, w.directory);
    if (url == null) return 'WebDAV 地址无效';
    final password = await SecretStore.read(w.username);
    if (password == null || password.isEmpty) return '请先设置 WebDAV 密码';

    app.webdavBusy = true;
    app.refresh();
    try {
      final cfg = app.cleanConfig;
      final body =
          const JsonEncoder.withIndent('  ').convert(cfg.toJson());
      final err = await WebDAVClient.upload(url, w.username, password, body);
      if (err != null) {
        app.log('WebDAV 备份失败：${err.message}');
        return err.message;
      }
      app.log('已备份到 WebDAV');
      return null;
    } catch (e) {
      return 'WebDAV 备份失败：$e';
    } finally {
      app.webdavBusy = false;
      app.refresh();
    }
  }

  /// WebDAV 还原
  static Future<String?> restoreFromWebDAV() async {
    final app = _app;
    final w = app.config.webdav;
    if (w == null || w.url.trim().isEmpty) return '请先填写 WebDAV 地址';
    final url = WebDAVClient.endpoint(w.url, w.directory);
    if (url == null) return 'WebDAV 地址无效';
    final password = await SecretStore.read(w.username);
    if (password == null || password.isEmpty) return '请先设置 WebDAV 密码';
    try {
      final err = WebDAVError('');
      final body =
          await WebDAVClient.download(url, w.username, password, outErr: err);
      if (body == null) return err.message.isEmpty ? '服务器连接失败' : err.message;
      final j = jsonDecode(body);
      if (j is! Map<String, dynamic>) return '不是有效的配置备份';
      final cfg = AppConfig.fromJson(j);
      if (app.isRunning || app.isStarting) {
        await app.stop();
      }
      app.applyRestored(cfg);
      return null;
    } catch (e) {
      return 'WebDAV 还原失败：$e';
    }
  }

  /// 删除 WebDAV 服务器上的备份文件（本地配置不受影响）。
  static Future<String?> deleteWebDAVBackup() async {
    final app = _app;
    final w = app.config.webdav;
    if (w == null || w.url.trim().isEmpty) return '请先填写 WebDAV 地址';
    final url = WebDAVClient.endpoint(w.url, w.directory);
    if (url == null) return 'WebDAV 地址无效';
    final password = await SecretStore.read(w.username);
    if (password == null || password.isEmpty) return '请先设置 WebDAV 密码';

    app.webdavBusy = true;
    app.refresh();
    try {
      final err = await WebDAVClient.delete(url, w.username, password);
      if (err != null) {
        app.log('删除远程 WebDAV 备份失败：${err.message}');
        return err.message;
      }
      app.log('已删除 WebDAV 上的备份');
      return null;
    } catch (e) {
      return '删除远程 WebDAV 备份失败：$e';
    } finally {
      app.webdavBusy = false;
      app.refresh();
    }
  }

  /// 删除已保存的 WebDAV 服务器设置（含本地凭据），不再作为备份目标。
  static Future<String?> removeWebDAVServer() async {
    final app = _app;
    final w = app.config.webdav;
    if (w == null) return null;
    if (w.username.trim().isNotEmpty) {
      await SecretStore.delete(w.username.trim());
    }
    app.config.webdav = null;
    app.persist();
    app.log('已删除 WebDAV 服务器');
    return null;
  }

  static Future<String?> restoreConfigLocal(String path) async {
    try {
      final j = jsonDecode(File(path).readAsStringSync());
      if (j is! Map<String, dynamic>) return '不是有效的配置备份';
      final cfg = AppConfig.fromJson(j);
      if (_app.isRunning || _app.isStarting) {
        await _app.stop();
      }
      _app.applyRestored(cfg);
      return null;
    } catch (_) {
      return '不是有效的配置备份';
    }
  }

  static String _availableName(String base, Set<String> used) {
    for (var i = 1; i < 100; i++) {
      final suffix = '-${i.toString().padLeft(2, '0')}';
      final head = base.truncatedToWidth(16 - suffix.displayWidth);
      final cand = head + suffix;
      if (!used.contains(cand)) return cand;
    }
    return base.truncatedToWidth(16);
  }

  static String _newUuid() => DateTime.now().microsecondsSinceEpoch.toRadixString(16);
}
