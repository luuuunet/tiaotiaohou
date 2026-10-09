#!/usr/bin/env bash
set -euo pipefail

# 在 VPS 上执行：sudo bash install.sh
# 8443 给 Cloudflare Worker 落地，8444 TLS/UDP 给客户端直连。

ROOT=/opt/tiaotiaohou
ETC=/etc/tiaotiaohou
PORT="${TTM_PORT:-8443}"
TLS_PORT="${TTM_TLS_PORT:-8444}"
SRC="$(cd "$(dirname "$0")" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请用 root 执行：sudo bash $0"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
need_pkg=0
command -v python3 >/dev/null 2>&1 || need_pkg=1
command -v openssl >/dev/null 2>&1 || need_pkg=1
if [[ "$need_pkg" -eq 1 ]]; then
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
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found" >&2
  exit 1
fi

mkdir -p "$ROOT" "$ETC"
install -m 0755 "$SRC/landing.py" "$ROOT/landing.py"

if [[ ! -s "$ETC/token" ]]; then
  python3 - <<'PY'
import secrets
from pathlib import Path
Path("/etc/tiaotiaohou/token").write_text(secrets.token_urlsafe(24) + "\n", encoding="utf-8")
PY
  chmod 600 "$ETC/token"
fi

if [[ ! -s "$ETC/cert.pem" || ! -s "$ETC/key.pem" ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$ETC/key.pem" -out "$ETC/cert.pem" \
    -subj "/CN=tiaotiaohou"
  chmod 600 "$ETC/key.pem"
  chmod 644 "$ETC/cert.pem"
fi

IP="$(python3 - <<'PY'
import urllib.request
try:
    print(urllib.request.urlopen("https://api.ipify.org", timeout=8).read().decode().strip())
except Exception:
    print("")
PY
)"
if [[ -z "$IP" ]]; then
  IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi

cat > /etc/systemd/system/tiaotiaohou-landing.service <<EOF
[Unit]
Description=跳跳猴落地
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/env python3 $ROOT/landing.py
Restart=always
RestartSec=2
Environment=TTM_PORT=$PORT
Environment=TTM_TLS_PORT=$TLS_PORT
Environment=TTM_TOKEN_FILE=$ETC/token
Environment=TTM_CERT_FILE=$ETC/cert.pem
Environment=TTM_KEY_FILE=$ETC/key.pem
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

if command -v ufw >/dev/null 2>&1; then
  ufw allow "${PORT}/tcp" || true
  ufw allow "${TLS_PORT}/tcp" || true
  ufw allow "${TLS_PORT}/udp" || true
fi
if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${PORT}/tcp" || true
  firewall-cmd --permanent --add-port="${TLS_PORT}/tcp" || true
  firewall-cmd --permanent --add-port="${TLS_PORT}/udp" || true
  firewall-cmd --reload || true
fi

systemctl daemon-reload
systemctl enable --now tiaotiaohou-landing.service
systemctl restart tiaotiaohou-landing.service
ok=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  if python3 -c 'import socket; s=socket.create_connection(("127.0.0.1",'"$PORT"'),2); s.close()' 2>/dev/null; then
    ok=1
    break
  fi
  sleep 1
done
if [ "$ok" != 1 ]; then
  echo "landing did not listen on $PORT" >&2
  systemctl --no-pager --full status tiaotiaohou-landing.service | head -n 20 >&2 || true
  exit 1
fi

TOKEN="$(tr -d '\n' < "$ETC/token")"
echo
echo "Worker 落地: ${IP}:${PORT}  （明文 TCP，给 Cloudflare Worker 用）"
echo "客户端直连: https://${IP}:${TLS_PORT}"
echo "在客户端选「直连 VPS」，节点地址填上面这一行，连接令牌填："
echo "$TOKEN"
