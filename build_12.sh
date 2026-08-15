#!/usr/bin/env bash
#
# build_12.sh — Build a macOS 12+ universal (arm64 + x86_64) Swift app.
# Native build: uses the system Swift runtime, NO embedded dylibs.
# Produces:  <OUT_DIR>/12-silent-launcher-universal.dmg
# The .app inside keeps the Chinese display name "静默启动管理器"
# (matches the LaunchAgent path), only the published DMG filename is English.
#
set -euo pipefail

# ───────────────────────── Config ─────────────────────────
APP_NAME="静默启动管理器"
APP_VERSION="20"
APP_BUNDLE_ID="com.user.silentlauncher"
SRC="main.swift"
OUT_DIR="$HOME/Downloads/workbuddy 项目/开机静默"
ICON="AppIcon.icns"
DEPLOY_TARGET="12.0"
COPYRIGHT="Copyright © 2026 hwl513782273. 基于 MIT 许可证开源发布。"
# ───────────────────────────────────────────────────────────

WORK="$(mktemp -d)"
APP="$WORK/$APP_NAME.app"
BIN="$APP/Contents/MacOS/$APP_NAME"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[ -f "$ICON" ] && cp "$ICON" "$APP/Contents/Resources/"

# 1) Compile both architectures natively @ 12.0
echo ">> compiling x86_64 @ $DEPLOY_TARGET"
swiftc -target "x86_64-apple-macosx$DEPLOY_TARGET" -O -o "$WORK/bin_x64" "$SRC"
echo ">> compiling arm64 @ $DEPLOY_TARGET"
swiftc -target "arm64-apple-macosx$DEPLOY_TARGET" -O -o "$WORK/bin_arm" "$SRC"

# 2) Lipo into a universal binary
echo ">> lipo -create universal"
lipo -create -output "$BIN" "$WORK/bin_x64" "$WORK/bin_arm"
lipo -info "$BIN"

# 3) Assemble bundle (native — no Swift runtime embedding)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$APP_BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$APP_VERSION</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$DEPLOY_TARGET</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>$COPYRIGHT</string>
</dict>
</plist>
PLIST

# 4) Package DMG — published filename format: <min-version>-silent-launcher-<arch>
DMG="$OUT_DIR/12-silent-launcher-universal.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$OUT_DIR"
hdiutil create -volname "$APP_NAME V$APP_VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO -imagekey zlib-level=9 "$DMG" -quiet
rm -rf "$STAGE" "$WORK"

echo "✅ built: $DMG"
echo "   arch: $(lipo -info "$BIN" 2>/dev/null | awk -F: '{print $2}')"
