// 网络感知（Windows）：枚举活动网络接口、识别 VPN/虚拟接口。
// 一期用途：接管系统代理前记录默认出口接口与 VPN 状态（日志提示），
// 为“VPN 环境下跳过接管/提示”预留数据源。
// - 默认路由接口：iphlpapi.GetIpForwardTable（FFI，扁平结构）
// - 接口名/描述：Get-NetAdapter（PowerShell，JSON 解析，避免手排结构体）
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// 默认出口接口 ifIndex：GetBestInterface(0) —— OS 计算的“到任意 IPv4 目标
/// 的最佳接口”，等价于默认路由出口（比手工解析 MIB_IPFORWARDROW 可靠）。
int? defaultRouteIfIndex() {
  final iphlp = DynamicLibrary.open('iphlpapi.dll');
  final getBest = iphlp.lookupFunction<
      Uint32 Function(Uint32, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)>('GetBestInterface');
  final idx = calloc<Uint32>();
  try {
    return getBest(0, idx) == 0 ? idx.value : null;
  } finally {
    calloc.free(idx);
  }
}

class NetInterface {
  final int ifIndex;
  final String name;
  final String description;
  final String status;
  const NetInterface(this.ifIndex, this.name, this.description, this.status);
}

/// PowerShell Get-NetAdapter 枚举（含 ifIndex/名称/描述/状态）。
Future<List<NetInterface>> interfaces() async {
  try {
    final r = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          'Get-NetAdapter -ErrorAction SilentlyContinue | '
              'Select-Object ifIndex,Name,InterfaceDescription,Status '
              '| ConvertTo-Json -Compress'
        ]);
    if (r.exitCode != 0) return const [];
    final text = (r.stdout as String).trim();
    if (text.isEmpty) return const [];
    final dynamic decoded = jsonDecode(text);
    final list = decoded is List
        ? decoded.cast<Map<String, dynamic>>()
        : (decoded is Map<String, dynamic> ? [decoded] : const []);
    return [
      for (final m in list)
        NetInterface(
          (m['ifIndex'] as num?)?.toInt() ?? 0,
          (m['Name'] as String?) ?? '',
          (m['InterfaceDescription'] as String?) ?? '',
          (m['Status'] as String?) ?? '',
        )
    ];
  } catch (_) {
    return const [];
  }
}

/// VPN/虚拟接口特征词（含这些词的描述/名称视为虚拟接口）。
const vpnKeywords = [
  'VPN', 'TUN', 'TAP', 'WireGuard', 'OpenVPN', 'Tailscale', 'ZeroTier',
  'Proton VPN', 'Surfshark', 'NordVPN', 'Mullvad', 'Virtual', 'VMware',
  'VirtualBox', 'VBox', 'Hyper-V', 'Loopback',
];

class NetworkProbe {
  /// 接管系统代理前的网络快照（默认出口 + VPN 状态）。
  static Future<NetworkSnapshot> snapshot() async {
    final ifIndex = defaultRouteIfIndex();
    final ifs = await interfaces();
    NetInterface? def;
    for (final i in ifs) {
      if (i.ifIndex == ifIndex) {
        def = i;
        break;
      }
    }
    final d = def;
    if (d == null) return const NetworkSnapshot(null, false);
    final vpn = vpnKeywords.any((k) =>
            d.description.toUpperCase().contains(k.toUpperCase())) ||
        vpnKeywords
            .any((k) => d.name.toUpperCase().contains(k.toUpperCase()));
    return NetworkSnapshot(d, vpn);
  }
}

/// 网络状态快照（供日志/提示）：默认出口接口 + 是否 VPN。
class NetworkSnapshot {
  final NetInterface? defaultInterface;
  final bool vpnActive;
  const NetworkSnapshot(this.defaultInterface, this.vpnActive);
}
