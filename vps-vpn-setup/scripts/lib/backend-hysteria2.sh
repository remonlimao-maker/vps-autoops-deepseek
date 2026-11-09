#!/usr/bin/env bash
# vpnctl backend: Hysteria2
#
# Sourced by scripts/vpnctl — do not execute directly.
#
# QUIC/UDP based. Best choice when the link has loss or high latency (mobile,
# long-haul, congested transit) because it uses BBR-like congestion control and
# does not suffer TCP-over-TCP meltdown.
#
# Layout:
#   /usr/local/bin/hysteria
#   /etc/hysteria/config.yaml
#   /etc/hysteria/{cert.pem,key.pem}      self-signed unless --cert/--key given
#   /etc/systemd/system/hysteria-server.service
#   /etc/vpnctl/hysteria2/{meta.env,clients/<n>.env}

HY_PORT="${HY_PORT:-443}"
HY_SNI="${HY_SNI:-}"
HY_OBFS="${HY_OBFS:-salamander}"
HY_OBFS_PASS="${HY_OBFS_PASS:-}"
HY_MASQUERADE="${HY_MASQUERADE:-https://news.ycombinator.com/}"
HY_VERSION="${HY_VERSION:-latest}"
HY_MIRROR="${HY_MIRROR:-}"
HY_CERT="${HY_CERT:-}"
HY_KEY="${HY_KEY:-}"
HY_INCLUDE_OBFS=1

HY_BIN="/usr/local/bin/hysteria"
HY_ETC="/etc/hysteria"
HY_CONF="$HY_ETC/config.yaml"
HY_UNIT="/etc/systemd/system/hysteria-server.service"

be_info() { printf 'hysteria2|Hysteria2|QUIC/UDP|%s\n' "$HY_PORT"; }

be_parse_opts() {
  while [ "$#" -gt 0 ]; do
    case $1 in
      --port) HY_PORT="${2:-}"; shift 2 ;;
      --sni) HY_SNI="${2:-}"; shift 2 ;;
      --obfs) HY_OBFS="${2:-}"; shift 2 ;;
      --obfs-password) HY_OBFS_PASS="${2:-}"; HY_INCLUDE_OBFS=1; shift 2 ;;
      --no-obfs) HY_INCLUDE_OBFS=0; shift ;;
      --masquerade) HY_MASQUERADE="${2:-}"; shift 2 ;;
      --cert) HY_CERT="${2:-}"; shift 2 ;;
      --key) HY_KEY="${2:-}"; shift 2 ;;
      --version) HY_VERSION="${2:-}"; shift 2 ;;
      --mirror) HY_MIRROR="${2:-}"; shift 2 ;;
      -h|--help) be_help; exit 0 ;;
      *) die "hysteria2: unknown option '$1' (see: vpnctl help)" ;;
    esac
  done
  case $HY_PORT in ''|*[!0-9]*) die "invalid port: '$HY_PORT'" ;; esac
  if [ "$HY_PORT" -lt 1 ] || [ "$HY_PORT" -gt 65535 ]; then die "port out of range: $HY_PORT"; fi
  if [ -n "$HY_CERT" ] || [ -n "$HY_KEY" ]; then
    [ -r "$HY_CERT" ] || die "--cert is not readable: $HY_CERT"
    [ -r "$HY_KEY" ] || die "--key is not readable: $HY_KEY"
  fi
}

be_help() {
  cat <<EOF
hysteria2 options:
  --port N            UDP/QUIC listen port (default $HY_PORT)
  --sni HOST          TLS server name clients use (default: detected IP)
  --obfs NAME         salamander (default) | "" to disable
  --obfs-password P   obfuscation password (default: random, printed in client config)
  --no-obfs           disable obfuscation entirely
  --masquerade URL    site served to HTTP/3 probes (default $HY_MASQUERADE)
  --cert PATH         existing certificate (default: self-signed, 10y)
  --key PATH          existing private key
  --version V         pin a release (default latest)
  --mirror URL        download base when github.com is unreachable
EOF
}

