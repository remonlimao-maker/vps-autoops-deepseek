#!/usr/bin/env bash
# tests/smoke.sh — run on any dev machine (macOS or Linux) WITHOUT a VPS.
#
# It never touches the real system: state lives in a temp dir, HOME is
# redirected, and anything that would need root/Linux is expected to refuse.
#
#   bash tests/smoke.sh            # summary
#   bash tests/smoke.sh -v         # show every assertion

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$HERE")"
SCRIPTS="$SKILL_DIR/scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME"
export VPNCTL_STATE_DIR="$TMP/state"
export VPNCTL_BACKUP_DIR="$TMP/backups"
export VPNCTL_LIB_DIR="$TMP/lib"
export NO_COLOR=1

PASS=0; FAIL=0; SKIP=0
say()  { [ "$VERBOSE" = "1" ] && printf '  %s\n' "$*"; return 0; }
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
group() { printf '\n%s\n' "$1"; }

assert_eq() {
  local want="$1" got="$2" label="$3"
  if [ "$want" = "$got" ]; then pass "$label"; else fail "$label" "want=[$want] got=[$got]"; fi
}
assert_contains() {
  local hay="$1" needle="$2" label="$3"
  case $hay in *"$needle"*) pass "$label" ;; *) fail "$label" "missing: $needle" ;; esac
}
assert_exit() {
  local want="$1" label="$2"; shift 2
  "$@" >"$TMP/out" 2>"$TMP/err"; local got=$?
  if [ "$got" = "$want" ]; then pass "$label"; else fail "$label" "want exit $want, got $got: $(head -n 2 "$TMP/err")"; fi
}

# ---------------------------------------------------------------------------
group "1. syntax"
for f in "$SCRIPTS/vpnctl" "$SCRIPTS/remote.sh" "$SKILL_DIR/install.sh" "$HERE/acceptance.sh" "$SCRIPTS"/lib/*.sh; do
  if bash -n "$f" 2>"$TMP/err"; then pass "bash -n $(basename "$f")"; else fail "bash -n $(basename "$f")" "$(cat "$TMP/err")"; fi
done

# ---------------------------------------------------------------------------
group "2. SKILL.md frontmatter"
FM_NAME="$(sed -n '2,20s/^name:[[:space:]]*//p' "$SKILL_DIR/SKILL.md" | head -n 1)"
FM_DESC="$(sed -n '2,20s/^description:[[:space:]]*//p' "$SKILL_DIR/SKILL.md" | head -n 1)"
assert_eq "vps-vpn-setup" "$FM_NAME" "name is kebab-case and stable"
if [ -n "$FM_DESC" ]; then pass "description present"; else fail "description present" "frontmatter has no description"; fi
DESC_LEN=${#FM_DESC}
if [ "$DESC_LEN" -gt 0 ] && [ "$DESC_LEN" -le 500 ]; then
  pass "description length ${DESC_LEN} <= 500"
else
  fail "description length" "got $DESC_LEN (catalog cap is 500)"
fi
case $FM_DESC in *WireGuard*|*wireguard*) pass "description mentions the protocols" ;; *) fail "description mentions the protocols" ;; esac
if [ -f "$SKILL_DIR/SKILL.md" ] && [ "$(basename "$SKILL_DIR")" = "$FM_NAME" ]; then
  pass "bundle directory matches the skill name"
else
  fail "bundle directory matches the skill name" "dir=$(basename "$SKILL_DIR") name=$FM_NAME"
fi
for ref in references/protocol-selection.md references/agent-adapters.md references/troubleshooting.md \
           references/client-setup.md references/security-hardening.md references/operations.md references/extending.md; do
  if [ -f "$SKILL_DIR/$ref" ]; then pass "reference exists: $ref"; else fail "reference exists: $ref"; fi
done

# ---------------------------------------------------------------------------
group "3. CLI surface"
assert_exit 0 "vpnctl help exits 0" bash "$SCRIPTS/vpnctl" --help
assert_exit 0 "vpnctl version exits 0" bash "$SCRIPTS/vpnctl" version
assert_contains "$(bash "$SCRIPTS/vpnctl" version)" "vpnctl 1." "version string"
assert_exit 2 "unknown command exits 2" bash "$SCRIPTS/vpnctl" frobnicate
assert_exit 2 "unknown backend exits 2" bash "$SCRIPTS/vpnctl" plan not-a-backend
assert_exit 0 "plan wireguard works read-only" bash "$SCRIPTS/vpnctl" plan wireguard
assert_contains "$(bash "$SCRIPTS/vpnctl" plan wireguard)" "MASQUERADE" "plan mentions NAT"
assert_exit 2 "client list without install exits 2" bash "$SCRIPTS/vpnctl" client wireguard list
assert_exit 0 "install.sh --list runs" bash "$SKILL_DIR/install.sh" --list
assert_exit 0 "doctor runs" bash "$SCRIPTS/vpnctl" doctor

if [ "$(uname -s)" = "Linux" ]; then
  SKIP=$((SKIP + 1)); say "skipping non-Linux refusal tests on Linux"
else
  assert_exit 2 "probe refuses to run on $(uname -s)" bash "$SCRIPTS/vpnctl" probe
  assert_contains "$(bash "$SCRIPTS/vpnctl" probe 2>&1)" "requires Linux" "probe explains why it refused"
  assert_exit 2 "install refuses to run on $(uname -s)" bash "$SCRIPTS/vpnctl" install wireguard --yes
fi

# ---------------------------------------------------------------------------
group "4. shared library"
# shellcheck disable=SC1091
. "$SCRIPTS/lib/common.sh"

assert_eq '"a\"b"' "$(json_str 'a"b')" "json_str escapes double quotes"
assert_eq '"a\\b"' "$(json_str 'a\b')" "json_str escapes backslashes"
assert_eq '"a\nb"' "$(json_str "$(printf 'a\nb')")" "json_str escapes newlines"
printf '{"k":%s}\n' "$(json_str 'v"1')" > "$TMP/j.json"
if python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$TMP/j.json" 2>/dev/null; then
  pass "json_str output parses as JSON"
else
  fail "json_str output parses as JSON"
fi

assert_eq "a%20b" "$(urlencode 'a b')" "urlencode space"
assert_eq "a%2Fb" "$(urlencode 'a/b')" "urlencode slash"
assert_eq "abc-_.~" "$(urlencode 'abc-_.~')" "urlencode leaves unreserved chars"

