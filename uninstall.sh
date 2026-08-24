#!/usr/bin/env sh
# Undo a rig setup, so the whole thing can be run again from nothing.
#
#   sh rig-uninstall.sh          keep the npm credential, so you are not asked again
#   sh rig-uninstall.sh --all    remove that too, for a completely clean run
set -eu

KEEP_NPMRC=1
[ "${1:-}" = "--all" ] && KEEP_NPMRC=0

say() { printf '  %s\n' "$*"; }
gone() { printf '  removed  %s\n' "$1"; }

printf '\n  Undoing rig\n\n'

# Nothing here names a product. Removing ~/.bun takes bun and everything installed
# globally with it, which is every tool a deployment asked for.

# rig itself, and what it installed. Each path named in full — no wildcards.
for p in \
  "$HOME/.local/bin/rig" \
  "$HOME/.local/share/rig" \
  "$HOME/.local/state/rig" \
  "$HOME/.local/bin/mise" \
  "$HOME/.local/share/mise" \
  "$HOME/.bun"
do
  if [ -e "$p" ]; then rm -rf "$p" && gone "$p"; fi
done

# The PATH block, and nothing else in the file.
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
  [ -f "$rc" ] || continue
  grep -q '^# BEGIN rig$' "$rc" 2>/dev/null || continue
  tmp=$(mktemp)
  awk '$0 == "# BEGIN rig" { skip = 1 } skip != 1 { print } $0 == "# END rig" { skip = 0 }' "$rc" > "$tmp"
  mv "$tmp" "$rc"
  gone "the rig block in $(basename "$rc")"
done

if [ "$KEEP_NPMRC" -eq 0 ] && [ -f "$HOME/.npmrc" ]; then
  rm -f "$HOME/.npmrc" && gone "$HOME/.npmrc"
else
  [ -f "$HOME/.npmrc" ] && say "kept     ~/.npmrc, so you are not asked for the registry again"
fi

printf '\n  Done. Open a new terminal, then run the install command again.\n'
printf '  A product\047s own configuration is left where it is.\n\n'
