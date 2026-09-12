// 日志服务：镜像 Mac LogFile.swift。
// 界面日志（分级别）+ 落盘 latest.log/previous.log/selfcheck.log，8MB 轮转。
import 'dart:io';

import '../models/config.dart';
import 'config_store.dart';

class LogService {
  static final LogService instance = LogService._();
  LogService._();

  static const int maxLogLines = 2000;
  static const int maxCheckLines = 300;
  static const int rotateBytes = 8 * 1024 * 1024; // 8MB
  static const int selfcheckMaxBytes = 1024 * 1024; // 1MB
  // error.log 的上限。它只在 startNewSession() 时清空，会话内持续报错又没有
  // 大小检查就会一直涨（四个日志文件里原先唯一没有上限的）。错误日志正常量很小，
  // 2MB 足够定位问题，超了先写一行标记再清空重写。
  static const int errorMaxBytes = 2 * 1024 * 1024; // 2MB

  final List<String> logLines = [];
  final List<String> errorLines = [];
  final List<String> checkLines = [];

  Directory? _dir;
  File? _current;
  File? _error;
  File? _check;
  int _written = 0;
  // 串行写盘队列：文件操作在后台链上执行，不阻塞 UI 线程
  Future<void> _fileQueue = Future.value();
  bool _closed = false;

  Directory get dir {
    if (_dir != null) return _dir!;
    final cfgDir = ConfigStore.instance.dir;
    _dir = Directory('${cfgDir.path}${Platform.pathSeparator}logs');
    _dir!.createSync(recursive: true);
    return _dir!;
  }

  File get currentFile => File('${dir.path}${Platform.pathSeparator}latest.log');
  File get previousFile => File('${dir.path}${Platform.pathSeparator}previous.log');
  File get errorFile => File('${dir.path}${Platform.pathSeparator}error.log');
  File get checkFile => File('${dir.path}${Platform.pathSeparator}selfcheck.log');

  /// 启动新会话：latest -> previous，重建 latest/error（随会话轮转），selfcheck 保留累计
  void startNewSession() {
    try {
      final cur = currentFile;
      if (cur.existsSync()) {
        final prev = previousFile;
        if (prev.existsSync()) prev.deleteSync();
        cur.renameSync(prev.path);
      }
      _current = File(cur.path)..createSync(recursive: true);
      _written = 0;
      final err = errorFile;
      if (err.existsSync()) err.deleteSync();
      _error = File(err.path)..createSync(recursive: true);
      final chk = checkFile;
      if (!chk.existsSync()) chk.createSync(recursive: true);
      _check = chk;
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final stamp =
          '${now.year}-${two(now.month)}-${two(now.day)} > ${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
      log('=== EchOS 启动 $stamp ===', level: LogLevel.info);
    } catch (_) {}
  }

