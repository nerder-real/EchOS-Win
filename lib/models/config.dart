// 配置模型：从 Mac 的 Config.swift 直译。
// JSON 字段名与 Mac 版保持一致，保证两边配置文件互相兼容。


// ---------------------------------------------------------------------------
// 日志级别
// ---------------------------------------------------------------------------

enum LogLevel {
  off('off', '关闭', 0),
  error('error', '错误', 1),
  info('info', '全部', 3),
  checkOnly('checkOnly', '自检记录', 3);

  final String raw;
  final String title;
  final int rank;
  const LogLevel(this.raw, this.title, this.rank);

  static LogLevel fromRaw(String? v) =>
      LogLevel.values.firstWhere((e) => e.raw == v, orElse: () => LogLevel.info);

  /// 判断一行日志属于哪个级别
  static LogLevel classify(String line) {
    final lower = line.toLowerCase();
    const errKeys = ['失败', '错误', '无应答', 'timeout', 'error', '拒绝', '超时'];
    for (final k in errKeys) {
      if (lower.contains(k)) return LogLevel.error;
    }
    return LogLevel.info;
  }
}

// ---------------------------------------------------------------------------
// 规则
// ---------------------------------------------------------------------------

enum RuleKind {
  domain('domain', '域名', 'claude.ai'),
  ip('ip', 'IP / 网段', '192.168.50.0/24'),
  category('category', '网站分类', '');

  final String raw;
  final String title;
  final String placeholder;
  const RuleKind(this.raw, this.title, this.placeholder);

  static RuleKind fromRaw(String? v) =>
      RuleKind.values.firstWhere((e) => e.raw == v, orElse: () => RuleKind.domain);
}

/// 可选的网站/地区分类。取自 geosite / geoip 数据里最常用的那些
class RuleCategory {
  final String value; // 内核认的写法
  final String label; // 界面上显示的中文

  const RuleCategory(this.value, this.label);

  static const List<RuleCategory> all = [
    RuleCategory('geosite:cn', '中国大陆网站'),
    RuleCategory('geoip:cn', '中国大陆 IP'),
    RuleCategory('geosite:geolocation-!cn', '境外网站'),
    RuleCategory('geosite:google', 'Google 系'),
    RuleCategory('geosite:youtube', 'YouTube'),
    RuleCategory('geosite:telegram', 'Telegram'),
    RuleCategory('geosite:netflix', 'Netflix'),
    RuleCategory('geosite:openai', 'OpenAI / ChatGPT'),
    RuleCategory('geosite:github', 'GitHub'),
    RuleCategory('geosite:apple', 'Apple'),
    RuleCategory('geosite:microsoft', 'Microsoft'),
    RuleCategory('geoip:private', '局域网'),
    RuleCategory('geoip:jp', '日本 IP'),
    RuleCategory('geoip:us', '美国 IP'),
    RuleCategory('geoip:hk', '香港 IP'),
    RuleCategory('geoip:tw', '台湾 IP'),
    RuleCategory('geoip:sg', '新加坡 IP'),
  ];
}

/// 一条自定义分流规则
class CustomRule {
  String id;
  RuleKind kind;
  String target;
  String action; // direct / proxy / block

  CustomRule({String? id, RuleKind? kind, this.target = '', this.action = 'direct'})
      : id = id ?? _newUuid(),
        kind = kind ?? RuleKind.domain;

  CustomRule.fromJson(Map<String, dynamic> j)
      : id = (j['id'] as String?) ?? _newUuid(),
        target = (j['target'] as String?) ?? '',
        action = (j['action'] as String?) ?? 'direct',
        kind = _inferKind(j['kind'] as String?, (j['target'] as String?) ?? '');

  static RuleKind _inferKind(String? kindRaw, String target) {
    if (kindRaw != null) return RuleKind.fromRaw(kindRaw);
    // 老配置没有 kind 字段，按 target 的样子猜一个
    final lower = target.toLowerCase();
    if (lower.startsWith('geosite:') || lower.startsWith('geoip:')) {
      return RuleKind.category;
    } else if (target.contains('/') ||
        target.split('').every((c) => RegExp(r'[0-9.:]').hasMatch(c))) {
      return RuleKind.ip;
    } else {
      return RuleKind.domain;
    }
  }

