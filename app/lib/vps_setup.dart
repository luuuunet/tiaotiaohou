import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';

class VpsSetupException implements Exception {
  VpsSetupException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 只接受公网 IPv4，给 Cloudflare Worker 当落地地址。
String? publicIpv4(String input) {
  var host = input.trim();
  if (host.isEmpty) return null;
  host = host.replaceFirst(RegExp(r'^https?://'), '');
  host = host.split('/').first;
  host = host.split(':').first;
  final match = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(host);
  if (match == null) return null;
  final o = List<int>.generate(4, (i) => int.parse(match.group(i + 1)!));
  if (o.any((n) => n > 255)) return null;
  final a = o[0];
  final b = o[1];
  if (a == 0 || a == 10 || a == 127 || a >= 224) return null;
  if (a == 169 && b == 254) return null;
  if (a == 100 && (b & 0xc0) == 64) return null;
  if (a == 172 && b >= 16 && b <= 31) return null;
  if (a == 192 && b == 168) return null;
  if (a == 192 && b == 0 && o[2] == 2) return null;
  if (a == 198 && (b == 18 || b == 19)) return null;
  return o.join('.');
}

String describeRemoteInstall(String output) {
  final text = output.replaceAll('\r', '').trim();
  final lower = text.toLowerCase();
  if (lower.contains('python3') && (lower.contains('not found') || lower.contains('no such'))) {
    return '这台系统没有 python3，请先装好再试';
  }
  if (lower.contains('systemctl') && lower.contains('not found')) {
    return '这台系统没有 systemd，换一台普通 Linux VPS';
  }
  if (lower.contains('landing did not listen')) {
    final port = RegExp(r'listen on (\d+)').firstMatch(text)?.group(1);
    final which = port == null ? '端口没监听到' : '$port 没监听到';
    return '落地服务没能起来。$which。看日志，或检查这个端口是否被占用';
  }
  if (lower.contains('could not get lock') || lower.contains('unmet dependencies')) {
    return 'VPS 上的软件源正忙或依赖没装全，稍等再试';
  }
  final lines = text.split('\n').map((line) => line.trim()).where((line) {
    if (line.isEmpty) return false;
    final low = line.toLowerCase();
    if (low.contains('token') || low.contains('password')) return false;
    return true;
  }).toList();
  final tail = lines.length <= 5 ? lines : lines.sublist(lines.length - 5);
  if (tail.isEmpty) return 'VPS 上安装落地服务失败';
  final shown = tail.map(_oneLine).join(' / ');
  return 'VPS 上安装失败：$shown';
}

String _oneLine(String line) {
  var text = line.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length > 180) text = '${text.substring(0, 180)}…';
  return text;
}

class VpsSetup {
  Future<String> install({
    required String host,
    required String password,
    required String token,
    required int requiredPort,
    int sshPort = 22,
    void Function(String step)? onStep,
  }) async {
    final ip = publicIpv4(host);
    if (ip == null) {
      throw VpsSetupException('VPS 要填公网 IPv4，例如 203.0.113.10');
    }
    if (password.isEmpty) {
      throw VpsSetupException('先填写 root 密码');
    }
    if (token.isEmpty || token.length > 256) {
      throw VpsSetupException('连接令牌不合法');
    }

    onStep?.call('正在连接 $ip:22');
    SSHClient? client;
    try {
      final socket = await SSHSocket.connect(ip, sshPort, timeout: const Duration(seconds: 20));
      client = SSHClient(
        socket,
        username: 'root',
        identities: const [],
        onPasswordRequest: () => password,
        onUserInfoRequest: (request) => List<String>.filled(request.prompts.length, password),
        disableHostkeyVerification: true,
        handshakeTimeout: const Duration(seconds: 25),
        authTimeout: const Duration(seconds: 25),
        keepAliveInterval: const Duration(seconds: 8),
      );
      await client.authenticated.timeout(const Duration(seconds: 30));

      onStep?.call('已登录，正在上传落地程序');
      await _put(client, '/tmp/ttm-landing.py', await rootBundle.loadString('assets/server/landing.py'));
      await _put(client, '/tmp/ttm-install.sh', _installer);
      await _put(client, '/tmp/ttm-token', '$token\n');

      onStep?.call('正在服务器上安装并启动');
      await _exec(client, 'TTM_NEED_PORT=$requiredPort bash /tmp/ttm-install.sh', onStep: onStep);
      final used = await _read(client, '/etc/tiaotiaohou/token');
      if (used.isEmpty) {
        throw VpsSetupException('服务器上没有写上连接令牌');
      }
      onStep?.call('VPS 落地已启动');
      return used;
    } on TimeoutException {
      throw VpsSetupException('VPS 安装超时。若卡在装软件，稍后再试');
    } on VpsSetupException {
      rethrow;
    } catch (err) {
      throw VpsSetupException(_sshError(err));
    } finally {
      client?.close();
    }
  }

