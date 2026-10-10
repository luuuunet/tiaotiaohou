import 'dart:io';

import 'package:flutter/services.dart';

/// Windows 托盘 / 窗口宿主通道。
class DesktopHost {
  DesktopHost._();

  static const channel = MethodChannel('dev.rsq/host');
  static bool get supported => Platform.isWindows || Platform.isMacOS;

  static Future<void> hideToTray() async {
    if (!supported) return;
    await channel.invokeMethod<void>('hideToTray');
  }

  static Future<void> showWindow() async {
    if (!supported) return;
    await channel.invokeMethod<void>('showWindow');
  }

  static Future<void> quit() async {
    if (Platform.isWindows || Platform.isMacOS) {
      await channel.invokeMethod<void>('quit');
      return;
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
    if (!supported) return;
    await channel.invokeMethod<void>('notify', {'title': title, 'body': body});
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
