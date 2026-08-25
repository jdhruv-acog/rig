#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043  # `local` — see rig.sh for the portability reasoning
#
# unit — rig's functions, one at a time.
#
# rig.sh is sourced with RIG_SOURCED=1, which stops it short of main(), so every
# function below is exercised without running an install and without a network.
# HOME is a throwaway directory for the whole file: nothing here may reach the
# real one.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$HERE")
# shellcheck source=/dev/null
. "$HERE/lib.sh"

new_home >/dev/null
ROOT_SANDBOX="$SANDBOX"
trap 'rm -rf "$ROOT_SANDBOX"' EXIT INT TERM HUP

RIG_SOURCED=1
export RIG_SOURCED
# shellcheck source=/dev/null
. "$ROOT/rig.sh"

# rig.sh runs under `set -e`; the assertions below deliberately run commands that
# fail, and each one reports rather than aborts.
set +e

PATH_AT_START="$PATH"
CASE_N=0
case_dir() {  # a fresh directory per case, so no case can see another's leftovers
  CASE_N=$((CASE_N + 1))
  mkdir -p "$ROOT_SANDBOX/case$CASE_N"
  printf '%s' "$ROOT_SANDBOX/case$CASE_N"
}

BEGIN="# BEGIN aganitha"
END="# END aganitha"

# ─── write_block ────────────────────────────────────────────────────────────

suite "write_block"

d=$(case_dir); rc="$d/rc"
printf 'mine above\n' > "$rc"

write_block "$rc" "$BEGIN" "$END" '. /x/env.sh'
assert_eq "appends when the block is absent" "1" "$(count_matching "^$BEGIN\$" "$rc")"
assert_contains "the person's line survives" "mine above" "$(cat "$rc")"
assert_contains "the body is written" ". /x/env.sh" "$(cat "$rc")"

write_block "$rc" "$BEGIN" "$END" '. /x/env.sh'
write_block "$rc" "$BEGIN" "$END" '. /x/env.sh'
assert_eq "three runs leave exactly one block" "1" "$(count_matching "^$BEGIN\$" "$rc")"
assert_eq "and exactly one end marker" "1" "$(count_matching "^$END\$" "$rc")"

write_block "$rc" "$BEGIN" "$END" '. /x/env.sh'
assert_eq "returns 1 when nothing changed" "1" "$?"

before=$(cat "$rc")
write_block "$rc" "$BEGIN" "$END" '. /x/env.sh'
assert_eq "and leaves the file byte-identical" "$before" "$(cat "$rc")"

# A person's own lines on both sides, and the block rewritten between them.
d=$(case_dir); rc="$d/rc"
{ printf 'mine above\n'; printf '%s\n' "$BEGIN"; printf '. /old/env.sh\n'
  printf '%s\n' "$END"; printf 'mine below\n'; } > "$rc"

write_block "$rc" "$BEGIN" "$END" '. /new/env.sh'
assert_eq "returns 0 when the body changed" "0" "$?"
assert_eq "still exactly one block" "1" "$(count_matching "^$BEGIN\$" "$rc")"
assert_eq "the region is rewritten in place, both sides verbatim" \
  "mine above
$BEGIN
. /new/env.sh
$END
mine below" "$(cat "$rc")"
assert_not_contains "the old body is gone" "/old/env.sh" "$(cat "$rc")"

write_block "$rc" "$BEGIN" "$END" '. /new/env.sh'
assert_eq "unchanged is still 1 with lines below the block" "1" "$?"

# A file that does not exist yet is created rather than refused.
d=$(case_dir)
write_block "$d/fresh" "$BEGIN" "$END" '. /x/env.sh'
assert_file "creates a missing file" "$d/fresh"

# The residue of a botched hand edit: two marked regions. One survives.
d=$(case_dir); rc="$d/rc"
{ printf '%s\n' "$BEGIN"; printf 'a\n'; printf '%s\n' "$END"
  printf 'keep me\n'
  printf '%s\n' "$BEGIN"; printf 'b\n'; printf '%s\n' "$END"; } > "$rc"
