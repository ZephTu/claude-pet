#!/bin/bash
# Build ClaudePet.app and the pet-emit binary from the SwiftPM package.
# No Xcode here, so the bundle is assembled by hand.
#
#   ./scripts/build-app.sh                 debug-ish local build (host arch)
#   ./scripts/build-app.sh release         release, host arch
#   ./scripts/build-app.sh release universal   release, arm64 + x86_64
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
ARCHMODE="${2:-host}"

# Plain string, not an array: macOS ships bash 3.2, where expanding an empty
# array under `set -u` is an error. Word-splitting is safe here because the
# flags contain no spaces.
ARCHFLAGS=""
if [ "$ARCHMODE" = "universal" ]; then
  ARCHFLAGS="--arch arm64 --arch x86_64"
fi

echo "==> swift build -c $CONFIG $ARCHFLAGS"
# Check swift build's own status, not the pipeline's: a failed build must stop
# the script instead of falling through to a confusing "product not found".
BUILD_LOG=$(mktemp)
if ! swift build -c "$CONFIG" $ARCHFLAGS >"$BUILD_LOG" 2>&1; then
  echo "编译失败："
  grep -vE "ld: warning|^\[" "$BUILD_LOG" | tail -20
  rm -f "$BUILD_LOG"
  exit 1
fi
grep -E "^Build complete" "$BUILD_LOG" || true
rm -f "$BUILD_LOG"

# SwiftPM puts universal output somewhere else than a plain host build.
find_product() {
  local name="$1" found
  for candidate in \
    ".build/out/Products/$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}/$name" \
    ".build/$CONFIG/$name" \
    ".build/apple/Products/$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}/$name"
  do
    [ -f "$candidate" ] && { echo "$candidate"; return 0; }
  done
  found=$(find .build -name "$name" -type f -perm +111 2>/dev/null | head -1)
  [ -n "$found" ] && { echo "$found"; return 0; }
  return 1
}

APP_BIN=$(find_product ClaudePet) || { echo "找不到 ClaudePet 产物"; exit 1; }
EMIT_BIN=$(find_product PetEmit) || { echo "找不到 PetEmit 产物"; exit 1; }
BUNDLE_DIR=$(dirname "$APP_BIN")
BUNDLE="$BUNDLE_DIR/ClaudePet_ClaudePet.bundle"

APP="$ROOT/ClaudePet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$APP_BIN" "$APP/Contents/MacOS/ClaudePet"
[ -d "$BUNDLE" ] && cp -R "$BUNDLE" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>ClaudePet</string>
  <key>CFBundleIdentifier</key><string>local.claudepet</string>
  <key>CFBundleName</key><string>ClaudePet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Required to jump to an iTerm2 tab. Without this key macOS denies the
       Automation request outright rather than prompting the user, and the jump
       fails silently forever. Orca's jump goes through its own CLI and needs
       no entitlement at all. -->
  <key>NSAppleEventsUsageDescription</key><string>用来把你点击的 Claude Code session 所在的终端标签页切到前台。</string>
</dict></plist>
PLIST

cp "$EMIT_BIN" "$ROOT/pet-emit"
chmod +x "$ROOT/pet-emit"

codesign --force --deep -s - "$APP" 2>/dev/null
codesign --force -s - "$ROOT/pet-emit" 2>/dev/null

echo "==> built $APP"
echo "==> built $ROOT/pet-emit"
file "$APP/Contents/MacOS/ClaudePet" | sed 's/^/    /'
