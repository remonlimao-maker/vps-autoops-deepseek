#!/usr/bin/env bash
# install.sh — make this skill visible to the agent frameworks on this machine.
#
# A skill is just Markdown plus scripts, but every host looks in a different
# place. This script writes the right files for each target and keeps them
# idempotent, so re-running after a `git pull` is always safe.
#
#   install.sh --target auto                 # detect what is installed
#   install.sh --target dsh,claude,codex
#   install.sh --target auto --dry-run
#   install.sh --list
#   install.sh --uninstall --target auto

set -euo pipefail

SKILL_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_NAME="vps-vpn-setup"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
MARK_BEGIN="<!-- BEGIN ${SKILL_NAME} (managed by install.sh) -->"
MARK_END="<!-- END ${SKILL_NAME} -->"
MODE="symlink"
TARGETS=""
PROJECT="$(dirname "$SKILL_DIR")"
DRY_RUN=0
FORCE=0
UNINSTALL=0

if [ -t 1 ]; then C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_RST=''; fi
ok()   { printf '%sok%s   %s\n' "$C_OK" "$C_RST" "$*"; }
warn() { printf '%s!!%s   %s\n' "$C_WARN" "$C_RST" "$*"; }
info() { printf '%s--%s   %s\n' "$C_DIM" "$C_RST" "$*"; }
# Mutating steps report differently under --dry-run so nobody mistakes a
# preview for a completed install.
act()  { if [ "$DRY_RUN" = "1" ]; then info "would: ${*}"; else ok "$*"; fi; }
die()  { printf '%serr%s  %s\n' "$C_ERR" "$C_RST" "$*" >&2; exit 2; }

usage() {
  cat <<'EOF'
install.sh — register the vps-vpn-setup skill with local agent frameworks

USAGE
  ./install.sh [options]

OPTIONS
  --target LIST     Comma list or "auto"/"all". Targets:
                      dsh      ~/.dsh/skills/vps-vpn-setup
                      claude   ~/.claude/skills/vps-vpn-setup
                      agents   ~/.agents/skills/vps-vpn-setup  (shared root)
                      codex    ~/.codex/AGENTS.md + ~/.codex/prompts/vpn.md
                      cursor   <project>/.cursor/rules/vps-vpn-setup.mdc + AGENTS.md
                      gemini   ~/.gemini/commands/vpn.toml + <project>/GEMINI.md
                      copilot  <project>/.github/prompts/vpn.prompt.md + copilot-instructions.md
  --mode symlink|copy   How skill directories are installed (default symlink)
  --project DIR      Project root for project-scoped targets (default: parent of this bundle)
  --list             Show detected targets and their state, then exit
  --uninstall        Remove what this script installed
  --force            Overwrite files that this script does not own
  --dry-run          Print actions without touching the filesystem
  -h, --help

NOTES
  symlink is best when this checkout is the single source of truth; copy is for
  machines where the checkout may move or where the target cannot follow links.
  Everything is idempotent: managed blocks are replaced, not duplicated.
EOF
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --target) TARGETS="${2:?--target needs a value}"; shift 2 ;;
    --target=*) TARGETS="${1#*=}"; shift ;;
    --mode) MODE="${2:?--mode needs a value}"; shift 2 ;;
    --project) PROJECT="${2:?--project needs a value}"; shift 2 ;;
    --list) LIST=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument '$1' (try --help)" ;;
  esac
done

[ -f "$SKILL_DIR/SKILL.md" ] || die "SKILL.md not found next to install.sh"
case $MODE in symlink|copy) ;; *) die "--mode must be symlink or copy" ;; esac

do_run() {
  if [ "$DRY_RUN" = "1" ]; then printf '     %s$ %s%s\n' "$C_DIM" "$*" "$C_RST"; return 0; fi
  "$@"
}

# --- target detection ------------------------------------------------------

detect_targets() {
  local found=""
  if [ -d "$DSH_HOME" ]; then found="$found dsh"; fi
  if [ -d "$HOME/.claude" ]; then found="$found claude"; fi
  if [ -d "$HOME/.agents" ]; then found="$found agents"; fi
  if [ -d "$HOME/.codex" ]; then found="$found codex"; fi
  if [ -d "$HOME/.cursor" ] || [ -d "$PROJECT/.cursor" ]; then found="$found cursor"; fi
  if [ -d "$HOME/.gemini" ]; then found="$found gemini"; fi
  if [ -d "$PROJECT/.github" ]; then found="$found copilot"; fi
  printf '%s' "${found# }"
}

expand_targets() {
  case $TARGETS in
    ""|auto) detect_targets ;;
    all) printf 'dsh claude agents codex cursor gemini copilot' ;;
    *) printf '%s' "$TARGETS" | tr ',' ' ' ;;
  esac
}

# --- helpers ---------------------------------------------------------------

