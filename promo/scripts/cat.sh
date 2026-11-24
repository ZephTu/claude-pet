#!/bin/bash
# The cat's real loops at 2x (480 px a frame) as one RGBA webp atlas per clip, plus
# assets/cat/clips.json for build.py. Same cutter as the app (scripts/skin-frames.swift),
# with only the frame size changed, so it needs the source videos in art/cat/ like the app does
# (art/ is not in git; ART=<dir> points at another checkout's).
#   [ART=../claude-pet/art] promo/scripts/cat.sh
set -euo pipefail
PROMO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$PROMO/.." && pwd)"
ART="${ART:-$ROOT/art}"
cd "$ROOT"   # skin-frames reads scripts/cat-sheets.json relative to the repo root
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
sed 's/^let size = 240$/let size = 480/' "$ROOT/scripts/skin-frames.swift" > "$TMP/cat-hires.swift"
grep -q '^let size = 480$' "$TMP/cat-hires.swift" || { echo "skin-frames.swift no longer has 'let size = 240'" >&2; exit 1; }
swiftc -O "$TMP/cat-hires.swift" -o "$TMP/cat-hires"
# skin-frames also rewrites <sheetDir>/../anchors, so give it a copy of the sheets: nothing in $ART changes.
mkdir -p "$TMP/art" && cp -R "$ART/cat/sheets" "$TMP/art/sheets"
"$TMP/cat-hires" cat "$ART/cat/videos" "$TMP/art/sheets" "$TMP/out"
mkdir -p "$PROMO/assets/cat"
"$PROMO/.venv/bin/python" - "$TMP/out" "$PROMO/assets/cat" <<'PY'
import json, sys
from PIL import Image
src, dst = sys.argv[1], sys.argv[2]
js = open(f"{src}/frames.js").read()
m = json.loads(js[js.index("{"):js.rindex("}") + 1])
out = {}
for name, c in m["clips"].items():
    col = Image.open(f"{src}/{c['file']}").convert("RGB")
    col.putalpha(Image.open(f"{src}/{c['alpha']}").convert("L"))
    fn = name.replace("@", "-") + ".webp"
    col.save(f"{dst}/{fn}", "WEBP", quality=88, method=6)
    out[name] = {"src": f"assets/cat/{fn}", "frames": c["frames"], "columns": c["columns"], "kind": c["kind"]}
json.dump({"size": m["size"], "fps": m["fps"], "clips": out}, open(f"{dst}/clips.json", "w"), indent=1)
print(len(out), "clips at", m["size"], "px,", m["fps"], "fps")
PY
