# VPS AutoOPs Agent

给 AI Agent 用的 VPS 自动化运维 Skill 集合。每个 Skill 都是一个自包含目录：Markdown 指令 + 可移植 shell 脚本 + 参考文档 + 自测。

针对 **DeepSeek Harness** 优化（技能自动发现、`/vps-vpn-setup` 直接调用），同时兼容 Claude Code、Codex、Cursor、Gemini CLI —— 内容层不绑定任何宿主。

## 已包含

| Skill | 作用 | 状态 |
|---|---|---|
| [`vps-provision/`](vps-provision/README.md) | 创建云主机（Vultr API）：区域/套餐查询、建机、等 SSH、快照、销毁，一条 `go` 命令完成建机 + 配置 | ✅ 52 项测试 |
| [`vps-vpn-setup/`](vps-vpn-setup/README.md) | 部署与运维 VPN（WireGuard / Xray REALITY / SS2022 / Hysteria2 / Trojan），多节点 + 订阅交付、分流规则、接管已有节点、防锁死加固 | ✅ 222 项测试 |

> **使用边界**：本仓库仅供个人在自己拥有或获授权的服务器上使用。请自行确认所在地法律、云厂商服务条款允许该用途；作者不对使用后果负责。详见 [SECURITY.md](SECURITY.md)。

## 粘一段话给任意 Agent

不想记命令？把 [`ENTRY-PROMPT.md`](vps-vpn-setup/assets/ENTRY-PROMPT.md) 里的提示词整段粘给 Codex / Claude Code / Cursor / DSH，Agent 会自己：问齐信息 → 连 SSH → 只读体检 → 要授权 → 部署 → 交付订阅链接。

## 快速开始

```bash
# 1) 让 Agent 发现这两个 Skill
./install.sh --dry-run
./install.sh

# 2) 自测（不联网、不花钱）
bash vps-provision/tests/smoke.sh
bash vps-vpn-setup/tests/smoke.sh

# 3) 一次性：粘贴 API Key（隐藏输入，自动校验）
bash vps-provision/scripts/vpsctl setup-key

# 4) 之后每次一句话：建机 + 装 VPN + 套你的规则 + 拉回配置
bash vps-provision/scripts/vpsctl go --purpose chatgpt --yes
```

已经有机器的（跳过创建）：

```bash
cd vps-vpn-setup
bash scripts/remote.sh deploy root@<VPS_IP> --cn --client phone
```

需要分步控制时：`remote.sh push` → `remote.sh run ... probe --json` → `install` → `harden` → `client add` → `verify`。

## 设计约定

所有 Skill 遵循同一套约定，便于 Agent 与不同模型复用：

- 单一命令入口，`--json` 输出、固定退出码、`--dry-run` 无副作用；
- 先只读 `probe`/`plan`，再改主机；改动幂等、可回滚；
- 密钥只落文件，不进 stdout 与对话；
- 文档与实现由冒烟测试对账（`tests/smoke.sh`）。
