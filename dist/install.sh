#!/bin/bash
# Claude Pet — one-shot installer
#
# Afterwards a small robot lives on your desktop and mirrors the state of every
# Claude Code session on this machine: green lamp while something is working,
# amber while a session waits on you, red once it has waited a minute, dark when
# everything is done.
#
# This script does four things and tells you about each one:
#   1. install ClaudePet.app into ~/Applications/
#   2. put pet-emit into ~/.claude/pet/
#   3. append 8 hooks to ~/.claude/settings.json (backed up first; your own
#      hooks are not touched)
#   4. start the pet
#
# Run ./uninstall.sh to put everything back the way it was.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
PET_DIR="$CLAUDE_DIR/pet"
APP_DEST="$HOME/Applications/ClaudePet.app"

say()  { echo "$@"; }
die()  { echo "" >&2; echo "✗ $*" >&2; exit 1; }

say "=== Claude Pet installer ==="
say ""

# ---- 1. Environment --------------------------------------------------------

OSVER=$(sw_vers -productVersion 2>/dev/null || echo "0")
OSMAJOR=${OSVER%%.*}
if [ "$OSMAJOR" -lt 14 ] 2>/dev/null; then
  die "macOS 14 or newer required; this machine is on $OSVER"
fi

[ -d "$CLAUDE_DIR" ] || die "no $CLAUDE_DIR — Claude Code does not look installed here; install it first"

# ---- 2. Pick an executable (precompiled first, local build as fallback) -----

APP_SRC="$HERE/bin/ClaudePet.app"
EMIT_SRC="$HERE/bin/pet-emit"
NEED_BUILD=0

if [ -d "$APP_SRC" ] && [ -f "$EMIT_SRC" ]; then
  # A tarball downloaded through a browser or mail client carries macOS's
  # quarantine flag, and Gatekeeper refuses to run it. Clearing that is stated
  # out loud rather than done quietly.
  if xattr -p com.apple.quarantine "$EMIT_SRC" >/dev/null 2>&1 \
     || xattr -p com.apple.quarantine "$APP_SRC" >/dev/null 2>&1; then
    say "==> this package carries macOS's download quarantine flag"
    say "    (it has no Apple Developer signature) — clearing it, or macOS will refuse to run it"
    xattr -dr com.apple.quarantine "$APP_SRC" 2>/dev/null || true
    xattr -dr com.apple.quarantine "$EMIT_SRC" 2>/dev/null || true
  fi

  # Does it actually run here — right architecture, not blocked by Gatekeeper?
  if "$EMIT_SRC" --version >/dev/null 2>&1; then
    say "==> using the precompiled build ($( "$EMIT_SRC" --version ))"
  else
    say "==> the precompiled build will not run here; building locally instead"
    NEED_BUILD=1
  fi
else
  say "==> no precompiled build in this package; building locally instead"
  NEED_BUILD=1
fi

if [ "$NEED_BUILD" = "1" ]; then
  [ -d "$HERE/src" ] || die "this package has neither a usable precompiled build nor source"
  command -v swift >/dev/null 2>&1 \
    || die "a local build needs Xcode Command Line Tools: run 'xcode-select --install' first"
  say "    building, takes about half a minute…"
  ( cd "$HERE/src" && ./scripts/build-app.sh release host >/dev/null 2>&1 ) \
    || die "build failed. Run ./scripts/build-app.sh release inside $HERE/src to see why"
  APP_SRC="$HERE/src/ClaudePet.app"
  EMIT_SRC="$HERE/src/pet-emit"
  [ -d "$APP_SRC" ] && [ -f "$EMIT_SRC" ] || die "the build finished but produced nothing"
  say "    build complete"
fi

# ---- 3. Install files ------------------------------------------------------

mkdir -p "$PET_DIR/sessions"
cp "$EMIT_SRC" "$PET_DIR/pet-emit"
chmod +x "$PET_DIR/pet-emit"
say "==> hook binary installed at $PET_DIR/pet-emit"

# ---- 4. Wire the hooks (edits settings.json — the riskiest step) ------------

say "==> appending hooks to $SETTINGS"
say "    (backed up first; not one of your existing hooks is touched)"
if ! "$PET_DIR/pet-emit" --patch-settings "$SETTINGS"; then
  die "could not edit settings.json. Your original file is intact — the backup path printed above can be used to check"
fi

# ---- 5. Install the app and start it ---------------------------------------

mkdir -p "$HOME/Applications"
pkill -x ClaudePet 2>/dev/null || true
rm -rf "$APP_DEST.installing"
cp -R "$APP_SRC" "$APP_DEST.installing"
rm -rf "$APP_DEST"
mv "$APP_DEST.installing" "$APP_DEST"
say "==> app installed at $APP_DEST"

open "$APP_DEST" 2>/dev/null || die "the app is installed but would not start; try opening $APP_DEST by hand"

say ""
say "Done 🎉 — a small robot should now be sitting in the bottom-right of your screen."
say ""
say "Worth knowing:"
say "  · hooks only take effect in a NEWLY STARTED Claude Code session; open ones are unaffected"
say "  · right-click the pet for the menu (nap / launch at login / quit) — that is the only way out"
say "  · left-click it to expand the list of live sessions"
say "  · drag it anywhere; it remembers where you put it"
say "  · changed your mind: run ./uninstall.sh from this package"
