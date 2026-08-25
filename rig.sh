#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043  # `local` is not POSIX, but dash, ash, busybox sh,
#   bash and zsh all implement it. Without it every function variable is global,
#   and a callee silently clobbers a caller's `tmp`.
# shellcheck disable=SC2016  # this script generates a shell file; $PATH and $HOME
#   must reach that file unexpanded.
# rig — take a machine from nothing to ready, in one command.
#
#   curl -fsSL https://<host>/rig.sh | sh                  the toolchain only
#   curl -fsSL https://<host>/rig.sh | sh -s -- <pack>     the toolchain, then a pack
#
# rig installs a public toolchain into ~/.aganitha/rig, signs the machine in to
# GitHub, fetches the private command repo, and hands over. It knows no company
# name, no hostname, and no package name — the pack argument is a word it carries
# and never interprets. scripts/check-clean.sh proves that in CI.
#
# It is POSIX sh because macOS ships bash 3.2 from 2007 and Debian's /bin/sh is
# dash. It is one file because it is fetched with curl and run once; it is never
# installed, so it can never be stale.
#
# Every stage checks before it acts and checks again after, so a second run does
# nothing and an interrupted run is finished by running the same line again.
set -eu

RIG_VERSION="1.0.0"

# ─── pinned versions ────────────────────────────────────────────────────────
#
# Pinned, not "latest": a bootstrap that installs a different thing each day
# cannot be supported. Bump these deliberately. tests/pins.sh runs in CI and
# fails when a recorded checksum no longer matches what the vendor publishes,
# so a pin can go out of date but it can never go silently wrong.
#
# gh and node are downloaded as binaries, so their checksums are recorded here.
# bun and uv are installed by their own vendor installers over TLS, which detect
# the platform themselves; those get a version pin and no checksum.
GH_VERSION="2.98.0"
NODE_VERSION="24.19.0"
BUN_VERSION="1.4.0"
UV_VERSION="0.12.5"
PYTHON_VERSION="3.14"

checksum_for() {
  case "$1" in
    gh:macos:arm64)  echo "8cfb027cc5310675f2b830eac8f9865c1155a45ffcf9757f699fdd5a22046ca4" ;;
    gh:macos:x64)    echo "734c7bbd0bc56a3974500ee9aea74d60f0e5b89be09e92b9d9148939a3a1e0e6" ;;
    gh:linux:arm64)  echo "cf689084f3a3618f7eae4a2420d335d74626d65f5e594b9828d125d69f800d86" ;;
    gh:linux:x64)    echo "3b8ac6b30336802fc1a858d7c084e11cdf24ac1a761ca90b68022d7d729208de" ;;
    node:macos:arm64) echo "8294b7aa9b03997481c06babf1e8b270c859358f27da57a11509afe537ac381d" ;;
    node:macos:x64)   echo "d1b5e999db158c62fe8f7267a4476b035d8bd93b1a605bac24a3f0dd166e3316" ;;
    node:linux:arm64) echo "d28c8a5bf0a808f0ed434a1dce8c54ae98f0371c0bd86ac58abc613f73e6643f" ;;
    node:linux:x64)   echo "f625d97cd707df4ff96254916fbc5ff014f09c09effe5a1e0ca8f6d41a8789d4" ;;
    *) echo "" ;;
  esac
}

# ─── layout ─────────────────────────────────────────────────────────────────
#
# One tree. Nothing in ~/.local — that directory belongs to the person, and a
# tool that scatters into it cannot tell its own files from theirs at removal.
AGANITHA_HOME="${AGANITHA_HOME:-$HOME/.aganitha}"
RIG_HOME="$AGANITHA_HOME/rig"
COMMANDS_HOME="$AGANITHA_HOME/commands"
MANIFEST="$RIG_HOME/manifest"
ENV_FILE="$RIG_HOME/env.sh"
BIN_DIR="$RIG_HOME/bin"

COMMANDS_REPO="${RIG_COMMANDS_REPO:-aganitha/commands}"

# Resolved during the run, then written into env.sh. Never assumed: a tool's
# install directory varies by version and by what was already on the machine,
# and a path guessed here becomes a PATH entry that points at nothing.
BUN_BIN=""
BUN_GLOBAL_BIN=""
UV_BIN=""
NODE_BIN=""

# ─── output ─────────────────────────────────────────────────────────────────
#
# The same four marks igniva uses, so a person who has read one of our tools has
# read all of them. Progress goes to stderr and results to stdout, so a pipe and
# a redirect both behave.
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OFF=$(printf '\033[0m');    C_DIM=$(printf '\033[2m')
  C_GREEN=$(printf '\033[32m'); C_RED=$(printf '\033[31m')
  C_YELLOW=$(printf '\033[33m'); C_BLUE=$(printf '\033[36m')
else
  C_OFF=""; C_DIM=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_BLUE=""
fi

