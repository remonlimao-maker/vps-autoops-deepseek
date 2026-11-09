#!/usr/bin/env bash
# vpsctl provider: Vultr API v2
#
# Sourced by scripts/vpsctl — do not execute directly.
#
# Only the calls actually needed are implemented; everything runs through one
# curl wrapper so the whole provider can be exercised against a fake API.
#
# Credentials: VULTR_API_KEY in the environment. Never written to disk.

VULTR_API_BASE="${VULTR_API_BASE:-https://api.vultr.com/v2}"

# The key comes from the environment, or from ~/.vpsctl/vultr.key (0600).
# The file fallback exists because a GUI-launched agent does not inherit the
# shell environment; it is the only persisted credential and stays user-only.
vultr_key_file() { printf '%s/vultr.key' "$VPSCTL_HOME"; }

vultr_key() {
  if [ -n "${VULTR_API_KEY:-}" ]; then printf '%s' "$VULTR_API_KEY"; return 0; fi
  local f; f="$(vultr_key_file)"
  [ -r "$f" ] || return 1
  local mode; mode="$(ls -l "$f" | awk '{print $1}')"
  case $mode in
    -rw-------*) ;;
    *) log_warn "permissions on $f are $mode; run: chmod 600 $f" ;;
  esac
  tr -d '\r\n' < "$f"
}

# Is the key allowed to write? A DELETE on a non-existent id is the cheapest
# probe: 401/403 means read-only, 404 means "authorized, nothing there".
vultr_check_write_scope() {
  if [ "$DRY_RUN" = "1" ]; then return 0; fi
  vultr_api DELETE "/ssh-keys/vpsctl-scope-probe" >/dev/null 2>&1 || true
  case $HTTP_CODE in
    401|403) return 1 ;;
    *) return 0 ;;
  esac
}

# /regions and /plans answer without authentication, so they cannot prove a key
# is valid. /account requires auth; use it for every "is this key good?" check.
vultr_check_auth() {
  # stderr is intentionally NOT suppressed: the exact reason (invalid token vs
  # blocked IP) is what the user needs to fix it.
  vultr_api GET /account >/dev/null
}

vultr_require_key() {
  [ "$DRY_RUN" = "1" ] && return 0
  if ! vultr_key >/dev/null; then
    die "no API key. Either: export VULTR_API_KEY=... , or: mkdir -p $VPSCTL_HOME && printf '%s' 'YOUR-KEY' > $(vultr_key_file) && chmod 600 $(vultr_key_file)"
  fi
}

vultr_require_python() {
  have python3 || die "python3 is required to parse API responses (install python3, or use --json with jq manually)"
}

# vultr_api METHOD PATH [BODY] -> body on stdout, HTTP_CODE set
vultr_api() {
  local method="$1" path="$2" body="${3:-}" out code
  if [ "$DRY_RUN" = "1" ] && [ "$method" != "GET" ]; then
    log_cmd curl -sS -X "$method" "$VULTR_API_BASE$path"
    HTTP_CODE="200"
    printf '{}'
    return 0
  fi
  vultr_require_key
  local -a args
  args=(-sS -X "$method" -H "Authorization: Bearer $(vultr_key)" -H "Content-Type: application/json" -w '\n%{http_code}')
  if [ -n "$body" ]; then
    args+=(-d "$body")
  fi
  local url
  case $path in
    http*) url="$path" ;;
    *) url="$VULTR_API_BASE$path" ;;
  esac
  out="$(curl "${args[@]}" "$url" 2>/dev/null)" || {
    HTTP_CODE="000"
    log_err "network error talking to $VULTR_API_BASE"
    return 1
  }
  code="$(printf '%s' "$out" | tail -n 1)"
  HTTP_CODE="${code:-000}"
  out="$(printf '%s' "$out" | sed '$d')"

  # Vultr puts the real reason in a JSON body even on 4xx. Never swallow it:
  # an empty list and an error used to look identical to the caller.
  if printf '%s' "$out" | grep -q '"error"'; then
    local reason
    reason="$(printf '%s' "$out" | _py 'import json,sys
try:
    print(json.load(sys.stdin).get("error",""))
