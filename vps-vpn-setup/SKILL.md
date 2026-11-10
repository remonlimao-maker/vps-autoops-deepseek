---
name: vps-vpn-setup
description: Provision, harden and operate a VPN on a Linux VPS over SSH — WireGuard, Xray VLESS+REALITY, Shadowsocks-2022, Hysteria2 and Trojan (domain + ACME) — delivering per-client configs plus one Clash/base64 subscription, with idempotent scripts, firewall lockout safeguards and adapters for DSH, Claude Code, Codex, Cursor, Gemini, Copilot and chat-only LLMs.
---

# VPS VPN 自动化部署

把一台 Linux VPS 变成可用的 VPN / 代理服务器，并产出客户端配置。适用于任何能执行 shell 的 Agent（DSH、Claude Code、Codex、Cursor、Gemini CLI、Copilot），也适用于纯聊天模型（见 `references/agent-adapters.md`）。

<skill_dir> = 本 SKILL.md 所在目录。工具入口：`bash <skill_dir>/scripts/vpnctl`。

## 适用范围

- **VPS 必须在境外**（如果要访问被封锁的站点）：国内 VPS 自己都上不了 YouTube/GitHub，当出口没有意义；用国内主机做这件事也违反云厂商条款与当地法规。本 Skill 会检测并在 `check-sites` 里直接拒绝。
- 支持：Debian/Ubuntu、RHEL/Rocky/Alma/Fedora、Arch、openSUSE、Alpine（systemd 或 OpenRC）。
- 需要：root 或免密 sudo、能出网（下载二进制）、`/dev/net/tun`（WireGuard 需要）。
- 不做：Windows/macOS 服务端、商业机场面板代购、绕过当地法律。默认拒绝把密钥写进聊天记录或日志。

## 第 0 步：前置条件（第一次用先看这里）

> **完全新手**：先读 [`references/first-run.md`](references/first-run.md)。
> 里面按顺序写了“要准备什么、AI 会问什么、注册/充值/建 Key 怎么做、每一步花多久”。

启动后**不要先选协议，也不要先跑 autopilot**。按这个顺序和用户对话：

1. 问：「你现在有可用的 VPS 吗？」
2. 有 → 要 IP / SSH 端口 / 用户 / 私钥或密码，先 `remote.sh connect` 验证，再进第一步。
3. 没有 → 问：「有 Vultr 账号吗？」
   - 有账号、没 Key → 发建 Key 步骤，让用户 `vpsctl setup-key`，`vpsctl doctor` 通过后继续。
   - **连账号都没有** → 发「注册 → 充值 → 建 Key」步骤（约 10 分钟），然后**停下等待**。
     用户回「好了」或 `vpsctl doctor` 通过之前，不要跑 `vpsctl go` / `autopilot.sh`，也不要假装已建机。
4. 只有前置条件齐了，才进入「第一步：选协议」。

先判断「有没有一台能 SSH 的 VPS」，这决定要不要 Vultr API：

| 场景 | 需要 Vultr API？ | 必须先有 |
|---|---|---|
| 已有 VPS，只装/改 VPN | **不需要** | IP、SSH 端口/用户、私钥（或密码）、root 或免密 sudo、主机能出网 |
| 有 Vultr 账号，但没有机器 | **需要**（Read & Write） | Vultr 账号 + API Key；本机 `bash`/`ssh`/`curl`/`python3` |
| **连 Vultr 账号都没有** | **需要**（先注册/充值/建 Key） | 邮箱、支付方式、约 $10 预算；约 10 分钟 |
| 只读规划、写文档、解释协议 | 不需要 | 无 |

### 套餐与价格（建机前给用户看）

| 套餐 | 配置 | 月费 | 区域 | 适合 |
|---|---|---|---|---|
| `vc2-1c-0.5gb` | 1 vCPU / 512MB / 10GB | **$3.5** | 仅 `ewr`（美国新泽西） | 只上 ChatGPT/YouTube/GitHub，单用户、单协议 |
| `vc2-1c-1gb` | 1 vCPU / 1GB / 25GB | **$5** | `nrt`/`sgp`/`lax` 等 | 多设备、多协议，或要日本/新加坡低延迟 |
| `vc2-1c-2gb` | 1 vCPU / 2GB / 55GB | **$10** | 多数区域 | 多人、多节点 |

