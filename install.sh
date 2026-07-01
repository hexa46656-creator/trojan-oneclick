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
NETWORK_SYSCTL_FILE="/etc/sysctl.d/99-trojan-oneclick-tuning.conf"
UFW_MSS_CLAMP_MARKER="vpsguard-trojan-mss-clamp"
INSTALLER_CORE_DIR="${INSTALLER_CORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../vps-installer-core" 2>/dev/null && pwd || true)}"

log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

if [[ -n "${INSTALLER_CORE_DIR}" && -f "${INSTALLER_CORE_DIR}/installer_core.sh" ]]; then
  # shellcheck source=/dev/null
  source "${INSTALLER_CORE_DIR}/installer_core.sh"
fi

if ! declare -F installer_core_detect_os >/dev/null 2>&1; then
  installer_core_detect_os() {
    local os_id
    local os_name
    local os_pretty_name
    local init_comm

    if [[ ! -r /etc/os-release ]]; then
      err "无法读取 /etc/os-release"
      exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    os_id="${ID:-unknown}"
    os_name="${NAME:-${ID:-unknown}}"
    os_pretty_name="${PRETTY_NAME:-${os_name}}"

    case "${os_id}" in
      ubuntu|debian) ;;
      *) err "不支持的系统：${os_pretty_name}，仅支持 Ubuntu 或 Debian"; exit 1 ;;
    esac

    init_comm="$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "${init_comm}" != "systemd" && ! -d /run/systemd/system ]]; then
      err "systemd 不可用，无法继续安装"
      exit 1
    fi

    # shellcheck disable=SC2034
    INSTALLER_OS_ID="${os_id}"
    # shellcheck disable=SC2034
    INSTALLER_OS_NAME="${os_name}"
    # shellcheck disable=SC2034
    INSTALLER_OS_VERSION_ID="${VERSION_ID:-unknown}"
    # shellcheck disable=SC2034
    INSTALLER_OS_PRETTY_NAME="${os_pretty_name}"
  }
fi

if ! declare -F installer_core_install_packages >/dev/null 2>&1; then
  installer_core_install_packages() {
    local packages=("$@")

    if [[ "${#packages[@]}" -eq 0 ]]; then
      return 0
    fi

    export DEBIAN_FRONTEND=noninteractive

    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      apt-get install -y "${packages[@]}"
    else
      apt update
      apt install -y "${packages[@]}"
    fi
  }
fi

if ! declare -F installer_core_subscription_protocol_defaults >/dev/null 2>&1; then
  installer_core_subscription_protocol_defaults() {
    SUBSCRIPTION_ACCESS_URL="${SUBSCRIPTION_ACCESS_URL:-${TROJAN_URI:-}}"
  }
fi

if ! declare -F installer_core_publish_subscription >/dev/null 2>&1; then
  installer_core_publish_subscription() {
    SUBSCRIPTION_ACCESS_URL="${SUBSCRIPTION_ACCESS_URL:-${TROJAN_URI:-}}"
  }
fi

if ! declare -F installer_core_mode_label >/dev/null 2>&1; then
  installer_core_mode_label() {
    printf '%s\n' "standalone"
  }
fi

if ! declare -F installer_core_print_completion_block >/dev/null 2>&1; then
  installer_core_print_completion_block() {
    local mode="${1:-standalone}"
    local access_url="${2:-${SUBSCRIPTION_ACCESS_URL:-${TROJAN_URI:-${HY2_URI:-${VLESS_LINK:-}}}}}"
    local clients="${3:-}"

    printf '\n\033[1;32m============================================================\033[0m\n'
    printf '\033[1;32m%s\033[0m\n' "${mode}"
    if [[ -n "${access_url}" ]]; then
      printf '\033[1;33m链接: %s\033[0m\n' "${access_url}"
    fi
    if [[ -n "${clients}" ]]; then
      printf '\033[1;33m客户端: %s\033[0m\n' "${clients}"
    fi
    printf '\033[1;32m============================================================\033[0m\n'
  }