# --- binary ----------------------------------------------------------------

hy_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    armv7l|armv7) printf 'arm' ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

hy_install_binary() {
  if [ -x "$HY_BIN" ]; then
    log_ok "hysteria already present: $($HY_BIN version 2>/dev/null | head -n 1)"
    return 0
  fi
  ensure_pkgs curl ca-certificates openssl
  local arch asset url tmp
  arch="$(hy_arch)"
  asset="hysteria-linux-$arch"
  if [ -n "$HY_MIRROR" ]; then
    url="${HY_MIRROR%/}/hysteria/releases/latest/download/$asset"
  elif [ "$HY_VERSION" = "latest" ]; then
    url="https://github.com/apernet/hysteria/releases/latest/download/$asset"
  else
    url="https://github.com/apernet/hysteria/releases/download/app/$HY_VERSION/$asset"
  fi
  tmp="$(mktemp -d)"
  log_info "downloading $url"
  if ! curl -fL --retry 3 --connect-timeout 10 -o "$tmp/$asset" "$url"; then
    rm -rf "$tmp"
    log_err "download failed. If github.com is unreachable, re-run with --mirror <proxy-base-url>."
    return 2
  fi
  if curl -fsSL --connect-timeout 10 -o "$tmp/$asset.sum" "$url.sha256" 2>/dev/null; then
    local want got
    want="$(grep -oiE '[a-f0-9]{64}' "$tmp/$asset.sum" | head -n 1)"
    got="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
    if [ -n "$want" ] && [ "$want" != "$got" ]; then rm -rf "$tmp"; die "sha256 mismatch for $asset"; fi
    log_ok "binary checksum verified"
  fi
  run install -m 0755 "$tmp/$asset" "$HY_BIN"
  rm -rf "$tmp"
  log_ok "installed $($HY_BIN version 2>/dev/null | head -n 1)"
}

# --- certificates ----------------------------------------------------------

hy_ensure_cert() {
  run mkdir -p "$HY_ETC"
  if [ -n "$HY_CERT" ] && [ -n "$HY_KEY" ]; then
    run install -m 0644 "$HY_CERT" "$HY_ETC/cert.pem"
    run install -m 0600 "$HY_KEY" "$HY_ETC/key.pem"
    log_ok "installed the supplied certificate"
    return 0
  fi
  if [ -s "$HY_ETC/cert.pem" ] && [ -s "$HY_ETC/key.pem" ]; then
    log_ok "keeping the existing self-signed certificate"
    return 0
  fi
  local host="$HY_SNI" san
  san="IP:${host}"
  case $host in
    *[a-zA-Z]*) san="DNS:${host}" ;;
  esac
  log_info "generating a self-signed certificate for $host (valid 10 years)"
  run openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 -subj "/CN=${host}" -addext "subjectAltName=${san}" \
    -keyout "$HY_ETC/key.pem" -out "$HY_ETC/cert.pem"
  if [ "$DRY_RUN" = "0" ]; then
    chmod 600 "$HY_ETC/key.pem" || true
    chmod 644 "$HY_ETC/cert.pem" || true
  fi
}

hy_cert_fingerprint() {
  [ -r "$HY_ETC/cert.pem" ] || return 0
  openssl x509 -in "$HY_ETC/cert.pem" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//' | tr -d ':'
}

# --- config ----------------------------------------------------------------