group()  { printf '\n  %s==> %s%s\n' "$C_BLUE" "$*" "$C_OFF" >&2; }
ok()     { printf '  %s✓%s  %-12s %s\n' "$C_GREEN" "$C_OFF" "$1" "${2-}" >&2; }
note()   { printf '  %s!%s  %-12s %s\n' "$C_YELLOW" "$C_OFF" "$1" "${2-}" >&2; }
skip()   { printf '  %s·%s  %-12s %s\n' "$C_DIM" "$C_OFF" "$1" "${2-}" >&2; }
bad()    { printf '  %s✗%s  %-12s %s\n' "$C_RED" "$C_OFF" "$1" "${2-}" >&2; }
say()    { printf '  %s\n' "$*" >&2; }
hint()   { printf '     %s%s%s\n' "$C_DIM" "$*" "$C_OFF" >&2; }

# Stop, and say what to do. Exit 2 means "this request is not possible here";
# exit 1 means "a step failed". Every caller passes the fix, because a refusal
# without a way out is a defect.
die() {
  local code line
  code="$1"; shift
  printf '\n' >&2
  bad "${1:-rig}" "${2:-}"
  shift 2 2>/dev/null || true
  for line in "$@"; do hint "$line"; done
  printf '\n' >&2
  exit "$code"
}

# ─── the terminal ───────────────────────────────────────────────────────────
#
# `curl … | sh` puts a pipe on stdin. Without this, every prompt from here to the
# end — Apple's password, GitHub's browser sign-in — reads from that pipe, gets
# nothing, and the run fails in a way that looks like the tool is broken.
INTERACTIVE=0
ASSUME_YES=0

connect_terminal() {
  # /dev/tty can exist and still refuse to open — a detached session, a container
  # with no controlling terminal. Probe in a subshell, where the failure can be
  # silenced, and only then take it for real.
  if [ ! -t 0 ] && ( : < /dev/tty ) 2>/dev/null; then
    exec < /dev/tty
  fi
  if [ -t 0 ] && [ -t 2 ] && [ "$ASSUME_YES" -eq 0 ]; then
    INTERACTIVE=1
  fi
}

# Ask, and default to yes. Non-interactive runs take the standard answer without
# waiting — a machine with no terminal must never block on input that cannot come.
confirm() {
  local answer
  if [ "$INTERACTIVE" -eq 0 ]; then return 0; fi
  printf '  %s?%s  %s [Y/n] ' "$C_BLUE" "$C_OFF" "$1" >&2
  read -r answer || answer=""
  case "$answer" in ""|y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ─── the manifest ───────────────────────────────────────────────────────────
#
# It records only what rig installed, and only things that can be removed. There
# is no "already here" line and no state column: absent means not ours, so the
# removal rule is one sentence and cannot be misread.
#
# Apple's Command Line Tools are deliberately never recorded. They are
# system-wide, they serve every account on the machine, and removing them needs
# an administrator. rig will not undo something it had to borrow a password for.
record() {
  local name version where tmp existing
  name="$1"; version="${2:--}"; where="${3:--}"
  mkdir -p "$RIG_HOME"
  [ -f "$MANIFEST" ] || printf 'schema\t1\n' > "$MANIFEST"

  # An unchanged entry is left exactly as it is, timestamp included. The time in
  # this file answers "when did rig install this", and rewriting it on every run
  # would turn it into "when did rig last run" — a different and less useful
  # fact. It also makes the whole file byte-stable, which is what lets a test
  # prove that a second run changed nothing.
  existing=$(awk -F'\t' -v n="$name" '$1 == n {print $2 "\t" $3}' "$MANIFEST")
  [ "$existing" = "$(printf '%s\t%s' "$version" "$where")" ] && return 0

  tmp="$MANIFEST.new"
  awk -F'\t' -v n="$name" '$1 != n' "$MANIFEST" > "$tmp"
  printf '%s\t%s\t%s\t%s\n' "$name" "$version" "$where" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$tmp"
  mv "$tmp" "$MANIFEST"
}

# ─── safe primitives ────────────────────────────────────────────────────────
#
# Two rules hold everywhere below. Every file is written beside its target and
# renamed into place, because rename is the one atomic filesystem operation — an
# interrupted run must never leave a truncated .zshrc. Every download lands in a
# trapped temporary directory and moves in last, so an interrupted fetch never
# leaves something that later looks installed.

# A scratch directory for this run, removed however the script exits.
#
# This sets $WORK rather than printing it. Command substitution runs a subshell,
# so a `$(work_dir)` would assign the variable and register the trap inside that
# subshell — the directory would be deleted the moment the substitution returned.
WORK=""
work_dir() {
  [ -n "$WORK" ] && return 0
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/rig.XXXXXX")
  trap 'rm -rf "$WORK"' EXIT INT TERM HUP
}

# Fetch a URL, and tell the three failures apart. A certificate error on a
# corporate network reads exactly like an outage unless something says so.
fetch() {
  local url dest err reason
  url="$1"; dest="$2"
  work_dir; err="$WORK/curl.err"
  if curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --connect-timeout 20 \
       "$url" -o "$dest" 2>"$err"; then
    return 0
  fi
  reason=$(cat "$err" 2>/dev/null || true)
  [ -n "$reason" ] || reason="curl gave no reason"
  case "$reason" in
    *certificate*|*SSL*|*TLS*)
      die 1 "network" "the certificate for this download was not accepted" \
        "A proxy on this network is inspecting TLS." \
        "Ask whoever runs it for the certificate, then run this line again." ;;
    *"Could not resolve"*|*"Resolving timed out"*)
      die 1 "network" "could not resolve the download host" \
        "Check your connection. If you are on a VPN, it may be filtering DNS." ;;
    *)
      die 1 "network" "could not download $url" "$reason" ;;
  esac
}

