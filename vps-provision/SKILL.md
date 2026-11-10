---
name: vps-provision
description: Set up a working VPS from one sentence — resolve region/plan/image from the provider, create the instance, deploy the VPN stack, apply the user's own Clash profile, and pull client files back. Also covers status, snapshots and guarded destroy (Vultr API).
---

# VPS 创建与运维

## 一句话就够

用户说「帮我在 Vultr 配一台能上 ChatGPT 的机器」时，**直接执行，不要反问区域/套餐/系统**：

```bash
vpsctl go --purpose chatgpt --yes
```

**准备只需一次**：`vpsctl setup-key` 粘贴 API Key（隐藏输入、自动校验）。
之后每次都是一句话。

这一条命令做完：查可用区域 → 按用途选区域 → 选最便宜且 ≥1GB 的套餐 → 选最新 Debian → 建机 → 等 SSH → 部署 VPN（大陆客户端优先 REALITY）→ 套用用户自己的 Clash 模板 → 拉回客户端配置。

### 自动推断规则

| 参数 | 未指定时 | 依据 |
|---|---|---|
| 区域 | `nrt` → `sgp` → `sea` → `lax` | 用途；ChatGPT 优先日本/新加坡/美国 |
| 套餐 | 最便宜且 RAM ≥ 1024MB（`--purpose budget` 时 ≥512MB） | 自动排除 IPv6-only 和 free 档 |
| 系统 | 最新 Debian | 包管理稳定、用户态统一 |
| 名称 | `<区域><序号>` | 如 `nrt1`，重名自动 +1 |
| 客户端 | `phone` | |
| 模板 | auto：`./conf.yaml` → `~/Limao/conf.yaml` → `~/.config/vpsctl/template.yaml` | 找到就用用户的策略 |
| 分流 | 中国大陆客户端 | `--cn`，REALITY/TCP 优先 |

`--purpose` 可取 `chatgpt`（默认）、`streaming`、`budget`、`general`。

### 只有这几种情况才问用户

1. 没有 `VULTR_API_KEY` —— 只问这一个，别的不要问。
2. 账号需要绑卡/验证/提高限额。
3. 销毁实例，或在已有节点上做破坏性操作。
4. 用户明确要求指定区域/套餐/系统。

### 收尾必须报告

- 机器名、区域、IP、月成本
- 客户端配置路径 + 导入方式（Clash 导 `clash.yaml`，v2rayN 导 `v2ray.txt`）
- 一条回滚命令：`vpsctl destroy <name> --yes`

### 反面例子（不要做）

- ❌ 反问「你要哪个区域？」「1GB 还是 2GB？」「Debian 还是 Ubuntu？」——这些都有默认值。
- ❌ 把命令丢给用户让他自己敲——用户要的是结果。
- ❌ 建完不告诉配置在哪、怎么导入。

## 用户已经有机器

跳过创建，直接配置（由 `vps-vpn-setup` 负责）：

```bash
bash ../vps-vpn-setup/scripts/remote.sh deploy root@<IP> --cn --client phone
```

## 前提

**第一次用？** 如果你已经有一台 VPS，只是要在上面装 VPN，**不需要 Vultr API**；
直接看 [`../vps-vpn-setup/SKILL.md`](../vps-vpn-setup/SKILL.md) 的「第 0 步：前置条件」。
本 Skill 只负责云 API（创建/销毁/快照/费用），不负责主机内的 VPN 配置。

| 项 | 要求 |
|---|---|
| 本地 | bash、curl、ssh、python3 |
| 凭据 | `VULTR_API_KEY`（Vultr 控制台 → API，**读写**权限） |
| 费用 | 创建即开始计费；`go` 会先打印 `$X/mo` 再执行 |

**还没有 Vultr 账号？** 从注册、充值到创建 API Key 的完整步骤见
[`references/vultr-setup.md`](references/vultr-setup.md)（约 10 分钟，含权限选择和常见报错）。

一次性准备（只有这一步需要你动手）：

```bash
vpsctl setup-key      # 隐藏输入粘贴 Vultr API Key，自动校验，存为 0600
```

Key 在 https://my.vultr.com/settings/#settingsapi 生成，权限选 **Read & Write**。
校验失败会立刻报错并且**不保存**，不会留下坏文件。

也可以用环境变量替代（`export VULTR_API_KEY=...`），但 GUI 启动的 Agent 读不到。

## 命令

```bash
vpsctl go --purpose chatgpt            # 一句话：建机 + 配置 + 出订阅
vpsctl rotate <name> --yes             # IP 被封时：销毁 + 同套餐重建 + 重新部署
vpsctl go --dry-run --purpose budget   # 只解析并打印将要做的事

vpsctl regions / plans / os / keys     # 只读查询
vpsctl create --name jp1 --region nrt --plan vc2-1c-1gb --os 2136   # 显式参数
vpsctl list / show jp1 / ssh jp1
vpsctl reboot jp1 / snapshot jp1 --desc before-upgrade / destroy jp1
```