hy_render_config() {
  printf '# Generated by vpnctl %s — re-run `vpnctl install hysteria2` instead of editing\n' "$VPNCTL_VERSION"
  printf 'listen: :%s\n\n' "$HY_PORT"
  printf 'tls:\n  cert: %s\n  key: %s\n\n' "$HY_ETC/cert.pem" "$HY_ETC/key.pem"
  printf 'auth:\n  type: userpass\n  userpass:\n'
  local n
  for n in $(client_list hysteria2); do
    printf '    %s: "%s"\n' "$n" "$(client_get hysteria2 "$n" PASSWORD)"
  done
  printf '\n'
  if [ "$HY_INCLUDE_OBFS" = "1" ]; then
    printf 'obfs:\n  type: %s\n  %s:\n    password: "%s"\n\n' "$HY_OBFS" "$HY_OBFS" "$HY_OBFS_PASS"
  fi
  printf 'masquerade:\n  type: proxy\n  proxy:\n    url: %s\n    rewriteHost: true\n\n' "$HY_MASQUERADE"
  printf 'bandwidth:\n  up: 1 gbps\n  down: 1 gbps\n'
}

hy_write_unit() {
  local tmp="/tmp/vpnctl-hy-unit.$$"
  {
    printf '# installed by vpnctl\n[Unit]\nDescription=Hysteria2 Server (vpnctl)\n'
    printf 'After=network-online.target\nWants=network-online.target\n\n'
    printf '[Service]\nType=simple\nExecStart=%s server -c %s\n' "$HY_BIN" "$HY_CONF"
    printf 'Restart=on-failure\nRestartSec=5s\nLimitNOFILE=1048576\n\n'
    printf '[Install]\nWantedBy=multi-user.target\n'
  } > "$tmp"
  install_file "$tmp" "$HY_UNIT" 0644
  rm -f "$tmp"
  run systemctl daemon-reload
}

hy_apply() {
  # An imported instance keeps its own hand-written config: rewriting it would
  # clobber a working service that vpnctl did not create.
  if [ "$(meta_get hysteria2 IMPORTED)" = "1" ]; then
    log_warn "hysteria2 was imported: vpnctl will not rewrite $HY_CONF"
    return 0
  fi
  hy_render_config > /tmp/vpnctl-hy.$$.yaml
  install_file /tmp/vpnctl-hy.$$.yaml "$HY_CONF" 0600
  rm -f /tmp/vpnctl-hy.$$.yaml
  if svc_active hysteria-server; then run systemctl restart hysteria-server; else svc_enable_now hysteria-server; fi
}

# --- client artifacts ------------------------------------------------------

hy_client_uri() {
  local name="$1" host="$2" pass obfs_q
  pass="$(client_get hysteria2 "$name" PASSWORD)"
  obfs_q=""
  if [ "$HY_INCLUDE_OBFS" = "1" ]; then
    obfs_q="&obfs=$(urlencode "$HY_OBFS")&obfs-password=$(urlencode "$HY_OBFS_PASS")"
  fi
  printf 'hysteria2://%s:%s@%s:%s/?sni=%s&insecure=1%s#%s\n' \
    "$(urlencode "$name")" "$(urlencode "$pass")" "$host" "$HY_PORT" \
    "$(urlencode "$HY_SNI")" "$obfs_q" "$(urlencode "$name")"
}

be_from_state() {
  local v
  v="$(meta_get hysteria2 PORT)";      if [ -n "$v" ]; then HY_PORT="$v"; fi
  v="$(meta_get hysteria2 SNI)";       if [ -n "$v" ]; then HY_SNI="$v"; fi
  v="$(meta_get hysteria2 OBFS)";      if [ -n "$v" ]; then HY_OBFS="$v"; fi
  v="$(meta_get hysteria2 OBFS_PASS)"; if [ -n "$v" ]; then HY_OBFS_PASS="$v"; fi
  v="$(meta_get hysteria2 MASQUERADE)";if [ -n "$v" ]; then HY_MASQUERADE="$v"; fi
  if [ "$(meta_get hysteria2 OBFS_ENABLED)" = "0" ]; then HY_INCLUDE_OBFS=0; fi
  return 0
}

