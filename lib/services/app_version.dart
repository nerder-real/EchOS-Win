import 'dart:io' show Platform;

/// 应用版本号（用于日志展示与更新判定）。
///
/// ## 来源优先级
/// 1. **发布构建**：CI 注入 `--dart-define=ECHOS_VERSION=<标签去掉 v 前缀>`，
///    保证「安装包文件名 / Release 标签 / 应用自报版本」三者一致。
/// 2. **本地构建**：回退到下面的 defaultValue，需与 pubspec.yaml 的
///    version（1.0.0+1 → 1.0.0）保持一致。
///
/// ## 为什么必须由构建期注入
/// Updater 用 `isNewer(Release 标签版本, kAppVersion)` 判定是否有更新。
/// 一旦自报版本高于（或等于）Release 标签，就会永远判定「已是最新版本」，
/// 自动更新**静默失效**——没有任何报错。把版本号交给 CI 从标签注入，
/// 可以从根上消除「改了 pubspec 忘了改这里」的人工同步风险。
///
/// ## 升级方向
/// 判定是**严格大于**，所以新标签必须大于客户端当前自报版本。
/// 基线为 1.0.0，后续依次 1.0.1 / 1.0.2 …。注意自报 1.0.0 的客户端
/// 收不到 v1.0.0 的更新（相等不算新），只会收到更高的版本。
const String kAppVersion = String.fromEnvironment(
  'ECHOS_VERSION',
  defaultValue: '1.3.0',
);

/// 对外上报用的「版本 + 平台」标识（授权服务 /verify、/activate 的
/// appVersion 字段用它，服务端与管理页原样透传）。
///
/// 为什么不直接改 kAppVersion：Updater 的更新判定比较的是纯三段版本号，
/// 往里拼平台后缀会让 isNewer 解析出错、自动更新静默失效。平台标识
/// 只随授权上报走这一份，两不相扰。
///
/// 平台取运行时系统（Win/Mac 为当前主要两端），其余按原样回退——
/// 管理页版本列的小徽章只认识已列出的几个，没列出的按普通文本显示。
final String kAppVersionTag = () {
  const labels = <String, String>{
    'windows': 'Win',
    'macos': 'Mac',
    'linux': 'Linux',
    'android': 'Android',
    'ios': 'iOS',
  };
  final os = labels[Platform.operatingSystem] ?? Platform.operatingSystem;
  return '$kAppVersion-$os';
}();