- **只访问 ChatGPT 等、自己用**：推荐 **$3.5**，但要说明只有 `ewr` 有，日本/新加坡最低 $5。
- 在意延迟、要多设备/双协议：选 $5 的 `nrt`/`sgp`。
- 创建前必须把这张表（或 `vpsctl plans --region <区域>`）给用户看，**不要只报选中那一档**。
- 价格按小时计费，$3.5/$5 是跑满一个月的估算；销毁即停止。

### 连 Vultr 账号都没有？

Agent **不能**替你注册账号或付款；按下面顺序做完再回到工作流（约 10 分钟）：

1. **注册**：打开 <https://www.vultr.com> → **Sign Up** → 邮箱验证
2. **充值**：右上头像 → **Billing** → **Add Funds**，通常 **$10 起**；
   支持信用卡 / PayPal，部分地区支付宝——以页面显示为准。**不充值不能开机**
3. **创建 API Key**：右上头像 → **Account** → **API Keys** → **Add API Key**，
   权限选 **Read & Write**
4. **存到本机**：
   ```bash
   bash ../vps-provision/scripts/vpsctl setup-key
   ```
5. **验证**：`bash ../vps-provision/scripts/vpsctl doctor` 显示
   `API key set` 和 `API call ok`

完整图文步骤见
[`vps-provision/references/vultr-setup.md`](../vps-provision/references/vultr-setup.md)。

不想注册 Vultr：用任意已有 VPS 走 SSH 路径；其他云厂商的机器同样可以，只是
`vpsctl` 目前只适配 Vultr。

> 不要买/借来源不明的账号或 API Key，也不要让 Agent 代填支付信息。
> 计费按小时；$3.5/月档跑一天约 $0.12，销毁后停止计费。

准备顺序：

1. **已有机器**：直接走 `vpnctl` / `remote.sh`，不碰云 API。
   ```bash
   bash scripts/remote.sh -i ~/.ssh/<你的私钥> connect root@<IP>   # 先证明 SSH 可用
   ```
2. **没有机器**：先确认有没有 Vultr 账号。
   - 有账号：一次性配置 Key（隐藏输入、自动校验、存 0600）：
     ```bash
     bash ../vps-provision/scripts/vpsctl setup-key
     ```
   - 连账号都没有：先按上面的「连 Vultr 账号都没有？」注册、充值、建 Key。
   也可以用 `export VULTR_API_KEY=...`；GUI 启动的 Agent 读不到环境变量，优先用 `setup-key`。
3. **本机自检**：
   ```bash
   bash scripts/vpnctl doctor
   bash ../vps-provision/scripts/vpsctl doctor   # 只有走云 API 时才需要
   ```
   需要 `bash`、`ssh`、`curl`、`python3`；缺什么先补什么。

边界（必须提前确认，否则会卡住）：

- VPS 在**境外**（要访问被墙站点时）；国内主机当出口没有意义。
- 云厂商**安全组/防火墙**已放行 SSH；VPN 端口（如 443/udp）之后也要在控制台放行。
- 改 SSH 端口前必须有**控制台/VNC** 退路；没有就先用 `--no-ssh`。
- API Key 只用于创建/销毁等云操作；**VPN 装好后删掉 Key 不影响节点运行**。
- 没有 shell 能力时只输出命令 + 预期输出 + 失败判据，不要假装执行。

**不要**在第 0 步之前问用户“用什么协议”——先确认有没有机器、有没有 API Key，再进入第一步。

## 第一步：选协议（默认优先 Hysteria2）

**默认且优先用 `hysteria2`**：手机、家庭 Wi-Fi、公司 Wi-Fi、国内客户端都已实测通过；
手机端还有确定性 profile（MTU 1400、IPv6 reject、本地规则集）。其他协议作为显式备用。

| 场景 | 推荐 | 理由 |
|---|---|---|
| **手机 / 家庭 Wi-Fi / 国内客户端（默认）** | **`hysteria2`** | QUIC+BBR，弱网吞吐好；手机确定性配置已固化 |
| 需要抗封锁、UDP 被封、只能走 TCP | `xray-reality` | VLESS+Vision+REALITY，TCP/443，无需域名与证书 |
| 客户端老旧/需要最简单兼容 | `ss2022` | Shadowsocks-2022（经 Xray 承载），客户端支持面最广 |
| 干净 UDP、追求最低开销 | `wireguard` | 内核态 UDP；需 TUN 与内核模块 |
| 需要标准 TLS 节点、可配自己的域名/证书 | `trojan` | 真 TLS，客户端兼容好；需要域名 |
| 内网互联、零信任组网 | 不在本 Skill 范围 | 用 Tailscale/Headscale，见 `references/protocol-selection.md` |