assert_eq "phone" "$(validate_client_name 'phone')" "client name accepted"
assert_eq "phone" "$(validate_client_name 'PHONE')" "client name lowercased"
for bad in "has space" "has/slash" "-leading" "" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; do
  if ( validate_client_name "$bad" ) >/dev/null 2>&1; then
    fail "client name rejected: '$bad'"
  else
    pass "client name rejected: '${bad:-<empty>}'"
  fi
done

H="$(rand_hex 16)"
assert_eq "32" "${#H}" "rand_hex 16 gives 32 chars"

# ---------------------------------------------------------------------------
group "5. wireguard rendering"
# shellcheck disable=SC1091
. "$SCRIPTS/lib/backend-wireguard.sh"
WG_PORT=51820; WG_SUBNET="10.66.66.0/24"; WG_IFACE="wg0"; WG_MTU=1420
WG_DNS="1.1.1.1, 8.8.8.8"; WG_ROUTE_V6=0; WG_SPLIT=1
meta_init wireguard
meta_set wireguard PUBKEY "SERVERPUBKEY000000000000000000000000000000="
meta_set wireguard ENDPOINT "203.0.113.9:51820"
meta_set wireguard PUBLIC_IP "203.0.113.9"
meta_set wireguard SUBNET "10.66.66.0/24"
mkdir -p "$(dirname "$(wg_key_file wg0)")"
printf 'SERVERPRIVATEKEY000000000000000000000000000=' > "$(wg_key_file wg0)"
client_write wireguard phone \
  "ADDRESS=10.66.66.2" "ADDRESS6=fd42:66:66::2" \
  "PRIVKEY=CLIENTPRIVATEKEY0000000000000000000000000=" \
  "PUBKEY=CLIENTPUBKEY000000000000000000000000000000=" \
  "PSK=PRESHAREDKEY000000000000000000000000000000000=" \
  "CREATED=2026-01-01T00:00:00Z"

assert_eq "10.66.66.1" "$(wg_server_ip)" "server address derived from subnet"
assert_eq "24" "$(wg_prefix_len)" "prefix length derived from subnet"
# .2 and ::2 are taken by `phone`, so the allocator must skip them.
assert_eq "10.66.66.3" "$(wg_next_ip)" "allocator skips the address already in use"
assert_eq "fd42:66:66::3" "$(wg_next_ip6)" "v6 allocator skips the address already in use"

SRV="$(wg_render_server)"
assert_contains "$SRV" "ListenPort = 51820" "server config has the port"
assert_contains "$SRV" "Address = 10.66.66.1/24" "server config has the tunnel address"
assert_contains "$SRV" "PostUp =" "server config installs NAT on up"
assert_contains "$SRV" "AllowedIPs = 10.66.66.2/32" "server config scopes the peer to a /32"
assert_contains "$SRV" "[Peer]" "server config renders a peer block"

CLI="$(wg_client_conf phone full)"
assert_contains "$CLI" "AllowedIPs = 0.0.0.0/0" "full tunnel routes everything"
assert_contains "$CLI" "Endpoint = 203.0.113.9:51820" "client config has the endpoint"
assert_contains "$CLI" "PersistentKeepalive = 25" "client config keeps the tunnel alive"
CLI_SPLIT="$(wg_client_conf phone split)"
assert_contains "$CLI_SPLIT" "AllowedIPs = 10.66.66.0/24" "split tunnel only routes the subnet"
if printf '%s\n' "$SRV" | grep -q "PRESHAREDKEY"; then pass "PSK present in server peer"; else fail "PSK present in server peer"; fi

# ---------------------------------------------------------------------------
group "6. xray rendering (VLESS + REALITY)"
VPNCTL_STATE_DIR="$TMP/state"  # already exported; keep it explicit
# shellcheck disable=SC1091
. "$SCRIPTS/lib/backend-xray.sh"
BE_ID="xray-reality"; BE_VARIANT=""
XR_PORT=443; XR_SNI="www.microsoft.com"; XR_DEST="www.microsoft.com:443"
XR_FLOW="xtls-rprx-vision"; XR_FP="chrome"
meta_init xray-reality
meta_set xray-reality MODE "reality"
meta_set xray-reality PORT "443"
meta_set xray-reality SNI "www.microsoft.com"
meta_set xray-reality DEST "www.microsoft.com:443"
meta_set xray-reality FLOW "xtls-rprx-vision"
meta_set xray-reality FP "chrome"
meta_set xray-reality PUBLIC_IP "203.0.113.9"
meta_set xray-reality SHORT_ID "0123456789abcdef"
meta_set xray-reality PUBKEY "REALITYPUBLICKEYxxxxxxxxxxxxxxxxxxxxxxxxxxx"
mkdir -p "$(be_dir xray-reality)"
printf 'REALITYPRIVATEKEYxxxxxxxxxxxxxxxxxxxxxxxxxx' > "$(xr_server_key)"
printf 'REALITYPUBLICKEYxxxxxxxxxxxxxxxxxxxxxxxxxxx' > "$(xr_server_key).pub"
client_write xray-reality phone "UUID=b831381d-6324-4d53-ad4f-8cda48b30811" "CREATED=2026-01-01T00:00:00Z"

RX_JSON="$(xr_render_config)"
printf '%s\n' "$RX_JSON" > "$TMP/xray-reality.json"
if python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$TMP/xray-reality.json" 2>/dev/null; then
  pass "reality config is valid JSON"
else
  fail "reality config is valid JSON" "$(python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$TMP/xray-reality.json" 2>&1 | tail -n 1)"
fi
assert_contains "$RX_JSON" '"security": "reality"' "reality stream enabled"
assert_contains "$RX_JSON" '"flow": "xtls-rprx-vision"' "vision flow set"
assert_contains "$RX_JSON" '"dest": "www.microsoft.com:443"' "REALITY dest set"
assert_contains "$RX_JSON" '"id": "b831381d-6324-4d53-ad4f-8cda48b30811"' "client UUID injected"
assert_contains "$RX_JSON" '"port": 443' "port wired"

URI="$(xr_client_uri phone)"
assert_contains "$URI" "vless://b831381d-6324-4d53-ad4f-8cda48b30811@203.0.113.9:443" "reality URI prefix"
assert_contains "$URI" "security=reality" "reality URI security"
assert_contains "$URI" "pbk=REALITYPUBLICKEYxxxxxxxxxxxxxxxxxxxxxxxxxxx" "reality URI public key"
assert_contains "$URI" "sid=0123456789abcdef" "reality URI short id"

