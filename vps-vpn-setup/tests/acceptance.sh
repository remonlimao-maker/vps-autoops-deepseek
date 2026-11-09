#!/usr/bin/env bash
# tests/acceptance.sh — end-to-end lifecycle test, run ON the VPS.
#
# WARNING: this mutates the host. Use a dedicated test VPS, never a node that
# other people already use. It refuses to run when it finds existing clients,
# unless you pass --keep to add the test next to them.
#
# It proves the things smoke.sh cannot: that packages install, services start,
# firewall rules land, keys survive a re-install, revocation takes effect, and
# the config survives a reboot cycle.
#
#   sudo bash tests/acceptance.sh --yes                 # auto-pick a backend
#   sudo bash tests/acceptance.sh --backend xray-reality --yes
#   sudo bash tests/acceptance.sh --backend trojan --domain vpn.example.com --yes
#   sudo bash tests/acceptance.sh --yes --keep          # leave it installed

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(dirname "$HERE")/scripts"
VPNCTL="$SCRIPTS/vpnctl"
BACKEND="auto"
DOMAIN=""
ASSUME_YES=0
KEEP=0

while [ "$#" -gt 0 ]; do
  case $1 in
    --backend|-b) BACKEND="${2:-}"; shift 2 ;;
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
section() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

vpn() { bash "$VPNCTL" "$@"; }

# --- preconditions ---------------------------------------------------------
[ "$(uname -s)" = "Linux" ] || { printf 'run this on the VPS, not on your laptop\n' >&2; exit 2; }
[ "$(id -u)" = "0" ] || { printf 'root required: sudo bash %s\n' "$0" >&2; exit 2; }
[ -x "$SCRIPTS/vpnctl" ] || [ -r "$SCRIPTS/vpnctl" ] || { printf 'cannot find %s\n' "$VPNCTL" >&2; exit 2; }

# shellcheck source=../scripts/lib/common.sh
. "$SCRIPTS/lib/common.sh"
BACKENDS="wireguard xray-reality ss2022 hysteria2 trojan"

# Local firewall probe (harden.sh is not sourced here on purpose: it defines
# command handlers we must not accidentally trigger).
fw_kind() {
  if have ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then printf 'ufw'
  elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then printf 'firewalld'
  elif have nft && nft list ruleset 2>/dev/null | grep -q 'hook input'; then printf 'nftables'
  elif have iptables; then printf 'iptables'
  else printf 'none'; fi
}

existing=0
for be in $BACKENDS; do
  [ -n "$(meta_get "$be" PORT)" ] || continue
  c="$(client_count "$be")"
  existing=$((existing + c))
done

if [ "$existing" -gt 0 ] && [ "$KEEP" != "1" ]; then
  printf '\033[31mThis host already has %s client(s) on an installed backend.\033[0m\n' "$existing" >&2
  printf 'Run this on a throwaway VPS, or pass --keep to add the test next to them.\n' >&2
  exit 3
fi

if [ "$ASSUME_YES" != "1" ]; then
  printf 'This will install, restart and uninstall VPN services on THIS host.\n'
  printf 'Type "yes" to continue: '
  read -r answer
  [ "$answer" = "yes" ] || { printf 'aborted\n'; exit 2; }
fi

printf '\nacceptance run: backend=%s host=%s\n' "$BACKEND" "$(hostname)"

# --- 1. probe --------------------------------------------------------------
section "1. probe (read-only)"
probe_json="$(vpn probe --json 2>/dev/null)"
if printf '%s' "$probe_json" | grep -q '"schema": 1' && printf '%s' "$probe_json" | grep -q '"host"'; then
  ok "probe --json reports the documented shape"
else
  bad "probe --json reports the documented shape" "got: $(printf '%s' "$probe_json" | head -c 120)"
