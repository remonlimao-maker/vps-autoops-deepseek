# 多 Agent / 多模型适配

本 Skill 刻意做成「内容无关宿主」：正文是 Markdown，能力是纯 shell 脚本，没有绑定任何 Agent 的 API、插件协议或函数签名。任何能读文件、能执行命令的宿主都能用。

## 1. 三种接入层级

| 层级 | 宿主的执行能力 | 使用方式 | 典型产品 |
|---|---|---|---|
| A 全自动 | 能执行 shell（本地或 SSH） | Agent 直接调 `scripts/vpnctl` | DSH、Claude Code、Codex CLI、Cursor Agent、Gemini CLI、Copilot Agent、Windsurf、Cline、opencode |
| B 半自动 | 只能在本机执行 shell，够不到 VPS | Agent 生成命令，用户复制执行；或让用户先 `remote.sh push` | 受限沙箱 Agent、只能读仓库的 IDE 助手 |
| C 纯对话 | 无 shell | 粘贴 `assets/prompts/chat-only.md`，按 runbook 人工执行 | ChatGPT/Claude/DeepSeek/Kimi/Qwen/GLM 网页版 |

降级原则：**能力不足时，输出可执行命令 + 期望输出 + 失败判据**，而不是假装执行。模型绝不应编造「已部署成功」。

## 2. 各宿主的发现路径

`install.sh` 会写这些位置；路径可能随版本变化，不确定时用 `--dry-run` 先看。

| 宿主 | Skill / 指令位置 | 本项目的安装目标 |
|---|---|---|
| DSH | `~/.dsh/skills/<name>/SKILL.md`、`<repo>/.dsh/skills/`、`~/.agents/skills/` | `dsh` |
| Claude Code | `~/.claude/skills/<name>/SKILL.md`、`<repo>/.claude/skills/` | `claude` |
| 通用 AGENTS.md 体系 | `<repo>/AGENTS.md`、`~/.codex/AGENTS.md`、部分工具读 `~/.agents/` | `codex`、`agents` |
| Cursor | `<repo>/.cursor/rules/*.mdc`、`AGENTS.md`；全局规则在设置里 | `cursor` |
| Gemini CLI | `<repo>/GEMINI.md`、`~/.gemini/commands/*.toml` | `gemini` |
| GitHub Copilot | `.github/copilot-instructions.md`、`.github/prompts/*.prompt.md` | `copilot` |
| Windsurf | `.windsurf/rules/*.md` | 用 `cursor` 产物改写 |
| Cline / Roo | `.clinerules`（文件或目录） | 用 `copilot` 产物改写 |
| Aider | `CONVENTIONS.md`（`--read` 载入） | 用 `codex` 产物 |
| OpenHands | `.openhands/microagents/*.md` | 手工复制 `assets/AGENTS.snippet.md` |

安装：

```bash
bash install.sh --target auto --dry-run     # 先看会写哪些文件
bash install.sh --target auto               # 自动探测
bash install.sh --target dsh,claude,codex   # 指定多个
bash install.sh --target all --mode copy    # 复制而非软链（跨机、跨用户）
```

软链适合「本仓库就是唯一真相源」；复制适合仓库会被移动、或目标机没有该路径。

## 3. 按模型能力分级指令

同一个 Skill，不同模型需要不同粒度的引导：

- **强推理 + 长上下文（Claude Opus/Sonnet、GPT 高级档、DeepSeek R1 类、Gemini Pro 类）**：直接读 SKILL.md，自主编排。要求先 `plan` 再 `install`，并解释选择。
- **中等能力、工具调用可靠（多数旗舰非推理模型）**：把 `SKILL.md` 的「标准流程」当固定脚本执行，不自由发挥；遇到错误必须查 `references/troubleshooting.md` 而不是猜测。
- **小模型 / 低上下文**：只给它三条命令（`probe` → `install` → `verify`）和一份「不要做什么」清单。不要让它读全部 references。
- **纯聊天**：用 `assets/prompts/chat-only.md`，要求它逐步给命令、等你贴回输出再给下一步。

写进 `AGENTS.md` 的通用约束（`assets/AGENTS.snippet.md` 已包含）：

1. 先 `probe`/`plan`，再改主机；
2. 不输出密钥到对话；
3. SSH 改动必须带自动回滚；
4. 完成以 `verify` 的 JSON 为准。

## 4. 跨模型的可移植技巧

- **命令即接口**：所有能力都有 CLI 形态，模型只需会拼命令，不需要理解实现。
- **JSON 输出**：`--json` 让结构化模型（和宿主 UI）能直接判断成功与否，不靠自然语言描述。
- **退出码语义固定**：`0/2/3/4`，见 SKILL.md。Agent 用退出码判断，不用猜日志。
- **幂等**：重试安全，模型犯错重跑不会放大破坏。
- **dry-run**：模型不确定时先跑 `--dry-run`，把风险暴露给用户。
- **单文件入口**：`vpnctl` 一个命令覆盖全流程，降低工具调用次数与参数错误率。

## 5. 各层级的验证闭环

| 层级 | Agent 必须证明的事 |
|---|---|
| A | 贴出 `verify --json` 的真实输出；失败则给出下一步命令 |
| B | 给出命令 + 期望输出片段 + 判据；要求用户回贴输出 |
| C | 每一步都让用户确认上一步输出，禁止一次性给完所有步骤 |

## 6. 反模式

- 让模型「大概记得」WireGuard 配置格式，然后手写一份与 `vpnctl` 状态不一致的配置。
- 在聊天里贴完整私钥「方便复制」。
- 不同宿主各维护一份分叉的脚本（本 Skill 用 `install.sh` 软链，避免分叉）。
- 用 `curl | bash` 或来源不明的镜像：`--mirror` 只接受指向官方 release 的代理。
- 跳过 `harden` 就宣称完成：端口没放行，客户端必然连不上。