  Map<String, dynamic> toJson() => {'id': id, 'kind': kind.raw, 'target': target, 'action': action};

  /// 转成内核认识的条件写法
  String? get kernelCondition {
    final t = target.trim();
    if (t.isEmpty) return null;
    switch (kind) {
      case RuleKind.category:
        return t; // 下拉选出来的本来就是内核写法
      case RuleKind.ip:
        return t; // IP 和 IP 段内核直接认
      case RuleKind.domain:
        var d = t;
        if (d.toLowerCase().startsWith('domain:')) return d;
        if (d.startsWith('*.')) d = d.substring(2);
        return 'domain:$d';
    }
  }
}

/// 一个可选项：内核认的值 + 界面上显示的说明
class PresetOption {
  final String value;
  final String label;
  const PresetOption(this.value, this.label);
}

/// DoH/DNS 服务预设 + ECH 域名预设
class EchPresets {
  static const List<PresetOption> dnsServers = [
    PresetOption('dns.alidns.com/dns-query', '阿里 DoH（国内推荐）'),
    PresetOption('sm2.doh.pub/dns-query', '腾讯国密 DoH（国内）'),
    PresetOption('doh.360.cn/dns-query', '360 DoH（国内）'),
    PresetOption('doh.onedns.net/dns-query', 'OneDNS DoH（国内）'),
    PresetOption('udp://208.67.220.220:443', 'OpenDNS（境外）'),
    PresetOption('udp://149.112.112.112:9953', 'Quad9（境外）'),
    PresetOption('udp://45.90.28.0:5353', 'NextDNS（境外）'),
    PresetOption('udp://188.166.206.224:5003', 'Tiarap（境外）'),
    PresetOption('doh.applied-privacy.net/query', 'Applied Privacy DoH（境外）'),
    PresetOption('odvr.nic.cz/doh', 'CZ.NIC DoH（境外）'),
    PresetOption('cloudflare-dns.com/dns-query', 'Cloudflare DoH（境外·HTTP2）'),
    PresetOption('dns.google/dns-query', 'Google DoH（境外·HTTP2）'),
    PresetOption('doh.opendns.com/dns-query', 'OpenDNS DoH（境外·HTTP2）'),
    PresetOption('dns.adguard.com/dns-query', 'AdGuard DoH（境外·HTTP2）'),
  ];

  static const List<PresetOption> echDomains = [
    PresetOption('cloudflare-ech.com', 'cloudflare-ech.com（推荐）'),
    PresetOption('crypto.cloudflare.com', 'crypto.cloudflare.com'),
    PresetOption('encryptedsni.com', 'encryptedsni.com'),
    PresetOption('icook.hk', 'icook.hk'),
    PresetOption('cm.edu.kg', 'cm.edu.kg'),
    PresetOption('godotengine.org', 'godotengine.org'),
    PresetOption('www.britannica.com', 'www.britannica.com'),
    PresetOption('www.prometheus.io', 'www.prometheus.io'),
    PresetOption('www.kyocera.com', 'www.kyocera.com'),
    PresetOption('celestia.org', 'celestia.org'),
    PresetOption('lido.fi', 'lido.fi'),
  ];
}

// ---------------------------------------------------------------------------
// 分流模式
// ---------------------------------------------------------------------------

enum RouteMode {
  bypassCN('bypassCN', '绕过中国大陆', '国内网站直连，其余走代理（推荐）', 'proxy',
      'proxy,geosite:google;proxy,geosite:geolocation-!cn;direct,geoip:private;direct,geosite:private;direct,geosite:cn;direct,geoip:cn'),
  blacklist('blacklist', '黑名单模式', '只有名单内的网站走代理，其余全部直连', 'direct',
      'direct,geoip:private;direct,geosite:private;direct,geosite:cn;direct,geoip:cn;proxy,geosite:google;proxy,geosite:geolocation-!cn'),
  global('global', '全局模式', '所有流量都走代理', 'proxy',
      'direct,geoip:private;direct,geosite:private');

