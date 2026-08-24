#!/usr/bin/env sh
# rig — put this tool on a machine that has nothing.
#
#   curl -fsSL https://<host>/install.sh | sh
#   curl -fsSL https://<host>/install.sh | sh -s -- https://identity.example.com
#
# It does three things and stops: read the platform, install Bun, fetch rig. It never
# learns about registries, products, deployments or credentials. Those belong to `rig`,
# which is real code with real tests.
#
# It is POSIX sh on purpose. macOS ships bash 3.2 from 2007, Debian's /bin/sh is dash, and
# a script fetched with curl cannot be tested well or upgraded once it has run. So it stays
# small enough to read in one sitting, and it holds no logic worth testing.
#
# It needs `curl` and `unzip`, which are base macOS and present in most Linux images.
# Bun's own installer needs `unzip` too.
set -eu

RIG_VERSION="${RIG_VERSION:-0.1.0}"
RIG_REPO="${RIG_REPO:-jdhruv-acog/rig}"
RIG_HOME="${RIG_HOME:-$HOME/.local/share/rig}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
DEPLOYMENT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --version) RIG_VERSION="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "install.sh: unknown option '$1'" >&2; exit 2 ;;
    # A bare argument is the deployment to set this machine up for. Handing it over
    # here makes the whole thing one command for somebody who was given one address.
    *) DEPLOYMENT="$1"; shift ;;
  esac
done

say()  { printf '  %s\n' "$*" >&2; }
fail() { printf '\n  %s\n' "$*" >&2; exit 1; }

# --- 1. what is this machine ------------------------------------------------

os=$(uname -s)
case "$os" in
  Darwin) os=macos ;;
  Linux)  os=linux ;;
  *) fail "rig supports macOS and Linux. This is $os.
     On Windows, run this inside WSL." ;;
esac

# On Apple Silicon a shell under Rosetta answers x86_64, and a tool installed for that
# answer runs emulated with nothing to say it is wrong.
arch=$(uname -m)
if [ "$os" = macos ] && [ "$arch" = x86_64 ]; then
  if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
    arch=arm64
  fi
fi

for tool in curl unzip tar; do
  command -v "$tool" >/dev/null 2>&1 || fail "rig needs '$tool', and it is not on this machine.
     On Debian or Ubuntu:  apt-get install -y $tool
     In an image, add it to the Dockerfile."
done

printf '\n  rig %s  ·  %s %s\n\n' "$RIG_VERSION" "$os" "$arch" >&2

# --- 2. bun, the runtime rig itself needs -----------------------------------

# Bun installs into a user directory and needs no administrator password. Its own
# installer edits a shell file; we suppress that, because one managed block is the point
# and three installers each appending their own is how PATH order becomes an accident.
if command -v bun >/dev/null 2>&1; then
  # Use the bun that is actually here. Assuming $HOME/.bun writes a shim pointing at a
  # path that does not exist for anybody whose bun came from brew, mise, or a custom
  # BUN_INSTALL — and the failure lands later, on first use, far from this line.
  bun_bin=$(command -v bun)
  say "bun          $(bun --version) — already here"
else
  say "bun          installing to \$HOME/.bun"
  BUN_INSTALL="$HOME/.bun" SHELL=/bin/false \
    sh -c 'curl -fsSL https://bun.sh/install | bash' >/dev/null 2>&1 \
    || fail "bun did not install. Run this to see why:
     curl -fsSL https://bun.sh/install | bash"
  bun_bin="$HOME/.bun/bin/bun"
  [ -x "$bun_bin" ] || fail "bun installed, but $bun_bin is not there."
fi
PATH="$(dirname "$bun_bin"):$BIN_DIR:$PATH"
export PATH

# --- 3. rig -----------------------------------------------------------------

# A tarball over plain HTTPS. No git — on macOS git means Xcode Command Line Tools, and
# those need an administrator password that a managed laptop does not have.
target="$RIG_HOME/$RIG_VERSION"
if [ ! -d "$target" ]; then
  say "rig          fetching $RIG_VERSION"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT INT TERM
  url="https://codeload.github.com/$RIG_REPO/tar.gz/refs/tags/v$RIG_VERSION"
  curl -fsSL "$url" -o "$tmp/rig.tar.gz" || fail "could not download $url
     If this is a certificate error, a proxy is inspecting TLS on this network."
  mkdir -p "$tmp/x"
  tar -xzf "$tmp/rig.tar.gz" -C "$tmp/x" --strip-components 1
  # Move into place last, so an interrupted download never leaves a half-written rig
  # that later looks installed.
  mkdir -p "$RIG_HOME"
  rm -rf "$target.partial"
  mv "$tmp/x" "$target.partial"
  mv "$target.partial" "$target"
  (cd "$target" && bun install --production --silent >/dev/null 2>&1) || true
fi

mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/rig" <<SHIM
#!/usr/bin/env sh
exec "$bun_bin" run "$target/src/index.ts" "\$@"
SHIM
chmod +x "$BIN_DIR/rig"
say "rig          $BIN_DIR/rig"

# --- 4. make it stick in new terminals --------------------------------------

# One managed block, in one file. Without this, "open a new terminal" is a dead end: bun's
# own installer edits a shell file and we suppressed that on purpose, so nothing else puts
# these directories on PATH.
#
# Rewritten between its markers on every run, so a second install replaces the block rather
# than appending another one.
rc=""
case "${SHELL:-}" in
  *zsh)  rc="$HOME/.zshrc" ;;
  *bash) rc="$HOME/.bashrc" ;;
  *)     [ -f "$HOME/.zshrc" ] && rc="$HOME/.zshrc" || rc="$HOME/.profile" ;;
esac

bun_dir=$(dirname "$bun_bin")
begin="# BEGIN rig"
end="# END rig"

if [ -n "$rc" ]; then
  tmp_rc=$(mktemp)
  if [ -f "$rc" ]; then
    awk -v b="$begin" -v e="$end" '
      $0 == b { skip = 1 } skip != 1 { print } $0 == e { skip = 0 }
    ' "$rc" > "$tmp_rc"
  fi
  {
    printf '%s\n' "$begin"
    # mise keeps what it installs behind shims. Without this directory, the Python and uv
    # rig installed are invisible, and anything asking for `python3` gets whatever the
    # system has — on macOS a stub that needs Xcode.
    printf 'export PATH="%s:%s:$HOME/.local/share/mise/shims:$PATH"\n' "$BIN_DIR" "$bun_dir"
    printf '%s\n' "$end"
  } >> "$tmp_rc"
  # Replace in one step, so an interrupted write never truncates somebody's shell file.
  mv "$tmp_rc" "$rc"
  say "path         added to $(basename "$rc")"
fi

# --- 5. hand over -----------------------------------------------------------

printf '\n' >&2
if [ -n "$DEPLOYMENT" ]; then
  exec "$BIN_DIR/rig" setup "$DEPLOYMENT"
fi

say "Next:"
say "  rig setup <deployment-url>   make this machine ready"
say "  rig doctor                   see what this machine has"
printf '\n' >&2
say "In this terminal, or open a new one:"
say "  export PATH=\"$BIN_DIR:$bun_dir:\$PATH\""
printf '\n' >&2
