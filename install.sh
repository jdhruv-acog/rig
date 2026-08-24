#!/usr/bin/env sh
# rig — put this tool on a machine that has nothing.
#
#   curl -fsSL https://<host>/install.sh | sh
#   curl -fsSL https://<host>/install.sh | sh -s -- --site https://<your-site>/site.yaml
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
SITE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --site) SITE="${2:-}"; shift 2 ;;
    --version) RIG_VERSION="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option '$1'" >&2; exit 2 ;;
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
  say "bun          $(bun --version) — already here"
else
  say "bun          installing to \$HOME/.bun"
  BUN_INSTALL="$HOME/.bun" SHELL=/bin/false \
    sh -c 'curl -fsSL https://bun.sh/install | bash' >/dev/null 2>&1 \
    || fail "bun did not install. Run this to see why:
     curl -fsSL https://bun.sh/install | bash"
fi
BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
PATH="$BUN_INSTALL/bin:$BIN_DIR:$PATH"
export PATH BUN_INSTALL

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
exec "$BUN_INSTALL/bin/bun" run "$target/src/index.ts" "\$@"
SHIM
chmod +x "$BIN_DIR/rig"
say "rig          $BIN_DIR/rig"

# --- 4. hand over -----------------------------------------------------------

printf '\n' >&2
if [ -n "$SITE" ]; then
  exec "$BIN_DIR/rig" init --site "$SITE"
fi

say "Next:"
say "  rig init --site <url>    point rig at your organisation"
say "  rig doctor               see what this machine has"
printf '\n' >&2
say "If 'rig' is not found, open a new terminal, or run:"
say "  export PATH=\"$BIN_DIR:$BUN_INSTALL/bin:\$PATH\""
printf '\n' >&2
