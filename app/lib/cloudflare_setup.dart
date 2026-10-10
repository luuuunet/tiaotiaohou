import 'dart:convert';
import 'dart:io';
import 'dart:math';

class DomainPlan {
  const DomainPlan(this.hostname, this.zoneNames);

  final String hostname;
  final List<String> zoneNames;
}

class DeployedNode {
  const DeployedNode(this.endpoint, this.token);

  final String endpoint;
  final String token;
}

class CloudflareSetupException implements Exception {
  CloudflareSetupException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// `example.com` 会部署到 `rsq.example.com`。已经写了子域名就用原样。
DomainPlan? planDomain(String input) {
  var host = input.trim().toLowerCase();
  if (host.isEmpty) return null;
  host = host.replaceFirst(RegExp(r'^https?://'), '');
  host = host.split('/').first;
  if (host.contains(':')) return null;
  host = host.endsWith('.') ? host.substring(0, host.length - 1) : host;
  final labels = host.split('.');
  if (labels.length < 2 || labels.any((label) => label.isEmpty || label.length > 63)) {
    return null;
  }
  if (!RegExp(r'^[a-z0-9.-]+$').hasMatch(host)) return null;
  if (labels.length == 2) {
    return DomainPlan('rsq.$host', [host]);
  }
  final zones = <String>[];
  for (var i = 0; i < labels.length - 1; i++) {
    zones.add(labels.sublist(i).join('.'));
  }
  return DomainPlan(host, zones);
}

String newAccessToken() {
  final bytes = List<int>.generate(24, (_) => Random.secure().nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// 每个域名一个 Worker，避免后一次搭建盖掉前面的令牌。
String workerScriptName(String hostname) {
  final raw = hostname.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  var name = 'tiaotiaohou-${raw.isEmpty ? 'node' : raw}';
  if (name.length > 54) {
    name = name.substring(0, 54).replaceAll(RegExp(r'-+$'), '');
  }
  return name;
}

class CloudflareSetup {
  Future<DeployedNode> deploy({
    required String apiToken,
    required String domain,
    String? accessToken,
    String landingHost = '',
    String landingPort = '8444',
    void Function(String step)? onStep,
  }) async {
    final token = apiToken.trim();
    if (token.isEmpty) {
      throw CloudflareSetupException('先填写 Cloudflare API 令牌');
    }
    final plan = planDomain(domain);
    if (plan == null) {
      throw CloudflareSetupException('域名要像 example.com 或 vpn.example.com');
    }
    final access = (accessToken == null || accessToken.trim().isEmpty) ? newAccessToken() : accessToken.trim();
    final api = _CfApi(token);

    onStep?.call('正在查找 Cloudflare 账号');
    final accountId = await api.accountId();

    onStep?.call('正在查找域名');
    final zoneId = await api.findZone(plan.zoneNames);
    if (zoneId == null) {
      throw CloudflareSetupException('这个令牌看不到 ${plan.zoneNames.last}，请确认域名已经加到这个 Cloudflare 账号');
    }

    onStep?.call('正在创建 Worker ${workerScriptName(plan.hostname)}');
    await api.uploadWorker(accountId, access, script: workerScriptName(plan.hostname), landingHost: landingHost, landingPort: landingPort);

    onStep?.call('正在绑定 ${plan.hostname}');
    await api.attachDomain(accountId, zoneId, plan.hostname, workerScriptName(plan.hostname));

    onStep?.call('正在检查节点');
    try {
      await _waitUntilReady('https://${plan.hostname}', access, tries: 12);
    } on CloudflareSetupException catch (err) {
      // 令牌已经写进 Worker。检查失败时也要把新令牌存下来，否则下次会一直 401。
      onStep?.call('域名检查还没通过：$err。新令牌已写上，节点会先保存，过一两分钟再连接。');
    }

    return DeployedNode('https://${plan.hostname}', access);
  }

  Future<DeployedNode> bindOrigin({
    required String apiToken,
    required String domain,
    required String originIp,
    String? accessToken,
    bool strictOrigin = false,
    void Function(String step)? onStep,
  }) async {
    final token = apiToken.trim();
    if (token.isEmpty) {
      throw CloudflareSetupException('先填写 Cloudflare API 令牌');
    }
    final ip = originIp.trim();
    if (ip.isEmpty) {
      throw CloudflareSetupException('VPS 要填公网 IPv4');
    }
    final plan = planDomain(domain);
    if (plan == null) {
      throw CloudflareSetupException('域名要像 example.com 或 vpn.example.com');
    }
    final access = (accessToken == null || accessToken.trim().isEmpty) ? newAccessToken() : accessToken.trim();
    final api = _CfApi(token);

    onStep?.call('正在查找 Cloudflare 账号');
    final accountId = await api.accountId();

    onStep?.call('正在查找域名');
    final zoneId = await api.findZone(plan.zoneNames);
    if (zoneId == null) {
      throw CloudflareSetupException('这个令牌看不到 ${plan.zoneNames.last}，请确认域名已经加到这个 Cloudflare 账号');
    }

    onStep?.call('正在解开原来的 Worker 绑定');
    await api.detachWorkerHostname(accountId, plan.hostname);

    onStep?.call('正在把 ${plan.hostname} 橙云指到服务器');
    await api.upsertProxiedA(zoneId, plan.hostname, ip);

    onStep?.call(strictOrigin ? '正在打开 HTTP/3 和严格回源' : '正在打开 HTTP/3 和回源');
    await api.patchZoneSetting(zoneId, 'ssl', strictOrigin ? 'strict' : 'full');
    await api.patchZoneSetting(zoneId, 'http3', 'on');
    await api.patchZoneSetting(zoneId, 'always_use_https', 'on');

    onStep?.call('正在检查橙云节点');
    await _waitUntilReady('https://${plan.hostname}', access, tries: 15);

    return DeployedNode('https://${plan.hostname}', access);
  }
}

HttpClient _httpClient() {
  final client = HttpClient();
  client.findProxy = (_) => 'DIRECT';
  return client;
}

Future<void> _waitUntilReady(String origin, String access, {int tries = 8}) async {
  final client = _httpClient();
  try {
    for (var i = 0; i < tries; i++) {
      try {
        final request = await client.getUrl(Uri.parse('$origin/rsq/v1/health'));
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $access');
        final response = await request.close().timeout(const Duration(seconds: 8));
        final code = response.statusCode;
        await response.drain<void>();
        if (code == 200) return;
      } catch (_) {}
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw CloudflareSetupException('域名已经绑上，但这台电脑还没连上节点');
  } finally {
    client.close(force: true);
  }
}

class _CfApi {
  _CfApi(this.token);

  final String token;

  Future<String> accountId() async {
    final json = await _send('GET', '/accounts');
    final result = json['result'];
    if (result is! List || result.isEmpty) {
      throw CloudflareSetupException('这个令牌看不到 Cloudflare 账号');
    }
    final id = result.first['id'];
    if (id is! String || id.isEmpty) {
      throw CloudflareSetupException('这个令牌看不到 Cloudflare 账号');
    }
    return id;
  }

  Future<String?> findZone(List<String> names) async {
    for (final name in names) {
      final json = await _send('GET', '/zones?name=$name&per_page=5');
      final result = json['result'];
      if (result is List) {
        for (final zone in result) {
          if (zone is Map && zone['name'] == name && zone['id'] is String) {
            return zone['id'] as String;
          }
        }
      }
    }
    return null;
  }

  Future<void> uploadWorker(
    String accountId,
    String accessToken, {
    required String script,
    String landingHost = '',
    String landingPort = '8444',
  }) async {
    final metadata = jsonEncode({
      'main_module': 'index.js',
      'compatibility_date': '2026-09-28',
      'bindings': [
        {'type': 'secret_text', 'name': 'RSQ_TOKEN', 'text': accessToken},
        {'type': 'plain_text', 'name': 'LANDING_HOST', 'text': landingHost.trim()},
        {'type': 'plain_text', 'name': 'LANDING_PORT', 'text': landingPort.trim().isEmpty ? '8444' : landingPort.trim()},
      ],
    });
    final boundary = '----tiaotiaohou${DateTime.now().microsecondsSinceEpoch}';
    final body = utf8.encode(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="metadata"\r\n'
      'Content-Type: application/json\r\n\r\n'
      '$metadata\r\n'
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="index.js"; filename="index.js"\r\n'
      'Content-Type: application/javascript+module\r\n\r\n'
      '$workerScript\r\n'
      '--$boundary--\r\n',
    );
    await _send(
      'PUT',
      '/accounts/$accountId/workers/scripts/$script',
      body: body,
      contentType: 'multipart/form-data; boundary=$boundary',
    );
  }

  Future<void> attachDomain(String accountId, String zoneId, String hostname, String script) async {
    await _send(
      'PUT',
      '/accounts/$accountId/workers/domains',
      body: utf8.encode(jsonEncode({
        'hostname': hostname,
        'service': script,
        'environment': 'production',
        'zone_id': zoneId,
        'override_existing': true,
      })),
      contentType: 'application/json',
    );
  }

  Future<void> detachWorkerHostname(String accountId, String hostname) async {
    try {
      final json = await _send('GET', '/accounts/$accountId/workers/domains');
      final result = json['result'];
      if (result is! List) return;
      for (final item in result) {
        if (item is Map && item['hostname'] == hostname && item['id'] is String) {
          await _send('DELETE', '/accounts/$accountId/workers/domains/${item['id']}');
        }
      }
    } catch (_) {}
  }

  Future<void> upsertProxiedA(String zoneId, String hostname, String ip) async {
    final json = await _send('GET', '/zones/$zoneId/dns_records?type=A&name=$hostname&per_page=50');
    final result = json['result'];
    String? id;
    if (result is List) {
      for (final item in result) {
        if (item is Map && item['name'] == hostname && item['id'] is String) {
          id = item['id'] as String;
          break;
        }
      }
    }
    final body = utf8.encode(jsonEncode({
      'type': 'A',
      'name': hostname,
      'content': ip,
      'ttl': 1,
      'proxied': true,
    }));
    if (id == null) {
      await _send('POST', '/zones/$zoneId/dns_records', body: body, contentType: 'application/json');
      return;
    }
    await _send('PUT', '/zones/$zoneId/dns_records/$id', body: body, contentType: 'application/json');
  }

  Future<void> patchZoneSetting(String zoneId, String setting, String value) async {
    try {
      await _send(
        'PATCH',
        '/zones/$zoneId/settings/$setting',
        body: utf8.encode(jsonEncode({'value': value})),
        contentType: 'application/json',
      );
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    List<int>? body,
    String? contentType,
  }) async {
    final client = _httpClient();
    try {
      final request = await client.openUrl(method, Uri.parse('https://api.cloudflare.com/client/v4$path'));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (contentType != null) {
        request.headers.set(HttpHeaders.contentTypeHeader, contentType);
      }
      if (body != null) request.add(body);
      final response = await request.close().timeout(const Duration(seconds: 40));
      final text = await response.transform(utf8.decoder).join();
      Map<String, dynamic> json = {};
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) json = decoded;
      } catch (_) {}
      if (response.statusCode >= 200 && response.statusCode < 300 && json['success'] != false) {
        return json;
      }
      throw CloudflareSetupException(_explain(response.statusCode, json, text));
    } on CloudflareSetupException {
      rethrow;
    } catch (err) {
      throw CloudflareSetupException('连不上 Cloudflare：$err');
    } finally {
      client.close(force: true);
    }
  }

  String _explain(int status, Map<String, dynamic> json, String raw) {
    final errors = json['errors'];
    var message = '';
    if (errors is List && errors.isNotEmpty && errors.first is Map) {
      message = '${errors.first['message'] ?? ''}';
    }
    final lower = '$message $raw'.toLowerCase();
    if (status == 401 || status == 403) {
      return '令牌权限不够或已失效。请新建 API 令牌，并选择 Full account and zone access。';
    }
    if (message.isNotEmpty) return message;
    return 'Cloudflare 返回 $status';
  }
}

const workerScript = r'''
import { connect } from "cloudflare:sockets";

function isCloudflareIp(host) {
  const match = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!match) return false;
  const octets = match.slice(1).map((part) => Number(part));
  if (octets.some((n) => n > 255)) return false;
  const ip = ((octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]) >>> 0;
  const nets = [[173,245,48,0,20],[103,21,244,0,22],[103,22,200,0,22],[103,31,4,0,22],[141,101,64,0,18],[108,162,192,0,18],[190,93,240,0,20],[188,114,96,0,20],[197,234,240,0,22],[198,41,128,0,17],[162,158,0,0,15],[104,16,0,0,13],[104,24,0,0,14],[172,64,0,0,13],[131,0,72,0,22],[1,1,1,0,24],[1,0,0,0,24]];
  return nets.some((net) => {
    const base = ((net[0] << 24) | (net[1] << 16) | (net[2] << 8) | net[3]) >>> 0;
    const mask = (0xffffffff << (32 - net[4])) >>> 0;
    return (ip & mask) === (base & mask);
  });
}

function headerPairs(raw) {
  if (Array.isArray(raw)) {
    const out = [];
    for (const item of raw) {
      if (Array.isArray(item) && item.length >= 2) out.push([String(item[0]), String(item[1])]);
    }
    return out;
  }
  return Object.entries(raw || {}).map(([key, value]) => [key, String(value)]);
}

function passUpstream(upstream) {
  const headers = new Headers();
  upstream.headers.forEach((value, key) => {
    if (String(key).toLowerCase() === "set-cookie") return;
    try { headers.append(key, value); } catch (_) {}
  });
  const listed = typeof upstream.headers.getSetCookie === "function" ? upstream.headers.getSetCookie() : [];
  const cookies = listed.length ? listed : (upstream.headers.get("set-cookie") ? [upstream.headers.get("set-cookie")] : []);
  for (const cookie of cookies) headers.append("set-cookie", cookie);
  return new Response(upstream.body, { status: upstream.status, headers });
}

function blockReason(host, port) {
  if (!Number.isInteger(port) || port <= 0 || port > 65535 || port === 25) return "这个端口不能转发";
  if (!host || host.length > 253) return "主机名不合法";
  if (/[\u0000-\u001f\/\\ @#?]/.test(host)) return "主机名不合法";
  const lower = host.replace(/^\[|\]$/g, "").toLowerCase();
  if (lower === "localhost" || lower.endsWith(".localhost") || lower.endsWith(".local") || lower === "metadata.google.internal") {
    return "内网地址不能转发";
  }
  if (isBlockedIp(lower)) return "内网地址不能转发";
  return null;
}

function isBlockedIp(host) {
  if (host.includes(":")) {
    const v6 = host.split("%")[0];
    if (v6 === "::1" || v6 === "::") return true;
    const head = v6.split(":")[0] || "0";
    const n = parseInt(head, 16);
    if (Number.isNaN(n)) return false;
    if ((n & 0xfe00) === 0xfc00) return true;
    if ((n & 0xffc0) === 0xfe80) return true;
    if ((n & 0xff00) === 0xff00) return true;
    return false;
  }
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!m) return false;
  const o = m.slice(1).map((x) => Number(x));
  if (o.some((n) => n > 255)) return true;
  const [a, b, c] = o;
  if (a === 0 || a === 10 || a === 127) return true;
  if (a === 100 && (b & 0xc0) === 64) return true;
  if (a === 169 && b === 254) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && b === 168) return true;
  if (a === 192 && b === 0 && c === 2) return true;
  if (a === 198 && (b === 18 || b === 19)) return true;
  if (a === 198 && b === 51 && c === 100) return true;
  if (a === 203 && b === 0 && c === 113) return true;
  if (a >= 224) return true;
  return false;
}

async function tokenOk(presented, expected) {
  if (!expected) return false;
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(presented)),
    crypto.subtle.digest("SHA-256", enc.encode(expected)),
  ]);
  const aa = new Uint8Array(a);
  const bb = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < aa.length; i++) diff |= aa[i] ^ bb[i];
  return diff === 0;
}

async function authorized(request, env) {
  const header = request.headers.get("authorization") ?? "";
  const presented = header.startsWith("Bearer ") ? header.slice(7) : "";
  return tokenOk(presented, env.RSQ_TOKEN ?? "");
}

function text(body, status) {
  return new Response(body, {
    status,
    headers: { "cache-control": "no-store", "content-type": "text/plain; charset=utf-8" },
  });
}

async function openExit(env, host, port, via) {
  const landingHost = String((env && env.LANDING_HOST) || "").trim();
  const landingPort = Number((env && env.LANDING_PORT) || "0");
  if (via === "direct" || !landingHost || !landingPort) {
    const socket = connect({ hostname: host, port });
    await socket.opened;
    return { socket, prefix: new Uint8Array() };
  }
  const socket = connect({ hostname: landingHost, port: landingPort });
  await socket.opened;
  const token = new TextEncoder().encode(env.RSQ_TOKEN || "");
  const hostBytes = new TextEncoder().encode(host);
  const head = new Uint8Array(1 + 2 + token.byteLength + 2 + hostBytes.byteLength + 2);
  let offset = 0;
  head[offset++] = 1;
  head[offset++] = token.byteLength >> 8;
  head[offset++] = token.byteLength & 0xff;
  head.set(token, offset);
  offset += token.byteLength;
  head[offset++] = hostBytes.byteLength >> 8;
  head[offset++] = hostBytes.byteLength & 0xff;
  head.set(hostBytes, offset);
  offset += hostBytes.byteLength;
  head[offset++] = port >> 8;
  head[offset++] = port & 0xff;
  const writer = socket.writable.getWriter();
  await writer.write(head);
  writer.releaseLock();
  const reader = socket.readable.getReader();
  const ack = await reader.read();
  reader.releaseLock();
  const raw = ack.value ? new Uint8Array(ack.value) : new Uint8Array();
  if (ack.done || raw.byteLength < 1 || raw[0] !== 1) throw new Error("landing refused");
  return { socket, prefix: raw.subarray(1).slice() };
}

async function pipeTcp(opened, reader, first, writable) {
  const writer = writable.getWriter();
  let sockWrite = null;
  try {
    sockWrite = opened.socket.writable.getWriter();
    const sockRead = opened.socket.readable.getReader();
    const upload = (async () => {
      let skip = true;
      const writeChunk = async (raw) => {
        let bytes = raw ? new Uint8Array(raw) : new Uint8Array();
        if (skip) {
          if (bytes.byteLength && bytes[0] === 0) bytes = bytes.subarray(1);
          skip = false;
        }
        if (bytes.byteLength) await sockWrite.write(bytes);
      };
      await writeChunk(first);
      while (true) {
        const next = await reader.read();
        if (next.done) break;
        await writeChunk(next.value);
      }
    })();
    const download = (async () => {
      const prefix = opened.prefix || new Uint8Array();
      if (prefix.byteLength) await writer.write(prefix);
      while (true) {
        const next = await sockRead.read();
        if (next.done) break;
        if (next.value && next.value.byteLength) await writer.write(next.value);
      }
    })();
    await Promise.race([upload, download]);
  } catch (_) {}
  try { await writer.close(); } catch (_) {}
  try { if (sockWrite) await sockWrite.close(); } catch (_) {}
}

async function bind(server, socket, prefix) {
  const writer = socket.writable.getWriter();
  const reader = socket.readable.getReader();
  const writing = new Promise((resolve) => {
    server.addEventListener("message", (event) => {
      const data = event.data;
      const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array();
      if (bytes.byteLength) writer.write(bytes).catch(() => server.close());
    });
    server.addEventListener("close", () => resolve());
    server.addEventListener("error", () => resolve());
  });
  const reading = (async () => {
    try {
      if (prefix && prefix.byteLength) server.send(prefix);
      while (true) {
        const next = await reader.read();
        if (next.done) break;
        if (next.value?.byteLength) server.send(next.value);
      }
    } catch (_) {}
    server.close();
  })();
  await Promise.race([writing, reading]);
  await writer.close().catch(() => undefined);
  server.close();
}

async function fetchByIp(urlString, method, headers, body, ip) {
  const target = new URL(urlString);
  const https = target.protocol === "https:";
  const port = Number(target.port || (https ? 443 : 80));
  let socket = connect({ hostname: ip, port });
  await socket.opened;
  if (https) socket = socket.startTls({ expectedServerHostname: target.hostname });
  const writer = socket.writable.getWriter();
  const lines = [method + " " + target.pathname + target.search + " HTTP/1.1", "Host: " + target.host, "Connection: close"];
  headers.forEach((value, key) => lines.push(key + ": " + value));
  const payload = body ? new Uint8Array(body) : new Uint8Array();
  if (payload.byteLength) lines.push("Content-Length: " + payload.byteLength);
  await writer.write(new TextEncoder().encode(lines.join("\r\n") + "\r\n\r\n"));
  if (payload.byteLength) await writer.write(payload);
  await writer.close();
  const reader = socket.readable.getReader();
  const chunks = [];
  let total = 0;
  while (total < 8 * 1024 * 1024) {
    const next = await reader.read();
    if (next.done) break;
    if (next.value && next.value.byteLength) {
      chunks.push(next.value);
      total += next.value.byteLength;
    }
  }
  const raw = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    raw.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let headEnd = -1;
  for (let i = 0; i + 3 < raw.length; i++) {
    if (raw[i] === 13 && raw[i + 1] === 10 && raw[i + 2] === 13 && raw[i + 3] === 10) {
      headEnd = i;
      break;
    }
  }
  if (headEnd < 0) return text("bad origin response", 502);
  const head = new TextDecoder().decode(raw.subarray(0, headEnd));
  const headerLines = head.split("\r\n");
  const status = Number((headerLines[0] || "").split(" ")[1] || "502");
  const out = new Headers();
  let chunked = false;
  let length = -1;
  for (const line of headerLines.slice(1)) {
    const cut = line.indexOf(":");
    if (cut <= 0) continue;
    const name = line.slice(0, cut).trim();
    const value = line.slice(cut + 1).trim();
    if (/^transfer-encoding$/i.test(name) && value.toLowerCase().includes("chunked")) chunked = true;
    if (/^content-length$/i.test(name)) length = Number(value);
    if (/^(connection|transfer-encoding|content-length)$/i.test(name)) continue;
    try { out.append(name, value); } catch (_) {}
  }
  let bytes = raw.subarray(headEnd + 4);
  if (chunked) bytes = decodeChunks(bytes);
  else if (length >= 0 && length <= bytes.length) bytes = bytes.subarray(0, length);
  return new Response(bytes, { status, headers: out });
}

function decodeChunks(raw) {
  const parts = [];
  let index = 0;
  let total = 0;
  const text = new TextDecoder();
  while (index < raw.length) {
    let lineEnd = index;
    while (lineEnd + 1 < raw.length && !(raw[lineEnd] === 13 && raw[lineEnd + 1] === 10)) lineEnd++;
    const size = parseInt(text.decode(raw.subarray(index, lineEnd)).split(";")[0].trim(), 16);
    if (!Number.isFinite(size) || size <= 0) break;
    index = lineEnd + 2;
    if (index + size > raw.length) break;
    parts.push(raw.subarray(index, index + size));
    total += size;
    index += size + 2;
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    body.set(part, offset);
    offset += part.byteLength;
  }
  return body;
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/rsq/v1/health")) {
      if (url.pathname === "/") return text("rsq/1", 200);
      if (!(await authorized(request, env))) return text("unauthorized", 401);
      return Response.json({ ok: true, version: 1, proto: "rsq" }, { headers: { "cache-control": "no-store" } });
    }
    if (url.pathname === "/rsq/v1/fetch" && request.method === "POST") {
      if (!(await authorized(request, env))) return text("unauthorized", 401);
      const buf = await request.arrayBuffer();
      if (buf.byteLength < 4) return text("bad fetch", 400);
      const view = new DataView(buf);
      const metaLen = view.getUint32(0);
      const meta = JSON.parse(new TextDecoder().decode(new Uint8Array(buf, 4, metaLen)));
      const headers = new Headers();
      for (const pair of headerPairs(meta.headers)) {
        const key = pair[0];
        const value = pair[1];
        const name = String(key).toLowerCase();
        if (["host", "connection", "content-length", "transfer-encoding", "upgrade"].includes(name)) continue;
        try {
          if (name === "cookie") headers.append(key, value);
          else headers.set(key, value);
        } catch (_) {}
      }
      const method = String(meta.method || "GET").toUpperCase();
      const body = buf.byteLength > 4 + metaLen ? buf.slice(4 + metaLen) : undefined;
      if (meta.ip && /^\d{1,3}(?:\.\d{1,3}){3}$/.test(meta.ip) && !isCloudflareIp(meta.ip)) {
        const target = new URL(meta.url);
        const port = Number(target.port || (target.protocol === "https:" ? 443 : 80));
        if (!blockReason(meta.ip, port)) {
          try {
            return await fetchByIp(meta.url, method, headers, body, meta.ip);
          } catch (_) {}
        }
      }
      const upstream = await fetch(meta.url, {
        method,
        headers,
        body: body && method !== "GET" && method !== "HEAD" ? body : undefined,
        redirect: "manual",
      });
      return passUpstream(upstream);
    }
    if (url.pathname === "/rsq/v1/tcp" && request.method === "POST") {
      if (!(await authorized(request, env))) return text("unauthorized", 401);
      const host = (request.headers.get("x-rsq-host") ?? "").trim();
      const port = Number(request.headers.get("x-rsq-port"));
      const denied = blockReason(host, port);
      if (denied) return text(denied, 403);
      if (!request.body) return text("bad tcp", 400);
      const via = String(request.headers.get("x-rsq-exit") || "landing").trim();
      const reader = request.body.getReader();
      let first;
      try {
        first = await reader.read();
      } catch (_) {
        return text("quic buffered", 404);
      }
      if (!first || first.done) return text("empty tcp", 400);
      let opened;
      try {
        opened = await openExit(env, host, port, via);
      } catch (err) {
        return text("connect failed", 502);
      }
      const pair = new TransformStream();
      ctx.waitUntil(pipeTcp(opened, reader, first.value, pair.writable));
      return new Response(pair.readable, {
        status: 200,
        headers: { "content-type": "application/octet-stream", "cache-control": "no-store" },
      });
    }
    if (url.pathname !== "/rsq/v1/ws" || (request.headers.get("Upgrade") ?? "").toLowerCase() !== "websocket") {
      return text("not found", 404);
    }
    if (!(await authorized(request, env))) return text("unauthorized", 401);
    const host = (request.headers.get("x-rsq-host") ?? "").trim();
    const port = Number(request.headers.get("x-rsq-port"));
    const denied = blockReason(host, port);
    if (denied) return text(denied, 403);
    let socket;
    let prefix = new Uint8Array();
    try {
      const via = String(request.headers.get("x-rsq-exit") || "landing").trim();
      const opened = await openExit(env, host, port, via);
      socket = opened.socket;
      prefix = opened.prefix || new Uint8Array();
    } catch (err) {
      return text("connect failed: " + (err && err.message ? err.message : String(err)), 502);
    }
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();
    server.binaryType = "arraybuffer";
    ctx.waitUntil(bind(server, socket, prefix));
    return new Response(null, { status: 101, webSocket: client });
  },
};
''';
