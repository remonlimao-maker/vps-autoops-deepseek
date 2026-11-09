# vps-vpn-setup

一个「让 AI Agent 帮你把 VPS 变成 VPN」的 Skill：协议选型 → 安装 → 加固 → 发客户端配置 → 验证，全流程脚本化、幂等、可回滚。

支持 5 种后端（含 Trojan）、一次交付多节点 + 订阅、任意能执行 shell 的 Agent，以及纯聊天大模型。

> **中国大陆用户**：出口必须是**境外** VPS（JP/SG/US 优先，HK 次之）。国内 VPS 自己都上不了 YouTube/GitHub；`vpnctl check-sites` 会检测并直接给出结论。客户端在中国大陆时用 `vpnctl up --cn`（自动选 TCP/443 的 REALITY，UDP 常被限速）。

```
SKILL.md              入口：决策树 + 安全规则 + 标准流程（Agent 读这个）
scripts/
  vpnctl              唯一命令入口（probe/plan/install/client/verify/harden/…）
  remote.sh           在笔记本上远程驱动 VPS
  lib/common.sh       共享库：OS 检测、包管理、状态、日志、JSON
  lib/backend-*.sh    5 个后端（同一组 be_* 函数契约）
  lib/harden.sh       防火墙 + SSH 加固 + 自动回滚
references/           选型、多 Agent 适配、客户端、排障、加固、运维、扩展
assets/               AGENTS.md 片段、各 Agent 的 /vpn 命令、聊天提示词
tests/smoke.sh        无 VPS 也能跑的 300 项断言
tests/acceptance.sh   在 VPS 上跑完整生命周期（装→验→重装→吊销→卸）
TESTING.md            四层实践路线：本机 → VPS → 手机
install.sh            写入各 Agent 的发现路径
```

## 30 秒上手

```bash
# 1) 装到本机 Agent（自动探测已安装的框架）
./install.sh --target auto --dry-run     # 先看会写什么
./install.sh --target auto

# 2) 一条命令配好整台 VPS，并把客户端配置取回本地
bash scripts/remote.sh deploy root@203.0.113.5 --client phone

# 要三节点 + 订阅（需要域名）：
bash scripts/remote.sh deploy root@203.0.113.5 --client phone \
     --backend all --domain vpn.example.com

# 部署前先确认这个 IP 能不能开 ChatGPT（不必已装 VPN）
bash scripts/remote.sh run root@IP check-sites

# 想分步控制时：
bash scripts/remote.sh push root@203.0.113.5
bash scripts/remote.sh run  root@203.0.113.5 probe --json
bash scripts/remote.sh run  root@203.0.113.5 install wireguard --yes
bash scripts/remote.sh run  root@203.0.113.5 harden --no-ssh
bash scripts/remote.sh run  root@203.0.113.5 client wireguard add --name phone --yes
bash scripts/remote.sh run  root@203.0.113.5 verify wireguard --json
bash scripts/remote.sh pull root@203.0.113.5 ./vpn-clients
```

已经在 VPS 上？把 `scripts/` 拷过去直接 `bash scripts/vpnctl <cmd>`。

## 后端

| id | 协议 | 传输 | 默认端口 | 适用 |
|---|---|---|---|---|
| `wireguard` | WireGuard | UDP | 51820 | 自用/团队全隧道，最快最省电 |
| `xray-reality` | VLESS + Vision + REALITY | TCP | 443 | 抗封锁，伪装成正常 TLS，无需域名 |
| `ss2022` | Shadowsocks-2022 | TCP+UDP | 8388 | 客户端兼容面最广 |
| `hysteria2` | Hysteria2 | QUIC/UDP | 443 | 弱网、丢包、跨境高延迟 |
| `trojan` | Trojan | TCP+TLS | 8443 | 有域名，要标准 TLS 节点 |

选型依据见 [`references/protocol-selection.md`](references/protocol-selection.md)。

装两个以上后端后，用 `vpnctl sub --name phone` 生成一份订阅（`clash.yaml` + `v2ray.txt`），一次导入全部节点；`vpnctl up` 装完会自动出订阅，并跑 `check-sites`。