# ---------------------------------------------------------------------------
group "7. shadowsocks-2022 rendering"
BE_VARIANT="ss2022"; BE_ID="ss2022"
meta_init ss2022
XR_PORT=8388; XR_SS_METHOD="2022-blake3-aes-128-gcm"; XR_SS_SERVER_PSK=""
meta_set ss2022 MODE "ss2022"
meta_set ss2022 PORT "8388"
meta_set ss2022 PUBLIC_IP "203.0.113.9"
meta_set ss2022 SS_METHOD "2022-blake3-aes-128-gcm"
meta_set ss2022 SS_SERVER_PSK "U0VSVkVSUFNLMDAwMDAwMA=="
printf 'U0VSVkVSUFNLMDAwMDAwMA==' > "$(xr_server_key)"
client_write ss2022 laptop "PSK=Q0xJRU5UUFNLMDAwMDAwMA==" "CREATED=2026-01-01T00:00:00Z"

SS_JSON="$(xr_render_config)"
printf '%s\n' "$SS_JSON" > "$TMP/ss2022.json"
if python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$TMP/ss2022.json" 2>/dev/null; then
  pass "ss2022 config is valid JSON"
else
  fail "ss2022 config is valid JSON"
fi
assert_contains "$SS_JSON" '"protocol": "shadowsocks"' "shadowsocks inbound"
assert_contains "$SS_JSON" '"method": "2022-blake3-aes-128-gcm"' "2022 method"
assert_contains "$SS_JSON" '"password": "Q0xJRU5UUFNLMDAwMDAwMA=="' "client PSK listed"
assert_contains "$(xr_client_uri laptop)" "ss://" "ss URI scheme"
assert_contains "$(xr_client_uri laptop)" "203.0.113.9:8388" "ss URI endpoint"

# ---------------------------------------------------------------------------
group "8. hysteria2 rendering"
# shellcheck disable=SC1091
. "$SCRIPTS/lib/backend-hysteria2.sh"
HY_PORT=443; HY_SNI="203.0.113.9"; HY_OBFS="salamander"; HY_OBFS_PASS="obfspass123"
HY_INCLUDE_OBFS=1; HY_MASQUERADE="https://news.ycombinator.com/"
meta_init hysteria2
meta_set hysteria2 PORT "443"
meta_set hysteria2 SNI "203.0.113.9"
meta_set hysteria2 PUBLIC_IP "203.0.113.9"
meta_set hysteria2 OBFS "salamander"
meta_set hysteria2 OBFS_PASS "obfspass123"
meta_set hysteria2 OBFS_ENABLED "1"
meta_set hysteria2 MASQUERADE "https://news.ycombinator.com/"
client_write hysteria2 phone "PASSWORD=clientpass123" "CREATED=2026-01-01T00:00:00Z"

HYCONF="$(hy_render_config)"
assert_contains "$HYCONF" "listen: :443" "hysteria listens on the port"
assert_contains "$HYCONF" "type: userpass" "hysteria uses userpass auth"
assert_contains "$HYCONF" "phone: \"clientpass123\"" "hysteria lists the client"
assert_contains "$HYCONF" "type: salamander" "hysteria obfs enabled"
assert_contains "$HYCONF" "rewriteHost: true" "masquerade configured"

HY_URI="$(hy_client_uri phone 203.0.113.9)"
assert_contains "$HY_URI" "hysteria2://phone:clientpass123@203.0.113.9:443" "hysteria URI"
assert_contains "$HY_URI" "insecure=1" "hysteria URI marks the self-signed cert"
assert_contains "$HY_URI" "obfs-password=obfspass123" "hysteria URI carries obfs"

# ---------------------------------------------------------------------------
group "9. dry-run safety"
# Simulate a Linux kernel so the install path can be exercised without a VPS;
# a dry run must print the plan and create nothing.
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/uname" <<'FAKE'
#!/bin/sh
if [ "$1" = "-s" ]; then echo Linux; else exec /usr/bin/uname "$@"; fi
FAKE
chmod +x "$TMP/fakebin/uname"
DRY_STATE="$TMP/dry-state"
rm -rf "$DRY_STATE"
dry_out="$(PATH="$TMP/fakebin:$PATH" VPNCTL_STATE_DIR="$DRY_STATE" bash "$SCRIPTS/vpnctl" install wireguard --dry-run 2>&1)"
assert_contains "$dry_out" "Plan: WireGuard" "install --dry-run prints the plan"
assert_contains "$dry_out" "port 51820" "plan includes the effective port"
if [ -d "$DRY_STATE" ]; then fail "install --dry-run created state"; else pass "install --dry-run created no state"; fi
DRY_RUN=1
out="$(run rm -rf /definitely/not/real 2>&1)"
assert_contains "$out" "rm -rf /definitely/not/real" "run prints instead of executing in dry-run"
if [ -e /definitely/not/real ]; then fail "dry-run created nothing"; else pass "dry-run created nothing"; fi
DRY_RUN=0

# ---------------------------------------------------------------------------
group "10. probe JSON contract"
cat > "$TMP/fakebin/curl" <<'FAKECURL'
#!/bin/sh
case "$*" in *ip*) echo "203.0.113.77"; exit 0;; esac
exit 0
FAKECURL
cat > "$TMP/fakebin/ss" <<'FAKESS'
#!/bin/sh
exit 0
FAKESS
cat > "$TMP/fakebin/systemd-detect-virt" <<'FAKEVIRT'
#!/bin/sh
echo kvm
FAKEVIRT
cat > "$TMP/fakebin/ip" <<'FAKEIP'
#!/bin/sh
case "$*" in
  *"route show default"*) echo "default via 10.0.0.1 dev eth0 proto dhcp src 10.0.0.5";;
  *"addr show dev eth0"*) echo "    inet 10.0.0.5/24 brd 10.0.0.255 scope global eth0";;
esac
exit 0
FAKEIP
cat > "$TMP/fakebin/modprobe" <<'FAKEMOD'
#!/bin/sh
exit 0
FAKEMOD
chmod +x "$TMP/fakebin/curl" "$TMP/fakebin/ss" "$TMP/fakebin/systemd-detect-virt" "$TMP/fakebin/ip" "$TMP/fakebin/modprobe"

PROBE_STATE="$TMP/probe-state"
rm -rf "$PROBE_STATE"
probe_json="$(PATH="$TMP/fakebin:$PATH" VPNCTL_STATE_DIR="$PROBE_STATE" bash "$SCRIPTS/vpnctl" probe --json 2>/dev/null)"
printf '%s\n' "$probe_json" > "$TMP/probe.json"
if python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["schema"]==1;assert d["host"];assert d["network"]["public_ipv4"];assert isinstance(d["backends"],list)' "$TMP/probe.json" 2>/dev/null; then
  pass "probe --json is valid JSON with the documented shape"