link_skill() {
  local dest="$1" src="$SKILL_DIR"
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    ok "already linked: $dest"
    return 0
  fi
  if [ -e "$dest" ] && [ "$FORCE" != "1" ]; then
    if [ -d "$dest" ] && [ -f "$dest/SKILL.md" ] && grep -q "name: ${SKILL_NAME}" "$dest/SKILL.md" 2>/dev/null; then
      info "replacing a previous copy at $dest"
      do_run rm -rf "$dest"
    else
      warn "exists and is not ours, skipping: $dest (use --force)"
      return 0
    fi
  elif [ -e "$dest" ]; then
    do_run rm -rf "$dest"
  fi
  do_run mkdir -p "$(dirname "$dest")"
  if [ "$MODE" = "symlink" ]; then
    do_run ln -sfn "$src" "$dest"
  else
    do_run cp -R "$src" "$dest"
  fi
  act "installed skill: $dest ($MODE)"
}

# upsert_block FILE SOURCE — replace or append the managed Markdown block
upsert_block() {
  local file="$1" src="$2" tmp blocktmp
  tmp="$(mktemp)"; blocktmp="$(mktemp)"
  {
    printf '%s\n' "$MARK_BEGIN"
    sed -n '1,$p' "$src"
    printf '%s\n' "$MARK_END"
  } > "$blocktmp"

  if [ -f "$file" ]; then
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
      $0 == b {skip=1; next}
      $0 == e {skip=0; next}
      skip != 1 {print}
    ' "$file" > "$tmp"
    if grep -qF "$MARK_BEGIN" "$file"; then
      cat "$blocktmp" >> "$tmp"
      do_run cp "$tmp" "$file"
      act "updated block in $file"
    else
      if [ "$UNINSTALL" = "1" ]; then info "no managed block in $file"; rm -f "$tmp" "$blocktmp"; return 0; fi
      { cat "$file"; printf '\n'; cat "$blocktmp"; } > "$tmp"
      do_run cp "$tmp" "$file"
      act "appended block to $file"
    fi
  else
    do_run mkdir -p "$(dirname "$file")"
    do_run cp "$blocktmp" "$file"
    act "created $file"
  fi
  rm -f "$tmp" "$blocktmp"
}

strip_block() {
  local file="$1" tmp
  [ -f "$file" ] || { info "absent: $file"; return 0; }
  grep -qF "$MARK_BEGIN" "$file" || { info "no managed block: $file"; return 0; }
  tmp="$(mktemp)"
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b {skip=1; next}
    $0 == e {skip=0; next}
    skip != 1 {print}
  ' "$file" > "$tmp"
  if [ -s "$tmp" ]; then do_run cp "$tmp" "$file"; else do_run rm -f "$file"; fi
  rm -f "$tmp"
  act "removed block from $file"
}

install_file() {
  local src="$1" dest="$2"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then ok "unchanged: $dest"; return 0; fi
  if [ -e "$dest" ] && [ "$FORCE" != "1" ] && ! grep -q "$SKILL_NAME" "$dest" 2>/dev/null; then
    warn "exists and is not ours, skipping: $dest (use --force)"; return 0
  fi
  do_run mkdir -p "$(dirname "$dest")"
  do_run cp "$src" "$dest"
  act "wrote $dest"
}

remove_file_if_ours() {
  local f="$1"
  [ -e "$f" ] || { info "absent: $f"; return 0; }
  if grep -q "$SKILL_NAME" "$f" 2>/dev/null || [ "$FORCE" = "1" ] || [ -L "$f" ]; then
    do_run rm -f "$f"; act "removed $f"
  else
    warn "not ours, leaving alone: $f (use --force)"
  fi
}

cursor_rule() {
  local tmp; tmp="$(mktemp)"
  {
    printf -- '---\n'
    printf 'description: VPS 上部署与排障 VPN（WireGuard / Xray REALITY / SS2022 / Hysteria2）\n'
    printf 'globs:\n'
    printf 'alwaysApply: false\n'
    printf -- '---\n\n'
    cat "$SKILL_DIR/assets/AGENTS.snippet.md"
  } > "$tmp"
  install_file "$tmp" "$PROJECT/.cursor/rules/$SKILL_NAME.mdc"
  rm -f "$tmp"
}

# --- per-target actions ----------------------------------------------------

target_dsh() {
  link_skill "$DSH_HOME/skills/$SKILL_NAME"
}

target_claude() {
  link_skill "$HOME/.claude/skills/$SKILL_NAME"
  install_file "$SKILL_DIR/assets/commands/claude-vpn.md" "$HOME/.claude/commands/vpn.md"
}

target_agents() {
  link_skill "$HOME/.agents/skills/$SKILL_NAME"
}

target_codex() {
  upsert_block "$HOME/.codex/AGENTS.md" "$SKILL_DIR/assets/AGENTS.snippet.md"
  install_file "$SKILL_DIR/assets/commands/codex-vpn.md" "$HOME/.codex/prompts/vpn.md"
}

