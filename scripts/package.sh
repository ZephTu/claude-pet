#!/bin/bash
# Build a shareable tarball: universal binaries + full source + install scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-0.1.0}"
NAME="claude-pet-$VERSION"
OUT="$ROOT/dist/$NAME"

echo "==> building universal binaries"
./scripts/build-app.sh release universal >/dev/null
[ -d ClaudePet.app ] && [ -f pet-emit ] || { echo "build products missing"; exit 1; }

echo "==> assembling $NAME/"
rm -rf "$OUT" "$ROOT/dist/$NAME.tar.gz"
mkdir -p "$OUT/bin" "$OUT/src"

cp -R ClaudePet.app "$OUT/bin/"
cp pet-emit "$OUT/bin/"
cp dist/install.sh dist/uninstall.sh dist/README.md dist/README.zh-CN.md "$OUT/"
chmod +x "$OUT/install.sh" "$OUT/uninstall.sh"

# Source: only what a build needs — no .build, no git history
for item in Package.swift Sources Resources hooks scripts; do
  cp -R "$item" "$OUT/src/"
done
cp README.md README.zh-CN.md LICENSE "$OUT/src/" 2>/dev/null || true
mkdir -p "$OUT/src/docs"
cp -R docs/superpowers/specs "$OUT/src/docs/" 2>/dev/null || true
rm -rf "$OUT/src/.build"

# The bundled source should not carry the packaging script or dist/ itself
rm -f "$OUT/src/scripts/package.sh"

echo "==> creating tar.gz"
( cd "$ROOT/dist" && tar -czf "$NAME.tar.gz" "$NAME" )
rm -rf "$OUT"

# ---- A second, source-only tarball ---------------------------------------
SRCNAME="$NAME-src"
SRCOUT="$ROOT/dist/$SRCNAME"
echo "==> assembling source-only $SRCNAME/"
rm -rf "$SRCOUT" "$ROOT/dist/$SRCNAME.tar.gz"
mkdir -p "$SRCOUT"

for item in Package.swift Sources Resources hooks scripts docs; do
  [ -e "$item" ] && cp -R "$item" "$SRCOUT/"
done
cp README.md README.zh-CN.md LICENSE "$SRCOUT/" 2>/dev/null || true
cp .gitignore "$SRCOUT/" 2>/dev/null || true
# Keep build products, the distribution installer and other tarballs out
rm -rf "$SRCOUT/.build" "$SRCOUT/scripts/package.sh"

( cd "$ROOT/dist" && tar -czf "$SRCNAME.tar.gz" "$SRCNAME" )
rm -rf "$SRCOUT"

SIZE=$(du -h "$ROOT/dist/$NAME.tar.gz" | cut -f1 | tr -d ' ')
SRCSIZE=$(du -h "$ROOT/dist/$SRCNAME.tar.gz" | cut -f1 | tr -d ' ')
echo ""
echo "Two tarballs ready:"
echo "  dist/$NAME.tar.gz      ($SIZE)   for others: unpack, run ./install.sh, no dev tools needed"
echo "  dist/$SRCNAME.tar.gz  ($SRCSIZE)    source only: build it yourself, needs Xcode CLT"
