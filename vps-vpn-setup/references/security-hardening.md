# 安全加固

一台公网 VPS 从上线那一刻就开始被扫描。目标不是「无法攻破」，而是「没有低成本突破口，且失陷后影响可控」。

## 威胁模型

| 威胁 | 现实程度 | 主要对策 |
|---|---|---|
| SSH 暴力破解 | 极高（每分钟都有） | 密钥登录、关密码、限速、换端口 |
| 协议指纹识别与主动探测 | 高（针对代理） | REALITY/Hysteria2 伪装，Obfs |
| 密钥/配置泄露 | 中 | 文件权限 0600、目录 0700、不进日志 |
| 端口扫描与服务暴露 | 高 | 默认拒绝、只开放必要端口 |
| 云控制台/账号被盗 | 低但致命 | 强口令 + MFA（本工具管不到） |
| 流量分析 | 中 | 传输层伪装，避免固定心跳特征 |

## SSH

`vpnctl harden` 会写入 `/etc/ssh/sshd_config.d/99-vpnctl.conf`：

```
PermitRootLogin prohibit-password
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
PasswordAuthentication no        # 仅当存在 authorized_keys 时写入
```

它**故意不做**的事，以及为什么：

- **不默认改端口**：改端口需要用户在断连风险下确认。要改走 `--ssh-port N`，带 5 分钟自动回滚。
- **不装 fail2ban**：不同发行版包名与服务名不一致，且与 `--lockdown` 叠加容易把自己关在门外。需要时手工装。
- **不禁用 root 登录**：很多 VPS 只给 root。改为 `prohibit-password`（只能密钥），兼顾可用与安全。

改端口的安全流程：

```bash
vpnctl harden --ssh-port 2222     # 先放行 2222，再改配置，再挂回滚定时器
# 新开一个终端验证
ssh -p 2222 root@<VPS_IP>
vpnctl harden --confirm           # 确认后取消回滚
```

5 分钟内不 confirm，定时器会自动删除 drop-in 并 reload sshd，恢复原端口。

## 防火墙

- 默认只放行：SSH 端口 + 已安装后端端口。
- `--lockdown` 才切换默认拒绝；它会先放行 SSH 再改策略，顺序不能反。
- 云厂商安全组是独立一层，必须同时配置。
- iptables 规则不持久化：重启会丢。用 `netfilter-persistent save`，或改用 ufw/firewalld。

## 内核与网络

```ini
# /etc/sysctl.d/99-vpnctl.conf（安装 WireGuard 时自动写入）
net.ipv4.ip_forward = 1
```

建议追加（不在工具默认范围内，按需）：

```ini
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.conf.all.rp_filter = 2      # 多网卡/策略路由场景
fs.file-max = 1000000
```

`rp_filter=2`（宽松）在部分云厂商多网卡环境下是必需的，否则回包被丢。

## 各后端的额外要点

**WireGuard**
- 服务器配置 0600，`/etc/vpnctl/wireguard/` 0700。
- 每个客户端独立 keypair + 独立 PSK；`AllowedIPs` 只给单个 /32，不要给整段。
- 客户端丢失 → `client remove` 立即从 `wg syncconf` 移除，旧配置马上失效。
- 明文 UDP，**不抗主动探测**。对审查敏感的网络不要把它当唯一通道。

**Xray REALITY**
- `dest` 选大厂的真实站点（默认 `www.microsoft.com:443`），且该站点支持 TLS1.3+h2。
- 服务以 `nobody` 运行，只有 `CAP_NET_BIND_SERVICE`/`CAP_NET_ADMIN`。
- 不要暴露 Xray 的 API/gRPC 管理口；本工具不启用 API。
- 日志级别 `warning`，不记录访问日志（避免留存用户访问目标）。
- `shortId` 每台服务器唯一；`privateKey` 绝不出现在 stdout。

**Shadowsocks-2022**
- 服务器 PSK 与每个客户端 PSK 分离（多用户模式），泄露单个用户不暴露他人。
- 2022 系列方法自带重放保护；不要退回 `aes-256-gcm`（无重放保护）。
- 明文协议 + 无 TLS，抗探测能力弱于 REALITY，适合做兼容备用。

**Hysteria2**
- 自签证书必须让客户端 `insecure` 或 pin sha256；**能上 ACME 就用真证书**（更隐蔽）。
- `masquerade` 指向真实站点，未认证请求会被反代过去，降低「空端口」特征。
- `obfs: salamander` 改变 QUIC 初始包特征，但会略增开销。
- `bandwidth` 设置过高会在共享线路上引发不公平抢占，按实际带宽的 80% 设。

## 密钥与文件权限

| 路径 | 期望权限 | 内容 |
|---|---|---|
| `/etc/vpnctl/` | `700` | 状态根 |
| `/etc/vpnctl/<be>/meta.env` | `600` | 端口、公钥、SNI 等 |
| `/etc/vpnctl/<be>/server.key` | `600` | 服务器私钥 / 服务器 PSK |
| `/etc/vpnctl/<be>/clients/*.env` | `600` | 客户端私钥/PSK/UUID |
| `/etc/wireguard/wg0.conf` | `600` | 含服务器私钥 |
| `/usr/local/etc/xray/<id>.json` | `644` | 含 REALITY 私钥（进程以 nobody 读） |
| `/etc/hysteria/key.pem` | `600` | TLS 私钥 |
| `~/vpn-clients/**` | 目录 `700`、文件 `600` | 交付给用户的配置 |

规则：

1. 任何私钥都不进 shell 历史（用文件，不用 `export`）。
2. 不把 `vpnctl` 的输出重定向到 world-readable 文件。
3. 交付用 `scp`/二维码，不在聊天里贴。
4. 吊销 = 删除客户端记录 + 重载服务；不要只删客户端文件。

## 日志与监控

```bash
journalctl -u xray-reality -n 100 --no-pager   # 或 ss2022
journalctl -u hysteria-server -n 100 --no-pager
wg show
```

- 关闭不必要的访问日志（隐私 + 磁盘）。
- 关注异常：短时间内大量握手失败、连接数突增、CPU 持续打满（可能被当跳板）。
- 建议设置 `logrotate` 或 `journalctl --vacuum-size=200M`。

## 合规

- 部署前确认当地法律与云厂商 AUP 允许该用途。
- 不用于攻击、扫描、发送垃圾邮件；出口 IP 的信誉会影响用户。
- 不记录、不转售用户流量数据。

## 加固检查清单

- [ ] `sshd -T | grep -E 'passwordauthentication|permitrootlogin'` 符合预期
- [ ] `vpnctl harden --status` 显示端口已放行、SSH 状态正确
- [ ] 云安全组只开放必要端口
- [ ] `ls -l /etc/vpnctl/*/server.key` 为 `600`
- [ ] `vpnctl verify <be> --json` 为 `ok:true`
- [ ] 已知回滚路径（`uninstall` / `harden --confirm` / 云控制台 VNC）