  final String raw;
  final String title;
  final String detail;
  final String defaultRoute;
  final String baseRoute;
  const RouteMode(this.raw, this.title, this.detail, this.defaultRoute, this.baseRoute);

  static RouteMode fromRaw(String? v) =>
      RouteMode.values.firstWhere((e) => e.raw == v, orElse: () => RouteMode.bypassCN);

  // 全局模式也需要 geoip/geosite：base 路由包含 direct,geoip:private 等规则，
  // 缺分流数据时局域网/内网流量会被误代理（对齐 Mac：恒加载分流数据）。
  bool get needsGeoData => true;
}

/// 找出被前面同目标规则盖住的那些规则的 id
Set<String> shadowedRuleIds(List<CustomRule> rules) {
  final seen = <String>{};
  final shadowed = <String>{};
  for (final r in rules) {
    final key = r.kernelCondition;
    if (key == null) continue;
    if (seen.contains(key)) {
      shadowed.add(r.id);
    } else {
      seen.add(key);
    }
  }
  return shadowed;
}

// ---------------------------------------------------------------------------
// ServerConfig
// ---------------------------------------------------------------------------

class ServerConfig {
  String id;
  String name;
  String server;
  int serverPort;
  String listen;
  int listenPort;
  String ip;
  String ech;
  String dns;
  String token;
  int connections;
  String block;
  String ips;
  bool fallback;
  bool insecure;
  List<CustomRule> customRules;

  ServerConfig({
    String? id,
    this.name = '新服务器',
    this.server = '',
    this.serverPort = 443,
    this.listen = '127.0.0.1',
    this.listenPort = 30000,
    this.ip = 'cdns.doon.eu.org',  // 对齐 Mac v1.2.5+ 默认优选IP
    this.ech = 'cloudflare-ech.com',
    this.dns = 'dns.alidns.com/dns-query',
    this.token = '',
    this.connections = 3,
    this.block = '443',
    this.ips = '',
    this.fallback = false,
    this.insecure = false,
    List<CustomRule>? customRules,
  })  : id = id ?? _newUuid(),
        customRules = customRules ?? [];

