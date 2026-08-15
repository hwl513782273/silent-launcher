#!/usr/bin/env bash
#
# build_1015.sh — Build a macOS 10.15-compatible Swift app (AppKit + embedded runtime).
#
# Produces:  <APP_NAME>-10.15.app  (x86_64 + embedded Swift runtime, LSMin 10.15)
#            <DMG_OUT_DIR>/<X64_PREFIX><APP_NAME>-V<APP_VERSION>.dmg  (clean app name inside)
#
# Adapt the constants below. Requires Xcode command-line tools and (for DMG)
# hdiutil. Runs on Apple Silicon hosts too (Rosetta covers the x86_64 binary).
#
set -euo pipefail

# ───────────────────────── Config (edit per project) ─────────────────────────
APP_NAME="静默启动管理器"
APP_VERSION="20"
APP_BUNDLE_ID="com.user.silentlauncher"
SRC="main.swift"                       # AppKit source (NOT SwiftUI)
OUT_DIR="$HOME/Downloads/workbuddy 项目/开机静默"
X64_PREFIX="10.15-"                    # DMG filename prefix
ICON="AppIcon.icns"                    # optional, in CWD
DEPLOY_TARGET="10.15"
# ─────────────────────────────────────────────────────────────────────────────

TOOLCHAIN_SWIFT="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.0/macosx"
WORK="$(mktemp -d)"
APP="$WORK/$APP_NAME-10.15.app"
BIN="$APP/Contents/MacOS/$APP_NAME"
FW="$APP/Contents/Frameworks"

echo ">> TOOLCHAIN_SWIFT = $TOOLCHAIN_SWIFT"
[ -d "$TOOLCHAIN_SWIFT" ] || { echo "✗ toolchain swift dir missing"; exit 1; }

# 0) Create bundle dirs first (swiftc/ld will NOT create parent dirs)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$FW"
[ -f "$ICON" ] && cp "$ICON" "$APP/Contents/Resources/"

# 1) Compile pure x86_64 @ 10.15 (NEVER two -target flags -> arm64-only)
echo ">> compiling x86_64 @ $DEPLOY_TARGET"
swiftc -target "x86_64-apple-macosx$DEPLOY_TARGET" -O -o "$BIN" "$SRC"
lipo -info "$BIN"

# 2) Assemble bundle
echo ">> assembling bundle"

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
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 hwl513782273. 基于 MIT 许可证开源发布。</string>
</dict>
</plist>
PLIST

# 3) Embed Swift runtime — recursive TRANSITIVE CLOSURE (catches CoreGraphics etc.)
embed_swift_runtime() {
  local bin="$1"; local fwdir="$2"
  mkdir -p "$fwdir"
  echo "  >> embedding Swift runtime -> $fwdir"
  local pending=("$bin")
  local copied=0
  while [ ${#pending[@]} -gt 0 ]; do
    local f="${pending[0]}"; pending=("${pending[@]:1}")
    # Catch BOTH reference forms:
    local deps
    deps=$(otool -L "$f" 2>/dev/null \
      | awk '/\/usr\/lib\/swift\/libswift.*\.dylib/{print $1}
             /@rpath\/libswift.*\.dylib/{print "@rpath/" substr($1, index($1,"libswift"))}')
    for dep in $deps; do
      local base; base=$(basename "$dep")
      [ -f "$fwdir/$base" ] && continue
      if [ -f "$TOOLCHAIN_SWIFT/$base" ]; then
        cp "$TOOLCHAIN_SWIFT/$base" "$fwdir/"
        copied=$((copied+1))
        pending+=("$fwdir/$base")          # scan its deps too
      else
        echo "  ⚠️  source missing (likely unused weak overlay): $base"
      fi
    done
  done
  # Rewrite main binary's /usr/lib/swift deps -> @rpath
  otool -L "$bin" 2>/dev/null | awk '/\/usr\/lib\/swift\/libswift.*\.dylib/{print $1}' \
    | while read -r dep; do
        [ -n "$dep" ] && install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$bin" 2>/dev/null || true
      done
  install_name_tool -delete_rpath /usr/lib/swift "$bin" 2>/dev/null || true
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$bin" 2>/dev/null || true
  echo "  >> embedded $copied dylibs"
}

embed_swift_runtime "$BIN" "$FW"
echo ">> verifying embedded deps all resolve to @rpath:"
otool -L "$BIN" | grep libswift || true

# 4) Package DMG — published filename format: <min-version>-silent-launcher-<arch>
DMG="$OUT_DIR/10.15-silent-launcher-x86_64.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/$APP_NAME.app"        # rename: drop the -10.15 suffix
ln -s /Applications "$STAGE/Applications"
mkdir -p "$OUT_DIR"
hdiutil create -volname "$APP_NAME V$APP_VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO -imagekey zlib-level=9 "$DMG" -quiet
rm -rf "$STAGE" "$WORK"

echo "✅ built: $DMG"
echo "   arch: $(lipo -info "$BIN" 2>/dev/null | awk -F: '{print $2}')"
echo "   embedded dylibs: $(ls "$FW" 2>/dev/null | grep -c libswift)"
