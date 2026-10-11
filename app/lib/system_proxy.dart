import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

class SystemProxy {
  static Future<String?> enable(int port, {List<String> bypass = const [], int socksPort = 1080}) async {
    if (Platform.isWindows) return _windows(true, port, bypass);
    if (Platform.isMacOS) return _mac(true, port, bypass, socksPort);
    if (Platform.isLinux) return _linux(true, port, bypass, socksPort);
    return '这个系统要用应用自己的代理设置，地址是 127.0.0.1:$port';
  }

  static Future<String?> disable(int port) async {
    if (Platform.isWindows) return _windows(false, port, const []);
    if (Platform.isMacOS) return _mac(false, port, const [], 0);
    if (Platform.isLinux) return _linux(false, port, const [], 0);
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
      return;
    }
    if (Platform.isLinux) await _linuxClear(0);
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
      return;
    }
    if (Platform.isLinux) await _linuxClear(port);
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

  static Future<({bool enabled, String server, String port})?> _macProxy(String service, String flag) async {
    final result = await Process.run('networksetup', [flag, service]);
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

  static Future<({bool enabled, String server, String port})?> _macWebProxy(String service) {
    return _macProxy(service, '-getwebproxy');
  }

  static Future<({bool enabled, String server, String port})?> _macSocksProxy(String service) {
    return _macProxy(service, '-getsocksfirewallproxy');
  }

  static bool _isLocalProxy(String server) {
    final host = server.toLowerCase();
    return host == '127.0.0.1' || host == 'localhost';
  }

  static Future<void> _macClearLocal() async {
    for (final service in await _macServices()) {
      final proxy = await _macWebProxy(service);
      final socks = await _macSocksProxy(service);
      final webOurs = proxy != null && proxy.enabled && _isLocalProxy(proxy.server);
      final socksOurs = socks != null && socks.enabled && _isLocalProxy(socks.server);
      if (webOurs || socksOurs) {
        await _macOff(service);
      }
    }
  }

  static Future<void> _macClearPort(int port) async {
    for (final service in await _macServices()) {
      final proxy = await _macWebProxy(service);
      final socks = await _macSocksProxy(service);
      final webOurs = proxy != null && proxy.enabled && _isLocalProxy(proxy.server) && (port == 0 || proxy.port == '$port');
      final socksOurs = socks != null && socks.enabled && _isLocalProxy(socks.server);
      if (webOurs || socksOurs) {
        await _macOff(service);
      }
    }
  }

  static Future<void> _macOff(String service) async {
    await Process.run('networksetup', ['-setwebproxystate', service, 'off']);
    await Process.run('networksetup', ['-setsecurewebproxystate', service, 'off']);
    await Process.run('networksetup', ['-setsocksfirewallproxystate', service, 'off']);
  }

  static Future<String?> _mac(bool enable, int port, List<String> bypass, int socksPort) async {
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
      if (socksPort > 0) {
        await Process.run('networksetup', ['-setsocksfirewallproxy', service, '127.0.0.1', '$socksPort']);
      }
      await Process.run('networksetup', ['-setproxybypassdomains', service, ...domains]);
      ok++;
    }
    if (ok == 0) return '设置系统代理失败';
    return null;
  }

  /// GNOME `ignore-hosts` 的 GVariant 文本。
  static String gnomeIgnoreHosts(List<String> bypass) {
    final parts = <String>['localhost', '127.0.0.1', '::1'];
    final seen = <String>{...parts};
    for (final host in bypass) {
      if (host.isEmpty || host.contains(' ') || host.contains("'")) continue;
      if (seen.add(host)) parts.add(host);
      if (!host.startsWith('*.') && host.contains('.') && !_looksIpv4(host)) {
        final wild = '*.$host';
        if (seen.add(wild)) parts.add(wild);
      }
    }
    return '[${parts.map((host) => "'${host.replaceAll('\\', '\\\\')}'").join(', ')}]';
  }

  static String gnomeUnquote(String raw) {
    final text = raw.trim();
    if (text.length >= 2 && ((text.startsWith("'") && text.endsWith("'")) || (text.startsWith('"') && text.endsWith('"')))) {
      return text.substring(1, text.length - 1);
    }
    return text;
  }

  static String kdeNoProxy(List<String> bypass) {
    final parts = <String>['localhost', '127.0.0.1', '::1'];
    final seen = <String>{...parts};
    for (final host in bypass) {
      if (host.isEmpty || host.contains(',') || host.contains(' ')) continue;
      if (seen.add(host)) parts.add(host);
      if (!host.startsWith('*.') && host.contains('.') && !_looksIpv4(host)) {
        final wild = '*.$host';
        if (seen.add(wild)) parts.add(wild);
      }
    }
    return parts.join(',');
  }

  static bool kdeProxyIsLocal(Map<String, String> keys) {
    if ((keys['ProxyType'] ?? '') != '1') return false;
    final blob = '${keys['httpProxy'] ?? ''} ${keys['httpsProxy'] ?? ''} ${keys['socksProxy'] ?? ''}'.toLowerCase();
    return blob.contains('127.0.0.1') || blob.contains('localhost');
  }

  /// 只改 `[Proxy Settings]`。不是本机代理时原样返回。
  static String rewriteKdeProxyFile(
    String existing, {
    required bool enable,
    required int httpPort,
    int socksPort = 1080,
    String noProxy = 'localhost,127.0.0.1,::1',
  }) {
    final text = existing.replaceAll('\r\n', '\n');
    final start = _iniHeader(text, 'Proxy Settings');
    if (start < 0) {
      if (!enable) return existing;
      final block = _kdeBlock(httpPort: httpPort, socksPort: socksPort, noProxy: noProxy);
      if (text.isEmpty) return block;
      final gap = text.endsWith('\n') ? '\n' : '\n\n';
      return '$text$gap$block';
    }
    final end = _iniNextHeader(text, start);
    final body = text.substring(start, end);
    if (!enable) {
      if (!kdeProxyIsLocal(_iniKeys(body))) return existing;
      final cleared = _setIniKey(body, 'ProxyType', '0');
      return text.substring(0, start) + cleared + text.substring(end);
    }
    final block = _kdeBlock(httpPort: httpPort, socksPort: socksPort, noProxy: noProxy);
    return text.substring(0, start) + block + text.substring(end);
  }

  static int _iniHeader(String text, String name) {
    final header = '[$name]';
    var offset = 0;
    for (final line in text.split('\n')) {
      if (line.trim() == header) return offset;
      offset += line.length + 1;
    }
    return -1;
  }

  static int _iniNextHeader(String text, int from) {
    final lines = text.substring(from).split('\n');
    var offset = from;
    var first = true;
    for (final line in lines) {
      if (!first && RegExp(r'^\s*\[.+\]\s*$').hasMatch(line)) return offset;
      first = false;
      offset += line.length + 1;
      if (offset > text.length) return text.length;
    }
    return text.length;
  }

  static Map<String, String> _iniKeys(String body) {
    final keys = <String, String>{};
    for (final line in body.split('\n')) {
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      keys[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
    }
    return keys;
  }

  static String _setIniKey(String body, String key, String value) {
    final lines = body.split('\n');
    var found = false;
    for (var i = 0; i < lines.length; i++) {
      final eq = lines[i].indexOf('=');
      if (eq <= 0) continue;
      if (lines[i].substring(0, eq).trim() == key) {
        lines[i] = '$key=$value';
        found = true;
        break;
      }
    }
    if (!found) lines.insert(lines.isEmpty ? 0 : 1, '$key=$value');
    var text = lines.join('\n');
    if (!text.endsWith('\n')) text = '$text\n';
    return text;
  }

  static String _kdeBlock({required int httpPort, required int socksPort, required String noProxy}) {
    final lines = <String>[
      '[Proxy Settings]',
      'ProxyType=1',
      'httpProxy=http://127.0.0.1:$httpPort',
      'httpsProxy=http://127.0.0.1:$httpPort',
      'ftpProxy=http://127.0.0.1:$httpPort',
      if (socksPort > 0) 'socksProxy=socks://127.0.0.1:$socksPort',
      'NoProxyFor=$noProxy',
      'ReversedException=false',
    ];
    return '${lines.join('\n')}\n';
  }

  static bool _desktopIsKde() {
    final desktop = '${Platform.environment['XDG_CURRENT_DESKTOP'] ?? ''} ${Platform.environment['DESKTOP_SESSION'] ?? ''}'.toLowerCase();
    return desktop.contains('kde') || desktop.contains('plasma');
  }

  static String? _kdeFilePath() {
    final xdg = Platform.environment['XDG_CONFIG_HOME'] ?? '';
    if (xdg.isNotEmpty) return '$xdg/kioslaverc';
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return null;
    return '$home/.config/kioslaverc';
  }

  static Future<bool> _gnomeSchemaPresent() async {
    try {
      final result = await Process.run('gsettings', ['list-schemas']);
      if (result.exitCode != 0) return false;
      return '${result.stdout}'.split('\n').any((line) => line.trim() == 'org.gnome.system.proxy');
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _gget(String schema, String key) async {
    try {
      final result = await Process.run('gsettings', ['get', schema, key]);
      if (result.exitCode != 0) return null;
      return gnomeUnquote('${result.stdout}');
    } catch (_) {
      return null;
    }
  }

  static Future<int> _gset(String schema, String key, String value) async {
    try {
      final result = await Process.run('gsettings', ['set', schema, key, value]);
      return result.exitCode;
    } catch (_) {
      return 1;
    }
  }

  static Future<bool> _gnomeIsOurs(int port) async {
    final mode = await _gget('org.gnome.system.proxy', 'mode');
    final host = await _gget('org.gnome.system.proxy.http', 'host');
    final current = await _gget('org.gnome.system.proxy.http', 'port');
    if (mode != 'manual' || !_isLocalProxy(host ?? '')) return false;
    if (port != 0 && current != '$port') return false;
    return true;
  }

  static Future<String?> _gnomeApply(bool enable, int port, List<String> bypass, int socksPort) async {
    if (!enable) {
      if (!await _gnomeIsOurs(0)) return null;
      if (await _gset('org.gnome.system.proxy', 'mode', "'none'") != 0) return '系统代理没有关掉';
      return null;
    }
    final sets = <List<String>>[
      ['org.gnome.system.proxy', 'mode', "'manual'"],
      ['org.gnome.system.proxy.http', 'host', "'127.0.0.1'"],
      ['org.gnome.system.proxy.http', 'port', '$port'],
      ['org.gnome.system.proxy.https', 'host', "'127.0.0.1'"],
      ['org.gnome.system.proxy.https', 'port', '$port'],
      if (socksPort > 0) ...[
        ['org.gnome.system.proxy.socks', 'host', "'127.0.0.1'"],
        ['org.gnome.system.proxy.socks', 'port', '$socksPort'],
      ],
      ['org.gnome.system.proxy', 'ignore-hosts', gnomeIgnoreHosts(bypass)],
    ];
    for (final item in sets) {
      if (await _gset(item[0], item[1], item[2]) != 0) return '设置系统代理失败';
    }
    return null;
  }

  static Future<String?> _kdeApply(bool enable, int port, List<String> bypass, int socksPort) async {
    final path = _kdeFilePath();
    if (path == null) return enable ? '系统代理没有写进去' : null;
    final file = File(path);
    final existing = file.existsSync() ? file.readAsStringSync() : '';
    final next = rewriteKdeProxyFile(existing, enable: enable, httpPort: port, socksPort: socksPort, noProxy: kdeNoProxy(bypass));
    if (next == existing) return null;
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(next);
    } catch (_) {
      return enable ? '系统代理没有写进去' : '系统代理没有关掉';
    }
    try {
      await Process.run('dbus-send', [
        '--session',
        '--type=signal',
        '/KIO/Scheduler',
        'org.kde.KIO.Scheduler.reparseSlaveConfiguration',
        'string:',
      ]);
    } catch (_) {}
    return null;
  }

  static Future<void> _linuxClear(int port) async {
    if (await _gnomeSchemaPresent() && await _gnomeIsOurs(port)) {
      await _gset('org.gnome.system.proxy', 'mode', "'none'");
    }
    final path = _kdeFilePath();
    if (path == null) return;
    final file = File(path);
    if (!file.existsSync()) return;
    final existing = file.readAsStringSync();
    final start = _iniHeader(existing.replaceAll('\r\n', '\n'), 'Proxy Settings');
    if (start < 0) return;
    final text = existing.replaceAll('\r\n', '\n');
    final body = text.substring(start, _iniNextHeader(text, start));
    final keys = _iniKeys(body);
    if (!kdeProxyIsLocal(keys)) return;
    if (port != 0 && !(keys['httpProxy'] ?? '').endsWith(':$port')) return;
    final next = rewriteKdeProxyFile(existing, enable: false, httpPort: port);
    if (next == existing) return;
    try {
      file.writeAsStringSync(next);
    } catch (_) {}
  }

  static Future<String?> _linux(bool enable, int port, List<String> bypass, int socksPort) async {
    final gnome = await _gnomeSchemaPresent();
    final kde = _desktopIsKde();
    if (!gnome && !kde) {
      if (!enable) return null;
      return '这个桌面不能自动设置系统代理，浏览器请填 127.0.0.1:$port';
    }
    if (!enable) {
      final gnomeError = gnome ? await _gnomeApply(false, port, bypass, socksPort) : null;
      final kdeError = kde ? await _kdeApply(false, port, bypass, socksPort) : null;
      return gnomeError ?? kdeError;
    }
    String? failure;
    var ok = false;
    if (gnome) {
      final err = await _gnomeApply(true, port, bypass, socksPort);
      if (err == null) {
        ok = true;
      } else {
        failure = err;
      }
    }
    if (kde) {
      final err = await _kdeApply(true, port, bypass, socksPort);
      if (err == null) {
        ok = true;
      } else if (_desktopIsKde()) {
        return err;
      } else {
        failure ??= err;
      }
    }
    if (ok) return null;
    return failure ?? '设置系统代理失败';
  }
}
