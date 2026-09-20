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

MODE="${1:-release}"
ARCH="${2:-host}"

[ -d "$CLAUDE_DIR" ] || { echo "no ${CLAUDE_DIR} — Claude Code is not installed here" >&2; exit 1; }

echo "==> building ($MODE / ${ARCH})"
"$ROOT/scripts/build-app.sh" "$MODE" "$ARCH"

echo "==> installing hook binary to $PET_DIR/pet-emit"
mkdir -p "$PET_DIR/sessions"
cp "$ROOT/pet-emit" "$PET_DIR/pet-emit"
chmod +x "$PET_DIR/pet-emit"

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
