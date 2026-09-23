// 平台驱动：开机自启 + 密码存储 + 提权（Windows）。
// 注册表 Run / DPAPI（FFI 直调 crypt32）/ ShellExecuteW(runas)。
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkg;

import 'instance_guard.dart';

class Autostart {
  static const String _runKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const String _valueName = 'EchOS';

  static bool get enabled {
    try {
      final r = Process.runSync(
          'reg', ['query', _runKey, '/v', _valueName], runInShell: true);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> set(bool on) async {
    try {
      final exe = Platform.resolvedExecutable;
      if (on) {
        final r = await Process.run('reg',
            ['add', _runKey, '/v', _valueName, '/t', 'REG_SZ', '/d', '"$exe"', '/f'],
            runInShell: true);
        return r.exitCode == 0;
      } else {
        final r = await Process.run(
            'reg', ['delete', _runKey, '/v', _valueName, '/f'],
            runInShell: true);
        return r.exitCode == 0;
      }
    } catch (_) {
      return false;
    }
  }
}

// DPAPI 里用的 DATA_BLOB / CRYPT_INTEGER_BLOB，两者内存布局一致。
final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

// CryptProtectData / CryptUnprotectData 与 LocalFree 的原生签名。
typedef _ProtectNative = Int32 Function(
    Pointer<_DataBlob>, Pointer<Uint16>, Pointer<_DataBlob>, Pointer<Void>,
    Pointer<Void>, Uint32, Pointer<_DataBlob>);
typedef _ProtectDart = int Function(
    Pointer<_DataBlob>, Pointer<Uint16>, Pointer<_DataBlob>, Pointer<Void>,
    Pointer<Void>, int, Pointer<_DataBlob>);

typedef _UnprotectNative = Int32 Function(
    Pointer<_DataBlob>, Pointer<Uint16>, Pointer<_DataBlob>, Pointer<Void>,
    Pointer<Void>, Uint32, Pointer<_DataBlob>);
typedef _UnprotectDart = int Function(
    Pointer<_DataBlob>, Pointer<Uint16>, Pointer<_DataBlob>, Pointer<Void>,
    Pointer<Void>, int, Pointer<_DataBlob>);

typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void>);

/// 密码存储：Windows 用 DPAPI（FFI 直调 crypt32.dll 的 CryptProtectData /
/// CryptUnprotectData，密文绑定当前 Windows 用户，无需钥匙串）。密文落盘到
/// %APPDATA%\EchOS\secrets\<账号>.bin。
class SecretStore {
  static final DynamicLibrary? _crypt32 = _load('crypt32.dll');
  static final DynamicLibrary? _kernel32 = _load('kernel32.dll');

  static DynamicLibrary? _load(String name) {
    try {
      return DynamicLibrary.open(name);
    } catch (_) {
      return null;
    }
  }

  static Pointer<Void> _localFree(Pointer<Void> p) {
    final lib = _kernel32;
    if (lib == null) return p;
    final f = lib.lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');
    return f(p);
  }

  static bool _protect(String plain, List<int> out) {
    final lib = _crypt32;
    if (lib == null) return false;
    final protect =
        lib.lookupFunction<_ProtectNative, _ProtectDart>('CryptProtectData');

    final inBytes = utf8.encode(plain);
    final inBlob = pkg.calloc<_DataBlob>(sizeOf<_DataBlob>());
    final inData = pkg.calloc<Uint8>(inBytes.length);
    final outBlob = pkg.calloc<_DataBlob>(sizeOf<_DataBlob>());
    try {
      inBlob.ref.cbData = inBytes.length;
      inBlob.ref.pbData = inData;
      for (var i = 0; i < inBytes.length; i++) {
        inData[i] = inBytes[i];
      }
      // dwFlags=0：熵/描述/会话/提示全空，默认 CurrentUser 作用域。
      final ok =
          protect(inBlob, nullptr, nullptr, nullptr, nullptr, 0, outBlob);
      if (ok != 0 && outBlob.ref.cbData > 0) {
        out.clear();
        for (var i = 0; i < outBlob.ref.cbData; i++) {
          out.add(outBlob.ref.pbData[i]);
        }
        _localFree(outBlob.ref.pbData.cast());
        return true;
      }
      return false;
    } finally {
      pkg.calloc.free(inBlob);
      pkg.calloc.free(inData);
      pkg.calloc.free(outBlob);
    }
  }

