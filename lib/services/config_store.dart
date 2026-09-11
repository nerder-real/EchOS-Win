// 配置持久化：读写 config.json，字段与 Mac 版二进制兼容。
// %APPDATA%\EchOS\config.json
import 'dart:convert';
import 'dart:io';

import '../models/config.dart';

class ConfigStore {
  static final ConfigStore instance = ConfigStore._();
  ConfigStore._();

  Directory? _dir;

  Directory get dir {
    if (_dir != null) return _dir!;
    final appData = Platform.environment['APPDATA'];
    _dir = Directory('${appData ?? ''}\\EchOS');
    _dir!.createSync(recursive: true);
    return _dir!;
  }

  File get file => File('${dir.path}${Platform.pathSeparator}config.json');

  AppConfig load() {
    try {
      final f = file;
      if (f.existsSync()) {
        final data = jsonDecode(f.readAsStringSync());
        if (data is Map<String, dynamic>) {
          final cfg = AppConfig.fromJson(data);
          // 不自动补一个空的「服务器 1」：全新安装不该预置任何服务器
          if (cfg.selectedID == null || !cfg.servers.any((s) => s.id == cfg.selectedID)) {
            cfg.selectedID = cfg.servers.isEmpty ? null : cfg.servers.first.id;
          }
          return cfg;
        }
      }
    } catch (_) {}
    return AppConfig();
  }

  void save(AppConfig cfg) {
    try {
      final enc = JsonEncoder.withIndent('  ');
      file.writeAsStringSync(enc.convert(cfg.toJson()), flush: true);
    } catch (_) {}
  }
}