else
  fail "probe --json is valid JSON with the documented shape"
fi
assert_contains "$probe_json" '"public_ipv4": "203.0.113.77"' "probe detects the public IPv4"
assert_contains "$probe_json" '"virt": "kvm"' "probe reports the virtualization"
assert_contains "$probe_json" '"backends": []' "probe reports no installed backends on a clean host"
if [ -d "$PROBE_STATE" ]; then fail "probe is read-only"; else pass "probe created no state"; fi

# ---------------------------------------------------------------------------
group "11. one-shot deployment"
FAKE_PATH="$TMP/fakebin:$PATH"
assert_contains "$(bash "$SCRIPTS/vpnctl" up --help 2>&1)" "one-shot deployment" "up --help documents the one-shot path"
assert_exit 2 "up rejects an unknown backend" env PATH="$FAKE_PATH" bash "$SCRIPTS/vpnctl" up --backend nope --dry-run

UP_STATE="$TMP/up-state"
rm -rf "$UP_STATE"
up_auto="$(PATH="$FAKE_PATH" VPNCTL_STATE_DIR="$UP_STATE" bash "$SCRIPTS/vpnctl" up --dry-run --client phone 2>&1)"
assert_contains "$up_auto" "auto-selected backend" "up auto-selects from host capabilities"
assert_contains "$up_auto" "Plan:" "up --dry-run prints a plan instead of acting"
if [ -d "$UP_STATE" ]; then fail "up --dry-run created no state"; else pass "up --dry-run created no state"; fi

up_wg="$(PATH="$FAKE_PATH" VPNCTL_STATE_DIR="$UP_STATE" bash "$SCRIPTS/vpnctl" up --dry-run --backend wireguard 2>&1)"
assert_contains "$up_wg" "Plan: WireGuard" "up honours an explicit --backend"
up_hy="$(PATH="$FAKE_PATH" VPNCTL_STATE_DIR="$UP_STATE" bash "$SCRIPTS/vpnctl" up --dry-run --backend hysteria2 2>&1)"
assert_contains "$up_hy" "Plan: Hysteria2" "up switches plans per backend"

assert_exit 2 "remote.sh deploy without a target exits 2" bash "$SCRIPTS/remote.sh" deploy
assert_contains "$(bash "$SCRIPTS/remote.sh" --help 2>&1)" "deploy" "remote.sh advertises deploy"

# ---------------------------------------------------------------------------
group "12. trojan backend"
BE_ID="trojan"
. "$SCRIPTS/lib/backend-trojan.sh"
XR_PORT=8443; BE_DOMAIN="vpn.example.com"; TJ_ALPN="http/1.1"
meta_init trojan
meta_set trojan MODE "trojan"
meta_set trojan PORT "8443"
meta_set trojan DOMAIN "vpn.example.com"
meta_set trojan ALPN "http/1.1"
meta_set trojan CERT_SOURCE "acme"
meta_set trojan PUBLIC_IP "203.0.113.9"
mkdir -p "$(be_dir trojan)/tls"
printf 'CERT' > "$(be_dir trojan)/tls/cert.pem"
printf 'KEY' > "$(be_dir trojan)/tls/key.pem"
client_write trojan phone "PASSWORD=tjpass123" "CREATED=2026-01-01T00:00:00Z"

TJ_JSON="$(xr_render_config)"
printf '%s\n' "$TJ_JSON" > "$TMP/trojan.json"
if python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$TMP/trojan.json" 2>/dev/null; then
  pass "trojan config is valid JSON"
else
  fail "trojan config is valid JSON"
fi
assert_contains "$TJ_JSON" '"protocol": "trojan"' "trojan inbound protocol"
assert_contains "$TJ_JSON" '"password": "tjpass123"' "trojan client password"
assert_contains "$TJ_JSON" '"security": "tls"' "trojan runs over TLS"
assert_contains "$TJ_JSON" 'cert.pem' "trojan points at its certificate"
assert_contains "$TJ_JSON" '"alpn": ["http/1.1"]' "trojan ALPN set"
assert_contains "$(xr_client_uri phone)" "trojan://tjpass123@vpn.example.com:8443" "trojan URI"
assert_contains "$(xr_client_uri phone)" "allowInsecure=0" "trojan URI verifies the CA for an ACME cert"

# ---------------------------------------------------------------------------
group "13. subscription generation"
SUB_STATE="$TMP/substate"
rm -rf "$SUB_STATE"; mkdir -p "$SUB_STATE"/{xray-reality,hysteria2,trojan}/clients
cat > "$SUB_STATE/xray-reality/meta.env" <<'M'
MODE=reality
PORT=443
PUBLIC_IP=203.0.113.9
SNI=www.microsoft.com
FLOW=xtls-rprx-vision
FP=chrome
PUBKEY=REALITYPUBxxxx
SHORT_ID=0123456789abcdef
M
printf 'UUID=b831381d-6324-4d53-ad4f-8cda48b30811\nCREATED=2026-01-01T00:00:00Z\n' > "$SUB_STATE/xray-reality/clients/phone.env"
cat > "$SUB_STATE/hysteria2/meta.env" <<'M'
PORT=443
PUBLIC_IP=203.0.113.9
SNI=203.0.113.9
OBFS=salamander
OBFS_PASS=obfspass123
OBFS_ENABLED=1
CERT_SOURCE=self-signed
M
printf 'PASSWORD=hypass123\nCREATED=2026-01-01T00:00:00Z\n' > "$SUB_STATE/hysteria2/clients/phone.env"
cat > "$SUB_STATE/trojan/meta.env" <<'M'
PORT=8443
DOMAIN=vpn.example.com
ALPN=http/1.1
CERT_SOURCE=acme
PUBLIC_IP=203.0.113.9
M
printf 'PASSWORD=tjpass123\nCREATED=2026-01-01T00:00:00Z\n' > "$SUB_STATE/trojan/clients/phone.env"

SUB_OUT="$TMP/subout"
sub_msg="$(VPNCTL_STATE_DIR="$SUB_STATE" bash "$SCRIPTS/vpnctl" sub --name phone --out "$SUB_OUT" 2>&1)"
assert_contains "$sub_msg" "3 node(s)" "sub reports all three nodes"
for f in clash.yaml uris.txt v2ray.txt info.txt; do
  if [ -s "$SUB_OUT/$f" ]; then pass "subscription file exists: $f"; else fail "subscription file exists: $f"; fi
