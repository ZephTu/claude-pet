#!/bin/bash
# Claude Pet 卸载：摘掉 hook、删掉 app，把 settings.json 还原成装之前的样子。
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
PET_DIR="$CLAUDE_DIR/pet"
APP_DEST="$HOME/Applications/ClaudePet.app"
PLIST="$HOME/Library/LaunchAgents/local.claudepet.plist"

say() { echo "$@"; }

say "=== Claude Pet 卸载 ==="

pkill -x ClaudePet 2>/dev/null || true

# 摘 hook 要用 pet-emit 本身；它可能已经被删了，那就退回到包里的那份。
EMIT=""
for candidate in "$PET_DIR/pet-emit" "$(cd "$(dirname "$0")" && pwd)/bin/pet-emit"; do
  if [ -x "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
    EMIT="$candidate"
    break
  fi
done

if [ -n "$EMIT" ] && [ -f "$SETTINGS" ]; then
  say "==> 正在从 $SETTINGS 摘掉 hook（会先备份）"
  "$EMIT" --unpatch-settings "$SETTINGS" || say "!! 摘 hook 失败，你的原文件没被破坏，可以手动检查"
elif [ -f "$SETTINGS" ]; then
  say "!! 找不到可用的 pet-emit，没法自动摘 hook"
  say "   请手动编辑 $SETTINGS，删掉所有 command 里含 pet-emit 的条目"
fi

# 开机自启（如果设过）
if [ -f "$PLIST" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  say "==> 已取消开机自启"
fi

rm -rf "$APP_DEST"
say "==> 已删除 $APP_DEST"

rm -f "$PET_DIR/pet-emit"
rm -rf "$PET_DIR/sessions"
rmdir "$PET_DIR" 2>/dev/null || true
say "==> 已清理 $PET_DIR"

say ""
say "卸干净了。settings.json 的备份还留着（$CLAUDE_DIR/settings.json.bak-claudepet-*），"
say "确认没问题后可以自己删掉。"
