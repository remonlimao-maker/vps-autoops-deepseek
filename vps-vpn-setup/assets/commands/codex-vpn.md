Deploy or troubleshoot a VPN on a Linux VPS using the vps-vpn-setup skill.

Arguments: $ARGUMENTS

Follow vps-vpn-setup/SKILL.md exactly. Non-negotiable rules:

1. Read-only first: run `probe --json`, then `plan <backend>`. Never change the host before both.
2. Never print private keys, UUIDs or passwords. Write client configs to files under ~/vpn-clients and tell me the paths.
3. Any SSH change must go through `vpnctl harden --ssh-port N` (it schedules an automatic 5-minute rollback). Enter a new SSH session and verify before `vpnctl harden --confirm`.
4. Do not disable password auth without an authorized_keys file present.
5. Do not edit /etc/wireguard, /usr/local/etc/xray or /etc/hysteria by hand; re-run `vpnctl install <backend>` to re-render.
6. Done means `vpnctl verify <backend> --json` reports "ok": true. Not "service started".

If this machine cannot reach the VPS, output the exact commands for me to run and wait for my output instead of pretending to execute them.

Report back: backend + port, client artifact paths + import method, the real verify output, and the rollback command.