fi

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "请使用 root 执行：DOMAIN=已经解析到你的IP的域名 EMAIL=您的邮箱 bash install.sh"
    exit 1
  fi
}

require_vars() {
  if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
    err "必须通过环境变量提供 DOMAIN 和 EMAIL"
    err "DOMAIN 必须是已经解析到本 VPS IP 的域名"
    err "EMAIL 请填写你的邮箱，用于申请 Let's Encrypt TLS 证书"
    err "示例："
    err "DOMAIN=已经解析到你的IP的域名 EMAIL=您的邮箱 bash install.sh"
    exit 1
  fi
}

preflight_checks() {
  require_vars

  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    err "PORT 必须是 1-65535 之间的数字，当前值：${PORT}"
    exit 1
  fi

  if [[ "$PORT" == "80" ]]; then
    err "PORT 不能设置为 80。80/tcp 需要留给 Nginx 和 Let's Encrypt HTTP 验证。"
    exit 1
  fi

  log "Preflight passed: DOMAIN=${DOMAIN}, EMAIL=${EMAIL}, TROJAN_PORT=${PORT}"
}

install_packages() {
  installer_core_install_packages nginx certbot python3-certbot-nginx dnsutils curl unzip ca-certificates ufw xz-utils python3 openssl qrencode iproute2
}

detect_path_mtu() {
  local mtu

  mtu="$(ip route get 1.1.1.1 2>/dev/null | awk 'match($0, /mtu ([0-9]+)/, m) {print m[1]; exit}')"

  if [[ -n "${mtu}" ]]; then
    log "Detected path MTU reference: ${mtu}"
    if [[ "${mtu}" -lt 1350 || "${mtu}" -gt 1450 ]]; then
      warn "Path MTU reference is outside the 1350-1450 target range for Trojan: ${mtu}"
    fi
  else
    warn "Unable to detect path MTU reference with ip route get 1.1.1.1."
  fi
}

enable_network_tuning() {
  log "Applying TCP stability tuning..."

  cat > "${NETWORK_SYSCTL_FILE}" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
EOF

  sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || warn "Failed to apply net.core.default_qdisc=fq immediately."
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || warn "Failed to apply net.ipv4.tcp_congestion_control=bbr immediately."
  sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1 || warn "Failed to apply net.ipv4.tcp_fastopen=3 immediately."
  sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1 || warn "Failed to apply net.ipv4.tcp_mtu_probing=1 immediately."
  sysctl -w net.ipv4.tcp_keepalive_time=300 >/dev/null 2>&1 || warn "Failed to apply net.ipv4.tcp_keepalive_time=300 immediately."
  sysctl -w net.ipv4.tcp_keepalive_intvl=30 >/dev/null 2>&1 || warn "Failed to apply net.ipv4.tcp_keepalive_intvl=30 immediately."
  sysctl -w net.ipv4.tcp_keepalive_probes=5 >/dev/null 2>&1 || warn "Failed to apply net.ipv4.tcp_keepalive_probes=5 immediately."
  detect_path_mtu
}

configure_tcp_mss_clamp() {
  local before_rules="/etc/ufw/before.rules"
  local before6_rules="/etc/ufw/before6.rules"
  local marker="# ${UFW_MSS_CLAMP_MARKER}"
  local tmp_file

  for rules_file in "${before_rules}" "${before6_rules}"; do
    [[ -f "${rules_file}" ]] || continue

    if grep -Fq "${marker}" "${rules_file}"; then
      log "UFW MSS clamp rule already present in ${rules_file}"
      continue
    fi

    log "Adding UFW MSS clamp rule to ${rules_file}"
    tmp_file="$(mktemp)"
    {
      printf '%s\n' "${marker}"
      printf '*mangle\n'
      printf ':POSTROUTING ACCEPT [0:0]\n'
      printf '-A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\n'
      printf 'COMMIT\n'
      printf '%s\n' "${marker}"
      cat "${rules_file}"
    } > "${tmp_file}"
    cat "${tmp_file}" > "${rules_file}"
    rm -f "${tmp_file}"
  done

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    ufw reload >/dev/null || true
  fi
}