# Verify a file against a known SHA-256. A mismatch is never retried and never
# tolerated: it means the bytes are not the bytes we pinned.
verify_sha256() {
  local file want got
  file="$1"; want="$2"
  [ -n "$want" ] || return 0
  if command -v shasum >/dev/null 2>&1; then
    got=$(shasum -a 256 "$file" | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum "$file" | awk '{print $1}')
  else
    note "checksum" "no shasum or sha256sum on this machine — cannot verify"
    return 0
  fi
  [ "$got" = "$want" ] && return 0
  die 1 "checksum" "$(basename "$file") does not match the pinned checksum" \
    "expected $want" "got      $got" \
    "Do not run this file. Report it."
}

# Rewrite the region between two markers, or append it when absent. The file is
# rebuilt beside itself and renamed, so a person's own lines above and below the
# block survive every rerun and an interruption cannot truncate the file.
write_block() {
  local file begin end body tmp
  file="$1"; begin="$2"; end="$3"; body="$4"
  [ -f "$file" ] || : > "$file"
  tmp="$file.rig.new"
  awk -v b="$begin" -v e="$end" '
    $0 == b { skip = 1 } skip != 1 { print } $0 == e { skip = 0 }
  ' "$file" > "$tmp"
  { printf '%s\n' "$begin"; printf '%s\n' "$body"; printf '%s\n' "$end"; } >> "$tmp"

  # Identical content is left alone, so a rerun does not touch the modification
  # time of a file the person also edits. Returns 1 when nothing changed, so the
  # caller can say so rather than claim work it did not do.
  if cmp -s "$tmp" "$file"; then rm -f "$tmp"; return 1; fi
  mv "$tmp" "$file"
  return 0
}

# Is a real, working tool here? On macOS `command -v` is not an answer:
# /usr/bin/git and /usr/bin/python3 are the same binary, hardlinked 78 times,
# which resolves the developer directory at exec and opens Apple's installer when
# there is none. So the tool is run, never merely located.
works() { command -v "$1" >/dev/null 2>&1 && "$@" >/dev/null 2>&1; }

# ─── the platform ───────────────────────────────────────────────────────────
OS=""; ARCH=""

detect_platform() {
  case "$(uname -s)" in
    Darwin) OS=macos ;;
    Linux)  OS=linux ;;
    *)      die 2 "platform" "rig supports macOS, Linux and WSL. This is $(uname -s)." \
              "On Windows, run this inside WSL." ;;
  esac

  ARCH=$(uname -m)
  case "$ARCH" in
    arm64|aarch64) ARCH=arm64 ;;
    x86_64|amd64)  ARCH=x64 ;;
    *) die 2 "platform" "rig has no build for $ARCH." \
         "Supported: arm64 and x86-64." ;;
  esac

  # Under Rosetta an Apple Silicon Mac reports x86_64. A toolchain installed for
  # that answer runs emulated for years with nothing to say it is wrong.
  if [ "$OS" = macos ] && [ "$ARCH" = x64 ]; then
    if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
      ARCH=arm64
    fi
  fi
}

require_base_tools() {
  local missing tool
  missing=""
  for tool in curl tar unzip; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  [ -z "$missing" ] && return 0
  if [ "$OS" = linux ]; then
    die 2 "prerequisites" "this machine is missing:$missing" \
      "Install them, then run this line again:" \
      "  sudo apt-get update && sudo apt-get install -y$missing" \
      "In an image, add them to the Dockerfile."
  fi
  die 2 "prerequisites" "this machine is missing:$missing" \
    "These are part of macOS. A machine without them is not one rig can repair."
}

# ─── git, and Apple's Command Line Tools ────────────────────────────────────
#
# This is a hard gate, and it is the only place rig asks for a password.
#
# `git` is not optional. Without it the private command repo cannot be updated,
# skills cannot be fetched over git, and a pack that clones fails much later and
# far from the cause — reading like a broken tool rather than a missing one. An
# honest stop with one command beats a machine that half works.
#
# The account does NOT have to be an administrator. `sudo` on macOS authenticates
# against any account in the admin group, so a person without admin rights can
# hand the keyboard to somebody who has them for ten seconds. Checking group
# membership first, and refusing on that basis, only sends them away.

CLT_MARKER="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
CLT_MARKER_MINE=0

