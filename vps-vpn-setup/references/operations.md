# 运维手册

部署只是开始。这一页覆盖「装上之后怎么长期用」。

## 日常检查

```bash
vpnctl verify <be> --json          # 服务/配置/端口/客户端数
vpnctl probe --json                # 端口、防火墙、公网 IP
wg show                            # WireGuard 实时握手与流量
systemctl is-enabled <service>     # 是否开机自启
```

建议每周一次，或写进 crontab：

```cron
0 4 * * 1 /usr/local/bin/vpnctl backup >/dev/null 2>&1
```

## 客户端生命周期

```bash
vpnctl client <be> list                       # 盘点
vpnctl client <be> add --name laptop --yes    # 新增
vpnctl client <be> export --name laptop       # 重新生成文件（丢了再取）
vpnctl client <be> remove --name old-phone    # 吊销，立即生效
```

策略建议：

- 一设备一条记录，命名带用途（`phone-alice`、`laptop-work`）。
- 成员离开 / 设备丢失：立即 `remove`，不要等定期轮换。
- 定期轮换：每 90 天对高价值账号 `remove` + `add`。
- 记录 `vpnctl client list` 的输出（不含密钥），便于审计。

## 备份与恢复

```bash
vpnctl backup
ls -lh /var/backups/vpnctl/
```

备份内容：`/etc/vpnctl`、`/etc/wireguard`、`/usr/local/etc/xray`、`/etc/hysteria`。**不含**二进制与系统包。

恢复（新机器）：

```bash
# 先装同款后端（会生成新密钥，稍后被覆盖）
vpnctl install wireguard --yes
tar xzf manual-YYYYMMDDTHHMMSSZ.tar.gz -C /
vpnctl install wireguard --yes        # 用恢复的密钥重新渲染
vpnctl verify wireguard --json
```

顺序很重要：先解包再重装，否则新生成的密钥会覆盖备份里的。

## 升级

```bash
vpnctl install xray-reality --yes        # 重新拉取最新 release，保留密钥与客户端
vpnctl install hysteria2 --yes
```

- 升级会重启服务，已连接会话短暂中断。
- 保留明文密码登录的机器，升级前先确认 SSH 还能进。
- 校验失败会中止，不会留下半装状态。

## 容量与性能

```bash
nstat -az | head
vnstat -l                            # 若已安装
ss -s                                # socket 总量
uptime; free -m; df -h
```

经验值（1 vCPU / 1 GB）：

| 后端 | 大致可承载 | 瓶颈 |
|---|---|---|
| WireGuard | 数百并发，千兆线速 | 带宽 |
| Xray REALITY | 数百并发 | 单核加解密 |
| Hysteria2 | 数十~数百 | 用户态 + 内存 |

调优方向：

- 打开 BBR（见 `security-hardening.md`）。
- `LimitNOFILE` 已设 1000000。
- 大量短连接时关注 `conntrack` 上限：`sysctl net.netfilter.nf_conntrack_max`。

## 监控（不依赖外部服务）

```bash
# 服务存活
systemctl is-active xray

# 端口存活
ss -lnt | grep -q ':443 ' && echo ok

# 证书到期（Hysteria2 自签 10 年，ACME 需关注）
openssl x509 -in /etc/hysteria/cert.pem -noout -enddate
```

需要告警时，把上面命令包进任意监控系统；本 Skill 不内置上报，避免引入外部依赖与隐私问题。

## IP 被封锁了怎么办

先判断是不是入口被封（**从你的设备测，不是从服务器上测**）：

```bash
nc -vz -w 5 <IP> 443      # 超时/拒绝，而服务器上服务正常 → 入口被封
# 换 Wi-Fi / 4G 对比：只有一种网络不通 → 运营商级封锁
```

| 手段 | 代价 | 适用 |
|---|---|---|
| 销毁重建 | 5–10 分钟，订阅要更新 | IP 被 GFW 拉黑，最快恢复 |
| Reserved IP 换绑 | 每月另收费 | 需要保住"地址身份" |
| 域名 + DNS | 一个域名 | 换 IP 只改 DNS，订阅链接不变 |
| **多节点订阅** | 多一台机器 | 最实用：封一个切另一个 |

重建并重新交付：

```bash
cd vps-provision
./scripts/vpsctl destroy <name> --yes
./scripts/vpsctl go --purpose budget --region ewr --plan vc2-1c-0.5gb --client phone --yes
```

> 注意：IP 变了，旧订阅里的 IP 就失效。要么重新发链接，要么改用域名。

## 多节点订阅（故障转移）

把另一台机器已生成的 profile 合进来：

```bash
vpnctl sub --name phone --template /root/profile.yaml \
  --extra-clash /root/other-machine-clash.yaml --serve
```

生成结果里两个节点都在同一个 `select` 分组，客户端里手动切换即可。
两个节点的机器和区域最好不同，避免同一机房被整体封禁。

## 降低被封的概率

- 用 REALITY（TCP/443 + 真实站点伪装），不要裸 WireGuard / 无 TLS 的 SS
- 不要让一个节点被大量设备或大流量下载共用
- 不要公开订阅链接（等于公开 IP 和使用特征）
- 多准备一个备用出口，被封时立刻切

## 多机部署

`vpnctl` 的密钥与客户端是**单机状态**，不要跨机复制：

- 每台机器独立 `install`，得到独立密钥。
- 客户端按机器分别添加，命名带机器前缀（`hk-phone`）。
- 需要统一管理时，分别 `remote.sh run` 到各机器，脚本层面循环。

## 迁移到新 VPS

1. 旧机 `vpnctl backup`，`scp` 备份到本地。
2. 新机装依赖 → 解包 → `install` 重渲染。
3. 域名/IP 变了：客户端 `Endpoint` 会变，必须重新导出；WireGuard 客户端配置里的 `Endpoint` 是写死的。
4. 验证后旧机 `vpnctl uninstall <be>`（确认 DNS/IP 已切换）。

## 下线

```bash
vpnctl backup
vpnctl uninstall wireguard --yes            # 保留状态
vpnctl uninstall wireguard --purge --yes    # 删除状态
```

卸载后检查：端口是否仍被其它进程占用、防火墙是否残留放行规则。

## 故障响应顺序

1. `vpnctl verify --json` + `journalctl`（5 分钟内能定位 80% 的问题）。
2. 回滚最近一次变更（重装 / 恢复备份）。
3. 网络层：安全组、路由、DNS。
4. 仍不行 → 换协议重装，保证可用性优先。

排障细节见 `troubleshooting.md`。
