#!/bin/bash
# Remove HQ's hooks, commands and CLI. Your task root (cards, asks) is left untouched.
set -euo pipefail
CLAUDE_DIR="$HOME/.claude"

python3 - "$CLAUDE_DIR/settings.json" <<'PY'
import json, os, shutil, sys, time
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)
s = json.load(open(path))
hooks = s.get("hooks", {})
removed = 0
for ev in list(hooks):
    for g in hooks[ev]:
        before = len(g.get("hooks", []))
        g["hooks"] = [h for h in g.get("hooks", []) if ".claude/hq/bin/hq hook" not in h.get("command", "")]
        removed += before - len(g["hooks"])
    hooks[ev] = [g for g in hooks[ev] if g.get("hooks")]
    if not hooks[ev]:
        del hooks[ev]
if removed:
    shutil.copy2(path, f"{path}.hq-backup-{time.strftime('%Y%m%d-%H%M%S')}")
    tmp = path + ".hq-tmp"
    json.dump(s, open(tmp, "w"), indent=2, ensure_ascii=False)
    json.load(open(tmp))
    os.replace(tmp, path)
print(f"removed {removed} hook entries")
PY

for c in task board; do
  f="$CLAUDE_DIR/commands/$c.md"
  [ -f "$f" ] && grep -q '.claude/hq/bin/hq' "$f" && rm "$f" && echo "removed /$c"
done
rm -rf "$CLAUDE_DIR/hq/bin" "$CLAUDE_DIR/hq/template"
echo "HQ removed. Config and session bindings remain in $CLAUDE_DIR/hq (delete it to forget them)."
