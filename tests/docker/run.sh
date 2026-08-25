#!/bin/sh
# shellcheck shell=sh
# The container matrix. Three images, one real rig run each, no stubs.
#
#   sh tests/docker/run.sh
#
# Every assertion lives in cases/, inside the container, where the machine under
# test actually is. This file only builds an image, starts the case, and reports.
# So a case fails by exiting non-zero and saying why on its own output — there is
# no second copy of the expectations out here to drift from the first.
#
# The runs need network: rig downloads gh, bun, uv, python and node for real.
# Nothing is authenticated and no pack is requested, so no token is needed and
# none is ever placed in an image.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH='' cd -- "$HERE/../.." && pwd)

FAILURES=0
RESULTS=""

record_result() {
  RESULTS="$RESULTS$1 $2
"
  [ "$1" = PASS ] || FAILURES=$((FAILURES + 1))
}

# A machine without docker is not a failing machine. Say so and stop, so this
# can sit in a CI job or a laptop check without either one needing a guard.
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  printf 'docker unavailable, skipped\n'
  exit 0
fi

# The linter is a checker, not a case: a missing shellcheck must not turn into
# a red matrix on somebody's laptop.
lint() {
  shellcheck=""
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck=$(command -v shellcheck)
  elif [ -x "$HOME/.bun/bin/shellcheck" ]; then
    shellcheck="$HOME/.bun/bin/shellcheck"
  fi
  if [ -z "$shellcheck" ]; then
    printf '\n  ·  shellcheck not found — lint skipped\n'
    return 0
  fi
  if "$shellcheck" -s sh "$HERE/run.sh" "$HERE"/cases/*.sh; then
    printf '\n  ok  shellcheck -s sh clean\n'
  else
    printf '\nFAIL  shellcheck\n'
    record_result FAIL shellcheck
  fi
}

# Build the image, then run one case inside it as the image's non-root user, with
# the repository mounted read-only. Read-only is the point: it proves the case is
# exercising the copy it staged and can never write back into the working tree.
run_case() {
  name="$1"; dockerfile="$2"; script="$3"
  tag="rig-test-$name"

  printf '\n══ %s ═══════════════════════════════════════════════\n' "$name"

  if ! docker build --quiet --file "$HERE/$dockerfile" --tag "$tag" "$HERE" >/dev/null; then
    printf '\nFAIL  %s  (image build failed)\n' "$name"
    record_result FAIL "$name"
    return 0
  fi

  if docker run --rm --volume "$REPO:/src:ro" "$tag" \
       sh "/src/tests/docker/cases/$script"; then
    printf '\nPASS  %s\n' "$name"
    record_result PASS "$name"
  else
    printf '\nFAIL  %s\n' "$name"
    record_result FAIL "$name"
  fi
}

lint

run_case ubuntu-sudo   ubuntu-sudo.Dockerfile   toolchain.sh
run_case ubuntu-nosudo ubuntu-nosudo.Dockerfile nosudo.sh
run_case debian-bare   debian-bare.Dockerfile   refuse.sh

printf '\n══ summary ══════════════════════════════════════════════\n\n'
printf '%s' "$RESULTS" | sed 's/^/  /'
printf '\n'

[ "$FAILURES" -eq 0 ] || exit 1