clt_present() {
  local dir
  dir=$(/usr/bin/xcode-select -p 2>/dev/null) || return 1
  [ -d "$dir" ] || return 1
  # Run the tools. The stub in /usr/bin exists whether or not they are installed.
  /usr/bin/git --version >/dev/null 2>&1 || return 1
  /usr/bin/make --version >/dev/null 2>&1 || return 1
  return 0
}

# softwareupdate does not list the Command Line Tools unless this marker exists.
# Listing needs no privilege, so it is safe even when we already know the install
# will need somebody else's password.
clt_label() {
  if [ ! -f "$CLT_MARKER" ]; then
    touch "$CLT_MARKER" 2>/dev/null || return 1
    CLT_MARKER_MINE=1
  fi
  # Newer macOS prints "Label: …"; older releases print "* …". Take the last
  # match, because Software Update lists these in ascending version order.
  /usr/sbin/softwareupdate -l 2>&1 | /usr/bin/awk -F': ' '
    /Label: Command Line Tools/ { label = $2 }
    /^[[:space:]]*\*/ && /Command Line Tools/ {
      line = $0
      sub(/^[[:space:]]*\*[[:space:]]*/, "", line)
      sub(/^Label:[[:space:]]*/, "", line)
      label = line
    }
    END { if (label != "") print label }
  '
}

clt_cleanup() {
  [ "$CLT_MARKER_MINE" = 1 ] && rm -f "$CLT_MARKER" 2>/dev/null || true
}

ensure_clt() {
  local label
  if clt_present; then
    ok "git" "$(/usr/bin/git --version 2>/dev/null | awk '{print $3}')"
    return 0
  fi

  if [ "$CLT_CONSENT" != yes ]; then
    die 2 "git" "Apple's Command Line Tools are not installed" \
      "They provide git, which rig and every pack need." \
      "" \
      "Someone with an administrator password can install them:" \
      "  xcode-select --install" \
      "" \
      "Then run this line again."
  fi

  say "Installing Apple's Command Line Tools. This takes a few minutes."
  label=$(clt_label 2>/dev/null || true)

  if [ -n "$label" ]; then
    # Synchronous, and it prints progress. Preferred over the dialog for exactly
    # that reason: a person can see it working.
    /usr/bin/sudo /usr/sbin/softwareupdate --install "$label" \
      --agree-to-license --verbose 2>&1 | sed 's/^/     /' >&2 || true
  fi
  clt_cleanup

  if clt_present; then
    ok "git" "$(/usr/bin/git --version 2>/dev/null | awk '{print $3}') installed"
    return 0
  fi

  # The Software Update route did not finish. Apple's dialog is the fallback, but
  # `xcode-select --install` returns immediately while the GUI installs in the
  # background — so this must stop rather than continue into a machine with no git.
  note "git" "the Software Update install did not complete"
  /usr/bin/xcode-select --install >/dev/null 2>&1 || true
  die 2 "git" "Apple's installer has been opened" \
    "Finish it, then run this line again." \
    "On a managed Mac, IT may have to approve it first."
}

ensure_git_linux() {
  if works git --version; then
    ok "git" "$(git --version 2>/dev/null | awk '{print $3}')"
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    say "Installing git."
    sudo apt-get update -qq >/dev/null 2>&1 || true
    sudo apt-get install -y -qq git >/dev/null 2>&1 || true
    if works git --version; then
      ok "git" "$(git --version | awk '{print $3}') installed"
      return 0
    fi
  fi
  die 2 "git" "git is not installed, and rig cannot install it here" \
    "Install it, then run this line again:" \
    "  sudo apt-get install -y git"
}

ensure_git() {
  if [ "$OS" = macos ]; then ensure_clt; else ensure_git_linux; fi
}

# ─── gh, and GitHub sign-in ─────────────────────────────────────────────────
#
# Downloaded as a plain binary, so it needs no package manager. That matters more
# than it looks: on macOS, Homebrew needs the Command Line Tools, which is the
# same gate git needs — installing brew to avoid needing git needs what git needs.

gh_path() { printf '%s' "$BIN_DIR/gh"; }

gh_works() {
  if [ -x "$(gh_path)" ]; then GH="$(gh_path)"; return 0; fi
  if command -v gh >/dev/null 2>&1; then GH=$(command -v gh); return 0; fi
  return 1
}

