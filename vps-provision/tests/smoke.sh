#!/usr/bin/env bash
# tests/smoke.sh — exercise vpsctl against a fake Vultr API. No network, no cost.
#
#   bash tests/smoke.sh [-v]

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$HERE")"
VPSCTL="$SKILL_DIR/scripts/vpsctl"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export VPSCTL_HOME="$TMP/home"
export VULTR_API_KEY="test-key-000000000000"
export NO_COLOR=1

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
group() { printf '\n%s\n' "$1"; }
assert_eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "want=[$1] got=[$2]"; fi; }
assert_contains() { case $1 in *"$2"*) pass "$3" ;; *) fail "$3" "missing: $2" ;; esac; }
assert_exit() { local want="$1" label="$2"; shift 2; "$@" >"$TMP/out" 2>"$TMP/err"; local got=$?
  if [ "$got" = "$want" ]; then pass "$label"; else fail "$label" "want $want got $got: $(head -n 2 "$TMP/err")"; fi }

# --- fake API --------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'FAKE'
#!/bin/sh
method=GET; url=""; prev=""
for a in "$@"; do
  [ "$prev" = "-X" ] && method=$a
  case "$a" in http*) url=$a ;; esac
  prev=$a
done
echo "$method $url" >> "${FAKE_LOG:-/dev/null}"
path=${url#https://api.vultr.com/v2}
if [ -n "${FAKE_ACCOUNT_STATUS:-}" ]; then
  case "$path" in
    /account) printf '{"error":"Invalid API token."}\n%s\n' "$FAKE_ACCOUNT_STATUS"; exit 0 ;;
  esac
fi
case "$method $path" in
  "GET /regions") body='{"regions":[{"id":"nrt","city":"Tokyo","country":"JP"},{"id":"sea","city":"Seattle","country":"US"}]}' ;;
  "GET /plans") body='{"plans":[{"id":"vc2-1c-1gb","vcpu_count":1,"ram":1024,"disk":25,"monthly_cost":6,"regions":["nrt","sea"]}]}' ;;
  "GET /os") body='{"os":[{"id":2136,"name":"Debian 12 x64","arch":"x64"}]}' ;;
  "GET /ssh-keys") body='{"ssh_keys":[]}' ;;
  "POST /ssh-keys") body='{"ssh_key":{"id":"key-abc"}}' ;;
  "POST /instances") body='{"instance":{"id":"inst-abc"}}' ;;
  "GET /instances/"*) body='{"instance":{"status":"active","main_ip":"203.0.113.7","label":"jp1","region":"nrt","plan":"vc2-1c-1gb","monthly_cost":6,"date_created":"2026-01-01T00:00:00+00:00"}}' ;;
  DELETE*) body='{}' ;;
  *) body='{}' ;;
esac
status="${FAKE_STATUS:-200}"
if [ -n "${FAKE_WRITE_STATUS:-}" ] && [ "$method" != "GET" ]; then status="$FAKE_WRITE_STATUS"; fi
printf '%s\n%s\n' "$body" "$status"
FAKE
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
export FAKE_LOG="$TMP/api.log"
: > "$FAKE_LOG"

printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY test@local\n' > "$TMP/id_test.pub"

# --- tests -----------------------------------------------------------------
group "1. surface"
assert_exit 0 "help exits 0" bash "$VPSCTL" --help
assert_exit 0 "version exits 0" bash "$VPSCTL" version
assert_exit 2 "unknown command exits 2" bash "$VPSCTL" frobnicate
assert_exit 2 "missing name is rejected" bash "$VPSCTL" show
assert_exit 0 "doctor runs" bash "$VPSCTL" doctor

group "2. read-only provider calls"
regions="$(bash "$VPSCTL" regions)"
assert_contains "$regions" "nrt" "regions lists Tokyo"
assert_contains "$regions" "JP" "regions shows the country"
plans="$(bash "$VPSCTL" plans)"
assert_contains "$plans" "vc2-1c-1gb" "plans lists a plan"
assert_contains "$plans" "6" "plans shows the monthly price"
os_list="$(bash "$VPSCTL" os)"
assert_contains "$os_list" "Debian 12" "os lists images"
keys="$(bash "$VPSCTL" keys 2>/dev/null)"
assert_eq "0" "$?" "keys tolerates an empty key list"