done
CLASH="$(cat "$SUB_OUT/clash.yaml")"
assert_contains "$CLASH" "  - name: \"reality-phone\"" "clash has the reality node"
assert_contains "$CLASH" "    type: vless" "clash encodes REALITY as vless"
assert_contains "$CLASH" "      public-key: \"REALITYPUBxxxx\"" "clash carries reality-opts"
assert_contains "$CLASH" "    type: hysteria2" "clash has the hysteria2 node"
assert_contains "$CLASH" "    obfs-password: \"obfspass123\"" "clash carries obfs"
assert_contains "$CLASH" "    type: trojan" "clash has the trojan node"
assert_contains "$CLASH" 'proxies: ["reality-phone", "hy2-phone", "trojan-phone"]' "group lists every node"
assert_contains "$CLASH" "  - MATCH,PROXY" "rules fall through to the proxy group"
assert_contains "$CLASH" "dns:" "profile carries a DNS block (no leaks around the tunnel)"
assert_contains "$CLASH" "enhanced-mode: fake-ip" "profile uses fake-ip DNS"
assert_contains "$CLASH" "DOMAIN-SUFFIX,chatgpt.com,PROXY" "chatgpt is pinned to the tunnel"
assert_contains "$CLASH" "DOMAIN-SUFFIX,youtube.com,PROXY" "youtube is pinned to the tunnel"
assert_contains "$CLASH" "DOMAIN-SUFFIX,github.com,PROXY" "github is pinned to the tunnel"
assert_contains "$CLASH" "DOMAIN-SUFFIX,deepseek.com,DIRECT" "mainland AI services stay direct"
assert_contains "$CLASH" "GEOSITE,cn,DIRECT" "geosite fallback present"
assert_contains "$CLASH" "GEOIP,CN,DIRECT" "geoip fallback present"
assert_contains "$(cat "$SUB_OUT/info.txt")" "mode:    split" "subscription declares split mode"
if grep -q "$(printf '\t')" "$SUB_OUT/clash.yaml"; then fail "clash.yaml uses tabs"; else pass "clash.yaml uses spaces only"; fi
assert_eq "3" "$(wc -l < "$SUB_OUT/uris.txt" | tr -d ' ')" "one URI per node"
assert_contains "$(cat "$SUB_OUT/uris.txt")" "vless://" "uris contain vless"
assert_contains "$(cat "$SUB_OUT/uris.txt")" "hysteria2://" "uris contain hysteria2"
assert_contains "$(cat "$SUB_OUT/uris.txt")" "trojan://" "uris contain trojan"
decoded="$(base64 -d "$SUB_OUT/v2ray.txt" 2>/dev/null || base64 -D -i "$SUB_OUT/v2ray.txt" 2>/dev/null)"
assert_eq "$(cat "$SUB_OUT/uris.txt")" "$decoded" "v2ray.txt is the base64 encoding of uris.txt"
if [ "$(ls -l "$SUB_OUT/clash.yaml" | awk '{print $1}' | sed 's/@$//')" = "-rw-------" ]; then
  pass "subscription files are 600"
else
  fail "subscription files are 600" "$(ls -l "$SUB_OUT/clash.yaml" | awk '{print $1}')"
fi
global_out="$(VPNCTL_STATE_DIR="$SUB_STATE" bash "$SCRIPTS/vpnctl" sub --name phone --out "$TMP/subglobal" --global 2>&1)"
assert_contains "$(cat "$TMP/subglobal/clash.yaml")" "full tunnel" "--global switches to a full tunnel"
if grep -q "DOMAIN-SUFFIX,deepseek.com,DIRECT" "$TMP/subglobal/clash.yaml"; then
  fail "--global drops the mainland direct rules"
else
  pass "--global drops the mainland direct rules"
fi
assert_exit 2 "sub refuses a client that does not exist" env VPNCTL_STATE_DIR="$SUB_STATE" bash "$SCRIPTS/vpnctl" sub --name ghost --out "$TMP/none"

# ---------------------------------------------------------------------------
group "14. multi-node dry run"
multi="$(PATH="$TMP/fakebin:$PATH" VPNCTL_STATE_DIR="$TMP/multi-state" bash "$SCRIPTS/vpnctl" up --all --domain vpn.example.com --dry-run 2>&1)"
assert_contains "$multi" "would deploy REALITY" "up --all previews all nodes"
assert_contains "$multi" "Hysteria2 (443/udp)" "up --all puts hysteria2 on 443/udp"
assert_contains "$multi" "trojan" "up --all includes trojan when a domain is given"
if [ -d "$TMP/multi-state" ]; then fail "up --all --dry-run created no state"; else pass "up --all --dry-run created no state"; fi
alias_multi="$(PATH="$TMP/fakebin:$PATH" VPNCTL_STATE_DIR="$TMP/multi-state" bash "$SCRIPTS/vpnctl" up --backend all --dry-run 2>&1)"
assert_contains "$alias_multi" "would deploy REALITY" "--backend all is an alias for --all"

# ---------------------------------------------------------------------------
group "15. site reachability (check-sites)"
cat > "$TMP/fakebin/curl" <<'FAKECURL'
#!/bin/sh
has_w=0; url=""
for a in "$@"; do
  case "$a" in
    -w) has_w=1 ;;
    http*) url="$a" ;;
  esac
done
blocked="${FAKE_BLOCK:-0}"
if [ "$has_w" = "1" ]; then
  case "$url" in
    *api.openai.com*)
      if [ "$blocked" = "1" ]; then echo "403 0.200"; else echo "401 0.150"; fi ;;
    *) echo "200 0.100" ;;
  esac
  exit 0
fi
case "$url" in
  *api.openai.com*)
    if [ "$blocked" = "1" ]; then printf '{"error":{"code":"unsupported_country"}}'
    else printf '{"error":{"message":"no key provided"}}'; fi ;;
  *ip-api.com*) printf '{"countryCode":"%s"}' "${FAKE_COUNTRY:-JP}" ;;
  *cdn-cgi/trace*) printf 'ip=203.0.113.9\nloc=JP\nts=1\n' ;;
  *) printf '<html>ok</html>' ;;
esac
FAKECURL
chmod +x "$TMP/fakebin/curl"

ok_json="$(PATH="$TMP/fakebin:$PATH" bash "$SCRIPTS/vpnctl" check-sites --json 2>/dev/null)"
printf '%s\n' "$ok_json" > "$TMP/sites-ok.json"
if python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["verdict"]=="ok";assert len(d["sites"])==3' "$TMP/sites-ok.json" 2>/dev/null; then
  pass "check-sites --json parses and reports three sites"
