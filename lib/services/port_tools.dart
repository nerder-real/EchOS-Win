// 端口工具：镜像 Mac PortPicker.swift 的行为，Windows 实现。
// - isFree: 尝试 bind 127.0.0.1:port
// - occupant: 找监听该端口的进程（netstat + tasklist）
// - kill: 结束进程（taskkill）
import 'dart:io';

class PortOccupant {
  final String name;
  final int pid;
  const PortOccupant(this.name, this.pid);
  String get label => '$name(PID $pid)';
}

class PortTools {
  static int lastBindErrno = 0;

  static String get lastBindReason =>
      lastBindErrno == 0 ? '未知' : 'errno $lastBindErrno';

  /// 尝试 bind 127.0.0.1:port，成功=空闲
  static Future<bool> isFree(int port) async {
    try {
      final s = ServerSocket.bind(InternetAddress.loopbackIPv4, port,
          shared: false, v6Only: false);
      // 同步等绑定完成
      return await s.then((sock) {
        sock.close();
        lastBindErrno = 0;
        return true;
      }).timeout(const Duration(milliseconds: 1500), onTimeout: () {
        lastBindErrno = -1;
        return false;
      }).catchError((e) {
        lastBindErrno = -2;
        return false;
      });
    } catch (e) {
      lastBindErrno = -3;
      return false;
    }
  }

  /// 扫描出一对连续空闲端口（socks, socks+1）
  static Future<(int, int)> pickPair(
      {int start = 30000, int limit = 200}) async {
    final end = (start + limit < 65534) ? start + limit : 65534;
    var p = start;
    while (p + 1 <= end) {
      if (await isFree(p) && await isFree(p + 1)) return (p, p + 1);
      p += 2;
    }
    return (start, start + 1);
  }

  /// 找到监听 port 的进程
  static Future<PortOccupant?> occupant(int port) async {
    try {
      final r = await Process.run('netstat', ['-ano', '-p', 'tcp'],
          runInShell: true);
      final out = (r.stdout as String).split('\n');
      final listening = out
          .where((l) =>
              l.contains('LISTENING') && l.contains(':${port.toString()} '))
          .toList();
      if (listening.isEmpty) return null;
      final cols = listening.first.trim().split(RegExp(r'\s+'));
      final pid = int.tryParse(cols.last);
      if (pid == null) return null;
      final name = await _processName(pid);
      return PortOccupant(name, pid);
    } catch (_) {
      return null;
    }
  }

  static Future<String> _processName(int pid) async {
    try {
      final r = await Process.run(
          'tasklist', ['/FI', 'PID eq $pid', '/FO', 'CSV'],
          runInShell: true);
      final line = (r.stdout as String)
          .split('\n')
          .firstWhere((l) => l.contains('"'), orElse: () => '');
      final parts = line.split('","');
      if (parts.length >= 2) return parts[0].replaceAll('"', '');
    } catch (_) {}
    return 'unknown';
  }

  /// 结束进程（taskkill），等待退出
  static Future<bool> kill(int pid) async {
    if (pid <= 0) return false;
    try {
      await Process.run('taskkill', ['/F', '/PID', '$pid'], runInShell: true);
      // 轮询确认退出
      for (var i = 0; i < 20; i++) {
        if (!await _processAlive(pid)) return true;
        await Future.delayed(const Duration(milliseconds: 50));
      }
    } catch (_) {}
    return false;
  }

  static Future<bool> _processAlive(int pid) async {
    try {
      final r = await Process.run('tasklist', ['/FI', 'PID eq $pid'],
          runInShell: true);
      return (r.stdout as String).contains(pid.toString());
    } catch (_) {
      return false;
    }
  }
}
