#!/bin/bash
# SilentLauncher 通用构建脚本（V22 修复版起）
# 修复内容：
#  1) 监测总时长 range 下界 30→10 秒（二进制 double 等长补丁，x86_64/arm64 各 slice 1 处）
#  2) about_inject.dylib：InsertAboutItem 改为轮询等待 SwiftUI 主菜单就绪 + 兜底创建主菜单
#     （解决 Intel/10.15 慢速机器上 SwiftUI 菜单构建晚导致「关于」菜单插不上的问题）
# 用法: ./build_silent_launcher.sh [版本号]   # 默认 1.22
set -e

VERSION="${1:-1.22}"
echo "=== SilentLauncher Build v$VERSION ==="

# 二进制等长替换：原版二进制里硬编码的旧名「开机静默启动器」(21字节 UTF-8)
# 全部替换为「静默启动管理器」(同样 21 字节)。
patch_binary() {
  local BIN="$1"
  python3 - "$BIN" <<'PY'
import sys
p = sys.argv[1]
old = "开机静默启动器".encode("utf-8")
new = "静默启动管理器".encode("utf-8")
assert len(old) == len(new), "old/new must be equal byte length"
with open(p, "rb") as f:
    data = f.read()
n = data.count(old)
if n:
    data = data.replace(old, new)
    with open(p, "wb") as f:
        f.write(data)
    print(f"patched {n} occurrences in {p}")
else:
    print(f"(no old name in {p}, skip)")
PY
}

# 修复「监测总时长」range 下界：30.0 → 10.0（double 等长 8 字节补丁）
# 12 universal 二进制 2 处（x86_64/arm64 各 1），10.15 x86_64 单架构 1 处
patch_duration_range() {
  local BIN="$1"
  python3 - "$BIN" <<'PY'
import sys, struct
p = sys.argv[1]
data = open(p, "rb").read()
old = struct.pack("<d", 30.0)
new = struct.pack("<d", 10.0)
hits = []
s = 0
while True:
    i = data.find(old, s)
    if i < 0: break
    hits.append(i); s = i + 1
assert len(hits) in (1, 2), f"期望 1 或 2 处 30.0，实际 {len(hits)} 处: {hits}"
for off in hits:
    data = data[:off] + new + data[off+8:]
open(p, "wb").write(data)
print(f"duration range patched 30->10 at {hits}")
PY
}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OUTDIR="/Users/banqiu/Downloads/workbuddy 项目/开机静默"
SRC_12="/Users/banqiu/Downloads/workbuddy 项目/开机静默/12-静默启动管理器-V20.dmg"
SRC_1015="/Users/banqiu/Downloads/workbuddy 项目/开机静默/10.15-静默启动管理器-V20.dmg"
DYLIB="$SCRIPT_DIR/about_inject.dylib"
STRINGS="$SCRIPT_DIR/strings.txt"

COPYRIGHT='Copyright © 2026 banqiu. Released under the MIT License.'

# ---- 12 universal ----
echo "--- [1/2] 12 universal ---"
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

plutil -replace CFBundleVersion -string "$VERSION" "$PLIST_12"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST_12"
plutil -insert NSHumanReadableCopyright -string "$COPYRIGHT" "$PLIST_12"
plutil -replace CFBundleName -string "静默启动管理器" "$PLIST_12"
plutil -replace CFBundleDisplayName -string "静默启动管理器" "$PLIST_12"

mv "$MACOS_12/SilentLauncher" "$MACOS_12/SilentLauncher.real"
patch_binary "$MACOS_12/SilentLauncher.real"
patch_duration_range "$MACOS_12/SilentLauncher.real"
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

rm -f "$OUTDIR/12-silent-launcher-v$VERSION-universal.dmg"
ln -s /Applications "$STAGE_12/Applications"
hdiutil create -volname "静默启动管理器 V$VERSION" -srcfolder "$STAGE_12" -ov -format UDZO "$OUTDIR/12-silent-launcher-v$VERSION-universal.dmg" 2>&1 | tail -1
hdiutil detach "$MNT_12" -quiet
echo "OK 12-silent-launcher-v$VERSION-universal.dmg"

# ---- 10.15 x86_64 ----
echo "--- [2/2] 10.15 x86_64 ---"
MNT_15=$(hdiutil info 2>/dev/null | grep -B1 "$SRC_1015" | grep '/Volumes/' | sed 's|.*\(/Volumes/\)|\1|')
if [ -z "$MNT_15" ] || [ ! -d "$MNT_15" ]; then
  MNT_15=$(hdiutil attach "$SRC_1015" -nobrowse 2>&1 | grep '/Volumes/' | sed 's|.*\(/Volumes/\)|\1|')
fi
echo "Mount: $MNT_15"
STAGE_15="/tmp/dmg_stage_15"
rm -rf "$STAGE_15"; mkdir -p "$STAGE_15"
cp -R "$MNT_15"/*.app "$STAGE_15/"
APP_15=$(ls -d "$STAGE_15"/*.app)
MACOS_15="$APP_15/Contents/MacOS"
RES_15="$APP_15/Contents/Resources"
PLIST_15="$APP_15/Contents/Info.plist"

plutil -replace CFBundleVersion -string "$VERSION" "$PLIST_15"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST_15"
plutil -insert NSHumanReadableCopyright -string "$COPYRIGHT" "$PLIST_15"
plutil -replace CFBundleName -string "静默启动管理器" "$PLIST_15"
plutil -replace CFBundleDisplayName -string "静默启动管理器" "$PLIST_15"

mv "$MACOS_15/SilentLauncher" "$MACOS_15/SilentLauncher.real"
patch_binary "$MACOS_15/SilentLauncher.real"
patch_duration_range "$MACOS_15/SilentLauncher.real"
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

rm -f "$OUTDIR/10.15-silent-launcher-v$VERSION-x86_64.dmg"
ln -s /Applications "$STAGE_15/Applications"
hdiutil create -volname "静默启动管理器 V$VERSION" -srcfolder "$STAGE_15" -ov -format UDZO "$OUTDIR/10.15-silent-launcher-v$VERSION-x86_64.dmg" 2>&1 | tail -1
hdiutil detach "$MNT_15" -quiet
echo "OK 10.15-silent-launcher-v$VERSION-x86_64.dmg"

echo ""
echo "=== DONE ==="
ls -lh "$OUTDIR/"*silent-launcher-v$VERSION*.dmg
