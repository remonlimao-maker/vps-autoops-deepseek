## VPS VPN 自动化（vps-vpn-setup）

当任务涉及「在 VPS 上装/改 VPN、给设备发配置、排查连不上」时，使用项目内 `vps-vpn-setup/` 这套 Skill，不要从零手写配置。

入口：`bash <skill-dir>/scripts/vpnctl`（`<skill-dir>` = 本仓库的 `vps-vpn-setup/`）。

固定流程：

```bash
vpnctl probe --json        # 1. 只读盘点：OS/虚拟化/端口/防火墙/公网 IP
vpnctl plan <backend>      # 2. 看计划，不执行
vpnctl install <backend> --yes
vpnctl harden --no-ssh     # 3. 放行端口（必要时再去掉 --no-ssh 加固 SSH）
vpnctl client <backend> add --name <device> --yes
vpnctl verify <backend> --json   # 4. ok:true 才算完成
```

后端：`wireguard`（默认/最快）、`xray-reality`（抗封锁/TCP443）、`ss2022`（兼容广）、`hysteria2`（弱网/UDP）。

必须遵守：

1. 先 `probe`/`plan` 再改主机；不要直接编辑 `/etc/wireguard`、`/usr/local/etc/xray` 下的文件，重跑 `install` 重新渲染。
2. 不要在回答或日志里输出私钥、UUID、密码；配置写到文件，用 `scp`/二维码交付。
3. 改 SSH 端口必须用 `vpnctl harden --ssh-port N`（自带 5 分钟自动回滚），确认连通后 `vpnctl harden --confirm`。
4. 没有 `authorized_keys` 时不要关闭密码登录。
5. 失败先看 `references/troubleshooting.md`，不要猜；不要用 `curl | bash` 装第三方脚本。
6. 完成的标准是 `vpnctl verify --json` 的 `ok:true`，不是「服务启动了」。

详细规则见 `vps-vpn-setup/SKILL.md`。