ensure_gh() {
  local asset tmp found
  if gh_works; then
    ok "gh" "$("$GH" --version 2>/dev/null | head -1 | awk '{print $3}')"
    return 0
  fi

  case "$OS" in
    macos) asset="gh_${GH_VERSION}_macOS_$( [ "$ARCH" = arm64 ] && echo arm64 || echo amd64 ).zip" ;;
    linux) asset="gh_${GH_VERSION}_linux_$( [ "$ARCH" = arm64 ] && echo arm64 || echo amd64 ).tar.gz" ;;
  esac

  work_dir; tmp="$WORK"
  fetch "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${asset}" "$tmp/$asset"
  verify_sha256 "$tmp/$asset" "$(checksum_for "gh:$OS:$ARCH")"

  mkdir -p "$tmp/gh" "$BIN_DIR"
  case "$asset" in
    *.zip) unzip -q "$tmp/$asset" -d "$tmp/gh" ;;
    *)     tar -xzf "$tmp/$asset" -C "$tmp/gh" ;;
  esac
  found=$(find "$tmp/gh" -type f -name gh -perm -u+x 2>/dev/null | head -1)
  [ -n "$found" ] || die 1 "gh" "the gh archive did not contain a gh binary"

  # Move in last, so an interrupted unpack never leaves a partial gh that later
  # looks installed.
  mv "$found" "$BIN_DIR/gh.partial"
  chmod +x "$BIN_DIR/gh.partial"
  mv "$BIN_DIR/gh.partial" "$BIN_DIR/gh"

  gh_works || die 1 "gh" "gh was installed but will not run"
  record gh "$GH_VERSION" "$BIN_DIR/gh"
  ok "gh" "$GH_VERSION installed"
}

gh_authenticated() { "$GH" auth status >/dev/null 2>&1; }

ensure_gh_auth() {
  local who
  if gh_authenticated; then
    who=$("$GH" api user --jq .login 2>/dev/null || echo "")
    ok "github" "signed in${who:+ as $who}"
    return 0
  fi

  if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
    gh_authenticated && { ok "github" "signed in with a token"; return 0; }
  fi

  if [ "$INTERACTIVE" -eq 0 ]; then
    die 1 "github" "this machine is not signed in to GitHub, and nothing can ask" \
      "Set GH_TOKEN, or run 'gh auth login' from a terminal first."
  fi

  # Interactive on purpose. gh asks its own questions and opens a browser; its
  # output has to reach the person, so rig hands the terminal over and stops talking.
  printf '\n' >&2
  "$GH" auth login --hostname github.com --git-protocol https --web || true
  printf '\n' >&2

  gh_authenticated || die 1 "github" "the GitHub sign-in did not complete" \
    "Run 'gh auth login' by hand, then run this line again."
  who=$("$GH" api user --jq .login 2>/dev/null || echo "")
  ok "github" "signed in${who:+ as $who}"
}

# ─── the command repo ───────────────────────────────────────────────────────
#
# Fetched before the toolchain, on purpose. This is the gate most likely to
# refuse, and finding out in fifteen seconds is better than finding out after a
# three minute install. It costs one clone of a small repository.

fetch_atk() {
  local err who
  if [ -x "$COMMANDS_HOME/bin/atk" ]; then
    ok "atk" "already here"
    # A pull keeps a rerun from using a months-old atk. Never fatal: a machine
    # offline, or one with local edits, still has a working atk on disk.
    if [ -d "$COMMANDS_HOME/.git" ]; then
      # --ff-only, never a plain pull: a plain pull may attempt an auto-merge,
      # which can open an editor. This runs where there may be no editor at all.
      git -C "$COMMANDS_HOME" pull --quiet --ff-only 2>/dev/null \
        || note "atk" "could not update — using the version on disk"
    fi
    return 0
  fi

  mkdir -p "$AGANITHA_HOME"
  work_dir; err="$WORK/clone.err"
  if "$GH" repo clone "$COMMANDS_REPO" "$COMMANDS_HOME.partial" -- --quiet 2>"$err"; then
    mv "$COMMANDS_HOME.partial" "$COMMANDS_HOME"
    record commands "-" "$COMMANDS_HOME"
    ok "atk" "$COMMANDS_REPO"
    return 0
  fi
  rm -rf "$COMMANDS_HOME.partial"

  # A bare 404 here is baffling, and it has two very different causes. Naming the
  # account that was refused is what turns it into something a person can act on.
  who=$("$GH" api user --jq .login 2>/dev/null || echo "this account")
  case "$(cat "$err" 2>/dev/null)" in
    *404*|*"Could not resolve to a Repository"*|*"not found"*)
      die 1 "atk" "$COMMANDS_REPO is not visible to $who" \
        "Either that GitHub account is not in the organisation," \
        "or it is the wrong account." \
        "" \
        "  wrong account   gh auth switch" \
        "  not a member    ask in #it, then run this line again" ;;
    *)
      die 1 "atk" "could not fetch $COMMANDS_REPO" "$(head -3 "$err" 2>/dev/null)" ;;
  esac
}

# ─── the toolchain ──────────────────────────────────────────────────────────
#
# Everything installs into the rig tree with no administrator password. Each
# installer is given its own directory variable and told not to touch shell
# files — one managed block is the point, and three installers each appending
# their own is how PATH order becomes an accident nobody can debug.
#
# After every install the binary is located rather than assumed. A tool's layout
# varies by version, and a guessed path becomes a PATH entry pointing at nothing.

