#!/bin/bash
# Claude Pet uninstaller: unwire the hooks, remove the app, and put
# settings.json back the way it was.
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
PET_DIR="$CLAUDE_DIR/pet"
APP_DEST="$HOME/Applications/ClaudePet.app"
PLIST="$HOME/Library/LaunchAgents/local.claudepet.plist"

say() { echo "$@"; }

say "=== Claude Pet uninstaller ==="

pkill -x ClaudePet 2>/dev/null || true

# Unwiring needs pet-emit itself. The installed copy may already be gone, so
# fall back to the one inside this package.
EMIT=""
for candidate in "$PET_DIR/pet-emit" "$(cd "$(dirname "$0")" && pwd)/bin/pet-emit"; do
  if [ -x "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
    EMIT="$candidate"
    break
  fi
done

if [ -n "$EMIT" ] && [ -f "$SETTINGS" ]; then
  say "==> removing hooks from $SETTINGS (backed up first)"
  "$EMIT" --unpatch-settings "$SETTINGS" || say "!! could not remove the hooks; your original file is intact — check it by hand"
elif [ -f "$SETTINGS" ]; then
  say "!! no usable pet-emit found; cannot unwire the hooks automatically"
  say "   edit $SETTINGS by hand and delete every entry whose command contains pet-emit"
fi

# Launch-at-login, if it was ever enabled
if [ -f "$PLIST" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  say "==> launch-at-login removed"
fi

rm -rf "$APP_DEST"
say "==> removed $APP_DEST"

rm -f "$PET_DIR/pet-emit"
rm -rf "$PET_DIR/sessions"
rmdir "$PET_DIR" 2>/dev/null || true
say "==> cleaned up $PET_DIR"

say ""
say "All gone. The settings.json backups are still there"
say "($CLAUDE_DIR/settings.json.bak-claudepet-*) — delete them once you are happy."
