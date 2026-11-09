# 零基础开始（什么都不用会）

如果你**没有**服务器、没用过终端、没配过代理，从这一页开始。

整个事情的目标：**让你的手机或电脑能上 ChatGPT、YouTube、GitHub。**

---

## 先判断你属于哪种情况

| 你的情况 | 走哪条路 | 需要多久 |
|---|---|---|
| 电脑上装了 DeepSeek Harness / Claude Code / Codex 这类**能执行命令的 AI** | **路径 A**（推荐，全自动） | 15 分钟 |
| 只有网页版 AI（ChatGPT / DeepSeek 网页、豆包、Kimi） | **路径 B**（网页 AI 指挥 + 浏览器里粘贴命令） | 30 分钟 |

先看你的 AI 能不能执行命令：**问它"你能在这台电脑上运行命令吗？"**
能 → 路径 A；不能 → 路径 B。

---

## 无论哪条路，你都需要准备

| 要什么 | 说明 | 多少钱 |
|---|---|---|
| 一台能上网的电脑 | Windows / Mac 都行 | — |
| 一个 Vultr 账号 | 国外的云服务器商家，注册只要邮箱 | 免费注册 |
| 支付方式 | 信用卡 / PayPal（部分地区支持支付宝） | 先充 **$10** 左右 |
| 预算 | 服务器约 **$3.5/月**（每天约 ¥1），不用了可以销毁 | ≈ ¥25/月 |

> **没有 Vultr 账号？** 注册、充值、创建 API Key 的完整步骤（含截图级说明）见
> [`vps-provision/references/vultr-setup.md`](vps-provision/references/vultr-setup.md)。

---

## 路径 A：AI 全自动（推荐）

### 第 0 步：装一个能执行命令的 AI

路径 A 需要 **DeepSeek Harness**（DeepSeek 官方的桌面 Agent 应用，当前版本 `0.2.2-rc.1`）。
如果你已经装了、并且它能在你电脑上跑命令，跳到第 1 步。

**怎么装**：

1. 从 **DeepSeek 官方渠道**获取安装包（官网 / 官方公告 / 官方群）。**不要用网盘里的"绿色版"**——这类工具会执行命令，装了来路不明的版本等于把电脑交出去。
2. macOS：打开 `.dmg`，把应用拖进 `Applications`
3. Windows：运行安装程序，一路下一步
4. 首次打开：登录 DeepSeek 账号、选一个模型
5. **验证**：在对话框问一句

   > 你能在这台电脑上运行命令吗？试一下 `echo hello`

   它执行并返回 `hello` → 具备了，继续。只会聊天、不能执行 → 走路径 B。

**装不了 DSH 的替代方案**：Claude Code 或 Codex CLI 也能做同样的事，但它们需要先装 Node.js，
对新手反而更麻烦。建议优先找一台 Mac/Windows 装 DSH。

### 第 1 步：拿到这个仓库

**会 git 的话**，在终端里：

```bash
git clone https://github.com/remonlimao-maker/vps-autoops-deepseek.git
```

**不会 git 的话**：打开仓库页面 → 绿色 **Code** 按钮 → **Download ZIP** → 解压到桌面。

