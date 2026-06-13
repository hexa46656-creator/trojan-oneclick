#!/usr/bin/env bash
set -Eeuo pipefail

CLIENT_FILE="/root/trojan-client.txt"
SERVICE_NAME="trojan-go.service"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

info() { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }

main() {
  printf "${BOLD}${GREEN}============================================================${NC}\n"
  printf "${BOLD}${GREEN}Trojan 状态检查${NC}\n"
  printf "${BOLD}${GREEN}============================================================${NC}\n"

  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      info "服务状态：active"
    else
      warn "服务状态：inactive 或 failed"
    fi

    systemctl status "$SERVICE_NAME" --no-pager || true
  else
    warn "未找到 systemd 服务：$SERVICE_NAME"
  fi

  printf "\n"
  info "监听端口检查："
  ss -tulpn | grep -E 'trojan|trojan-go|:443' || warn "未检测到 Trojan 常见监听端口。"

  printf "\n"
  if [[ -f "$CLIENT_FILE" ]]; then
    printf "${BOLD}${CYAN}============================================================${NC}\n"
    printf "${BOLD}${CYAN}📌 Trojan 客户端导入信息${NC}\n"
    printf "${BOLD}${CYAN}============================================================${NC}\n"
    cat "$CLIENT_FILE"
    printf "\n"
  else
    warn "未找到客户端文件：$CLIENT_FILE"
  fi
}

main "$@"
