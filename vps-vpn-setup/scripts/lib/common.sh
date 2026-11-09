#!/usr/bin/env bash
# vpnctl shared library.
#
# Look-and-feel rules that the rest of the tool depends on:
#   * stdout carries machine-readable output only (JSON, configs, lists);
#   * stderr carries human progress and warnings;
#   * every mutation goes through run(), so --dry-run is always faithful;
#   * nothing here assumes GNU coreutils beyond what a VPS kernel ships.
#
# Compatibility target: bash 3.2+ (macOS dev machines and old LTS distros),
# Linux for anything that touches the network stack.

VPNCTL_VERSION="1.1.0"
VPNCTL_SCHEMA="1"

: "${VPNCTL_STATE_DIR:=/etc/vpnctl}"
: "${VPNCTL_BACKUP_DIR:=/var/backups/vpnctl}"
: "${VPNCTL_LIB_DIR:=/usr/local/lib/vpnctl}"
: "${VPNCTL_BIN_PATH:=/usr/local/bin/vpnctl}"

DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
JSON_OUT="${JSON_OUT:-0}"
VERBOSE="${VERBOSE:-0}"

if [ -z "${NO_COLOR:-}" ] && [ -t 2 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''
fi

# --------------------------------------------------------------------------
# logging
# --------------------------------------------------------------------------

log_info() { printf '%s\n' "${C_BLUE}::${C_RESET} $*" >&2; }
log_ok()   { printf '%s\n' "${C_GREEN}ok${C_RESET} $*" >&2; }
log_warn() { printf '%s\n' "${C_YELLOW}warn${C_RESET} $*" >&2; }
log_err()  { printf '%s\n' "${C_RED}err${C_RESET} $*" >&2; }
log_step() { printf '\n%s\n' "${C_BOLD}==> $*${C_RESET}" >&2; }
log_debug() { [ "$VERBOSE" = "1" ] && printf '%s\n' "${C_DIM}debug${C_RESET} $*" >&2; return 0; }

die() { log_err "$*"; exit 2; }

# Print a command the way a human would type it (dry-run and verbose output).
log_cmd() {
  local out="" arg
  for arg in "$@"; do
    case $arg in
      *[[:space:]\'\"]*) out="$out '$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")'" ;;
      *) out="$out $arg" ;;
    esac
  done
  printf '%s\n' "${C_DIM}\$ ${out# }${C_RESET}" >&2
}

# The single choke point for side effects.
run() {
  if [ "$DRY_RUN" = "1" ]; then
    log_cmd "$@"
    return 0
  fi
  log_debug "exec: $*"
  "$@"
}

# run_shell for the handful of places that genuinely need a pipeline.
run_shell() {
  if [ "$DRY_RUN" = "1" ]; then
    log_cmd "$1"
    return 0
  fi
  log_debug "sh: $1"
  sh -c "$1"
}

# --------------------------------------------------------------------------
# environment probes
# --------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

os_field() {
  [ -r /etc/os-release ] || return 0
  sed -n "s/^$1=//p" /etc/os-release | head -n 1 | tr -d '"'
}

detect_os() {
  OS_ID="$(os_field ID)"; [ -n "$OS_ID" ] || OS_ID=unknown
  OS_NAME="$(os_field PRETTY_NAME)"; [ -n "$OS_NAME" ] || OS_NAME="$OS_ID"
  OS_LIKE="$(os_field ID_LIKE)"
  OS_VER="$(os_field VERSION_ID)"
}

pkg_manager() {
  if have apt-get; then printf 'apt'
  elif have dnf; then printf 'dnf'
  elif have yum; then printf 'yum'
  elif have pacman; then printf 'pacman'
  elif have zypper; then printf 'zypper'
  elif have apk; then printf 'apk'
  else printf 'none'; fi
}

virt_kind() {
  if have systemd-detect-virt; then
    systemd-detect-virt 2>/dev/null || printf 'none'
    return 0
  fi
  if [ -r /proc/1/cgroup ]; then
    if grep -qa 'lxc\|lxd' /proc/1/cgroup 2>/dev/null; then printf 'lxc'; return 0; fi
    if grep -qa 'docker\|kubepods' /proc/1/cgroup 2>/dev/null; then printf 'docker'; return 0; fi
  fi
  if [ -r /proc/user_beancounters ] || [ -d /proc/vz ]; then printf 'openvz'; return 0; fi
  if [ -d /sys/module/virtio_net ] || [ -d /sys/module/virtio_blk ]; then printf 'kvm'; return 0; fi
  printf 'unknown'
}

systemd_present() { [ -d /run/systemd/system ] && have systemctl; }

is_linux() { [ "$(uname -s)" = "Linux" ]; }

require_linux() {
  is_linux && return 0
  die "vpnctl requires Linux; this host is $(uname -s). Run it on the VPS (via ssh), or use 'scripts/remote.sh' from your laptop."
}

require_root() {
  [ "$(id -u)" = "0" ] && return 0
  if have sudo; then
    die "root is required. Re-run as: sudo $0 ${*:-}"
  fi
  die "root is required (uid $(id -u))."
}

require_cmd() {
  local c
  for c in "$@"; do
    have "$c" || die "missing required command: $c"
  done
}

# --------------------------------------------------------------------------
# packages
# --------------------------------------------------------------------------

_APT_UPDATED=0

apt_update_once() {
  [ "$_APT_UPDATED" = "1" ] && return 0
  _APT_UPDATED=1
  if [ "$DRY_RUN" = "1" ]; then
    log_cmd apt-get update -qq
    return 0
  fi
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >&2 || log_warn "apt-get update failed; continuing with the current index"
}

pkg_install() {
  [ "$#" -gt 0 ] || return 0
  local pm; pm="$(pkg_manager)"
  log_info "installing packages: $*"
  case $pm in
    apt)
      apt_update_once
      run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
      ;;
    dnf) run dnf install -y "$@" ;;
    yum) run yum install -y "$@" ;;
    pacman) run pacman -Sy --needed --noconfirm "$@" ;;
    zypper) run zypper --non-interactive install "$@" ;;
    apk) run apk add --no-cache "$@" ;;
    *) die "no supported package manager found; install manually: $*" ;;
  esac
}

