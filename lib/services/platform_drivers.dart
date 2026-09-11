// 平台驱动：开机自启 + 密码存储（Windows）。
// 注册表 Run / DPAPI（FFI 直调 crypt32）。
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkg;

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