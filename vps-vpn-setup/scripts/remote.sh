#!/usr/bin/env bash
# remote.sh — drive vpnctl on a VPS from your workstation.
#
# The skill bundle lives on your machine; the VPS only needs sshd. This script
# ships the scripts over, bootstraps them into /usr/local, and runs commands.
#
#   scripts/remote.sh connect root@203.0.113.5           # verify ssh + sudo before doing anything
#   scripts/remote.sh deploy root@203.0.113.5            # everything, one command
#   scripts/remote.sh test   root@203.0.113.5            # full lifecycle acceptance run
#   scripts/remote.sh push   root@203.0.113.5
#   scripts/remote.sh probe  root@203.0.113.5
#   scripts/remote.sh run    root@203.0.113.5 install wireguard --yes
#   scripts/remote.sh pull   root@203.0.113.5 ./vpn-clients
#
# Options (before the command):
#   -p PORT        ssh port (default 22)
#   -i KEYFILE     identity file
#   -o OPTION      extra ssh option, repeatable (e.g. -o StrictHostKeyChecking=no)
#   --sudo         run privileged commands through sudo -n (non-root login)
#   --remote-dir D bundle location on the server (default ~/.vpnctl)
#   -b, --backend  backend for deploy (default auto)
#   -c, --client   client name for deploy (default default)
#   --domain D     domain for the trojan node when deploying --backend all
#   --cn           clients are in mainland China: prefer REALITY on TCP/443

set -euo pipefail

SSH_PORT=22
SSH_KEY=""
SSH_EXTRA=""
USE_SUDO=0
REMOTE_DIR='$HOME/.vpnctl'
VERBOSE=0
DEPLOY_BACKEND="auto"
DEPLOY_CLIENT="default"
DEPLOY_DOMAIN=""
DEPLOY_CN=0

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(dirname "$SCRIPT_DIR")"

log() { printf ':: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 2; }

# Print the leading comment block, whatever its length.
usage() {
  awk 'NR > 1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else { exit } }' "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

while [ "$#" -gt 0 ]; do
  case $1 in
    -p) SSH_PORT="${2:?-p needs a port}"; shift 2 ;;
    -i) SSH_KEY="${2:?-i needs a file}"; shift 2 ;;
    -o) SSH_EXTRA="$SSH_EXTRA $2"; shift 2 ;;
    --sudo) USE_SUDO=1; shift ;;
    --remote-dir) REMOTE_DIR="$2"; shift 2 ;;
    -b|--backend) DEPLOY_BACKEND="${2:?--backend needs a value}"; shift 2 ;;
    -c|--client) DEPLOY_CLIENT="${2:?--client needs a value}"; shift 2 ;;
    --domain) DEPLOY_DOMAIN="${2:?--domain needs a value}"; shift 2 ;;
    --cn) DEPLOY_CN=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) usage ;;
    --) shift; break ;;
    *) break ;;
  esac
done

ACTION="${1:-}"; shift || true
TARGET="${1:-}"; shift || true

[ -n "$ACTION" ] && [ -n "$TARGET" ] || usage 2
case $TARGET in
  -*|"") die "target must be user@host" ;;
esac

# accept-new: an agent has no tty to answer the host-key prompt, but we still
# refuse a changed key on a host we have already seen (that is a real signal).
SSH_ARGS=(-p "$SSH_PORT" -o ConnectTimeout=10 -o ServerAliveInterval=15 -o StrictHostKeyChecking=accept-new)
[ -n "$SSH_KEY" ] && SSH_ARGS+=(-i "$SSH_KEY")
# shellcheck disable=SC2206
[ -n "$SSH_EXTRA" ] && SSH_ARGS+=($SSH_EXTRA)
[ "$VERBOSE" = "1" ] && SSH_ARGS+=(-v)

ssh_run() { ssh "${SSH_ARGS[@]}" "$TARGET" "$@"; }
scp_run() { scp -P "$SSH_PORT" ${SSH_KEY:+-i "$SSH_KEY"} "$@"; }

# Wrap a command in sudo when the login user is not root.
priv() {
  if [ "$USE_SUDO" = "1" ]; then printf 'sudo -n %s' "$1"; else printf '%s' "$1"; fi
}

quote_args() {
  local out="" a
  for a in "$@"; do out="$out '$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'"; done
  printf '%s' "${out# }"
}

cmd_push() {
  [ -d "$SCRIPT_DIR/lib" ] || die "cannot find $SCRIPT_DIR/lib — run this from the skill bundle"
  log "packing the script bundle"
  tar czf - -C "$BUNDLE_DIR" scripts tests \
    | ssh_run "mkdir -p $REMOTE_DIR && tar xzf - -C $REMOTE_DIR && chmod +x $REMOTE_DIR/scripts/vpnctl $REMOTE_DIR/tests/acceptance.sh"
  log "bootstrapping into /usr/local (needs root on the server)"
  ssh_run "$(priv "$REMOTE_DIR/scripts/vpnctl bootstrap")"
  log "pushed to $TARGET:$REMOTE_DIR"
}

