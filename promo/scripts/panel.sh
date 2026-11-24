#!/bin/bash
# The session list stills (assets/panel-open.png, assets/panel-allowed.png) and the bubbles: the real pet page
# driven by demo/panel-zh.js through `ClaudePet --probe-skin`. Run after `swift build`.
set -euo pipefail
PROMO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$PROMO/.." && pwd)"
for sc in open allowed; do
  CLAUDE_PET_LANG=zh "$ROOT/.build/debug/ClaudePet" --probe-skin index.html "$PROMO/assets/panel-$sc.png" \
    "$(cat "$PROMO/demo/panel-zh.js"); PANEL('$sc')" >/dev/null
done

# The pet's own speech bubbles for the quick-note scene (assets/bubble-*.png): the same page,
# saying what AppMain.fileQuickNote says, cropped to the bubble (the cat under it is ours).
crop() { "$PROMO/.venv/bin/python" -c "import sys; from PIL import Image; im = Image.open(sys.argv[1]); a = im.split()[3].crop((0, 0, im.width, 284)); im.crop(a.getbbox()).save(sys.argv[2])" "$@"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
say() {  # say <name> <js say(...) call>
  CLAUDE_PET_LANG=zh "$ROOT/.build/debug/ClaudePet" --probe-skin index.html "$TMP/$1.png" "setMood('busy', null); $2; 'ok'" >/dev/null
  crop "$TMP/$1.png" "$PROMO/assets/bubble-$1.png"
}
say sorting 'say("记下了，正在分拣…", 600000)'
say filed 'say("已放到：新任务「订单导出 CSV 中文乱码」", 600000, "新任务「订单导出 CSV 中文乱码」")'
