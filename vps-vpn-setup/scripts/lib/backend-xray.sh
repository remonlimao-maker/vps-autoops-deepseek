#!/usr/bin/env bash
# vpnctl backend: Xray (VLESS + REALITY, and Shadowsocks-2022)
#
# Sourced by scripts/vpnctl — do not execute directly.
#
# One binary, two protocols. BE_ID selects the mode:
#   xray-reality : VLESS + XTLS-Vision + REALITY on TCP/443 (no domain needed,
#                  looks like a normal TLS session to the camouflage site)
#   ss2022       : Shadowsocks-2022 (2022-blake3-aes-128-gcm) multi-user
#
# Layout:
#   /usr/local/bin/xray
#   /usr/local/etc/xray/config.json
#   /etc/systemd/system/xray.service
#   /etc/vpnctl/xray/{meta.env,server.key,clients/<n>.env}

XR_PORT="${XR_PORT:-}"
XR_DEST="${XR_DEST:-}"
XR_SNI="${XR_SNI:-www.microsoft.com}"
XR_FP="${XR_FP:-chrome}"
XR_FLOW="${XR_FLOW:-xtls-rprx-vision}"
XR_SS_METHOD="${XR_SS_METHOD:-2022-blake3-aes-128-gcm}"
XR_SS_SERVER_PSK="${XR_SS_SERVER_PSK:-}"
XR_VERSION="${XR_VERSION:-latest}"
XR_MIRROR="${XR_MIRROR:-}"
XR_BIN="/usr/local/bin/xray"
XR_ETC="/usr/local/etc/xray"
XR_CONF=""   # resolved per backend id: /usr/local/etc/xray/<id>.json
XR_SHARE="/usr/local/share/xray"
XR_UNIT=""   # resolved per backend id: /etc/systemd/system/<id>.service

be_info() { printf 'xray|Xray VLESS+REALITY|TCP|%s\n' "${XR_PORT:-443}"; }

# Both variants run the same binary but as independent systemd units, so they
# can be installed side by side (443/tcp for REALITY, 8388/tcp+udp for SS2022).
xr_conf() { printf '%s/%s.json' "$XR_ETC" "$BE_ID"; }
xr_unit() { printf '/etc/systemd/system/%s.service' "$BE_ID"; }

be_mode() { if [ "${BE_VARIANT:-}" = "ss2022" ]; then printf 'ss2022'; else printf 'reality'; fi; }

be_default_port() { if [ "$(be_mode)" = "ss2022" ]; then printf '8388'; else printf '443'; fi; }

be_parse_opts() {
  local mode; mode="$(be_mode)"
  [ -n "$XR_PORT" ] || XR_PORT="$(be_default_port)"
  [ -n "$XR_DEST" ] || XR_DEST="$XR_SNI:443"
  while [ "$#" -gt 0 ]; do
    case $1 in
      --port) XR_PORT="${2:-}"; shift 2 ;;
      --sni) XR_SNI="${2:-}"; shift 2 ;;
      --dest) XR_DEST="${2:-}"; shift 2 ;;
      --fingerprint|--fp) XR_FP="${2:-}"; shift 2 ;;
      --flow) XR_FLOW="${2:-}"; shift 2 ;;
      --method) XR_SS_METHOD="${2:-}"; shift 2 ;;
      --version) XR_VERSION="${2:-}"; shift 2 ;;
      --mirror) XR_MIRROR="${2:-}"; shift 2 ;;
      -h|--help) be_help; exit 0 ;;
      *) die "$BE_ID: unknown option '$1' (see: vpnctl help)" ;;
    esac
  done
  validate_xr_port "$XR_PORT"
  case $mode in
    reality)
      case $XR_DEST in *:*) ;; *) die "xray-reality: --dest must be host:port (got '$XR_DEST')" ;; esac
      ;;
    ss2022)
      case $XR_SS_METHOD in
        2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) ;;
        *) die "xray ss2022: unsupported method '$XR_SS_METHOD'" ;;
      esac
      ;;
  esac
}