group "3. guards"
assert_exit 2 "create without --region exits 2" bash "$VPSCTL" create --name jp1 --yes
assert_exit 2 "create with a bad name exits 2" bash "$VPSCTL" create --name "Bad_Name" --region nrt --plan vc2-1c-1gb --os 2136 --yes
assert_exit 2 "destroy of an unknown instance exits 2" bash "$VPSCTL" destroy ghost --yes

group "4. create (fake provider, --no-wait)"
create_out="$(bash "$VPSCTL" create --name jp1 --region nrt --plan vc2-1c-1gb --os 2136 \
  --ssh-key-file "$TMP/id_test.pub" --no-wait --yes 2>&1)"
assert_contains "$create_out" "instance created" "create reports the new instance id"
if [ -f "$VPSCTL_HOME/instances/jp1.env" ]; then pass "create records local state"; else fail "create records local state"; fi
assert_eq "inst-abc" "$(sed -n 's/^ID=//p' "$VPSCTL_HOME/instances/jp1.env")" "state holds the provider id"
assert_contains "$(cat "$FAKE_LOG")" "POST https://api.vultr.com/v2/instances" "create called POST /instances"
assert_contains "$(cat "$FAKE_LOG")" "POST https://api.vultr.com/v2/ssh-keys" "create registered the ssh key"

group "5. list / show"
list="$(bash "$VPSCTL" list)"
assert_contains "$list" "jp1" "list shows the instance"
show="$(bash "$VPSCTL" show jp1)"
assert_contains "$show" "203.0.113.7" "show reports the live ip"
assert_contains "$show" "active" "show reports the status"
show_json="$(bash "$VPSCTL" --json show jp1)"
printf '%s\n' "$show_json" > "$TMP/show.json"
if python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["ip"]=="203.0.113.7"' "$TMP/show.json" 2>/dev/null; then
  pass "show --json parses"
else
  fail "show --json parses" "$show_json"
fi

group "6. dry run changes nothing"
DRY_HOME="$TMP/dry"
dry="$(VPSCTL_HOME="$DRY_HOME" bash "$VPSCTL" create --name dry1 --region nrt --plan vc2-1c-1gb --os 2136 \
  --ssh-key-file "$TMP/id_test.pub" --dry-run --yes 2>&1)"
assert_contains "$dry" "dry run" "create --dry-run previews the work"
if [ -e "$DRY_HOME/instances/dry1.env" ]; then fail "dry run wrote no state"; else pass "dry run wrote no state"; fi

group "7. destroy"
assert_exit 2 "destroy without --yes and no tty exits 2" bash "$VPSCTL" destroy jp1
destroy_out="$(bash "$VPSCTL" destroy jp1 --yes 2>&1)"
assert_contains "$destroy_out" "destroyed" "destroy reports success"
if [ -e "$VPSCTL_HOME/instances/jp1.env" ]; then fail "destroy forgets local state"; else pass "destroy forgets local state"; fi
assert_contains "$(cat "$FAKE_LOG")" "DELETE https://api.vultr.com/v2/instances/inst-abc" "destroy called DELETE"

group "8. credentials"
assert_exit 2 "missing API key is reported" env -u VULTR_API_KEY bash "$VPSCTL" regions

group "9. one-sentence setup (go)"
: > "$FAKE_LOG"
go_out="$(bash "$VPSCTL" go --dry-run --purpose chatgpt --template no --client phone 2>&1)"
assert_contains "$go_out" "region    nrt" "go resolves a ChatGPT-friendly region"
assert_contains "$go_out" "plan      vc2-1c-1gb" "go resolves the cheapest fitting plan"
assert_contains "$go_out" "image     Debian 12 x64" "go resolves a Debian image"
assert_contains "$go_out" "name      nrt1" "go derives an instance name from the region"
assert_contains "$go_out" "mainland client" "go defaults to a mainland client"
if grep -q "POST https://api.vultr.com/v2/instances" "$FAKE_LOG"; then
  fail "go --dry-run creates nothing"
