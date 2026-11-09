# 怎么实践与测试

按成本从低到高分四层。**前两层不需要 VPS**，第三层开始才碰真机器。

| 层 | 要什么 | 花多久 | 能证明什么 |
|---|---|---|---|
| L0 本机只读 | 一台装了 bash + python3 的电脑 | 1 分钟 | 脚本没语法/逻辑错，配置渲染正确 |
| L1 本机加载 | 已装 DSH / Claude Code / Codex 等 | 2 分钟 | Agent 能发现并读到这个 Skill |
| L2 VPS 自动验收 | 一台一次性 VPS（root） | 10 分钟 | 装得上、起得来、能重装、吊销生效 |
| L3 人工客户端验收 | 手机或电脑装好客户端 | 10 分钟 | 真的能上网、重启后还能连 |

> **在中国大陆的读者**：`check-sites` 要在 **VPS 上**跑。你在自己电脑上跑会看到一片红——那不是故障，是现状（它测的是「这台机器 → 目标网站」）。国内 VPS 会直接返回 `host_in_cn`，退出码 6。
>
> L2 全绿也不等于「能用」。同一台机器上测通只说明服务在跑；用户手机能不能连，取决于云安全组、运营商 UDP 策略、客户端时钟——这些只有 L3 能证明。

---

## L0：本机零成本自检（现在就能跑）

```bash
cd vps-vpn-setup

bash tests/smoke.sh          # 160 项断言，不碰真实系统
bash scripts/vpnctl doctor   # 工具自检
bash scripts/vpnctl plan wireguard      # 看它打算做什么
bash scripts/vpnctl plan xray-reality --help
bash scripts/vpnctl up --dry-run        # 一键部署的计划（不执行）
bash install.sh --target auto --dry-run # 会写哪些 Agent 路径
```

**期望**：`smoke: OK`；`plan` 打印步骤且 `--dry-run` 不创建 `/etc/vpnctl`。

想验证「渲染出来的配置对不对」，不用等 VPS：

```bash
# smoke 里第 5~8 节就是干这个的：构造状态 -> 渲染 -> 断言
bash tests/smoke.sh -v | sed -n '/5. wireguard/,/9. dry-run/p'
```

---

## L1：验证 Agent 真的能加载

```bash
bash install.sh --target auto          # 自动探测已安装的框架
bash install.sh --list                 # 看每个目标的安装状态
```

- DSH：新开一个会话，技能目录里应出现 `vps-vpn-setup`；输入 `/vps-vpn-setup` 能直接调用。
- Claude Code：`~/.claude/skills/vps-vpn-setup/SKILL.md` 存在；`/vpn` 命令可用。
- Codex / Cursor：`AGENTS.md` 里出现受管区块；向 Agent 说「装个 VPN」时它会先读 SKILL.md。

**判据**：Agent 开口第一句是「我先 probe 一下」而不是直接给你一段 WireGuard 配置。

---

## L2：一次性 VPS 自动验收

### 先准备一台「可销毁」的机器

任何按小时计费的云主机都行，**当天销毁**：

- Vultr / DigitalOcean / Lightsail：最低配，几美分/小时
- Oracle Cloud 永久免费额度：ARM 或 x86 小机型
- 本地虚拟化也行（UTM / Lima / Multipass 装 Debian 12）

要求：Debian/Ubuntu/RHEL 系任一、root 或免密 sudo、能出网。**不要用已经在跑业务的机器。**

### 从笔记本一条命令跑完

```bash
cd vps-vpn-setup
bash scripts/remote.sh push root@<测试机IP>          # 上传并安装到 /usr/local
bash scripts/remote.sh test root@<测试机IP>          # 跑完整生命周期验收
```

`remote.sh test` 会自动：装一个后端 → verify → 开防火墙 → 建客户端 → 重装（验证密钥不变）→ 吊销（验证凭据从配置消失）→ 重启服务 → 卸载 → 清状态。

也可以登上去手动跑，选后端和域名：

```bash
sudo bash tests/acceptance.sh --backend xray-reality --yes
sudo bash tests/acceptance.sh --backend trojan --domain vpn.example.com --yes
sudo bash tests/acceptance.sh --backend wireguard --yes --keep   # 保留，留着手工验客户端
```

**期望输出**：

```
acceptance: 14 passed, 0 failed  (backend: xray-reality)

This host is proven to install, verify, survive re-install and revoke.
Still needs a human: import the client config on a device and browse.
```

有 FAIL 时脚本会打印取证命令（`probe` / `verify` / `journalctl`），照着贴给我或查 `references/troubleshooting.md`。

### 手动版本（想自己一步步来）