pkg_present() {
  local pm; pm="$(pkg_manager)"
  case $pm in
    apt) dpkg -s "$1" >/dev/null 2>&1 ;;
    dnf|yum) rpm -q "$1" >/dev/null 2>&1 ;;
    pacman) pacman -Q "$1" >/dev/null 2>&1 ;;
    zypper) rpm -q "$1" >/dev/null 2>&1 ;;
    apk) apk info -e "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# ensure_pkgs PKG... -> installs only what is missing.
ensure_pkgs() {
  local missing="" p
  for p in "$@"; do
    if have "$p" || pkg_present "$p"; then continue; fi
    missing="$missing $p"
  done
  # shellcheck disable=SC2086
  [ -n "$missing" ] && pkg_install $missing
  return 0
}

# --------------------------------------------------------------------------
# services
# --------------------------------------------------------------------------

svc_active() { systemd_present && systemctl is-active --quiet "$1"; }

svc_enable_now() {
  systemd_present || die "systemd is required to manage service '$1'"
  run systemctl enable "$1" >/dev/null 2>&1 || true
  run systemctl restart "$1"
}

svc_reload() { systemd_present && run systemctl reload "$1"; }

svc_stop_disable() {
  systemd_present || return 0
  run systemctl stop "$1" >/dev/null 2>&1 || true
  run systemctl disable "$1" >/dev/null 2>&1 || true
}

wait_for_port() {
  local port="$1" proto="${2:-any}" timeout="${3:-15}" i=0
  while [ "$i" -lt "$timeout" ]; do
    if port_listening "$port" "$proto"; then return 0; fi
    i=$((i + 1)); sleep 1
  done
  return 1
}

port_listening() {
  local port="$1" proto="${2:-any}"
  have ss || return 1
  case $proto in
    tcp) ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" ;;
    udp) ss -H -lnu 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" ;;
    *)   ss -H -lntu 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" ;;
  esac
}

port_owner_hint() {
  local port="$1"
  have ss || return 0
  ss -H -lntup 2>/dev/null | grep -E "[:.]${port} " | head -n 3 || true
}

# --------------------------------------------------------------------------
# state: /etc/vpnctl/<backend>/{config,clients/,meta.env}
# --------------------------------------------------------------------------

