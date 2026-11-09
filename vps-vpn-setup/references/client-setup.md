# 客户端配置详解

> 第一次使用、不知道装什么？先看 [`getting-started.md`](getting-started.md)（按 Windows / macOS / Linux / iOS / Android 分步写）。
> 本文件是各协议对应的客户端细节，适合已经装好客户端的人。

服务器端只负责生成文件；能否用起来取决于客户端是否导入正确。导出物固定放在 `~/vpn-clients/<backend>/<name>/`。

取回本地：

```bash
# 在笔记本上
bash scripts/remote.sh pull root@<VPS_IP> ./vpn-clients
```

## WireGuard

| 平台 | App | 导入 |
|---|---|---|
| iOS | WireGuard（官方） | 从文件导入 或 扫二维码 |
| Android | WireGuard（官方） | `+` → 扫描二维码 / 从文件导入 |
| macOS | WireGuard（App Store） | 导入 `.conf` |
| Windows | WireGuard for Windows | 导入隧道 |
| Linux | `wg-quick` | `cp x.conf /etc/wireguard/ && wg-quick up x` |

- `phone.conf` = 全隧道（`AllowedIPs = 0.0.0.0/0`）；`phone-split.conf` = 只走隧道网段（访问 VPS 内网/其它客户端）。
- DNS 由 `--dns` 决定（默认 `1.1.1.1, 8.8.8.8`）；要防 DNS 泄漏就用隧道内的解析器。
- 移动端省电：`PersistentKeepalive = 25` 会持续唤醒，流量敏感场景可调大或去掉。
- 二维码：`qrencode -t ansiutf8 < phone.conf`，或直接用导出的 `phone.png`。

## Xray VLESS + REALITY

| 平台 | 客户端 | 导入 |
|---|---|---|
| Windows | v2rayN | 从剪贴板导入 `vless://…` |
| Android | v2rayNG / NekoBox | 从剪贴板导入 |
| iOS | Shadowrocket（付费）/ Stash | 扫码或粘贴 URI |
| macOS | V2RayXS / sing-box / mihomo | 粘贴 URI 或 `outbound.json` |
| 路由器 | OpenWrt + sing-box | 用 `outbound.json` |

关键字段必须与服务器一致：`sni`、`pbk`（公钥）、`sid`（shortId）、`flow`（`xtls-rprx-vision`）、`fp`（指纹）。缺 `flow` 会握手失败；`pbk/sid` 错会超时。

`outbound.json` 是 sing-box/mihomo 可直接引用的 outbound 片段，比 URI 更不容易被客户端改写。

## Shadowsocks-2022

| 平台 | 客户端 | 备注 |
|---|---|---|
| iOS | Shadowrocket、Stash | 需支持 2022 方法 |
| Android | v2rayNG、NekoBox、sing-box | 同上 |
| Windows | v2rayN（内置 Xray 内核） | 同上 |
| 全平台 | sing-box CLI | `ss://` 或 JSON |

- 方法默认 `2022-blake3-aes-128-gcm`；客户端必须支持该 2022 系列，老客户端只认 aes-256-gcm 会连不上。
- 多用户模式下客户端密码形如 `用户PSK:服务器PSK`（`outbound.json` 已拼好）；手工填 URI 时不要漏掉冒号后半段。
- `ss://` 的 userinfo 是 base64url，部分客户端要求无 padding，`uri.txt` 已处理。

## Hysteria2

| 平台 | 客户端 | 备注 |
|---|---|---|
| Android | NekoBox、Karing、Hysteria 官方 | 支持 `hysteria2://` |
| iOS | Shadowrocket、Stash、Karing | 版本要新 |
| Windows | NekoRay、Karing、sing-box | |
| macOS | Karing、sing-box | |
| 全平台 CLI | `hysteria client -c client.yaml` | 自带 socks5/http 入口 |

- 自签证书场景必须 `insecure: true`（URI 里是 `insecure=1`），或按 `info.txt` 的 `sha256:` 做证书固定。**能上 ACME 就别用 insecure**。
- `client.yaml` 默认在本地开 `127.0.0.1:1080`(socks5) 和 `:8080`(http)，再把系统代理指过去。
- 开启 obfs 时，客户端必须填同样的 `obfs` 类型与密码，否则握手后立刻断开。
- QUIC 需要客户端网络允许 UDP；公司网络常封 UDP，此时改用 REALITY。

## Trojan

| 平台 | 客户端 | 备注 |
|---|---|---|
| Windows | v2rayN | 粘贴 `trojan://…` |
| Android | v2rayNG、NekoBox | 粘贴 URI |
| iOS | Shadowrocket、Stash | 扫码或粘贴 |
| 全平台 | Clash Verge / Mihomo | 用订阅里的 `trojan-<name>` 节点 |

- 用 ACME 或自备证书时**不要**关证书校验；只有 `--self-signed` 才需要 `allowInsecure=1`（`uri.txt` 已按证书来源写好）。
- 服务器名（SNI）必须是证书里的域名，用 IP 连会握手失败。
- 端口默认 8443 是为了和 REALITY 的 443 共存；如果 443 空着，`--port 443` 更自然。

## 订阅（推荐）

装了两个以上后端时，用一份订阅一次导入全部节点：

```bash
vpnctl sub --name phone
# -> ~/vpn-clients/_subscriptions/phone/clash.yaml
#    ~/vpn-clients/_subscriptions/phone/v2ray.txt   (base64)
#    ~/vpn-clients/_subscriptions/phone/uris.txt
```

| 客户端 | 导入哪个文件 | 怎么导 |
|---|---|---|
| Clash Verge / Mihomo | `clash.yaml` | 配置 → 导入 → 从文件 |
| v2rayN / v2rayNG | `v2ray.txt` | 订阅 → 从剪贴板/文件导入（base64） |
| Shadowrocket | `v2ray.txt` 或逐个 `uri.txt` | 扫码/粘贴/订阅 |
| sing-box | `uris.txt` 逐条 | 或自己转 JSON |

订阅文件是**凭据**：等同于账号密码。`600` 权限、不要发群、不要进 Git。想变成链接共享时，把它放在带认证的静态托管后面（或 Cloudflare Worker + KV），不要裸 `http.server`。

## 通用检查清单

1. 服务器侧 `vpnctl verify <be> --json` 为 `ok:true`。
2. 云安全组 + 本机防火墙都放行了对应端口与协议（TCP/UDP 别搞混）。
3. 客户端时间与服务器偏差 < 2 分钟（REALITY/TLS 对时间敏感）。
4. 导入后先测「能否打开一个纯 IP 网站」，再测域名（区分代理是否生效）。
5. 失败时先看客户端日志，再看服务器 `journalctl -u <service> -n 50`。

## 多设备建议

- 一设备一客户端名（`phone`、`laptop`、`pad`），吊销时互不影响。
- 不要把同一个 WireGuard 配置复制到多台设备：`AllowedIPs` 相同会互相顶掉握手。
- 定期 `vpnctl client <be> list` 清理不再使用的条目。