be_help() {
  if [ "$(be_mode)" = "ss2022" ]; then
    cat <<EOF
ss2022 options:
  --port N       TCP/UDP listen port (default 8388)
  --method NAME  2022-blake3-aes-128-gcm (default) | -aes-256-gcm | -chacha20-poly1305
  --version V    pin a Xray release (default latest)
  --mirror URL   download base for xray-core (use when github.com is blocked)
EOF
  else
    cat <<EOF
xray-reality options:
  --port N       TCP listen port (default 443)
  --sni HOST     camouflage server name (default $XR_SNI)
  --dest H:P     REALITY target, must serve TLS1.3+HTTP/2 (default <sni>:443)
  --fp NAME      client fingerprint: chrome (default) | firefox | safari | ios | android
  --flow NAME    xtls-rprx-vision (default) | "" (disable Vision)
  --version V    pin a Xray release (default latest)
  --mirror URL   download base for xray-core (use when github.com is blocked)
EOF
  fi
}

# Called by vpnctl for every command once the backend is installed: restore the
# persisted options so `client export` renders the same values `install` used.
be_from_state() {
  local mode; mode="$(meta_get "$BE_ID" MODE)"
  if [ -n "$mode" ]; then
    if [ "$mode" = "ss2022" ]; then BE_VARIANT="ss2022"; else BE_VARIANT=""; fi
  fi
  XR_PORT="$(meta_get "$BE_ID" PORT)"
  if [ -z "$XR_PORT" ]; then
    XR_PORT="$( [ "$(be_mode)" = "ss2022" ] && printf 8388 || printf 443 )"
  fi
  XR_SNI="$(meta_get "$BE_ID" SNI)"; [ -n "$XR_SNI" ] || XR_SNI="www.microsoft.com"
  XR_DEST="$(meta_get "$BE_ID" DEST)"; [ -n "$XR_DEST" ] || XR_DEST="$XR_SNI:443"
  XR_FLOW="$(meta_get "$BE_ID" FLOW)"; if [ -z "$XR_FLOW" ] && [ "$(be_mode)" = "reality" ]; then XR_FLOW="xtls-rprx-vision"; fi
  XR_FP="$(meta_get "$BE_ID" FP)"; [ -n "$XR_FP" ] || XR_FP="chrome"
  local m; m="$(meta_get "$BE_ID" SS_METHOD)"; [ -n "$m" ] && XR_SS_METHOD="$m"
  local psk; psk="$(meta_get "$BE_ID" SS_SERVER_PSK)"; [ -n "$psk" ] && XR_SS_SERVER_PSK="$psk"
  return 0
}

validate_xr_port() {
  case $1 in ''|*[!0-9]*) die "invalid port: '$1'" ;; esac
  if [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then die "port out of range: $1"; fi
}

# --- xray binary -----------------------------------------------------------

xr_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf '64' ;;
    aarch64|arm64) printf 'arm64-v8a' ;;
    armv7l|armv7) printf 'arm32-v7a' ;;
    i386|i686) printf '32' ;;
    *) die "unsupported architecture: $(uname -m). Build xray manually from https://github.com/XTLS/Xray-core" ;;
  esac
}

