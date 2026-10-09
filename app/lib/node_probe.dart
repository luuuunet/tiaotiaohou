import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'nodes.dart';

class NodeProbe {
  const NodeProbe({required this.ok, required this.ms, required this.detail});

  final bool ok;
  final int ms;
  final String detail;

  String get label => ok ? '正常' : '不可用';
}

HttpClient _client() {
  final client = HttpClient();
  client.findProxy = (_) => 'DIRECT';
  client.connectionTimeout = const Duration(seconds: 8);
  client.badCertificateCallback = (_, __, ___) => true;
  return client;
}

Future<NodeProbe> probeNode(VpnNode node) async {
  final started = DateTime.now();
  int ms() => DateTime.now().difference(started).inMilliseconds;
  if (!node.ready) {
    return NodeProbe(ok: false, ms: 0, detail: '节点不完整');
  }
  try {
    if (node.exitVia == 'vps') {
      return await _probeTls(node, ms);
    }
    return await _probeHealth(node, ms);
  } on SocketException {
    return NodeProbe(ok: false, ms: ms(), detail: '连不上');
  } on HandshakeException {
    return NodeProbe(ok: false, ms: ms(), detail: '证书或握手失败');
  } on TimeoutException {
    return NodeProbe(ok: false, ms: ms(), detail: '超时');
  } catch (_) {
    return NodeProbe(ok: false, ms: ms(), detail: '测试失败');
  }
}

Future<NodeProbe> _probeHealth(VpnNode node, int Function() ms) async {
  final origin = node.endpoint.replaceFirst(RegExp(r'/$'), '');
  final client = _client();
  try {
    final request = await client.getUrl(Uri.parse('$origin/rsq/v1/health')).timeout(const Duration(seconds: 8));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${node.token}');
    final response = await request.close().timeout(const Duration(seconds: 8));
    await response.drain<void>();
    if (response.statusCode == 200) {
      return NodeProbe(ok: true, ms: ms(), detail: '节点正常');
    }
    if (response.statusCode == 401) {
      return NodeProbe(ok: false, ms: ms(), detail: '令牌不对');
    }
    return NodeProbe(ok: false, ms: ms(), detail: '状态 ${response.statusCode}');
  } finally {
    client.close(force: true);
  }
}

Future<NodeProbe> _probeTls(VpnNode node, int Function() ms) async {
  final uri = Uri.tryParse(node.endpoint);
  final host = uri?.host ?? '';
  final port = uri?.hasPort == true ? uri!.port : 8444;
  if (host.isEmpty) {
    return NodeProbe(ok: false, ms: 0, detail: '地址不合法');
  }
  final socket = await SecureSocket.connect(
    host,
    port,
    onBadCertificate: (_) => true,
    timeout: const Duration(seconds: 8),
  );
  socket.destroy();
  return NodeProbe(ok: true, ms: ms(), detail: '端口可连');
}

class SpeedSample {
  const SpeedSample({required this.ok, required this.label});
  final bool ok;
  final String label;
}

String formatSpeed(int bytes, double seconds) {
  if (seconds <= 0 || bytes <= 0) return '—';
  final mega = bytes / seconds / (1024 * 1024);
  if (mega >= 1) return '${mega.toStringAsFixed(1)} MB/s';
  final kilo = mega * 1024;
  if (kilo >= 1) return '${kilo.toStringAsFixed(0)} KB/s';
  return '${(kilo * 1024).toStringAsFixed(0)} B/s';
}

HttpClient _proxyClient(int httpPort, {int hosts = 8}) {
  final client = HttpClient();
  client.findProxy = (_) => 'PROXY 127.0.0.1:$httpPort';
  client.badCertificateCallback = (_, __, ___) => true;
  client.connectionTimeout = const Duration(seconds: 12);
  client.idleTimeout = const Duration(seconds: 20);
  client.maxConnectionsPerHost = hosts;
  return client;
}

/// 节点主机的 ICMP ping，只显示往返毫秒，不含 HTTPS / 健康检查。
Future<SpeedSample> measurePing(String host) async {
  final target = host.trim();
  if (target.isEmpty) return const SpeedSample(ok: false, label: '失败');
  final args = Platform.isWindows
      ? <String>['-n', '3', '-w', '1500', target]
      : <String>['-c', '3', '-W', '2', target];
  late final ProcessResult r;
  try {
    r = await Process.run('ping', args).timeout(const Duration(seconds: 8));
  } on TimeoutException {
    return const SpeedSample(ok: false, label: '失败');
  } catch (_) {
    return const SpeedSample(ok: false, label: '失败');
  }
  final text = '${r.stdout}\n${r.stderr}';
  final avg = RegExp(r'(?:Average|平均)\s*=\s*(\d+)').firstMatch(text);
  if (avg != null) return SpeedSample(ok: true, label: '${avg.group(1)}ms');
  final times = <int>[
    for (final m in RegExp(r'(?:time|时间)\s*[=<]\s*(\d+)').allMatches(text)) int.parse(m.group(1)!),
  ];
  if (times.isEmpty) return const SpeedSample(ok: false, label: '失败');
  times.sort();
  return SpeedSample(ok: true, label: '${times[times.length ~/ 2]}ms');
}

Future<bool> _tinyGet(int httpPort, String url) async {
  final client = _proxyClient(httpPort);
  try {
    final request = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 8));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 8));
    await response.drain<void>().timeout(const Duration(seconds: 4));
    return response.statusCode < 500;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// 多路并行下载，先丢掉开头一小段，再计 5 秒里真正下来的数据。
