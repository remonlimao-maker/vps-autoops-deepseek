# 排障手册

排障顺序固定：**服务状态 → 端口监听 → 主机防火墙 → 云安全组 → 客户端配置 → 线路**。不要跳步猜。

```bash
vpnctl verify <backend> --json     # 服务/配置/端口
vpnctl probe --json                # 端口占用、防火墙类型、公网 IP
vpnctl harden --status             # 实际放行情况
journalctl -u <service> -n 50 --no-pager
```

## 快速索引

| 症状 | 最可能原因 | 处置 |
|---|---|---|
| `verify` 通过但客户端连不上 | 云安全组未放行 / 协议端口搞错 | 控制台放行；核对 TCP vs UDP |
| WireGuard `handshaked=0` | UDP 被封、端口不对、公钥不匹配 | 换 TCP 后端或换端口；重导配置 |
| REALITY 超时 | `pbk/sid/sni` 不一致、`dest` 不可用 | 重新导出 `uri.txt`，核对 dest |
| REALITY 握手后立即断开 | `flow` 不匹配、客户端时间偏差大 | 客户端开 Vision；校准时间 |
| Hysteria2 连上没流量 | obfs 密码不一致、masquerade 干扰 | `--no-obfs` 复测；核对客户端 |
| 隧道通但上不了网 | 未开 IP 转发 / NAT 未生效 | `sysctl net.ipv4.ip_forward`；`vpnctl install` 重跑 |
| 小包通、大包卡死 | MTU 过大 | `--mtu 1280` 重装或客户端改 MTU |
| 装完重启后失效 | 未 enable 服务 / 规则未持久化 | `systemctl is-enabled`；iptables 需持久化 |
| YouTube/GitHub 正常，ChatGPT 打不开 | OpenAI 按出口 IP 的地区/机房信誉封禁 | `vpnctl check-sites`；被封只能换 IP，改配置无效 |
| 在自己电脑上跑 `check-sites` 全红 | 它测的是本机出口，你在中国大陆 | 改到 VPS 上跑；本机全红是正常现象 |
| `host_in_cn` / 退出码 6 | VPS 本身在国内 | 换境外机器，配置无解 |
| 下载失败 | github.com 不可达 | `--mirror <代理基址>` |
| `443 already in use` | nginx/caddy 占端口 | 换端口或让 nginx 反代（不推荐混跑） |

## 1. 服务起不来

```bash
systemctl status xray-reality --no-pager -l      # ss2022 时换成 ss2022
journalctl -u xray-reality -n 80 --no-pager
/usr/local/bin/xray run -test -config /usr/local/etc/xray/xray-reality.json
```

- `xray -test` 报错 → 配置被手改坏了。重跑 `vpnctl install xray-reality --yes` 重新渲染。
- `xray-reality` 与 `ss2022` 是两个独立 unit、两份配置（`/usr/local/etc/xray/<id>.json`），可同时运行；排查时确认看的是对应那个。
- `bind: permission denied` → 端口 <1024 且未给 capability。unit 已含 `CAP_NET_BIND_SERVICE`；若被覆盖，重装。
- Hysteria2：`journalctl -u hysteria-server`。证书路径错、私钥权限不对（应 600）都会启动失败。

## 2. 端口没在监听

```bash
ss -lntup | grep -E ':(443|51820|8388)\b'
```

- 端口被别的进程占用：`vpnctl probe --json` 的 `listening` 字段能看出来。换端口后必须重新导出客户端。
- UDP 服务在 `ss -lnu` 里可能延迟出现，Hysteria2 启动后等 2–3 秒。

## 3. 防火墙与安全组

```bash
ufw status numbered            # 或 firewall-cmd --list-all
iptables -w -S INPUT | head
```

- **本机放行 ≠ 云上放行**。AWS/阿里云/腾讯云/Oracle 的安全组是独立一层，必须单独开。
- Oracle Cloud 还有默认的 iptables REJECT 规则，`vpnctl harden` 会插到最前面；重启后若丢失，需要 `netfilter-persistent save`。
- `--lockdown` 之后连不上：用云控制台 VNC 进入，`vpnctl harden --no-ssh` 或清空 ufw 规则。

## 4. WireGuard

```bash
wg show                      # 有没有 peer、latest handshake
wg show wg0 transfer
```

- `latest handshake` 一直是 0：客户端根本没打到服务器。查端口、安全组、客户端 Endpoint 是否写的是公网 IP。
- 有握手但没流量：`sysctl net.ipv4.ip_forward` 必须为 1；`iptables -t nat -L POSTROUTING -n` 应有 MASQUERADE。
- 加了 peer 但服务端没生效：`vpnctl client ... add` 会 `wg syncconf`；若失败看 `journalctl -u wg-quick@wg0`。
- 客户端显示「已连接」但 DNS 不解析：`--dns` 指向的解析器不可达，改成 `1.1.1.1` 或 VPS 本地 `systemd-resolved`。

## 5. Xray REALITY

