// 应用运行时临时文件（托盘图标、更新看门狗日志、自替换批处理等）的统一落点。
//
// 之前各处直接写 Directory.systemTemp，也就是 %TEMP%（C:\Users\<用户>\AppData\
// Local\Temp），东西一多既难找又占系统盘。这里统一收敛：
//   - 开发环境（存在 F:\WorkBuddy\Temp\go-build）→ 用该目录，和构建中间产物
//     放在一处，保持 C 盘干净，清理时也只需清空一个目录；
//   - 其他机器（没有上述目录）→ 回退 %TEMP%，发布版功能不受影响。
import 'dart:io';

/// 应用临时目录。不保证子目录已存在，需要建子目录请用 [appTempSubDir]。
Directory appTempDir() {
  const preferred = r'F:\WorkBuddy\Temp\go-build';
  final d = Directory(preferred);
  if (d.existsSync()) return d;
  return Directory.systemTemp;
}

/// [appTempDir] 下的子目录，不存在则创建。
Directory appTempSubDir(String name) {
  final d = Directory('${appTempDir().path}${Platform.pathSeparator}$name');
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

/// [appTempDir] 下的文件路径。
String appTempFile(String name) =>
    '${appTempDir().path}${Platform.pathSeparator}$name';

/// 给生成的 PowerShell 脚本用的临时目录路径（反斜杠形式）。
/// 脚本里不能引用 Dart 变量，只能把路径内联进去。
String appTempDirForScript() => appTempDir().path;
