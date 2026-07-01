# Trojan 一键部署脚本

## 1. 项目用途

用于在 Ubuntu LTS 上一键部署 Trojan 服务端，自动申请 Let's Encrypt 证书、生成随机密码、创建 systemd 服务，并把客户端导入信息保存到 `/root/trojan-client.txt`。

## 2. 默认端口

默认端口是 `443/tcp`。

## 3. 自定义端口示例

```bash
PORT=8444 DOMAIN=已经解析到你的IP的域名 EMAIL=您的邮箱 bash install.sh
```

## 4. 一键安装命令示例

```bash
DOMAIN=已经解析到你的IP的域名 EMAIL=您的邮箱 bash <(curl -fsSL https://raw.githubusercontent.com/hexa46656-creator/trojan-oneclick/main/install.sh)
```

请把 `已经解析到你的IP的域名` 替换为已经解析到当前 VPS IP 的真实域名。
请把 `您的邮箱` 替换为你的真实邮箱，用于申请 Let's Encrypt TLS 证书。

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
- iproute2

## 6. 域名与 Cloudflare 要求

Trojan 必须使用真实域名和证书。请把域名的 DNS 设置为 `DNS only`，不要开启 Cloudflare 橙色云朵代理，否则证书申请和直连都可能失败。

## 7. 端口要求

安装前和安装过程中，`80/tcp` 和 Trojan 端口（默认 `443/tcp`）必须放行。脚本会在申请证书前自动添加 UFW 规则，但不会重置 UFW，也不会修改 SSH。云服务器安全组也必须放行这些端口。

`PORT` 不能设置为 `80`，因为 `80/tcp` 需要留给 Nginx 和 Let's Encrypt HTTP 验证。

## 8. 架构要求

官方 `trojan-gfw/trojan` 当前只发布 `linux-amd64` 二进制。脚本会拒绝在 ARM64 上 fallback 安装 amd64 二进制，避免安装后服务无法启动。

## 9. 安装完成后的输出

安装成功后，终端最后一屏会显示彩色高亮的 `trojan://` 导入链接，方便直接复制到 Shadowrocket 或其他客户端。

## 10. Shadowrocket 手动填写

如果 Shadowrocket 无法导入，可手动填写：

- 类型：Trojan
- 地址：DOMAIN
- 端口：PORT
- 密码：原始密码
- TLS：开启
- SNI/Peer：DOMAIN
- Allow Insecure：关闭

## 11. 状态查看

```bash
bash status.sh
```

状态脚本会显示 Trojan 服务状态、监听端口，并直接展示 `/root/trojan-client.txt` 的内容。

## 12. 卸载命令

```bash
bash uninstall.sh
```

## 13. 常见故障排查

1. DNS 未生效：先检查 `dig +short DOMAIN` 是否返回当前 VPS 的公网 IPv4。
2. 公网 IP 不一致：先检查 `curl -4 ifconfig.me` 的结果。
3. 证书申请失败：查看 `/var/log/letsencrypt/letsencrypt.log`。
4. 服务启动失败：安装脚本会直接打印 `systemctl status trojan-server.service` 和 `journalctl -u trojan-server.service -n 80 --no-pager`。
5. 端口无法访问：确认云服务器安全组和本机防火墙已经放行 `80/tcp` 与 `443/tcp`。

## 中文说明

### 项目简介

本项目用于在 Ubuntu VPS 上一键部署 Trojan 服务端。脚本会自动申请证书、生成随机密码、创建 systemd 服务，并把客户端导入信息保存到本机。

### 支持系统

- Ubuntu LTS
- 需要可正常解析到当前 VPS IP 的真实域名

### 一键安装命令

```bash
sudo -i
apt update && apt install -y curl
DOMAIN=已经解析到你的IP的域名 EMAIL=您的邮箱 bash <(curl -fsSL https://raw.githubusercontent.com/hexa46656-creator/trojan-oneclick/main/install.sh)
```

### 默认端口

- 默认端口：`443/tcp`

### 默认 SNI

- Trojan 使用你填写的域名作为 `SNI/Peer`
- 不使用固定公共域名
- 如果你修改了 `DOMAIN`，客户端里的 `peer` 和 `sni` 也会随之变化

### 安装完成后的客户端链接

- 客户端信息保存到：`/root/trojan-client.txt`
- 安装完成后，终端会显示原始 `trojan://` 导入链接
- 同时也会输出订阅链接，方便支持订阅的客户端使用

### 二维码扫码导入

安装完成后，脚本会在终端显示二维码，并保存 PNG 文件。

- 二维码内容优先使用脚本最终生成的订阅链接
- 如果订阅链接不可用，会回退到原始 `trojan://` 链接
- PNG 文件保存路径：`/root/trojan-qr.png`

常用客户端：

- Shadowrocket
- v2rayNG
- Hiddify
- NekoBox
- Clash / Clash Verge

### 状态检查命令

```bash
bash status.sh
```

### 卸载命令

```bash
bash uninstall.sh
```

### 安全提示

- 请确保域名已经正确解析到当前 VPS
- 请确保 `80/tcp` 和 Trojan 端口（默认 `443/tcp`）在云安全组和本机防火墙中已放行
- 不要把客户端密码公开分享

### 故障排查

1. 先执行 `bash status.sh` 查看服务状态和日志
2. 确认 `dig +short DOMAIN` 的结果等于当前 VPS 公网 IP
3. 确认 `80/tcp` 和 `443/tcp` 已放行
4. 如果二维码无法显示，直接复制 `/root/trojan-client.txt` 中的原始链接手动导入
5. 如果证书申请失败，查看 `/var/log/letsencrypt/letsencrypt.log`
