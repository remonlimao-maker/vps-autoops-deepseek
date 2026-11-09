# VPS AutoOPs Agent

**一句话：把「帮我弄一台能上 ChatGPT 的服务器」变成一段可以粘给 AI 的话。**

你不需要懂 Linux、不需要会配 VPN、不需要记命令。把下面的话发给 AI，剩下的它做。

---

## 30 秒开始

### 前提

- 电脑上装了 **DeepSeek Harness**（或 Claude Code / Codex / Cursor，都行）
- 有一个能执行命令的 AI 对话窗口

### 第 1 步：复制这段，粘进对话框

```text
请用这个仓库帮我搭建自己的 VPN 节点：
https://github.com/remonlimao-maker/vps-autoops-deepseek

先读 AGENTS.md 和 vps-vpn-setup/SKILL.md，
需要什么信息直接问我（一次问完），先连 SSH 做只读检查，
把要改什么、风险、怎么回滚列给我，等我确认后再执行，
最后把订阅链接和客户端安装步骤给我。
```

### 第 2 步：回答 AI 的问题

它只会问 3–4 个问题，比如：

- 你已经有一台服务器了吗？（有就给 IP）
- 主要用来做什么？（ChatGPT / YouTube / GitHub / 全部）
- 你的手机或电脑在国内还是国外？
- 有没有现成的 Clash 配置想沿用？

**没有服务器也没关系**，它会帮你开一台（约 $3.5/月，需要 Vultr 账号）。

### 第 3 步：看它给的「变更清单」，回一句「可以」

AI 会先做只读检查，然后列出：要装什么、占哪些端口、改哪些文件、怎么回滚。
你确认后它才开始动手。

### 第 4 步：等 5–10 分钟，拿到订阅链接

最后你会收到一条网址，形如：

```
http://1.2.3.4:27008/xxxxxx/clash.yaml
```

把它导进客户端（Clash Verge 等），就能上网了。**具体怎么导入看 [新手向导](vps-vpn-setup/references/getting-started.md)。**

---

## 它是怎么工作的

### 一张图

```
你的手机/电脑                境外服务器                 目标网站
（客户端）    ──加密隧道──▶   （节点/出口）  ──正常访问──▶  YouTube
                                                          ChatGPT
                                                          GitHub
```

你在国内直接连 YouTube 会被拦。所以租一台国外服务器，让它**替你访问**，
再把内容加密传回你的设备。中间的网络设备只能看到一串加密数据。

### 三个概念，看懂就够了

| 概念 | 大白话 |
|---|---|
| **节点** | 那台替你上网的国外服务器。它的 IP 就是你的「出口身份」 |
| **协议** | 隧道怎么伪装。REALITY 假装你在访问微软官网；Hysteria2 用 UDP 跑得更快但容易被限速 |
| **订阅** | 一个网址，里面写着节点信息（IP、端口、密码）。客户端读它来连接，服务器更新了客户端点一下就能同步 |

### 为什么要「分流」

不是所有流量都该走国外。刷 B 站、用 DeepSeek 走国外反而更慢，还可能触犯风控。
所以规则是这样：**国内网站直连，国外网站走隧道**。

本项目生成的配置默认就是这个策略，并且把 DeepSeek、飞书、B 站等写死成直连。

### 为什么 IP 会被封

防火墙认得出"这台机器在干什么"。被盯上后会封 IP——这时候换端口、换协议都没用，
只能换一台机器（新 IP）。所以项目里带了一个 `check-ip` 检测：先判断是不是 IP 被封，
再决定"修服务"还是"重建机器"。

---

## 部署时会经过什么（理解后你能自己排查）

AI 执行的就是这五步，每一步你都可以问它"现在到哪了"：

| # | 做什么 | 产出 / 检查 |
|---|---|---|
| 1 | **探测**：看操作系统、内存、端口占用、防火墙；如果机器上已经有别人装的服务，会识别出来而不是重装 | `probe` 报告 |
| 2 | **安装**：装 Xray（REALITY）或 Hysteria2，生成服务器密钥，写系统服务 | 服务 running |
| 3 | **放行**：防火墙开端口；云厂商的安全组要单独开（这步最容易漏） | 端口监听 |
| 4 | **出配置**：生成客户端配置和订阅；用你自己的规则就套用你的 | `clash.yaml` / 订阅网址 |
| 5 | **验证**：从服务器测 ChatGPT/YouTube/GitHub 能不能通，从你这边测 IP 有没有被封 | `verdict: ok` |

---

## 你需要准备什么

| 你的情况 | 需要准备 |
|---|---|
| **已经有一台 VPS** | 服务器 IP + root 密码，或 SSH 密钥 |
| **没有服务器** | Vultr 账号 + API Key（读写权限）。大约 $3.5/月，无其他费用 |
| **想用手机连** | 装一个客户端（Clash Verge / Shadowrocket / CMFA），见新手向导 |

**不需要**：域名、证书、备案、任何增值服务。

> 打不开 GitHub 下不了客户端？先装 [Watt Toolkit](https://steampp.net/download) 开 GitHub 加速，
> 装完客户端再关掉。详见新手向导「第 0 步」。

---

## 第一次用客户端

拿到订阅链接之后的事，看这份文档：

👉 [`vps-vpn-setup/references/getting-started.md`](vps-vpn-setup/references/getting-started.md)

里面有：Windows / macOS / Linux / iPhone / Android 各自的安装和导入步骤、
本地 yaml 文件怎么改、怎么验证成功、常见问题。

---

## 进阶：直接敲命令

不想让 AI 代劳、或者想自己看清楚每一步：

```bash
# 让 Agent 发现这两个 Skill
./install.sh

# 自测：不联网、不花钱
bash vps-provision/tests/smoke.sh
bash vps-vpn-setup/tests/smoke.sh

# 一次性：粘贴 Vultr API Key（隐藏输入，自动验证读写权限）
bash vps-provision/scripts/vpsctl setup-key

# 之后一条命令：建机 + 装 VPN + 套规则 + 出订阅
bash vps-provision/scripts/vpsctl go --purpose chatgpt --yes
```

已经有机器、只想配置：

```bash
cd vps-vpn-setup
bash scripts/remote.sh --cn -c phone deploy root@<VPS_IP>
```

> ⚠️ 选项要写在 `deploy` **之前**，写在目标地址后面会被当成目录名。

## 仓库里有什么

| Skill | 作用 | 测试 |
|---|---|---|
| [`vps-provision/`](vps-provision/README.md) | 创建云主机（Vultr）：区域/套餐选择、建机、快照、销毁 | 52 项 |
| [`vps-vpn-setup/`](vps-vpn-setup/README.md) | 部署与运维 VPN：WireGuard / REALITY / SS2022 / Hysteria2 / Trojan，订阅交付、分流、接管已有节点、防锁死加固 | 235 项 |

还有：`AGENTS.md`（Agent 入口约定）、`SECURITY.md`（安全边界）、
`vps-vpn-setup/assets/ENTRY-PROMPT.md`（中英文提示词模板）。

## 设计约定

- 单一命令入口，`--json` 给机器、日志给人类、退出码固定
- 先只读检查（`probe`/`plan`），再改主机；改动幂等、可回滚
- 密钥只落文件，不进对话与日志
- 文档与实现由冒烟测试对账（改了参数就补断言）

> **使用边界**：仅供个人在自己拥有或获授权的服务器上使用。请自行确认所在地法律、云厂商服务条款允许该用途；作者不对使用后果负责。详见 [SECURITY.md](SECURITY.md)。