xr_install_binary() {
  if [ -x "$XR_BIN" ]; then
    log_ok "xray already present: $($XR_BIN version 2>/dev/null | head -n 1)"
    return 0
  fi
  ensure_pkgs curl unzip ca-certificates
  local arch zip base url tmp
  arch="$(xr_arch)"
  zip="Xray-linux-$arch.zip"
  if [ -n "$XR_MIRROR" ]; then
    base="${XR_MIRROR%/}"
    case $base in
      *releases/download*) url="$base/$zip" ;;
      *) url="$base/Xray-core/releases/latest/download/$zip" ;;
    esac
  elif [ "$XR_VERSION" = "latest" ]; then
    url="https://github.com/XTLS/Xray-core/releases/latest/download/$zip"
  else
    url="https://github.com/XTLS/Xray-core/releases/download/$XR_VERSION/$zip"
  fi

  tmp="$(mktemp -d)"
  log_info "downloading $url"
  if ! curl -fL --retry 3 --connect-timeout 10 -o "$tmp/$zip" "$url"; then
    rm -rf "$tmp"
    log_err "download failed. If github.com is unreachable from this host, re-run with:"
    log_err "  --mirror https://your-mirror.example.com    (a proxy pointing at github.com)"
    return 2
  fi

  if curl -fsSL --connect-timeout 10 -o "$tmp/$zip.dgst" "$url.dgst" 2>/dev/null; then
    local want got
    want="$(grep -oiE '[a-f0-9]{64}' "$tmp/$zip.dgst" | head -n 1)"
    got="$(sha256sum "$tmp/$zip" | awk '{print $1}')"
    if [ -n "$want" ] && [ "$want" != "$got" ]; then
      rm -rf "$tmp"
      die "sha256 mismatch for $zip (expected $want, got $got)"
    fi
    log_ok "archive checksum verified"
  else
    log_warn "checksum file unavailable; continuing without verification"
  fi

  run unzip -oq "$tmp/$zip" -d "$tmp/x"
  run install -m 0755 "$tmp/x/xray" "$XR_BIN"
  run mkdir -p "$XR_SHARE"
  if [ -f "$tmp/x/geoip.dat" ]; then run install -m 0644 "$tmp/x/geoip.dat" "$XR_SHARE/geoip.dat"; fi
  if [ -f "$tmp/x/geosite.dat" ]; then run install -m 0644 "$tmp/x/geosite.dat" "$XR_SHARE/geosite.dat"; fi
  rm -rf "$tmp"
  log_ok "installed $($XR_BIN version 2>/dev/null | head -n 1)"
}

xr_service_unit() {
  {
    printf '# installed by vpnctl\n'
    printf '[Unit]\nDescription=Xray %s (vpnctl)\n' "$(be_mode)"
    printf 'After=network-online.target nss-lookup.target\nWants=network-online.target\n\n'
    printf '[Service]\nUser=nobody\n'
    printf 'CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE\n'
    printf 'AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE\n'
    printf 'NoNewPrivileges=true\n'
    printf 'ExecStart=%s run -config %s\n' "$XR_BIN" "$(xr_conf)"
    printf 'Restart=on-failure\nRestartSec=3\nLimitNOFILE=1000000\n'
    printf 'StandardOutput=journal\nStandardError=journal\n\n'
    printf '[Install]\nWantedBy=multi-user.target\n'
  }
}

xr_write_unit() {
  local tmp="/tmp/vpnctl-xray-unit.$$"
  xr_service_unit > "$tmp"
  install_file "$tmp" "$(xr_unit)" 0644
  rm -f "$tmp"
  run systemctl daemon-reload
}

# --- keys ------------------------------------------------------------------

xr_server_key() { printf '%s/server.key' "$(be_dir "$BE_ID")"; }

xr_ensure_keys() {
  local key; key="$(xr_server_key)"
  mkdir -p "$(be_dir "$BE_ID")"
  chmod 700 "$(be_dir "$BE_ID")"
  case $(be_mode) in
    reality)
      if [ ! -s "$key" ]; then
        ( umask 077
          { "$XR_BIN" x25519 2>/dev/null || true; } > "$key.raw"
        )
        local priv pub
        priv="$(sed -nE 's/^(Private ?[Kk]ey:?|PrivateKey:) *//p' "$key.raw" | head -n 1)"
        pub="$(sed -nE 's/^(Password:|Public ?[Kk]ey:?|PublicKey:) *//p' "$key.raw" | head -n 1)"
        [ -n "$priv" ] || die "cannot parse x25519 output from $XR_BIN"
        [ -n "$pub" ] || die "cannot parse the REALITY public key from $XR_BIN"
        printf '%s' "$priv" > "$key"
        printf '%s' "$pub" > "$key.pub"
        chmod 600 "$key" "$key.pub"
        rm -f "$key.raw"
      fi
      ;;
    ss2022)
      if [ ! -s "$key" ]; then
        local bytes=16
        case $XR_SS_METHOD in *aes-256-gcm) bytes=32 ;; esac
        ( umask 077
          if have openssl; then openssl rand -base64 "$bytes" | tr -d '\n' > "$key"
          else head -c "$bytes" /dev/urandom | base64 | tr -d '\n' > "$key"; fi
        )
        chmod 600 "$key"
      fi
      ;;
  esac
}