```bash
bash scripts/remote.sh run root@<IP> probe --json      # 只读盘点
bash scripts/remote.sh run root@<IP> plan xray-reality # 只读计划
bash scripts/remote.sh run root@<IP> install xray-reality --yes
bash scripts/remote.sh run root@<IP> harden --no-ssh
bash scripts/remote.sh run root@<IP> client xray-reality add --name phone --yes
bash scripts/remote.sh run root@<IP> verify xray-reality --json
bash scripts/remote.sh pull root@<IP> ./vpn-clients    # 取回配置
```

---

## L3：人工客户端验收（唯一能证明「能用」的一步）

1. 用 `remote.sh pull` 把 `~/vpn-clients/...` 取回本地。
2. 在**手机**上装对应客户端并导入：
   - WireGuard → 扫 `phone.png`
   - REALITY / SS / Trojan → 粘贴 `uri.txt`
   - 多节点 → 导入 `_subscriptions/phone/clash.yaml`
3. 关掉 Wi-Fi，用 4G/5G 测一次（这是真实场景，UDP 策略不同）。
4. 打开 `https://ipinfo.io`，确认出口 IP = 你的 VPS。
5. 断开重连两次，确认不卡死。
6. **重启 VPS**（`reboot`），等 1 分钟，确认还能连——这一步验证服务自启和密钥持久化。

**判据**：出口 IP 正确 + 重启后仍可用 + 至少一台设备走蜂窝网络可用。

---

## 破坏性 / 安全性测试（在一次性 VPS 上做）

这些是「我宣称安全，你敢不敢验」的部分：

| 测什么 | 怎么测 | 期望 |
|---|---|---|
| 改 SSH 端口能回滚 | `vpnctl harden --ssh-port 2222`，**不**执行 `--confirm`，等 5 分钟 | sshd 自动回到原端口，没锁死 |
| 无密钥不关密码 | 在没 `authorized_keys` 的机器上 `vpnctl harden` | 拒绝关密码，提示先加 key |
| 吊销立即生效 | `client add --name t` → 用 t 连上 → `client remove --name t` | t 的配置立刻失效 |
| 重装不换密钥 | 记下 `vpnctl verify` 前的 PUBKEY，重跑 `install` | 公钥不变，老客户端仍可用 |
| 幂等 | 连跑三次 `install` | 无报错、无重复配置块 |
| 卸载干净 | `uninstall --purge` | 服务停、端口释放、`/etc/vpnctl/<be>` 消失 |

## 故障注入（验证排障路径真的有效）

```bash
# 1) 端口没放行会不会被以为是“服务挂了”
vpnctl harden --status

# 2) 证书过期/不匹配时 verify 能不能发现
openssl x509 -in /etc/vpnctl/trojan/tls/cert.pem -noout -enddate

# 3) 服务被停掉后 verify 是否立刻变红
systemctl stop xray-reality && vpnctl verify xray-reality --json

# 4) 客户端配置里的 Endpoint 故意写错，看客户端报什么
```

## 成本与收尾

- 一台按小时的测试机跑完 L2+L3 通常 **< 1 小时**，成本几美分到几元。
- 测完立刻销毁实例；不要留着「反正也没在用」的机器——它会被扫。
- 如果保留，至少 `vpnctl uninstall <be> --purge` + 关掉安全组。

## 常见「测试通过但实际不能用」

| 盲区 | 为什么 | 怎么补 |
|---|---|---|
| 在 VPS 上 `curl localhost` 测通 | 只证明进程在跑 | 必须从**外部**网络测 |
| 只测 TCP，没测 UDP | WireGuard/Hysteria2 走 UDP | 用手机流量测一次 |
| 忘开云安全组 | 本机防火墙放行 ≠ 云上放行 | 控制台核对；`probe` 的 `listening` 只反映本机 |
| 客户端时间偏差 | REALITY/TLS 对时间敏感 | 设备开启自动时间 |
| 通道通了但 ChatGPT 打不开 | OpenAI 按出口 IP 的地区/机房信誉封 | `vpnctl check-sites`；被封只能换 IP，改配置无效 |
| 同一份 WireGuard 配置装两台设备 | `AllowedIPs` 冲突互相顶掉 | 一设备一条客户端记录 |

## 一页速查

```bash
# 本机（无需 VPS）
bash tests/smoke.sh
bash scripts/vpnctl doctor
bash scripts/vpnctl up --dry-run

# VPS（一次性机器）
bash scripts/remote.sh push root@IP
bash scripts/remote.sh test root@IP
bash scripts/remote.sh run  root@IP probe --json

# VPS 上手工
sudo bash tests/acceptance.sh --backend wireguard --yes
sudo bash tests/acceptance.sh --backend trojan --domain vpn.example.com --yes --keep
```
