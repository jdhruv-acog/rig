#!/bin/sh
# shellcheck shell=sh
# A machine rig cannot repair. The exit code alone is a weak assertion: a refusal
# that does not name what is missing and the command that fixes it is a defect,
# so the message text is what this case actually checks.
set -eu
# shellcheck source=/dev/null
. /src/tests/docker/cases/common.sh

stage

out="$WORK/refusal.txt"
code=0
sh "$RIG" --yes >"$out" 2>&1 || code=$?

printf '\n  -- refusal as printed --\n'
sed 's/^/  | /' "$out"
printf '\n'

[ "$code" = 2 ] || fail "expected exit 2 for an unrepairable machine, got $code"
good "exit 2"

grep -q 'missing:.*curl' "$out" || fail "the refusal does not name curl"
grep -q 'missing:.*unzip' "$out" || fail "the refusal does not name unzip"
good "the refusal names both missing tools"

grep -q 'apt-get install -y.*curl' "$out" \
  || fail "the refusal does not offer an 'apt-get install' command"
grep -q 'apt-get install -y.*unzip' "$out" \
  || fail "the offered apt-get command does not include unzip"
good "the refusal offers an apt-get install command that fixes it"

if [ -e "$RIG_HOME" ]; then fail "a refused run still created $RIG_HOME"; fi
good "nothing was installed"
