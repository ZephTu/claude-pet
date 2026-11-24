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

# The pet's own speech bubbles (assets/bubble-*.png): the same page saying what the app says —
# AppMain.fileQuickNote for the quick note, window.notify for the finish notices — cropped to the
# bubbles (the cat under them is ours). A crop box comes from the alpha of the render named last.
crop() {  # crop <box-from.png> <in.png> <out.png>
  "$PROMO/.venv/bin/python" -c "import sys; from PIL import Image
box = Image.open(sys.argv[1]).split()[3].crop((0, 0, 960, 284)).getbbox()
Image.open(sys.argv[2]).crop(box).save(sys.argv[3])" "$@"
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pet() {  # pet <name> <js>
  CLAUDE_PET_LANG=zh "$ROOT/.build/debug/ClaudePet" --probe-skin index.html "$TMP/$1.png" "setMood('idle', null); $2; 'ok'" >/dev/null
}
pet sorting 'say("记下了，正在分拣…", 600000)'
pet filed 'say("已放到：新任务「订单导出 CSV 中文乱码」", 600000, "新任务「订单导出 CSV 中文乱码」")'
DARK='notify("深色模式: 对比度检查全部通过。", 600000, "深色模式", "s2", true)'
pet done-1 "$DARK"
pet done-2 "$DARK; notify(\"结账重试 · 接手: 重试写好了，测试全绿。下一步压测。\", 600000, \"结账重试 · 接手\", \"s5\", true)"
for b in sorting filed; do crop "$TMP/$b.png" "$TMP/$b.png" "$PROMO/assets/bubble-$b.png"; done
for b in done-1 done-2; do crop "$TMP/done-2.png" "$TMP/$b.png" "$PROMO/assets/bubble-$b.png"; done
