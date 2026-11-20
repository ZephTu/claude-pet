#!/bin/bash
# Install HQ: the hq CLI, its Claude Code hooks, and the /task and /board commands.
#
#   hq/install.sh --root ~/claude-hq        first install: where your task cards live
#   hq/install.sh                           upgrade, keeping the configured root
#   hq/install.sh --dev                     symlink the CLI to this checkout (for hacking on it)
#
# Touches: ~/.claude/hq/ (CLI, templates, config, state), ~/.claude/commands/{task,board}.md,
# and three hook entries in ~/.claude/settings.json (backed up first). Your task root is only
# scaffolded where files are missing; existing cards are never overwritten.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HQ_HOME="$CLAUDE_DIR/hq"
ROOT=""
DEV=0

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --dev) DEV=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
[ -d "$CLAUDE_DIR" ] || { echo "no $CLAUDE_DIR — Claude Code is not installed here" >&2; exit 1; }

if [ -z "$ROOT" ] && [ -f "$HQ_HOME/config.json" ]; then
  ROOT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["root"])' "$HQ_HOME/config.json")"
fi
[ -n "$ROOT" ] || { echo "first install needs --root <dir> (where task cards will live)" >&2; exit 2; }
ROOT="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$ROOT")"

echo "==> CLI and templates → $HQ_HOME"
mkdir -p "$HQ_HOME/bin" "$HQ_HOME/state"
rm -rf "$HQ_HOME/template" "$HQ_HOME/bin/hq"
if [ "$DEV" = 1 ]; then
  ln -s "$SRC/bin/hq" "$HQ_HOME/bin/hq"
  ln -s "$SRC/template" "$HQ_HOME/template"
else
  cp "$SRC/bin/hq" "$HQ_HOME/bin/hq"
  cp -R "$SRC/template" "$HQ_HOME/template"
fi
chmod +x "$SRC/bin/hq" "$HQ_HOME/bin/hq"
python3 - "$HQ_HOME/config.json" "$ROOT" <<'PY'
import json, os, sys
path, root = sys.argv[1], sys.argv[2]
cfg = {}
if os.path.exists(path):
    cfg = json.load(open(path))
cfg["root"] = root
json.dump(cfg, open(path, "w"), indent=1)
PY

echo "==> task root → $ROOT"
mkdir -p "$ROOT/tasks" "$ROOT/templates" "$ROOT/.claude/agents"
[ -f "$ROOT/templates/TASK.md" ] || cp "$SRC/template/TASK.md" "$ROOT/templates/TASK.md"
[ -f "$ROOT/templates/lead.md" ] || cp "$SRC/template/agents/lead.md" "$ROOT/templates/lead.md"
[ -f "$ROOT/CLAUDE.md" ] || cp "$SRC/template/CLAUDE.md" "$ROOT/CLAUDE.md"

echo "==> slash commands → $CLAUDE_DIR/commands"
mkdir -p "$CLAUDE_DIR/commands"
for c in task board; do
  dst="$CLAUDE_DIR/commands/$c.md"
  if [ -f "$dst" ] && ! grep -q '.claude/hq/bin/hq' "$dst"; then
    echo "    skip /$c: $dst exists and is not HQ's (rename it, then re-run)"
  else
    cp "$SRC/template/commands/$c.md" "$dst"
  fi
done

echo "==> hooks → $CLAUDE_DIR/settings.json (backup first)"
python3 - "$CLAUDE_DIR/settings.json" <<'PY'
import json, os, shutil, sys, time
path = sys.argv[1]
CMD = "$HOME/.claude/hq/bin/hq hook"
EVENTS = ["SessionStart", "UserPromptSubmit", "Stop"]
s = json.load(open(path)) if os.path.exists(path) else {}
hooks = s.setdefault("hooks", {})
changed = False
for ev in EVENTS:
    groups = hooks.setdefault(ev, [])
    if any(".claude/hq/bin/hq hook" in h.get("command", "") for g in groups for h in g.get("hooks", [])):
        continue
    groups.append({"hooks": [{"type": "command", "command": CMD, "timeout": 10}]})
    changed = True
if not changed:
    print("    already wired")
    sys.exit(0)
if os.path.exists(path):
    backup = f"{path}.hq-backup-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, backup)
    print(f"    backup: {backup}")
tmp = path + ".hq-tmp"
with open(tmp, "w") as f:
    json.dump(s, f, indent=2, ensure_ascii=False)
    f.write("\n")
json.load(open(tmp))  # parse-back check before replacing
os.replace(tmp, path)
print("    wired: " + ", ".join(EVENTS))
PY

echo ""
echo "Done. New Claude Code sessions pick up the hooks. Try:"
echo "  $HQ_HOME/bin/hq board"
echo "  /task <T-id | new task title>   (inside any Claude Code session)"
