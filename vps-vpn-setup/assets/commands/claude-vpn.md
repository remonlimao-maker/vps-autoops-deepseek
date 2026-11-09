---
description: 在 VPS 上部署或排障 VPN（WireGuard / Xray REALITY / SS2022 / Hysteria2）
argument-hint: "[wireguard|xray-reality|ss2022|hysteria2] [目标主机 user@ip]"
---

# /vpn — VPS VPN 部署

按 `vps-vpn-setup/SKILL.md` 执行。参数：$ARGUMENTS

先读 `vps-vpn-setup/SKILL.md` 的「硬性安全规则」和「标准流程」，然后：

1. 后端：参数里给了就用；没给则按 `references/protocol-selection.md` 判断（UDP 可用 → wireguard；需要抗封锁 → xray-reality；弱网 → hysteria2）。
2. 如果目标是远程主机且本机有 ssh：
   ```bash
   bash vps-vpn-setup/scripts/remote.sh push <target>
   bash vps-vpn-setup/scripts/remote.sh run  <target> probe --json
   ```
   否则在当前主机直接 `bash vps-vpn-setup/scripts/vpnctl probe --json`。
3. 依次执行 probe → plan → install → harden → client add → verify。
4. 最后向我汇报：后端与端口、客户端文件名与导入方式、`verify --json` 的真实输出、回滚命令。

约束：不要输出任何私钥；不要跳过 verify；SSH 改动必须带自动回滚并等我确认。