Future<SpeedSample> measureDownload(
  int httpPort, {
  void Function(String label)? onProgress,
  bool Function()? shouldStop,
}) async {
  const sources = <(String, int)>[
    ('https://speed.cloudflare.com/__down?bytes=25000000', 4),
    ('https://cachefly.cachefly.net/100mb.test', 4),
  ];
  await _tinyGet(httpPort, 'https://www.gstatic.com/generate_204');
  for (final source in sources) {
    final sample = await _downloadFast(httpPort, source.$1, source.$2, onProgress, shouldStop);
    if (sample.ok) return sample;
  }
  return const SpeedSample(ok: false, label: '失败');
}

void _report(DateTime? clock, int counted, void Function(String label)? onProgress, List<DateTime?> gate) {
  if (onProgress == null || clock == null || counted <= 0) return;
  final now = DateTime.now();
  final last = gate[0];
  if (last != null && now.difference(last) < const Duration(milliseconds: 200)) return;
  final seconds = now.difference(clock).inMilliseconds / 1000;
  if (seconds < 0.25) return;
  gate[0] = now;
  onProgress(formatSpeed(counted, seconds));
}

Future<SpeedSample> _downloadFast(
  int httpPort,
  String url,
  int streams,
  void Function(String label)? onProgress,
  bool Function()? shouldStop,
) async {
  var counted = 0;
  DateTime? clock;
  var stop = false;
  int? frozenMs;
  int? frozenBytes;
  final gate = <DateTime?>[null];
  void considerStop() {
    if (shouldStop?.call() == true) stop = true;
    if (clock == null) return;
    final ms = DateTime.now().difference(clock!).inMilliseconds;
    if (ms >= 5000 && frozenMs == null) {
      stop = true;
      frozenMs = ms;
      frozenBytes = counted;
    }
  }
  Future<void> one(int i) async {
    final client = _proxyClient(httpPort, hosts: streams);
    var warmed = 0;
    try {
      final base = Uri.parse(url);
      final uri = base.replace(
        queryParameters: base.host.contains('cloudflare')
            ? {
                ...base.queryParameters,
                'n': '$i',
                't': '${DateTime.now().microsecondsSinceEpoch}',
              }
            : base.queryParameters,
      );
      final request = await client.getUrl(uri).timeout(const Duration(seconds: 12));
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await request.close().timeout(const Duration(seconds: 12));
      if (response.statusCode >= 400) return;
      await for (final chunk in response) {
        considerStop();
        if (stop) break;
        if (warmed < 256 * 1024) {
          warmed += chunk.length;
          continue;
        }
        clock ??= DateTime.now();
        counted += chunk.length;
        _report(clock, counted, onProgress, gate);
        considerStop();
        if (stop) break;
      }
    } catch (_) {}
    client.close(force: true);
  }

  await Future.wait(<Future<void>>[for (var i = 0; i < streams; i++) one(i)]);
  final bytes = frozenBytes ?? counted;
  final started = clock;
  if (started == null || bytes < 256 * 1024) {
    return const SpeedSample(ok: false, label: '失败');
  }
  final seconds = (frozenMs ?? DateTime.now().difference(started).inMilliseconds) / 1000;
  return SpeedSample(ok: true, label: formatSpeed(bytes, seconds));
}

/// 多路并行上传。只计服务器真正收下的数据，握手和回显都不算进速度。
Future<SpeedSample> measureUpload(
  int httpPort, {
  void Function(String label)? onProgress,
  bool Function()? shouldStop,
}) async {
  await _tinyGet(httpPort, 'https://www.gstatic.com/generate_204');
  final sample = await _uploadFast(httpPort, 'https://speed.cloudflare.com/__up', 4, onProgress, shouldStop);
  if (sample.ok) return sample;
  return const SpeedSample(ok: false, label: '失败');
}

Future<SpeedSample> _uploadFast(
  int httpPort,
  String url,
  int streams,
  void Function(String label)? onProgress,
  bool Function()? shouldStop,
) async {
  var counted = 0;
  DateTime? clock;
  var stop = false;
  int? frozenMs;
  int? frozenBytes;
  final gate = <DateTime?>[null];
  final chunk = Uint8List(64 * 1024);
  void considerStop() {
    if (shouldStop?.call() == true) stop = true;
    if (clock == null) return;
    final ms = DateTime.now().difference(clock!).inMilliseconds;
    if (ms >= 5000 && frozenMs == null) {
      stop = true;
      frozenMs = ms;
      frozenBytes = counted;
    }
  }

  Future<void> one(int i) async {
    final client = _proxyClient(httpPort, hosts: streams);
    var warmed = 0;
    try {
      final request = await client
          .postUrl(Uri.parse('$url?n=$i&t=${DateTime.now().microsecondsSinceEpoch}'))
          .timeout(const Duration(seconds: 12));
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/octet-stream');
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      await request.addStream(() async* {
        while (!stop) {
          considerStop();
          if (stop) break;
          yield chunk;
          if (warmed < 256 * 1024) {
            warmed += chunk.length;
            continue;
          }
          clock ??= DateTime.now();
          counted += chunk.length;
          _report(clock, counted, onProgress, gate);
          considerStop();
        }
      }()).timeout(const Duration(seconds: 20));
      final response = await request.close().timeout(const Duration(seconds: 20));
      await response.drain<void>().timeout(const Duration(seconds: 8));
    } catch (_) {}
    client.close(force: true);
  }

  await Future.wait(<Future<void>>[for (var i = 0; i < streams; i++) one(i)]);
  final bytes = frozenBytes ?? counted;
  final started = clock;
  if (started == null || bytes < 128 * 1024) {
    return const SpeedSample(ok: false, label: '失败');
  }
  final seconds = (frozenMs ?? DateTime.now().difference(started).inMilliseconds) / 1000;
  return SpeedSample(ok: true, label: formatSpeed(bytes, seconds));
}
