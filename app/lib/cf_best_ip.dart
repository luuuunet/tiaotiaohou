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
  final dnsFirst = <String>{};
  final candidates = <String>{..._seeds}..removeAll(skip);
  try {
    for (final addr in await InternetAddress.lookup(host, type: InternetAddressType.IPv4)) {
      if (addr.type == InternetAddressType.IPv4) {
        candidates.add(addr.address);
        dnsFirst.add(addr.address);
      }
    }
  } catch (_) {}
  dnsFirst.removeAll(skip);

  onProgress?.call('正在扫描 ${candidates.length} 个 Cloudflare IP');
  final ips = candidates.toList();
  final part = await Future.wait(ips.map(_tcpMs));
  final tcpHits = part.whereType<_TcpHit>().toList()
    ..sort((a, b) {
      final ad = dnsFirst.contains(a.ip) ? 0 : 1;
      final bd = dnsFirst.contains(b.ip) ? 0 : 1;
      if (ad != bd) return ad.compareTo(bd);
      return a.ms.compareTo(b.ms);
    });
  if (tcpHits.isEmpty) {
    throw const CfBestIpException('没有扫到可用的 Cloudflare IP');
  }

  // 最快的几个端口通，不代表这个域名能在上面打开。一批不行就再试下一批。
  final pool = tcpHits.take(16).toList();
  for (var i = 0; i < pool.length; i += 4) {
    final wave = pool.sublist(i, i + 4 > pool.length ? pool.length : i + 4);
    onProgress?.call('正在验证 ${wave.map((hit) => hit.ip).join('、')}');
    final winner = await _firstServe(wave, host, token, skip);
    if (winner != null) return winner;
  }
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
  return done.future.timeout(const Duration(seconds: 8), onTimeout: () => null);
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

HttpClient _pinned(String ip, String host) {
  final client = HttpClient();
  client.findProxy = (_) => 'DIRECT';
  client.connectionTimeout = const Duration(seconds: 6);
  client.badCertificateCallback = (_, __, ___) => true;
  // 自己连到指定地址，再按节点域名做 TLS。否则会把明文送到 443，Cloudflare 直接拒绝。
  client.connectionFactory = (uri, _, __) {
    final Future<Socket> future = Socket.connect(
      InternetAddress(ip),
      uri.hasPort ? uri.port : 443,
      timeout: const Duration(seconds: 6),
    ).then((tcp) {
      if (uri.scheme != 'https') return tcp;
      return SecureSocket.secure(
        tcp,
        host: host,
        onBadCertificate: (_) => true,
        supportedProtocols: const ['http/1.1'],
      );
    });
    return Future<ConnectionTask<Socket>>.value(ConnectionTask.fromSocket(future, () {}));
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
  final client = _pinned(ip, host);
  final watch = Stopwatch()..start();
  try {
    // 先确认这个地址真的在为该域名服务。橙云回源和 Worker 都能从这里看到机房。
    final trace = await client.getUrl(Uri.https(host, '/cdn-cgi/trace')).timeout(const Duration(seconds: 6));
    final traced = await trace.close().timeout(const Duration(seconds: 6));
    final body = await traced.transform(utf8.decoder).join().timeout(const Duration(seconds: 4));
    if (traced.statusCode != 200 || !body.contains('colo=')) return null;
    final colo = RegExp(r'colo=([A-Z0-9]+)').firstMatch(body)?.group(1) ?? '';
    if (token.isNotEmpty) {
      try {
        final health = await client.getUrl(Uri.https(host, '/rsq/v1/health')).timeout(const Duration(seconds: 6));
        health.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        final checked = await health.close().timeout(const Duration(seconds: 6));
        await checked.drain<void>();
        // 401 是令牌问题。404 说明这个域名上没有节点。
        if (checked.statusCode == 404) return null;
      } catch (_) {
        // 边缘已经认出这个域名，健康检查超时仍保留这条地址。
      }
    }
    return CfBestIp(ip: ip, ms: watch.elapsedMilliseconds, colo: colo);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