  static String? _unprotect(List<int> data) {
    final lib = _crypt32;
    if (lib == null) return null;
    final unprotect =
        lib.lookupFunction<_UnprotectNative, _UnprotectDart>('CryptUnprotectData');

    final inBlob = pkg.calloc<_DataBlob>(sizeOf<_DataBlob>());
    final inData = pkg.calloc<Uint8>(data.length);
    final outBlob = pkg.calloc<_DataBlob>(sizeOf<_DataBlob>());
    try {
      inBlob.ref.cbData = data.length;
      inBlob.ref.pbData = inData;
      for (var i = 0; i < data.length; i++) {
        inData[i] = data[i];
      }
      final ok =
          unprotect(inBlob, nullptr, nullptr, nullptr, nullptr, 0, outBlob);
      if (ok != 0 && outBlob.ref.cbData > 0) {
        final bytes = Uint8List(outBlob.ref.cbData);
        for (var i = 0; i < outBlob.ref.cbData; i++) {
          bytes[i] = outBlob.ref.pbData[i];
        }
        _localFree(outBlob.ref.pbData.cast());
        return utf8.decode(bytes);
      }
      return null;
    } finally {
      pkg.calloc.free(inBlob);
      pkg.calloc.free(inData);
      pkg.calloc.free(outBlob);
    }
  }

  // ---- 路径 / 落盘 ----

  static Directory get _dir {
    final appData = Platform.environment['APPDATA'] ?? '';
    return Directory('$appData\\EchOS\\secrets');
  }

  static File _file(String account) =>
      File('${_dir.path}${Platform.pathSeparator}${_safeName(account)}.bin');

  static Future<String?> read(String account) async {
    if (_crypt32 == null || _kernel32 == null) {
      return null;
    }
    try {
      final f = _file(account);
      if (!f.existsSync()) return null;
      return _unprotect(f.readAsBytesSync());
    } catch (_) {
      return null;
    }
  }