ensure_bun() {
  if [ -x "$RIG_HOME/bun/bin/bun" ]; then
    BUN_BIN="$RIG_HOME/bun/bin"
  elif command -v bun >/dev/null 2>&1; then
    # Somebody's own bun. Used, and deliberately not recorded, so removal leaves it.
    BUN_BIN=$(dirname "$(command -v bun)")
    ok "bun" "$(bun --version) (already on this machine)"
    resolve_bun_global
    return 0
  fi

  if [ -z "$BUN_BIN" ]; then
    say "Installing bun."
    BUN_INSTALL="$RIG_HOME/bun" SHELL=/bin/false \
      sh -c "curl -fsSL https://bun.sh/install | bash -s 'bun-v$BUN_VERSION'" \
      >/dev/null 2>&1 || true
    [ -x "$RIG_HOME/bun/bin/bun" ] || die 1 "bun" "bun did not install" \
      "Run this to see why:" "  curl -fsSL https://bun.sh/install | bash"
    BUN_BIN="$RIG_HOME/bun/bin"
    record bun "$BUN_VERSION" "$RIG_HOME/bun"
  fi

  PATH="$BUN_BIN:$PATH"; export PATH
  ok "bun" "$(bun --version)  installed"
  resolve_bun_global
}

# Where bun puts globally installed commands. Asked, never assumed: the answer
# differs between versions, so a hardcoded path is one bun stops using — and the
# install still succeeds while everything that looks for the command fails.
resolve_bun_global() {
  BUN_GLOBAL_BIN=$(bun pm bin -g 2>/dev/null || true)
  [ -n "$BUN_GLOBAL_BIN" ] || BUN_GLOBAL_BIN="$RIG_HOME/bun/bin"
}

ensure_uv() {
  local found
  if [ -x "$RIG_HOME/uv/uv" ]; then
    UV_BIN="$RIG_HOME/uv"
  elif command -v uv >/dev/null 2>&1; then
    UV_BIN=$(dirname "$(command -v uv)")
    ok "uv" "$(uv --version | awk '{print $2}') (already on this machine)"
    return 0
  fi

  if [ -z "$UV_BIN" ]; then
    say "Installing uv."
    UV_INSTALL_DIR="$RIG_HOME/uv" UV_NO_MODIFY_PATH=1 \
      sh -c "curl -LsSf https://astral.sh/uv/$UV_VERSION/install.sh | sh" \
      >/dev/null 2>&1 || true
    # The installer's layout has moved between releases, so find the binary.
    found=$(find "$RIG_HOME/uv" -maxdepth 2 -type f -name uv -perm -u+x 2>/dev/null | head -1)
    [ -n "$found" ] || die 1 "uv" "uv did not install" \
      "Run this to see why:" "  curl -LsSf https://astral.sh/uv/install.sh | sh"
    UV_BIN=$(dirname "$found")
    record uv "$UV_VERSION" "$RIG_HOME/uv"
  fi

  PATH="$UV_BIN:$PATH"; export PATH
  ok "uv" "$(uv --version 2>/dev/null | awk '{print $2}')  installed"
}

ensure_python() {
  UV_PYTHON_INSTALL_DIR="$RIG_HOME/python"; export UV_PYTHON_INSTALL_DIR
  # The check is "the version we require", not "a python exists". A stray python3
  # dragged in as somebody else's dependency is not the interpreter we pinned.
  if uv python find "$PYTHON_VERSION" >/dev/null 2>&1; then
    ok "python" "$PYTHON_VERSION"
    return 0
  fi
  say "Installing Python $PYTHON_VERSION."
  uv python install "$PYTHON_VERSION" >/dev/null 2>&1 || true
  uv python find "$PYTHON_VERSION" >/dev/null 2>&1 \
    || die 1 "python" "Python $PYTHON_VERSION did not install" \
         "Run this to see why:" "  uv python install $PYTHON_VERSION"
  record python "$PYTHON_VERSION" "$RIG_HOME/python"
  ok "python" "$PYTHON_VERSION installed"
}

# Node is here for one reason: tools published to npm carry a
# `#!/usr/bin/env node` shebang and will not run without it. bun installs them
# and cannot replace the interpreter they ask for.
#
# It is a pinned tarball, not nvm. nvm's own PATH handling substitutes in place
# rather than prepending, so a foreign node ahead of it stays ahead even after
# `nvm use` succeeds; its `default` alias resolves to the newest node *installed*,
# so an old one satisfies it forever; and a global npm package belongs to the node
# it was installed under, so an upgrade strands it. One pinned directory has none
# of those failure modes. See docs/why-not.md.
ensure_node() {
  local target plat asset tmp
  target="$RIG_HOME/node"
  if [ -x "$target/bin/node" ]; then
    NODE_BIN="$target/bin"
    PATH="$NODE_BIN:$PATH"; export PATH
    ok "node" "$(node --version 2>/dev/null)"
    return 0
  fi
  if command -v node >/dev/null 2>&1; then
    NODE_BIN=$(dirname "$(command -v node)")
    ok "node" "$(node --version) (already on this machine)"
    return 0
  fi

  case "$OS" in
    macos) plat="darwin-$ARCH" ;;
    linux) plat="linux-$ARCH" ;;
  esac
  asset="node-v${NODE_VERSION}-${plat}.tar.gz"

  say "Installing node ${NODE_VERSION}."
  work_dir; tmp="$WORK"
  fetch "https://nodejs.org/dist/v${NODE_VERSION}/${asset}" "$tmp/$asset"
  verify_sha256 "$tmp/$asset" "$(checksum_for "node:$OS:$ARCH")"

  mkdir -p "$tmp/node"
  tar -xzf "$tmp/$asset" -C "$tmp/node" --strip-components 1
  [ -x "$tmp/node/bin/node" ] || die 1 "node" "the node archive did not contain a node binary"
  rm -rf "$target.partial"
  mv "$tmp/node" "$target.partial"
  mv "$target.partial" "$target"

  NODE_BIN="$target/bin"
  PATH="$NODE_BIN:$PATH"; export PATH
  node --version >/dev/null 2>&1 || die 1 "node" "node was installed but will not run"
  record node "$NODE_VERSION" "$target"
  ok "node" "v${NODE_VERSION} installed"
}