be_print_plan() {
  cat <<EOF
Plan: Hysteria2 on this host
  1. install   hysteria binary ($(hy_arch)) -> $HY_BIN
  2. cert      self-signed EC cert for ${HY_SNI:-<detected ip>} (or --cert/--key)
  3. write     $HY_CONF  (listen :$HY_PORT/udp, userpass auth, masquerade $HY_MASQUERADE)
  4. obfs      $([ "$HY_INCLUDE_OBFS" = "1" ] && echo "$HY_OBFS (QUIC obfuscation)" || echo "disabled")
  5. unit      $HY_UNIT
  6. firewall  stays closed until: vpnctl harden   (UDP/$HY_PORT must be allowed)

Clients are added later:
  vpnctl client hysteria2 add --name phone --yes
EOF
}

be_install() {
  meta_init hysteria2
  if port_listening "$HY_PORT" udp && ! svc_active hysteria-server; then
    log_err "UDP/$HY_PORT is already in use:"
    port_owner_hint "$HY_PORT" >&2 || true
    die "pick another port with --port"
  fi

  hy_install_binary

  local ip; ip="$(public_ipv4 || true)"
  if [ -z "$ip" ]; then log_warn "public IPv4 unknown; using local address"; ip="$(local_ipv4 || true)"; fi
  [ -n "$ip" ] || die "cannot determine the host address"
  if [ -z "$HY_SNI" ]; then HY_SNI="$ip"; fi
  if [ "$HY_INCLUDE_OBFS" = "1" ] && [ -z "$HY_OBFS_PASS" ]; then HY_OBFS_PASS="$(rand_hex 8)"; fi

  hy_ensure_cert

  meta_set hysteria2 PORT "$HY_PORT"
  meta_set hysteria2 SNI "$HY_SNI"
  meta_set hysteria2 PUBLIC_IP "$ip"
  meta_set hysteria2 OBFS "$HY_OBFS"
  meta_set hysteria2 OBFS_PASS "$HY_OBFS_PASS"
  meta_set hysteria2 OBFS_ENABLED "$HY_INCLUDE_OBFS"
  meta_set hysteria2 MASQUERADE "$HY_MASQUERADE"
  meta_set hysteria2 PROTO "udp"
  meta_set hysteria2 CONFIG "$HY_CONF"
  meta_set hysteria2 SERVICE "hysteria-server"
  meta_set hysteria2 CERT_SHA256 "$(hy_cert_fingerprint)"
  if [ -n "$HY_CERT" ]; then meta_set hysteria2 CERT_SOURCE "provided"; else meta_set hysteria2 CERT_SOURCE "self-signed"; fi
  local hv; hv="$("$HY_BIN" version 2>/dev/null | head -n 1 | awk '{print $3}')"
  if [ -n "$hv" ]; then meta_set hysteria2 VERSION "$hv"; fi

  hy_write_unit
  hy_apply

  if ! wait_for_port "$HY_PORT" udp 10; then
    log_warn "UDP/$HY_PORT not visible in 'ss' yet; check: journalctl -u hysteria-server -n 30"
  fi
  log_ok "Hysteria2 listening on UDP/$HY_PORT (self-signed TLS)"
  if [ -n "$(meta_get hysteria2 CERT_SHA256)" ]; then
    log_info "cert sha256 (for pinning instead of insecure=1): $(meta_get hysteria2 CERT_SHA256)"
  fi
}

be_client_add() {
  if [ "$(meta_get hysteria2 IMPORTED)" = "1" ]; then
    die "this node was imported: edit $HY_CONF by hand, then re-run: vpnctl import hysteria2"
  fi
  local name="$1"
  client_write hysteria2 "$name" \
    "PASSWORD=$(rand_hex 10)" \
    "CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  hy_apply
  log_ok "added client $name"
}

be_client_remove() {
  if [ "$(meta_get hysteria2 IMPORTED)" = "1" ]; then
    die "this node was imported: edit $HY_CONF by hand, then re-run: vpnctl import hysteria2"
  fi
  rm -f "$(client_file hysteria2 "$1")"
  hy_apply
}