拿不准时：默认 `hysteria2`。只有确认 UDP 被封/不稳定时，才显式选 `xray-reality`
或 `ss2022`（TCP）；不要反过来把 Hysteria2 当成“弱网才用”的备选。

**要多节点就一次装齐**（三者同机、端口错开：REALITY 443/tcp、Hysteria2 443/udp、Trojan 8443/tcp）：

```bash
vpnctl up --all --domain vpn.example.com --acme-email you@example.com --client phone --yes
```

装完自动生成一份**订阅**（Clash + base64），客户端一次导入全部节点。没有域名时 `--all` 会跳过 Trojan 并说明原因。

## 硬性安全规则（违反任何一条就停下来）

1. **先开端口，再启服务；先验证，再改 SSH。** 顺序不能反。
2. **不要在远程会话里直接关闭当前 SSH 端口**。改端口必须走 `vpnctl harden --ssh-port N`，它会先放行新端口，并挂 5 分钟自动回滚定时器；确认能连上新端口后再 `vpnctl harden --confirm`。
3. **没有 `authorized_keys` 就不要关密码登录**。工具会自动检测并拒绝；不要用 `--force-password-off` 绕过。
4. **不要在终端输出或对话里明文回显私钥**。客户端配置写到文件，用 `scp`/二维码交付。
5. **任何破坏性操作前先 `vpnctl backup`**；`uninstall` 默认保留状态，`--purge` 才删除。
6. **不要用 `curl | bash` 安装第三方脚本**。本 Skill 的二进制走 GitHub release + `.dgst` 校验，失败即中止。

## 中国大陆用户（最常见的场景）

拓扑必须是：**你（中国大陆）→ 加密隧道 → 境外 VPS → 目标网站**。

| 角色 | 位置 | 说明 |
|---|---|---|
| 客户端 | 中国大陆 | 你的手机/电脑 |
| 出口 | **境外：美国优先（ChatGPT 账号风控更低），日本 / 新加坡次之，香港不建议** | 香港 IP 便宜但常被 ChatGPT 判定不支持 |
| 被访问方 | 境外网站 | YouTube / GitHub / ChatGPT |

三条容易踩的坑：

1. **`check-sites` 要在 VPS 上跑**，不是在你电脑上。本机跑必然全红（它测的是"这台机器→目标"这一段）。
2. **本机不需要能访问 GitHub**：Skill 和脚本都在你本地，`remote.sh` 只用 SSH 连 VPS。
3. **UDP 是否可用要实测**：默认优先 Hysteria2；如果公司/校园网确实封 UDP，再显式切 TCP：

```bash
vpnctl up --backend hysteria2 --client phone --yes       # 默认，推荐
vpnctl up --cn --client phone --yes                      # 同上，Hysteria2
vpnctl up --backend xray-reality --client phone --yes    # 仅 UDP 不可用时
```
`--cn` 不再切 REALITY；它只是标记“大陆客户端”，默认仍是 Hysteria2。

判断一台机器能不能用，一条命令：

```bash
vpnctl check-sites
# country CN   -> verdict: host_in_cn，退出码 6：这台机器在国内，换境外机器
# country JP   -> verdict: ok / chatgpt_blocked，再决定要不要装
```

## 机器已经建好、甚至已经装了服务

**不要重装**。先读 `probe` 的 `foreign` 字段，再决定接管还是重建：

```bash
vpnctl probe --json | grep -A4 foreign
vpnctl import hysteria2 phone            # 读现有配置，不改服务、不重启
vpnctl sub --name phone --template /root/conf.yaml --serve
```

完整步骤、安全保证和常见坑见 `references/adopt-existing.md`。

## 全自动工作流（优先）

> 第一次用、或还没有 VPS / API Key：先完成「第 0 步」。
> 没有 Key 时 `autopilot.sh` 会在建机阶段失败；连 Vultr 账号都没有时，先带用户注册，不要直接跑。

`scripts/autopilot.sh` 把下面所有步骤串成一条命令，Agent 优先调它：

```bash
bash scripts/autopilot.sh --purpose chatgpt        # 建机 + 部署 + 订阅 + 装本机客户端 + 导入
bash scripts/autopilot.sh --host root@1.2.3.4      # 已有机器，只部署和配置本机
bash scripts/autopilot.sh --dry-run                # 先看要做什么
```

（仓库根目录的 `./autopilot.sh` 是同一个脚本的快捷方式。）

## 从零开始（连机器都还没有）

先创建机器，再配置——两步可以合成一条命令：

