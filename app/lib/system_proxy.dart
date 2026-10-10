import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

class SystemProxy {
  static Future<String?> enable(int port, {List<String> bypass = const []}) async {
    if (Platform.isWindows) return _windows(true, port, bypass);
    if (Platform.isMacOS) return _mac(true, port, bypass);
    return '这个系统要用应用自己的代理设置，地址是 127.0.0.1:$port';
  }

  static Future<String?> disable(int port) async {
    if (Platform.isWindows) return _windows(false, port, const []);
    if (Platform.isMacOS) return _mac(false, port, const []);
    return null;
  }

  /// 关掉指向本机的系统代理。端口变过也认，避免退出后浏览器还卡在旧代理上。
  static Future<void> clearLocal() async {
    if (Platform.isWindows) {
      final server = (_readString('ProxyServer') ?? '').toLowerCase();
      final enabled = _readDword('ProxyEnable') == 1;
      if (enabled && (server.startsWith('127.0.0.1:') || server.startsWith('localhost:'))) {
        await disable(0);
      }
      return;
    }
    if (Platform.isMacOS) {
      await _macClearLocal();
    }
  }

  /// 启动时清掉上次异常退出留下的本机代理，避免 Chrome 一直卡在死代理上。
  static Future<void> clearIfOurs(int port) async {
    if (Platform.isWindows) {
      final server = _readString('ProxyServer') ?? '';
      final enabled = _readDword('ProxyEnable') == 1;
      if (enabled && (server == '127.0.0.1:$port' || server == 'localhost:$port' || server == '127.0.0.1:0')) {
        await disable(port);
      }
      return;
    }
    if (Platform.isMacOS) {
      await _macClearPort(port);
    }
  }

  static Future<String?> _windows(bool enable, int port, List<String> bypass) async {
    final wrote = _writeProxy(enable, port, bypass);
    if (wrote != 0) {
      return '系统代理没有写进去';
    }
    _refreshWindows();
    return null;
  }

  static String proxyOverride(List<String> bypass) {
    final parts = <String>['localhost', '127.0.0.1', '<local>'];
    for (final host in bypass) {
      if (host.isEmpty) continue;
      parts.add(host);
      if (!host.startsWith('*.') && host.contains('.') && !_looksIpv4(host)) {
        parts.add('*.$host');
      }
    }
    return parts.join(';');
  }