else
  fail "check-sites --json parses" "$(head -c 160 "$TMP/sites-ok.json")"
fi
assert_contains "$ok_json" '"region":"JP"' "check-sites reports the Cloudflare region"
assert_contains "$ok_json" '"country":"JP"' "check-sites reports the host country"
assert_exit 0 "check-sites exits 0 when everything is reachable" env PATH="$TMP/fakebin:$PATH" bash "$SCRIPTS/vpnctl" check-sites

blocked_json="$(PATH="$TMP/fakebin:$PATH" FAKE_BLOCK=1 bash "$SCRIPTS/vpnctl" check-sites --json 2>/dev/null)"; blocked_rc=$?
assert_eq "5" "$blocked_rc" "check-sites exits 5 when ChatGPT is region-blocked"
assert_contains "$blocked_json" '"verdict":"chatgpt_blocked"' "check-sites names the ChatGPT block"

# ---------------------------------------------------------------------------
group "16. mainland China guard"
cn_json="$(PATH="$TMP/fakebin:$PATH" FAKE_COUNTRY=CN bash "$SCRIPTS/vpnctl" check-sites --json 2>/dev/null)"; cn_rc=$?
assert_eq "6" "$cn_rc" "a mainland server exits 6 (cannot be an exit node)"
assert_contains "$cn_json" '"verdict":"host_in_cn"' "check-sites names the mainland case"
assert_contains "$cn_json" '"status":"skipped"' "no pointless probing from a blocked host"

cn_text="$(PATH="$TMP/fakebin:$PATH" FAKE_COUNTRY=CN bash "$SCRIPTS/vpnctl" check-sites 2>&1)"
assert_contains "$cn_text" "cannot be your exit node" "the message says why, not just 'failed'"

cn_up="$(PATH="$TMP/fakebin:$PATH" VPNCTL_STATE_DIR="$TMP/cn-state" bash "$SCRIPTS/vpnctl" up --cn --dry-run 2>&1)"
assert_contains "$cn_up" "--cn: choosing REALITY" "up --cn prefers the TCP backend"
assert_contains "$cn_up" "Plan: xray-reality" "up --cn plans REALITY"
if [ -d "$TMP/cn-state" ]; then fail "up --cn --dry-run created no state"; else pass "up --cn --dry-run created no state"; fi

# ---------------------------------------------------------------------------
group "17. bring your own profile (--template)"
TPL="$TMP/my-profile.yaml"
cat > "$TPL" <<'YAML'
mixed-port: 7890
mode: rule
proxies:
  - name: "OLD-NODE"
    type: ss
    server: 127.0.0.1
    port: 1
proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "OLD-NODE"
      - "DIRECT"
  - name: "🤖 AI服务"
    type: select
    proxies:
      - "OLD-NODE"
      - "DIRECT"
rule-providers:
  gfw:
    type: http
    behavior: domain
    url: "https://example.invalid/gfw.txt"
    path: ./ruleset/gfw.yaml
rules:
  - DOMAIN-SUFFIX,deepseek.com,DIRECT
  - DOMAIN-KEYWORD,openai,🤖 AI服务
  - MATCH,🚀 节点选择
YAML

TPL_OUT="$TMP/sub-tpl"
tpl_msg="$(VPNCTL_STATE_DIR="$SUB_STATE" bash "$SCRIPTS/vpnctl" sub --name phone --out "$TPL_OUT" --template "$TPL" 2>&1)"
TPL_YAML="$(cat "$TPL_OUT/clash.yaml")"
assert_contains "$tpl_msg" "kept your rules" "template mode is announced"
if printf '%s' "$TPL_YAML" | grep -q "OLD-NODE"; then
  fail "old node removed from the proxies block"
else
  pass "old node removed from the proxies block"
fi
assert_contains "$TPL_YAML" '  - name: "reality-phone"' "generated node injected"
assert_contains "$TPL_YAML" '  - name: "hy2-phone"' "every backend is injected"
assert_contains "$TPL_YAML" '- "reality-phone"' "group members refilled"
assert_eq "2" "$(printf '%s\n' "$TPL_YAML" | grep -c '\- "DIRECT"')" "each group keeps DIRECT"
assert_contains "$TPL_YAML" "DOMAIN-SUFFIX,deepseek.com,DIRECT" "user rules preserved verbatim"
assert_contains "$TPL_YAML" "DOMAIN-KEYWORD,openai,🤖 AI服务" "user AI rules preserved"
assert_contains "$TPL_YAML" "rule-providers:" "rule-providers preserved"
assert_contains "$TPL_YAML" "url: \"https://example.invalid/gfw.txt\"" "provider url untouched"
if printf '%s' "$TPL_YAML" | grep -q "^dns:"; then
  fail "template mode does not inject the built-in DNS block"
else
  pass "template mode does not inject the built-in DNS block"
fi
assert_eq "1" "$(printf '%s\n' "$TPL_YAML" | grep -c '^proxies:')" "exactly one proxies block"

printf 'mixed-port: 7890\n' > "$TMP/bad-template.yaml"
assert_exit 2 "template without proxies: is rejected" env VPNCTL_STATE_DIR="$SUB_STATE" bash "$SCRIPTS/vpnctl" sub --name phone --out "$TMP/bad" --template "$TMP/bad-template.yaml"

EXAMPLE="$(dirname "$SKILL_DIR")/vps-vpn-setup/assets/profile-template.example.yaml"
if [ -f "$SKILL_DIR/assets/profile-template.example.yaml" ]; then
  ex_out="$TMP/sub-example"
  VPNCTL_STATE_DIR="$SUB_STATE" bash "$SCRIPTS/vpnctl" sub --name phone --out "$ex_out" \
    --template "$SKILL_DIR/assets/profile-template.example.yaml" >/dev/null 2>&1
  if grep -q "PLACEHOLDER" "$ex_out/clash.yaml"; then
    fail "bundled example template renders cleanly"
  else
    pass "bundled example template renders cleanly"
  fi
else
  fail "bundled example template exists"
fi

# ---------------------------------------------------------------------------
group "18. portable entry"
assert_contains "$(bash "$SCRIPTS/vpnctl" sub --help 2>&1)" "--serve" "sub advertises --serve"
assert_contains "$(bash "$SCRIPTS/vpnctl" sub --help 2>&1)" "--unserve" "sub advertises --unserve"
assert_exit 2 "sub --unserve refuses to run without root" bash "$SCRIPTS/vpnctl" sub --unserve
assert_contains "$(bash "$SCRIPTS/remote.sh" --help 2>&1)" "connect" "remote.sh advertises connect"