else
  pass "go --dry-run creates nothing"
fi

budget_out="$(bash "$VPSCTL" go --dry-run --purpose budget --template no 2>&1)"
assert_contains "$budget_out" "region    sea" "a different purpose picks a different region"

tpl_file="$TMP/template.yaml"
printf 'proxies:\n  - name: "OLD"\nproxy-groups:\n  - name: "G"\n    type: select\n    proxies:\n      - "OLD"\nrules:\n  - MATCH,G\n' > "$tpl_file"
tpl_out="$(bash "$VPSCTL" go --dry-run --template "$tpl_file" 2>&1)"
assert_contains "$tpl_out" "profile   $tpl_file" "go picks up an explicit template"

group "10. one-time key setup"
KEY_HOME="$TMP/keyhome"
key_out="$(printf 'N3ATESTKEY\n' | env -u VULTR_API_KEY VPSCTL_HOME="$KEY_HOME" bash "$VPSCTL" setup-key 2>&1)"
assert_contains "$key_out" "key verified and saved" "setup-key verifies before saving"
if [ "$(ls -l "$KEY_HOME/vultr.key" 2>/dev/null | awk '{print $1}' | sed 's/@$//')" = "-rw-------" ]; then
  pass "the key file is 0600"
else
  fail "the key file is 0600"
fi
assert_exit 0 "doctor accepts the stored key" env -u VULTR_API_KEY VPSCTL_HOME="$KEY_HOME" bash "$VPSCTL" doctor

BAD_HOME="$TMP/badhome"
bad_out="$(printf 'BAD\n' | FAKE_STATUS=401 env -u VULTR_API_KEY VPSCTL_HOME="$BAD_HOME" bash "$VPSCTL" setup-key 2>&1)"; bad_rc=$?
assert_eq "2" "$bad_rc" "a rejected key exits 2"
assert_contains "$bad_out" "Nothing was saved" "a rejected key explains itself"
if [ -e "$BAD_HOME/vultr.key" ]; then fail "a rejected key is not persisted"; else pass "a rejected key is not persisted"; fi

assert_contains "$(bash "$VPSCTL" setup-key --help 2>&1)" "setup-key options" "setup-key has its own help"

group "11. read-only key is caught early"
RO_HOME="$TMP/rohome"
ro_out="$(printf 'N3AREADONLY\n' | FAKE_WRITE_STATUS=401 env -u VULTR_API_KEY VPSCTL_HOME="$RO_HOME" bash "$VPSCTL" setup-key 2>&1)"; ro_rc=$?
assert_eq "2" "$ro_rc" "a read-only key exits 2 at setup time"
assert_contains "$ro_out" "READ-ONLY" "the error names the real problem"
if [ -e "$RO_HOME/vultr.key" ]; then fail "a read-only key is not persisted"; else pass "a read-only key is not persisted"; fi
assert_contains "$ro_out" "Read & Write" "the error says how to fix it"

group "12. key verified against an authenticated endpoint"
PUB_HOME="$TMP/pubhome"
pub_out="$(printf 'ANYSTRING\n' | FAKE_ACCOUNT_STATUS=401 env -u VULTR_API_KEY VPSCTL_HOME="$PUB_HOME" bash "$VPSCTL" setup-key 2>&1)"; pub_rc=$?
assert_eq "2" "$pub_rc" "a key that only passes public endpoints is rejected"
assert_contains "$pub_out" "invalid" "the failure names the real reason"
if [ -e "$PUB_HOME/vultr.key" ]; then fail "the bad key is not persisted"; else pass "the bad key is not persisted"; fi

group "13. documented counts"
expected=$(( PASS + 1 ))
nums="$(grep -rhoE "[0-9]{2,3} 项(断言|测试|冒烟测试)" --include="*.md" "$SKILL_DIR" 2>/dev/null | grep -oE "^[0-9]+" | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [ "$nums" = "$expected" ]; then
  pass "docs state the real test count ($expected)"
else
  fail "docs state the real test count" "docs say [$nums], actual is $expected"
fi

printf '\n%s\n' "----------------------------------------"
printf 'passed %s   failed %s\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && exit 1
printf 'smoke: OK\n'
