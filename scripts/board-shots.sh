#!/bin/bash
# The Task Board pictures in the README, rendered from made-up data (docs/previews/board-demo.js)
# through the real board page — so they show what the board looks like today, and never anyone's
# actual tasks. Run from the repo root after `swift build`: scripts/board-shots.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/debug/ClaudePet"
OUT="$ROOT/docs/images"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
DEMO="$(cat "$ROOT/docs/previews/board-demo.js")"

shot() {  # shot <out.png> <js run after the demo data is in>
  "$BIN" --render-board "$1" "$DEMO
$2
'ok'"
}

# Stills, scaled to 1600px wide.
shot "$TMP/board-today.png" 'render();'
shot "$TMP/board-all.png" 'ui.mode = "all"; render();'
shot "$TMP/board-task.png" 'ui.mode = "all"; ui.expanded.add("T-014"); render();
  setTimeout(() => { document.getElementById("task-T-014").scrollIntoView(); render(); }, 300);'
shot "$TMP/board-peek.png" 'render(); openPeek(DEMO_IDS.checkout);'
for f in board-today board-all board-task board-peek; do
  sips -Z 1600 "$TMP/$f.png" --out "$OUT/$f.png" >/dev/null
done

# Answering three asks at once: pick, pick, pick, send.
mkdir -p "$TMP/asks"
shot "$TMP/asks/1.png" 'render();'
shot "$TMP/asks/2.png" 'ui.picks["T-014.4"] = "do"; ui.drafts["note:T-014.4"] = "2 times — the 5s budget wins"; render();'
shot "$TMP/asks/3.png" 'ui.picks["T-014.4"] = "do"; ui.drafts["note:T-014.4"] = "2 times — the 5s budget wins"; ui.picks["T-014.5"] = "do"; render();'
shot "$TMP/asks/4.png" 'ui.picks["T-014.4"] = "do"; ui.drafts["note:T-014.4"] = "2 times — the 5s budget wins"; ui.picks["T-014.5"] = "do"; ui.picks["T-014.6"] = "todo"; render();'
shot "$TMP/asks/5.png" 'const t = taskById("T-014"); t.asks = [];
  t.todos.push({ i: 5, state: "open", owner: "me", text: "Once it is merged, post the load-test numbers in #payments", created: new Date().toISOString() });
  render(); toast("3 answers recorded · sent to checkout retries");'
# The left column, cropped from the 2x renders, at half size.
swift "$ROOT/scripts/make-gif.swift" "$TMP/asks" "$OUT/board-asks.gif" 40 190 1420 1300 1.8 0.5
ls -la "$OUT"/board-*
