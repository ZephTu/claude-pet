#!/bin/bash
# 开发用安装：编译当前工作副本，装到本机，挂 hook。
#
# 面向分发的那份在 dist/install.sh（由 scripts/package.sh 生成），它多了预编译
# 二进制、架构探测和隔离标记清理。这份只服务"改完代码马上装上看效果"。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
PET_DIR="$CLAUDE_DIR/pet"
APP_DEST="$HOME/Applications/ClaudePet.app"

MODE="${1:-release}"
ARCH="${2:-host}"

[ -d "$CLAUDE_DIR" ] || { echo "找不到 ${CLAUDE_DIR}，这台机器没装 Claude Code" >&2; exit 1; }

echo "==> 编译（$MODE / ${ARCH}）"
"$ROOT/scripts/build-app.sh" "$MODE" "$ARCH"

echo "==> 安装 hook 程序到 $PET_DIR/pet-emit"
mkdir -p "$PET_DIR/sessions"
cp "$ROOT/pet-emit" "$PET_DIR/pet-emit"
chmod +x "$PET_DIR/pet-emit"

# settings.json 管着本机所有 Claude Code session，是整个项目风险最高的一步。
# 备份、原子写、写完解析校验、出任何问题回滚，全在 pet-emit 里面做，跟分发版
# 走的是同一份代码——这里不再单独实现一套。
echo "==> 挂 hook（会先备份 settings.json）"
"$PET_DIR/pet-emit" --patch-settings "$SETTINGS"

echo "==> 安装 app 到 $APP_DEST"
mkdir -p "$HOME/Applications"
pkill -x ClaudePet 2>/dev/null || true
rm -rf "$APP_DEST.installing"
cp -R "$ROOT/ClaudePet.app" "$APP_DEST.installing"
rm -rf "$APP_DEST"
mv "$APP_DEST.installing" "$APP_DEST"
open "$APP_DEST"

echo ""
echo "装好了。hook 要开一个新的 Claude Code session 才生效。"
