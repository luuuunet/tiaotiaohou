import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'core_api.dart';
import 'nodes.dart';
import 'node_probe.dart';

const workerDailyLimit = 100000;

class DiagnosticReport {
  DiagnosticReport({
    required this.lines,
    required this.ok,
    required this.summary,
  });

  final List<String> lines;
  final bool ok;
  final String summary;

  String get text => lines.join('\n');
}

Future<DiagnosticReport> runDiagnostics({
  required String endpoint,
  required String token,
  required String exitVia,
  required String vpsIp,
  required int socks,
  required int http,
  required bool running,
  required List<String> recentLog,
}) async {
  final lines = <String>[];
  var ok = true;
  void add(String line) => lines.add(line);

  add('跳跳猴诊断');
  add('时间 ${DateTime.now().toIso8601String()}');
  add('系统 ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
  add('程序 ${Platform.resolvedExecutable}');
  add('');

  final host = Uri.tryParse(endpoint)?.host ?? '';
  add('节点 ${host.isEmpty ? '（无）' : host}');
  add('出口 $exitVia${vpsIp.isEmpty ? '' : ' · UDP $vpsIp'}');
  add('本地 SOCKS 127.0.0.1:$socks');
  add('本地 HTTP 127.0.0.1:$http');
  add('连接状态 ${running ? '已连接' : '未连接'}');

  try {
    final stats = RsqCore.open().stats();
    add('核心 phase=${stats['phase']} mode=${stats['mode']}');
    add('流量 ↑ ${stats['bytes_up']}  ↓ ${stats['bytes_down']}');
    final err = '${stats['error'] ?? ''}';
    if (err.isNotEmpty) {
      ok = false;
      add('核心错误 $err');
    }
  } catch (err) {
    ok = false;
    add('核心不可用 $err');
  }

  if (endpoint.startsWith('https://') && token.isNotEmpty) {
    final node = VpnNode(
      id: 'diag',
      name: 'diag',
      endpoint: endpoint,
      token: token,
      exitVia: exitVia,
      vpsIp: vpsIp,
    );
    final probe = await probeNode(node);
    add('节点探测 ${probe.ok ? '可用' : '不可用'} ${probe.ms}ms · ${probe.detail}');
    if (!probe.ok) ok = false;
  } else {
    ok = false;
    add('节点探测 跳过（没有完整节点）');
  }

  if (running) {
    final exit = await probeExitIp(http);
    if (exit == null) {
      ok = false;
      add('出口 IP 探测失败（经本地 HTTP 代理）');
    } else {
      add('出口 IP $exit');
    }
  } else {
    add('出口 IP 跳过（未连接）');
  }

  final usage = await fetchWorkerUsage();
  add(usage.line);
  if (usage.blocked) ok = false;

  if (recentLog.isNotEmpty) {
    add('');
    add('最近记录');
    for (final line in recentLog.take(12)) {
      add('- $line');
    }
  }

  return DiagnosticReport(
    lines: lines,
    ok: ok,
    summary: ok ? '诊断正常' : '发现问题，见下方详情',
  );
}

class WorkerUsage {
  const WorkerUsage({required this.line, this.homeLine = '', this.requests, this.blocked = false, this.warn = false});

  final String line;
  final String homeLine;
  final int? requests;
  final bool blocked;
  final bool warn;

  factory WorkerUsage.fromRequests(int requests) {
    if (requests >= workerDailyLimit) {
      return WorkerUsage(
        line: 'Worker 用量 $requests，已到免费上限 $workerDailyLimit',
        homeLine: '今日额度已用完，网页可能打不开',
        requests: requests,
        blocked: true,
        warn: true,
      );
    }
    final pct = ((requests / workerDailyLimit) * 100).clamp(0, 100).round();
    if (requests >= workerDailyLimit * 0.8) {
      return WorkerUsage(
        line: 'Worker 用量 $requests / $workerDailyLimit，快到上限了',
        homeLine: '今日额度已用 $pct%，快用完了',
        requests: requests,
        warn: true,
      );
    }
    return WorkerUsage(
      line: 'Worker 用量 $requests / $workerDailyLimit',
      homeLine: '今日额度已用 $pct%',
      requests: requests,
    );
  }
}

Future<WorkerUsage> fetchWorkerUsage({bool allowCache = false}) async {
  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString('cf_api_token')?.trim() ?? '';
  if (token.isEmpty) {
    return const WorkerUsage(line: 'Worker 用量 未填写 Cloudflare 令牌');
  }
  final cachedAt = prefs.getInt('worker_usage_at') ?? 0;
  final cachedReq = prefs.getInt('worker_usage_requests');
  if (allowCache && cachedReq != null && DateTime.now().millisecondsSinceEpoch - cachedAt < 8 * 60 * 1000) {
    return WorkerUsage.fromRequests(cachedReq);
  }
  final client = HttpClient();
  client.findProxy = (_) => 'DIRECT';
  client.connectionTimeout = const Duration(seconds: 12);
  try {
    final accountId = await _cfAccount(client, token);
    final now = DateTime.now().toUtc();
    final start = DateTime.utc(now.year, now.month, now.day);
    final query = '''
query(\$account: String!, \$since: Time!, \$until: Time!) {
  viewer {
    accounts(filter: { accountTag: \$account }) {
      workersInvocationsAdaptive(limit: 10000, filter: { datetime_geq: \$since, datetime_leq: \$until }) {
        sum { requests }
      }
    }
  }
}
''';
    final payload = jsonEncode({
      'query': query,
      'variables': {
        'account': accountId,
        'since': start.toIso8601String(),
        'until': now.toIso8601String(),
      },
    });
    final request = await client.postUrl(Uri.parse('https://api.cloudflare.com/client/v4/graphql'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    request.add(utf8.encode(payload));
    final response = await request.close().timeout(const Duration(seconds: 20));
    final text = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      return const WorkerUsage(line: 'Worker 用量 读不到');
    }
    final errors = decoded['errors'];
    if (errors is List && errors.isNotEmpty) {
      return const WorkerUsage(line: 'Worker 用量 令牌没有分析权限');
    }
    final requests = sumWorkerRequests(decoded);
    if (requests == null) {
      return const WorkerUsage(line: 'Worker 用量 读不到');
    }
    await prefs.setInt('worker_usage_requests', requests);
    await prefs.setInt('worker_usage_at', DateTime.now().millisecondsSinceEpoch);
    return WorkerUsage.fromRequests(requests);
  } on SocketException {
    return const WorkerUsage(line: 'Worker 用量 连不上 Cloudflare');
  } catch (_) {
    return const WorkerUsage(line: 'Worker 用量 查询失败');
  } finally {
    client.close(force: true);
  }
}

int? sumWorkerRequests(Map json) {
  final data = json['data'];
  if (data is! Map) return null;
  final viewer = data['viewer'];
  if (viewer is! Map) return null;
  final accounts = viewer['accounts'];
  if (accounts is! List) return null;
  var total = 0;
  var seen = false;
  for (final account in accounts) {
    if (account is! Map) continue;
    final rows = account['workersInvocationsAdaptive'];
    if (rows is! List) continue;
    for (final row in rows) {
      if (row is! Map) continue;
      final sum = row['sum'];
      if (sum is! Map) continue;
      final requests = sum['requests'];
      if (requests is num) {
        total += requests.round();
        seen = true;
      }
    }
  }
  return seen ? total : null;
}

Future<String> _cfAccount(HttpClient client, String token) async {
  final request = await client.getUrl(Uri.parse('https://api.cloudflare.com/client/v4/accounts'));
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  final response = await request.close().timeout(const Duration(seconds: 15));
  final text = await response.transform(utf8.decoder).join();
  final decoded = jsonDecode(text);
  if (decoded is! Map) throw StateError('no account');
  final result = decoded['result'];
  if (result is! List || result.isEmpty || result.first is! Map) throw StateError('no account');
  final id = result.first['id'];
  if (id is! String || id.isEmpty) throw StateError('no account');
  return id;
}

class ExitTrace {
  const ExitTrace({required this.ip, this.loc = ''});
  final String ip;
  final String loc;
}

Future<String?> probeExitIp(int httpPort) async {
  return (await probeExitTrace(httpPort))?.ip;
}

Future<ExitTrace?> probeExitTrace(int httpPort) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 8);
  client.findProxy = (_) => 'PROXY 127.0.0.1:$httpPort';
  client.badCertificateCallback = (_, __, ___) => true;
  try {
    final request = await client.getUrl(Uri.parse('https://cloudflare.com/cdn-cgi/trace')).timeout(const Duration(seconds: 10));
    final response = await request.close().timeout(const Duration(seconds: 10));
    final body = await response.transform(utf8.decoder).join();
    var ip = '';
    var loc = '';
    for (final line in body.split('\n')) {
      if (line.startsWith('ip=')) ip = line.substring(3).trim();
      if (line.startsWith('loc=')) loc = line.substring(4).trim();
    }
    if (ip.isEmpty) return null;
    return ExitTrace(ip: ip, loc: loc);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
