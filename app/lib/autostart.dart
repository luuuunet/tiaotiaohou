import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// 开机自启。Windows 写当前用户 Run 项，macOS 写登录项，Linux 写 XDG autostart。
class Autostart {
  static const _valueName = 'TiaoTiaoHou';
  static const _subKey = r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const _macLabel = 'dev.rsq.tiaotiaohou';
  static const _linuxName = 'dev.rsq.rsq.desktop';

  static bool get supported => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static Future<bool> isEnabled() async {
    if (Platform.isMacOS) return _macEnabled();
    if (Platform.isLinux) return _linuxEnabled();
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
    if (Platform.isMacOS) return _macSet(enabled);
    if (Platform.isLinux) return _linuxSet(enabled);
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

  /// Desktop Entry 的 Exec 转义。空格写成反斜杠空格。
  static String desktopExec(String exe) {
    return exe.replaceAll('\\', '\\\\').replaceAll('"', r'\"').replaceAll(' ', r'\ ').replaceAll('`', r'\`').replaceAll(r'$', r'\$');
  }

  static String linuxAutostartEntry(String exe) {
    return '''
[Desktop Entry]
Type=Application
Version=1.0
Name=跳跳猴
Comment=一只会跳跳的猴子
Exec=${desktopExec(exe)} --quiet
Terminal=false
X-GNOME-Autostart-enabled=true
''';
  }

  static File? _linuxAutostartFile() {
    final xdg = Platform.environment['XDG_CONFIG_HOME'] ?? '';
    final home = Platform.environment['HOME'] ?? '';
    final root = xdg.isNotEmpty ? xdg : (home.isEmpty ? '' : '$home/.config');
    if (root.isEmpty) return null;
    return File('$root/autostart/$_linuxName');
  }

  static bool _linuxEnabled() {
    final file = _linuxAutostartFile();
    if (file == null || !file.existsSync()) return false;
    final text = file.readAsStringSync();
    if (text.contains('X-GNOME-Autostart-enabled=false')) return false;
    if (RegExp(r'^Hidden=true', multiLine: true).hasMatch(text)) return false;
    return text.contains(desktopExec(Platform.resolvedExecutable)) && text.contains('--quiet');
  }

  static Future<String?> _linuxSet(bool enabled) async {
    final file = _linuxAutostartFile();
    if (file == null) return '开机自启没有写进去';
    try {
      if (!enabled) {
        if (file.existsSync()) file.deleteSync();
        return null;
      }
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(linuxAutostartEntry(Platform.resolvedExecutable));
      return null;
    } catch (_) {
      return '开机自启没有写进去';
    }
  }

  static File get _macPlist {
    final home = Platform.environment['HOME'] ?? '';
    return File('$home/Library/LaunchAgents/$_macLabel.plist');
  }

  static bool _macEnabled() {
    if (!_macPlist.existsSync()) return false;
    final text = _macPlist.readAsStringSync();
    return text.contains(Platform.resolvedExecutable) && text.contains('--quiet');
  }

  static Future<String?> _macSet(bool enabled) async {
    try {
      if (!enabled) {
        if (_macPlist.existsSync()) _macPlist.deleteSync();
        return null;
      }
      final exe = Platform.resolvedExecutable;
      final plist = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$_macLabel</string>
  <key>ProgramArguments</key>
  <array>
    <string>$exe</string>
    <string>--quiet</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
''';
      _macPlist.parent.createSync(recursive: true);
      _macPlist.writeAsStringSync(plist);
      return null;
    } catch (_) {
      return '开机自启没有写进去';
    }
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