# --- config rendering ------------------------------------------------------

xr_short_id() {
  local sid; sid="$(meta_get "$BE_ID" SHORT_ID)"
  [ -n "$sid" ] || sid="$(rand_hex 8)"
  printf '%s' "$sid"
}

xr_render_config() {
  local key priv pub
  priv="$([ -r "$(xr_server_key)" ] && cat "$(xr_server_key)" || true)"
  pub="$([ -r "$(xr_server_key).pub" ] && cat "$(xr_server_key).pub" || true)"

  printf '{\n'
  printf '  "log": {"loglevel": "warning", "access": "none"},\n'
  printf '  "inbounds": [\n'
  if [ "$(be_mode)" = "reality" ]; then
    printf '    {\n'
    printf '      "tag": "vless-reality",\n'
    printf '      "listen": "0.0.0.0",\n'
    printf '      "port": %s,\n' "$XR_PORT"
    printf '      "protocol": "vless",\n'
    printf '      "settings": {\n'
    printf '        "clients": [\n'
    local first=1 n uuid
    for n in $(client_list "$BE_ID"); do
      uuid="$(client_get "$BE_ID" "$n" UUID)"
      [ -n "$uuid" ] || continue
      [ "$first" = "1" ] || printf ',\n'
      first=0
      printf '          {"id": %s, "flow": %s, "email": %s}' \
        "$(json_str "$uuid")" "$(json_str "$XR_FLOW")" "$(json_str "$n")"
    done
    printf '\n        ],\n'
    printf '        "decryption": "none",\n'
    printf '        "fallbacks": []\n'
    printf '      },\n'
    printf '      "streamSettings": {\n'
    printf '        "network": "tcp",\n'
    printf '        "security": "reality",\n'
    printf '        "realitySettings": {\n'
    printf '          "show": false,\n'
    printf '          "dest": %s,\n' "$(json_str "$XR_DEST")"
    printf '          "xver": 0,\n'
    printf '          "serverNames": [%s],\n' "$(json_str "$XR_SNI")"
    printf '          "privateKey": %s,\n' "$(json_str "$priv")"
    printf '          "shortIds": [%s]\n' "$(json_str "$(xr_short_id)")"
    printf '        }\n'
    printf '      },\n'
    printf '      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}\n'
    printf '    }\n'
  else
    printf '    {\n'
    printf '      "tag": "ss2022",\n'
    printf '      "listen": "0.0.0.0",\n'
    printf '      "port": %s,\n' "$XR_PORT"
    printf '      "protocol": "shadowsocks",\n'
    printf '      "settings": {\n'
    printf '        "method": %s,\n' "$(json_str "$XR_SS_METHOD")"
    printf '        "password": %s,\n' "$(json_str "$priv")"
    printf '        "network": "tcp,udp",\n'
    printf '        "clients": [\n'
    local first=1 n psk
    for n in $(client_list "$BE_ID"); do
      psk="$(client_get "$BE_ID" "$n" PSK)"
      [ -n "$psk" ] || continue
      [ "$first" = "1" ] || printf ',\n'
      first=0
      printf '          {"password": %s, "email": %s}' "$(json_str "$psk")" "$(json_str "$n")"
    done
    printf '\n        ]\n'
    printf '      },\n'
    printf '      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}\n'
    printf '    }\n'
  fi
  printf '  ],\n'
  printf '  "outbounds": [\n'
  printf '    {"protocol": "freedom", "tag": "direct"},\n'
  printf '    {"protocol": "blackhole", "tag": "block"}\n'
  printf '  ],\n'
  printf '  "routing": {\n'
  printf '    "domainStrategy": "AsIs",\n'
  printf '    "rules": [\n'
  printf '      {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"}\n'
  printf '    ]\n'
  printf '  }\n'
  printf '}\n'
}

