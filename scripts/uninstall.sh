#!/bin/bash
# Developer uninstall: unwire hooks, remove the app, clean up. settings.json
# returns to exactly what it was.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
PET_DIR="$CLAUDE_DIR/pet"
APP_DEST="$HOME/Applications/ClaudePet.app"
PLIST="$HOME/Library/LaunchAgents/local.claudepet.plist"

pkill -x ClaudePet 2>/dev/null || true

# Unwiring needs pet-emit itself; the installed copy may already be gone, so
# fall back to the freshly built one in the repo.
EMIT=""
for candidate in "$PET_DIR/pet-emit" "$ROOT/pet-emit"; do
  if [ -x "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
    EMIT="$candidate"
    break
  fi
done

if [ -n "$EMIT" ] && [ -f "$SETTINGS" ]; then
  echo "==> unwiring hooks (backed up first)"
  "$EMIT" --unpatch-settings "$SETTINGS"
elif [ -f "$SETTINGS" ]; then
  echo "!! no usable pet-emit — remove entries whose command contains pet-emit from $SETTINGS by hand" >&2
fi

if [ -f "$PLIST" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "==> launch-at-login removed"
fi

# Scheduled jobs: each has an agent that runs pet-emit, which is about to go. The jobs
# themselves (~/.claude/pet/jobs) are kept; reinstalling and opening the pet puts the agents back.
removed_jobs=0
for job in "$HOME"/Library/LaunchAgents/local.claudepet.job.*.plist; do
  [ -e "$job" ] || continue
  launchctl bootout "gui/$(id -u)/$(basename "$job" .plist)" 2>/dev/null || true
  rm -f "$job"
  removed_jobs=$((removed_jobs + 1))
done
[ "$removed_jobs" -gt 0 ] && echo "==> scheduled jobs switched off ($removed_jobs); they are kept in $PET_DIR/jobs"

rm -rf "$APP_DEST"
rm -f "$PET_DIR/pet-emit"
rm -rf "$PET_DIR/sessions"
rmdir "$PET_DIR" 2>/dev/null || true
echo "==> removed the app and $PET_DIR"
echo ""
echo "Done. settings.json backups remain at $CLAUDE_DIR/settings.json.bak-claudepet-*"
