#!/bin/sh
# shellcheck shell=sh
# Are the recorded checksums still the ones the vendors publish?
#
# rig pins a version and records the checksum of every binary it downloads. A pin
# is allowed to go out of date — that is a deliberate, reviewed decision. What it
# must never do is go silently wrong: a recorded checksum that no longer matches
# the published one means the bytes at that URL changed under a tag, and no
# install should proceed on that.
#
# This needs the network, so it runs in CI rather than in the offline suite.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
FAILED=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  OFF=$(printf '\033[0m'); GREEN=$(printf '\033[32m'); RED=$(printf '\033[31m')
else
  OFF=""; GREEN=""; RED=""
fi
good() { printf '  %s✓%s %s\n' "$GREEN" "$OFF" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$OFF" "$*"; FAILED=$((FAILED + 1)); }

# Read a pinned value straight out of rig.sh, so this can never disagree with
# what actually ships.
pin() { sed -n "s/^$1=\"\\([^\"]*\\)\"/\\1/p" "$ROOT/rig.sh" | head -1; }

# Ask rig.sh itself for the checksum it would use, rather than re-reading the
# table. One fact, one place.
# shellcheck source=/dev/null
recorded() { RIG_SOURCED=1 . "$ROOT/rig.sh" >/dev/null 2>&1; checksum_for "$1"; }

GH_VERSION=$(pin GH_VERSION)
NODE_VERSION=$(pin NODE_VERSION)

printf '\n  pins: gh %s · node %s\n\n' "$GH_VERSION" "$NODE_VERSION"

# ─── gh ─────────────────────────────────────────────────────────────────────
gh_sums=$(curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt" 2>/dev/null || true)
if [ -z "$gh_sums" ]; then
  bad "gh ${GH_VERSION}: no published checksum file — is the version still released?"
else
  for target in macos:arm64:macOS_arm64.zip macos:x64:macOS_amd64.zip \
                linux:arm64:linux_arm64.tar.gz linux:x64:linux_amd64.tar.gz; do
    os=${target%%:*}; rest=${target#*:}; arch=${rest%%:*}; suffix=${rest#*:}
    want=$(printf '%s\n' "$gh_sums" | awk -v f="gh_${GH_VERSION}_${suffix}" '$2 == f {print $1}')
    got=$(recorded "gh:$os:$arch")
    if [ -z "$want" ]; then bad "gh $os/$arch: no such asset published"
    elif [ "$want" = "$got" ]; then good "gh $os/$arch"
    else bad "gh $os/$arch: recorded $got, published $want"; fi
  done
fi

# ─── node ───────────────────────────────────────────────────────────────────
node_sums=$(curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" 2>/dev/null || true)
if [ -z "$node_sums" ]; then
  bad "node ${NODE_VERSION}: no published checksum file — is the version still released?"
else
  for target in macos:arm64:darwin-arm64 macos:x64:darwin-x64 \
                linux:arm64:linux-arm64 linux:x64:linux-x64; do
    os=${target%%:*}; rest=${target#*:}; arch=${rest%%:*}; plat=${rest#*:}
    want=$(printf '%s\n' "$node_sums" | awk -v f="node-v${NODE_VERSION}-${plat}.tar.gz" '$2 == f {print $1}')
    got=$(recorded "node:$os:$arch")
    if [ -z "$want" ]; then bad "node $os/$arch: no such asset published"
    elif [ "$want" = "$got" ]; then good "node $os/$arch"
    else bad "node $os/$arch: recorded $got, published $want"; fi
  done
fi

printf '\n'
if [ "$FAILED" -eq 0 ]; then
  printf '  every pinned checksum matches what the vendor publishes\n\n'
  exit 0
fi
printf '  %s pin(s) do not match. Do not ship until this is understood.\n\n' "$FAILED"
exit 1
