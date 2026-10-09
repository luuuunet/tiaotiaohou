import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Windows 开机自启（当前用户 Run 项）。
class Autostart {
  static const _valueName = 'TiaoTiaoHou';
  static const _subKey = r'Software\Microsoft\Windows\CurrentVersion\Run';

  static bool get supported => Platform.isWindows;

  static Future<bool> isEnabled() async {
    if (!supported) return false;
    final current = _read();
    if (current == null || current.isEmpty) return false;
    final exe = Platform.resolvedExecutable.replaceAll('/', '\\').toLowerCase();
    if (!current.toLowerCase().contains(exe)) return false;
    if (!current.toLowerCase().contains('--quiet')) {
      await setEnabled(true);
    }
    return true;
  }

  static Future<String?> setEnabled(bool enabled) async {
    if (!supported) return '这个系统暂不支持开机自启';
    if (enabled) {
      final path = Platform.resolvedExecutable.replaceAll('/', '\\');
      final wrote = _setString(_valueName, '"$path" --quiet');
      if (wrote != 0) return '开机自启没有写进去';
      return null;
    }
    final deleted = _delete(_valueName);
    // 2 = ERROR_FILE_NOT_FOUND，本来就没有也算成功
    if (deleted != 0 && deleted != 2) return '关掉开机自启失败';
    return null;
  }

  static String? _read() {
    final advapi = DynamicLibrary.open('advapi32.dll');
    final getValue = advapi.lookupFunction<
        Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Uint32, Pointer<Uint32>, Pointer<Void>, Pointer<Uint32>),
        int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Uint32>, Pointer<Void>, Pointer<Uint32>)>('RegGetValueW');
    const key = -2147483647; // HKCU
    final sub = _subKey.toNativeUtf16();
    final valueName = _valueName.toNativeUtf16();
    final type = calloc<Uint32>();
    final size = calloc<Uint32>()..value = 0;
    getValue(key, sub, valueName, 0x00000002, type, nullptr, size);
    if (size.value == 0) {
      calloc.free(sub);
      calloc.free(valueName);
      calloc.free(type);
      calloc.free(size);
      return null;
    }
    final data = calloc<Uint8>(size.value);
    final code = getValue(key, sub, valueName, 0x00000002, type, data.cast(), size);
    final text = code == 0 ? data.cast<Utf16>().toDartString() : null;
    calloc.free(sub);
    calloc.free(valueName);
    calloc.free(type);
    calloc.free(size);
    calloc.free(data);
    return text;
  }

  static int _setString(String name, String value) {
    final advapi = DynamicLibrary.open('advapi32.dll');
    final setValue = advapi.lookupFunction<
        Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Uint32, Pointer<Void>, Uint32),
        int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Void>, int)>('RegSetKeyValueW');
    const key = -2147483647;
    final sub = _subKey.toNativeUtf16();
    final valueName = name.toNativeUtf16();
    final data = value.toNativeUtf16();
    final code = setValue(key, sub, valueName, 1, data.cast(), (value.length + 1) * 2);
    calloc.free(sub);
    calloc.free(valueName);
    calloc.free(data);
    return code;
  }

  static int _delete(String name) {
    final advapi = DynamicLibrary.open('advapi32.dll');
    final deleteValue = advapi.lookupFunction<
        Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>),
        int Function(int, Pointer<Utf16>, Pointer<Utf16>)>('RegDeleteKeyValueW');
    const key = -2147483647;
    final sub = _subKey.toNativeUtf16();
    final valueName = name.toNativeUtf16();
    final code = deleteValue(key, sub, valueName);
    calloc.free(sub);
    calloc.free(valueName);
    return code;
  }
}