```bash
export VULTR_API_KEY="..."
bash ../vps-provision/scripts/vpsctl up --name jp1 --region nrt \
     --plan vc2-1c-1gb --os 2136 --cn --client phone
```

如果没有 `vps-provision`，先按云厂商控制台开一台机，再走下面的路径。

## 被一段提示词唤起时（标准入口）

如果用户是**粘贴一段话**让你干活（而不是逐步对话），按这个顺序：

1. 读 `references/intake.md`，**一次问完**所有信息（默认值先填好）。
2. `bash scripts/remote.sh connect root@<IP>` —— 先证明 SSH、sudo、系统版本都可用，再谈部署。
3. 只读检查：`probe` → `plan` → `check-sites`，把「改什么 / 风险 / 回滚」列给用户，**等授权**。
4. 授权后连续执行，不逐步打断。
5. 交付：订阅链接（或文件路径）+ 导入方式 + 回滚命令。

可直接复制的提示词模板在 `assets/ENTRY-PROMPT.md`，含中英文两版。

## 一键路径（优先使用）

用户说「帮我配好」「自动装一个」时，不要逐步执行，直接走一键：

```bash
# 在笔记本上，一条命令完成：上传 -> 安装 -> 开端口 -> 建客户端 -> 验证 -> 取回配置
bash <skill_dir>/scripts/remote.sh deploy root@<VPS_IP> --client phone

# 已经在 VPS 上时
vpnctl up --client phone --yes
vpnctl up --backend hysteria2 --client phone --yes   # 指定后端
vpnctl up --dry-run                                  # 只看计划
```

`up` 的后端选择规则（`--backend auto`，默认）：

| 条件 | 选择 |
|---|---|
| **默认（未显式指定）** | **`hysteria2`** |
| 明确要 TCP / UDP 被封 | 显式 `--backend xray-reality` 或 `ss2022` |
| 明确要内核态最低开销 | 显式 `--backend wireguard` |

`up` 默认只开防火墙、不动 sshd；需要一并加固 SSH 时加 `--ssh-harden`。失败即停，不会带着半成品继续。非交互执行必须带 `--yes`。

装完会**自动生成订阅**（Clash 完整配置 + base64），并跑一次站点可达性检查。

**有自己的分流策略时**，用 `--template` 把你的 profile 交给它——工具只替换 `proxies:` 与各分组的成员，规则、规则集、分组名原样保留：

```bash
vpnctl sub --name phone --template ~/my-clash-conf.yaml
```

示例模板见 `assets/profile-template.example.yaml`（Loyalsoldier 规则集 + 节点选择/流媒体/AI 三组）。

### 目标站点：ChatGPT / YouTube / GitHub

这三件事不是同一类问题，必须分开说：

| 站点 | 卡在哪 | 本 Skill 怎么处理 |
|---|---|---|
| YouTube | 只要通道通就能看 | 订阅里 `youtube.com`/`googlevideo.com` 固定走代理 |
| GitHub | 同上，只是可能慢 | 订阅里固定走代理 |
| **ChatGPT** | **按出口 IP 的国家 + 机房信誉封禁**，配置再对也可能提示 "not available in your country" | **美区优先 + 固定 IP**；`check-sites` 提前判定；订阅里加 DNS 防泄漏 + 域名固定走代理 |

```bash
vpnctl check-sites          # 部署前后都该跑：这个 IP 到底能不能开 ChatGPT
vpnctl check-sites --json   # {"verdict":"ok"|"chatgpt_blocked"|"network_issue", ...}
```

`verdict: host_in_cn` 时先换机器——国内 VPS 无论怎么配都到不了这些站点。

`verdict: chatgpt_blocked` 时**不要改配置**——换 IP 或换区域才有用（美国优先，日本/新加坡次之；机房 IP 被 OpenAI 标记是常态）。这时如实告诉用户，不要承诺"再调调就好"。

### 降低 ChatGPT 账号风控（美区优先）

- 出口优先 **美区**：`ewr` / `lax` / `sjc` / `sea`；香港不建议，日本/新加坡次之。
- **固定一个出口 IP 和节点**，不要频繁换国家、重建机器或来回切换订阅。
- 不要共享订阅链接；不要多人共用一个出口登录多个 ChatGPT 账号。
- 账号注册地/支付方式尽量与出口地区一致；美区账号优先美区出口。
- 不要用这个 IP 做爬虫、批量注册、试用滥用。
- `check-sites` 只代表网络可达，不代表账号不会被风控；以上只能降低概率，**不能保证不封号**。

**自动化的边界**（不要向用户承诺做不到的事）：

