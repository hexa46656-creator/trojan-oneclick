#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
SERVICE="trojan-server.service"
PORT="${PORT:-443}"
CONFIG_DIR="/etc/trojan"
CONFIG_FILE="/etc/trojan/config.json"
CLIENT_FILE="/root/trojan-client.txt"
NGINX_SITE="/etc/nginx/sites-available/trojan"
NGINX_LINK="/etc/nginx/sites-enabled/trojan"

log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "请使用 root 执行：DOMAIN=xxx EMAIL=yyy bash install.sh"
    exit 1
  fi
}

require_vars() {
  if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
    err "必须通过环境变量提供 DOMAIN 和 EMAIL"
    err "示例：DOMAIN=proxy.example.com EMAIL=admin@example.com bash install.sh"
    exit 1
  fi
}

install_packages() {
  apt-get update -y
  apt-get install -y nginx certbot python3-certbot-nginx dnsutils curl unzip ca-certificates ufw xz-utils python3 openssl
}

get_public_ip() {
  local ip
  ip="$(curl -4 -fsS ifconfig.me 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4 -fsS https://api.ipify.org 2>/dev/null || true)"
  fi
  printf '%s' "$ip"
}

check_dns() {
  local domain_ip public_ip
  public_ip="$(get_public_ip)"
  if [[ -z "$public_ip" ]]; then
    err "无法获取当前 VPS 公网 IPv4，请先确认网络可用"
    exit 1
  fi
  domain_ip="$(dig +short A "$DOMAIN" | head -n1 | tr -d '\r')"
  if [[ -z "$domain_ip" ]]; then
    err "DOMAIN 未解析出 A 记录：$DOMAIN"
    err "请先添加正确的 A 记录，再重新执行安装"
    exit 1
  fi
  if [[ "$domain_ip" != "$public_ip" ]]; then
    err "DNS 解析不正确"
    err "DOMAIN: $DOMAIN"
    err "解析到: $domain_ip"
    err "当前 VPS: $public_ip"
    err "请将 A 记录修正到当前 VPS 公网 IPv4 后重试"
    exit 1
  fi
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64) printf '%s' "amd64" ;;
    aarch64|arm64) printf '%s' "arm64" ;;
    *) err "不支持的架构：$arch"; exit 1 ;;
  esac
}

install_trojan_binary() {
  local arch api_url asset_url tmpdir
  arch="$(detect_arch)"
  api_url="https://api.github.com/repos/trojan-gfw/trojan/releases/latest"
  asset_url="$(curl -fsSL "$api_url" \
    | grep -oE '"browser_download_url":[[:space:]]*"[^"]*\.tar\.xz"' \
    | grep -E "(${arch}|x86_64|amd64|arm64)" \
    | head -n1 \
    | cut -d'"' -f4)"
  if [[ -z "${asset_url:-}" ]]; then
    err "未能找到适合当前架构的 Trojan 安装包"
    exit 1
  fi
  tmpdir="$(mktemp -d)"
  log "下载 Trojan：$asset_url"
  curl -fsSL "$asset_url" -o "$tmpdir/trojan.tar.xz"
  tar -xf "$tmpdir/trojan.tar.xz" -C "$tmpdir"
  if [[ -f "$tmpdir/trojan" ]]; then
    install -m 0755 "$tmpdir/trojan" /usr/local/bin/trojan
  else
    local binary
    binary="$(find "$tmpdir" -type f -name trojan | head -n1)"
    if [[ -z "$binary" ]]; then
      err "未在 Trojan 压缩包中找到可执行文件"
      exit 1
    fi
    install -m 0755 "$binary" /usr/local/bin/trojan
  fi
  rm -rf "$tmpdir"
}

write_nginx_http_site() {
  cat > "$NGINX_SITE" <<EOF
server {
  listen 80;
  server_name ${DOMAIN};
  root /var/www/html;
  location / {
    try_files \$uri \$uri/ =404;
  }
}
EOF
  ln -sf "$NGINX_SITE" "$NGINX_LINK"
  rm -f /etc/nginx/sites-enabled/default || true
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

request_certificate() {
  certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --keep-until-expiring
}

generate_password() {
  openssl rand -base64 24 | tr -d '\n'
}

urlencode() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=''))
PY
}

write_config() {
  local password="$1"
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_FILE" <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": ${PORT},
  "remote_addr": "127.0.0.1",
  "remote_port": 80,
  "password": ["${password}"],
  "ssl": {
    "cert": "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem",
    "key": "/etc/letsencrypt/live/${DOMAIN}/privkey.pem",
    "sni": "${DOMAIN}"
  }
}
EOF
}

write_service() {
  cat > "/etc/systemd/system/${SERVICE}" <<EOF
[Unit]
Description=Trojan Server
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/trojan -c ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

allow_ufw_ports() {
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    ufw allow 80/tcp >/dev/null
    ufw allow "${PORT}/tcp" >/dev/null
  fi
}

write_client_file() {
  local password="$1"
  local encoded_password encoded_name trojan_uri
  encoded_password="$(urlencode "$password")"
  encoded_name="$(urlencode "Trojan-${DOMAIN}")"
  trojan_uri="trojan://${encoded_password}@${DOMAIN}:${PORT}?peer=${DOMAIN}&sni=${DOMAIN}#${encoded_name}"

  cat > "$CLIENT_FILE" <<EOF
Trojan 客户端信息
=================
域名: ${DOMAIN}
端口: ${PORT}
原始密码: ${password}
SNI: ${DOMAIN}
Peer: ${DOMAIN}

Shadowrocket 手动填写说明:
类型: Trojan
地址: ${DOMAIN}
端口: ${PORT}
密码: 原始密码
TLS: 开启
SNI/Peer: ${DOMAIN}
Allow Insecure: 关闭

最终 trojan:// 导入链接:
${trojan_uri}
EOF

  chmod 600 "$CLIENT_FILE"
}

print_final_screen() {
  local trojan_uri
  trojan_uri="$(grep -E '^trojan://' "$CLIENT_FILE" | tail -n 1 || true)"

  printf '\n\033[1;32m============================================================\033[0m\n'
  printf '\033[1;32mTrojan 部署完成\033[0m\n'
  printf '\033[1;32m============================================================\033[0m\n'
  printf '\033[1;33m域名: %s\033[0m\n' "$DOMAIN"
  printf '\033[1;33m端口: %s\033[0m\n' "$PORT"
  printf '\033[1;33mSNI: %s\033[0m\n' "$DOMAIN"
  printf '\033[1;33mPeer: %s\033[0m\n' "$DOMAIN"
  printf '\033[1;33m客户端信息保存路径: %s\033[0m\n' "$CLIENT_FILE"
  printf '\n\033[1;36m最终 trojan:// 导入链接\033[0m\n'
  printf '\033[1;36m%s\033[0m\n' "$trojan_uri"
}

main() {
  require_root
  require_vars
  install_packages
  check_dns
  install_trojan_binary
  write_nginx_http_site
  request_certificate

  local password
  password="$(generate_password)"
  write_config "$password"
  write_service
  systemctl daemon-reload
  systemctl enable --now "$SERVICE"
  allow_ufw_ports
  write_client_file "$password"
  print_final_screen
}

main "$@"
