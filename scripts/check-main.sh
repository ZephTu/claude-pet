#!/bin/bash
# Refuse to install a working copy that is missing what is already on main.
#
# Several worktrees of this repo each run scripts/install.sh, and the last install wins. One built
# from a feature branch that was cut before a fix merged puts the old code back: on 2026-11-21 the
# installed pet was a build from a branch cut before PR #50, and #50's fix looked broken for hours
# although it was on main. So before building, this checks that HEAD contains origin/main.
#
#   scripts/check-main.sh [--force]
# Exit 0: fine (or forced / confirmed / not a git checkout). Exit 1: refused.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORCE=0
for a in "$@"; do [ "$a" = "--force" ] && FORCE=1; done
[ "${CLAUDE_PET_INSTALL_ANYWAY:-}" = 1 ] && FORCE=1

git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || exit 0          # a tarball, not a checkout
git -C "$ROOT" remote get-url origin >/dev/null 2>&1 || exit 0        # no remote to compare with

if ! GIT_TERMINAL_PROMPT=0 git -C "$ROOT" fetch -q origin main 2>/dev/null; then
  echo "    (could not fetch origin/main — comparing with the last fetched copy)" >&2
fi
git -C "$ROOT" rev-parse -q --verify origin/main >/dev/null || exit 0

git -C "$ROOT" merge-base --is-ancestor origin/main HEAD && exit 0

branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
missing="$(git -C "$ROOT" rev-list --count HEAD..origin/main)"
{
  echo ""
  echo "!!  This checkout ($branch) is missing $missing commit(s) that are on origin/main:"
  git -C "$ROOT" log --oneline --no-decorate -8 HEAD..origin/main | sed 's/^/      /'
  [ "$missing" -gt 8 ] && echo "      …"
  echo "    Installing it would put the installed pet back to code without them."
  echo "    Install from main, or bring this branch up to date first:"
  echo "      git -C \"$ROOT\" merge origin/main      (or rebase)"
} >&2

if [ "$FORCE" = 1 ]; then
  echo "    --force given: installing anyway." >&2
  exit 0
fi
if [ -t 0 ] && [ -t 1 ]; then
  printf "    Install this older code anyway? [y/N] " >&2
  read -r answer
  case "$answer" in y|Y|yes|YES) exit 0 ;; esac
fi
echo "    Not installed. Re-run with --force to install it anyway." >&2
exit 1
