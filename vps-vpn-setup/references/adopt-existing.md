# 接管一台「已经建好」的机器

最常见的情况不是从零开始，而是：机器开好了、甚至 VPN 已经手装过了，只是没有订阅、没有统一管理。

这个流程**不重装、不覆盖**，只把现状读进来。

## 0. 先看，不动

```bash
bash scripts/remote.sh connect root@<IP>     # SSH/sudo/系统/内存/TUN 体检
vpnctl probe --json                          # 端口、防火墙、已装后端、以及「非本工具安装的服务」
```

`probe` 的 `foreign` 字段就是为这个场景加的：

```json
"foreign": {
  "binaries": "hysteria",
  "units": "hysteria-server.service",
  "config_dirs": "/etc/hysteria",
  "note": "found services vpnctl does not manage; run: vpnctl import hysteria2"
}
```

看到 `foreign` 非空就**不要直接 install**，否则会在一个正在跑的节点旁边再起一套，抢端口。

## 1. 把它纳入管理

```bash
vpnctl import hysteria2 phone      # 读 /etc/hysteria/config.yaml，登记为 node "phone"
```

它只做三件事：

| 做 | 不做 |
|---|---|
| 读端口、auth 类型、口令、证书路径、obfs | 不改 `config.yaml` |
| 写 `/etc/vpnctl/hysteria2/` 状态 | 不重启 hysteria |
| 建一个 client 记录 | 不重写任何证书 |

**验证没被动过**：

```bash
systemctl show hysteria-server -p ActiveEnterTimestamp --value   # 导入前后时间戳应一致
```

支持两种 auth：

| `auth.type` | 行为 |
|---|---|
| `password` | 建一个 client，URI 形如 `hysteria2://<password>@host:443` |
| `userpass` | 每个用户建一个 client，URI 形如 `hysteria2://user:pass@host:443` |

证书处理：读到 SAN 就用它当 SNI；自签（issuer == subject）自动标 `insecure=1`，真证书标 `0`。

## 2. 出订阅（套用自己的规则）

```bash
scp ~/conf.yaml root@<IP>:/root/.vpnctl-profile.yaml
vpnctl sub --name phone --template /root/.vpnctl-profile.yaml
```

模板里只有 `proxies:` 和分组成员会被替换，`rule-providers`、`rules`、分组名一字不动。

⚠️ **检查你的规则是否真的把国内应用直连**。靠 `GEOIP,CN` / `GEOSITE,CN` 判断的写法，在客户端没有 geodata 时会落到最后的 `MATCH` → 走代理。稳妥做法是在 `rules:` 最前面写死：

```yaml
- DOMAIN-SUFFIX,deepseek.com,DIRECT
- DOMAIN-SUFFIX,volcengine.com,DIRECT
- DOMAIN-SUFFIX,feishu.cn,DIRECT
```

## 3. 出链接（可选）

```bash
vpnctl sub --name phone --template /root/.vpnctl-profile.yaml --serve
# http://<IP>:<PORT>/<token>/clash.yaml
```

- **token 和端口会复用**，所以重新生成订阅时链接不变，客户端只需「更新订阅」。
- 想换链接：`vpnctl sub --serve --rotate-token`（旧链接立即失效）。
- 关闭：`vpnctl sub --unserve`。
- 它会自动在 ufw 放行该端口；如果你的云厂商还有安全组，需要单独开。

## 4. 验收

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://<IP>:<PORT>/<token>/clash.yaml   # 200
curl -s -o /dev/null -w '%{http_code}\n' http://<IP>:<PORT>/wrong/clash.yaml     # 404
vpnctl client hysteria2 list
systemctl is-active hysteria-server vpnctl-sub
```

## 安全保证（为什么不会把你的节点搞坏）

1. **导入的服务永不重写**：`be_client_add` / `be_client_remove` 对导入节点直接拒绝，并提示「改配置文件后重新 import」。
2. **`sub` 只读状态**：生成订阅不会碰任何服务进程。
3. **`--serve` 是新增的独立 unit**（`vpnctl-sub.service`），与你的节点隔离。
4. **可逆**：`sub --unserve` 关订阅；`rm -rf /usr/local/{bin,lib}/vpnctl /etc/vpnctl` 连工具一起撤。

## 常见坑

| 现象 | 原因 | 处理 |
|---|---|---|
| 导入后 URI 里口令多了一段 `user:` | 服务是 `password` 模式却按 `userpass` 拼 | 本工具按 `auth.type` 自动区分；手写订阅时注意 |
| 客户端报证书错误 | 自签证书但没设 `insecure` | `import` 会自动标；手写时加 `insecure=1` |
| 重出订阅后链接失效 | 旧版本每次换 token | 已改为复用；需要换用 `--rotate-token` |
| 订阅端口连不上 | ufw 没放行 / 云安全组没开 | `vpnctl harden` 放行本机；安全组在控制台开 |
| 512MB 机器装第二个协议就 OOM | 内存不足 | 先 `probe` 看可用内存；或用 `--no-swap` 之外的默认（会自动加 512MB swap） |
| 日志里反复 `no recent network activity` | UDP 被限速/丢包 | 加一条 TCP 通道（REALITY 443/tcp）作为备用 |

## 什么时候该重建而不是接管

- 配置文件被改得面目全非，已无人能解释每个字段
- 版本落后两个大版本以上，且配置格式已变
- 机器上还跑着其它业务，端口和防火墙互相牵制

重建也能保留现有节点：新装到一个不冲突的端口，验证通过后再切换订阅，最后再下线旧的。