be_client_export() {
  local name="$1" outdir="${2:-}" dir host pass
  host="$(meta_get hysteria2 PUBLIC_IP)"
  if [ -z "$outdir" ]; then dir="${HOME:-/root}/vpn-clients/hysteria2/$name"; else dir="$outdir"; fi
  mkdir -p "$dir"
  pass="$(client_get hysteria2 "$name" PASSWORD)"

  hy_client_uri "$name" "$host" > "$dir/uri.txt"
  chmod 600 "$dir/uri.txt"

  {
    printf 'server: %s:%s\n' "$host" "$HY_PORT"
    printf 'auth: %s:%s\n' "$name" "$pass"
    printf 'tls:\n  sni: %s\n  insecure: true\n' "$HY_SNI"
    if [ "$HY_INCLUDE_OBFS" = "1" ]; then
      printf 'obfs:\n  type: %s\n  %s:\n    password: "%s"\n' "$HY_OBFS" "$HY_OBFS" "$HY_OBFS_PASS"
    fi
    printf 'socks5:\n  listen: 127.0.0.1:1080\n'
    printf 'http:\n  listen: 127.0.0.1:8080\n'
  } > "$dir/client.yaml"
  chmod 600 "$dir/client.yaml"

  {
    printf 'backend: hysteria2\nclient:  %s\n' "$name"
    printf 'server:  %s:%s (UDP)\nauth:    %s\n' "$host" "$HY_PORT" "$pass"
    printf 'sni:     %s\n' "$HY_SNI"
    if [ -n "$(meta_get hysteria2 CERT_SHA256)" ]; then
      printf 'pin:     sha256:%s\n' "$(meta_get hysteria2 CERT_SHA256)"
    fi
    printf '\nImport: paste uri.txt into the client (NekoBox/Karing/sing-box/mihomo)\n'
    printf 'CLI:    hysteria client -c client.yaml\n'
  } > "$dir/info.txt"

  if have qrencode; then
    qrencode -o "$dir/$name.png" -r "$dir/uri.txt" 2>/dev/null && printf '%s\n' "$dir/$name.png" || true
  fi
  printf '%s\n' "$dir/uri.txt" "$dir/client.yaml"
  log_ok "client files in $dir"
}

be_verify() {
  local ok=1 checks="" svc=ok
  if svc_active hysteria-server; then checks="$checks service=up"; else checks="$checks service=down"; ok=0; fi
  if [ -r "$HY_CONF" ]; then checks="$checks config=present"; else checks="$checks config=missing"; ok=0; fi
  if [ -s "$HY_ETC/cert.pem" ]; then
    checks="$checks cert=ok"
  else
    checks="$checks cert=missing"; ok=0
  fi
  if port_listening "$HY_PORT" udp; then checks="$checks udp=$HY_PORT"; else checks="$checks udp=unconfirmed"; fi
  checks="$checks clients=$(client_count hysteria2)"
  if [ "$JSON_OUT" = "1" ]; then
    printf '{"backend":"hysteria2","ok":%s,"checks":%s,"port":%s}\n' \
      "$([ "$ok" = "1" ] && printf true || printf false)" "$(json_str "${checks# }")" "$HY_PORT"
  else
    printf 'hysteria2: %s\n' "$([ "$ok" = "1" ] && echo OK || echo FAILED)"
    printf '  %s\n' "${checks# }"
  fi
  [ "$ok" = "1" ]
}

be_uninstall() {
  svc_stop_disable hysteria-server
  if [ -f "$HY_UNIT" ]; then backup_file "$HY_UNIT" >/dev/null; run rm -f "$HY_UNIT"; run systemctl daemon-reload; fi
  if [ -f "$HY_CONF" ]; then backup_file "$HY_CONF" >/dev/null; run rm -f "$HY_CONF"; fi
  log_ok "hysteria2 removed (binary, cert and state kept)"
}