| 能自动 | 不能自动 |
|---|---|
| 装包、下载二进制、生成密钥 | 开云厂商安全组（需要你的账号/API 权限） |
| 写配置、起服务、开防火墙 | 提供 SSH 凭据或执行目标 IP |
| 建客户端、导出配置、二维码 | 在用户手机上装 App、点导入 |
| 健康检查与回滚 | 判断当地法律是否允许 |

触发方式：用户显式调用 `/vps-vpn-setup`，或模型根据需求加载。加载本身**不会**执行任何命令——必须有 shell 工具且目标可达。

## 标准流程（需要分步控制时）

**准备**：先按「第 0 步」确认已有机器和 SSH；没有机器先按 `vps-provision` 建机。
下面的命令默认 SSH 密钥已配置好，否则给 `remote.sh` 加 `-i ~/.ssh/<你的私钥>`。

复制脚本到 VPS 只用一种方式（在本地执行，`scripts/remote.sh` 自动打包 + bootstrap）：

```bash
bash <skill_dir>/scripts/remote.sh push root@<VPS_IP>     # 打包上传 + 安装到 /usr/local/bin/vpnctl
bash <skill_dir>/scripts/remote.sh run  root@<VPS_IP> probe --json
```

若已在 VPS 上（或有现成 ssh 会话），把 `scripts/` 目录拷过去后直接：

```bash
bash scripts/vpnctl bootstrap        # 可选：安装为 /usr/local/bin/vpnctl
```

0. **探测**（只读，绝不修改主机）
   ```bash
   vpnctl probe --json
   ```
   关注：`host.virt`（lxc/openvz → WireGuard 不可用）、`capabilities.tun_device`、`network.public_ipv4`、`firewall.kind`、`listening.*`（端口是否被占）。

1. **出计划并复核**（不执行）
   ```bash
   vpnctl plan wireguard
   ```
   计划里出现意外的端口、网段、SNI 时，先停下来向用户确认。

2. **安装**
   ```bash
   vpnctl install wireguard --yes
   vpnctl install xray-reality --port 443 --sni www.microsoft.com --yes
   vpnctl install hysteria2 --port 443 --yes
   vpnctl install ss2022 --port 8388 --yes
   vpnctl install trojan --domain vpn.example.com --acme-email you@example.com --yes
   ```
   幂等：重复执行只更新配置，不重建密钥、不影响已有客户端。

3. **放行端口 / 加固 SSH**
   ```bash
   vpnctl harden --no-ssh          # 只开防火墙端口，最安全的第一步
   vpnctl harden                   # SSH 加固（有 key 时自动关密码登录）
   vpnctl harden --status          # 复核
   ```

4. **建客户端并导出**
   ```bash
   vpnctl client wireguard add --name phone --yes
   vpnctl client wireguard list
   ```
   导出物在 `~/vpn-clients/<backend>/<name>/`：`*.conf` / `uri.txt` / `outbound.json` / `*.png`（有 `qrencode` 时）。取回本地：
   ```bash
   bash <skill_dir>/scripts/remote.sh pull root@<VPS_IP> ./vpn-clients
   ```

5. **验证**（必须做，不能只看服务状态）
   ```bash
   vpnctl verify wireguard --json
   ```
   `ok:true` 才算完成；WireGuard 额外看 `peers/handshaked`（客户端首次握手后才会增长），其它后端看 `service/config/tcp` 三项。

6. **交付**：告诉用户客户端 App 名称、导入方式、二维码文件路径，以及一条回滚命令。

## 命令速查