write_block "$rc" "$BEGIN" "$END" '. /x/env.sh'
assert_eq "a duplicated block collapses to one" "1" "$(count_matching "^$BEGIN\$" "$rc")"
assert_contains "and the line between them survives" "keep me" "$(cat "$rc")"

# ─── record ─────────────────────────────────────────────────────────────────

suite "record"

d=$(case_dir)
RIG_HOME="$d/rig"; MANIFEST="$RIG_HOME/manifest"

record bun 1.4.0 "$RIG_HOME/bun"
assert_file "creates the manifest" "$MANIFEST"
assert_eq "with a schema line first" "schema	1" "$(head -1 "$MANIFEST")"

record uv 0.12.5 "$RIG_HOME/uv"
record bun 1.4.0 "$RIG_HOME/bun"
assert_eq "upserts by name — no duplicate line" "1" "$(count_matching '^bun	' "$MANIFEST")"
assert_eq "and the other entry is untouched" "1" "$(count_matching '^uv	' "$MANIFEST")"

# The timestamp answers "when did rig install this". Rewriting an unchanged entry
# would turn it into "when did rig last run", and the file would never be stable.
# A visibly impossible time proves the original was kept rather than re-derived.
sed 's/^bun	1.4.0	\(.*\)	.*$/bun	1.4.0	\1	1999-01-01T00:00:00Z/' "$MANIFEST" > "$MANIFEST.t"
mv "$MANIFEST.t" "$MANIFEST"
before=$(cat "$MANIFEST")
record bun 1.4.0 "$RIG_HOME/bun"
assert_eq "an unchanged entry keeps its timestamp" "$before" "$(cat "$MANIFEST")"

record bun 1.5.0 "$RIG_HOME/bun"
assert_contains "a new version is recorded" "1.5.0" "$(grep '^bun	' "$MANIFEST")"
assert_not_contains "and the old timestamp goes with it" "1999-01-01" "$(grep '^bun	' "$MANIFEST")"
assert_eq "still one bun line" "1" "$(count_matching '^bun	' "$MANIFEST")"

record bun 1.5.0 "$d/elsewhere"
assert_contains "a new path is recorded" "$d/elsewhere" "$(grep '^bun	' "$MANIFEST")"
assert_eq "still one bun line after a path change" "1" "$(count_matching '^bun	' "$MANIFEST")"

record shell
assert_contains "an omitted version and path record as -" "shell	-	-" "$(grep '^shell	' "$MANIFEST")"

# ─── verify_sha256 ──────────────────────────────────────────────────────────

suite "verify_sha256"

d=$(case_dir)
printf 'rig\n' > "$d/payload"
if command -v shasum >/dev/null 2>&1; then
  sum=$(shasum -a 256 "$d/payload" | awk '{print $1}')
else
  sum=$(sha256sum "$d/payload" | awk '{print $1}')
fi

assert_exits "a correct sum passes" 0 verify_sha256 "$d/payload" "$sum"
assert_exits "a wrong sum is fatal, exit 1" 1 \
  verify_sha256 "$d/payload" "0000000000000000000000000000000000000000000000000000000000000000"
assert_exits "an empty expected sum is skipped" 0 verify_sha256 "$d/payload" ""

out=$( (verify_sha256 "$d/payload" "0000") 2>&1 )
assert_contains "and it says what it expected" "expected 0000" "$out"
assert_contains "and what it got" "$sum" "$out"

# ─── detect_platform ────────────────────────────────────────────────────────

suite "detect_platform"

# uname is one program with two answers, so the stub reads its own argument.
plat() {  # plat <uname -s> <uname -m> [proc_translated] [macOS version] -> "<os> <arch>"
  local dir
  dir=$(case_dir)/bin
  stub_body "$dir" uname "case \"\$1\" in
  -s) echo '$1' ;;
  -m) echo '$2' ;;
  *) echo '$1' ;;
esac"
  stub "$dir" sysctl 0 "${3:-0}"
  stub "$dir" sw_vers 0 "${4:-15.2}"
  PATH="$dir:$PATH_AT_START"
  OS=""; ARCH=""
  detect_platform
  PATH="$PATH_AT_START"
  printf '%s %s' "$OS" "$ARCH"
}