# ─── the one PATH truth ─────────────────────────────────────────────────────
#
# env.sh is generated from what this run actually resolved, never from constants.
# It is read on every shell start, so it runs no subprocess and holds only
# literal paths — a `bun pm bin -g` here would cost a process on every prompt.
#
# The last line is why atk needs no shell block of its own. One block, one file,
# one place where PATH is decided.

write_env() {
  local tmp seen dir changed
  mkdir -p "$RIG_HOME"
  tmp="$ENV_FILE.new"
  {
    printf '# Generated by rig %s. Do not edit — rerun rig instead.\n' "$RIG_VERSION"
    printf 'export AGANITHA_HOME="%s"\n' "$AGANITHA_HOME"
    printf 'export RIG_HOME="%s"\n' "$RIG_HOME"
    [ -d "$RIG_HOME/bun" ]    && printf 'export BUN_INSTALL="%s"\n' "$RIG_HOME/bun"
    [ -d "$RIG_HOME/python" ] && printf 'export UV_PYTHON_INSTALL_DIR="%s"\n' "$RIG_HOME/python"

    # Deduplicated in order, so a repeated entry never piles up and the first
    # match wins predictably.
    seen=""
    for dir in "$BIN_DIR" "$NODE_BIN" "$BUN_GLOBAL_BIN" "$BUN_BIN" "$UV_BIN"; do
      [ -n "$dir" ] || continue
      case ":$seen:" in *":$dir:"*) continue ;; esac
      seen="$seen:$dir"
      printf 'PATH="%s${PATH:+:$PATH}"\n' "$dir"
    done

    # An `if`, not `&&`: a trailing false `&&` makes this file return non-zero,
    # which exits any shell whose rc runs under `set -e`.
    printf 'if [ -d "$AGANITHA_HOME/commands/bin" ]; then\n'
    printf '  PATH="$AGANITHA_HOME/commands/bin:$PATH"\n'
    printf 'fi\n'
    printf 'export PATH\n'
  } > "$tmp"

  if cmp -s "$tmp" "$ENV_FILE"; then
    rm -f "$tmp"; changed=no
  else
    mv "$tmp" "$ENV_FILE"; changed=yes
  fi
  record env "-" "$ENV_FILE"
  if [ "$changed" = yes ]; then ok "env" "written"; else ok "env" "current"; fi
}

# Which file a new shell reads. On macOS a bash login shell reads .bash_profile
# and never .bashrc, which is why a block written only to .bashrc appears to do
# nothing there. So .bashrc holds the block, and .bash_profile is made to source
# it — the standard arrangement, applied once rather than left to the person.
shell_rc() {
  case "${SHELL:-}" in
    */zsh)  printf '%s' "$HOME/.zshrc" ;;
    */bash) printf '%s' "$HOME/.bashrc" ;;
    */fish) printf '%s' "" ;;
    *)      if [ -f "$HOME/.zshrc" ]; then printf '%s' "$HOME/.zshrc"
            else printf '%s' "$HOME/.profile"; fi ;;
  esac
}

BLOCK_BEGIN="# BEGIN aganitha"
BLOCK_END="# END aganitha"

write_shell() {
  local rc changed
  rc=$(shell_rc)
  if [ -z "$rc" ]; then
    note "shell" "fish is not supported — add this to config.fish by hand"
    hint "  bass source $ENV_FILE"
    return 0
  fi

  changed=no
  write_block "$rc" "$BLOCK_BEGIN" "$BLOCK_END" ". \"$ENV_FILE\"" && changed=yes
  record shell "-" "$rc"

  # On macOS a bash login shell reads .bash_profile and never .bashrc, so a block
  # written only to .bashrc appears to do nothing there. Make .bash_profile read
  # .bashrc, which is the arrangement everything else already assumes.
  case "$rc" in
    */.bashrc)
      if [ ! -f "$HOME/.bash_profile" ] || ! grep -q 'bashrc' "$HOME/.bash_profile" 2>/dev/null; then
        write_block "$HOME/.bash_profile" "$BLOCK_BEGIN" "$BLOCK_END" \
          '[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"' && changed=yes
        record shell-profile "-" "$HOME/.bash_profile"
      fi ;;
  esac

  if [ "$changed" = yes ]; then ok "shell" "$(basename "$rc")  written"
  else ok "shell" "$(basename "$rc")"; fi
}

