#!/bin/bash
# 开发用卸载：摘 hook、删 app、清目录。settings.json 回到装之前的样子。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
PET_DIR="$CLAUDE_DIR/pet"
APP_DEST="$HOME/Applications/ClaudePet.app"
PLIST="$HOME/Library/LaunchAgents/local.claudepet.plist"

pkill -x ClaudePet 2>/dev/null || true

# 摘 hook 要用 pet-emit；装过的那份可能已被删，退回到仓库里刚编出来的那份。
EMIT=""
for candidate in "$PET_DIR/pet-emit" "$ROOT/pet-emit"; do
  if [ -x "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
    EMIT="$candidate"
    break
  fi
done

if [ -n "$EMIT" ] && [ -f "$SETTINGS" ]; then
  echo "==> 摘 hook（会先备份）"
  "$EMIT" --unpatch-settings "$SETTINGS"
elif [ -f "$SETTINGS" ]; then
  echo "!! 找不到可用的 pet-emit，请手动删掉 $SETTINGS 里 command 含 pet-emit 的条目" >&2
fi

if [ -f "$PLIST" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "==> 已取消开机自启"
fi

rm -rf "$APP_DEST"
rm -f "$PET_DIR/pet-emit"
rm -rf "$PET_DIR/sessions"
rmdir "$PET_DIR" 2>/dev/null || true
echo "==> 已删除 app 和 $PET_DIR"
echo ""
echo "卸干净了。settings.json 的备份留在 $CLAUDE_DIR/settings.json.bak-claudepet-*"
