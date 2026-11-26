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

# A statusline wrapped in `pet-emit --statusline` (docs/pet.md) would break the moment
# pet-emit is gone, in every session, with nothing pointing back here. The installer never
# writes it, so neither does this: stop before touching anything and say what to change.
# Both user settings files count; one plutil cannot parse is searched as text instead of
# being taken for one with no statusline.
for file in "$SETTINGS" "$CLAUDE_DIR/settings.local.json"; do
  [ -f "$file" ] || continue
  if statusline="$(plutil -extract statusLine.command raw -o - "$file" 2>/dev/null)"; then
    case "$statusline" in *pet-emit*) ;; *) continue ;; esac
  elif ! plutil -lint "$file" >/dev/null 2>&1 && statusline="$(grep -o 'pet-emit[^"]*--statusline' "$file")"; then
    :
  else
    continue
  fi
  echo "!! your statusline still runs pet-emit, which uninstalling removes:" >&2
  echo "     $statusline" >&2
  echo "   In $file, take the 'pet-emit --statusline --' part out of statusLine.command" >&2
  echo "   (or remove statusLine if pet-emit was all it ran), then run this again." >&2
  echo "   Nothing has been changed." >&2
  exit 1
done

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
rm -f "$PET_DIR/pet-emit" "$PET_DIR/app.lock"
rm -rf "$PET_DIR/sessions"
echo "==> removed the app and pet-emit"
# Say what is actually left rather than claim the folder is gone: jobs, notes and history
# stay unless the user removes them.
if rmdir "$PET_DIR" 2>/dev/null || [ ! -e "$PET_DIR" ]; then
  echo "==> removed $PET_DIR"
else
  echo "==> kept $PET_DIR, which still holds: $(ls -A "$PET_DIR" | tr '\n' ' ')"
  echo "    (rm -rf \"$PET_DIR\" removes it, scheduled jobs included)"
fi
echo ""
echo "Done. settings.json backups remain at $CLAUDE_DIR/settings.json.bak-claudepet-*"
echo "Claude Code sessions already open keep the hooks they started with: restart them, or"
echo "they report a hook error on each event until they end."
