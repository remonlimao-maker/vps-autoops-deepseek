#!/usr/bin/env bash
# vpnctl backend: Trojan (TLS, Xray-hosted)
#
# Sourced by scripts/vpnctl — do not execute directly.
#
# Trojan authenticates with a password inside a real TLS session, so it needs a
# domain that resolves to this host plus a certificate the client can verify.
# It reuses the Xray binary and the per-instance unit pattern from
# backend-xray.sh; only the inbound, the certificate handling and the client
# artefacts differ.
#
# Certificate sources, in order of preference:
#   1. --cert / --key      bring your own (Cloudflare Origin, commercial, ...)
#   2. certbot standalone  automatic Let's Encrypt, with a renewal hook
#   3. --self-signed       fallback; clients must disable verification

# Reuse the Xray binary installer, unit writer and apply/restart logic.
if ! declare -f xr_install_binary >/dev/null 2>&1; then
  . "${LIB_DIR:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/backend-xray.sh"
fi

BE_DOMAIN="${BE_DOMAIN:-}"
BE_ACME_EMAIL="${BE_ACME_EMAIL:-}"
BE_CERT="${BE_CERT:-}"
BE_KEY="${BE_KEY:-}"
BE_SELF_SIGNED="${BE_SELF_SIGNED:-0}"
TJ_ALPN="${TJ_ALPN:-http/1.1}"

be_mode() { printf 'trojan'; }
be_default_port() { printf '8443'; }

be_parse_opts() {
  [ -n "$XR_PORT" ] || XR_PORT="$(be_default_port)"
  while [ "$#" -gt 0 ]; do
    case $1 in
      --port) XR_PORT="${2:-}"; shift 2 ;;
      --domain) BE_DOMAIN="${2:-}"; shift 2 ;;
      --acme-email|--email) BE_ACME_EMAIL="${2:-}"; shift 2 ;;
      --cert) BE_CERT="${2:-}"; shift 2 ;;
      --key) BE_KEY="${2:-}"; shift 2 ;;
      --self-signed) BE_SELF_SIGNED=1; shift ;;
      --alpn) TJ_ALPN="${2:-}"; shift 2 ;;
      -h|--help) be_help; exit 0 ;;
      *) die "trojan: unknown option '$1' (see: vpnctl help)" ;;
    esac
  done
  validate_xr_port "$XR_PORT"
  case $BE_DOMAIN in
    "") ;;
    *[!a-zA-Z0-9.-]*) die "trojan: invalid domain '$BE_DOMAIN'" ;;
  esac
  if [ -n "$BE_CERT" ] || [ -n "$BE_KEY" ]; then
    [ -n "$BE_CERT" ] && [ -n "$BE_KEY" ] || die "trojan: --cert and --key must be given together"
    [ -r "$BE_CERT" ] || die "trojan: --cert is not readable: $BE_CERT"
    [ -r "$BE_KEY" ] || die "trojan: --key is not readable: $BE_KEY"
  fi
}

be_help() {
  cat <<EOF
trojan options:
  --domain HOST       domain pointing at this host (required; becomes the SNI)
  --acme-email ADDR   email for Let's Encrypt registration
  --cert PATH         existing certificate chain (with --key)
  --key PATH          existing private key
  --self-signed       skip ACME and generate a self-signed cert (clients must skip verification)
  --port N            TCP listen port (default $XR_PORT)
  --alpn LIST         ALPN for the TLS listener (default $TJ_ALPN)
EOF
}

be_from_state() {
  local v
  v="$(meta_get "$BE_ID" PORT)";   if [ -n "$v" ]; then XR_PORT="$v"; fi
  v="$(meta_get "$BE_ID" DOMAIN)"; if [ -n "$v" ]; then BE_DOMAIN="$v"; fi
  v="$(meta_get "$BE_ID" ALPN)";   if [ -n "$v" ]; then TJ_ALPN="$v"; fi
  return 0
}

# --- certificates ----------------------------------------------------------

tj_tls_dir() { printf '%s/tls' "$(be_dir "$BE_ID")"; }

tj_install_cert_files() {
  local src_cert="$1" src_key="$2" dir
  dir="$(tj_tls_dir)"
  run mkdir -p "$dir"
  run install -m 0644 "$src_cert" "$dir/cert.pem"
  run install -m 0600 "$src_key" "$dir/key.pem"
  # Xray runs as nobody: give it sole read access to the key.
  if [ "$DRY_RUN" = "0" ] && have chown; then
    chown nobody "$dir/key.pem" 2>/dev/null || log_warn "could not chown $dir/key.pem to nobody"
    chmod 600 "$dir/key.pem" 2>/dev/null || true
    chmod 644 "$dir/cert.pem" 2>/dev/null || true
  fi
}