print_client_qr() {
  local client_url="${1:-}"
  local output_file="${2:-}"

  if [[ -z "${client_url}" ]]; then
    echo "[WARN] Client URL is empty, skip QR code generation."
    return 0
  fi

  if [[ -z "${output_file}" ]]; then
    output_file="/root/trojan-qr.png"
  fi

  if ! command -v qrencode >/dev/null 2>&1; then
    echo "[INFO] Installing qrencode..."
    if command -v apt >/dev/null 2>&1; then
      apt update >/dev/null 2>&1 || true
      apt install -y qrencode >/dev/null 2>&1 || true
    elif command -v apt-get >/dev/null 2>&1; then
      apt-get update >/dev/null 2>&1 || true
      apt-get install -y qrencode >/dev/null 2>&1 || true
    fi
  fi

  if ! command -v qrencode >/dev/null 2>&1; then
    echo "[WARN] qrencode is not available, skip QR code generation."
    echo "[INFO] Client URL:"
    echo "${client_url}"
    return 0
  fi

  echo
  echo "========== Client QR Code =========="
  if ! qrencode -t ANSIUTF8 "${client_url}"; then
    echo "[WARN] Failed to render QR code in terminal."
  fi

  if qrencode -o "${output_file}" "${client_url}"; then
    chmod 600 "${output_file}"
    echo
    echo "[OK] QR code saved to: ${output_file}"
  else
    echo "[WARN] Failed to save QR code PNG."
  fi

  echo
  echo "Mobile import:"
  echo "1. Open Shadowrocket / v2rayNG / Hiddify / NekoBox"
  echo "2. Tap scan QR code"
  echo "3. Scan the QR code above"
  echo "4. Save and test the node"
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
  local public_ip system_dns cloudflare_dns google_dns
  public_ip="$(get_public_ip)"
  if [[ -z "$public_ip" ]]; then
    err "无法获取当前 VPS 公网 IPv4，请先确认网络可用"
    exit 1
  fi

  system_dns="$(dig +short A "$DOMAIN" | head -n1 | tr -d '\r')"
  cloudflare_dns="$(dig +short A "$DOMAIN" @1.1.1.1 | head -n1 | tr -d '\r')"
  google_dns="$(dig +short A "$DOMAIN" @8.8.8.8 | head -n1 | tr -d '\r')"

  log "当前 VPS 公网 IPv4: ${public_ip}"
  log "系统 DNS 解析结果: ${system_dns:-<空>}"
  log "1.1.1.1 解析结果: ${cloudflare_dns:-<空>}"
  log "8.8.8.8 解析结果: ${google_dns:-<空>}"

  if [[ -z "$system_dns" || -z "$cloudflare_dns" || -z "$google_dns" ]]; then
    err "DNS 校验失败：至少有一个解析器没有返回 A 记录。"
    err "DNS 传播不完整或解析器结果不一致，可能导致证书签发失败、客户端连不上，或者 Trojan 连接不稳定。"
    exit 1
  fi

  if [[ "$system_dns" != "$public_ip" || "$cloudflare_dns" != "$public_ip" || "$google_dns" != "$public_ip" ]]; then
    err "DNS 校验失败：解析结果与当前 VPS 公网 IPv4 不一致。"
    err "DNS 传播不完整或解析器结果不一致，可能导致证书签发失败、客户端连不上，或者 Trojan 连接不稳定。"
    err "DOMAIN: $DOMAIN"
    err "当前 VPS: $public_ip"
    err "系统 DNS: $system_dns"
    err "1.1.1.1: $cloudflare_dns"
    err "8.8.8.8: $google_dns"
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
  log "Installing Trojan binary..."

  local arch api_url asset_url tmpdir archive_file trojan_bin asset_pattern fallback_name
  arch="$(detect_arch)"
  api_url="https://api.github.com/repos/trojan-gfw/trojan/releases/latest"
  tmpdir="/tmp/trojan-oneclick"
  archive_file="${tmpdir}/trojan.tar.xz"

  mkdir -p "$tmpdir"

  case "$arch" in
    amd64) asset_pattern='(linux-amd64|amd64|x86_64)' ;;
    arm64) asset_pattern='(linux-arm64|linux-aarch64|arm64|aarch64)' ;;
    *) err "不支持的架构：$arch"; exit 1 ;;
  esac

  asset_url="$(curl -fsSL \
    -H "User-Agent: trojan-oneclick-installer" \
    "$api_url" \
    | grep -oE '"browser_download_url":[[:space:]]*"[^"]*\.tar\.xz"' \
    | grep -Ei "$asset_pattern" \
    | head -n1 \
    | cut -d'"' -f4 || true)"

  if [[ -z "${asset_url:-}" ]]; then
    warn "GitHub API latest request failed or returned no matching asset; using fallback Trojan version."
    TROJAN_VERSION="${TROJAN_VERSION:-1.16.0}"
    fallback_name="trojan-${TROJAN_VERSION}-linux-${arch}.tar.xz"
    asset_url="https://github.com/trojan-gfw/trojan/releases/download/v${TROJAN_VERSION}/${fallback_name}"

    if ! curl -fsSI "$asset_url" >/dev/null 2>&1; then
      err "No Trojan binary is available for architecture '${arch}'."
      err "Upstream trojan-gfw/trojan v${TROJAN_VERSION} may only publish linux-amd64 builds."
      err "Refusing to install an amd64 binary on ${arch}."
      exit 1
    fi
  fi

  log "Downloading Trojan from: $asset_url"

  curl -fL "$asset_url" -o "$archive_file" || {
    err "Failed to download Trojan binary."
    exit 1
  }

  tar -xf "$archive_file" -C "$tmpdir" || {
    err "Failed to extract Trojan archive."
    exit 1
  }

  trojan_bin="$(find "$tmpdir" -type f -name trojan | head -n1 || true)"

  if [[ -z "${trojan_bin:-}" ]]; then
    err "Trojan binary not found after extraction."
    exit 1
  fi

  install -m 755 "$trojan_bin" /usr/local/bin/trojan

  command -v trojan >/dev/null 2>&1 || {
    err "Trojan installation failed: trojan command not found."
    exit 1
  }

  if ! trojan -v >/dev/null 2>&1; then
    err "Trojan binary failed to execute on this machine. Architecture may be incompatible."
    exit 1
  fi

  log "Trojan installed successfully: $(trojan -v 2>&1 | head -n1 || true)"
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
  if certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --keep-until-expiring; then
    return 0
  fi

  warn "Nginx 模式申请证书失败，尝试使用 webroot 回退方式。"
  if certbot certonly --webroot -w /var/www/html -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --keep-until-expiring; then
    return 0
  fi

  err "证书申请失败，请按以下顺序排查："
  err "1) 检查 DNS A 记录是否已经正确指向当前 VPS 公网 IPv4"
  err "2) 检查 80 端口是否可从公网访问"
  err "3) 检查 nginx 状态是否正常"
  err "4) 如果你在使用 Cloudflare，请在签发证书期间切换为 DNS only"
  err "5) 查看 certbot 日志 /var/log/letsencrypt/ 下的详细错误"
  exit 1
}

