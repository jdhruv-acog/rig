#!/bin/sh
# shellcheck shell=sh
# An account with no route to root at all. rig must install the entire toolchain
# without asking for a password, because most people on a managed laptop do not
# have one to give.
set -eu
# shellcheck source=/dev/null
. /src/tests/docker/cases/common.sh

stage

if command -v sudo >/dev/null 2>&1; then fail "this image is supposed to have no sudo"; fi
good "no sudo on this machine"
command -v git >/dev/null 2>&1 || fail "this image is supposed to ship git"
good "git is already here, so rig has nothing to install with a password"

sh "$RIG" --yes

[ -f "$MANIFEST" ] || fail "no manifest at $MANIFEST"
for entry in gh bun uv python node; do manifest_lists "$entry"; done
[ -f "$ENV_FILE" ] || fail "no env.sh at $ENV_FILE"
good "env.sh written"
toolchain_runs

count=$(rc_block_count)
[ "$count" = 1 ] || fail "expected exactly one '# BEGIN aganitha' in $RC, found $count"
good "$RC holds exactly one managed block"
