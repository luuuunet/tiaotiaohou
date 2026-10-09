import 'dart:async';
import 'dart:convert';
import 'dart:io';

class CfBestIp {
  const CfBestIp({required this.ip, required this.ms, this.colo = ''});

  final String ip;
  final int ms;
  final String colo;

  String get label {
    if (colo.isEmpty) return '$ip · ${ms}ms';
    return '$ip · $colo · ${ms}ms';
  }
}

const _cacheHours = 6;

/// Cloudflare anycast samples. SNI stays on the Worker hostname.
const _seeds = <String>[
  '104.16.1.1',
  '104.16.20.8',
  '104.16.80.1',
  '104.16.160.1',
  '104.16.248.1',
  '104.17.1.1',
  '104.17.80.1',
  '104.17.160.1',
  '104.18.1.1',
  '104.18.32.7',
  '104.18.80.1',
  '104.18.160.1',
  '104.19.1.1',
  '104.19.80.1',
  '104.21.1.1',
  '104.21.16.1',
  '104.21.48.1',
  '104.21.80.1',
  '104.22.1.1',
  '104.22.16.1',
  '104.24.0.2',
  '104.25.1.1',
  '104.26.1.1',
  '104.27.1.1',
  '172.64.32.1',
  '172.64.80.1',
  '172.67.70.238',
  '172.67.128.1',
  '172.67.160.1',
  '172.67.192.1',
  '162.159.36.1',
  '162.159.46.1',
  '162.159.128.1',
  '162.159.135.1',
  '162.159.136.1',
  '162.159.137.1',
  '162.159.152.2',
  '162.159.153.2',
  '162.159.192.1',
  '188.114.96.3',
  '188.114.97.3',
  '188.114.98.3',
  '188.114.99.3',
  '198.41.192.47',
  '198.41.200.1',
  '198.41.208.1',
  '141.101.64.1',
  '141.101.90.1',
];

bool usesCloudflarePath(String exitVia, String host) {
  if (exitVia == 'vps') return false;
  if (host.isEmpty) return false;
  return InternetAddress.tryParse(host) == null;
}

bool cfBestIpFresh({required String host, required String cachedHost, required int cachedAtMs, required String ip}) {
  if (ip.isEmpty || cachedHost != host) return false;
  if (cachedAtMs <= 0) return false;
  final age = DateTime.now().millisecondsSinceEpoch - cachedAtMs;
  return age >= 0 && age < const Duration(hours: _cacheHours).inMilliseconds;
}

Future<CfBestIp> pickCloudflareIp({
  required String host,
  String token = '',
  Set<String> skip = const {},
  void Function(String)? onProgress,
}) async {
  onProgress?.call('正在解析节点');
  final candidates = <String>{..._seeds}..removeAll(skip);
  try {
    for (final addr in await InternetAddress.lookup(host, type: InternetAddressType.IPv4)) {
      if (addr.type == InternetAddressType.IPv4) candidates.add(addr.address);
    }
  } catch (_) {}

  onProgress?.call('正在扫描 ${candidates.length} 个 Cloudflare IP');
  final ips = candidates.toList();
  final part = await Future.wait(ips.map(_tcpMs));
  final tcpHits = part.whereType<_TcpHit>().toList()..sort((a, b) => a.ms.compareTo(b.ms));
  final shortlist = tcpHits.take(4).toList();
  if (shortlist.isEmpty) {
    throw const CfBestIpException('没有扫到可用的 Cloudflare IP');
  }

  onProgress?.call('正在验证最快的地址');
  final winner = await _firstServe(shortlist, host, token, skip);
  if (winner != null) return winner;
  throw const CfBestIpException('这些地址连得上端口，但打不开这个节点');
}

/// 几个地址一起试，谁先打开节点就用谁，不等最慢的那个。
Future<CfBestIp?> _firstServe(List<_TcpHit> shortlist, String host, String token, Set<String> skip) {
  final done = Completer<CfBestIp?>();
  var pending = shortlist.length;
  for (final hit in shortlist) {
    unawaited(_serveHost(hit.ip, host, token).then((ok) {
      if (!done.isCompleted && ok != null && !skip.contains(ok.ip)) {
        done.complete(ok);
      }
      pending -= 1;
      if (pending == 0 && !done.isCompleted) done.complete(null);
    }));
  }
  return done.future.timeout(const Duration(seconds: 2), onTimeout: () => null);
}

class CfBestIpException implements Exception {
  const CfBestIpException(this.message);
  final String message;
  @override
  String toString() => message;
}

class _TcpHit {
  const _TcpHit(this.ip, this.ms);
  final String ip;
  final int ms;
}

Future<_TcpHit?> _tcpMs(String ip) async {
  final watch = Stopwatch()..start();
  try {
    final socket = await Socket.connect(InternetAddress(ip), 443, timeout: const Duration(milliseconds: 700));
    final ms = watch.elapsedMilliseconds;
    socket.destroy();
    return _TcpHit(ip, ms);
  } catch (_) {
    return null;
  }
}

HttpClient _pinned(String ip) {
  final client = HttpClient();
  client.findProxy = (_) => 'DIRECT';
  client.connectionTimeout = const Duration(seconds: 4);
  client.badCertificateCallback = (_, __, ___) => true;
  client.connectionFactory = (uri, _, __) {
    return Socket.startConnect(InternetAddress(ip), uri.hasPort ? uri.port : 443);
  };
  return client;
}

/// 确认这个地址真的能打开节点，而不只是 443 端口通。
Future<CfBestIp?> proveCloudflareIp({required String ip, required String host, required String token}) {
  return _serveHost(ip, host, token);
}

/// 测已经选中的地址打开节点要多久。打不开就不要拿端口时间冒充。
Future<int?> pingCloudflareIp({required String ip, required String host, required String token}) async {
  final hit = await _serveHost(ip, host, token);
  return hit?.ms;
}

Future<CfBestIp?> _serveHost(String ip, String host, String token) async {
  final client = _pinned(ip);
  final watch = Stopwatch()..start();
  try {
    final path = token.isEmpty ? '/cdn-cgi/trace' : '/rsq/v1/health';
    final request = await client.getUrl(Uri.https(host, path)).timeout(const Duration(seconds: 5));
    if (token.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    final response = await request.close().timeout(const Duration(seconds: 5));
    final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 4));
    if (token.isNotEmpty) {
      if (response.statusCode != 200) return null;
      return CfBestIp(ip: ip, ms: watch.elapsedMilliseconds);
    }
    if (!body.contains('colo=')) return null;
    final colo = RegExp(r'colo=([A-Z0-9]+)').firstMatch(body)?.group(1) ?? '';
    return CfBestIp(ip: ip, ms: watch.elapsedMilliseconds, colo: colo);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
