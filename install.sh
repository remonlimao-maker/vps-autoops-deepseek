#!/usr/bin/env bash
# install.sh — register every skill bundle in this repo with local agent
# frameworks. One symlink per skill; idempotent.
#
#   ./install.sh                 # auto-detect (dsh, claude, agents roots)
#   ./install.sh --dry-run
#   ./install.sh --uninstall
#   ./install.sh --root ~/.claude/skills     # custom skill root

set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
DRY_RUN=0
UNINSTALL=0
CUSTOM_ROOT=""

if [ -t 1 ]; then C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else C_OK=''; C_WARN=''; C_DIM=''; C_RST=''; fi
ok()   { printf '%sok%s   %s\n' "$C_OK" "$C_RST" "$*"; }
warn() { printf '%s!!%s   %s\n' "$C_WARN" "$C_RST" "$*"; }
info() { printf '%s--%s   %s\n' "$C_DIM" "$C_RST" "$*"; }
act()  { if [ "$DRY_RUN" = "1" ]; then info "would: $*"; else ok "$*"; fi; }

while [ "$#" -gt 0 ]; do
  case $1 in
    --dry-run) DRY_RUN=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --root) CUSTOM_ROOT="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

# every directory that contains a SKILL.md is a skill bundle
SKILLS=""
for d in "$ROOT"/*/; do
  [ -f "$d/SKILL.md" ] || continue
  SKILLS="$SKILLS $(basename "$d")"
done
[ -n "$SKILLS" ] || { printf 'no skill bundles found in %s\n' "$ROOT" >&2; exit 2; }

ROOTS=""
if [ -n "$CUSTOM_ROOT" ]; then
  ROOTS="$CUSTOM_ROOT"
else
  [ -d "$DSH_HOME" ] && ROOTS="$ROOTS $DSH_HOME/skills"
  [ -d "$HOME/.claude" ] && ROOTS="$ROOTS $HOME/.claude/skills"
  [ -d "$HOME/.agents" ] && ROOTS="$ROOTS $HOME/.agents/skills"
fi

if [ -z "$ROOTS" ]; then
  warn "no agent skill directory detected"
  printf 'create one, or point at it explicitly:\n  %s\n' "./install.sh --root <dir>"
  exit 0
fi

printf '\nskills:%s\nroots:%s\n\n' "$SKILLS" "$ROOTS"

for root in $ROOTS; do
  for s in $SKILLS; do
    dest="$root/$s"
    if [ "$UNINSTALL" = "1" ]; then
      if [ -L "$dest" ]; then rm -f "$dest"; act "removed $dest"
      elif [ -e "$dest" ]; then warn "not a symlink, left alone: $dest"
      else info "absent: $dest"; fi
      continue
    fi
    if [ "$DRY_RUN" = "0" ]; then mkdir -p "$root"; fi
    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$ROOT/$s" ]; then
      info "already linked: $dest"; continue
    fi
    if [ -e "$dest" ] && [ ! -L "$dest" ]; then
      warn "exists and is not a symlink, left alone: $dest"; continue
    fi
    if [ "$DRY_RUN" = "0" ]; then rm -f "$dest"; ln -s "$ROOT/$s" "$dest"; fi
    act "linked $dest -> $ROOT/$s"
  done
done

printf '\n'
[ "$DRY_RUN" = "1" ] && info "dry run: nothing changed" || ok "done. new agent sessions will see the skills."
