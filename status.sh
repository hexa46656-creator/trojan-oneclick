#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE="trojan-server.service"
CONFIG_FILE="/etc/trojan/config.json"
CLIENT_FILE="/root/trojan-client.txt"
PORT="${PORT:-443}"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "请使用 root 执行：bash status.sh" >&2
  exit 1
fi

printf '\033[1;34mTrojan 状态检查\033[0m\n'
systemctl status "$SERVICE" --no-pager || true

printf '\n\033[1;34m监听端口\033[0m\n'
ss -tulpn | grep -E "(:${PORT}\b|trojan)" || echo "未检测到 ${PORT} 端口监听"

printf '\n\033[1;34m客户端文件\033[0m\n'
if [[ -f "$CLIENT_FILE" ]]; then
  cat "$CLIENT_FILE"
else
  echo "未找到客户端文件：$CLIENT_FILE"
  echo "sudo cat /root/trojan-client.txt"
fi

printf '\n\033[1;34m配置文件\033[0m\n'
if [[ -f "$CONFIG_FILE" ]]; then
  ls -l "$CONFIG_FILE"
else
  echo "未找到配置文件：$CONFIG_FILE"
fi