  Future<String> _read(SSHClient client, String path) async {
    final sftp = await client.sftp().timeout(const Duration(seconds: 20));
    final file = await sftp.open(path);
    final bytes = await file.readBytes();
    await file.close();
    return utf8.decode(bytes).trim();
  }

  Future<void> _put(SSHClient client, String path, String text) async {
    final bytes = Uint8List.fromList(utf8.encode(text.replaceAll('\r\n', '\n')));
    try {
      final sftp = await client.sftp().timeout(const Duration(seconds: 20));
      final file = await sftp.open(
        path,
        mode: SftpFileOpenMode.create | SftpFileOpenMode.truncate | SftpFileOpenMode.write,
      );
      await file.writeBytes(bytes);
      await file.close();
      return;
    } catch (_) {}
    final session = await client.execute('cat > $path');
    unawaited(session.stdout.drain<void>());
    unawaited(session.stderr.drain<void>());
    session.write(bytes);
    await session.flush();
    await session.stdin.close();
    await session.done.timeout(const Duration(seconds: 30));
    if ((session.exitCode ?? 0) != 0) {
      throw VpsSetupException('上传文件失败');
    }
  }

  Future<void> _exec(SSHClient client, String command, {void Function(String step)? onStep}) async {
    final session = await client.execute(command);
    final out = StringBuffer();
    final pending = StringBuffer();
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();

    void onData(Uint8List data) {
      final chunk = utf8.decode(data, allowMalformed: true);
      out.write(chunk);
      pending.write(chunk);
      var buffer = pending.toString();
      var index = buffer.indexOf('\n');
      while (index >= 0) {
        final line = buffer.substring(0, index).trim();
        buffer = buffer.substring(index + 1);
        if (line.isNotEmpty && !line.toLowerCase().contains('token')) {
          onStep?.call(_oneLine(line));
        }
        index = buffer.indexOf('\n');
      }
      pending
        ..clear()
        ..write(buffer);
    }

    session.stdout.listen(onData, onDone: stdoutDone.complete, onError: stdoutDone.completeError, cancelOnError: true);
    session.stderr.listen(onData, onDone: stderrDone.complete, onError: stderrDone.completeError, cancelOnError: true);

    await session.done.timeout(const Duration(minutes: 8));
    await Future.wait([stdoutDone.future, stderrDone.future]).timeout(const Duration(seconds: 20));
    final rest = pending.toString().trim();
    if (rest.isNotEmpty && !rest.toLowerCase().contains('token')) {
      onStep?.call(_oneLine(rest));
    }
    if ((session.exitCode ?? 1) != 0) {
      throw VpsSetupException(describeRemoteInstall(out.toString()));
    }
  }

  String _sshError(Object err) {
    final text = '$err'.toLowerCase();
    if (text.contains('auth') || text.contains('password') || text.contains('permission') || text.contains('denied')) {
      return 'VPS 登录失败，请确认 IP、root 密码，以及 22 端口能从本机连上';
    }
    if (text.contains('timed out') || text.contains('timeout') || text.contains('refused') || text.contains('unreachable')) {
      return '连不上这台 VPS，请确认 IP 和 SSH 端口';
    }
    if (text.contains('handshake') || text.contains('kex') || text.contains('algorithm')) {
      return 'SSH 握手失败，换一台较新的 Linux VPS 再试';
    }
    return 'VPS 搭建失败';
  }
}

