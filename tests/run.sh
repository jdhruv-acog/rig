#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043  # `local` — see rig.sh for the portability reasoning
#
# run — everything, in one command.
#
#   sh tests/run.sh
#
# Two suites and three checks. The checks come first, because a syntax error
# found by parsing is cheaper to read than the same error found halfway through
# an install, and because rig has to be valid sh under more than one shell: macOS
# runs it under bash-as-sh and Debian runs it under dash.
#
# A missing dash or shellcheck is reported and skipped rather than failing. This
# has to run on a laptop as well as in CI, and a suite that cannot be run locally
# stops being run.
set -u

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$HERE")

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  R_OFF=$(printf '\033[0m');    R_DIM=$(printf '\033[2m')
  R_GREEN=$(printf '\033[32m'); R_RED=$(printf '\033[31m')
else
  R_OFF=""; R_DIM=""; R_GREEN=""; R_RED=""
fi

FAILED=0
CHECKS=0
CASES=0
CASE_FAILURES=0

good() { CHECKS=$((CHECKS + 1)); printf '  %s✓%s %s\n' "$R_GREEN" "$R_OFF" "$*"; }
bad()  { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1))
         printf '  %s✗%s %s\n' "$R_RED" "$R_OFF" "$*"; }
skip() { printf '  %s·%s %s%s%s\n' "$R_DIM" "$R_OFF" "$R_DIM" "$*" "$R_OFF"; }
head_() { printf '\n%s── %s%s\n' "$R_DIM" "$*" "$R_OFF"; }

# Every shell file in the project. rig.sh and uninstall-rig.sh are what ships;
# the tests are held to the same bar, because a test file that only runs under
# one shell hides exactly the portability problem it exists to find.
files() {
  printf '%s\n%s\n' "$ROOT/rig.sh" "$ROOT/uninstall-rig.sh"
  for f in "$HERE"/*.sh; do [ -f "$f" ] && printf '%s\n' "$f"; done
}

# ─── syntax ─────────────────────────────────────────────────────────────────

head_ "syntax"

for f in $(files); do
  if out=$(sh -n "$f" 2>&1); then good "sh -n  $(basename "$f")"
  else bad "sh -n  $(basename "$f")"; printf '%s\n' "$out" | sed 's/^/      /'; fi
done

if command -v dash >/dev/null 2>&1; then
  for f in $(files); do
    if out=$(dash -n "$f" 2>&1); then good "dash -n  $(basename "$f")"
    else bad "dash -n  $(basename "$f")"; printf '%s\n' "$out" | sed 's/^/      /'; fi
  done
else
  skip "dash is not installed — skipping the dash syntax check"
fi

# ─── shellcheck ─────────────────────────────────────────────────────────────

head_ "shellcheck"

SHELLCHECK=""
if command -v shellcheck >/dev/null 2>&1; then
  SHELLCHECK=$(command -v shellcheck)
elif [ -x "$HOME/.bun/bin/shellcheck" ]; then
  SHELLCHECK="$HOME/.bun/bin/shellcheck"
fi

if [ -n "$SHELLCHECK" ]; then
  for f in $(files); do
    # -s sh, not the shebang: these must be correct as POSIX sh, which is the
    # one thing every machine rig lands on agrees to provide.
    if out=$("$SHELLCHECK" -s sh "$f" 2>&1); then good "shellcheck  $(basename "$f")"
    else bad "shellcheck  $(basename "$f")"; printf '%s\n' "$out" | sed 's/^/      /'; fi
  done
else
  skip "shellcheck is not installed — skipping"
fi

# ─── the suites ─────────────────────────────────────────────────────────────
#
# Output is teed rather than swallowed, so a failure is readable here and the
# case counts can still be added up for the summary.

LOGS=$(mktemp -d "${TMPDIR:-/tmp}/rigrun.XXXXXX")
trap 'rm -rf "$LOGS"' EXIT INT TERM HUP

run_suite() {  # run_suite <name>
  local name log
  name="$1"
  log="$LOGS/$name"
  head_ "$name"
  sh "$HERE/$name.sh" 2>&1 | tee "$log" | sed 's/^/  /'

  # The last line of a suite is its tally, and that is what is read — not the
  # pipeline's exit status, which belongs to sed, and not a count of marks, which
  # would disagree with the suite if either ever changed.
  # shellcheck disable=SC2046  # the two numbers are meant to split into $1 $2
  set -- $(sed -n 's/^\([0-9][0-9]*\) cases, all passed$/\1 0/p;
                   s/^\([0-9][0-9]*\) of \([0-9][0-9]*\) cases failed$/\2 \1/p' "$log")
  if [ $# -eq 2 ]; then
    CASES=$((CASES + $1))
    CASE_FAILURES=$((CASE_FAILURES + $2))
    if [ "$2" -eq 0 ]; then good "$name: $1 cases, all passed"
    else bad "$name: $2 of $1 cases failed"; fi
  else
    bad "$name did not finish — no tally on its last line"
    CASE_FAILURES=$((CASE_FAILURES + 1))
  fi
}

run_suite unit
run_suite hermetic

# ─── the answer ─────────────────────────────────────────────────────────────

printf '\n'
if [ "$FAILED" -eq 0 ] && [ "$CASE_FAILURES" -eq 0 ]; then
  printf '%s%s checks and %s cases, all passed%s\n\n' "$R_GREEN" "$CHECKS" "$CASES" "$R_OFF"
  exit 0
fi
printf '%s%s of %s checks and %s of %s cases failed%s\n\n' \
  "$R_RED" "$FAILED" "$CHECKS" "$CASE_FAILURES" "$CASES" "$R_OFF"
exit 1