  factory ServerConfig.fromJson(Map<String, dynamic> j) {
    final rawServer = (j['server'] as String?) ?? '';
    final rawListen = simplifyListen((j['listen'] as String?) ?? '127.0.0.1:30000');
    final sp = j['serverPort'];
    final lp = j['listenPort'];
    String server;
    int serverPort;
    if (sp is int) {
      server = rawServer;
      serverPort = sp;
    } else {
      final r = splitHostPort(rawServer, 443);
      server = r.host;
      serverPort = r.port;
    }
    String listen;
    int listenPort;
    if (lp is int) {
      listen = rawListen;
      listenPort = lp;
    } else {
      final r = splitHostPort(rawListen, 30000);
      listen = r.host.isEmpty ? '127.0.0.1' : r.host;
      listenPort = r.port;
    }
    final rules = (j['customRules'] as List?) ?? [];
    return ServerConfig(
      id: (j['id'] as String?) ?? _newUuid(),
      name: (j['name'] as String?) ?? '新服务器',
      server: server,
      serverPort: serverPort,
      listen: listen,
      listenPort: listenPort,
      ip: (j['ip'] as String?) ?? 'cdns.doon.eu.org',
      ech: (j['ech'] as String?) ?? 'cloudflare-ech.com',
      dns: (j['dns'] as String?) ?? 'dns.alidns.com/dns-query',
      token: (j['token'] as String?) ?? '',
      connections: (j['connections'] as num?)?.toInt() ?? 3,
      block: (j['block'] as String?) ?? '443',
      ips: (j['ips'] as String?) ?? '',
      fallback: (j['fallback'] as bool?) ?? false,
      insecure: (j['insecure'] as bool?) ?? false,
      customRules: rules.map((e) => CustomRule.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'server': server,
        'serverPort': serverPort,
        'listen': listen,
        'listenPort': listenPort,
        'ip': ip,
        'ech': ech,
        'dns': dns,
        'token': token,
        'connections': connections,
        'block': block,
        'ips': ips,
        'fallback': fallback,
        'insecure': insecure,
        'customRules': customRules.map((e) => e.toJson()).toList(),
      };

  // ---- 工具方法（对齐 Mac Config.swift）----

  /// 从 "host:port" 里拆出主机和端口。中文冒号也认。
  static ({String host, int port}) splitHostPort(String raw, int defaultPort) {
    var t = raw.trim();
    for (final scheme in ['wss://', 'ws://', 'https://', 'http://', 'socks5://']) {
      if (t.toLowerCase().startsWith(scheme)) {
        t = t.substring(scheme.length);
        break;
      }
    }
    t = t.replaceAll('：', ':');
    final slash = t.indexOf('/');
    if (slash >= 0) t = t.substring(0, slash);
    final colon = t.lastIndexOf(':');
    if (colon >= 0) {
      final p = int.tryParse(t.substring(colon + 1).trim());
      if (p != null && p > 0 && p < 65536) {
        return (host: t.substring(0, colon), port: p);
      }
    }
    return (host: t, port: defaultPort);
  }

  /// 主机名清洗
  static String cleanHost(String raw) {
    var t = raw.trim();
    for (final scheme in ['wss://', 'ws://', 'https://', 'http://', 'socks5://']) {
      if (t.toLowerCase().startsWith(scheme)) {
        t = t.substring(scheme.length);
        break;
      }
    }
    t = t.replaceAll('：', ':');
    final slash = t.indexOf('/');
    if (slash >= 0) t = t.substring(0, slash);
    final colon = t.lastIndexOf(':');
    if (colon >= 0 && int.tryParse(t.substring(colon + 1)) != null) {
      t = t.substring(0, colon);
    }
    return t;
  }

  /// 把界面上填的监听地址展开成内核认识的 -l 串
  static String? expandListen(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    if (s.contains('://')) return s;
    var host = '127.0.0.1';
    var portPart = s;
    final colon = s.lastIndexOf(':');
    if (colon >= 0) {
      host = s.substring(0, colon);
      if (host.isEmpty) host = '127.0.0.1';
      portPart = s.substring(colon + 1);
    }
    final port = int.tryParse(portPart);
    if (port == null || port <= 0 || port >= 65535) return null;
    return 'socks5://$host:$port,http://$host:${port + 1}';
  }

  /// expandListen 的逆操作
  static String simplifyListen(String raw) {
    final s = raw.trim();
    if (!s.contains('://')) return s;
    final parts = s.split(',');
    final socks = socksEndpoint(s);
    if (socks == null || parts.length > 2) return s;
    if (parts.length == 2) {
      final http = httpEndpoint(s);
      if (http == null || http.host != socks.host || http.port != socks.port + 1) {
        return s;
      }
    }
    return '${socks.host}:${socks.port}';
  }

  static ({String host, int port})? socksEndpoint(String listen) =>
      endpoint(listen, 'socks5');
  static ({String host, int port})? httpEndpoint(String listen) =>
      endpoint(listen, 'http');

  static ({String host, int port})? endpoint(String listen, String scheme) {
    for (final raw in listen.split(',')) {
      final item = raw.trim();
      if (!item.toLowerCase().startsWith('$scheme://')) continue;
      var rest = item.substring(scheme.length + 3);
      final at = rest.lastIndexOf('@');
      if (at >= 0) rest = rest.substring(at + 1);
      final slash = rest.indexOf('/');
      if (slash >= 0) rest = rest.substring(0, slash);
      final colon = rest.lastIndexOf(':');
      if (colon < 0) continue;
      final port = int.tryParse(rest.substring(colon + 1));
      if (port == null) continue;
      final host = rest.substring(0, colon);
      return (host: host.isEmpty ? '127.0.0.1' : host, port: port);
    }
    return null;
  }

  /// 内核要求 -f 带协议头
  String get normalizedServer {
    final h = ServerConfig.cleanHost(server);
    if (h.isEmpty) return '';
    return 'wss://$h:$serverPort';
  }

  /// 内核要求的 -l
  String get expandedListen {
    final h = ServerConfig.cleanHost(listen);
    final host = h.isEmpty ? '127.0.0.1' : h;
    return 'socks5://$host:$listenPort,http://$host:${listenPort + 1}';
  }

  /// 把 dns.alidns.com/dns-query 这类写法补成 https:// 前缀
  static String normalizedDoH(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;
    final lower = s.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) return s;
    if (lower.startsWith('udp://')) return s.substring(6);
    if (s.contains('/')) return 'https://$s';
    return s;
  }

  /// 组装内核命令行参数
  List<String> arguments(
      {String? listen,
      String? geoip,
      String? geosite,
      required RouteMode mode,
      List<CustomRule>? rules}) {
    final args = <String>[];
    void add(String flag, String value) {
      final v = value.trim();
      if (v.isNotEmpty) {
        args.addAll([flag, v]);
      }
    }

    add('-f', normalizedServer);
    add('-l', listen ?? expandedListen);

    // 全局规则：所有服务器共用
    final custom = (rules ?? customRules).map((r) {
      final cond = r.kernelCondition;
      if (cond == null) return '';
      return '${r.action},$cond';
    }).where((s) => s.isNotEmpty).join(';');
    final base = mode.baseRoute;
    final route = custom.isEmpty ? base : (base.isEmpty ? custom : '$custom;$base');
    args.addAll(['-default', mode.defaultRoute, '-route', route]);

    if (mode.needsGeoData) {
      if (geoip != null && geoip.trim().isNotEmpty) add('-geoip', geoip);
      if (geosite != null && geosite.trim().isNotEmpty) add('-geosite', geosite);
    }
    add('-token', token);
    add('-ip', ip);

    if (fallback) {
      args.add('-fallback');
    } else {
      add('-dns', ServerConfig.normalizedDoH(dns));
      add('-ech', ech);
    }

    if (connections != 3) args.addAll(['-n', '$connections']);
    if (insecure) args.add('-insecure');
    add('-block', block);
    add('-ips', ips);
    return args;
  }

  /// 配置是否完整到可以启动
  String? validate() {
    if (ServerConfig.cleanHost(server).isEmpty) return '请填写「服务地址」';
    if (serverPort <= 0 || serverPort > 65535) return '「服务端口」应在 1–65535 之间';
    if (!_validUrlHost(normalizedServer)) return '「服务地址」格式不对，应形如 xxx.workers.dev';
    if (ServerConfig.cleanHost(listen).isEmpty) return '请填写「监听地址」';
    if (listenPort <= 0 || listenPort >= 65535) return '「监听端口」应在 1–65534 之间';
    if (ip.trim().isEmpty) return '请填写「优选IP/域名」';
    return null;
  }

  static bool _validUrlHost(String s) {
    // 简单校验：有 "://host" 且 host 非空
    final m = RegExp(r'^[a-z]+://([^/:]+)').firstMatch(s);
    return m != null && m.group(1)!.isNotEmpty;
  }
}

// ---------------------------------------------------------------------------
// WebDAV / AppConfig
// ---------------------------------------------------------------------------

class WebDAVConfig {
  String url;
  String username;
  String directory;

