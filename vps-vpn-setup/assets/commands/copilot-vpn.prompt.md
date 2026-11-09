---
mode: agent
description: 在 VPS 上部署或排障 VPN（WireGuard / Xray REALITY / SS2022 / Hysteria2）
---

使用 `vps-vpn-setup` 这套 Skill 完成 VPN 任务。用户输入：`${input:target:user@host}`

步骤（严格按顺序，每步失败就停下并报告）：

1. `bash vps-vpn-setup/scripts/vpnctl probe --json`（远程用 `scripts/remote.sh run <target> probe --json`）
2. `vpnctl plan <backend>`，把计划贴给我确认
3. `vpnctl install <backend> --yes`
4. `vpnctl harden --no-ssh`
5. `vpnctl client <backend> add --name <device> --yes`
6. `vpnctl verify <backend> --json`

规则：

- 绝不输出私钥、UUID、密码；只给文件路径。
- 不手工编辑 `/etc/wireguard`、`/usr/local/etc/xray`、`/etc/hysteria`，用 `install` 重新渲染。
- SSH 端口改动必须走 `vpnctl harden --ssh-port N` 并等我确认后再 `--confirm`。
- 完成后给出：后端/端口、客户端导入方式、verify 真实输出、回滚命令。