| 命令 | 作用 |
|---|---|
| `vpnctl up [--backend NAME] [--client NAME]` | **一键**：选后端 → 安装 → 开端口 → 建客户端 → 验证 |
| `vpnctl probe [--json]` | 主机/网络/端口/已装后端盘点（只读） |
| `vpnctl sub --name N [--out DIR] [--template FILE] [--serve]` | 汇成一份订阅；`--template` 套用你的规则，`--serve` 同时给出订阅**链接** |
| `vpnctl sub --unserve` | 关闭订阅链接服务 |
| `vpnctl import hysteria2 [NAME]` | 把**手装**的 Hysteria2 纳入管理（不改服务） |
| `vpnctl passwd [--generate] [--allow-password-login]` | 给 root 设密码（网页控制台登录需要；默认不开 SSH 密码登录） |
| `vpnctl singbox --name N [--phone] [--out F] [--global]` | 生成手机端 sing-box JSON；`--phone` 为确定性 Hysteria2-only 配置 |
| `vpnctl plan <be>` | 打印将要执行的动作（只读） |
| `vpnctl install <be> [opts]` | 安装或重配后端（幂等） |
| `vpnctl client <be> add --name N` | 新增客户端并导出 |
| `vpnctl client <be> list` | 列出客户端 |
| `vpnctl client <be> remove --name N` | 吊销客户端（立即生效） |
| `vpnctl client <be> export --name N [--out DIR]` | 重新渲染导出物 |
| `vpnctl verify <be> [--json]` | 健康检查 |
| `vpnctl check-sites [--json]` | 这个 IP 能不能开 ChatGPT/YouTube/GitHub（退出码 5 = 地区被封） |
| `vpnctl harden [--status\|--ssh-port N\|--lockdown\|--no-ssh\|--confirm]` | 防火墙 + SSH 加固 |
| `vpnctl backup` | 打包 `/etc/vpnctl` 与后端配置到 `/var/backups/vpnctl` |
| `vpnctl uninstall <be> [--purge]` | 卸载（默认保留状态） |
| `vpnctl doctor` | 工具自检 |
| `vpnctl bootstrap` | 安装到 `/usr/local/lib/vpnctl` + `/usr/local/bin/vpnctl` |

退出码：`0` 成功，`2` 用法/前置条件错误，`3` 内部错误，`4` 验证失败。全局参数 `--yes`、`--dry-run`、`--json`、`--verbose`、`--no-color` 可放在任意位置。

**顺序要求**：`install` 必须在 `client add` 之前；`harden` 必须在用户真正尝试连接之前；`uninstall` 前先 `backup`。

## 后端参数摘要

- `wireguard`：`--port` `--subnet` `--mtu` `--dns` `--iface` `--route-ipv6` `--no-split`
- `xray-reality`：`--port` `--sni` `--dest` `--fp` `--flow` `--version` `--mirror`
- `ss2022`：`--port` `--method` `--version` `--mirror`
- `hysteria2`：`--port` `--sni` `--obfs` `--obfs-password` `--no-obfs` `--masquerade` `--cert` `--key`
- `trojan`：`--domain`（必填）`--acme-email` `--cert` `--key` `--self-signed` `--port` `--alpn`

`--mirror` 用于 VPS 拉不到 GitHub 的场景；不要自行改成非官方二进制源。

## 交付给第一次用的用户（必须做）

只给链接是不够的。交付时**必须同时给出**：

1. 订阅链接（或 `clash.yaml` 文件路径）
2. 用户系统对应的客户端：Windows/macOS/Linux → **Clash Verge Rev**；iPhone → Shadowrocket / sing-box；Android → Clash Meta for Android
3. 导入步骤：客户端里「订阅 → 从 URL 导入 → 粘贴」；如果给的是本地文件，说明「从文件导入」和 yaml 的四块结构（`proxies` / `proxy-groups` / `rule-providers` / `rules`）
4. 验证方法：打开 `https://ipinfo.io`，应显示**服务器所在地（如美国）**；再打开一个国内站点确认直连正常。IP 查询站（`ipinfo.io`/`ip.sb` 等）已特意加入代理；其他没被墙的海外站仍直连
5. 关闭方法：关掉系统代理/TUN 开关

**iPhone/Android 用 sing-box 时**：导入 `http://<IP>:<端口>/<token>/singbox.json`。
完整的 URL 导入步骤、验证方法、版本要求（1.10+）和注意事项见
[`references/getting-started.md`](references/getting-started.md) 的「手机端：sing-box」。

> **手机端固定配置（不要再混协议）**：`vpnctl sub --name phone --serve` 会优先生成
> **Hysteria2-only** 的 `singbox.json`：TUN MTU 1400、IPv4+IPv6、IPv6 reject、无 fakeip、
> `final: proxy`、头条/字节直连、规则集从订阅服务本地加载。不要在同一份手机配置里加
> SS2022 + 选择器 + UDP 分流——Wi-Fi/蜂窝下 TCP/QUIC 出口会不一致，YouTube 和头条会时好时坏。
> 公司 Wi-Fi、家庭 Wi-Fi、手机流量都用同一份配置。

如果 Agent 就运行在用户这台电脑上，可以代劳最后一步：

```bash
bash scripts/clientctl detect                      # 先看系统和是否已装
bash scripts/clientctl all "<订阅链接>"             # 下载 + 安装 + 深链接导入
```

macOS/Linux 能真的装；Windows 只下载安装包。

