#!/bin/bash
# Refuse to install a working copy that is missing what is already on main.
#
# Several worktrees of this repo each run scripts/install.sh, and the last install wins. One built
# from a feature branch that was cut before a fix merged puts the old code back: on 2026-11-21 the
# installed pet was a build from a branch cut before PR #50, and #50's fix looked broken for hours
# although it was on main. So before building, this checks that HEAD contains origin/main.
#
#   scripts/check-main.sh [--force]        (or CLAUDE_PET_INSTALL_ANYWAY=1)
# Exit 0: fine, forced, confirmed, or nothing to check against (said so). Exit 1: refused.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
REF=refs/remotes/origin/main          # spelled out: a local branch named "origin/main" must not win
FETCH_LIMIT=20                         # seconds; a dead network must not hang the install

FORCE=""
for a in "$@"; do [ "$a" = "--force" ] && FORCE="--force given"; done
[ -z "$FORCE" ] && [ "${CLAUDE_PET_INSTALL_ANYWAY:-}" = 1 ] && FORCE="CLAUDE_PET_INSTALL_ANYWAY=1 set"

say() { echo "    $*" >&2; }
skip() { say "$* — not checked"; exit 0; }

# Only this repo's own checkout. A source tree without .git sitting inside some other repository
# would otherwise be judged by that repository's HEAD and origin.
top="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ "$(cd "$top" && pwd -P)" = "$ROOT" ] || exit 0
git -C "$ROOT" remote get-url origin >/dev/null 2>&1 || skip "no remote named origin"

# An explicit refspec: `fetch origin main` updates origin/main only when the remote's fetch
# config covers main (not in a --single-branch clone, nor with a narrowed refspec).
say "fetching origin/main…"
( GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=5" \
    git -C "$ROOT" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 \
    fetch -q origin "+refs/heads/main:$REF" ) 2>/dev/null &
pid=$!
waited=0
while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt $((FETCH_LIMIT * 2)) ]; do
  sleep 0.5
  waited=$((waited + 1))
done
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  say "(no answer from origin in ${FETCH_LIMIT}s — comparing with the last fetched copy)"
elif ! wait "$pid"; then
  say "(could not fetch origin/main — comparing with the last fetched copy)"
fi
git -C "$ROOT" rev-parse -q --verify "$REF^{commit}" >/dev/null || skip "no origin/main to compare with"

git -C "$ROOT" merge-base --is-ancestor "$REF" HEAD 2>/dev/null
case $? in
  0) exit 0 ;;
  1) ;;                                                   # missing commits: below
  *) skip "could not compare this checkout with origin/main" ;;
esac

if branch="$(git -C "$ROOT" symbolic-ref -q --short HEAD)"; then
  fix="git -C \"$ROOT\" merge origin/main      (or rebase)"
else
  branch="detached at $(git -C "$ROOT" rev-parse --short HEAD)"
  fix="git -C \"$ROOT\" checkout --detach origin/main"
fi
missing="$(git -C "$ROOT" rev-list --count "HEAD..$REF" 2>/dev/null || echo "some")"
{
  echo ""
  echo "!!  This checkout ($branch) is missing $missing commit(s) that are on origin/main:"
  git -C "$ROOT" log --oneline --no-decorate -8 "HEAD..$REF" | sed 's/^/      /'
  [ "$missing" != "some" ] && [ "$missing" -gt 8 ] && echo "      …"
  echo "    Installing it would put the installed pet back to code without them."
  echo "    Install from main, or bring this checkout up to date first:"
  echo "      $fix"
} >&2

if [ -n "$FORCE" ]; then
  say "$FORCE: installing anyway."
  exit 0
fi
# Ask only when a person can see the question and answer it: the list and the prompt go to stderr.
if [ -t 0 ] && [ -t 1 ] && [ -t 2 ]; then
  printf "    Install this older code anyway? [y/N] " >&2
  read -r answer
  case "$answer" in y|Y|yes|YES) exit 0 ;; esac
fi
say "Not installed. Re-run with --force to install it anyway."
exit 1