# --- client URIs -----------------------------------------------------------

xr_client_uri() {
  local name="$1" host uuid sid pub
  host="$(meta_get "$BE_ID" PUBLIC_IP)"
  case $(be_mode) in
    reality)
      uuid="$(client_get "$BE_ID" "$name" UUID)"
      sid="$(meta_get "$BE_ID" SHORT_ID)"
      pub="$(meta_get "$BE_ID" PUBKEY)"
      printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=tcp&flow=%s#%s\n' \
        "$uuid" "$host" "$XR_PORT" "$(urlencode "$XR_SNI")" "$XR_FP" "$(urlencode "$pub")" \
        "$sid" "$(urlencode "$XR_FLOW")" "$(urlencode "$name")"
      ;;
    ss2022)
      local psk server_psk userinfo
      psk="$(client_get "$BE_ID" "$name" PSK)"
      server_psk="${XR_SS_SERVER_PSK:-$(meta_get "$BE_ID" SS_SERVER_PSK)}"
      # SIP002: base64url(method:password), password = userPSK:serverPSK
      userinfo="$(printf '%s:%s:%s' "$XR_SS_METHOD" "$psk" "$server_psk" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')"
      printf 'ss://%s@%s:%s#%s\n' "$userinfo" "$host" "$XR_PORT" "$(urlencode "$name")"
      ;;
  esac
}

xr_client_outbound_json() {
  local name="$1" host
  host="$(meta_get "$BE_ID" PUBLIC_IP)"
  case $(be_mode) in
    reality)
      cat <<EOF
{
  "type": "vless",
  "tag": "$name",
  "server": "$host",
  "server_port": $XR_PORT,
  "uuid": "$(client_get "$BE_ID" "$name" UUID)",
  "flow": "$XR_FLOW",
  "tls": {
    "enabled": true,
    "server_name": "$XR_SNI",
    "utls": {"enabled": true, "fingerprint": "$XR_FP"},
    "reality": {
      "enabled": true,
      "public_key": "$(meta_get "$BE_ID" PUBKEY)",
      "short_id": "$(meta_get "$BE_ID" SHORT_ID)"
    }
  }
}
EOF
      ;;
    ss2022)
      cat <<EOF
{
  "type": "shadowsocks",
  "tag": "$name",
  "server": "$host",
  "server_port": $XR_PORT,
  "method": "$XR_SS_METHOD",
  "password": "$(client_get "$BE_ID" "$name" PSK):${XR_SS_SERVER_PSK:-$(meta_get "$BE_ID" SS_SERVER_PSK)}",
  "udp_over_tcp": false
}
EOF
      ;;
  esac
}

# --- plan ------------------------------------------------------------------

be_print_plan() {
  local mode; mode="$(be_mode)"
  cat <<EOF
Plan: $BE_ID on this host
  1. install   xray-core binary ($(xr_arch)) -> $XR_BIN, checksum-verified
  2. generate  $([ "$mode" = "reality" ] && echo "REALITY x25519 keypair + shortId" || echo "Shadowsocks-2022 server key (16 bytes, base64)")
  3. write     $(xr_conf)  (port $XR_PORT)
$( [ "$mode" = "reality" ] && printf '       camouflage: %s (SNI %s), flow %s\n' "$XR_DEST" "$XR_SNI" "$XR_FLOW" || printf '       method: %s, multi-user\n' "$XR_SS_METHOD")
  4. unit      $(xr_unit)  (systemd, user nobody, auto-restart)
  5. firewall  port stays closed until you run: vpnctl harden
  6. verify    config test + listening port

Clients are added later:
  vpnctl client $BE_ID add --name phone --yes
EOF
}

# --- install ---------------------------------------------------------------

