#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043  # `local` — see rig.sh for the portability reasoning
# shellcheck disable=SC2016  # the single quotes are the assertion: env.sh must
#   contain these characters literally, and the shell fragments handed to `sh -c`
#   must reach it unexpanded.
#
# hermetic — whole runs of rig.sh and uninstall-rig.sh, with nothing real behind
# them.
#
# Every case gets its own HOME from mktemp and a PATH that starts with a
# directory of stubs and holds only the system directories after it. Nothing here
# reaches the network, and nothing here can see a bun, uv, node or gh that
# happens to be installed on the machine running the tests — which is the point:
# a suite that passes only on a developer's laptop proves nothing about a fresh
# one.
#
# The stubs count their calls. That is what makes the second-run case an actual
# proof: "the files look the same afterwards" would also pass if every installer
# had run again and rewritten them.
set -u

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$HERE")
# shellcheck source=/dev/null
. "$HERE/lib.sh"

RIG="$ROOT/rig.sh"
UNINSTALL="$ROOT/uninstall-rig.sh"

WORKROOT=$(mktemp -d "${TMPDIR:-/tmp}/righerm.XXXXXX")
trap 'rm -rf "$WORKROOT"' EXIT INT TERM HUP
FIX="$WORKROOT/fixtures"

# Only the system directories. A homebrew or bun directory on the real PATH would
# put a real gh or node in reach and quietly turn an install case into a
# already-here case.
SYS_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# ─── fixtures ───────────────────────────────────────────────────────────────
#
# What the vendors would have served, built once and served from disk by the
# curl stub.

# Read a pin out of rig.sh itself rather than copying it here. A checksum copied
# into a test is a second source of truth that goes stale silently.
pin() {  # pin <key> -> the pinned sha256
  RIG_SOURCED=1 sh -c '. "$1"; checksum_for "$2"' sh "$RIG" "$1"
}

# rig unpacks the gh release with unzip, so the fixture has to be a real zip.
# `zip` is not one of rig's prerequisites and is missing from a bare Debian, so
# python3 is the fallback.
make_zip() {  # make_zip <zipfile> <dir-to-zip> <entry-path-inside>
  if command -v zip >/dev/null 2>&1; then
    ( cd "$2" && zip -q -r "$1" . )
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$1" "$2/$3" "$3" <<'PY'
import os, stat, sys, zipfile
out, src, name = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(out, "w") as z:
    info = zipfile.ZipInfo(name)
    info.external_attr = (stat.S_IFREG | 0o755) << 16
    z.writestr(info, open(src).read())
PY
    return 0
  fi
  return 1
}

build_fixtures() {
  local d
  mkdir -p "$FIX"

  # gh: a release zip holding one executable that answers --version.
  d="$WORKROOT/build/gh_2.98.0_linux_amd64/bin"
  mkdir -p "$d"
  printf '#!/bin/sh\necho "gh version 2.98.0 (2025-01-01)"\n' > "$d/gh"
  chmod +x "$d/gh"
  make_zip "$FIX/gh.zip" "$WORKROOT/build" "gh_2.98.0_linux_amd64/bin/gh" \
    || { printf 'hermetic: no zip and no python3 — cannot build the gh fixture\n' >&2; exit 1; }

  # node: a tarball with the one directory rig strips off the front.
  d="$WORKROOT/build/node-v24.19.0-linux-x64/bin"
  mkdir -p "$d"
  printf '#!/bin/sh\necho "v24.19.0"\n' > "$d/node"
  chmod +x "$d/node"
  ( cd "$WORKROOT/build" && tar -czf "$FIX/node.tar.gz" "node-v24.19.0-linux-x64" )

  # The two vendor installers. Each honours the directory variable rig hands it,
  # exactly as the real ones do, and writes a binary that answers the questions
  # rig asks after the install.
  cat > "$FIX/bun-install.sh" <<'INSTALLER'
mkdir -p "$BUN_INSTALL/bin"
cat > "$BUN_INSTALL/bin/bun" <<'BUN'
#!/bin/sh
case "$*" in
  --version)   echo "1.4.0" ;;
  "pm bin -g") dirname "$0" ;;
  *) exit 0 ;;
