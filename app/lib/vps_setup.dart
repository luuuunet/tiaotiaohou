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
    String certMode = 'self',
    String domain = '',
    String cloudflareToken = '',
    String certificate = '',
    String privateKey = '',
    int? tlsPort,
    int? originPort,
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
    final mode = certMode == 'acme' || certMode == 'own' || certMode == 'acme-http' ? certMode : 'self';
    if (mode == 'acme' || mode == 'acme-http') {
      if (domain.isEmpty) throw VpsSetupException('自动申请证书要先填域名');
    }
    if (mode == 'acme' && cloudflareToken.trim().isEmpty) {
      throw VpsSetupException('自动申请证书要用 Cloudflare API 令牌');
    }
    if (mode == 'own') {
      final problem = ownCertificateProblem(certificate, privateKey);
      if (problem != null) throw VpsSetupException(problem);
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
      if (mode == 'own') {
        onStep?.call('正在上传自有证书');
        await _put(client, '/tmp/ttm-cert.pem', certificate.trim());
        await _put(client, '/tmp/ttm-key.pem', privateKey.trim());
      }
      if (mode == 'acme') {
        onStep?.call('正在准备 ACME 申请');
        await _put(client, '/tmp/ttm-cf.ini', 'dns_cloudflare_api_token = ${cloudflareToken.trim()}\n');
      }

      onStep?.call(mode == 'acme' ? '正在申请证书并启动' : '正在服务器上安装并启动');
      final command = StringBuffer('TTM_NEED_PORT=$requiredPort TTM_CERT_MODE=$mode TTM_DOMAIN=${_shellQuote(domain)} TTM_EXPECT_IP=$ip');
      if (tlsPort != null) command.write(' TTM_TLS_PORT=$tlsPort');
      if (originPort != null) command.write(' TTM_ORIGIN_PORT=$originPort');
      command.write(' bash /tmp/ttm-install.sh');
      await _exec(
        client,
        command.toString(),
        onStep: onStep,
        timeout: mode == 'acme' || mode == 'acme-http' ? const Duration(minutes: 12) : const Duration(minutes: 8),
      );
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

  Future<void> _exec(SSHClient client, String command, {void Function(String step)? onStep, Duration timeout = const Duration(minutes: 8)}) async {
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
        if (line.isNotEmpty && !_secretLog(line)) {
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

    await session.done.timeout(timeout);
    await Future.wait([stdoutDone.future, stderrDone.future]).timeout(const Duration(seconds: 20));
    final rest = pending.toString().trim();
    if (rest.isNotEmpty && !_secretLog(rest)) {
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

bool _secretLog(String line) {
  final low = line.toLowerCase();
  return low.contains('token') || low.contains('private key') || low.contains('begin certificate');
}

String _shellQuote(String value) {
  return "'${value.replaceAll("'", "'\\''")}'";
}

/// 自有证书要是 PEM。返回 null 表示可以上传。
/// 直连搭建用的域名，必须是用户自己填的主机名，不会自动加前缀。
String? directHostname(String input) {
  var host = input.trim().toLowerCase();
  if (host.startsWith('https://')) host = host.substring(8);
  if (host.startsWith('http://')) host = host.substring(7);
  host = host.split('/').first;
  if (host.isEmpty || host.contains(':')) return null;
  final labels = host.split('.');
  if (labels.length < 2 || labels.any((label) => label.isEmpty)) return null;
  if (!RegExp(r'^[a-z0-9.-]+$').hasMatch(host)) return null;
  if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) return null;
  return host;
}

String? ownCertificateProblem(String certificate, String privateKey) {
  final cert = certificate.trim();
  final key = privateKey.trim();
  if (!cert.contains('-----BEGIN CERTIFICATE-----') || !cert.contains('-----END CERTIFICATE-----')) {
    return '证书要贴完整的 PEM，从 BEGIN CERTIFICATE 到 END CERTIFICATE';
  }
  if (!key.contains('PRIVATE KEY-----') || !key.contains('-----END')) {
    return '私钥要贴完整的 PEM';
  }
  return null;
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
mode="${TTM_CERT_MODE:-self}"
domain="${TTM_DOMAIN:-}"
expect_ip="${TTM_EXPECT_IP:-}"
if [ "$mode" = "acme-http" ]; then
  echo "正在检查域名是否指向这台服务器"
  if [ -z "$domain" ]; then
    echo "acme needs domain" >&2
    exit 1
  fi
  resolved="$(python3 -c 'import os,socket; print(socket.gethostbyname(os.environ["TTM_DOMAIN"]))' 2>/dev/null || true)"
  if [ -z "$resolved" ] || [ "$resolved" != "$expect_ip" ]; then
    echo "域名 $domain 还没指向 $expect_ip" >&2
    exit 1
  fi
  echo "正在安装 ACME 工具"
  if ! command -v certbot >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get -o Acquire::ForceIPv4=true update -y || apt-get update -y || true
      apt-get install -y certbot
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y certbot
    elif command -v yum >/dev/null 2>&1; then
      yum install -y certbot
    else
      echo "certbot not available" >&2
      exit 1
    fi
  fi
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 80/tcp || true
  fi
  echo "正在为 $domain 申请证书"
  certbot certonly --standalone \
    -d "$domain" \
    --agree-tos --register-unsafely-without-email \
    --non-interactive --keep-until-expiring
  install -m 0644 "/etc/letsencrypt/live/$domain/fullchain.pem" /etc/tiaotiaohou/cert.pem
  install -m 0600 "/etc/letsencrypt/live/$domain/privkey.pem" /etc/tiaotiaohou/key.pem
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/tiaotiaohou.sh <<EOF
#!/bin/sh
install -m 0644 "/etc/letsencrypt/live/$domain/fullchain.pem" /etc/tiaotiaohou/cert.pem
install -m 0600 "/etc/letsencrypt/live/$domain/privkey.pem" /etc/tiaotiaohou/key.pem
systemctl restart tiaotiaohou-landing.service
EOF
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/tiaotiaohou.sh
elif [ "$mode" = "own" ]; then
  echo "写入自有证书"
  if [ ! -s /tmp/ttm-cert.pem ] || [ ! -s /tmp/ttm-key.pem ]; then
    echo "own cert missing" >&2
    exit 1
  fi
  install -m 0644 /tmp/ttm-cert.pem /etc/tiaotiaohou/cert.pem
  install -m 0600 /tmp/ttm-key.pem /etc/tiaotiaohou/key.pem
  rm -f /tmp/ttm-cert.pem /tmp/ttm-key.pem
elif [ "$mode" = "acme" ]; then
  echo "正在安装 ACME 工具"
  if ! command -v certbot >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get -o Acquire::ForceIPv4=true update -y || apt-get update -y || true
      apt-get install -y certbot python3-certbot-dns-cloudflare
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y certbot python3-certbot-dns-cloudflare
    elif command -v yum >/dev/null 2>&1; then
      yum install -y certbot python3-certbot-dns-cloudflare
    else
      echo "certbot not available" >&2
      exit 1
    fi
  fi
  if [ -z "$domain" ] || [ ! -s /tmp/ttm-cf.ini ]; then
    echo "acme needs domain and cloudflare token" >&2
    exit 1
  fi
  install -m 0600 /tmp/ttm-cf.ini /etc/tiaotiaohou/cloudflare.ini
  rm -f /tmp/ttm-cf.ini
  echo "正在为 $domain 申请证书"
  certbot certonly --dns-cloudflare \
    --dns-cloudflare-credentials /etc/tiaotiaohou/cloudflare.ini \
    --dns-cloudflare-propagation-seconds 60 \
    -d "$domain" \
    --agree-tos --register-unsafely-without-email \
    --non-interactive --keep-until-expiring
  install -m 0644 "/etc/letsencrypt/live/$domain/fullchain.pem" /etc/tiaotiaohou/cert.pem
  install -m 0600 "/etc/letsencrypt/live/$domain/privkey.pem" /etc/tiaotiaohou/key.pem
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/tiaotiaohou.sh <<EOF
#!/bin/sh
install -m 0644 "/etc/letsencrypt/live/$domain/fullchain.pem" /etc/tiaotiaohou/cert.pem
install -m 0600 "/etc/letsencrypt/live/$domain/privkey.pem" /etc/tiaotiaohou/key.pem
systemctl restart tiaotiaohou-landing.service
EOF
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/tiaotiaohou.sh
elif [ ! -s /etc/tiaotiaohou/cert.pem ] || [ ! -s /etc/tiaotiaohou/key.pem ]; then
  echo "生成临时证书"
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
tls_port="${TTM_TLS_PORT:-8443}"
origin_port="${TTM_ORIGIN_PORT:-443}"
python3 - <<PY
from pathlib import Path
path = Path("/etc/systemd/system/tiaotiaohou-landing.service")
text = path.read_text(encoding="utf-8")
text = text.replace("TTM_TLS_PORT=8443", "TTM_TLS_PORT=$tls_port")
text = text.replace("TTM_ORIGIN_PORT=443", "TTM_ORIGIN_PORT=$origin_port")
path.write_text(text, encoding="utf-8")
PY
if command -v ufw >/dev/null 2>&1; then
  ufw allow 8443/tcp || true
  ufw allow 8444/tcp || true
  ufw allow 8444/udp || true
  ufw allow 443/tcp || true
  ufw allow 80/tcp || true
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