const _installer = r'''
set -euo pipefail
echo "检查系统"
if ! command -v systemctl >/dev/null 2>&1; then
  echo "systemctl not found" >&2
  exit 1
fi
export DEBIAN_FRONTEND=noninteractive
need_pkg=0
command -v python3 >/dev/null 2>&1 || need_pkg=1
command -v openssl >/dev/null 2>&1 || need_pkg=1
if [ "$need_pkg" = 1 ]; then
  echo "正在安装 python3 / openssl"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get -o Acquire::ForceIPv4=true update -y || apt-get update -y || true
    apt-get install -y python3 openssl ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    yum install -y python3 openssl ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3 openssl ca-certificates
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache python3 openssl ca-certificates
  fi
else
  echo "python3 已存在，跳过装包"
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found" >&2
  exit 1
fi
echo "写入落地文件"
mkdir -p /opt/tiaotiaohou /etc/tiaotiaohou
install -m 0755 /tmp/ttm-landing.py /opt/tiaotiaohou/landing.py
if [ -s /etc/tiaotiaohou/token ]; then
  echo "沿用已有连接令牌，同一台机器上的另一套还能用"
  rm -f /tmp/ttm-token
else
  install -m 0600 /tmp/ttm-token /etc/tiaotiaohou/token
  rm -f /tmp/ttm-token
fi
if [ ! -s /etc/tiaotiaohou/cert.pem ] || [ ! -s /etc/tiaotiaohou/key.pem ]; then
  echo "生成证书"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout /etc/tiaotiaohou/key.pem -out /etc/tiaotiaohou/cert.pem \
    -subj "/CN=tiaotiaohou"
  chmod 600 /etc/tiaotiaohou/key.pem
  chmod 644 /etc/tiaotiaohou/cert.pem
fi
cat > /etc/systemd/system/tiaotiaohou-landing.service <<'EOF'
[Unit]
Description=tiaotiaohou landing
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/env python3 /opt/tiaotiaohou/landing.py
Restart=always
RestartSec=2
Environment=TTM_PORT=8444
Environment=TTM_TLS_PORT=8443
Environment=TTM_ORIGIN_PORT=443
Environment=TTM_UDP_PORT=8444
Environment=TTM_TOKEN_FILE=/etc/tiaotiaohou/token
Environment=TTM_CERT_FILE=/etc/tiaotiaohou/cert.pem
Environment=TTM_KEY_FILE=/etc/tiaotiaohou/key.pem
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
if command -v ufw >/dev/null 2>&1; then
  ufw allow 8443/tcp || true
  ufw allow 8444/tcp || true
  ufw allow 8444/udp || true
  ufw allow 443/tcp || true
fi
if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port=8443/tcp || true
  firewall-cmd --permanent --add-port=8444/tcp || true
  firewall-cmd --permanent --add-port=8444/udp || true
  firewall-cmd --permanent --add-port=443/tcp || true
  firewall-cmd --reload || true
fi
if command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p tcp --dport 8443 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 8443 -j ACCEPT || true
  iptables -C INPUT -p tcp --dport 8444 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 8444 -j ACCEPT || true
  iptables -C INPUT -p udp --dport 8444 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 8444 -j ACCEPT || true
  iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 443 -j ACCEPT || true
fi
echo "启动落地服务"
systemctl daemon-reload
systemctl enable --now tiaotiaohou-landing.service
systemctl restart tiaotiaohou-landing.service
need="${TTM_NEED_PORT:-8444}"
ok=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if python3 -c "import socket; s=socket.create_connection(('127.0.0.1', int('${need}')), 2); s.close()" 2>/dev/null; then
    ok=1
    break
  fi
  sleep 1
done
if [ "$ok" != 1 ]; then
  echo "landing did not listen on ${need}" >&2
  systemctl --no-pager --full status tiaotiaohou-landing.service >&2 || true
  journalctl -u tiaotiaohou-landing.service -n 30 --no-pager >&2 || true
  exit 1
fi
echo "${need} 已在监听"
rm -f /tmp/ttm-install.sh /tmp/ttm-landing.py
''';