esac
BUN
chmod +x "$BUN_INSTALL/bin/bun"
INSTALLER

  cat > "$FIX/uv-install.sh" <<'INSTALLER'
mkdir -p "$UV_INSTALL_DIR"
cat > "$UV_INSTALL_DIR/uv" <<'UV'
#!/bin/sh
# A python install lands an interpreter under UV_PYTHON_INSTALL_DIR and a shim
# in UV_PYTHON_BIN_DIR, which is what rig looks for afterwards.
case "$*" in
  --version) echo "uv 0.12.5" ;;
  "python install "*)
    mkdir -p "$UV_PYTHON_INSTALL_DIR" "$UV_PYTHON_BIN_DIR"
    printf '#!/bin/sh\necho "Python 3.14.0"\n' > "$UV_PYTHON_BIN_DIR/python3"
    chmod +x "$UV_PYTHON_BIN_DIR/python3" ;;
  *) exit 0 ;;
esac
UV
chmod +x "$UV_INSTALL_DIR/uv"
INSTALLER

  GH_SUM=$(pin gh:linux:x64)
  NODE_SUM=$(pin node:linux:x64)
}

# ─── the stubbed machine ────────────────────────────────────────────────────

# curl, told what each URL serves. It refuses an address rig was never supposed
# to reach, so a new download added to rig.sh fails here rather than escaping to
# the network.
fake_curl() {  # fake_curl <dir>
  cat > "$1/curl" <<CURL
#!/bin/sh
echo "\$*" >> "$1/.calls.curl"
url=""; dest=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) dest="\$2"; shift 2 ;;
    https://*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
if [ -n "\${RIGTEST_CURL_FAIL:-}" ]; then
  case "\$url" in
    *"\$RIGTEST_CURL_FAIL"*) echo "curl: (22) simulated failure" >&2; exit 22 ;;
  esac
