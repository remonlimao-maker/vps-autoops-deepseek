#!/usr/bin/env bash
# vpnctl check-sites: can this VPS actually reach the sites you care about?
#
# Read-only. It answers the question no amount of proxy configuration can:
# OpenAI blocks by exit IP (country + datacenter reputation), so a perfectly
# working tunnel can still show "not available in your country". Better to
# learn that here than after shipping configs to a phone.
#
# Checks:
#   chatgpt   https://chatgpt.com/cdn-cgi/trace   (region seen by Cloudflare)
#             https://api.openai.com/v1/models    (unsupported_country signal)
#   youtube   https://www.youtube.com/
#   github    https://github.com/
#
# Sourced by scripts/vpnctl — do not execute directly.

SITE_TIMEOUT="${SITE_TIMEOUT:-12}"

# http_status URL -> prints "CODE TIME"; sets HTTP_CODE/HTTP_TIME
http_status() {
  local url="$1" out code time
  HTTP_CODE="000"; HTTP_TIME="0"
  out="$(curl -sS -L -o /dev/null --max-time "$SITE_TIMEOUT" \
        -w '%{http_code} %{time_total}' "$url" 2>/dev/null)" || return 1
  code="$(printf '%s' "$out" | awk '{print $1}')"
  time="$(printf '%s' "$out" | awk '{print $2}')"
  HTTP_CODE="${code:-000}"
  HTTP_TIME="${time:-0}"
  case $HTTP_CODE in 2*|3*|401|403) return 0 ;; *) return 1 ;; esac
}

# http_body URL BYTES -> prints up to BYTES of the body
http_body() {
  local url="$1" bytes="${2:-4096}"
  curl -sS -L --max-time "$SITE_TIMEOUT" --max-filesize 2000000 "$url" 2>/dev/null \
    | head -c "$bytes"
}

# Where is this host? The trace endpoint is authoritative but unreachable from a
# mainland network, so fall back to a plain-HTTP geolocation API.
sites_country() {
  local c=""
  # ip-api is plain HTTP and reachable from mainland networks; the trace
  # endpoint is authoritative for Cloudflare's view but blocked there.
  c="$( { curl -sS --max-time 5 'http://ip-api.com/json/?fields=countryCode' 2>/dev/null || true; } \
        | sed -n 's/.*"countryCode":"\([A-Z]*\)".*/\1/p' )" || true
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  c="$( { http_body 'https://chatgpt.com/cdn-cgi/trace' 2048 2>/dev/null || true; } \
        | sed -n 's/^loc=//p' | head -n 1 )" || true
  printf '%s' "$c"
}

sites_ip() {
  local ip; ip="$(public_ipv4 || true)"
  printf '%s' "${ip:-unknown}"
}

# Cloudflare's view of where this IP sits; OpenAI's edge uses the same signal.
sites_region() {
  local trace
  trace="$(http_body 'https://chatgpt.com/cdn-cgi/trace' 2048)" || return 1
  printf '%s' "$trace" | sed -n 's/^loc=//p' | head -n 1
}

