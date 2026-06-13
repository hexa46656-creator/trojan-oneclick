# Trojan 一键部署脚本

## 1. 项目用途

用于在 Ubuntu LTS 上一键部署 Trojan 服务端，自动申请 Let's Encrypt 证书、生成随机密码、创建 systemd 服务，并把客户端导入信息保存到 `/root/trojan-client.txt`。

## 2. 默认端口

默认端口是 `443/tcp`。

## 3. 自定义端口示例

```bash
PORT=8444 DOMAIN=proxy.example.com EMAIL=admin@example.com bash install.sh
```

## 4. 一键安装命令示例

```bash
DOMAIN=proxy.example.com EMAIL=admin@example.com bash <(curl -fsSL https://raw.githubusercontent.com/hexa46656-creator/trojan-oneclick/main/install.sh)
```

## 5. 必要依赖

安装脚本会自动安装以下依赖：

- nginx
- certbot
- python3-certbot-nginx
- dnsutils
- curl
- unzip
- ca-certificates
- ufw
- xz-utils
- python3

## 6. 域名与 Cloudflare 要求

Trojan 必须使用真实域名和证书。请把域名的 DNS 设置为 `DNS only`，不要开启 Cloudflare 橙色云朵代理，否则证书申请和直连都可能失败。

## 7. 端口要求

安装完成后，`80/tcp` 和 `443/tcp` 必须放行。脚本会在检测到 UFW 已启用时自动放行这两个端口，但不会重置 UFW，也不会修改 SSH。

## 8. 安装完成后的输出

安装成功后，终端最后一屏会显示彩色高亮的 `trojan://` 导入链接，方便直接复制到 Shadowrocket 或其他客户端。

## 9. Shadowrocket 手动填写

如果 Shadowrocket 无法导入，可手动填写：

- 类型：Trojan
- 地址：DOMAIN
- 端口：PORT
- 密码：原始密码
- TLS：开启
- SNI/Peer：DOMAIN
- Allow Insecure：关闭

## 10. 状态查看

```bash
bash status.sh
```

状态脚本会显示 Trojan 服务状态、监听端口，并直接展示 `/root/trojan-client.txt` 的内容。

## 11. 卸载命令

```bash
bash uninstall.sh
```

## 12. 常见故障排查

1. DNS 未生效：先检查 `dig +short DOMAIN` 是否返回当前 VPS 的公网 IPv4。
2. 公网 IP 不一致：先检查 `curl -4 ifconfig.me` 的结果。
3. 证书申请失败：查看 `/var/log/letsencrypt/letsencrypt.log`。
4. 服务启动失败：查看 `journalctl -u trojan-go -n 100 --no-pager`。
5. 端口无法访问：确认云服务器安全组和本机防火墙已经放行 `80/tcp` 与 `443/tcp`。