be_install() {
  meta_init xray
  case $(be_mode) in
    reality)
      if port_listening "$XR_PORT" tcp; then
        if [ "$(meta_get "$BE_ID" PORT)" != "$XR_PORT" ] || ! svc_active "$BE_ID"; then
          log_err "TCP/$XR_PORT is already in use by something else:"
          port_owner_hint "$XR_PORT" >&2 || true
          die "pick another port with --port, or stop the existing service"
        fi
      fi
      ;;
    ss2022)
      if port_listening "$XR_PORT" tcp && ! svc_active "$BE_ID"; then
        log_err "TCP/$XR_PORT is in use:"; port_owner_hint "$XR_PORT" >&2 || true
        die "pick another port with --port"
      fi
      ;;
  esac

  xr_install_binary
  run mkdir -p "$XR_ETC"
  xr_ensure_keys

  local ip; ip="$(public_ipv4 || true)"
  if [ -z "$ip" ]; then
    log_warn "public IPv4 unknown; clients will use the local address"
    ip="$(local_ipv4 || true)"
  fi
  [ -n "$ip" ] || die "cannot determine the host address"

  meta_set "$BE_ID" MODE "$(be_mode)"
  meta_set "$BE_ID" PORT "$XR_PORT"
  meta_set "$BE_ID" PUBLIC_IP "$ip"
  meta_set "$BE_ID" PROTO "$([ "$(be_mode)" = "ss2022" ] && echo tcp,udp || echo tcp)"
  meta_set "$BE_ID" CONFIG "$(xr_conf)"
  meta_set "$BE_ID" SERVICE "$BE_ID"
  local xrver
  xrver="$("$XR_BIN" version 2>/dev/null | head -n 1 | awk '{print $2}')"
  if [ -n "$xrver" ]; then meta_set "$BE_ID" VERSION "$xrver"; fi
  if [ "$(be_mode)" = "ss2022" ]; then
    meta_set "$BE_ID" SS_METHOD "$XR_SS_METHOD"
    meta_set "$BE_ID" SS_SERVER_PSK "$(cat "$(xr_server_key)")"
  fi
  if [ "$(be_mode)" = "reality" ]; then
    meta_set "$BE_ID" SNI "$XR_SNI"
    meta_set "$BE_ID" DEST "$XR_DEST"
    meta_set "$BE_ID" FLOW "$XR_FLOW"
    meta_set "$BE_ID" FP "$XR_FP"
    meta_set "$BE_ID" PUBKEY "$(cat "$(xr_server_key).pub")"
    if [ -z "$(meta_get "$BE_ID" SHORT_ID)" ]; then meta_set "$BE_ID" SHORT_ID "$(rand_hex 8)"; fi
  fi

  xr_write_unit
  xr_apply
  log_ok "xray ($(be_mode)) configured on port $XR_PORT"
}

xr_apply() {
  xr_render_config > /tmp/vpnctl-xray.$$.json
  if ! "$XR_BIN" run -test -config "/tmp/vpnctl-xray.$$.json" >/dev/null 2>&1; then
    log_err "generated config failed 'xray -test':"
    "$XR_BIN" run -test -config "/tmp/vpnctl-xray.$$.json" 2>&1 | tail -n 5 >&2 || true
    rm -f "/tmp/vpnctl-xray.$$.json"
    return 3
  fi
  install_file "/tmp/vpnctl-xray.$$.json" "$(xr_conf)" 0644
  rm -f "/tmp/vpnctl-xray.$$.json"
  if svc_active "$BE_ID"; then
    run systemctl restart "$BE_ID"
  else
    svc_enable_now "$BE_ID"
  fi
}

# --- clients ---------------------------------------------------------------

xr_ss_key_for_method() {
  local bytes=16
  case $XR_SS_METHOD in *aes-256-gcm) bytes=32 ;; esac
  if have openssl; then openssl rand -base64 "$bytes" | tr -d '\n'
  else head -c "$bytes" /dev/urandom | base64 | tr -d '\n'; fi
}

be_client_add() {
  local name="$1"
  case $(be_mode) in
    reality)
      local uuid; uuid="$("$XR_BIN" uuid 2>/dev/null || rand_uuid)"
      client_write "$BE_ID" "$name" "UUID=$uuid" "CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      ;;
    ss2022)
      local psk; psk="$(xr_ss_key_for_method)"
      client_write "$BE_ID" "$name" "PSK=$psk" "CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      ;;
  esac
  xr_apply
  log_ok "added client $name"
}