  static bool _looksIpv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return false;
    return parts.every((p) {
      final n = int.tryParse(p);
      return n != null && n >= 0 && n <= 255;
    });
  }

  static int _writeProxy(bool enable, int port, List<String> bypass) {
    final advapi = DynamicLibrary.open('advapi32.dll');
    final setValue = advapi.lookupFunction<
        Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Uint32, Pointer<Void>, Uint32),
        int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Void>, int)>('RegSetKeyValueW');
    const key = -2147483647;
    final sub = r'Software\Microsoft\Windows\CurrentVersion\Internet Settings'.toNativeUtf16();
    var code = _setDword(setValue, key, sub, 'ProxyEnable', enable ? 1 : 0);
    if (enable && code == 0) {
      code = _setString(setValue, key, sub, 'ProxyServer', '127.0.0.1:$port');
    }
    if (enable && code == 0) {
      code = _setString(setValue, key, sub, 'ProxyOverride', proxyOverride(bypass));
    }
    calloc.free(sub);
    return code;
  }

  static int? _readDword(String name) {
    final advapi = DynamicLibrary.open('advapi32.dll');
    final getValue = advapi.lookupFunction<
        Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Uint32, Pointer<Uint32>, Pointer<Void>, Pointer<Uint32>),
        int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Uint32>, Pointer<Void>, Pointer<Uint32>)>('RegGetValueW');
    const key = -2147483647;
    final sub = r'Software\Microsoft\Windows\CurrentVersion\Internet Settings'.toNativeUtf16();
    final valueName = name.toNativeUtf16();
    final type = calloc<Uint32>();
    final data = calloc<Uint32>();
    final size = calloc<Uint32>()..value = 4;
    final code = getValue(key, sub, valueName, 0x00000010, type, data.cast(), size);
    final value = code == 0 ? data.value : null;
    calloc.free(sub);
    calloc.free(valueName);
    calloc.free(type);
    calloc.free(data);
    calloc.free(size);
    return value;
  }

  static String? _readString(String name) {
    final advapi = DynamicLibrary.open('advapi32.dll');
    final getValue = advapi.lookupFunction<
        Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Uint32, Pointer<Uint32>, Pointer<Void>, Pointer<Uint32>),
        int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Uint32>, Pointer<Void>, Pointer<Uint32>)>('RegGetValueW');
    const key = -2147483647;
    final sub = r'Software\Microsoft\Windows\CurrentVersion\Internet Settings'.toNativeUtf16();
    final valueName = name.toNativeUtf16();
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
    String? text;
    if (code == 0) {
      text = data.cast<Utf16>().toDartString();
    }
    calloc.free(sub);
    calloc.free(valueName);
    calloc.free(type);
    calloc.free(size);
    calloc.free(data);
    return text;
  }

  static int _setDword(
    int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Void>, int) setValue,
    int key,
    Pointer<Utf16> sub,
    String name,
    int value,
  ) {
    final valueName = name.toNativeUtf16();
    final data = calloc<Uint32>()..value = value;
    final code = setValue(key, sub, valueName, 4, data.cast(), 4);
    calloc.free(valueName);
    calloc.free(data);
    return code;
  }

  static int _setString(
    int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Void>, int) setValue,
    int key,
    Pointer<Utf16> sub,
    String name,
    String value,
  ) {
    final valueName = name.toNativeUtf16();
    final data = value.toNativeUtf16();
    final code = setValue(key, sub, valueName, 1, data.cast(), (value.length + 1) * 2);
    calloc.free(valueName);
    calloc.free(data);
    return code;
  }

  static void _refreshWindows() {
    final inet = DynamicLibrary.open('wininet.dll');
    final setOption = inet.lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32),
        int Function(int, int, Pointer<Void>, int)>('InternetSetOptionW');
    setOption(0, 39, nullptr, 0);
    setOption(0, 37, nullptr, 0);
  }

  static Future<List<String>> _macServices() async {
    final listed = await Process.run('networksetup', ['-listallnetworkservices']);
    if (listed.exitCode != 0) return const [];
    return (listed.stdout as String)
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('*') && !line.contains('asterisk'))
        .toList();
  }

  static Future<({bool enabled, String server, String port})?> _macWebProxy(String service) async {
    final result = await Process.run('networksetup', ['-getwebproxy', service]);
    if (result.exitCode != 0) return null;
    var enabled = false;
    var server = '';
    var port = '';
    for (final raw in (result.stdout as String).split('\n')) {
      final line = raw.trim();
      if (line.startsWith('Enabled:')) enabled = line.toLowerCase().contains('yes');
      if (line.startsWith('Server:')) server = line.substring('Server:'.length).trim();
      if (line.startsWith('Port:')) port = line.substring('Port:'.length).trim();
    }
    return (enabled: enabled, server: server, port: port);
  }

  static bool _isLocalProxy(String server) {
    final host = server.toLowerCase();
    return host == '127.0.0.1' || host == 'localhost';
  }

  static Future<void> _macClearLocal() async {
    for (final service in await _macServices()) {
      final proxy = await _macWebProxy(service);
      if (proxy != null && proxy.enabled && _isLocalProxy(proxy.server)) {
        await _macOff(service);
      }
    }
  }

  static Future<void> _macClearPort(int port) async {
    for (final service in await _macServices()) {
      final proxy = await _macWebProxy(service);
      if (proxy != null && proxy.enabled && _isLocalProxy(proxy.server) && (port == 0 || proxy.port == '$port')) {
        await _macOff(service);
      }
    }
  }

  static Future<void> _macOff(String service) async {
    await Process.run('networksetup', ['-setwebproxystate', service, 'off']);
    await Process.run('networksetup', ['-setsecurewebproxystate', service, 'off']);
  }

  static Future<String?> _mac(bool enable, int port, List<String> bypass) async {
    final services = await _macServices();
    if (services.isEmpty) return '没有可设置的网络服务';
    if (!enable) {
      for (final service in services) {
        await _macOff(service);
      }
      return null;
    }
    final domains = <String>['localhost', '127.0.0.1', '*.local'];
    for (final host in bypass) {
      if (host.isEmpty) continue;
      domains.add(host);
      if (!host.startsWith('*.') && host.contains('.') && !_looksIpv4(host)) {
        domains.add('*.$host');
      }
    }
    var ok = 0;
    for (final service in services) {
      final web = await Process.run('networksetup', ['-setwebproxy', service, '127.0.0.1', '$port']);
      final secure = await Process.run('networksetup', ['-setsecurewebproxy', service, '127.0.0.1', '$port']);
      if (web.exitCode != 0 || secure.exitCode != 0) continue;
      await Process.run('networksetup', ['-setproxybypassdomains', service, ...domains]);
      ok++;
    }
    if (ok == 0) return '设置系统代理失败';
    return null;
  }
}