open_required_ports() {
  if command -v ufw >/dev/null 2>&1; then
    log "Opening required UFW ports before installation: 80/tcp and ${PORT}/tcp..."
    ufw allow 80/tcp >/dev/null || warn "Could not add UFW rule for 80/tcp. Certificate issuance may fail."
    ufw allow "${PORT}/tcp" >/dev/null || warn "Could not add UFW rule for ${PORT}/tcp. Trojan may be unreachable."

    if ufw status | grep -q '^Status: active'; then
      ufw reload >/dev/null || true
      log "UFW is active. Required ports are allowed."
    else
      warn "UFW is not active. Port rules were added but are not currently effective."
      warn "Before enabling UFW, make sure your SSH port is allowed to avoid locking yourself out."
    fi
  else
    warn "UFW not found. Skipping firewall rule configuration."
  fi
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
    "sni": "${DOMAIN}",
    "reuse_session": true,
    "session_ticket": true
  },
  "tcp": {
    "fast_open": true,
    "fast_open_qlen": 1024,
    "keep_alive": true
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
  if command -v ufw >/dev/null 2>&1; then
    log "Configuring UFW port rules..."

    ufw allow 80/tcp >/dev/null
    ufw allow "${PORT}/tcp" >/dev/null

    if ufw status | grep -q '^Status: active'; then
      ufw reload >/dev/null || true
      log "UFW is active. Allowed 80/tcp and ${PORT}/tcp."
    else
      warn "UFW is not active. Port rules have been added but are not currently effective."
      warn "Before enabling UFW, make sure your SSH port is allowed to avoid locking yourself out."
      warn "If you are sure it is safe, run manually: ufw allow OpenSSH && ufw enable"
    fi
  else
    warn "UFW not found. Skipping firewall rule verification."
  fi
}

