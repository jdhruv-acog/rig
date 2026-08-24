#!/usr/bin/env sh
# Prove this repository is safe to publish.
#
# `rig` knows kinds. A site file supplies the data. So no company name, no internal
# hostname, and no private package name belongs in this tree — they all live in a site
# file that stays private.
#
# This runs in CI and it fails the build on any hit. "Safe to publish" has to be a
# property with a test, not a promise somebody remembers to keep.
set -eu

status=0

# Words that must never appear. Add to this list, never remove from it.
#
# Each entry is a POSIX basic regular expression, matched without regard to case.
FORBIDDEN='aganitha
igniva
\.internal\b
\.corp\b
\.intranet\b'

# Files that are allowed to mention a company, because they are examples that
# deliberately show the shape of a site file. They use example.com and nothing else.
SKIP='^\./\.git/
^\./node_modules/
^\./bun\.lock
^\./scripts/check-clean\.sh$'

echo "checking that this tree names no private infrastructure"

files=$(find . -type f | grep -v -E "$(echo "$SKIP" | tr '\n' '|' | sed 's/|$//')")

for word in $FORBIDDEN; do
  hits=$(echo "$files" | xargs grep -l -i -E "$word" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    echo "FAIL: '$word' appears in:"
    echo "$hits" | sed 's/^/  /'
    status=1
  fi
done

# An example must use a reserved example domain, and nothing that could resolve.
# RFC 2606 reserves example.com, example.net, example.org and .example.
if [ -d ./examples ]; then
  bad=$(grep -h -o -E 'https?://[A-Za-z0-9.-]+' ./examples/* 2>/dev/null \
    | grep -v -E '://(localhost|127\.0\.0\.1|[A-Za-z0-9.-]*example\.(com|net|org))' || true)
  if [ -n "$bad" ]; then
    echo "FAIL: an example names a host that is not a reserved example domain:"
    echo "$bad" | sort -u | sed 's/^/  /'
    status=1
  fi
fi

if [ "$status" -eq 0 ]; then
  echo "ok: this tree is safe to publish"
fi

exit "$status"
