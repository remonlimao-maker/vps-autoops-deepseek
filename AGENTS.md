# Agent instructions — VPS AutoOPs Agent

本仓库是「给 Agent 用的 VPS 自动化 Skill 集合」，不是应用代码库。涉及 VPS VPN 任务时，先读对应 Skill 的 `SKILL.md`，再动手。

## 入口

| 任务 | 先读 | 工具入口 |
|---|---|---|
| 一句话建机 + 配置 | [`vps-provision/SKILL.md`](vps-provision/SKILL.md) | `vpsctl go --purpose chatgpt --yes` |
| 创建/销毁/快照云主机 | 同上 | `bash vps-provision/scripts/vpsctl` |
| 在 VPS 上装/改 VPN、发客户端配置、排障 | [`vps-vpn-setup/SKILL.md`](vps-vpn-setup/SKILL.md) | `bash vps-vpn-setup/scripts/vpnctl` |
| 从笔记本驱动远端 VPS | 同上「一键路径」 | `bash vps-vpn-setup/scripts/remote.sh` |
| 让 Agent 发现全部 Skill | [`README.md`](README.md) | `bash install.sh` |
| 粘一段话给任意 Agent | [`vps-vpn-setup/assets/ENTRY-PROMPT.md`](vps-vpn-setup/assets/ENTRY-PROMPT.md) | 复制其中的提示词 |

只读 / 规划类请求（写文档、review、解释协议）**不要**连 VPS、不要改主机。

## 不可违反

1. 改主机前先 `probe`（只读）和 `plan`（只读），确认端口、网段、SNI 与用户说的一致。
2. 私钥、UUID、PSK、订阅内容不进入对话、日志、Git；只给文件路径。
3. SSH 端口变更只能走 `vpnctl harden --ssh-port N`（先放行、再校验、挂 5 分钟自动回滚），确认连通后 `vpnctl harden --confirm`。
4. 没有 `authorized_keys` 时不得关闭密码登录，不得用 `--force-password-off` 绕过。
5. 破坏性操作前 `vpnctl backup`；`uninstall --purge` 需要用户明确同意。
6. 不执行 `curl | bash`，不从非官方源装二进制；`--mirror` 只接受指向官方 release 的代理。
7. 没有 shell 能力时，输出可执行命令 + 期望输出 + 失败判据，**不要假装已执行**。

## 完成标准

`vpnctl verify <backend> --json` 返回 `"ok": true`，且用户知道客户端文件在哪、怎么导入、怎么回滚。

「服务已启动」「端口在监听」都不是完成。安装 ≠ 验收。

## 本地检查（不需要 VPS）

```bash
bash vps-provision/tests/smoke.sh      # 52 项断言（假 API，不花钱）
bash vps-vpn-setup/tests/smoke.sh      # 235 项断言
bash vps-vpn-setup/scripts/vpnctl doctor
bash -n vps-provision/scripts/vpsctl vps-vpn-setup/scripts/vpnctl
```

改动脚本后必须跑 smoke；它只依赖 bash + python3，不碰真实系统。

## 仓库约定

- 两个 Skill 有明确分工：`vps-provision` 只碰云 API 与本地状态，`vps-vpn-setup` 只碰主机内部；跨 Skill 调用必须走对方的 CLI，不直接 source。
- 每个 Skill 一个目录，自包含（`SKILL.md` + `scripts/` + `references/` + `assets/` + `tests/`）。
- 对外只暴露一个命令入口；`--json` 给机器、stderr 给人、退出码固定 `0/2/3/4`。
- 文档与实现由 `tests/smoke.sh` 对账，改了参数就补断言。
- 安全边界写在 `SECURITY.md`。