有自己维护的 Clash 策略（规则集/分组/规则）时，用 `--template 你的配置文件`：只替换节点定义和分组里的节点成员，其余原样保留。示例见 `assets/profile-template.example.yaml`。

**关于 ChatGPT**：YouTube/GitHub 通道通了就行；ChatGPT 还取决于出口 IP 的国家与机房信誉。`vpnctl check-sites` 会直接告诉你结论（`verdict: ok` / `chatgpt_blocked`），被封时改配置无用，只能换 IP/区域。

## 设计原则

1. **先读后写**：`probe` 和 `plan` 永远只读；`--dry-run` 打印真实命令而不是模拟。
2. **渲染与生效分离**：配置由状态重新渲染（服务器密钥 + 客户端记录），不手改配置文件；重跑 `install` 即可修复。
3. **幂等**：重复执行不重建密钥、不影响已有客户端；`client add` 对同名是「重新渲染」而不是重复添加。
4. **防锁死**：改 SSH 端口先放行、先 `sshd -t` 校验、再挂 5 分钟自动回滚定时器；没有 `authorized_keys` 绝不关密码登录。
5. **不泄密**：私钥/UUID/PSK 只写文件（`600`），状态目录 `700`；stdout 只放机器可读内容。
6. **可验证**：`verify --json` 的 `ok:true` 是唯一完成标准；退出码固定 `0/2/3/4`。

## 多 Agent / 多模型

`install.sh --target`：

| target | 写入位置 |
|---|---|
| `dsh` | `~/.dsh/skills/vps-vpn-setup` |
| `claude` | `~/.claude/skills/vps-vpn-setup` + `~/.claude/commands/vpn.md` |
| `agents` | `~/.agents/skills/vps-vpn-setup`（共享根） |
| `codex` | `~/.codex/AGENTS.md` + `~/.codex/prompts/vpn.md` |
| `cursor` | `<project>/.cursor/rules/vps-vpn-setup.mdc` + `AGENTS.md` |
| `gemini` | `~/.gemini/commands/vpn.toml` + `<project>/GEMINI.md` |
| `copilot` | `<project>/.github/prompts/vpn.prompt.md` + `copilot-instructions.md` |

纯聊天模型（ChatGPT/Claude/DeepSeek/Kimi/Qwen/GLM 网页版）用 [`assets/prompts/chat-only.md`](assets/prompts/chat-only.md)；自建 API 集成用 [`assets/prompts/system-prompt.md`](assets/prompts/system-prompt.md)。完整矩阵见 [`references/agent-adapters.md`](references/agent-adapters.md)。

## 验证

```bash
bash tests/smoke.sh                     # 本机，不需要 VPS；300 项断言
bash scripts/vpnctl doctor              # 目标机自检
bash scripts/remote.sh test root@IP     # 一次性 VPS 上的完整生命周期验收
```

完整路线（本机 → VPS → 手机真机）见 [`TESTING.md`](TESTING.md)。

测试覆盖：语法、frontmatter、CLI 退出码、JSON 转义、URL 编码、客户端名校验、5 种后端的配置渲染与 URI 生成、订阅生成（Clash/base64）、一键与多节点 dry-run 无副作用。

## 平台支持

- 服务端：Debian/Ubuntu、RHEL/Rocky/Alma/Fedora、Arch、openSUSE、Alpine（systemd 或 OpenRC）
- 脚本运行环境：bash 3.2+（macOS 开发机 / 老 LTS 发行版）
- 客户端：WireGuard 官方 App、v2rayN/NG、NekoBox、Shadowrocket、sing-box、mihomo、Karing

## 边界

- 不自动化 Tailscale/Headscale、OpenVPN、3x-ui/Marzban 面板（见 references 的替代方案说明）。
- 订阅只生成本地文件，不内置 HTTP 托管：把它暴露成公网链接等同于公开密码，需要时自行加认证/Worker。
- 不提供「翻墙合法性」判断；使用前确认当地法律与云厂商 AUP。
- 自签证书的 Hysteria2 需要客户端 `insecure` 或 pin，安全性弱于 ACME 真证书。
