#!/bin/bash
# V21 Build: original V20 binary + about menu dylib injection
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OUTDIR="/Users/banqiu/Downloads/workbuddy 项目/开机静默"
SRC_12="/Users/banqiu/Downloads/workbuddy 项目/开机静默/12-静默启动管理器-V20.dmg"
SRC_1015="/Users/banqiu/Downloads/workbuddy 项目/开机静默/10.15-静默启动管理器-V20.dmg"
DYLIB="$SCRIPT_DIR/about_inject.dylib"
STRINGS="$SCRIPT_DIR/strings.txt"

COPYRIGHT='Copyright © 2026 banqiu. Released under the MIT License.'

echo "=== V21 Build ==="

# ---- 12 universal ----
echo "--- [1/2] 12 universal ---"
# 挂载（若已挂载则复用）
MNT_12=$(hdiutil info 2>/dev/null | grep -B1 "$SRC_12" | grep '/Volumes/' | sed 's|.*\(/Volumes/.*\)|\1|')
if [ -z "$MNT_12" ] || [ ! -d "$MNT_12" ]; then
  MNT_12=$(hdiutil attach "$SRC_12" -nobrowse 2>&1 | grep '/Volumes/' | sed 's|.*\(/Volumes/.*\)|\1|')
fi
echo "Mount: $MNT_12"
STAGE_12="/tmp/dmg_stage_12"
rm -rf "$STAGE_12"; mkdir -p "$STAGE_12"
cp -R "$MNT_12"/*.app "$STAGE_12/"
APP_12=$(ls -d "$STAGE_12"/*.app)
MACOS_12="$APP_12/Contents/MacOS"
RES_12="$APP_12/Contents/Resources"
PLIST_12="$APP_12/Contents/Info.plist"

plutil -replace CFBundleVersion -string "21" "$PLIST_12"
plutil -replace CFBundleShortVersionString -string "21" "$PLIST_12"
plutil -insert NSHumanReadableCopyright -string "$COPYRIGHT" "$PLIST_12"
# 统一显示名：软件「里面」（菜单栏 / Dock / 关于 / 窗口标题）均显示新名
plutil -replace CFBundleName -string "静默启动管理器" "$PLIST_12"
plutil -replace CFBundleDisplayName -string "静默启动管理器" "$PLIST_12"

mv "$MACOS_12/SilentLauncher" "$MACOS_12/SilentLauncher.real"
cp "$DYLIB" "$RES_12/about_inject.dylib"
cp "$STRINGS" "$RES_12/strings.txt"
cat > "$MACOS_12/SilentLauncher" <<'EOF'
#!/bin/sh
D=$(cd "$(dirname "$0")" && pwd)
export DYLD_INSERT_LIBRARIES="$D/../Resources/about_inject.dylib"
exec "$D/SilentLauncher.real" "$@"
EOF
chmod +x "$MACOS_12/SilentLauncher"

xattr -cr "$APP_12"
codesign --force --sign - "$RES_12/about_inject.dylib" 2>/dev/null
codesign --force --deep --sign - "$APP_12"

rm -f "$OUTDIR/12-silent-launcher-universal.dmg"
ln -s /Applications "$STAGE_12/Applications"
hdiutil create -volname "静默启动管理器 V21" -srcfolder "$STAGE_12" -ov -format UDZO "$OUTDIR/12-silent-launcher-universal.dmg" 2>&1 | tail -1
hdiutil detach "$MNT_12" -quiet
echo "OK 12-silent-launcher-universal.dmg"

# ---- 10.15 x86_64 ----
echo "--- [2/2] 10.15 x86_64 ---"
MNT_15=$(hdiutil info 2>/dev/null | grep -B1 "$SRC_1015" | grep '/Volumes/' | sed 's|.*\(/Volumes/.*\)|\1|')
if [ -z "$MNT_15" ] || [ ! -d "$MNT_15" ]; then
  MNT_15=$(hdiutil attach "$SRC_1015" -nobrowse 2>&1 | grep '/Volumes/' | sed 's|.*\(/Volumes/.*\)|\1|')
fi
echo "Mount: $MNT_15"
STAGE_15="/tmp/dmg_stage_15"
rm -rf "$STAGE_15"; mkdir -p "$STAGE_15"
cp -R "$MNT_15"/*.app "$STAGE_15/"
APP_15=$(ls -d "$STAGE_15"/*.app)
MACOS_15="$APP_15/Contents/MacOS"
RES_15="$APP_15/Contents/Resources"
PLIST_15="$APP_15/Contents/Info.plist"

plutil -replace CFBundleVersion -string "21" "$PLIST_15"
plutil -replace CFBundleShortVersionString -string "21" "$PLIST_15"
plutil -insert NSHumanReadableCopyright -string "$COPYRIGHT" "$PLIST_15"
# 统一显示名：软件「里面」（菜单栏 / Dock / 关于 / 窗口标题）均显示新名
plutil -replace CFBundleName -string "静默启动管理器" "$PLIST_15"
plutil -replace CFBundleDisplayName -string "静默启动管理器" "$PLIST_15"

mv "$MACOS_15/SilentLauncher" "$MACOS_15/SilentLauncher.real"
cp "$DYLIB" "$RES_15/about_inject.dylib"
cp "$STRINGS" "$RES_15/strings.txt"
cat > "$MACOS_15/SilentLauncher" <<'EOF'
#!/bin/sh
D=$(cd "$(dirname "$0")" && pwd)
export DYLD_INSERT_LIBRARIES="$D/../Resources/about_inject.dylib"
exec "$D/SilentLauncher.real" "$@"
EOF
chmod +x "$MACOS_15/SilentLauncher"

xattr -cr "$APP_15"
codesign --force --sign - "$RES_15/about_inject.dylib" 2>/dev/null
codesign --force --deep --sign - "$APP_15"

rm -f "$OUTDIR/10.15-silent-launcher-x86_64.dmg"
ln -s /Applications "$STAGE_15/Applications"
hdiutil create -volname "静默启动管理器 V21" -srcfolder "$STAGE_15" -ov -format UDZO "$OUTDIR/10.15-silent-launcher-x86_64.dmg" 2>&1 | tail -1
hdiutil detach "$MNT_15" -quiet
echo "OK 10.15-silent-launcher-x86_64.dmg"

echo ""
echo "=== DONE ==="
ls -lh "$OUTDIR/"*silent-launcher*.dmg