  /// 写一行：内存列表同步更新（界面即时）；落盘进异步队列，不卡 UI。
  /// [uiRank] = 当前界面日志级别 rank（off=0 时界面和文件都不写，对齐 Mac）。
  /// 存储按级别归档，保证「级别 ↔ 文件」一一对应：
  ///   普通行（含错误）→ latest.log + 内存 logLines（全部视图）
  ///   错误行额外      → error.log + 内存 errorLines（错误视图）
  ///   自检行          → selfcheck.log + 内存 checkLines（自检记录视图）
  void log(String text, {required LogLevel level, int? uiRank}) {
    final rank = uiRank ?? LogLevel.info.rank;
    if (rank <= LogLevel.off.rank) return;
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (t.contains('[自检]')) {
        checkLines.add(line);
        if (checkLines.length > maxCheckLines) checkLines.removeAt(0);
        _enqueueCheck(line);
      } else if (level.rank <= rank) {
        logLines.add(line);
        if (logLines.length > maxLogLines) logLines.removeAt(0);
        _enqueueFile(line);
        if (level == LogLevel.error) {
          errorLines.add(line);
          if (errorLines.length > maxLogLines) errorLines.removeAt(0);
          _enqueueError(line);
        }
      }
    }
  }

  /// 普通日志行 → 异步队列
  void _enqueueFile(String line) {
    _fileQueue = _fileQueue.then((_) => _writeFileLine(line));
  }

  /// 自检行 → 异步队列（带时间戳）
  void _enqueueCheck(String line) {
    _fileQueue = _fileQueue.then((_) => _writeCheckLine(line));
  }

  /// 错误行 → 异步队列（error.log）
  void _enqueueError(String line) {
    _fileQueue = _fileQueue.then((_) => _writeErrorLine(line));
  }

  Future<void> _writeErrorLine(String line) async {
    if (_closed) return;
    try {
      final f = _error;
      if (f != null) {
        // 与 selfcheck.log 同一套保护：超过上限就整体清空重写。
        // 不留旧内容是为了让「最近的错误」始终可读——错误日志的价值在时效，
        // 不像 selfcheck 需要看累计趋势。
        if (f.existsSync() && f.lengthSync() > errorMaxBytes) {
          await f.writeAsString(
              '=== error.log 超过 ${errorMaxBytes ~/ 1024 ~/ 1024}MB，已清空重写 ===\n',
              mode: FileMode.write,
              flush: true);
        }
        await f.writeAsString('$line\n', mode: FileMode.append, flush: true);
      }
    } catch (_) {}
  }

  Future<void> _writeFileLine(String line) async {
    if (_closed) return;
    try {
      final f = _current;
      if (f != null) {
        await f.writeAsString('$line\n', mode: FileMode.append, flush: true);
        _written += line.length + 1;
        if (_written >= rotateBytes) await _rotate();
      }
    } catch (_) {}
  }

  Future<void> _writeCheckLine(String line) async {
    if (_closed) return;
    try {
      final chk = _check;
      if (chk != null) {
        if (chk.lengthSync() > selfcheckMaxBytes) {
          if (chk.existsSync()) await chk.delete();
          await chk.create();
        }
        await chk.writeAsString('[${_stamp()}] $line\n',
            mode: FileMode.append, flush: true);
      }
    } catch (_) {}
  }

  Future<void> _rotate() async {
    try {
      final cur = currentFile;
      final prev = previousFile;
      if (prev.existsSync()) await prev.delete();
      if (cur.existsSync()) await cur.rename(prev.path);
      _current = File(cur.path)..createSync();
      _written = 0;
      await _writeFileLine('=== 日志已轮转（上一段保存在 previous.log）===');
    } catch (_) {}
  }

  static String _stamp() {
    final d = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  void clear() {
    logLines.clear();
    errorLines.clear();
    checkLines.clear();
    // 等挂起的写队列排空后再删文件，避免清空后旧任务又写回
    _fileQueue = _fileQueue.then((_) async {
      try {
        for (final f in [currentFile, previousFile, checkFile, errorFile]) {
          if (f.existsSync()) await f.delete();
        }
        _current = File(currentFile.path)..createSync(recursive: true);
        _check = File(checkFile.path)..createSync();
        _error = File(errorFile.path)..createSync();
        _written = 0;
      } catch (_) {}
    });
  }

  void close() {
    _closed = true;
    _fileQueue = _fileQueue.then((_) {
      _current = null;
      _check = null;
    });
  }

  /// 打开当前视图对应的日志文件（在资源管理器中定位选中）。
  /// 自检记录 → selfcheck.log；错误 → error.log；其它 → latest.log。
  Future<void> openLogFile(LogLevel level) async {
    File f;
    if (level == LogLevel.checkOnly) {
      f = checkFile;
    } else if (level == LogLevel.error) {
      f = errorFile;
    } else {
      f = currentFile;
    }
    try {
      if (!f.existsSync()) f.createSync(recursive: true);
      await Process.start('explorer', ['/select,${f.path}'],
          mode: ProcessStartMode.detached);
    } catch (_) {}
  }

  /// 打开日志目录（资源管理器）
  Future<void> openFolder() async {
    final path = dir;
    if (!path.existsSync()) path.createSync(recursive: true);
    try {
      await Process.start('explorer', [path.path],
          mode: ProcessStartMode.detached);
    } catch (_) {}
  }

  /// 当前视图显示的日志行（每级对应各自文件镜像）
  List<String> displayedLines(LogLevel level) {
    switch (level) {
      case LogLevel.checkOnly:
        return checkLines;
      case LogLevel.error:
        return errorLines;
      case LogLevel.off:
        return const <String>[];
      default:
        return logLines;
    }
  }

  /// 切换日志级别时：读取对应日志文件尾部，保证「级别 ↔ 文件」关联显示。
  Future<void> loadView(LogLevel level) async {
    switch (level) {
      case LogLevel.off:
        logLines.clear();
        errorLines.clear();
        checkLines.clear();
        break;
      case LogLevel.checkOnly:
        checkLines
          ..clear()
          ..addAll(await _readTail(checkFile, maxCheckLines));
        break;
      case LogLevel.error:
        errorLines
          ..clear()
          ..addAll(await _readTail(errorFile, maxLogLines));
        break;
      default:
        logLines
          ..clear()
          ..addAll(await _readTail(currentFile, maxLogLines));
    }
  }

  Future<List<String>> _readTail(File f, int max) async {
    try {
      if (!f.existsSync()) return const <String>[];
      final text = await f.readAsString();
      final lines = text
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (lines.length > max) lines.removeRange(0, lines.length - max);
      return lines;
    } catch (_) {
      return const <String>[];
    }
  }
}
