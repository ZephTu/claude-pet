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
say "==> removed $APP_DEST"

rm -f "$PET_DIR/pet-emit" "$PET_DIR/app.lock"
rm -rf "$PET_DIR/sessions"
# Say what is actually left rather than claim the folder is gone: jobs, notes and history
# stay unless you remove them.
if rmdir "$PET_DIR" 2>/dev/null || [ ! -e "$PET_DIR" ]; then
  say "==> removed $PET_DIR"
else
  say "==> kept $PET_DIR, which still holds: $(ls -A "$PET_DIR" | tr '\n' ' ')"
  say "    (rm -rf \"$PET_DIR\" removes it, scheduled jobs included)"
fi

say ""
say "Done. The settings.json backups are still there"
say "($CLAUDE_DIR/settings.json.bak-claudepet-*) — delete them once you are happy."
say "Claude Code sessions already open keep the hooks they started with: restart them, or"
say "they report a hook error on each event until they end."