EP="$SKILL_DIR/assets/ENTRY-PROMPT.md"
if [ -r "$EP" ]; then pass "entry prompt shipped"; else fail "entry prompt shipped"; fi
assert_contains "$(cat "$EP" 2>/dev/null)" "intake.md" "entry prompt points at the intake questions"
assert_contains "$(cat "$EP" 2>/dev/null)" "remote.sh connect" "entry prompt uses the ssh check"
assert_contains "$(cat "$EP" 2>/dev/null)" "wait for my authorization" "entry prompt requires authorization"
assert_contains "$(cat "$EP" 2>/dev/null)" "subscription link" "entry prompt names the deliverable"

INTAKE="$SKILL_DIR/references/intake.md"
if [ -r "$INTAKE" ]; then pass "intake checklist shipped"; else fail "intake checklist shipped"; fi
assert_contains "$(cat "$INTAKE" 2>/dev/null)" "一次问完" "intake forbids drip-feeding questions"

if [ -r "$SCRIPTS/lib/sub-server.py" ]; then
  if python3 -c 'import ast,sys;ast.parse(open(sys.argv[1]).read())' "$SCRIPTS/lib/sub-server.py" 2>/dev/null; then
    pass "sub-server.py parses"
  else
    fail "sub-server.py parses"
  fi
else
  fail "sub-server.py exists"
fi

# ---------------------------------------------------------------------------
group "19. adopting a hand-installed node"
HY1="$TMP/hy1.yaml"
cat > "$HY1" <<'YAML'
listen: :443
tls:
  cert: /etc/ssl/hysteria/cert.pem
  key: /etc/ssl/hysteria/key.pem
auth:
  type: password
  password: shared-secret
obfs:
  type: salamander
  salamander:
    password: obfspass
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
YAML
hy_dry="$(VPNCTL_STATE_DIR="$TMP/hystate" IMPORT_HOST=203.0.113.9 HYSTERIA_CONFIG="$HY1" \
  bash "$SCRIPTS/vpnctl" import hysteria2 phone --dry-run 2>&1)"
assert_contains "$hy_dry" "auth        password" "import detects password auth"
assert_contains "$hy_dry" "port        443/udp" "import reads the listen port"
assert_contains "$hy_dry" "sni         203.0.113.9" "import falls back to the host as sni"
assert_contains "$hy_dry" "obfs        salamander" "import detects obfs"
assert_contains "$hy_dry" "password    set" "import sees the shared secret without printing it"
if printf '%s' "$hy_dry" | grep -q "shared-secret"; then
  fail "import never prints the secret"
else
  pass "import never prints the secret"
fi

HY2="$TMP/hy2.yaml"
cat > "$HY2" <<'YAML'
listen: :8443
tls:
  cert: /etc/ssl/hysteria/cert.pem
  key: /etc/ssl/hysteria/key.pem
auth:
  type: userpass
  userpass:
    alice: passA
    bob: passB
YAML
hy_users="$(VPNCTL_STATE_DIR="$TMP/hystate" IMPORT_HOST=203.0.113.9 HYSTERIA_CONFIG="$HY2" \
  bash "$SCRIPTS/vpnctl" import hysteria2 --dry-run 2>&1)"
assert_contains "$hy_users" "auth        userpass" "import detects userpass auth"
assert_contains "$hy_users" "port        8443/udp" "import reads a non-default port"
assert_contains "$hy_users" "users       2" "import counts userpass users"

assert_exit 2 "import rejects an unknown backend" bash "$SCRIPTS/vpnctl" import wireguard

probe_keys="$(PATH="$TMP/fakebin:$PATH" VPNCTL_STATE_DIR="$TMP/probe2" bash "$SCRIPTS/vpnctl" probe --json 2>/dev/null)"
assert_contains "$probe_keys" '"foreign"' "probe reports services vpnctl does not manage"

# ---------------------------------------------------------------------------
group "20. IP blocked vs service down"
LPORT=$(( 18000 + ($$ % 500) ))
python3 -m http.server "$LPORT" --bind 127.0.0.1 >/dev/null 2>&1 &
SRV=$!
sleep 1
CHK="$SCRIPTS/check-ip.sh"

ok_out="$(bash "$CHK" 127.0.0.1 --port "$LPORT" --ssh-port "$LPORT" --control "127.0.0.1:$LPORT" --json 2>/dev/null)"
assert_contains "$ok_out" '"verdict":"ok"' "open service port reports ok"

blocked_out="$(bash "$CHK" 127.0.0.1 --port 1 --ssh-port 2 --control "127.0.0.1:$LPORT" --json 2>/dev/null)"; blocked_rc=$?
assert_eq "10" "$blocked_rc" "both ports closed + control up exits 10"
assert_contains "$blocked_out" '"verdict":"blocked"' "and calls it a blocked IP"

svc_out="$(bash "$CHK" 127.0.0.1 --port 1 --ssh-port "$LPORT" --control "127.0.0.1:$LPORT" --json 2>/dev/null)"; svc_rc=$?
assert_eq "11" "$svc_rc" "ssh reachable but service closed exits 11"
assert_contains "$svc_out" '"verdict":"service"' "and refuses to call the IP blocked"

local_out="$(bash "$CHK" 127.0.0.1 --port 1 --ssh-port 2 --control 127.0.0.1:1 --json 2>/dev/null)"; local_rc=$?
assert_eq "12" "$local_rc" "dead control target exits 12"
assert_contains "$local_out" '"verdict":"local"' "and blames the local network"

kill "$SRV" 2>/dev/null
wait "$SRV" 2>/dev/null

# ---------------------------------------------------------------------------
group "21. beginner onboarding"
GS="$SKILL_DIR/references/getting-started.md"
if [ -r "$GS" ]; then pass "getting-started guide shipped"; else fail "getting-started guide shipped"; fi
gs_body="$(cat "$GS" 2>/dev/null)"
for osname in Windows macOS Linux iPhone Android; do
  assert_contains "$gs_body" "$osname" "onboarding covers $osname"
