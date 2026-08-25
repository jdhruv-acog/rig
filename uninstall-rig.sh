#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043  # see rig.sh for why `local` is used here
#
# uninstall-rig — undo what rig installed, and nothing else.
#
#   curl -fsSL https://<host>/uninstall-rig.sh | sh
#
# rig records what it installed. This reads that record and removes exactly those
# things. A tool that was on this machine before rig ran was never recorded, so it
# is never touched — that difference is what separates an uninstaller from a mess.
#
# Apple's Command Line Tools are never removed. They are system-wide, they serve
# every account, and taking them away needs a password rig had to borrow.
set -eu

AGANITHA_HOME="${AGANITHA_HOME:-$HOME/.aganitha}"
RIG_HOME="$AGANITHA_HOME/rig"
MANIFEST="$RIG_HOME/manifest"
PACKS_RECORD="$AGANITHA_HOME/.packs_installed"

BLOCK_BEGIN="# BEGIN aganitha"
BLOCK_END="# END aganitha"

FORCE=0
ASSUME_YES=0

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OFF=$(printf '\033[0m');    C_DIM=$(printf '\033[2m')
  C_GREEN=$(printf '\033[32m'); C_RED=$(printf '\033[31m')
  C_YELLOW=$(printf '\033[33m'); C_BLUE=$(printf '\033[36m')
else
  C_OFF=""; C_DIM=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_BLUE=""
fi

group() { printf '\n  %s==> %s%s\n' "$C_BLUE" "$*" "$C_OFF" >&2; }
ok()    { printf '  %s✓%s  %-12s %s\n' "$C_GREEN" "$C_OFF" "$1" "${2-}" >&2; }
note()  { printf '  %s!%s  %-12s %s\n' "$C_YELLOW" "$C_OFF" "$1" "${2-}" >&2; }
bad()   { printf '  %s✗%s  %-12s %s\n' "$C_RED" "$C_OFF" "$1" "${2-}" >&2; }
say()   { printf '  %s\n' "$*" >&2; }
hint()  { printf '     %s%s%s\n' "$C_DIM" "$*" "$C_OFF" >&2; }

die() {
  local code
  code="$1"; shift
  printf '\n' >&2
  bad "${1:-uninstall}" "${2:-}"
  shift 2 2>/dev/null || true
  for line in "$@"; do hint "$line"; done
  printf '\n' >&2
  exit "$code"
}

connect_terminal() {
  # /dev/tty can exist, be world-readable, and still refuse to open — a session
  # with no controlling terminal returns ENXIO. `[ -r ]` tests the permission
  # bits and answers yes anyway, and a failed redirection on `exec` is fatal in a
  # non-interactive shell, so `|| true` is never reached. Probe in a subshell,
  # where the failure can be silenced, and only then take it for real.
  if [ ! -t 0 ] && ( : < /dev/tty ) 2>/dev/null; then
    exec < /dev/tty
  fi
}

