# shellcheck shell=sh
# Test helpers. Sourced by every test file.
# shellcheck disable=SC3043  # `local` — see rig.sh for the portability reasoning
#
# Assertions print one line each and count failures in $FAILED, so a run reports
# every problem rather than stopping at the first — a suite that hides the second
# failure costs a full cycle to find it.

FAILED=0
CASES=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  T_OFF=$(printf '\033[0m'); T_GREEN=$(printf '\033[32m'); T_RED=$(printf '\033[31m')
  T_DIM=$(printf '\033[2m')
else
  T_OFF=""; T_GREEN=""; T_RED=""; T_DIM=""
fi

suite() { printf '\n%s── %s%s\n' "$T_DIM" "$*" "$T_OFF"; }

pass() { CASES=$((CASES+1)); printf '  %s✓%s %s\n' "$T_GREEN" "$T_OFF" "$1"; }
fail() {
  CASES=$((CASES+1)); FAILED=$((FAILED+1))
  printf '  %s✗%s %s\n' "$T_RED" "$T_OFF" "$1"
  shift
  for line in "$@"; do printf '      %s\n' "$line"; done
}

assert_eq() {   # assert_eq <name> <want> <got>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want: $2" "got:  $3"; fi
}

assert_contains() {  # assert_contains <name> <needle> <haystack>
  case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "expected to contain: $2" "got: $3" ;; esac
}

assert_not_contains() {
  case "$3" in *"$2"*) fail "$1" "expected NOT to contain: $2" "got: $3" ;; *) pass "$1" ;; esac
}

assert_file() {  # assert_file <name> <path>
  if [ -f "$2" ]; then pass "$1"; else fail "$1" "no such file: $2"; fi
}

assert_no_file() {
  if [ -f "$2" ]; then fail "$1" "file should not exist: $2"; else pass "$1"; fi
}

assert_status() {  # assert_status <name> <want> <command...>
  local name want got
  name="$1"; want="$2"; shift 2
  set +e; "$@" >/dev/null 2>&1; got=$?; set -e
  assert_eq "$name" "$want" "$got"
}

# A throwaway HOME for one case. Every test that touches the filesystem gets its
# own, so nothing leaks between cases and a failure cannot cascade.
new_home() {
  SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/rigtest.XXXXXX")
  HOME="$SANDBOX"
  export HOME
  printf '%s' "$SANDBOX"
}

drop_home() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; SANDBOX=""; }

# A fake executable that records every call, so a test can assert that a second
# run of an installer did nothing at all. Counting calls is the only way to prove
# idempotence: "the files look the same" would also pass if the work was redone.
stub() {   # stub <dir> <name> [exit-code] [stdout]
  local dir name code out
  dir="$1"; name="$2"; code="${3:-0}"; out="${4:-}"
  mkdir -p "$dir"
  cat > "$dir/$name" <<STUB
#!/bin/sh
echo "\$*" >> "$dir/.calls.$name"
[ -n "$out" ] && printf '%s\n' "$out"
exit $code
STUB
  chmod +x "$dir/$name"
}

calls() {  # calls <dir> <name> -> how many times it ran
  local f
  f="$1/.calls.$2"
  [ -f "$f" ] && wc -l < "$f" | tr -d ' ' || echo 0
}

reset_calls() { rm -f "$1"/.calls.* 2>/dev/null || true; }

report() {
  printf '\n'
  if [ "$FAILED" -eq 0 ]; then
    printf '%s%s cases, all passed%s\n\n' "$T_GREEN" "$CASES" "$T_OFF"
    return 0
  fi
  printf '%s%s of %s cases failed%s\n\n' "$T_RED" "$FAILED" "$CASES" "$T_OFF"
  return 1
}
