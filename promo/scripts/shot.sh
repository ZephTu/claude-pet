#!/bin/bash
# shot.sh <out.png> <js run after the zh demo data is in>
# Renders the real Task Board (Chinese UI) with promo/demo/board-demo-zh.js through
# `ClaudePet --render-board`. Run after `swift build` in the repo root.
#   NOW="2026-11-24T10:05:00"  fixes the board's clock (local time)
#   DAY2=1                     the next day: the first session closed, a new one took over
set -euo pipefail
PROMO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$PROMO/.." && pwd)"
PRE=""
[ -n "${NOW:-}" ] && PRE="window.DEMO_NOW = new Date('$NOW').getTime();"
[ -n "${DAY2:-}" ] && PRE="$PRE window.DEMO_DAY2 = true;"
DEMO="$(cat "$PROMO/demo/board-demo-zh.js")"
HQ_BIN="$PROMO/scripts/nohq/hq" CLAUDE_PET_LANG=zh "$ROOT/.build/debug/ClaudePet" --render-board "$1" "$PRE
$DEMO
$2
'ok'"