  WebDAVConfig({this.url = '', this.username = '', this.directory = ''});

  factory WebDAVConfig.fromJson(Map<String, dynamic> j) => WebDAVConfig(
        url: (j['url'] as String?) ?? '',
        username: (j['username'] as String?) ?? '',
        directory: (j['directory'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'url': url,
        'username': username,
        'directory': directory,
      };
}

class AppConfig {
  List<ServerConfig> servers;
  String? selectedID;
  bool autoSystemProxy;
  bool showDiagnosticLogs;
  LogLevel logLevel;
  bool showDockIcon;
  RouteMode routeMode;
  bool logVisible;
  double logHeight; // 日志区高度（px），可拖拽调整；默认 4 行
  List<CustomRule> customRules; // 全局分流规则（对所有服务器生效）
  WebDAVConfig? webdav;

  AppConfig({
    List<ServerConfig>? servers,
    this.selectedID,
    this.autoSystemProxy = true,
    this.showDiagnosticLogs = false,
    this.logLevel = LogLevel.info,
    this.showDockIcon = false,
    this.routeMode = RouteMode.bypassCN,
    this.logVisible = true,
    this.logHeight = _defaultLogHeight,
    List<CustomRule>? customRules,
    this.webdav,
  })  : servers = servers ?? [],
        customRules = customRules ?? [];

  factory AppConfig.fromJson(Map<String, dynamic> j) {
    final servers = (j['servers'] as List?)
            ?.map((e) => ServerConfig.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    // 全局规则：新字段 customRules 优先；兼容旧版把各服务器里的规则收敛到全局
    final globalRules = <CustomRule>[
      ...?((j['customRules'] as List?)?.map(
              (e) => CustomRule.fromJson(e as Map<String, dynamic>))),
    ];
    final seen = globalRules.map((r) => r.id).toSet();
    for (final s in servers) {
      for (final r in s.customRules) {
        if (!seen.contains(r.id)) {
          globalRules.add(r);
          seen.add(r.id);
        }
      }
      s.customRules = [];
    }
    return AppConfig(
      servers: servers,
      selectedID: j['selectedID'] as String?,
      autoSystemProxy: (j['autoSystemProxy'] as bool?) ?? true,
      showDiagnosticLogs: (j['showDiagnosticLogs'] as bool?) ?? false,
      logLevel: LogLevel.fromRaw(j['logLevel'] as String?),
      showDockIcon: (j['showDockIcon'] as bool?) ?? false,
      routeMode: RouteMode.fromRaw(j['routeMode'] as String?),
      logVisible: (j['logVisible'] as bool?) ?? true,
      logHeight: (j['logHeight'] as num?)?.toDouble() ?? _defaultLogHeight,
      customRules: globalRules,
      webdav: j['webdav'] == null
          ? null
          : WebDAVConfig.fromJson(j['webdav'] as Map<String, dynamic>),
    );
  }

  Map<String, dynamic> toJson() => {
        // 全局规则同时写入每台服务器（Mac 按每台读规则），保证
        // Windows→Mac 迁移/导入时规则不丢；顶层 customRules 保留给本端。
        'servers': servers.map((e) => {
              ...e.toJson(),
              'customRules': customRules.map((r) => r.toJson()).toList(),
            }).toList(),
        'selectedID': selectedID,
        'autoSystemProxy': autoSystemProxy,
        'showDiagnosticLogs': showDiagnosticLogs,
        'logLevel': logLevel.raw,
        'showDockIcon': showDockIcon,
        'routeMode': routeMode.raw,
        'logVisible': logVisible,
        'logHeight': logHeight,
        'customRules': customRules.map((e) => e.toJson()).toList(),
        'webdav': webdav?.toJson(),
      };

  ServerConfig? get selected =>
      servers.where((s) => s.id == selectedID).firstOrNull ?? (servers.isEmpty ? null : servers.first);

  int get selectedIndex => servers.indexWhere((s) => s.id == selectedID);
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

/// 日志区默认高度（px）＝ 4 行 × 行高 15 + 内边距 16
const double _defaultLogHeight = 4 * 15 + 16;
/// 日志单行高度（px）
const double logLineHeight = 15;
/// 日志区最小行数（拖拽不能低于此）
const int minLogLines = 4;

String _newUuid() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${DateTime.now().millisecond}';

extension StringWidth on String {
  /// 显示宽度：汉字/全角算 2，英文数字符号算 1
  int get displayWidth {
    var w = 0;
    for (final ch in runes) {
      w += ch >= 0x1100 ? 2 : 1;
    }
    return w;
  }

  /// 从尾部截断，使显示宽度不超过 max
  String truncatedToWidth(int max) {
    var out = '';
    var w = 0;
    for (final ch in runes) {
      final cw = ch >= 0x1100 ? 2 : 1;
      if (w + cw > max) break;
      out += String.fromCharCode(ch);
      w += cw;
    }
    return out;
  }
}

// 简化的 firstOrNull 扩展
extension FirstOrNullX<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