state_root() { printf '%s' "$VPNCTL_STATE_DIR"; }
be_dir() { printf '%s/%s' "$VPNCTL_STATE_DIR" "$1"; }
be_meta() { printf '%s/%s/meta.env' "$VPNCTL_STATE_DIR" "$1"; }
be_clients_dir() { printf '%s/%s/clients' "$VPNCTL_STATE_DIR" "$1"; }

be_installed() { [ -r "$(be_meta "$1")" ]; }

# meta_get BACKEND KEY -> value or empty
meta_get() {
  local f; f="$(be_meta "$1")"
  [ -r "$f" ] || return 0
  sed -n "s/^$2=//p" "$f" | head -n 1
}

meta_set() {
  local be="$1" key="$2" val="$3" f tmp
  f="$(be_meta "$be")"; tmp="$f.tmp"
  mkdir -p "$(dirname "$f")"
  if [ -r "$f" ]; then
    sed "/^${key}=/d" "$f" > "$tmp" || return 1
  else
    : > "$tmp"
  fi
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$f"
}

meta_init() {
  local be="$1"
  mkdir -p "$(be_dir "$be")/clients"
  chmod 700 "$(be_dir "$be")" "$(be_clients_dir "$be")"
  if [ ! -r "$(be_meta "$be")" ]; then
    {
      printf 'BACKEND=%s\n' "$be"
      printf 'SCHEMA=%s\n' "$VPNCTL_SCHEMA"
      printf 'CREATED=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$(be_meta "$be")"
    chmod 600 "$(be_meta "$be")"
  fi
}

# client_file BACKEND NAME -> path of the client record (key=value)
client_file() { printf '%s/%s.env' "$(be_clients_dir "$1")" "$2"; }

client_exists() { [ -r "$(client_file "$1" "$2")" ]; }

# client_get BACKEND NAME KEY
client_get() {
  local f; f="$(client_file "$1" "$2")"
  [ -r "$f" ] || return 0
  sed -n "s/^$3=//p" "$f" | head -n 1
}

client_write() {
  local be="$1" name="$2"; shift 2
  local f tmp; f="$(client_file "$be" "$name")"; tmp="$f.tmp"
  {
    printf 'NAME=%s\n' "$name"
    local kv
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$f"
}

client_list() {
  local d; d="$(be_clients_dir "$1")"
  [ -d "$d" ] || return 0
  local f
  for f in "$d"/*.env; do
    [ -r "$f" ] || continue
    basename "$f" .env
  done | sort
}

client_count() { client_list "$1" | wc -l | tr -d ' '; }

validate_client_name() {
  local n="$1"
  case $n in
    "") die "client name is required (--name NAME)";;
  esac
  if ! printf '%s' "$n" | grep -Eq '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$'; then
    die "invalid client name '$n': use 1-32 chars of [A-Za-z0-9_-], starting with a letter or digit"
  fi
  printf '%s' "$n" | tr '[:upper:]' '[:lower:]'
}

# --------------------------------------------------------------------------
# randomness
# --------------------------------------------------------------------------

rand_hex() {
  local n="${1:-16}"
  if [ -r /dev/urandom ]; then
    od -An -tx1 -N "$n" /dev/urandom | tr -d ' \n'
  else
    printf '%s' "$(date +%s%N)$RANDOM" | sha256sum | cut -c1-$((n * 2))
  fi
}

rand_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  elif have uuidgen; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    local h; h="$(rand_hex 16)"
    printf '%s-%s-4%s-a%s-%s\n' \
      "$(printf '%s' "$h" | cut -c1-8)" \
      "$(printf '%s' "$h" | cut -c9-12)" \
      "$(printf '%s' "$h" | cut -c14-16)" \
      "$(printf '%s' "$h" | cut -c18-20)" \
      "$(printf '%s' "$h" | cut -c21-32)"
  fi
}

rand_b64() {
  local n="${1:-16}"
  if have openssl; then
    openssl rand -base64 "$n" | tr -d '\n'
  else
    head -c "$n" /dev/urandom | base64 | tr -d '\n'
  fi
}

# Percent-encode a URI component (byte-wise, ASCII-safe).
urlencode() {
  local s="$1" out="" c code i=0 n=${#1}
  while [ "$i" -lt "$n" ]; do
    c="${s:$i:1}"
    case $c in
      [a-zA-Z0-9._~-]) out="$out$c" ;;
      *)
        code=$(LC_ALL=C printf '%d' "'$c" 2>/dev/null) || code=63
        out="$out$(printf '%%%02X' "$code")"
        ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# --------------------------------------------------------------------------
# network identity
# --------------------------------------------------------------------------

default_iface() {
  ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

local_ipv4() {
  local ifc; ifc="$(default_iface)"
  [ -n "$ifc" ] || return 0
  ip -4 addr show dev "$ifc" 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}'
}

public_ipv4() {
  local cache="$VPNCTL_STATE_DIR/public-ipv4"
  if [ "${REFRESH_IP:-0}" != "1" ] && [ -r "$cache" ]; then
    local cached; cached="$(head -n 1 "$cache")"
    case $cached in
      [0-9]*.[0-9]*.[0-9]*.[0-9]*) printf '%s' "$cached"; return 0 ;;
    esac
  fi
  local url ip
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com https://ipinfo.io/ip; do
    ip="$(curl -4 -fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]')" || continue
    case $ip in
      [0-9]*.[0-9]*.[0-9]*.[0-9]*)
        # Read-only callers (probe) must not create anything: cache only when
        # the state directory already exists (i.e. after an install).
        if [ -d "$VPNCTL_STATE_DIR" ]; then
          printf '%s\n' "$ip" > "$cache" 2>/dev/null || true
        fi
        printf '%s' "$ip"; return 0 ;;
    esac
  done
  return 1
}

public_ipv6() {
  curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]' || return 1
}

# --------------------------------------------------------------------------
# files, backups, rendering
# --------------------------------------------------------------------------

backup_file() {
  local src="$1" stamp dest
  [ -e "$src" ] || return 0
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="$VPNCTL_BACKUP_DIR/$stamp/$(printf '%s' "$src" | sed 's|^/||; s|/|__|g')"
  mkdir -p "$(dirname "$dest")"
  cp -a "$src" "$dest"
  printf '%s' "$dest"
}

# install_file SRC DEST MODE -- backup + atomic replace
install_file() {
  local src="$1" dest="$2" mode="${3:-0644}"
  [ -r "$src" ] || die "install_file: missing source $src"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    log_debug "unchanged: $dest"
    return 0
  fi
  if [ -f "$dest" ]; then backup_file "$dest" >/dev/null; fi
  run mkdir -p "$(dirname "$dest")"
  if [ "$DRY_RUN" = "1" ]; then
    log_cmd install -m "$mode" "$src" "$dest"
    return 0
  fi
  install -m "$mode" "$src" "$dest.tmp.$$"
  mv "$dest.tmp.$$" "$dest"
  log_ok "wrote $dest"
}

# render_write TARGET -- reads stdin, writes atomically (or prints in dry-run)
render_write() {
  local target="$1" tmp
  if [ "$DRY_RUN" = "1" ]; then
    log_info "[dry-run] would write $target"
    return 0
  fi
  tmp="$target.tmp.$$"
  mkdir -p "$(dirname "$target")"
  cat > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$target"
}

confirm() {
  local prompt="${1:-Proceed?}"
  [ "$ASSUME_YES" = "1" ] && return 0
  if [ ! -t 0 ]; then
    die "$prompt (non-interactive: re-run with --yes)"
  fi
  printf '%s [y/N] ' "$prompt" >&2
  local answer; read -r answer || answer=""
  case $answer in
    y|Y|yes|YES) return 0 ;;
    *) die "aborted by user" ;;
  esac
}

# --------------------------------------------------------------------------
# json helpers (no jq dependency: jq is not guaranteed on a fresh VPS)
# --------------------------------------------------------------------------

json_str() {
  local s="$1" out="" c i=0 n=${#1}
  while [ "$i" -lt "$n" ]; do
    c="${s:$i:1}"
    case $c in
      '"') out="$out\\\"" ;;
      '\') out="$out\\\\" ;;
      $'\n') out="$out\\n" ;;
      $'\r') out="$out\\r" ;;
      $'\t') out="$out\\t" ;;
      *) out="$out$c" ;;
    esac
    i=$((i + 1))
  done
  printf '"%s"' "$out"
}

json_bool() { if "$@" >/dev/null 2>&1; then printf 'true'; else printf 'false'; fi; }