target_cursor() {
  cursor_rule
  upsert_block "$PROJECT/AGENTS.md" "$SKILL_DIR/assets/AGENTS.snippet.md"
}

target_gemini() {
  upsert_block "$PROJECT/GEMINI.md" "$SKILL_DIR/assets/AGENTS.snippet.md"
  install_file "$SKILL_DIR/assets/commands/gemini-vpn.toml" "$HOME/.gemini/commands/vpn.toml"
}

target_copilot() {
  install_file "$SKILL_DIR/assets/commands/copilot-vpn.prompt.md" "$PROJECT/.github/prompts/vpn.prompt.md"
  upsert_block "$PROJECT/.github/copilot-instructions.md" "$SKILL_DIR/assets/AGENTS.snippet.md"
}

uninstall_target_dsh()     { remove_dir "$DSH_HOME/skills/$SKILL_NAME"; }
uninstall_target_claude()  { remove_dir "$HOME/.claude/skills/$SKILL_NAME"; remove_file_if_ours "$HOME/.claude/commands/vpn.md"; }
uninstall_target_agents()  { remove_dir "$HOME/.agents/skills/$SKILL_NAME"; }
uninstall_target_codex()   { strip_block "$HOME/.codex/AGENTS.md"; remove_file_if_ours "$HOME/.codex/prompts/vpn.md"; }
uninstall_target_cursor()  { remove_file_if_ours "$PROJECT/.cursor/rules/$SKILL_NAME.mdc"; strip_block "$PROJECT/AGENTS.md"; }
uninstall_target_gemini()  { strip_block "$PROJECT/GEMINI.md"; remove_file_if_ours "$HOME/.gemini/commands/vpn.toml"; }
uninstall_target_copilot() { remove_file_if_ours "$PROJECT/.github/prompts/vpn.prompt.md"; strip_block "$PROJECT/.github/copilot-instructions.md"; }

remove_dir() {
  local d="$1"
  [ -e "$d" ] || { info "absent: $d"; return 0; }
  if [ -L "$d" ] || [ "$FORCE" = "1" ]; then
    do_run rm -rf "$d"; act "removed $d"
  else
    warn "refusing to delete a real directory: $d (use --force)"
  fi
}

# --- list ------------------------------------------------------------------

if [ "${LIST:-0}" = "1" ]; then
  printf 'detected:  %s\n' "$(detect_targets)"
  printf 'project:   %s\n' "$PROJECT"
  printf 'bundle:    %s\n' "$SKILL_DIR"
  for t in dsh claude agents codex cursor gemini copilot; do
    case $t in
      dsh) p="$DSH_HOME/skills/$SKILL_NAME" ;;
      claude) p="$HOME/.claude/skills/$SKILL_NAME" ;;
      agents) p="$HOME/.agents/skills/$SKILL_NAME" ;;
      codex) p="$HOME/.codex/AGENTS.md" ;;
      cursor) p="$PROJECT/.cursor/rules/$SKILL_NAME.mdc" ;;
      gemini) p="$HOME/.gemini/commands/vpn.toml" ;;
      copilot) p="$PROJECT/.github/prompts/vpn.prompt.md" ;;
    esac
    if [ -e "$p" ] || [ -L "$p" ]; then printf '  %-8s %sINSTALLED%s  %s\n' "$t" "$C_OK" "$C_RST" "$p"
    else printf '  %-8s %s-\t%s  %s\n' "$t" "$C_DIM" "$C_RST" "$p"; fi
  done
  exit 0
fi

# --- main ------------------------------------------------------------------

TARGET_LIST="$(expand_targets)"
[ -n "$TARGET_LIST" ] || die "no target detected; pass --target dsh|claude|codex|cursor|gemini|copilot|agents"

printf '\n%s%s%s -> %s\n\n' "$C_DIM" "install ${SKILL_NAME}" "$C_RST" "${TARGET_LIST// /, }"
[ "$DRY_RUN" = "1" ] && printf '%s(dry run: nothing will change)%s\n\n' "$C_DIM" "$C_RST"

for t in $TARGET_LIST; do
  case $t in
    dsh|claude|agents|codex|cursor|gemini|copilot) ;;
    *) die "unknown target '$t'" ;;
  esac
  printf '\n[%s]\n' "$t"
  if [ "$UNINSTALL" = "1" ]; then "uninstall_target_${t}"; else "target_${t}"; fi
done

printf '\n'
if [ "$UNINSTALL" = "1" ]; then
  act "uninstalled from ${TARGET_LIST// /, }"
elif [ "$DRY_RUN" = "1" ]; then
  info "dry run: nothing was written"
else
  ok "done. verify with:"
  printf '     %s\n' "bash '$SKILL_DIR/scripts/vpnctl' --help"
  printf '     %s\n' "bash '$SKILL_DIR/tests/smoke.sh'"
  printf '  agents load skills at session start — start a new session to see "%s".\n' "$SKILL_NAME"
fi