except Exception:
    print("")')"
    case $reason in
      *"Invalid API token"*|*"invalid api token"*)
        log_err "Vultr says this API key is invalid (revoked or replaced)."
        log_err "fix: copy the current key from my.vultr.com -> Account -> API Keys, then run: vpsctl setup-key"
        ;;
      *"Unauthorized IP"*)
        log_err "Vultr rejected this machine's IP address ($reason)"
        log_err "fix: my.vultr.com -> Account -> API Keys -> edit this key ->"
        log_err "     set IP Access to 'Allow all IPv4' (or add the IP above), then retry"
        ;;
      "") log_err "Vultr returned HTTP $HTTP_CODE" ;;
      *)  log_err "Vultr refused the request: $reason" ;;
    esac
    return 1
  fi

  case $HTTP_CODE in
    2*) printf '%s' "$out"; return 0 ;;
    401) log_err "401 from Vultr: the API key is invalid or revoked" ;;
    403) log_err "403 from Vultr: the key lacks permission, or an account limit was hit" ;;
    404) log_err "404 from Vultr: $path does not exist" ;;
    429) log_err "429 from Vultr: rate limited, wait a moment" ;;
    *) log_err "Vultr returned HTTP $HTTP_CODE: $(printf '%s' "$out" | head -c 300)" ;;
  esac
  printf '%s' "$out"
  return 1
}

_py() { python3 -c "$1"; }


# vultr_pages PATH — emit every page body in sequence.
# Vultr's meta.links.next is an opaque cursor token, not a URL: replay it as
# ?cursor=<token> against the same list path.
vultr_pages() {
  local base="$1" sep="?" body next cursor=""
  case $base in *\?*) sep="&" ;; esac
  while :; do
    if [ -n "$cursor" ]; then
      body="$(vultr_api GET "$base${sep}cursor=$cursor")" || return 1
    else
      body="$(vultr_api GET "$base")" || return 1
    fi
    printf '%s\n' "$body"
    next="$(printf '%s' "$body" | _py '
import json,sys
d=json.load(sys.stdin)
print(d.get("meta",{}).get("links",{}).get("next","") or "")
')"
    [ -n "$next" ] || break
    cursor="$next"
  done
}

# vultr_collect PATH KEY — flatten every page's KEY array into JSON lines
vultr_collect() {
  local path="$1" key="$2"
  vultr_pages "$path" | _py "
import json,sys
buf = sys.stdin.read()
dec = json.JSONDecoder()
i = 0
while i < len(buf):
    while i < len(buf) and buf[i] in ' \n\t\r':
        i += 1
    if i >= len(buf):
        break
    obj, i = dec.raw_decode(buf, i)
    for item in obj.get('$key', []):
        print(json.dumps(item))
"
}

vultr_regions() {
  vultr_collect /regions regions | _py '
import json,sys
for line in sys.stdin:
    r = json.loads(line)
    print("%s|%s|%s" % (r.get("id",""), r.get("city",""), r.get("country","")))
'
}

vultr_plans() {
  vultr_collect /plans plans | _py '
import json,sys
for line in sys.stdin:
    p = json.loads(line)
    print("%s|%s|%s|%s|%s|%s" % (
        p.get("id",""), p.get("vcpu_count",0), p.get("ram",0), p.get("disk",0),
        p.get("monthly_cost",0), ",".join(p.get("locations") or p.get("regions") or [])))
'
}

vultr_os() {
  vultr_collect /os os | _py '
import json,sys
for line in sys.stdin:
    o = json.loads(line)
    print("%s|%s|%s" % (o.get("id",""), o.get("name",""), o.get("arch","")))
'
}

vultr_ssh_keys() {
  vultr_collect /ssh-keys ssh_keys | _py '
import json,sys
for line in sys.stdin:
    k = json.loads(line)
    print("%s|%s" % (k.get("id",""), k.get("name","")))
'
}

