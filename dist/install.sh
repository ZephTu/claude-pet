#!/bin/bash
# Claude Pet 一键安装
#
# 装完会有一只小星芒常驻桌面，反映你本机所有 Claude Code session 的状态：
# 有 session 卡着等你授权它就跳，有 session 在干活它就转，都停了它就打瞌睡。
#
# 这个脚本会做四件事，每一步都会告诉你：
#   1. 把 ClaudePet.app 装到 ~/Applications/
#   2. 把 pet-emit 放到 ~/.claude/pet/
#   3. 往 ~/.claude/settings.json 里追加 7 条 hook（先备份，不动你现有的任何配置）
#   4. 启动宠物
#
# 卸载跑 ./uninstall.sh，能还原成装之前的样子。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
PET_DIR="$CLAUDE_DIR/pet"
APP_DEST="$HOME/Applications/ClaudePet.app"

say()  { echo "$@"; }
die()  { echo "" >&2; echo "✗ $*" >&2; exit 1; }

say "=== Claude Pet 安装 ==="
say ""

# ---- 1. 环境检查 -----------------------------------------------------------

OSVER=$(sw_vers -productVersion 2>/dev/null || echo "0")
OSMAJOR=${OSVER%%.*}
if [ "$OSMAJOR" -lt 14 ] 2>/dev/null; then
  die "需要 macOS 14 或更新，你现在是 $OSVER"
fi

[ -d "$CLAUDE_DIR" ] || die "找不到 $CLAUDE_DIR —— 这台机器看起来没装 Claude Code，先装它再来"

# ---- 2. 准备可执行文件（优先用预编译，不行就本地编译）----------------------

APP_SRC="$HERE/bin/ClaudePet.app"
EMIT_SRC="$HERE/bin/pet-emit"
NEED_BUILD=0

if [ -d "$APP_SRC" ] && [ -f "$EMIT_SRC" ]; then
  # 压缩包如果是从网盘或邮件下载的，macOS 会打上隔离标记，双击会被拦。
  # 这里显式清掉，并且告诉你我在这么做——不偷偷来。
  if xattr -p com.apple.quarantine "$EMIT_SRC" >/dev/null 2>&1 \
     || xattr -p com.apple.quarantine "$APP_SRC" >/dev/null 2>&1; then
    say "==> 这个包带着 macOS 的下载隔离标记（因为它没有 Apple 开发者签名）"
    say "    正在清除，否则系统会拒绝运行它"
    xattr -dr com.apple.quarantine "$APP_SRC" 2>/dev/null || true
    xattr -dr com.apple.quarantine "$EMIT_SRC" 2>/dev/null || true
  fi

  # 真的能在这台机器上跑起来吗（架构对不对、有没有被 Gatekeeper 拦）
  if "$EMIT_SRC" --version >/dev/null 2>&1; then
    say "==> 用包里预编译好的版本（$( "$EMIT_SRC" --version )）"
  else
    say "==> 预编译版本在这台机器上跑不起来，改为本地编译"
    NEED_BUILD=1
  fi
else
  say "==> 包里没有预编译版本，改为本地编译"
  NEED_BUILD=1
fi

if [ "$NEED_BUILD" = "1" ]; then
  [ -d "$HERE/src" ] || die "包里既没有可用的预编译版本，也没有源码，装不了"
  command -v swift >/dev/null 2>&1 \
    || die "本地编译需要 Xcode Command Line Tools，先跑一次：xcode-select --install"
  say "    编译中，大概需要半分钟…"
  ( cd "$HERE/src" && ./scripts/build-app.sh release host >/dev/null 2>&1 ) \
    || die "编译失败。可以进 $HERE/src 手动跑 ./scripts/build-app.sh release 看报错"
  APP_SRC="$HERE/src/ClaudePet.app"
  EMIT_SRC="$HERE/src/pet-emit"
  [ -d "$APP_SRC" ] && [ -f "$EMIT_SRC" ] || die "编译完了但没找到产物"
  say "    编译完成"
fi

# ---- 3. 安装文件 -----------------------------------------------------------

mkdir -p "$PET_DIR/sessions"
cp "$EMIT_SRC" "$PET_DIR/pet-emit"
chmod +x "$PET_DIR/pet-emit"
say "==> hook 程序已放到 $PET_DIR/pet-emit"

# ---- 4. 挂 hook（改 settings.json，这是风险最高的一步）---------------------

say "==> 正在往 $SETTINGS 追加 hook"
say "    （会先备份；你现有的 hook 一条都不会动）"
if ! "$PET_DIR/pet-emit" --patch-settings "$SETTINGS"; then
  die "改 settings.json 失败。你的原文件没有被破坏，上面那行备份路径可以用来核对"
fi

# ---- 5. 装 app 并启动 ------------------------------------------------------

mkdir -p "$HOME/Applications"
pkill -x ClaudePet 2>/dev/null || true
rm -rf "$APP_DEST.installing"
cp -R "$APP_SRC" "$APP_DEST.installing"
rm -rf "$APP_DEST"
mv "$APP_DEST.installing" "$APP_DEST"
say "==> app 已装到 $APP_DEST"

open "$APP_DEST" 2>/dev/null || die "app 装好了但启动失败，可以手动打开 $APP_DEST"

say ""
say "装好了 🎉 桌面右下角应该出现一只橙色星芒。"
say ""
say "几件需要知道的事："
say "  · hook 要等你【开一个新的 Claude Code session】才生效，已经开着的不受影响"
say "  · 右键点宠物 = 菜单（暂停 / 开机自启 / 退出），这是唯一的退出入口"
say "  · 左键点它 = 展开当前所有 session 的列表"
say "  · 拖动可以换位置，会记住"
say "  · 不想要了：跑这个包里的 ./uninstall.sh"