tj_acme() {
  ensure_pkgs certbot
  have certbot || { log_warn "certbot is unavailable in this distro's repositories"; return 1; }
  if port_listening 80 tcp; then
    log_err "TCP/80 is already in use; Let's Encrypt HTTP-01 standalone needs it free"
    return 1
  fi
  local live="/etc/letsencrypt/live/$BE_DOMAIN"
  if [ ! -s "$live/fullchain.pem" ]; then
    log_info "requesting a Let's Encrypt certificate for $BE_DOMAIN"
    local rc=0
    if [ -n "$BE_ACME_EMAIL" ]; then
      run certbot certonly --standalone -d "$BE_DOMAIN" --email "$BE_ACME_EMAIL" \
        --agree-tos --non-interactive --keep-until-expiring || rc=$?
    else
      run certbot certonly --standalone -d "$BE_DOMAIN" --register-unsafely-without-email \
        --agree-tos --non-interactive --keep-until-expiring || rc=$?
    fi
    if [ "$rc" != "0" ]; then
      log_err "certbot failed (DNS not pointing here? port 80 blocked? rate limit?)"
      return 1
    fi
  fi
  [ -s "$live/fullchain.pem" ] || return 1
  tj_install_cert_files "$live/fullchain.pem" "$live/privkey.pem"
  tj_write_renew_hook "$live"
  return 0
}

# certbot renews on a timer; copy the new certs and reload Xray when it does.
tj_write_renew_hook() {
  local live="$1" hook="/etc/letsencrypt/renewal-hooks/deploy/vpnctl-$BE_ID.sh" tmp
  tmp="/tmp/vpnctl-hook.$$"
  {
    printf '#!/bin/sh\n'
    printf '# installed by vpnctl: refresh the Trojan certificate and reload Xray\n'
    printf 'set -eu\n'
    printf 'install -m 0644 %s/fullchain.pem %s/cert.pem\n' "$live" "$(tj_tls_dir)"
    printf 'install -m 0600 %s/privkey.pem %s/key.pem\n' "$live" "$(tj_tls_dir)"
    printf 'chown nobody %s/key.pem || true\n' "$(tj_tls_dir)"
    printf 'systemctl restart %s\n' "$BE_ID"
  } > "$tmp"
  install_file "$tmp" "$hook" 0755
  rm -f "$tmp"
}

tj_self_signed() {
  ensure_pkgs openssl
  local dir; dir="$(tj_tls_dir)"
  run mkdir -p "$dir"
  log_warn "using a self-signed certificate: clients must enable 'skip certificate verification'"
  run openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 825 \
    -subj "/CN=$BE_DOMAIN" -addext "subjectAltName=DNS:$BE_DOMAIN" \
    -keyout "$dir/key.pem" -out "$dir/cert.pem"
  if [ "$DRY_RUN" = "0" ]; then
    chmod 600 "$dir/key.pem" || true
    chown nobody "$dir/key.pem" 2>/dev/null || true
    chmod 644 "$dir/cert.pem" || true
  fi
}

tj_ensure_cert() {
  local dir; dir="$(tj_tls_dir)"
  if [ -n "$BE_CERT" ]; then
    tj_install_cert_files "$BE_CERT" "$BE_KEY"
    meta_set "$BE_ID" CERT_SOURCE "provided"
    return 0
  fi
  if [ -s "$dir/cert.pem" ] && [ -s "$dir/key.pem" ]; then
    log_ok "keeping the existing certificate in $dir"
    return 0
  fi
  if [ "$BE_SELF_SIGNED" != "1" ]; then
    if tj_acme; then meta_set "$BE_ID" CERT_SOURCE "acme"; return 0; fi
    log_warn "falling back to a self-signed certificate"
  fi
  tj_self_signed
  meta_set "$BE_ID" CERT_SOURCE "self-signed"
}

# --- config ----------------------------------------------------------------

