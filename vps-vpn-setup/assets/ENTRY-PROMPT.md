# 入口提示词（粘给任意 Agent）

把下面整段复制给 Codex / Claude Code / Cursor / DSH / Gemini CLI 等任意能执行命令的 Agent。
它不依赖具体厂商——Skill 本身是 Markdown + shell 脚本。

---

## 中文版（推荐）

> 请用这个 Skill 帮我自动搭建自己的 VPN 节点：
> **`<仓库地址或本地绝对路径>`**
>
> 步骤：
> 1. 读取完整目录，先读 `AGENTS.md`，再读 `vps-provision/SKILL.md` 与 `vps-vpn-setup/SKILL.md`，以及 `vps-vpn-setup/references/intake.md`。
> 2. 按 `intake.md` **一次问完**我需要的 VPS 信息，不要一条条挤牙膏；能填默认值的先填好再让我确认。
> 3. 先帮我连好 SSH：`bash vps-vpn-setup/scripts/remote.sh connect root@<IP>`，确认密钥登录、sudo、系统版本都可用。
> 4. 跑**只读**检查：`probe`、`plan`、`check-sites`，把「将要改什么、风险是什么、怎么回滚」列给我，**等我授权**。
> 5. 拿到授权后连续执行完整部署与验证，不要每一步都来问我；失败就按 `references/troubleshooting.md` 处理。
> 6. 最后交付：订阅链接（或文件路径）+ **按我的系统给出客户端安装和导入步骤**（Mac/Windows/Linux/手机）+ 验证方法 + 一条回滚命令。
>
> 约束：
> - 不要让我手动敲命令，你直接执行。
> - 不要把我的私钥、密码、订阅内容贴进对话或日志。
> - 没有我的授权，不要做销毁、改 SSH 端口等破坏性操作。

---

## English

> Set up my own VPN node automatically using this skill at **`<repo url or absolute path>`**.
>
> 1. Read the whole bundle: `AGENTS.md`, then `vps-provision/SKILL.md`, `vps-vpn-setup/SKILL.md` and `vps-vpn-setup/references/intake.md`.
> 2. Ask me everything you need about the VPS **in one message**, with defaults pre-filled from `intake.md`.
> 3. Establish SSH first: `bash vps-vpn-setup/scripts/remote.sh connect root@<IP>` and confirm key auth, sudo and OS.
> 4. Run the read-only checks (`probe`, `plan`, `check-sites`), then show me exactly what will change, the risks and the rollback, and **wait for my authorization**.
> 5. After authorization, execute the full deployment and verification without asking at every step; use `references/troubleshooting.md` if something fails.
> 6. Deliver: the subscription link (or file path), **client install + import steps for my OS** (macOS/Windows/Linux/mobile), how to verify, and one rollback command.
>
> Rules: do not make me type commands; never print private keys, passwords or subscription bodies; no destructive action (destroy, SSH port change) without my explicit approval.

---

## 没有 VPS 的情况

把第 2 步换成：

> 我还没有服务器。请用 `vps-provision` 帮我建一台：需要我的 Vultr API Key（Read & Write），先跑
> `vpsctl setup-key` 让我粘贴，然后用 `vpsctl go --purpose chatgpt --region <区域> --yes` 一条命令完成。

## 为什么这样写就能移植

| 设计 | 作用 |
|---|---|
| 提示词只指向**目录**，不指向某个 Agent 的 API | 换宿主不用改写 |
| 第 1 步明确「先读哪个文件」 | 不依赖自动发现机制 |
| 第 2 步引用 `intake.md` | 提问方式统一，不会每个 Agent 问得不一样 |
| 第 4 步要求「列变更 + 等授权」 | 把安全审查变成流程的一部分 |
| 第 6 步固定交付物 | 结果可核对 |
| 所有能力都是 CLI | Agent 只需要会执行命令 |

## 落地检查清单

Agent 做完后，用这三条自查：

```bash
vpnctl verify <backend> --json     # "ok": true
vpnctl check-sites                 # 目标站点可达
vpnctl harden --status             # 端口已放行
```

三者都对，才算交付完成。
