// 数据目录 / 内核路径 / 分流数据路径
import 'dart:io';

class AppPaths {
  static final AppPaths instance = AppPaths._();
  AppPaths._();

  /// %APPDATA%\EchOS\data
  static Directory get dataDir {
    final base = _platformDataBase();
    final d = Directory('${base.path}${Platform.pathSeparator}data');
    d.createSync(recursive: true);
    return d;
  }

  /// %APPDATA%\EchOS
  static Directory get appDataDir {
    final d = _platformDataBase();
    d.createSync(recursive: true);
    return d;
  }

  static Directory _platformDataBase() {
    final appData = Platform.environment['APPDATA'];
    return Directory('${appData ?? ''}\\EchOS');
  }

  static File? geoData(String name) {
    // 优先本地下载的数据
    final f = File('${dataDir.path}${Platform.pathSeparator}$name');
    return f.existsSync() ? f : null;
  }

  static String? get geoipPath => geoData('geoip.dat')?.path;
  static String? get geositePath => geoData('geosite.dat')?.path;

  /// 打包内默认的分流数据路径
  static String? builtinGeoipPath() =>
      _builtinFile('geoip.dat')?.path;
  static String? builtinGeositePath() =>
      _builtinFile('geosite.dat')?.path;

  /// 查找与可执行文件同目录的打包文件
  static File? _builtinFile(String name) {
    final resolved = Platform.resolvedExecutable;
    final dir = File(resolved).parent.path;
    final f = File('$dir${Platform.pathSeparator}$name');
    return f.existsSync() ? f : null;
  }
}
