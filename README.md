# Trojan 一键部署脚本

## 1. Trojan 为什么需要域名和证书

Trojan 的设计目标是让流量看起来像正常的 HTTPS 流量，因此它通常运行在 `443/tcp` 上，并依赖真实域名和受信任的 TLS 证书。这样客户端和服务端之间可以完成标准 TLS 握手，也更接近真实网站访问行为。

## 2. Cloudflare DNS only 设置步骤

如果你使用 Cloudflare 管理域名，请把 A 记录设置为 `DNS only`，不要开启橙色云代理。原因是 Trojan 需要直接连接到你的 VPS 真实公网 IP，Cloudflare 代理会干扰证书申请和直连握手。

操作步骤：

1. 登录 Cloudflare 控制台。
2. 进入域名的 DNS 页面。
3. 添加或修改 A 记录。
4. 将代理状态设置为灰色云朵，也就是 `DNS only`。
5. 保存后等待解析生效。

## 3. 如何添加 A 记录

新增一条 A 记录，示例：

- Name: `proxy`
- Type: `A`
- Content: 你的 VPS 公网 IPv4
- TTL: Auto
- Proxy Status: DNS only

最终域名示例就是 `proxy.example.com`。

## 4. 如何检查 dig +short DOMAIN

在本机或服务器上执行：

```bash
dig +short proxy.example.com
```

如果输出的 IP 与你的 VPS 公网 IPv4 一致，说明 DNS 已正确指向当前服务器。

## 5. 如何检查 curl -4 ifconfig.me

在 VPS 上执行：

```bash
curl -4 ifconfig.me
```

这个命令会显示当前服务器的公网 IPv4。安装脚本会用它来校验域名解析是否正确。

## 6. 一键安装命令

```bash
DOMAIN=proxy.example.com EMAIL=admin@example.com bash install.sh
```

## 7. 查看状态命令

```bash
bash status.sh
```

## 8. 卸载命令

```bash
bash uninstall.sh
```

## 9. 客户端配置说明

安装完成后，客户端信息会保存到：

```bash
/root/trojan-client.txt
```

该文件包含域名、端口、密码和客户端连接要点。Trojan 使用真实域名和 Let's Encrypt 证书，因此客户端正常情况下不需要 `insecure`。

## 10. 常见故障排查

1. DNS 校验失败：确认 `dig +short DOMAIN` 返回的是当前 VPS 的公网 IPv4。
2. 证书申请失败：确认 `80/tcp` 可达，Cloudflare 必须使用 `DNS only`。
3. 服务未启动：执行 `bash status.sh` 查看 systemd 状态和日志。
4. 端口被拦截：检查云厂商安全组和本机 UFW，确认 `443/tcp` 已放行。
5. 域名不对：确认 `DOMAIN` 和 `EMAIL` 都已正确传入安装命令。
