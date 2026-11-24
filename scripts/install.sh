#!/bin/bash
# Developer install: build the working copy, install it, wire the hooks.
#
# The distribution-facing one is dist/install.sh (produced by scripts/package.sh);
# it adds precompiled binaries, arch probing and quarantine stripping. This one
# exists only for "I changed the code, install it now".
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
PET_DIR="$CLAUDE_DIR/pet"
APP_DEST="$HOME/Applications/ClaudePet.app"

# Positional: [release|debug] [host|universal]. --force anywhere: install even if this checkout
# is missing commits that are on origin/main (see scripts/check-main.sh).
FORCE=()
ARGS=()
for a in "$@"; do
  if [ "$a" = "--force" ]; then FORCE=(--force); else ARGS+=("$a"); fi
done
MODE="${ARGS[0]:-release}"
ARCH="${ARGS[1]:-host}"

[ -d "$CLAUDE_DIR" ] || { echo "no ${CLAUDE_DIR} — Claude Code is not installed here" >&2; exit 1; }

echo "==> checking this checkout has everything on origin/main"
"$ROOT/scripts/check-main.sh" ${FORCE[@]+"${FORCE[@]}"} || exit 1

echo "==> building ($MODE / ${ARCH})"
"$ROOT/scripts/build-app.sh" "$MODE" "$ARCH"

echo "==> installing hook binary to $PET_DIR/pet-emit"
mkdir -p "$PET_DIR/sessions"
# Into place as a new file, never copied over the old one: running sessions' hooks keep calling
# it, and macOS kills (SIGKILL, "Killed: 9") a signed binary whose file was rewritten in place.
cp "$ROOT/pet-emit" "$PET_DIR/pet-emit.new"
chmod +x "$PET_DIR/pet-emit.new"
mv -f "$PET_DIR/pet-emit.new" "$PET_DIR/pet-emit"

# settings.json drives every Claude Code session on this machine and is the
# riskiest thing here. Backup, atomic write, parse-back verification and
# rollback all live inside pet-emit — the same code the distribution installer
# uses, rather than a second implementation.
echo "==> wiring hooks (settings.json is backed up first)"
"$PET_DIR/pet-emit" --patch-settings "$SETTINGS"

echo "==> installing app to $APP_DEST"
mkdir -p "$HOME/Applications"
pkill -x ClaudePet 2>/dev/null || true
rm -rf "$APP_DEST.installing"
cp -R "$ROOT/ClaudePet.app" "$APP_DEST.installing"
rm -rf "$APP_DEST"
mv "$APP_DEST.installing" "$APP_DEST"
open "$APP_DEST"

echo ""
echo "Installed. Hooks take effect in newly started Claude Code sessions."