> 打不开 GitHub？先装 [Watt Toolkit](https://steampp.net/download) 开「GitHub 加速」，装完再关掉。
> 详见 [`getting-started.md`](vps-vpn-setup/references/getting-started.md) 第 0 步。

### 第 2 步：把仓库路径发给 AI

打开 DeepSeek Harness（或 Claude Code / Codex），把下面这段粘进去，
**记得把路径换成你电脑上那个文件夹的真实路径**：

```text
请用这个仓库帮我搭建自己的 VPN 节点：
<这里换成你的文件夹路径，例如 /Users/你的名字/Downloads/vps-autoops-deepseek>

我是完全的新手，请一步一步带我：
1. 先读 AGENTS.md 和 vps-vpn-setup/SKILL.md
2. 需要什么信息直接问我，一次问完
3. 每一步告诉我你在做什么、我该看到什么
4. 需要我动手的地方，明确告诉我点哪里
```

### 第 3 步：回答 AI 的问题

它会问你 3–4 个问题，例如：

- 有没有 Vultr 账号 / API Key？
- 主要用来干什么？
- 手机和电脑在国内还是国外？

**不知道就说不知道**，它会带你做。

### 第 4 步：等它跑完

它会自己做：建服务器 → 装服务 → 生成订阅 → 帮你装客户端 → 导入。
中间可能弹窗让你输入电脑密码（授权安装），点允许。

### 第 5 步：最后点两下

客户端打开后：

1. 订阅列表里选中刚导入的配置 → 右键 **设为当前**
2. 打开 **系统代理**（或 **TUN 模式**）
3. 浏览器打开 <https://ipinfo.io>，看到是国外就成功了

---

## 路径 B：只有网页 AI

没有能执行命令的 AI 也能做，只是要你自己在浏览器里粘贴命令。

### 第 1 步：在 Vultr 开一台服务器

1. 注册并充值（见 [Vultr 指南](vps-provision/references/vultr-setup.md)）
2. 控制台点 **Deploy New Server**
3. 选择：
   - **Type**：Cloud Compute – Shared CPU
   - **Location**：Tokyo / Singapore / Los Angeles（**别选国内**）
   - **Image**：Debian 12 或 13
   - **Plan**：$3.5/月那档（0.5GB 内存够用）
   - **SSH Keys**：先跳过（后面用密码登录）
4. 点 **Deploy Now**，等 1–2 分钟
5. 列表里点进这台机器，记下 **IP 地址** 和 **root 密码**

### 第 2 步：打开 Vultr 的网页终端

在那台机器的详情页，右上角点 **View Console**（网页里的黑框终端）。
用 `root` + 密码登录。

> 如果你是用 SSH 密钥创建的机器，root 可能**没有密码**，控制台登不进去。
> 这时在终端里跑 `vpnctl passwd --generate`（或 `vpsctl passwd <名字>`）设一个即可。

### 第 3 步：把命令粘给网页 AI

把下面这段发给 ChatGPT / DeepSeek 网页版：

```text
我在 Vultr 开了一台 Debian 13 的服务器，用网页终端登录了 root。
我要装一个能上 ChatGPT 的节点。请一步一步给我命令，我执行后把输出贴给你。
不要一次给完所有步骤。我的服务器在 <东京/新加坡/洛杉矶>。
```

它会一条一条给命令，你复制粘贴到 Vultr 的网页终端，把输出贴回去。

### 第 4 步：或者直接用本仓库的命令

如果你更想按现成的来，在网页终端里依次执行（每行回车，等上一条跑完）：

```bash
apt-get update && apt-get install -y git curl
git clone https://github.com/remonlimao-maker/vps-autoops-deepseek.git
cd vps-autoops-deepseek/vps-vpn-setup
bash scripts/vpnctl install xray-reality --yes
bash scripts/vpnctl client xray-reality add --name phone --yes
bash scripts/vpnctl sub --name phone --serve
```

最后一条会打印出**订阅链接**，形如：

```
http://1.2.3.4:27008/xxxxxx/clash.yaml
```

记下来。

### 第 5 步：在自己电脑/手机上装客户端

照 [`getting-started.md`](vps-vpn-setup/references/getting-started.md) 做：
**电脑**：装 **Clash Verge** → 从 URL 导入订阅 → 选节点 → 打开「系统代理」。

**手机（推荐 sing-box，免费）**：装 **sing-box** → 导入导出的 `singbox.json` → 打开开关。
这份 JSON 已经包含节点和国内直连规则，不用手填任何参数
（详细步骤见 [手机端章节](vps-vpn-setup/references/getting-started.md)）。

---

## 卡住了怎么办

| 现象 | 怎么办 |
|---|---|
| 找不到终端（Mac） | 启动台搜索 `Terminal`（终端） |
| 找不到终端（Windows） | 按 `Win + R`，输入 `cmd` 回车 |
| 命令粘贴不进去 | 终端里用 `Cmd+V`（Mac）/ 右键（Windows） |
| 提示 permission denied | 命令前面加 `sudo ` |
| 下载客户端很慢 | 走路径 B 的网页终端方式，或先装 Watt Toolkit 加速 |
| 装完连不上 | 让 AI 跑 `bash scripts/check-ip.sh <IP>`，它会告诉你是 IP 被封还是服务问题 |
| 网站能开但很慢 | 换订阅里的另一个节点（如果有） |
| 不想用了 | Vultr 控制台 **Destroy** 那台机器；客户端关掉系统代理 |

## 三个必须知道的常识

1. **服务器在境外才有用**。国内服务器自己都上不了 YouTube，白花钱。
2. **销毁 = 停止计费**，但 IP 会变，订阅链接要重新生成。
3. **订阅链接等于密码**，别发群、别截图外传。

---

## 目录：接下来读什么

- 想了解原理 → [README 的「它是怎么工作的」](README.md#它是怎么工作的)
- 装客户端 / 导入订阅 → [`getting-started.md`](vps-vpn-setup/references/getting-started.md)
- 注册 Vultr / 拿 API Key → [`vultr-setup.md`](vps-provision/references/vultr-setup.md)
- 出问题了 → [`troubleshooting.md`](vps-vpn-setup/references/troubleshooting.md)
