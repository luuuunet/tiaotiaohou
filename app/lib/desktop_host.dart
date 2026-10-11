import 'dart:io';

import 'package:flutter/services.dart';

/// 桌面窗口、托盘和通知。
class DesktopHost {
  DesktopHost._();

  static const channel = MethodChannel('dev.rsq/host');
  static bool get supported => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static Future<void> hideToTray() async {
    if (!supported) return;
    await channel.invokeMethod<void>('hideToTray');
  }

  static Future<void> showWindow() async {
    if (!supported) return;
    await channel.invokeMethod<void>('showWindow');
  }

  static Future<void> quit() async {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      try {
        await channel.invokeMethod<void>('quit');
        return;
      } catch (_) {
        exit(0);
      }
    }
    exit(0);
  }

  static Future<void> setTrayTip(String text) async {
    if (!supported) return;
    await channel.invokeMethod<void>('setTrayTip', {'text': text});
  }

  static Future<void> notify({required String title, required String body}) async {
    if (Platform.isMacOS) {
      final script = 'display notification ${jsonString(body)} with title ${jsonString(title)}';
      await Process.run('osascript', ['-e', script]);
      return;
    }
    if (Platform.isLinux) {
      await _linuxNotify(title, body);
      return;
    }
    if (!supported) return;
    await channel.invokeMethod<void>('notify', {'title': title, 'body': body});
  }

  static Future<void> _linuxNotify(String title, String body) async {
    try {
      final result = await Process.run('gdbus', [
        'call',
        '--session',
        '--dest',
        'org.freedesktop.Notifications',
        '--object-path',
        '/org/freedesktop/Notifications',
        '--method',
        'org.freedesktop.Notifications.Notify',
        _gvariant('跳跳猴'),
        '0',
        "''",
        _gvariant(title),
        _gvariant(body),
        '[]',
        '{}',
        '5000',
      ]);
      if (result.exitCode == 0) return;
    } catch (_) {}
    try {
      await Process.run('notify-send', ['--app-name=跳跳猴', title, body]);
    } catch (_) {}
  }

  static String _gvariant(String text) {
    return "'${text.replaceAll('\\', '\\\\').replaceAll("'", r"\'")}'";
  }

  static String jsonString(String text) {
    final escaped = text.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
    return '"$escaped"';
  }

  static void listen({
    Future<void> Function()? onShow,
    Future<void> Function()? onToggle,
    Future<void> Function()? onQuit,
    Future<void> Function()? onNetworkChanged,
    Future<void> Function()? onSessionUnlock,
  }) {
    if (!supported) return;
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'trayShow':
          await onShow?.call();
        case 'trayToggle':
          await onToggle?.call();
        case 'trayQuit':
          await onQuit?.call();
        case 'networkChanged':
          await onNetworkChanged?.call();
        case 'sessionUnlock':
          await onSessionUnlock?.call();
      }
    });
  }
}