# vultr_ensure_key FILE NAME -> prints key id, registering only when needed
vultr_ensure_key() {
  local file="$1" name="$2" existing_id="" pub
  [ -r "$file" ] || die "ssh public key not readable: $file"
  pub="$(cat "$file")"
  existing_id="$(vultr_ssh_keys | awk -F'|' -v n="$name" '$2==n {print $1; exit}')"
  if [ -n "$existing_id" ]; then
    log_info "reusing ssh key '$name' ($existing_id)"
    printf '%s' "$existing_id"
    return 0
  fi
  local body
  body="$(printf '{"name":%s,"ssh_key":%s}' "$(json_str "$name")" "$(json_str "$pub")")"
  local id
  id="$(vultr_api POST /ssh-keys "$body" | _py '
import json,sys
print(json.load(sys.stdin).get("ssh_key", {}).get("id", ""))
')"
  if [ -z "$id" ]; then
    case ${HTTP_CODE:-} in
      401|403) die "the API key cannot write (read-only scope?). Recreate it with Read & Write and run: vpsctl setup-key" ;;
      *) die "failed to register the ssh key (HTTP ${HTTP_CODE:-unknown})" ;;
    esac
  fi
  log_ok "registered ssh key '$name' ($id)"
  printf '%s' "$id"
}

# vultr_create REGION PLAN OS_ID LABEL KEY_ID -> instance id
vultr_create() {
  local region="$1" plan="$2" os_id="$3" label="$4" key_id="$5"
  local body
  body="$(printf '{"region":%s,"plan":%s,"os_id":%s,"label":%s,"hostname":%s,"sshkey_ids":[%s],"backups":"disabled","enable_ipv6":true}' \
    "$(json_str "$region")" "$(json_str "$plan")" "$os_id" "$(json_str "$label")" "$(json_str "$label")" "$(json_str "$key_id")")"
  vultr_api POST /instances "$body" | _py '
import json,sys
print(json.load(sys.stdin).get("instance", {}).get("id", ""))
'
}

# vultr_instance ID -> status|ip|label|region|plan|monthly|created
# vultr_instances — every instance in the account (paginated)
# prints: id|label|region|plan|status|main_ip|monthly
vultr_instances() {
  vultr_collect /instances instances | _py '
import json,sys
for line in sys.stdin:
    i = json.loads(line)
    print("%s|%s|%s|%s|%s|%s|%s" % (
        i.get("id",""), i.get("label",""), i.get("region",""), i.get("plan",""),
        i.get("status",""), i.get("main_ip",""), i.get("monthly_cost",0)))
'
}

vultr_instance() {
  vultr_api GET "/instances/$1" | _py '
import json,sys
i = json.load(sys.stdin).get("instance", {})
print("%s|%s|%s|%s|%s|%s|%s" % (
    i.get("status",""), i.get("main_ip",""), i.get("label",""), i.get("region",""),
    i.get("plan",""), i.get("monthly_cost",0), i.get("date_created","")))
'
}

vultr_delete()  { vultr_api DELETE "/instances/$1" >/dev/null; }
vultr_reboot()  { vultr_api POST "/instances/$1/reboot" '{}' >/dev/null; }

vultr_snapshot() {
  local id="$1" desc="$2" body
  body="$(printf '{"description":%s}' "$(json_str "$desc")")"
  vultr_api POST "/instances/$id/snapshot" "$body" | _py '
import json,sys
s = json.load(sys.stdin).get("snapshot", {})
print("%s|%s" % (s.get("id",""), s.get("description","")))
'
}

# vultr_wait_active ID TIMEOUT -> prints the ip
vultr_wait_active() {
  local id="$1" timeout="${2:-600}" waited=0 interval=8 status ip line rest
  while [ "$waited" -lt "$timeout" ]; do
    line="$(vultr_instance "$id")"
    status="${line%%|*}"
    rest="${line#*|}"
    ip="${rest%%|*}"
    case $status in
      active)
        if [ -n "$ip" ] && [ "$ip" != "0.0.0.0" ]; then printf '%s' "$ip"; return 0; fi ;;
      locked|pending|installing) ;;
      *) log_warn "instance status: $status" ;;
    esac
    sleep "$interval"; waited=$((waited + interval))
    log_info "waiting for the instance to boot ($(fmt_secs "$waited"))"
  done
  return 1
}