start_trojan_service() {
  log "Starting Trojan service..."

  systemctl daemon-reload
  if ! systemctl enable --now "$SERVICE"; then
    err "Trojan service failed to start."
    systemctl status "$SERVICE" --no-pager || true
    journalctl -u "$SERVICE" -n 80 --no-pager || true
    exit 1
  fi

  sleep 2

  if ! systemctl is-active --quiet "$SERVICE"; then
    err "Trojan service is not active after start."
    systemctl status "$SERVICE" --no-pager || true
    journalctl -u "$SERVICE" -n 80 --no-pager || true
    exit 1
  fi

  if ! ss -tulpn 2>/dev/null | awk -v port="${PORT}" '{n=split($5,a,":"); if (a[n] == port) found=1} END {exit found ? 0 : 1}'; then
    err "Trojan service is active but port ${PORT}/tcp is not listening."
    systemctl status "$SERVICE" --no-pager || true
    journalctl -u "$SERVICE" -n 80 --no-pager || true
    exit 1
  fi

  log "Trojan service is active and listening on ${PORT}/tcp."
}

write_client_file() {
  local password="$1"
  local encoded_password encoded_name trojan_uri
  local subscription_uuid
  encoded_password="$(urlencode "$password")"
  encoded_name="$(urlencode "Trojan-${DOMAIN}")"
  trojan_uri="trojan://${encoded_password}@${DOMAIN}:${PORT}?peer=${DOMAIN}&sni=${DOMAIN}#${encoded_name}"
  subscription_uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)"
  export TROJAN_URI="${trojan_uri}"

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

  export SUBSCRIPTION_PROTOCOL="trojan"
  export SUBSCRIPTION_UUID="${subscription_uuid}"
  export SUBSCRIPTION_DIR="/sub/${subscription_uuid}"
  export SUBSCRIPTION_SERVER="${DOMAIN}"
  export SUBSCRIPTION_PASSWORD="${password}"
  export SUBSCRIPTION_CLIENT_NAME="Trojan"
  export SUBSCRIPTION_PORT="${PORT}"
  export SUBSCRIPTION_SNI="${DOMAIN}"
  installer_core_subscription_protocol_defaults
  installer_core_publish_subscription
  : "${SUBSCRIPTION_ACCESS_URL:=${TROJAN_URI:-}}"
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
  installer_core_print_completion_block "$(installer_core_mode_label)" "${SUBSCRIPTION_ACCESS_URL}" "Shadowrocket, v2rayNG, Clash, sing-box"

  print_client_qr "${SUBSCRIPTION_ACCESS_URL:-${trojan_uri:-}}" "/root/trojan-qr.png"
}

main() {
  require_root
  preflight_checks
  install_packages
  enable_network_tuning
  open_required_ports
  configure_tcp_mss_clamp
  check_dns
  install_trojan_binary
  write_nginx_http_site
  request_certificate

  local password
  password="$(generate_password)"
  write_config "$password"
  write_service
  start_trojan_service
  allow_ufw_ports
  write_client_file "$password"
  print_final_screen
}

main "$@"