# Prefer the bootstrapped binary, fall back to the pushed bundle.
REMOTE_PICK='VP=$(command -v vpnctl >/dev/null 2>&1 && echo vpnctl || echo "$HOME/.vpnctl/scripts/vpnctl");'

cmd_run() {
  local args cmd
  args="$(quote_args "$@")"
  if [ "$USE_SUDO" = "1" ]; then
    cmd="$REMOTE_PICK sudo -n \"\$VP\" $args"
  else
    cmd="$REMOTE_PICK \"\$VP\" $args"
  fi
  ssh "${SSH_ARGS[@]}" "$TARGET" "$cmd"
}

cmd_probe() { cmd_run probe --json; }

# One command from the laptop: ship, provision, fetch the client files.
cmd_deploy() {
  local dest="${1:-./vpn-clients}"
  log "deploying to $TARGET (backend=$DEPLOY_BACKEND client=$DEPLOY_CLIENT)"
  cmd_push
  local args="--backend $DEPLOY_BACKEND --client $DEPLOY_CLIENT"
  [ -n "$DEPLOY_DOMAIN" ] && args="$args --domain $DEPLOY_DOMAIN"
  [ "$DEPLOY_CN" = "1" ] && args="$args --cn"
  # shellcheck disable=SC2086
  cmd_run up $args --yes
  cmd_pull "$dest"
  log "done. client files: $dest"
}

# Run the on-host acceptance suite (mutating: use a throwaway VPS).
cmd_test() {
  cmd_push
  local args="--yes"
  [ "$DEPLOY_BACKEND" != "auto" ] && args="$args --backend $DEPLOY_BACKEND"
  [ -n "$DEPLOY_DOMAIN" ] && args="$args --domain $DEPLOY_DOMAIN"
  log "running acceptance on $TARGET"
  ssh_run "$(priv "bash $REMOTE_DIR/tests/acceptance.sh $args")"
}


# Verify that we can actually operate this host before touching it.
cmd_connect() {
  log "checking ssh to $TARGET"
  if ! ssh "${SSH_ARGS[@]}" "$TARGET" true 2>/tmp/vpnctl-ssh-err.$$; then
    log "ssh failed:"
    sed 's/^/    /' /tmp/vpnctl-ssh-err.$$ >&2 || true
    rm -f /tmp/vpnctl-ssh-err.$$
    printf '\nfixes to try:\n' >&2
    printf '  ~/.ssh/config alias     ssh <alias>\n' >&2
    printf '  different port          remote.sh -p 2222 connect root@host\n' >&2
    printf '  different key           remote.sh -i ~/.ssh/other connect root@host\n' >&2
    printf '  no key on the server    ssh-copy-id -i ~/.ssh/id_ed25519.pub root@host\n' >&2
    die "cannot reach the host over ssh"
  fi
  rm -f /tmp/vpnctl-ssh-err.$$

  log "collecting host facts"
  ssh "${SSH_ARGS[@]}" "$TARGET" 'bash -s' <<'REMOTE'
set -u
u="$(id -un)"
if [ "$u" = root ]; then sudo_ok="root"; else
  if sudo -n true >/dev/null 2>&1; then sudo_ok="yes"; else sudo_ok="NO"; fi
fi
printf 'user      %s\n' "$u"
printf 'sudo      %s\n' "$sudo_ok"
printf 'os        %s\n' "$( (. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}") || uname -s)"
printf 'kernel    %s\n' "$(uname -r)"
printf 'arch      %s\n' "$(uname -m)"
printf 'virt      %s\n' "$(systemd-detect-virt 2>/dev/null || echo none)"
printf 'memory    %s MB\n' "$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo '?')"
printf 'disk      %s free\n' "$(df -h / | awk 'NR==2 {print $4}')"
printf 'systemd   %s\n' "$([ -d /run/systemd/system ] && echo yes || echo NO)"
printf 'tun       %s\n' "$([ -c /dev/net/tun ] && echo yes || echo NO)"
printf 'ipv4      %s\n' "$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)"
REMOTE

  log "next: probe (read-only), then plan, then ask the user for authorization"
}

cmd_pull() {
  local dest="${1:-./vpn-clients}"
  mkdir -p "$dest"
  log "copying client artifacts from $TARGET to $dest"
  scp_run -r "$TARGET:~/vpn-clients/." "$dest/" 2>/dev/null \
    || scp_run -r "$TARGET:/root/vpn-clients/." "$dest/" \
    || die "no client artifacts found (run: remote.sh run HOST client <backend> add --name X --yes)"
  find "$dest" -type f | sed 's|^|  |' >&2
  log "artifacts in $dest"
}

case $ACTION in
  connect) cmd_connect ;;
  deploy) cmd_deploy "$@" ;;
  test)   cmd_test ;;
  push)  cmd_push ;;
  run)   cmd_run "$@" ;;
  probe) cmd_probe ;;
  pull)  cmd_pull "$@" ;;
  help)  cmd_run help ;;
  *)     die "unknown action '$ACTION' (push|run|probe|pull|help)" ;;
esac
