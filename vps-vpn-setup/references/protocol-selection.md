# 协议选型

选型的唯一标准是「在当前网络环境下能连上且够快」，不是协议新旧。先测量，再决定。

## 1. 先确认三条网络事实

在 VPS 上执行（`vpnctl probe --json` 已覆盖大部分）：

```bash
# 出口 IP 与是否双栈
curl -4 -s https://api.ipify.org; echo
curl -6 -s https://api64.ipify.org; echo

# TCP/443 是否已被占用
ss -lntp | grep ':443 '

# UDP 是否可出网（WireGuard/Hysteria2 的前提）
nc -u -z -w3 1.1.1.1 53 && echo "udp ok" || echo "udp blocked"

# 线路质量（从客户端侧测更准）
ping -c 20 <VPS_IP>
```

再确认云厂商安全组：**安全组不开，本机防火墙开了也没用**。这是最高频的「装好了连不上」原因。

## 2. 决策矩阵

| 约束 / 场景 | 选择 | 说明 |
|---|---|---|
| UDP 可用，追求吞吐与延迟 | WireGuard | 内核态，无用户态转发开销 |
| UDP 可用但线路丢包 >1% | Hysteria2 | QUIC + Brutal/BBR，主动对抗丢包 |
| 只有 TCP 放行 | Xray VLESS+REALITY | 直接吃 TCP/443 |
| 需要伪装成正常网站流量 | Xray VLESS+REALITY | TLS1.3 指纹与真实站点一致，无需证书 |
| 客户端老旧、只认 SS | Shadowsocks-2022 | 2022 方法需较新客户端；老客户端用 aes-256-gcm（不推荐） |
| 容器（OpenVZ/LXC）无 TUN | Xray / Hysteria2 | WireGuard 需要内核模块 + TUN |
| 内存 ≤ 256 MB | WireGuard 或 Xray | Hysteria2 用户态缓冲吃内存 |
| 只想给几台设备互联 | Tailscale/Headscale | 不在本 Skill 自动化范围 |
| 有域名、需要标准 TLS 节点 | Trojan | 真证书（ACME/自备），客户端兼容面仅次于 SS |
| 需要网页管理面板、多用户计费 | 3x-ui / Marzban | 本项目不覆盖；面板自身的攻击面需自行加固 |

## 3. 横向对比

| 维度 | WireGuard | Xray REALITY | Shadowsocks-2022 | Hysteria2 | Trojan |
|---|---|---|---|---|---|
| 传输层 | UDP | TCP（可 WS/gRPC） | TCP/UDP | QUIC(UDP) | TCP+TLS |
| 抗封锁 | 弱（UDP 特征明显） | 强（伪装 TLS） | 中（流量特征弱但可识别） | 中（QUIC 特征） | 中（真 TLS，需域名） |
| 丢包适应 | 一般 | 依赖 TCP 重传 | 依赖 TCP 重传 | 强 | 依赖 TCP 重传 |
| 移动端耗电 | 低 | 中 | 中 | 中高 | 中 |
| 客户端覆盖 | 极广（系统级） | 广（需 Xray 系客户端） | 极广 | 中（需新版客户端） | 广 |
| 配置复杂度 | 低 | 中 | 低 | 中 | 中 |
| 需要域名/证书 | 否 | 否（REALITY） | 否 | 自签可，ACME 更佳 | 是（域名 + 证书） |
| 典型端口 | 51820/udp | 443/tcp | 8388/tcp+udp | 443/udp | 8443/tcp |

## 4. 组合策略

同时部署不冲突的后端，客户端按网络切换：

- `xray-reality`(443/tcp) + `hysteria2`(443/udp)：同一端口号不同传输层，UDP 好走 Hysteria2，UDP 差走 REALITY。**推荐组合**。
- 再加 `trojan`(8443/tcp)：有域名时多一条标准 TLS 通道，客户端兼容性兜底。
- `wireguard`(51820/udp) + `xray-reality`(443/tcp)：性能优先 + 备用通道。
- 四后端并存时注意 443/tcp 与 443/udp 分别被占用，`vpnctl probe` 的 `listening` 字段可核对。

```bash
# 一条命令装齐三个远端节点并生成订阅
vpnctl up --all --domain vpn.example.com --acme-email you@example.com --client phone --yes
# 等价的手动顺序
vpnctl install xray-reality --port 443 --yes
vpnctl install hysteria2 --port 443 --yes
vpnctl install trojan --domain vpn.example.com --port 8443 --yes
vpnctl harden --no-ssh
vpnctl sub --name phone
```

## 5. 反模式

- **在 UDP 被封的网络上装 WireGuard**，然后花几小时查「为什么没握手」。先测 UDP。
- **把 REALITY 的 `dest` 指向自己的域名**：dest 必须是一个真实、支持 TLS1.3+h2 的外部站点（默认 `www.microsoft.com:443`），指错会握手失败。
- **端口选 80/8080**：容易被中间设备做 HTTP 解析。REALITY 用 443。
- **Hysteria2 用 ACME 却没开 80**：证书签不下来。要么自签（客户端 insecure/pin），要么确保 80 可达。
- **多后端抢同一端口**：`install` 会检测并报错，不要用 `--port` 改动已有后端的端口后不重新导出客户端。

## 6. 选完之后的固定动作

```bash
vpnctl plan <backend>        # 复核端口/网段/SNI
vpnctl install <backend> --yes
vpnctl harden --no-ssh       # 放行端口
vpnctl client <backend> add --name phone --yes
vpnctl verify <backend> --json
```

验证通过前不要向用户宣称「已经能用」。握手类字段（`handshaked`）需要客户端实际连一次才会增长。