done
assert_contains "$gs_body" "Clash Verge Rev" "names a cross-platform client"
assert_contains "$gs_body" "ipinfo.io" "tells the user how to verify"
assert_contains "$gs_body" "从 URL 导入" "explains importing the subscription URL"
assert_contains "$(cat "$SKILL_DIR/SKILL.md")" "getting-started.md" "SKILL.md points at the guide"
assert_contains "$(cat "$SKILL_DIR/assets/ENTRY-PROMPT.md")" "客户端安装" "entry prompt requires client steps"
assert_contains "$(cat "$SUB_OUT/info.txt" 2>/dev/null)" "第一次使用" "the delivered info.txt tells a beginner what to do"
assert_contains "$gs_body" "Watt Toolkit" "onboarding solves the 'cannot reach GitHub' problem"
assert_contains "$gs_body" "steampp.net" "links the official Watt Toolkit page"
assert_contains "$gs_body" "第 0 步" "puts the GitHub workaround before everything else"
assert_contains "$(cat "$SUB_OUT/info.txt" 2>/dev/null)" "Watt Toolkit" "the delivered info.txt mentions the workaround too"
assert_contains "$gs_body" "方式二：用本地 yaml 文件" "guide explains the local yaml delivery mode"
for blk in proxies proxy-groups rule-providers rules; do
  assert_contains "$gs_body" "$blk:" "guide explains the $blk block"
done
assert_contains "$gs_body" "从文件导入" "guide shows how to import a local file"
assert_contains "$gs_body" "最前面" "guide warns that new rules must go first"
assert_contains "$gs_body" "Tab" "guide warns about tabs vs spaces"
assert_contains "$gs_body" "profile-template.example.yaml" "guide points at the annotated example"

# ---------------------------------------------------------------------------
group "22. local client helper"
CC="$SCRIPTS/clientctl"
assert_exit 0 "clientctl detect runs" bash "$CC" detect
cc_json="$(bash "$CC" detect --json 2>/dev/null)"
printf '%s\n' "$cc_json" > "$TMP/cc.json"
if python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["os"] in ("macos","linux","windows");assert d["arch"] in ("aarch64","x64");assert isinstance(d["installed"],bool)' "$TMP/cc.json" 2>/dev/null; then
  pass "clientctl detect --json parses"
else
  fail "clientctl detect --json parses" "$cc_json"
fi

link="$(bash "$CC" import 'http://1.2.3.4:27008/tok/clash.yaml' --name phone --dry-run 2>&1)"
assert_contains "$link" "clash://install-config?url=http%3A%2F%2F1.2.3.4%3A27008%2Ftok%2Fclash.yaml" "import builds a clash:// deep link"
assert_contains "$link" "name=phone" "deep link carries the profile name"

cat > "$TMP/release.json" <<'JSON'
{"tag_name":"v9.9.9","assets":[
 {"name":"Clash.Verge_9.9.9_aarch64.dmg","browser_download_url":"https://example.invalid/a.dmg","size":100,"digest":"sha256:aa"},
 {"name":"Clash.Verge_9.9.9_x64.dmg","browser_download_url":"https://example.invalid/x.dmg","size":100,"digest":"sha256:bb"},
 {"name":"Clash.Verge_9.9.9_amd64.AppImage","browser_download_url":"https://example.invalid/l.AppImage","size":100,"digest":"sha256:cc"},
 {"name":"Clash.Verge_9.9.9_x64-setup.exe","browser_download_url":"https://example.invalid/w.exe","size":100,"digest":"sha256:dd"}
]}
JSON
pick="$(bash "$CC" install --dry-run --release-json "$TMP/release.json" 2>&1)"
assert_contains "$pick" "选中" "install picks an asset from the release"
case "$(uname -s)" in
  Darwin) assert_contains "$pick" ".dmg" "macOS picks a dmg" ;;
  Linux)  assert_contains "$pick" "AppImage" "linux picks an AppImage" ;;
esac
assert_contains "$pick" "dry run" "install --dry-run downloads nothing"

# ---------------------------------------------------------------------------
group "23. autopilot workflow"
AP="$SCRIPTS/autopilot.sh"
assert_exit 0 "autopilot --help runs" bash "$AP" --help
assert_contains "$(bash "$AP" --help 2>&1)" "建机 → 部署 → 出订阅" "help states the whole workflow"

nokey_out="$(VPSCTL_HOME="$TMP/nokey" env -u VULTR_API_KEY bash "$AP" --dry-run 2>&1)"; nokey_rc=$?
assert_eq "2" "$nokey_rc" "without an API key it stops before doing anything"
assert_contains "$nokey_out" "setup-key" "and says exactly what to run"

dry_out="$(VULTR_API_KEY=dummy-key-for-test bash "$AP" --dry-run 2>&1)"; dry_rc=$?
assert_eq "0" "$dry_rc" "with a key it previews and exits cleanly"
assert_contains "$dry_out" "dry run:" "preview names the underlying command"
assert_contains "$dry_out" "--purpose chatgpt" "preview passes the purpose through"

host_out="$(VULTR_API_KEY=dummy bash "$AP" --host root@203.0.113.9 --dry-run 2>&1)"
assert_contains "$host_out" "deploy root@203.0.113.9" "an existing host skips creation"

# ---------------------------------------------------------------------------
group "24. skill package validity"
validate_skill() {
  local dir="$1" base; base="$(basename "$dir")"
  python3 - "$dir/SKILL.md" "$base" <<'PYV'
import re, sys, pathlib
path, expect = sys.argv[1], sys.argv[2]
text = pathlib.Path(path).read_text()
m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
if not m:
    print("no-frontmatter"); sys.exit(1)
fm = m.group(1)
name = (re.search(r"^name:\s*(.+)$", fm, re.M) or [None, ""])[1].strip()
desc = (re.search(r"^description:\s*(.+)$", fm, re.M) or [None, ""])[1].strip().strip('"')
if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", name):
    print("bad-name"); sys.exit(1)
if name != expect:
    print("dir-mismatch"); sys.exit(1)
if not (0 < len(desc) <= 500):
    print("bad-description"); sys.exit(1)
print("ok")
PYV
}
assert_eq "ok" "$(validate_skill "$SKILL_DIR")" "vps-vpn-setup/SKILL.md is a valid package"
if [ -r "$SKILL_DIR/../vps-provision/SKILL.md" ]; then
  assert_eq "ok" "$(validate_skill "$SKILL_DIR/../vps-provision")" "vps-provision/SKILL.md is a valid package"
fi
for d in references scripts assets tests; do
  if [ -d "$SKILL_DIR/$d" ]; then pass "resource dir present: $d/"; else fail "resource dir present: $d/"; fi
done

# ---------------------------------------------------------------------------
printf '\n%s\n' "----------------------------------------"
printf 'passed %s   failed %s   skipped %s\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
printf 'smoke: OK\n'