xr_render_config() {
  local dir; dir="$(tj_tls_dir)"
  printf '{\n'
  printf '  "log": {"loglevel": "warning", "access": "none"},\n'
  printf '  "inbounds": [\n'
  printf '    {\n'
  printf '      "tag": "trojan",\n'
  printf '      "listen": "0.0.0.0",\n'
  printf '      "port": %s,\n' "$XR_PORT"
  printf '      "protocol": "trojan",\n'
  printf '      "settings": {\n'
  printf '        "clients": [\n'
  local first=1 n
  for n in $(client_list "$BE_ID"); do
    [ -n "$(client_get "$BE_ID" "$n" PASSWORD)" ] || continue
    [ "$first" = "1" ] || printf ',\n'
    first=0
    printf '          {"password": %s, "email": %s}' \
      "$(json_str "$(client_get "$BE_ID" "$n" PASSWORD)")" "$(json_str "$n")"
  done
  printf '\n        ],\n'
  printf '        "fallbacks": [{"dest": 80}]\n'
  printf '      },\n'
  printf '      "streamSettings": {\n'
  printf '        "network": "tcp",\n'
  printf '        "security": "tls",\n'
  printf '        "tlsSettings": {\n'
  printf '          "certificates": [{\n'
  printf '            "certificateFile": %s,\n' "$(json_str "$dir/cert.pem")"
  printf '            "keyFile": %s\n' "$(json_str "$dir/key.pem")"
  printf '          }],\n'
  printf '          "alpn": [%s],\n' "$(json_str "$TJ_ALPN")"
  printf '          "minVersion": "1.2"\n'
  printf '        }\n'
  printf '      },\n'
  printf '      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}\n'
  printf '    }\n'
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

# --- plan ------------------------------------------------------------------

be_print_plan() {
  local csource="Let's Encrypt via certbot"
  if [ -n "$BE_CERT" ]; then csource="the certificate you provided ($BE_CERT)"
  elif [ "$BE_SELF_SIGNED" = "1" ]; then csource="self-signed (clients must skip verification)"; fi
  cat <<EOF
Plan: Trojan on this host
  1. require   xray-core binary (shared with xray-reality / ss2022)
  2. require   domain $([ -n "$BE_DOMAIN" ] && printf '%s' "$BE_DOMAIN" || printf '<missing: pass --domain>')
  3. cert      $csource -> $(tj_tls_dir)
  4. write     $(xr_conf)  (port $XR_PORT/tcp, ALPN $TJ_ALPN, fallback to :80 for probes)
  5. unit      $(xr_unit)  (systemd, user nobody)
  6. firewall  stays closed until: vpnctl harden

Clients are added later:
  vpnctl client trojan add --name phone --yes
EOF
}

# --- install ---------------------------------------------------------------

be_install() {
  [ -n "$BE_DOMAIN" ] || die "trojan needs --domain: Trojan is verified inside TLS, so clients must connect by name"
  meta_init "$BE_ID"

  if port_listening "$XR_PORT" tcp && ! svc_active "$BE_ID"; then
    log_err "TCP/$XR_PORT is already in use:"
    port_owner_hint "$XR_PORT" >&2 || true
    die "pick another port with --port"
  fi

  xr_install_binary

  local ip; ip="$(public_ipv4 || true)"
  if [ -z "$ip" ]; then log_warn "public IPv4 unknown"; ip="$(local_ipv4 || true)"; fi

  tj_ensure_cert

  meta_set "$BE_ID" MODE "trojan"
  meta_set "$BE_ID" PORT "$XR_PORT"
  meta_set "$BE_ID" PROTO "tcp"
  meta_set "$BE_ID" PUBLIC_IP "$ip"
  meta_set "$BE_ID" DOMAIN "$BE_DOMAIN"
  meta_set "$BE_ID" ALPN "$TJ_ALPN"
  meta_set "$BE_ID" CONFIG "$(xr_conf)"
  meta_set "$BE_ID" SERVICE "$BE_ID"

  xr_write_unit
  xr_apply
  log_ok "trojan listening on TCP/$XR_PORT (domain $BE_DOMAIN, cert $(meta_get "$BE_ID" CERT_SOURCE))"
}

# --- clients ---------------------------------------------------------------

be_client_add() {
  local name="$1"
  client_write "$BE_ID" "$name" \
    "PASSWORD=${CLIENT_PASSWORD:-$(rand_hex 16)}" \
    "CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  xr_apply
  log_ok "added client $name"
}

be_client_remove() {
  rm -f "$(client_file "$BE_ID" "$1")"
  xr_apply
}

xr_client_uri() {
  local name="$1" host pass
  host="$(meta_get "$BE_ID" DOMAIN)"
  pass="$(client_get "$BE_ID" "$name" PASSWORD)"
  local insecure=0
  if [ "$(meta_get "$BE_ID" CERT_SOURCE)" = "self-signed" ]; then insecure=1; fi
  printf 'trojan://%s@%s:%s?security=tls&sni=%s&type=tcp&alpn=%s&allowInsecure=%s#%s\n' \
    "$(urlencode "$pass")" "$host" "$XR_PORT" "$(urlencode "$host")" \
    "$(urlencode "$TJ_ALPN")" "$insecure" "$(urlencode "$name")"
}

be_client_export() {
  local name="$1" outdir="${2:-}" dir host pass
  host="$(meta_get "$BE_ID" DOMAIN)"
  pass="$(client_get "$BE_ID" "$name" PASSWORD)"
  if [ -z "$outdir" ]; then dir="${HOME:-/root}/vpn-clients/$BE_ID/$name"; else dir="$outdir"; fi
  mkdir -p "$dir"

  xr_client_uri "$name" > "$dir/uri.txt"
  chmod 600 "$dir/uri.txt"

  {
    printf 'backend: trojan\n'
    printf 'client:  %s\n' "$name"
    printf 'server:  %s:%s (TLS)\n' "$host" "$XR_PORT"
    printf 'password:%s\n' "$pass"
    printf 'sni:     %s\n' "$host"
    printf 'alpn:    %s\n' "$TJ_ALPN"
    printf 'cert:    %s\n' "$(meta_get "$BE_ID" CERT_SOURCE)"
    if [ "$(meta_get "$BE_ID" CERT_SOURCE)" = "self-signed" ]; then
      printf 'warning: self-signed certificate — enable "skip certificate verification" in the client\n'
    fi
    printf '\nImport: paste uri.txt (v2rayN / v2rayNG / NekoBox / Shadowrocket / Clash mihomo)\n'
  } > "$dir/info.txt"

  if have qrencode; then
    qrencode -o "$dir/$name.png" -r "$dir/uri.txt" 2>/dev/null && printf '%s\n' "$dir/$name.png" || true
  fi
  printf '%s\n' "$dir/uri.txt"
  log_ok "client files in $dir"
}

# --- verify / uninstall ----------------------------------------------------

be_verify() {
  local ok=1 checks="" out dir
  dir="$(tj_tls_dir)"
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
  if [ -s "$dir/cert.pem" ] && [ -s "$dir/key.pem" ]; then
    checks="$checks cert=present"
    local end; end="$(openssl x509 -in "$dir/cert.pem" -noout -enddate 2>/dev/null | sed 's/notAfter=//')"
    if [ -n "$end" ] && date -d "$end" +%s >/dev/null 2>&1; then
      local left=$(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
      checks="$checks cert_days=$left"
      if [ "$left" -lt 7 ]; then log_warn "certificate expires in $left days"; fi
    fi
  else
    checks="$checks cert=missing"; ok=0
  fi
  if port_listening "$XR_PORT" tcp; then checks="$checks tcp=$XR_PORT"; else checks="$checks tcp=unconfirmed"; fi
  checks="$checks clients=$(client_count "$BE_ID")"
  if [ "$JSON_OUT" = "1" ]; then
    printf '{"backend":"trojan","ok":%s,"checks":%s,"port":%s,"domain":%s}\n' \
      "$([ "$ok" = "1" ] && printf true || printf false)" "$(json_str "${checks# }")" \
      "$XR_PORT" "$(json_str "$(meta_get "$BE_ID" DOMAIN)")"
  else
    printf 'trojan: %s\n' "$([ "$ok" = "1" ] && echo OK || echo FAILED)"
    printf '  %s\n' "${checks# }"
  fi
  [ "$ok" = "1" ]
}

be_uninstall() {
  svc_stop_disable "$BE_ID"
  if [ -f "$(xr_unit)" ]; then backup_file "$(xr_unit)" >/dev/null; run rm -f "$(xr_unit)"; run systemctl daemon-reload; fi
  if [ -f "$(xr_conf)" ]; then backup_file "$(xr_conf)" >/dev/null; run rm -f "$(xr_conf)"; fi
  run rm -f "/etc/letsencrypt/renewal-hooks/deploy/vpnctl-$BE_ID.sh"
  log_ok "trojan removed (certificates and state kept)"
}
