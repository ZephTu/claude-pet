#!/bin/bash
# Build a shareable tarball: universal binaries + full source + install scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-0.1.0}"
NAME="claude-pet-$VERSION"
OUT="$ROOT/dist/$NAME"

echo "==> 编译 universal 二进制"
./scripts/build-app.sh release universal >/dev/null
[ -d ClaudePet.app ] && [ -f pet-emit ] || { echo "构建产物缺失"; exit 1; }

echo "==> 组装 $NAME/"
rm -rf "$OUT" "$ROOT/dist/$NAME.tar.gz"
mkdir -p "$OUT/bin" "$OUT/src"

cp -R ClaudePet.app "$OUT/bin/"
cp pet-emit "$OUT/bin/"
cp dist/install.sh dist/uninstall.sh dist/README.md "$OUT/"
chmod +x "$OUT/install.sh" "$OUT/uninstall.sh"

# 源码：只带编译需要的东西，不带 .build 和 git 历史
for item in Package.swift Sources Resources hooks scripts; do
  cp -R "$item" "$OUT/src/"
done
cp README.md "$OUT/src/" 2>/dev/null || true
mkdir -p "$OUT/src/docs"
cp -R docs/superpowers/specs "$OUT/src/docs/" 2>/dev/null || true
rm -rf "$OUT/src/.build"

# 源码里不该带上打包脚本自己和 dist 目录
rm -f "$OUT/src/scripts/package.sh"

echo "==> 打 tar.gz"
( cd "$ROOT/dist" && tar -czf "$NAME.tar.gz" "$NAME" )
rm -rf "$OUT"

# ---- 另外单独打一份纯源码包 ----------------------------------------------
SRCNAME="$NAME-src"
SRCOUT="$ROOT/dist/$SRCNAME"
echo "==> 组装纯源码包 $SRCNAME/"
rm -rf "$SRCOUT" "$ROOT/dist/$SRCNAME.tar.gz"
mkdir -p "$SRCOUT"

for item in Package.swift Sources Resources hooks scripts docs; do
  [ -e "$item" ] && cp -R "$item" "$SRCOUT/"
done
cp README.md "$SRCOUT/" 2>/dev/null || true
cp .gitignore "$SRCOUT/" 2>/dev/null || true
# 别把编译产物、分发脚本和别人的安装包塞进源码包
rm -rf "$SRCOUT/.build" "$SRCOUT/scripts/package.sh"

( cd "$ROOT/dist" && tar -czf "$SRCNAME.tar.gz" "$SRCNAME" )
rm -rf "$SRCOUT"

SIZE=$(du -h "$ROOT/dist/$NAME.tar.gz" | cut -f1 | tr -d ' ')
SRCSIZE=$(du -h "$ROOT/dist/$SRCNAME.tar.gz" | cut -f1 | tr -d ' ')
echo ""
echo "打好了两个包："
echo "  dist/$NAME.tar.gz      ($SIZE)   给同事用：解压跑 ./install.sh，不需要任何开发工具"
echo "  dist/$SRCNAME.tar.gz  ($SRCSIZE)    纯源码：自己编或继续开发，需要 Xcode CLT"