**再进一步**：Clash Verge 的状态都在文件里（`profiles.yaml` 的 `current:`、`verge.yaml` 的
`enable_system_proxy`），可以完全免点界面：

```bash
bash scripts/clientctl attach "<订阅链接>" --name phone --system-proxy
```

写完后让用户重启客户端即可。深链接（`import`）作为兼容路径保留。

完整的分系统步骤见 `references/getting-started.md`（含截图级细节和常见问题）。

**下载客户端的现实问题**：中国大陆直连 GitHub 常常打不开。手机端用 App Store / 应用商店；
桌面端如果下载不动，先换能上网的环境下载安装包，或用镜像站搜索同名项目。这一点要主动告诉用户。

## 客户端交付

| 后端 | 客户端 | 导入方式 |
|---|---|---|
| wireguard | WireGuard（官方 App） | 导入 `.conf` 或扫 `*.png`；`sysctl` 全隧道默认 `0.0.0.0/0` |
| xray-reality | v2rayN/v2rayNG/NekoBox/sing-box/mihomo | 粘贴 `uri.txt`（`vless://…`）或 `outbound.json` |
| ss2022 | 同上 + Shadowrocket | 粘贴 `ss://…`；2022 方法需较新客户端 |
| hysteria2 | NekoBox/Karing/sing-box/mihomo | 粘贴 `hysteria2://…` 或 `client.yaml` |
| trojan | v2rayN/NG、NekoBox、Shadowrocket、Clash | 粘贴 `trojan://…`；自签证书需关校验 |
| 订阅 | Clash Verge/Mihomo、v2rayN/NG、Shadowrocket | 导入 `~/vpn-clients/_subscriptions/<name>/clash.yaml` 或 `v2ray.txt` |

REALITY 的 `sni/pbk/sid` 必须与服务器一致；Hysteria2 用自签证书时客户端需 `insecure` 或按 `info.txt` 里的 sha256 固定证书；Trojan 用自签证书时同样要关校验，用 ACME/自备证书则不要关。

**要**链接**而不是文件时加 `--serve`：

```bash
vpnctl sub --name phone --template /root/conf.yaml --serve
# http://<IP>:<PORT>/<token>/clash.yaml
```

URL 本身就是密码（bearer credential）：token 32 位随机、端口随机、服务只认 `/<token>/` 下的三个文件。
不用时 `vpnctl sub --unserve` 立即关闭。

订阅是完整 Clash 配置（含 `dns` 防泄漏块与目标站点规则），不是只列节点。订阅是凭据**：`clash.yaml` / `v2ray.txt` 里是可直接连的节点，等同于密码。不要贴群、不要提交 Git；要给别人用就单发文件。

## 密码：默认随机，用户可自己定

**先问用户一次**（不要默认替他选弱密码）：

> 节点密码使用哪种？
> 1. **随机生成（推荐）**：20 位随机，强度最高
> 2. **我自己定**：建议至少 16 位随机字符；不要用 `password123`、生日、手机号、姓名，也不要和公开服务共用

默认是随机生成。用户要自己定时，优先用 stdin，避免留在 shell 历史：

```bash
vpnctl up --backend hysteria2 --client phone --password-stdin
echo '你的强密码' | vpnctl client hysteria2 add --name phone --password-stdin
```

也可以直接传 `--password '...'`（会进 shell 历史，不推荐）。规则：

- 工具最低接受 8 位；**强烈建议 16+ 位随机**
- 少于 12 位会警告；`password123` 等常见弱密码会明确警告
- **不能含冒号**（hysteria2 内部用 `user:pass` 形式，有冒号会把配置截断）
- 不能含空格

已存在的客户端再传一次 `--password` 会**更新密码**；`up` 也会更新已存在客户端的密码。旧客户端会立刻失效，要先告诉用户。

**共享密码的代价**：一旦把同一个密码给朋友/群，任何拿到它的人都能用你的出口；无法单独吊销某个人。能接受再共用，并优先选随机强密码。Trojan 同样支持 `--password`；SS2022 的 PSK 是固定长度 base64，不能随便填。

## 用户要"能登录服务器"时

用密钥创建的机器，root 通常没有可用密码——用户想用云厂商的**网页控制台**（Vultr 的
View Console）登录就会卡住。

```bash
vpnctl passwd --generate                 # 生成 24 位密码，写到 /root/.vpnctl/passwords/root.txt
vpnctl passwd --generate --show          # 同时打印（只在用户明确要时用）
vpnctl passwd --stdin                    # 用户自己给：echo 'xxx' | vpnctl passwd --stdin
```