fi
PUBIP="$(printf '%s' "$probe_json" | sed -n 's/.*"public_ipv4": "\([^"]*\)".*/\1/p')"
if [ -n "$PUBIP" ]; then ok "public IPv4 detected: $PUBIP"; else bad "public IPv4 detected"; fi

# --- 2. backend selection --------------------------------------------------
section "2. install"
if [ "$BACKEND" = "auto" ]; then
  if [ -c /dev/net/tun ] && (modprobe -n wireguard >/dev/null 2>&1 || [ -d /sys/module/wireguard ]); then
    BACKEND="wireguard"
  else
    BACKEND="xray-reality"
  fi
  printf '  auto-selected: %s\n' "$BACKEND"
fi

install_args=(install "$BACKEND" --yes)
[ -n "$DOMAIN" ] && install_args+=(--domain "$DOMAIN")
if vpn "${install_args[@]}" >/dev/null 2>&1; then
  ok "install $BACKEND"
else
  bad "install $BACKEND" "run it manually to see why: vpnctl install $BACKEND --yes"
  printf '\nacceptance aborted: nothing else can be tested.\n'
  exit 4
fi

# --- 3. verify -------------------------------------------------------------
section "3. verify"
if vpn verify "$BACKEND" --json 2>/dev/null | grep -q '"ok": *true'; then
  ok "verify reports ok=true"
else
  bad "verify reports ok=true" "$(vpn verify "$BACKEND" --json 2>&1 | tail -n 3)"
fi

SERVICE="$(meta_get "$BACKEND" SERVICE)"
if svc_active "$SERVICE"; then ok "service $SERVICE is active"; else bad "service $SERVICE is active"; fi
if systemd_present && systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
  ok "service $SERVICE is enabled (survives reboot)"
else
  bad "service $SERVICE is enabled (survives reboot)"
fi

PORT="$(meta_get "$BACKEND" PORT)"
PROTO="$(meta_get "$BACKEND" PROTO)"; [ -n "$PROTO" ] || PROTO="any"
if port_listening "$PORT" "$PROTO"; then ok "listening on $PORT/$PROTO"; else bad "listening on $PORT/$PROTO"; fi

# --- 4. firewall -----------------------------------------------------------
section "4. firewall"
if vpn harden --no-ssh >/dev/null 2>&1; then
  ok "harden --no-ssh completed"
else
  bad "harden --no-ssh completed"
fi
case $(fw_kind) in
  ufw) ufw status 2>/dev/null | grep -qE "^${PORT}" && ok "ufw allows $PORT" || bad "ufw allows $PORT" ;;
  firewalld) firewall-cmd --list-ports 2>/dev/null | grep -q "$PORT" && ok "firewalld allows $PORT" || bad "firewalld allows $PORT" ;;
  nftables) nft list ruleset 2>/dev/null | grep -q "dport $PORT" && ok "nftables allows $PORT" || bad "nftables allows $PORT" ;;
  iptables) iptables -w -S INPUT 2>/dev/null | grep -q "dport $PORT" && ok "iptables allows $PORT" || bad "iptables allows $PORT" ;;
  *) printf '  SKIP no host firewall detected (cloud security group still matters)\n' ;;
esac

# --- 5. client lifecycle ---------------------------------------------------
section "5. client lifecycle"
vpn client "$BACKEND" add --name acc-test --yes >/dev/null 2>&1
if client_exists "$BACKEND" "acc-test"; then ok "client acc-test created"; else bad "client acc-test created"; fi

CLIENT_DIR="${HOME:-/root}/vpn-clients/$BACKEND/acc-test"
if [ -d "$CLIENT_DIR" ] && [ -n "$(ls -A "$CLIENT_DIR" 2>/dev/null)" ]; then
  ok "client artifacts exported to $CLIENT_DIR"
else
  bad "client artifacts exported" "expected: $CLIENT_DIR"
fi

