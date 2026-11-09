#!/usr/bin/env bash
# 仓库根目录的快捷方式：真正的实现放在 vps-vpn-setup/scripts/autopilot.sh，
# 这样 vps-vpn-setup 这个 Skill 包是自包含的，单独拷走也能用。
exec bash "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vps-vpn-setup/scripts/autopilot.sh" "$@"