be_client_remove() {
  rm -f "$(client_file "$BE_ID" "$1")"
  xr_apply
}

be_client_export() {
  local name="$1" outdir="${2:-}" dir uri
  if [ -z "$outdir" ]; then dir="${HOME:-/root}/vpn-clients/$BE_ID/$name"; else dir="$outdir"; fi
  mkdir -p "$dir"
  uri="$(xr_client_uri "$name")"
  printf '%s\n' "$uri" > "$dir/uri.txt"
  chmod 600 "$dir/uri.txt"
  xr_client_outbound_json "$name" > "$dir/outbound.json"
  chmod 600 "$dir/outbound.json"

  {
    printf 'backend: %s\n' "$BE_ID"
    printf 'client:  %s\n' "$name"
    printf 'server:  %s:%s\n' "$(meta_get "$BE_ID" PUBLIC_IP)" "$XR_PORT"
    case $(be_mode) in
      reality)
        printf 'uuid:    %s\n' "$(client_get "$BE_ID" "$name" UUID)"
        printf 'sni:     %s\n' "$XR_SNI"
        printf 'pbk:     %s\n' "$(meta_get "$BE_ID" PUBKEY)"
        printf 'sid:     %s\n' "$(meta_get "$BE_ID" SHORT_ID)"
        printf 'flow:    %s\n' "$XR_FLOW"
        ;;
      ss2022)
        printf 'method:  %s\n' "$XR_SS_METHOD"
        printf 'password:%s\n' "$(client_get "$BE_ID" "$name" PSK)"
        ;;
    esac
    printf '\nImport: cut uri.txt into the client (v2rayN / v2rayNG / NekoBox / sing-box / mihomo)\n'
    printf 'QR:     qrencode -t ansiutf8 < uri.txt\n'
  } > "$dir/info.txt"

  if have qrencode; then
    qrencode -o "$dir/$name.png" -r "$dir/uri.txt" 2>/dev/null && printf '%s\n' "$dir/$name.png" || true
  fi
  printf '%s\n' "$dir/uri.txt" "$dir/outbound.json"
  log_ok "client files in $dir"
}

# --- verify / uninstall ----------------------------------------------------

be_verify() {
  local ok=1 checks="" out
  if svc_active "$BE_ID"; then checks="$checks service=up"; else checks="$checks service=down"; ok=0; fi
  if [ -r "$(xr_conf)" ]; then
    if out="$("$XR_BIN" run -test -config "$(xr_conf)" 2>&1)"; then
      checks="$checks config=valid"
    else
      checks="$checks config=invalid"; ok=0
      printf '%s\n' "$out" | tail -n 3 >&2
    fi
  else
    checks="$checks config=missing"; ok=0
  fi
  if port_listening "$XR_PORT" tcp; then checks="$checks tcp=$XR_PORT"; else checks="$checks tcp=unconfirmed"; fi
  checks="$checks clients=$(client_count "$BE_ID")"
  if [ "$JSON_OUT" = "1" ]; then
    printf '{"backend":%s,"mode":%s,"ok":%s,"checks":%s,"port":%s}\n' \
      "$(json_str "$BE_ID")" "$(json_str "$(be_mode)")" \
      "$([ "$ok" = "1" ] && printf true || printf false)" "$(json_str "${checks# }")" "$XR_PORT"
  else
    printf '%s: %s\n' "$BE_ID" "$([ "$ok" = "1" ] && echo OK || echo FAILED)"
    printf '  %s\n' "${checks# }"
  fi
  [ "$ok" = "1" ]
}

be_uninstall() {
  svc_stop_disable "$BE_ID"
  if [ -f "$(xr_unit)" ]; then backup_file "$(xr_unit)" >/dev/null; run rm -f "$(xr_unit)"; run systemctl daemon-reload; fi
  if [ -f "$(xr_conf)" ]; then backup_file "$(xr_conf)" >/dev/null; run rm -f "$(xr_conf)"; fi
  log_ok "xray removed (binary and state kept)"
}