perm_ok=1
for f in "$CLIENT_DIR"/*; do
  [ -f "$f" ] || continue
  case $(ls -l "$f" | awk '{print $1}') in
    -rw-------*) ;;
    *) perm_ok=0; printf '       %s is %s\n' "$f" "$(ls -l "$f" | awk '{print $1}')" ;;
  esac
done
if [ "$perm_ok" = "1" ]; then ok "client files are 0600"; else bad "client files are 0600"; fi

# --- 6. idempotency --------------------------------------------------------
section "6. idempotency (re-run install, keys must survive)"
case $BACKEND in
  wireguard) key_before="$(meta_get wireguard PUBKEY)" ;;
  xray-reality) key_before="$(meta_get xray-reality PUBKEY)" ;;
  hysteria2) key_before="$(meta_get hysteria2 CERT_SHA256)" ;;
  trojan) key_before="$(meta_get trojan CERT_SOURCE)" ;;
  *) key_before="$(meta_get "$BACKEND" PORT)" ;;
esac
vpn install "$BACKEND" --yes >/dev/null 2>&1
case $BACKEND in
  wireguard) key_after="$(meta_get wireguard PUBKEY)" ;;
  xray-reality) key_after="$(meta_get xray-reality PUBKEY)" ;;
  hysteria2) key_after="$(meta_get hysteria2 CERT_SHA256)" ;;
  trojan) key_after="$(meta_get trojan CERT_SOURCE)" ;;
  *) key_after="$(meta_get "$BACKEND" PORT)" ;;
esac
if [ -n "$key_before" ] && [ "$key_before" = "$key_after" ]; then
  ok "re-install kept the server identity ($key_before)"
else
  bad "re-install kept the server identity" "before=[$key_before] after=[$key_after]"
fi
if client_exists "$BACKEND" "acc-test"; then ok "re-install kept the client"; else bad "re-install kept the client"; fi
if vpn verify "$BACKEND" --json 2>/dev/null | grep -q '"ok": *true'; then
  ok "still healthy after re-install"
else
  bad "still healthy after re-install"
fi

# --- 7. revocation ---------------------------------------------------------
section "7. revocation"
vpn client "$BACKEND" add --name acc-temp --yes >/dev/null 2>&1
tmp_id="$(client_get "$BACKEND" acc-temp UUID)"
[ -n "$tmp_id" ] || tmp_id="$(client_get "$BACKEND" acc-temp PSK)"
[ -n "$tmp_id" ] || tmp_id="$(client_get "$BACKEND" acc-temp PASSWORD)"
[ -n "$tmp_id" ] || tmp_id="$(client_get "$BACKEND" acc-temp PUBKEY)"
vpn client "$BACKEND" remove --name acc-temp --yes >/dev/null 2>&1
if client_exists "$BACKEND" "acc-temp"; then
  bad "client record removed"
else
  ok "client record removed"
fi
leaked=0
if [ -n "$tmp_id" ]; then
  grep -rqs -- "$tmp_id" /etc/vpnctl/"$BACKEND" 2>/dev/null && leaked=1
  cfg_tmp="$(meta_get "$BACKEND" CONFIG)"
  if [ -n "$cfg_tmp" ] && [ -f "$cfg_tmp" ]; then grep -qs -- "$tmp_id" "$cfg_tmp" && leaked=1; fi
  if [ -f /etc/wireguard/"$(meta_get wireguard IFACE 2>/dev/null || echo wg0)".conf ]; then
    grep -qs -- "$tmp_id" /etc/wireguard/*.conf 2>/dev/null && leaked=1
  fi
fi
if [ "$leaked" = "1" ]; then bad "revoked credential gone from state and config"; else ok "revoked credential gone from state and config"; fi
if vpn verify "$BACKEND" --json 2>/dev/null | grep -q '"ok": *true'; then ok "healthy after revocation"; else bad "healthy after revocation"; fi

# --- 8. restart resilience -------------------------------------------------
section "8. service restart"
if systemd_present; then
  systemctl restart "$SERVICE"
  sleep 2
  if svc_active "$SERVICE"; then ok "service came back after restart"; else bad "service came back after restart"; fi
  if vpn verify "$BACKEND" --json 2>/dev/null | grep -q '"ok": *true'; then ok "verify passes after restart"; else bad "verify passes after restart"; fi
else
  printf '  SKIP no systemd\n'
fi

# --- 9. config drift -------------------------------------------------------
section "9. config re-render"
cfg="$(meta_get "$BACKEND" CONFIG)"
if [ -n "$cfg" ] && [ -f "$cfg" ]; then
  if vpn install "$BACKEND" --yes >/dev/null 2>&1 && [ -s "$cfg" ]; then
    ok "config re-rendered at $cfg"
  else
    bad "config re-rendered at $cfg"
  fi
else
  printf '  SKIP this backend keeps no single config file\n'
fi

# --- 10. teardown ----------------------------------------------------------
section "10. teardown"
if [ "$KEEP" = "1" ]; then
  printf '  SKIP --keep: leaving %s installed with client acc-test\n' "$BACKEND"
  printf '  remove later with: vpnctl uninstall %s --yes && vpnctl uninstall %s --purge\n' "$BACKEND" "$BACKEND"
else
  if vpn uninstall "$BACKEND" --yes >/dev/null 2>&1; then ok "uninstall completed"; else bad "uninstall completed"; fi
  if systemd_present && svc_active "$SERVICE"; then bad "service stopped"; else ok "service stopped"; fi
  if vpn uninstall "$BACKEND" --purge --yes >/dev/null 2>&1; then ok "purge completed"; else bad "purge completed"; fi
  if [ -d "/etc/vpnctl/$BACKEND" ]; then bad "state purged"; else ok "state purged"; fi
fi

# --- summary ---------------------------------------------------------------
printf '\n%s\n' "----------------------------------------"
printf 'acceptance: %s passed, %s failed  (backend: %s)\n' "$PASS" "$FAIL" "$BACKEND"
if [ "$FAIL" -gt 0 ]; then
  printf '\nCollect evidence before retrying:\n'
  printf '  vpnctl probe --json\n  vpnctl verify %s --json\n  journalctl -u %s -n 80 --no-pager\n' "$BACKEND" "$SERVICE"
  exit 1
fi
printf '\nThis host is proven to install, verify, survive re-install and revoke.\n'
printf 'Still needs a human: import the client config on a device and browse.\n'