  static Future<bool> write(String account, String value) async {
    if (_crypt32 == null || _kernel32 == null) {
      return false;
    }
    try {
      final out = <int>[];
      if (!_protect(value, out)) return false;
      final f = _file(account);
      // 仅在实际写入时才创建目录：读取/删除不应留下空 secrets 目录。
      if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
      f.writeAsBytesSync(out, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 删除账号密码（如卸载 WebDAV 服务器时）。文件不存在视为成功。
  static Future<bool> delete(String account) async {
    try {
      final f = _file(account);
      if (!f.existsSync()) return true;
      f.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _safeName(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
}

// ---------------------------------------------------------------------------
// 提权：管理员检测 + 以管理员身份重启自身
// ---------------------------------------------------------------------------
//
// 为什么需要：TUN 模式要创建 Wintun 虚拟网卡、改路由表和网卡 DNS，三件事都
// 需要管理员权限。应用清单里写的是 asInvoker（不写 requestedExecutionLevel
// 就是它），所以默认不是管理员 —— 否则每次开机自启都要弹 UAC，托盘常驻的
// 体验就毁了。
//
// 因此策略是：默认按普通用户跑；用户打开 TUN 开关时，若当前不是管理员，
// 就提示并「以管理员身份重启」。整个应用提权（而不是只提权 x-tunnel.exe）是
// 刻意的选择：
//   1) 内核进程继续挂在 KILL_ON_JOB_CLOSE 作业对象里 —— 非管理员进程**不能**
//      把高完整性级别的进程塞进作业对象（ACCESS_DENIED），只提权内核就会
//      丢掉「主进程怎么死内核都跟着死」的兜底，留下孤儿内核。
//   2) 不需要改内核和打包链路，改动面小。
//
// 已知取舍：提权后「开机自启」若仍走 HKCU\...\Run，登录时起的是普通权限进程，
// TUN 会启动失败。这种情况由 AppState.start() 明确报错并给出「以管理员身份
// 重启」的入口，不做静默降级。

typedef _GetCurrentProcessNative = Pointer<Void> Function();
typedef _GetCurrentProcessDart = Pointer<Void> Function();

typedef _OpenProcessTokenNative = Int32 Function(
    Pointer<Void> hProcess, Uint32 desiredAccess, Pointer<Pointer<Void>> phToken);
typedef _OpenProcessTokenDart = int Function(
    Pointer<Void> hProcess, int desiredAccess, Pointer<Pointer<Void>> phToken);

typedef _GetTokenInformationNative = Int32 Function(Pointer<Void> token,
    Int32 infoClass, Pointer<Void> buf, Uint32 bufLen, Pointer<Uint32> retLen);
typedef _GetTokenInformationDart = int Function(Pointer<Void> token,
    int infoClass, Pointer<Void> buf, int bufLen, Pointer<Uint32> retLen);

typedef _CloseHandleNative = Int32 Function(Pointer<Void> hObject);
typedef _CloseHandleDart = int Function(Pointer<Void> hObject);

typedef _ShellExecuteNative = Pointer<Void> Function(
    Pointer<Void> hwnd,
    Pointer<pkg.Utf16> lpOperation,
    Pointer<pkg.Utf16> lpFile,
    Pointer<pkg.Utf16> lpParameters,
    Pointer<pkg.Utf16> lpDirectory,
    Int32 nShowCmd);
typedef _ShellExecuteDart = Pointer<Void> Function(
    Pointer<Void> hwnd,
    Pointer<pkg.Utf16> lpOperation,
    Pointer<pkg.Utf16> lpFile,
    Pointer<pkg.Utf16> lpParameters,
    Pointer<pkg.Utf16> lpDirectory,
    int nShowCmd);

class Elevation {
  static const int _tokenQuery = 0x0008;
  static const int _tokenElevation = 20; // TOKEN_INFORMATION_CLASS
  static const int _swShowNormal = 1;
  /// ShellExecuteW 返回值 ≤ 32 表示失败；用户取消 UAC 时是 SE_ERR_ACCESSDENIED(5)。
  static const int _shellExecuteMinSuccess = 32;

  static final DynamicLibrary? _kernel32 = _load('kernel32.dll');
  static final DynamicLibrary? _advapi32 = _load('advapi32.dll');
  static final DynamicLibrary? _shell32 = _load('shell32.dll');

  static DynamicLibrary? _load(String name) {
    try {
      return DynamicLibrary.open(name);
    } catch (_) {
      return null;
    }
  }

  /// 当前进程是否以管理员（高完整性级别）身份运行。
  /// 走 OpenProcessToken + GetTokenInformation(TokenElevation)，
  /// 不用已废弃的 shell32!IsUserAnAdmin。
  static bool get isElevated {
    final k32 = _kernel32;
    final adv = _advapi32;
    if (k32 == null || adv == null) return false;
    Pointer<Void>? token;
    final tokenPtr = pkg.calloc<Pointer<Void>>();
    final elevPtr = pkg.calloc<Uint32>(1);
    final retLenPtr = pkg.calloc<Uint32>(1);
    try {
      final getCurrentProcess = k32
          .lookupFunction<_GetCurrentProcessNative, _GetCurrentProcessDart>(
              'GetCurrentProcess');
      final openProcessToken = adv
          .lookupFunction<_OpenProcessTokenNative, _OpenProcessTokenDart>(
              'OpenProcessToken');
      final getTokenInformation = adv.lookupFunction<_GetTokenInformationNative,
          _GetTokenInformationDart>('GetTokenInformation');

      if (openProcessToken(
              getCurrentProcess(), _tokenQuery, tokenPtr) ==
          0) {
        return false;
      }
      token = tokenPtr.value;
      if (token == nullptr) return false;
      if (getTokenInformation(token, _tokenElevation, elevPtr.cast(), 4,
              retLenPtr) ==
          0) {
        return false;
      }
      return elevPtr.value != 0;
    } catch (_) {
      return false;
    } finally {
      if (token != null && token != nullptr && _kernel32 != null) {
        try {
          _kernel32!
              .lookupFunction<_CloseHandleNative, _CloseHandleDart>(
                  'CloseHandle')(token);
        } catch (_) {}
      }
      pkg.calloc.free(tokenPtr);
      pkg.calloc.free(elevPtr);
      pkg.calloc.free(retLenPtr);
    }
  }

  /// 以管理员身份重启自身。返回 null 表示新实例已拉起（**调用方应立即 exit(0)**），
  /// 否则返回给用户看的失败说明（UAC 被取消也会走到这里）。
  static Future<String?> relaunchElevated() async {
    final shell32 = _shell32;
    if (shell32 == null) return '无法加载 shell32.dll，提权失败';

    // 1) 先让位：关 IPC 端口 + 删单实例锁。必须在 ShellExecuteW 之前完成，
    //    否则新实例会认为「已有实例在跑」，唤起旧实例后自己退出。
    await InstanceGuard.releaseForRelaunch();

    // 2) 提权启动自身
    var rc = 0;
    try {
      final shellExecute = shell32
          .lookupFunction<_ShellExecuteNative, _ShellExecuteDart>(
              'ShellExecuteW');
      final op = 'runas'.toNativeUtf16();
      final file = Platform.resolvedExecutable.toNativeUtf16();
      try {
        final h = shellExecute(
            nullptr, op, file, nullptr, nullptr, _swShowNormal);
        rc = h.address;
      } finally {
        pkg.malloc.free(op);
        pkg.malloc.free(file);
      }
    } catch (e) {
      rc = 0;
    }

    if (rc > _shellExecuteMinSuccess) return null; // 成功，调用方 exit(0)

    // 3) 失败/被取消 → 把主人身份收回来，本实例继续正常跑
    await InstanceGuard.restoreAfterFailedRelaunch();
    if (rc == 5) return '已取消管理员授权，TUN 模式未启用。';
    return '以管理员身份重启失败（ShellExecuteW 返回 $rc），TUN 模式未启用。';
  }
}