# ─── the run ────────────────────────────────────────────────────────────────

PACK=""
CLT_CONSENT=no
GH="gh"

usage() {
  cat >&2 <<USAGE

  rig $RIG_VERSION — take a machine from nothing to ready.

    curl -fsSL <host>/rig.sh | sh                  the toolchain only
    curl -fsSL <host>/rig.sh | sh -s -- <pack>     the toolchain, then a pack

  Options
    --yes         take the standard answer to every question
    --version     print the version and stop
    --help        this

  It is safe to run again. Every stage asks whether it is already true before it
  acts, so a second run does nothing and an interrupted run is finished by
  running the same line again.

USAGE
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y)   ASSUME_YES=1; shift ;;
      --version)  printf 'rig %s\n' "$RIG_VERSION"; exit 0 ;;
      --help|-h)  usage; exit 0 ;;
      -*)         die 2 "rig" "unknown option: $1" "Run with --help." ;;
      *)
        [ -z "$PACK" ] || die 2 "rig" "rig installs one pack at a time" \
          "Given: $PACK and $1"
        PACK="$1"; shift ;;
    esac
  done
}

# Every question this run will ask, asked before anything is changed. A person
# answers, walks away, and comes back to a finished machine. Nothing below this
# point waits for input except the sign-in a browser has to complete.
ask_everything() {
  local needs_clt needs_signin
  needs_clt=no
  needs_signin=no

  if [ "$OS" = macos ] && ! clt_present; then needs_clt=yes; fi
  if [ -n "$PACK" ]; then
    if gh_works && "$GH" auth status >/dev/null 2>&1; then :; else needs_signin=yes; fi
  fi

  if [ "$needs_clt" = no ] && [ "$needs_signin" = no ]; then
    return 0
  fi

  printf '\n' >&2
  if [ "$needs_signin" = yes ] && [ "$needs_clt" = yes ]; then
    say "Two questions, then this runs on its own."
  else
    say "One question, then this runs on its own."
  fi
  printf '\n' >&2

  if [ "$needs_clt" = yes ]; then
    say "Apple's Command Line Tools are not installed. They provide git."
    say "Installing them needs an administrator password. If you are not an"
    say "administrator, somebody who is can type it now."
    if confirm "Install them? (a few minutes)"; then CLT_CONSENT=yes; fi
    printf '\n' >&2
  fi

  if [ "$needs_signin" = yes ]; then
    say "This machine is not signed in to GitHub. Signing in is how rig proves"
    say "you may fetch the private tools, and it opens a browser."
    confirm "Sign in to GitHub?" || die 2 "github" "a GitHub sign-in is needed to install a pack" \
      "Run without a pack name for the toolchain only:" \
      "  curl -fsSL <host>/rig.sh | sh"
    printf '\n' >&2
  fi
}

handover() {
  printf '\n' >&2
  say "───────────────────────────────────────────────────────────"
  printf '\n' >&2
  # exec, not call: atk owns the rest of the run and its exit code is the answer.
  # The absolute path is used because the shell block has not taken effect in
  # this process — it is read by the *next* shell, not this one.
  ATK_FROM_RIG=1; export ATK_FROM_RIG
  exec "$COMMANDS_HOME/bin/atk" install "$PACK"
}

finish_base() {
  local rc
  rc=$(shell_rc)
  printf '\n' >&2
  say "Done."
  printf '\n' >&2
  say "Open a new terminal, or read the new settings into this one:"
  hint ". $ENV_FILE"
  printf '\n' >&2
  if [ -z "$PACK" ]; then
    say "To install a pack, run this line again with its name:"
    hint "curl -fsSL <host>/rig.sh | sh -s -- <pack>"
    printf '\n' >&2
  fi
}

main() {
  parse_args "$@"
  connect_terminal
  detect_platform
  require_base_tools

  printf '\n  %srig %s%s  ·  %s %s%s\n' \
    "$C_BLUE" "$RIG_VERSION" "$C_OFF" "$OS" "$ARCH" \
    "$( [ -n "$PACK" ] && printf '  ·  pack: %s' "$PACK" )" >&2

  ask_everything

  # The gates first, and the long work after. A person who is not in the
  # organisation finds out in fifteen seconds rather than after a three minute
  # install that was never going to be useful to them.
  group "Access"
  ensure_git
  ensure_gh
  if [ -n "$PACK" ]; then
    ensure_gh_auth
    fetch_atk
  fi

  group "Toolchain"
  ensure_bun
  ensure_uv
  ensure_python
  ensure_node

  group "Shell"
  write_env
  write_shell

  [ -n "$PACK" ] && handover
  finish_base
}

# Sourced by the tests, so every function above can be exercised without running
# an install. Nothing else may live below this line.
[ -n "${RIG_SOURCED:-}" ] || main "$@"