- 客户端报 `REALITY: processed invalid connection` 或直接 timeout：`pbk`（公钥）或 `sid` 错，重新粘贴 `uri.txt`。
- `dest` 必须支持 TLS1.3 + HTTP/2 且不是自己的域名：
  ```bash
  openssl s_client -connect www.microsoft.com:443 -tls1_3 -alpn h2 </dev/null 2>/dev/null | head -5
  ```
- `flow` 不匹配：客户端必须开 `xtls-rprx-vision`，服务器 `--flow ""` 时客户端也要关。
- 时间偏差 >2 分钟会导致 TLS 失败：`timedatectl set-ntp true`。
- 用 CDN 中转 REALITY 无效（REALITY 需要直连 443），要 CDN 就用 WS+TLS 方案。
- 连接数暴涨：`ss -s`、`journalctl -u xray-reality | grep -c accepted`，必要时 `--lockdown` 只放行必要端口。

## 6. Hysteria2

- 客户端 `QUIC handshake failed`：UDP 被中间设备阻断。换 TCP 后端。
- `auth failed`：`userpass` 用户名或密码错。`vpnctl client hysteria2 export --name X` 重新取。
- obfs 不一致：客户端与服务器 `obfs` 类型/密码必须完全相同；排查时先 `--no-obfs` 重装。
- 自签证书报错：客户端置 `insecure: true`，或用 `info.txt` 里的 `sha256:` 固定。
- 速度上不去：检查 `bandwidth` 设置与宿主带宽；Brutal 拥塞控制会按设定值抢占，设太大反而伤线路。

## 7. MTU / 大包

现象：网页能打开但图片/视频卡住，`ping -M do -s 1400 <VPS_IP>` 失败。

```bash
# 服务器侧与客户端侧都试
ping -c 3 -M do -s 1372 <VPS_IP>
```

WireGuard 默认 1420，PPPoE/双栈环境常需 1280。重装时 `--mtu 1280`，客户端配置同步改。

## 8. 安装/依赖问题

| 现象 | 处置 |
|---|---|
| `apt-get` 锁冲突 | 等 unattended-upgrades 结束：`while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done` |
| 磁盘满 | `df -h`；`journalctl --vacuum-size=100M` |
| `modprobe wireguard` 失败 | 升级内核或安装 `wireguard-dkms` + headers；容器内改用 TCP 后端 |
| 无 systemd（容器/LXC） | 本工具的服务管理依赖 systemd；改用真实 VPS 或手工 `wg-quick up` |
| GitHub 超时 | `--mirror https://<代理>/`（代理基址指向 github.com 即可） |

## 8.5 通道正常但 ChatGPT 用不了

现象：YouTube、GitHub 都能开，ChatGPT 提示「not available in your country」、「Access denied」，或登录后转圈/反复跳验证。

先跑结论明确的诊断：

```bash
vpnctl check-sites
```

| 输出 | 含义 | 该做什么 |
|---|---|---|
| `chatgpt ok` | 网络层没问题 | 若客户端仍失败，查 DNS 泄漏与客户端规则（见下） |
| `chatgpt blocked-region` | **IP 地区不被支持** | 换区域重建（US/JP/SG 通常可用）；改协议、换端口都无用 |
| `chatgpt blocked` (403) | IP 被标记 | 换 IP；很多云厂商的廉价段被反复标记 |
| `chatgpt unreachable` | 出网或 DNS 有问题 | 先修网络，见第 1–3 节 |

**关键认知**：ChatGPT 的封锁是**出口 IP 的属性**，不是隧道的属性。同一个客户端，换个 VPS 就能上，说明是 IP 问题。

如果 `check-sites` 是 `ok` 但客户端仍然不行，按顺序查：

1. **DNS 泄漏** —— 客户端没导入我们的完整配置，DNS 走本地解析器，OpenAI 看到的是你本地 IP 的地区。
   → 导入 `clash.yaml` 全文（含 `dns` 块），或用 `uri.txt` 但确保客户端 DNS 走隧道。
2. **客户端规则把 OpenAI 放直连了** —— 很多订阅默认「国外直连」或按延迟分流。
   → 订阅里已固定 `openai.com`/`chatgpt.com` 走代理；如果你换了别人的规则集，把这几条加回去。
3. **IPv6 泄漏** —— 隧道只代理了 IPv4，浏览器优先走 IPv6。
   → 客户端关 IPv6；订阅里已写 `ipv6: false`。
4. **账号/地区设置** —— 账号注册地与当前 IP 长期冲突会触发额外验证。这是账号侧问题，不是节点问题。

**不要做的事**：不要为了「解锁 ChatGPT」去装来源不明的脚本或公共解锁代理——那是在把你的登录态交给陌生人。

## 9. 彻底重置

```bash
vpnctl backup
vpnctl uninstall <backend> --purge
vpnctl install <backend> --yes
```

重置后必须重新导出所有客户端；旧配置全部失效。这是排查「玄学问题」最快的一步，但要先确认用户能接受重新分发配置。

## 10. 需要收集的信息

上报问题或交给更强的模型时，提供：

```bash
vpnctl probe --json
vpnctl verify <backend> --json
vpnctl harden --status
journalctl -u <service> -n 100 --no-pager
```

**不要**附带私钥、客户端 UUID、密码。`probe` 与 `verify` 的输出不含密钥。