confirm() {
  local answer
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ -t 0 ] || return 1
  printf '  %s?%s  %s [y/N] ' "$C_BLUE" "$C_OFF" "$1" >&2
  read -r answer || answer=""
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Follow a symbolic link to the file it finally points at.
#
# Writing through `mv` replaces a symlink with a regular file. A shell file
# symlinked into a dotfiles repository is common, and replacing it detaches that
# repository silently: it stops receiving changes, and the block we wrote is not
# in it either. So the link is resolved and the target is written.
resolve_link() {
  local target link
  target="$1"
  while [ -L "$target" ]; do
    link=$(readlink "$target")
    case "$link" in
      /*) target="$link" ;;
      *)  target="$(dirname "$target")/$link" ;;
    esac
  done
  printf '%s' "$target"
}

# Remove a marker block and leave every other line exactly as it was. Rebuilt
# beside the file and renamed, so an interruption cannot truncate somebody's
# shell configuration.
strip_block() {
  local file tmp
  file=$(resolve_link "$1")
  [ -f "$file" ] || return 0
  grep -q "^$BLOCK_BEGIN\$" "$file" 2>/dev/null || return 0
  tmp="$file.rig.new"
  awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
    $0 == b { skip = 1 } skip != 1 { print } $0 == e { skip = 0 }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# Removing the toolchain while packs are still installed strands them: a pack's
# own uninstall script needs the bun and node that are about to disappear. So
# this refuses, and names the commands that put it in the right order.
check_packs_first() {
  local packs
  [ -f "$PACKS_RECORD" ] || return 0
  packs=$(awk -F'\t' 'NF && $1 !~ /^#/ {printf "%s ", $1}' "$PACKS_RECORD" 2>/dev/null)
  [ -n "$packs" ] || return 0
  [ "$FORCE" -eq 1 ] && { note "packs" "still installed:$packs — removing anyway (--force)"; return 0; }

  die 2 "packs" "these packs are still installed: $packs" \
    "Removing the toolchain now would strand them — their own uninstall" \
    "scripts need the bun and node that are about to be removed." \
    "" \
    "Remove them first:" \
    "  atk uninstall $(echo "$packs" | tr ' ' '\n' | head -1)" \
    "" \
    "Then run this again. Or --force to remove the toolchain regardless."
}

usage() {
  cat >&2 <<USAGE

  uninstall-rig — undo what rig installed, and nothing else.

    curl -fsSL <host>/uninstall-rig.sh | sh

  Options
    --force   remove the toolchain even when packs are still installed
    --yes     do not ask
    --help    this

  It reads ~/.aganitha/rig/manifest and removes only what is recorded there.
  Anything that was already on this machine was never recorded, so it stays.

USAGE
}

main() {
  local name _version where entries removed
  while [ $# -gt 0 ]; do
    case "$1" in
      --force)   FORCE=1; shift ;;
      --yes|-y)  ASSUME_YES=1; shift ;;
      --help|-h) usage; exit 0 ;;
      *) die 2 "uninstall" "unknown option: $1" "Run with --help." ;;
    esac
  done

  connect_terminal

  if [ ! -f "$MANIFEST" ]; then
    say ""
    say "Nothing to undo — no rig manifest at $MANIFEST."
    say ""
    exit 0
  fi

  check_packs_first

  # Name the tree before listing anything. AGANITHA_HOME is honoured from the
  # environment, so a stale value would otherwise send this at a different tree
  # without ever saying so.
  group "This will remove, from $AGANITHA_HOME"
  entries=0
  while IFS="$(printf '\t')" read -r name _version where _; do
    [ -n "$name" ] || continue
    [ "$name" = schema ] && continue
    printf '  %s·%s  %-12s %s%s%s\n' "$C_DIM" "$C_OFF" "$name" \
      "$C_DIM" "$where" "$C_OFF" >&2
    entries=$((entries + 1))
  done < "$MANIFEST"

  if [ "$entries" -eq 0 ]; then
    say ""
    say "The manifest is empty. Nothing to undo."
    say ""
    exit 0
  fi

  printf '\n' >&2
  say "Anything not listed above was already on this machine, and stays."
  printf '\n' >&2
  confirm "Remove these?" || { say ""; say "Nothing was changed."; say ""; exit 0; }

  group "Removing"
  removed=0
  while IFS="$(printf '\t')" read -r name _version where _; do
    [ -n "$name" ] || continue
    [ "$name" = schema ] && continue
    case "$name" in
      shell|shell-profile) strip_block "$where"; ok "$name" "block removed from $(basename "$where")" ;;
      env)                 : ;;   # inside RIG_HOME, removed with the tree below
      *)
        if [ -e "$where" ]; then rm -rf "$where"; ok "$name" "removed"
        else note "$name" "already gone"; fi ;;
    esac
    removed=$((removed + 1))
  done < "$MANIFEST"

  # Last, so a failure above leaves the record intact and this can be run again.
  rm -rf "$RIG_HOME"
  ok "rig" "$RIG_HOME removed"

  # Only when nothing else lives there. Somebody's own files under ~/.aganitha
  # are not ours to delete.
  rmdir "$AGANITHA_HOME" 2>/dev/null && ok "aganitha" "$AGANITHA_HOME removed" || true

  printf '\n' >&2
  say "Done. Open a new terminal."
  printf '\n' >&2
}

[ -n "${RIG_SOURCED:-}" ] || main "$@"