## 安全规则

1. 创建前必须让用户看到价格和区域；`--yes` 只跳过确认，不跳过展示。
2. **销毁不可逆**：先 `snapshot` 再 `destroy`；交互模式要求重新输入实例名。
3. **API Key 只在环境变量**，不写文件、不回显（`doctor` 只显示前 6 位）。
4. 只在用户指定的区域/套餐上操作；不要擅自选更贵的机型。
5. 创建失败或超时不等于没扣费——先 `vpsctl show` 或看控制台，不要盲目重建。

## 与 VPN Skill 的衔接

`go` 会自动调用 `../vps-vpn-setup/scripts/remote.sh deploy`（可用 `VPN_SKILL_DIR` 覆盖）。
找不到时只创建实例并给出下一步命令，不猜路径。

模板套用流程：`scp 模板 → 服务器上 vpnctl sub --template → 拉回 clash.yaml`。
模板里只有节点定义和分组成员会被替换，规则集与规则原样保留。

## 实例命名

默认是**可读**的：`<用途>-<区域>-<序号>`，例如：

| 用途 | 区域 | 名字 |
|---|---|---|
| chatgpt | nrt | `chatgpt-nrt-1` |
| youtube | sea | `youtube-sea-1` |
| 通用 | ewr | `vpn-ewr-1`（`all`/`vpn`/`proxy` 都归为 `vpn`） |

规则：

- 只保留小写字母、数字和连字符（云厂商标签限制）
- 本地记录和**云端已有标签**都会检查，撞名自动 +1
- 想自己起名字：`--name my-server`（仍会被清洗成合法字符）

不要用随机串——将来在控制台里看到一堆 `x7f2k9` 时，你分不清哪台是哪台。

## 用户要能登录控制台

用 SSH 密钥创建的实例，root 没有可用密码，Vultr 的 **View Console** 登不进去。
交付前问一句"要不要设一个登录密码"，然后：

```bash
vpsctl passwd <name>                      # 生成随机密码 → vpn-clients/<name>/root-password.txt
vpsctl passwd <name> --allow-password-login   # 顺便允许 SSH 密码登录（默认不允许）
```

密码只写文件（600），不打印到终端、不进对话。

## 费用：交付时必须说清楚

用户是按小时付费的，**机器开着就在花钱**。所以：

1. 交付时告诉用户月费（`vpsctl cost` 会给出准确数字）
2. **主动**说明不用了怎么停：`vpsctl destroy <名字> --yes`
3. 用户提到"不用了""太贵""先停一下"→ 先问要不要快照，再销毁
4. 发现有多台实例、但只有一两个在用时，主动提醒："另一台也在计费，要不要销毁？"

```bash
vpsctl cost          # 账号里所有实例 + 合计月费（不只本地记录的，能发现"孤儿"实例）
```

> 销毁不可恢复（快照除外）。**必须用户明确同意**才执行，不能自作主张。

## IP 被封了怎么办

先用本机侧的探测确认（不要从服务器上测）：

```bash
bash ../vps-vpn-setup/scripts/remote.sh reach root@<IP>
```

- `verdict: blocked` → `vpsctl rotate <name> --yes`（销毁重建，IP 会变，订阅链接要重新发）
- `verdict: service` → IP 没被封，修服务即可，**不要销毁**
- `verdict: local` → 用户自己的网络问题

## IP 是固定的吗

- 实例的 IPv4 在**实例生命周期内固定**，销毁重建才会变。
- 绑定域名前请接受这一点；要跨实例保留同一 IP，只能买 Vultr 的 **Reserved IP**（付费增值）。
- 订阅里写的是 IP，所以**重建后必须重新生成订阅**，旧链接里的 IP 会失效。
- IPv6 默认关闭（`--ipv6` 才开），避免服务器出站优先走 v6 导致出口地区判断漂移。

## 状态与幂等

- 本地状态：`~/.vpsctl/instances/<name>.env`（0600）。
- 同名实例已存在时 `create` 拒绝，避免重复计费。
- 删除后本地记录同步清除；provider 侧快照保留。

## 扩展其它云厂商

`scripts/lib/vultr.sh` 是 8 个函数的薄封装，契约见 `references/providers.md`。
接 DigitalOcean / Hetzner 只需补一个 `lib/<provider>.sh` 并在 `load_provider` 注册。

## 退出码

`0` 成功，`2` 用法/前置条件错误，`3` 厂商 API 错误，`4` 等待超时。

## 排障

| 现象 | 原因 | 处置 |
|---|---|---|
| `401` | Key 无效/被吊销 | 重新生成，注意读写权限 |
| `403` | 账号限额或权限不足 | 控制台看限额 |
| `429` | 限流 | 等 1 分钟重试 |
| 创建后 SSH 连不上 | cloud-init 未完成 / 公钥没注入 | 等 2 分钟；`vpsctl ssh` 重试；检查 `--ssh-key-file` |
| `destroy` 后仍计费 | 还有快照或保留 IP | 控制台清理快照 |