**默认不打开 SSH 密码登录**（密钥优先）。确实需要再加 `--allow-password-login`，
并且要提醒用户：这会扩大暴露面，值得配 fail2ban。

密码落到文件（600）而不是聊天记录里——这是本项目的硬规则。

## IP 是否被封（先测，再决定）

在**用户自己的设备上**测，不是服务器上——被封的是「用户 → 服务器」这一段：

```bash
bash scripts/check-ip.sh <IP> --port 443
# 或经 remote.sh：bash scripts/remote.sh reach root@<IP>
```

四种结论，动作完全不同：

| verdict | 含义 | 必须对用户说什么 |
|---|---|---|
| `ok` | 端口可达 | 正常，不用动 |
| **`blocked`** | 服务端口和 SSH 都不通，但控制目标可达 | **「这个 IP 被封了，需要销毁服务器、重新建一台」**，并给出 rebuild 命令 |
| `service` | IP 通（SSH 能连），只是服务挂了 | 修服务，**绝对不要**建议重建 |
| `local` | 连控制目标都不通 | 先查用户自己的网络 |

`blocked` 时的动作：

```bash
cd ../vps-provision
./scripts/vpsctl rotate <name> --yes --client phone   # 同套餐重建 + 重新部署
```

**禁止**：`blocked` 时建议"换个端口试试""换成 WireGuard"——IP 级封锁下这些都无效，只会浪费用户时间。

**必须**：明确告诉用户为什么是 IP 的问题（端口和 SSH 同时不通），以及重建后订阅链接会变。

## 排障入口

先 `vpnctl verify <be> --json`、`vpnctl probe --json`、`vpnctl check-sites`，再查 `references/troubleshooting.md`。常见：UDP 被云厂商安全组挡住（WireGuard/Hysteria2 连不上但服务正常）、TCP/443 被 nginx 占用、容器内无 TUN、时间不同步导致 REALITY 握手失败。

## 维护

- 升级二进制：重跑 `install`（会保留密钥与客户端）。
- 轮换客户端：`client remove` + `client add`，旧配置立即失效。
- 备份/迁移：`vpnctl backup` → `/var/backups/vpnctl/manual-*.tar.gz`。
- 卸载：`uninstall` 保留 `/etc/vpnctl`，便于回滚。

## 多 Agent / 多模型适配

本 Skill 的内容与工具与具体 Agent 无关。`install.sh` 会按目标工具写入各自的发现路径：

```bash
bash <skill_dir>/install.sh --target auto     # 自动探测已安装的 Agent
bash <skill_dir>/install.sh --target dsh|claude|codex|cursor|gemini|copilot|agents
```

各工具的目录约定、能力分级（能跑 shell / 只能给命令 / 纯聊天）与降级策略见 `references/agent-adapters.md`；纯聊天模型用 `assets/prompts/chat-only.md`。

## 资源

- `scripts/vpnctl` — 主入口（探测/安装/客户端/校验/卸载）
- `scripts/remote.sh` — 本地侧上传与远程执行；`connect` 做 SSH 体检
- `scripts/lib/` — 共享库与 5 个后端（新增后端只需实现同一组 `be_*` 函数，见 `references/extending.md`）
- `references/protocol-selection.md` — 选型与网络环境判断
- `references/agent-adapters.md` — 多 Agent / 多模型适配矩阵
- `references/first-run.md` — **完全新手**：注册 Vultr、充值、建 API Key、客户端导入的完整剧本
- `references/getting-started.md` — **第一次使用**：分系统安装客户端、导入订阅、验证
- `references/client-setup.md` — 各协议对应的客户端详解
- `references/troubleshooting.md` — 排障手册
- `references/security-hardening.md` — 加固与合规要点
- `references/operations.md` — 运维：监控、轮换、迁移、限流
- `references/adopt-existing.md` — 接管已有机器/已有节点（不重装）
- `tests/smoke.sh` — 本机 311 项断言（无需 VPS）
- `tests/acceptance.sh` — 在 VPS 上跑完整生命周期验收
- `TESTING.md` — 四层实践路线（本机 → 一次性 VPS → 手机真机）
- `assets/` — 可粘贴的提示词与各 Agent 的命令模板

## 完成标准（Definition of Done）

1. `vpnctl verify <be> --json` 返回 `"ok": true`。
2. 至少一个客户端导出物已生成，且用户能说出导入方式。
3. `vpnctl harden --status` 显示 VPN 端口已放行、SSH 状态符合预期。
4. 明确告知用户回滚方式（`uninstall` / `harden --confirm` / 云控制台）。