check_chatgpt() {
  CHAT_OK=0; CHAT_STATUS="unreachable"; CHAT_REGION=""; CHAT_CODE="000"; CHAT_MS="0"; CHAT_NOTE=""
  if ! have curl; then CHAT_STATUS="no curl"; return 1; fi

  local reg; reg="$(sites_region || true)"
  if [ -n "$reg" ]; then CHAT_REGION="$reg"; fi

  # api.openai.com is the cheapest region gate: 401 = reachable, 403+code = blocked
  if http_status 'https://api.openai.com/v1/models'; then
    CHAT_CODE="$HTTP_CODE"
    CHAT_MS="$(awk -v t="$HTTP_TIME" 'BEGIN{printf "%d", t*1000}')"
    local body; body="$(http_body 'https://api.openai.com/v1/models' 4096)"
    case $body in
      *unsupported_country*) CHAT_STATUS="blocked-region"; CHAT_NOTE="OpenAI reports unsupported_country for this IP" ;;
      *)
        if [ "$CHAT_CODE" = "401" ]; then
          CHAT_STATUS="ok"; CHAT_OK=1; CHAT_NOTE="network reachable (401 is expected without an API key)"
        elif [ "$CHAT_CODE" = "403" ]; then
          CHAT_STATUS="blocked"; CHAT_NOTE="403 from api.openai.com — often a flagged datacenter IP"
        else
          CHAT_STATUS="degraded"; CHAT_NOTE="api.openai.com returned $CHAT_CODE"
        fi
        ;;
    esac
  else
    CHAT_CODE="${HTTP_CODE:-000}"
    CHAT_STATUS="unreachable"
    CHAT_NOTE="api.openai.com did not respond"
  fi

  # The web app can behave differently from the API edge.
  if [ "$CHAT_OK" = "1" ]; then
    if http_status 'https://chatgpt.com/'; then
      case $HTTP_CODE in 200|301|302|307|308) : ;; *) CHAT_NOTE="$CHAT_NOTE; chatgpt.com returned $HTTP_CODE" ;; esac
    else
      CHAT_NOTE="$CHAT_NOTE; chatgpt.com did not respond"
    fi
  fi
  [ "$CHAT_OK" = "1" ]
}

check_simple() {
  local url="$1"
  SIMPLE_OK=0; SIMPLE_STATUS="unreachable"; SIMPLE_CODE="000"; SIMPLE_MS="0"
  if http_status "$url"; then
    SIMPLE_CODE="$HTTP_CODE"
    SIMPLE_MS="$(awk -v t="$HTTP_TIME" 'BEGIN{printf "%d", t*1000}')"
    SIMPLE_STATUS="ok"; SIMPLE_OK=1
  else
    SIMPLE_CODE="${HTTP_CODE:-000}"
    SIMPLE_STATUS="unreachable"
  fi
  [ "$SIMPLE_OK" = "1" ]
}

cmd_check_sites() {
  while [ "$#" -gt 0 ]; do
    case $1 in
      --timeout) SITE_TIMEOUT="${2:-12}"; shift 2 ;;
      --json) JSON_OUT=1; shift ;;
      -h|--help)
        cat <<'EOF'
check-sites options:
  --timeout N   per-request timeout in seconds (default 12)
  --json        machine-readable output

Run this ON the VPS: it measures the server -> site path, not your laptop's.
Exit codes: 0 all reachable, 1 network problem, 5 ChatGPT region-blocked,
            6 server located in mainland China (cannot be an exit node).