fi
case "\$url" in
  *cli/cli/releases/download/*) cp "$FIX/gh.zip" "\$dest" ;;
  https://nodejs.org/dist/*)    cp "$FIX/node.tar.gz" "\$dest" ;;
  https://bun.sh/install)       cat "$FIX/bun-install.sh" ;;
  https://astral.sh/uv/*)       cat "$FIX/uv-install.sh" ;;
  *) echo "curl: refusing an address this test did not expect: \$url" >&2; exit 1 ;;
esac
CURL
  chmod +x "$1/curl"
}

# The checksum tools answer for the two pinned assets and nothing else. Faking
# the hasher rather than the pins is what lets a fabricated archive travel rig's
# real fetch-and-verify path; verify_sha256 itself is proved against a genuine
# sum in unit.sh.
fake_sums() {  # fake_sums <dir>
  local name
  for name in shasum sha256sum; do
    cat > "$1/$name" <<SUM
#!/bin/sh
echo "\$*" >> "$1/.calls.$name"
for f in "\$@"; do :; done
case "\$f" in
  *gh_*)    echo "$GH_SUM  \$f" ;;
  *node-v*) echo "$NODE_SUM  \$f" ;;
  *) echo "$name: nothing pinned for \$f" >&2; exit 1 ;;
esac
SUM
    chmod +x "$1/$name"
  done
}

# A machine with git and nothing else. STUBS is the only directory ahead of the
# system ones, so this is the whole of what rig can find.
STUBS=""
new_case() {  # new_case -> a fresh HOME with a stubbed machine around it
  new_home >/dev/null
  STUBS="$SANDBOX/stubs"
  mkdir -p "$STUBS"
  stub_body "$STUBS" uname 'case "$1" in
  -s) echo Linux ;;
  -m) echo x86_64 ;;
  *)  echo Linux ;;
esac'
  stub "$STUBS" git 0 "git version 2.44.0"
  spy "$STUBS" tar
  spy "$STUBS" unzip
  fake_curl "$STUBS"
  fake_sums "$STUBS"
}

RIG_CODE=0
RIG_LOG=""
run_rig() {  # run_rig [args...] -> RIG_CODE, RIG_LOG
  RIG_LOG="$SANDBOX/rig.log"
  RIG_CODE=0
  env -i HOME="$SANDBOX" PATH="$STUBS:$SYS_PATH" SHELL=/bin/zsh \
      TMPDIR="${TMPDIR:-/tmp}" NO_COLOR=1 \
      RIGTEST_CURL_FAIL="${RIGTEST_CURL_FAIL:-}" \
      sh "$RIG" "$@" </dev/null >"$RIG_LOG" 2>&1 || RIG_CODE=$?
}

UN_CODE=0
UN_LOG=""
run_uninstall() {
  UN_LOG="$SANDBOX/uninstall.log"
  UN_CODE=0
  env -i HOME="$SANDBOX" PATH="$STUBS:$SYS_PATH" SHELL=/bin/zsh \
      TMPDIR="${TMPDIR:-/tmp}" NO_COLOR=1 \
      sh "$UNINSTALL" "$@" </dev/null >"$UN_LOG" 2>&1 || UN_CODE=$?
}

build_fixtures

MANIFEST_OF()  { printf '%s' "$1/.aganitha/rig/manifest"; }
ENVFILE_OF()   { printf '%s' "$1/.aganitha/rig/env.sh"; }

# ─── a first run on an empty machine ────────────────────────────────────────

suite "a full run on an empty HOME"

new_case
run_rig --yes
h="$SANDBOX"

assert_eq "the run succeeds" "0" "$RIG_CODE"
assert_file "the manifest is written" "$(MANIFEST_OF "$h")"
assert_file "env.sh is written"       "$(ENVFILE_OF "$h")"
assert_file "the shell rc is written" "$h/.zshrc"

assert_eq "the schema line comes first" "schema	1" "$(head -1 "$(MANIFEST_OF "$h")")"
for tool in gh bun uv python node env shell; do
  assert_eq "$tool is recorded" "1" "$(count_matching "^$tool	" "$(MANIFEST_OF "$h")")"
done

assert_contains "the shell block is in .zshrc" "# BEGIN aganitha" "$(cat "$h/.zshrc")"
assert_contains "and it sources env.sh" ". \"$h/.aganitha/rig/env.sh\"" "$(cat "$h/.zshrc")"
assert_eq "exactly one block" "1" "$(count_matching '^# BEGIN aganitha$' "$h/.zshrc")"

assert_file "gh landed in the rig tree" "$h/.aganitha/rig/bin/gh"
assert_file "bun landed in the rig tree" "$h/.aganitha/rig/bun/bin/bun"
assert_file "uv landed in the rig tree" "$h/.aganitha/rig/uv/uv"
assert_file "node landed in the rig tree" "$h/.aganitha/rig/node/bin/node"

# ─── env.sh runs on every shell start ───────────────────────────────────────

suite "env.sh costs nothing to read"

env_body=$(cat "$(ENVFILE_OF "$h")")
assert_not_contains "no command substitution" '$(' "$env_body"
assert_not_contains "no backticks"            '`' "$env_body"
assert_contains "it exports PATH" "export PATH" "$env_body"
assert_contains "the rig bin directory is on it" "$h/.aganitha/rig/bin" "$env_body"
assert_contains "and the commands directory is picked up when it appears" \
  '$AGANITHA_HOME/commands/bin' "$env_body"

# It has to be readable by a shell that will exit on a non-zero return, because
# an rc file under `set -e` is where that lands on somebody's Monday morning.
assert_exits "it is valid sh and returns 0 under set -e" 0 \
  sh -c 'set -e; . "$1"' sh "$(ENVFILE_OF "$h")"

# ─── the second run ─────────────────────────────────────────────────────────
#
# The claim rig makes at the top of its own file is that a second run does
# nothing. This is where that is either true or it is not.

suite "a second run acts on nothing"

manifest_before=$(cat "$(MANIFEST_OF "$h")")
rc_before=$(cat "$h/.zshrc")
env_before=$(cat "$(ENVFILE_OF "$h")")

reset_calls "$STUBS"
run_rig --yes

assert_eq "the second run succeeds" "0" "$RIG_CODE"
assert_eq "nothing was downloaded"  "0" "$(calls "$STUBS" curl)"
assert_eq "nothing was unpacked with tar"   "0" "$(calls "$STUBS" tar)"
assert_eq "nothing was unpacked with unzip" "0" "$(calls "$STUBS" unzip)"
assert_eq "nothing was checksummed"  "0" "$(calls "$STUBS" shasum)"

assert_eq "the manifest is byte-identical" "$manifest_before" "$(cat "$(MANIFEST_OF "$h")")"
assert_eq "the shell rc is byte-identical" "$rc_before"       "$(cat "$h/.zshrc")"
assert_eq "env.sh is byte-identical"       "$env_before"      "$(cat "$(ENVFILE_OF "$h")")"

# A third run, to catch anything that alternates rather than settles.
run_rig --yes
assert_eq "a third run also changes nothing" "$manifest_before" "$(cat "$(MANIFEST_OF "$h")")"

# A line the person added after rig ran must still be there, and still below the
# block, on the next run.
printf 'export EDITOR=vim\n' >> "$h/.zshrc"
rc_before=$(cat "$h/.zshrc")
run_rig --yes
assert_eq "a line added after rig ran survives, in place" "$rc_before" "$(cat "$h/.zshrc")"

drop_home

# ─── something already on the machine ───────────────────────────────────────

suite "a tool already on the machine is used, not recorded"

new_case
h="$SANDBOX"
mkdir -p "$h/mine/bin"
cat > "$h/mine/bin/bun" <<'BUN'
#!/bin/sh
case "$*" in
  --version)   echo "1.2.3" ;;
  "pm bin -g") dirname "$0" ;;
  *) exit 0 ;;
esac
BUN
chmod +x "$h/mine/bin/bun"

RIG_LOG="$h/rig.log"; RIG_CODE=0
env -i HOME="$h" PATH="$h/mine/bin:$STUBS:$SYS_PATH" SHELL=/bin/zsh \
    TMPDIR="${TMPDIR:-/tmp}" NO_COLOR=1 \
    sh "$RIG" --yes </dev/null >"$RIG_LOG" 2>&1 || RIG_CODE=$?

assert_eq "the run succeeds" "0" "$RIG_CODE"
assert_contains "rig says it found one already" "already on this machine" "$(cat "$RIG_LOG")"
assert_eq "the person's bun is not recorded" "0" \
  "$(count_matching '^bun	' "$(MANIFEST_OF "$h")")"
assert_no_file "and nothing was installed over it" "$h/.aganitha/rig/bun/bin/bun"
assert_eq "the tools rig did install are still recorded" "1" \
  "$(count_matching '^node	' "$(MANIFEST_OF "$h")")"

# The whole reason it is not recorded: uninstall must leave it alone.
run_uninstall --yes
assert_eq "uninstall succeeds" "0" "$UN_CODE"
assert_file "the person's bun is still there" "$h/mine/bin/bun"
assert_no_file "and rig's tree is gone" "$(MANIFEST_OF "$h")"

drop_home

# ─── a stage that fails ─────────────────────────────────────────────────────

suite "a failed stage records nothing"

new_case
h="$SANDBOX"
RIGTEST_CURL_FAIL="bun.sh"; export RIGTEST_CURL_FAIL
run_rig --yes
unset RIGTEST_CURL_FAIL

assert_eq "the run fails" "1" "$RIG_CODE"
assert_contains "and says which stage" "bun" "$(cat "$RIG_LOG")"
assert_file "the manifest exists — earlier stages did happen" "$(MANIFEST_OF "$h")"
assert_eq "gh, which succeeded, is recorded" "1" \
  "$(count_matching '^gh	' "$(MANIFEST_OF "$h")")"
assert_eq "bun, which failed, is not" "0" \
  "$(count_matching '^bun	' "$(MANIFEST_OF "$h")")"
assert_eq "and neither is anything after it" "0" \
  "$(count_matching '^node	' "$(MANIFEST_OF "$h")")"

# The same line again finishes the job. That is the recovery rig promises.
run_rig --yes
assert_eq "running the same line again succeeds" "0" "$RIG_CODE"
assert_eq "and bun is recorded now" "1" "$(count_matching '^bun	' "$(MANIFEST_OF "$h")")"

drop_home

# ─── uninstall ──────────────────────────────────────────────────────────────

suite "uninstall removes what is recorded, and only that"

new_case
h="$SANDBOX"
mkdir -p "$h/mine/bin"
printf '#!/bin/sh\necho hi\n' > "$h/mine/bin/keepme"
chmod +x "$h/mine/bin/keepme"
mkdir -p "$h/.aganitha/notes"          # somebody's own files under ~/.aganitha
printf 'mine\n' > "$h/.aganitha/notes/n"

run_rig --yes
assert_eq "the install succeeds" "0" "$RIG_CODE"

run_uninstall --yes
assert_eq "uninstall succeeds" "0" "$UN_CODE"
assert_no_file "the manifest is gone" "$(MANIFEST_OF "$h")"
assert_no_file "env.sh is gone" "$(ENVFILE_OF "$h")"
if [ -d "$h/.aganitha/rig" ]; then fail "the rig tree is gone"; else pass "the rig tree is gone"; fi
assert_file "an unrecorded file elsewhere is untouched" "$h/mine/bin/keepme"
assert_file "and somebody's own files under ~/.aganitha stay" "$h/.aganitha/notes/n"
assert_contains "it says what it removed" "removed" "$(cat "$UN_LOG")"

drop_home

suite "uninstall leaves the rest of the rc alone"

new_case
h="$SANDBOX"
printf 'export EDITOR=vim\n' > "$h/.zshrc"
run_rig --yes
printf 'alias ll="ls -l"\n' >> "$h/.zshrc"

run_uninstall --yes
assert_eq "uninstall succeeds" "0" "$UN_CODE"
assert_eq "the block is gone and every other line is verbatim" \
  'export EDITOR=vim
alias ll="ls -l"' "$(cat "$h/.zshrc")"

drop_home

suite "uninstall refuses while packs are installed"

new_case
h="$SANDBOX"
run_rig --yes
printf 'bio\t1.0\t2025-01-01T00:00:00Z\n' > "$h/.aganitha/.packs_installed"

run_uninstall --yes
assert_eq "it refuses, exit 2" "2" "$UN_CODE"
assert_contains "and names the pack" "bio" "$(cat "$UN_LOG")"
assert_contains "and names the command that puts it in order" "atk uninstall" "$(cat "$UN_LOG")"
assert_file "nothing was removed" "$(MANIFEST_OF "$h")"

# An empty record is not a pack, and must not block anything.
: > "$h/.aganitha/.packs_installed"
run_uninstall --yes
assert_eq "an empty packs record does not block" "0" "$UN_CODE"

drop_home

suite "uninstall --force overrides the refusal"

new_case
h="$SANDBOX"
run_rig --yes
printf 'bio\t1.0\t2025-01-01T00:00:00Z\n' > "$h/.aganitha/.packs_installed"

run_uninstall --force --yes
assert_eq "--force goes ahead" "0" "$UN_CODE"
assert_contains "and says it is overriding" "--force" "$(cat "$UN_LOG")"
assert_no_file "the manifest is gone" "$(MANIFEST_OF "$h")"

drop_home

suite "uninstall on a machine rig never touched"

new_case
run_uninstall --yes
assert_eq "it succeeds and says there is nothing to undo" "0" "$UN_CODE"
assert_contains "in those words" "Nothing to undo" "$(cat "$UN_LOG")"

run_uninstall --wat
assert_eq "an unknown option is refused, exit 2" "2" "$UN_CODE"

drop_home

report
