#!/bin/sh
# shellcheck shell=sh
# Shared assertions for the in-container cases. Sourced, never run on its own.
#
# The repository is mounted read-only at /src. rig writes nothing inside its own
# directory, but a test that runs from a read-only mount cannot tell "rig does
# not need to write here" from "rig could not write here", so every case copies
# the two scripts to a writable place first.

WORK="$HOME/work"
RIG="$WORK/rig.sh"
UNINSTALL="$WORK/uninstall-rig.sh"
TOOLCHAIN="$HOME/.aganitha/toolchain"
MANIFEST="$TOOLCHAIN/manifest"
ENV_FILE="$TOOLCHAIN/env.sh"
RC="$HOME/.bashrc"
TAB=$(printf '\t')

fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; exit 1; }
good() { printf '    ok  %s\n' "$*"; }

stage() {
  [ "$(id -u)" -ne 0 ] || fail "this case must not run as root"
  mkdir -p "$WORK"
  cp /src/rig.sh /src/uninstall-rig.sh "$WORK/"
  chmod +x "$RIG" "$UNINSTALL"
  good "staged rig.sh as uid $(id -u) ($(id -un))"
}

manifest_lists() {
  grep -q "^$1$TAB" "$MANIFEST" || fail "manifest has no line for $1"
  good "manifest lists $1"
}

# The whole promise of env.sh is that reading that one file is enough. Each tool
# is run in a fresh shell that has been given nothing else.
toolchain_runs() {
  for tool in bun uv node gh; do
    sh -c '. "$1"; shift; "$@"' _ "$ENV_FILE" "$tool" --version >/dev/null 2>&1 \
      || fail "after sourcing env.sh, '$tool --version' failed"
    good "$tool --version runs from env.sh alone"
  done
}

rc_block_count() { grep -c '^# BEGIN aganitha$' "$RC" 2>/dev/null || true; }
