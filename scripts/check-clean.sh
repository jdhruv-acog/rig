#!/bin/sh
# shellcheck shell=sh
# Hold the line on what a public repository may contain.
#
# This repository is published. A stranger can read every byte of it. So the
# question is not "does the word 'aganitha' appear" — that is a public GitHub
# organisation slug, and the private repository behind it answers 404 to anybody
# who is not a member. The question is whether this tree leaks the shape of an
# internal network.
#
# FORBIDDEN, because each one tells a reader something they could not otherwise
# learn, and none of them is needed for rig to do its job:
#
#   internal hostnames    npm.<org>.ai, pypi.<org>.ai, a deployment address
#   package names         the private scope, and anything published under it
#   product names         what the organisation builds and runs
#   credentials           of any kind, in any encoding
#
# ALLOWED, deliberately, and the reason is that a one-line installer has to know
# where to get its next step:
#
#   the org slug in the repository it hands over to  (aganitha/commands)
#   the tree it installs into                        (~/.aganitha)
#   the shell block marker                           (# BEGIN aganitha)
#
# Those three name a private repository that already refuses strangers. They
# reveal no address, no package, and no product. Everything else is a build
# failure.
set -eu

ROOT="${1:-.}"
STATUS=0

# One pattern per line: <what it is><TAB><extended regex>
FORBIDDEN=$(cat <<'PATTERNS'
internal hostname	[A-Za-z0-9_-]+\.aganitha\.(ai|com|io)
private package scope	@aganitha/
product name	\b(igniva|atk-identity|atk-job-manager|atk-secrets|atk-event-bus)\b
credential	(LDAP|ldap_password|_auth=[A-Za-z0-9+/]{16,})
PATTERNS
)

command -v grep >/dev/null 2>&1 || { echo "check-clean: grep is required" >&2; exit 2; }

# Text files only, and never this file — it necessarily contains every pattern
# it looks for.
files=$(find "$ROOT" -type f \
  ! -path "*/.git/*" \
  ! -name "check-clean.sh" \
  ! -name "*.png" ! -name "*.jpg" ! -name "*.gz" ! -name "*.zip" \
  2>/dev/null)

printf '%s\n' "$FORBIDDEN" | while IFS="$(printf '\t')" read -r label pattern; do
  [ -n "$label" ] || continue
  hits=$(printf '%s\n' "$files" | xargs grep -nEI "$pattern" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    printf '\n  %s must not appear in a public repository:\n' "$label" >&2
    printf '%s\n' "$hits" | sed 's/^/    /' >&2
    echo "FAILED" > "${TMPDIR:-/tmp}/.check-clean-failed.$$"
  fi
done

if [ -f "${TMPDIR:-/tmp}/.check-clean-failed.$$" ]; then
  rm -f "${TMPDIR:-/tmp}/.check-clean-failed.$$"
  printf '\n  This tree is not publishable.\n\n' >&2
  STATUS=1
else
  printf '  clean — no hostname, package, product or credential in this tree\n' >&2
fi

exit "$STATUS"
