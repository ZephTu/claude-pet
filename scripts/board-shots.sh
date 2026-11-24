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

# A stub hq that knows nothing: the board's own reads at load time get an empty answer instead
# of your real board, so nothing real can land in a picture before the demo data replaces it.
mkdir -p "$TMP/bin"; printf '#!/bin/sh\necho "{}"\n' > "$TMP/bin/hq"; chmod +x "$TMP/bin/hq"

shot() {  # shot <out.png> <js run after the demo data is in>
  HQ_BIN="$TMP/bin/hq" CLAUDE_PET_LANG=en "$BIN" --render-board "$1" "window.DEMO_NOW = new Date('2026-11-24T17:05:00').getTime();
$DEMO
$2
'ok'" >/dev/null
}
DRAWER_AT='render(); openDrawer("T-014"); setTimeout(() => { document.querySelector("#drawer .dr-body").scrollTop ='

# Stills, scaled to 1600px wide.
shot "$TMP/board-today.png" 'render();'
shot "$TMP/board-task.png" "$DRAWER_AT 470; }, 300);"
shot "$TMP/board-project.png" 'ui.mode = "projects"; goToProject("shop-api"); render();'
shot "$TMP/board-peek.png" 'render(); openPeek(DEMO_IDS.checkout);'
shot "$TMP/board-secretary.png" 'render(); openSecretary();'
shot "$TMP/board-jobs.png" 'ui.mode = "jobs"; loadJobs().then(() => render());'
for f in board-today board-task board-project board-peek board-secretary board-jobs; do
  sips -Z 1600 "$TMP/$f.png" --out "$OUT/$f.png" >/dev/null
done

# Answering three asks at once, in the task's drawer: pick, pick, pick, send.
PICK1='ui.picks["T-014.4"] = "do"; ui.drafts["note:T-014.4"] = "2 times — the 5s budget wins";'
PICK2="$PICK1 ui.picks[\"T-014.5\"] = \"do\";"
PICK3="$PICK2 ui.picks[\"T-014.6\"] = \"todo\";"
mkdir -p "$TMP/asks"
shot "$TMP/asks/1.png" 'render(); openDrawer("T-014");'
shot "$TMP/asks/2.png" "$PICK1 render(); openDrawer(\"T-014\");"
shot "$TMP/asks/3.png" "$PICK2 render(); openDrawer(\"T-014\");"
shot "$TMP/asks/4.png" "$PICK3 render(); openDrawer(\"T-014\");"
shot "$TMP/asks/5.png" 'const t = taskById("T-014"); t.asks = [];
  t.todos.push({ i: 5, state: "open", owner: "me", text: "Once it is merged, post the load-test numbers in #payments", created: new Date().toISOString() });
  render(); openDrawer("T-014");'
# The drawer, cropped from the 2x renders, at half size.
swift "$ROOT/scripts/make-gif.swift" "$TMP/asks" "$OUT/board-asks.gif" 1240 100 1120 1300 1.8 0.5
ls -la "$OUT"/board-*
