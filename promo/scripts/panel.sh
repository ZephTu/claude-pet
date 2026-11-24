#!/bin/bash
# The session list stills (assets/panel-open.png, assets/panel-allowed.png): the real pet page
# driven by demo/panel-zh.js through `ClaudePet --probe-skin`. Run after `swift build`.
set -euo pipefail
PROMO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$PROMO/.." && pwd)"
for sc in open allowed; do
  CLAUDE_PET_LANG=zh "$ROOT/.build/debug/ClaudePet" --probe-skin index.html "$PROMO/assets/panel-$sc.png" \
    "$(cat "$PROMO/demo/panel-zh.js"); PANEL('$sc')" >/dev/null
done