EOF
        return 0 ;;
      *) die "check-sites: unknown option '$1'" ;;
    esac
  done

  require_cmd curl
  local ip; ip="$(sites_ip)"
  local country; country="$(sites_country || true)"

  # 0 = reachable; a failed probe overwrites with its own status code.
  local chat_ok=0 yt_ok=0 gh_ok=0
  local CHAT_STATUS="skipped" CHAT_REGION="" CHAT_CODE="-" CHAT_MS="0" CHAT_NOTE="not probed"
  local yt_status="skipped" yt_code="-" yt_ms="0"
  local gh_status="skipped" gh_code="-" gh_ms="0"
  local verdict="ok" rc=0

  if [ "$country" = "CN" ]; then
    # A mainland server cannot reach these sites at all, and using one as an
    # exit breaks provider terms and local regulations. Say it once, clearly.
    verdict="host_in_cn"; rc=6
    chat_ok=1; yt_ok=1; gh_ok=1
    CHAT_NOTE="host is in mainland China; not probed"
  else
    check_chatgpt || chat_ok=$?
    check_simple 'https://www.youtube.com/' || yt_ok=$?
    yt_status="$SIMPLE_STATUS"; yt_code="$SIMPLE_CODE"; yt_ms="$SIMPLE_MS"
    check_simple 'https://github.com/' || gh_ok=$?
    gh_status="$SIMPLE_STATUS"; gh_code="$SIMPLE_CODE"; gh_ms="$SIMPLE_MS"

    if [ "$chat_ok" != "0" ]; then
      case $CHAT_STATUS in
        blocked-region|blocked) verdict="chatgpt_blocked"; rc=5 ;;
        *) verdict="network_issue"; rc=1 ;;
      esac
    fi
    if [ "$rc" = "0" ] && { [ "$yt_ok" != "0" ] || [ "$gh_ok" != "0" ]; }; then
      verdict="network_issue"; rc=1
    fi
  fi

  if [ "$JSON_OUT" = "1" ]; then
    printf '{"ip":%s,"country":%s,"verdict":%s,"sites":[' \
      "$(json_str "$ip")" "$(json_str "$country")" "$(json_str "$verdict")"
    printf '{"name":"chatgpt","ok":%s,"status":%s,"region":%s,"http":%s,"ms":%s,"note":%s},' \
      "$([ "$chat_ok" = "0" ] && printf true || printf false)" "$(json_str "$CHAT_STATUS")" \
      "$(json_str "$CHAT_REGION")" "$(json_str "$CHAT_CODE")" "${CHAT_MS:-0}" "$(json_str "$CHAT_NOTE")"
    printf '{"name":"youtube","ok":%s,"status":%s,"http":%s,"ms":%s},' \
      "$([ "$yt_ok" = "0" ] && printf true || printf false)" "$(json_str "$yt_status")" \
      "$(json_str "$yt_code")" "${yt_ms:-0}"
    printf '{"name":"github","ok":%s,"status":%s,"http":%s,"ms":%s}' \
      "$([ "$gh_ok" = "0" ] && printf true || printf false)" "$(json_str "$gh_status")" \
      "$(json_str "$gh_code")" "${gh_ms:-0}"
    printf ']}\n'
    return "$rc"
  fi

  printf 'exit ip   %s\n' "$ip"
  printf 'country   %s\n' "${country:-unknown}"
  printf '\n%-10s %-16s %-6s %-8s %s\n' SITE STATUS HTTP REGION NOTE
  printf '%-10s %-16s %-6s %-8s %s\n' chatgpt "$CHAT_STATUS" "$CHAT_CODE" "${CHAT_REGION:-?}" "$CHAT_NOTE"
  printf '%-10s %-16s %-6s %-8s %s\n' youtube "$yt_status" "$yt_code" "-" "${yt_ms}ms"
  printf '%-10s %-16s %-6s %-8s %s\n' github "$gh_status" "$gh_code" "-" "${gh_ms}ms"

  case $verdict in
    ok) printf '\nverdict: all three reachable from this IP\n' ;;
    host_in_cn)
      printf '\nverdict: this server is in mainland China — it cannot be your exit node\n'
      printf '  It is blocked from YouTube/GitHub exactly like your laptop, and using a\n'
      printf '  domestic server this way breaks provider terms and local regulations.\n'
      printf '  Deploy on an overseas VPS instead: Hong Kong / Japan / Singapore / US.\n'
      printf '  For ChatGPT prefer Japan/Singapore/US — Hong Kong IPs are often blocked.\n'
      ;;
    chatgpt_blocked)
      printf '\nverdict: ChatGPT is blocked for this IP\n'
      printf '  This is an IP problem, not a proxy configuration problem. Options:\n'
      printf '    - rebuild the VPS in another region (US/JP/SG are commonly supported)\n'
      printf '    - ask the provider for a different IP (datacenter ranges get flagged)\n'
      printf '    - keep this node for YouTube/GitHub and use another egress for ChatGPT\n'
      ;;
    network_issue) printf '\nverdict: at least one site is unreachable; check outbound connectivity and DNS\n' ;;
  esac
  return "$rc"
}