assert_eq "Darwin arm64"        "macos arm64" "$(plat Darwin arm64)"
assert_eq "Darwin x86_64"       "macos x64"   "$(plat Darwin x86_64 0)"
assert_eq "Linux aarch64"       "linux arm64" "$(plat Linux aarch64)"
assert_eq "Linux x86_64"        "linux x64"   "$(plat Linux x86_64)"
assert_eq "Linux amd64"         "linux x64"   "$(plat Linux amd64)"
# Under Rosetta an Apple Silicon Mac reports x86_64, and installing the x64
# toolchain for that answer runs emulated for years with nothing to say so.
assert_eq "Darwin x86_64 under Rosetta is arm64" "macos arm64" "$(plat Darwin x86_64 1)"

# node 24 needs macOS 13.5 or newer, so an older Mac is refused here rather than
# by a dynamic-linker error from a binary that downloaded and verified perfectly.
d=$(case_dir)/bin
stub_body "$d" uname "case \"\$1\" in -s) echo Darwin ;; *) echo arm64 ;; esac"
stub "$d" sysctl 0 "0"
stub "$d" sw_vers 0 "12.7.1"
PATH="$d:$PATH_AT_START"
assert_exits "macOS 12 is refused, exit 2" 2 detect_platform
assert_contains "and it names the release" "12.7.1" "$( (detect_platform) 2>&1 )"
PATH="$PATH_AT_START"
assert_eq "macOS 13 is fine" "macos arm64" "$(plat Darwin arm64 0 13.5)"

d=$(case_dir)/bin
stub_body "$d" uname "case \"\$1\" in -s) echo FreeBSD ;; *) echo amd64 ;; esac"
PATH="$d:$PATH_AT_START"
assert_exits "an unsupported OS is refused, exit 2" 2 detect_platform
out=$( (detect_platform) 2>&1 )
assert_contains "and it names the OS it found" "FreeBSD" "$out"

d=$(case_dir)/bin
stub_body "$d" uname "case \"\$1\" in -s) echo Linux ;; *) echo mips64 ;; esac"
PATH="$d:$PATH_AT_START"
assert_exits "an unsupported architecture is refused, exit 2" 2 detect_platform
out=$( (detect_platform) 2>&1 )
assert_contains "and it names the architecture" "mips64" "$out"
PATH="$PATH_AT_START"

# ─── shell_rc ───────────────────────────────────────────────────────────────

suite "shell_rc"

d=$(case_dir); HOME="$d"

SHELL=/bin/zsh;              assert_eq "zsh"  "$d/.zshrc"  "$(shell_rc)"
SHELL=/usr/local/bin/zsh;    assert_eq "zsh anywhere on disk" "$d/.zshrc" "$(shell_rc)"
SHELL=/bin/bash;             assert_eq "bash" "$d/.bashrc" "$(shell_rc)"
SHELL=/usr/bin/fish;         assert_eq "fish has no rc rig can write" "" "$(shell_rc)"

SHELL=/bin/ksh
assert_eq "an unknown shell with no .zshrc falls to .profile" "$d/.profile" "$(shell_rc)"
: > "$d/.zshrc"
assert_eq "an unknown shell with a .zshrc uses it" "$d/.zshrc" "$(shell_rc)"

unset SHELL
assert_eq "no SHELL at all still answers" "$d/.zshrc" "$(shell_rc)"
SHELL=/bin/sh

HOME="$ROOT_SANDBOX"

# ─── parse_args ─────────────────────────────────────────────────────────────

suite "parse_args"

ASSUME_YES=0; PACK=""
parse_args --yes
assert_eq "--yes sets the standard answer" "1" "$ASSUME_YES"
assert_eq "and consumes no pack" "" "$PACK"

ASSUME_YES=0; PACK=""
parse_args -y
assert_eq "-y is the same" "1" "$ASSUME_YES"

ASSUME_YES=0; PACK=""
parse_args bio
assert_eq "a bare word is the pack" "bio" "$PACK"

