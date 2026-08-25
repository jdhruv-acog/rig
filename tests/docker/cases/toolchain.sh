#!/bin/sh
# shellcheck shell=sh
# The full lifecycle on an ordinary account that can borrow root: install,
# install again, then remove. Run twice in one session on purpose — idempotence
# is a claim about a machine that has already been rigged, and a fresh container
# per run would never test it.
set -eu
# shellcheck source=/dev/null
. /src/tests/docker/cases/common.sh

stage

printf '\n  -- first run --\n'
sh "$RIG" --yes

[ -f "$MANIFEST" ] || fail "no manifest at $MANIFEST"
for entry in gh bun uv python node; do manifest_lists "$entry"; done
[ -f "$ENV_FILE" ] || fail "no env.sh at $ENV_FILE"
good "env.sh written"
toolchain_runs

count=$(rc_block_count)
[ "$count" = 1 ] || fail "expected exactly one '# BEGIN aganitha' in $RC, found $count"
good "$RC holds exactly one managed block"

cp "$MANIFEST" "$WORK/manifest.first"

printf '\n  -- second run --\n'
sh "$RIG" --yes
cmp "$MANIFEST" "$WORK/manifest.first" \
  || fail "the second run rewrote the manifest; it must be byte-identical"
good "manifest is byte-identical after the second run"

count=$(rc_block_count)
[ "$count" = 1 ] || fail "after the second run $RC holds $count managed blocks, expected 1"
good "$RC still holds exactly one managed block"

printf '\n  -- uninstall --\n'
sh "$UNINSTALL" --yes

if [ -e "$TOOLCHAIN" ]; then fail "$TOOLCHAIN survived the uninstall"; fi
good "$TOOLCHAIN is gone"

if grep -q '^# BEGIN aganitha$' "$RC" 2>/dev/null; then
  fail "the managed block survived the uninstall in $RC"
fi
good "the managed block is stripped from $RC"

# The rc file itself must survive: an uninstaller that removes its block by
# removing the file has destroyed somebody's shell configuration.
[ -f "$RC" ] || fail "$RC itself was removed"
good "$RC still exists"
