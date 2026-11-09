#!/usr/bin/env bash
# vpsctl shared library — deliberately small: logging, state, json, confirm.
#
# Same contract as vpnctl: stdout is machine-readable, stderr is for humans,
# every mutation goes through run() so --dry-run stays honest.

VPSCTL_VERSION="1.0.0"
VPSCTL_SCHEMA="1"

: "${VPSCTL_HOME:=$HOME/.vpsctl}"

DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
JSON_OUT="${JSON_OUT:-0}"
VERBOSE="${VERBOSE:-0}"

if [ -z "${NO_COLOR:-}" ] && [ -t 2 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BOLD=''
fi

log_info() { printf '%s\n' "${C_DIM}::${C_RESET} $*" >&2; }
log_ok()   { printf '%s\n' "${C_GREEN}ok${C_RESET} $*" >&2; }
log_warn() { printf '%s\n' "${C_YELLOW}warn${C_RESET} $*" >&2; }
log_err()  { printf '%s\n' "${C_RED}err${C_RESET} $*" >&2; }
log_step() { printf '\n%s\n' "${C_BOLD}==> $*${C_RESET}" >&2; }
log_debug() { [ "$VERBOSE" = "1" ] && printf '%s\n' "${C_DIM}debug${C_RESET} $*" >&2; return 0; }

die() { log_err "$*"; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }

log_cmd() {
  local out="" a
  for a in "$@"; do
    case $a in
      *[[:space:]]*) out="$out '$a'" ;;
      *) out="$out $a" ;;
    esac
  done
  printf '%s\n' "${C_DIM}\$ ${out# }${C_RESET}" >&2
}

run() {
  if [ "$DRY_RUN" = "1" ]; then log_cmd "$@"; return 0; fi
  log_debug "exec: $*"
  "$@"
}

confirm() {
  local prompt="${1:-Proceed?}"
  [ "$ASSUME_YES" = "1" ] && return 0
  [ -t 0 ] || die "$prompt (non-interactive: re-run with --yes)"
  printf '%s [y/N] ' "$prompt" >&2
  local a; read -r a || a=""
  case $a in y|Y|yes|YES) return 0 ;; *) die "aborted" ;; esac
}

# --- instance state --------------------------------------------------------
instances_dir() { printf '%s/instances' "$VPSCTL_HOME"; }
instance_file() { printf '%s/%s.env' "$(instances_dir)" "$1"; }
instance_exists() { [ -r "$(instance_file "$1")" ]; }

instance_get() {
  local f; f="$(instance_file "$1")"
  [ -r "$f" ] || return 0
  sed -n "s/^$2=//p" "$f" | head -n 1
}

instance_save() {
  local name="$1"; shift
  local f; f="$(instance_file "$name")"
  run mkdir -p "$(instances_dir)"
  if [ "$DRY_RUN" = "1" ]; then log_cmd mkdir -p "$(dirname "$f")" "&&" write "$f"; return 0; fi
  {
    printf 'NAME=%s\n' "$name"
    local kv; for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "$f"
  chmod 600 "$f"
}

instance_list() {
  local d; d="$(instances_dir)"
  [ -d "$d" ] || return 0
  local f
  for f in "$d"/*.env; do
    [ -r "$f" ] || continue
    basename "$f" .env
  done | sort
}

instance_forget() { run rm -f "$(instance_file "$1")"; }

validate_name() {
  local n="$1"
  case $n in
    "") die "instance name required (--name)" ;;
    *[!A-Za-z0-9-]*) die "invalid name '$n': letters, digits and dashes only" ;;
  esac
  case $n in
    [A-Za-z]*) ;;
    *) die "name must start with a letter: '$n'" ;;
  esac
  return 0
}

# --- json ------------------------------------------------------------------
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

# Format a millisecond-ish duration for humans.
fmt_secs() {
  local s="$1"
  if [ "$s" -lt 60 ]; then printf '%ss' "$s"; else printf '%dm%02ds' $((s / 60)) $((s % 60)); fi
}