ASSUME_YES=0; PACK=""
parse_args --yes bio
assert_eq "a flag and a pack together" "bio" "$PACK"
assert_eq "and the flag still took" "1" "$ASSUME_YES"

PACK=""
assert_exits "--version stops, exit 0" 0 parse_args --version
assert_eq "--version prints the version" "rig $RIG_VERSION" "$( (parse_args --version) 2>&1 )"

PACK=""
assert_exits "--help stops, exit 0" 0 parse_args --help
assert_contains "--help says what it is" "take a machine from nothing to ready" \
  "$( (parse_args --help) 2>&1 )"

PACK=""
assert_exits "an unknown option is refused, exit 2" 2 parse_args --wat
assert_contains "and names it" "--wat" "$( (parse_args --wat) 2>&1 )"

PACK=""
assert_exits "two packs are refused, exit 2" 2 parse_args bio chem
assert_contains "and names both" "bio and chem" "$( (parse_args bio chem) 2>&1 )"
PACK=""

# ─── clt_label_parse ────────────────────────────────────────────────────────
#
# Software Update has printed these two ways across the macOS releases rig has to
# run on. Both are fed here, mixed and in the ascending order Software Update
# uses, and the answer must be the last — the newest.

suite "clt_label_parse"

new_format="Software Update found the following new software:
* Label: Command Line Tools for Xcode-15.3
	Title: Command Line Tools for Xcode, Version: 15.3, Size: 730076KiB
* Label: Command Line Tools for Xcode-16.1
	Title: Command Line Tools for Xcode, Version: 16.1, Size: 750000KiB"

old_format="Software Update found the following new software:
   * Command Line Tools (macOS High Sierra version 10.13) for Xcode-9.4
	Command Line Tools (macOS High Sierra version 10.13) for Xcode-9.4 (9.4)
   * Command Line Tools (macOS High Sierra version 10.13) for Xcode-10.1
	Command Line Tools (macOS High Sierra version 10.13) for Xcode-10.1 (10.1)"

assert_eq "the newer 'Label:' format, last match wins" \
  "Command Line Tools for Xcode-16.1" "$(printf '%s\n' "$new_format" | clt_label_parse)"

assert_eq "the older '* …' format, last match wins" \
  "Command Line Tools (macOS High Sierra version 10.13) for Xcode-10.1" \
  "$(printf '%s\n' "$old_format" | clt_label_parse)"

assert_eq "both formats in one listing, last match wins" \
  "Command Line Tools for Xcode-16.1" \
  "$(printf '%s\n%s\n' "$old_format" "$new_format" | clt_label_parse)"

assert_eq "an indented Label line with no asterisk" \
  "Command Line Tools for Xcode-16.1" \
  "$(printf '\tLabel: Command Line Tools for Xcode-16.1\n' | clt_label_parse)"

assert_eq "a listing with no Command Line Tools prints nothing" "" \
  "$(printf 'No new software available.\n* Label: macOS Sequoia 15.2-24C101\n' | clt_label_parse)"

assert_eq "empty input prints nothing" "" "$(printf '' | clt_label_parse)"

# A Title line mentioning the tools must not be mistaken for a label.
assert_eq "a Title line is not a label" "Command Line Tools for Xcode-16.1" \
  "$(printf '* Label: Command Line Tools for Xcode-16.1\n\tTitle: Command Line Tools for Xcode, Version: 16.1\n' \
     | clt_label_parse)"

# ─── works ──────────────────────────────────────────────────────────────────
#
# On macOS `command -v` is not an answer: /usr/bin/git is a stub that exists
# whether or not the tools behind it do. So the tool is run, never merely located.

suite "works"

d=$(case_dir)/bin
stub "$d" present 0
stub "$d" broken 1
PATH="$d:$PATH_AT_START"
assert_exits "a tool that runs" 0 works present --version
assert_exits "a tool that is there but fails" 1 works broken --version
assert_exits "a tool that is not there" 1 works nosuchtool --version
PATH="$PATH_AT_START"

report
