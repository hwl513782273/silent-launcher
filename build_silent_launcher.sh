#!/bin/bash
# SilentLauncher 通用构建脚本（V22 修复版起）
# 修复内容：
#  1) 监测总时长 range 下界 30→10 秒（二进制 double 等长补丁，x86_64/arm64 各 slice 1 处）
#  2) about_inject.dylib：InsertAboutItem 改为轮询等待 SwiftUI 主菜单就绪 + 兜底创建主菜单
#     （解决 Intel/10.15 慢速机器上 SwiftUI 菜单构建晚导致「关于」菜单插不上的问题）
#  3) V24：默认检测总时长 180→10 秒（PollSettings 默认值；x86_64 数据 2 处 + arm64 数据 1 处 + arm64 指令 4 处）
#     检测间隔默认 2 秒保持不变（已是目标值）
#  4) V25：首次安装默认值修正 + 彩虹球修复
#     - 全局静默（globalSilent）默认 true→false：PollSettings.init / ContentView 失败兜底 共 4 处（x86_64 2 + arm64 2）
#     - 开机自启（launchAtLogin）首次安装默认关闭：ensureLoginItemInstalledOnce 置为 no-op（不再自动注册 LaunchAgent）
#     - about_inject.dylib 彩虹球修复：ShowFirstLaunchGuide 移后台线程、InsertAboutItem 改异步轮询
# 用法: ./build_silent_launcher.sh [版本号]   # 默认 1.35
set -e

VERSION="${1:-1.35}"
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

# 修复「默认检测总时长」：180.0 → 10.0（PollSettings 默认值）
#  - x86_64：数据常量 2 处（均紧邻 interval=2.0）
#  - arm64：数据常量 1 处 + 指令立即数 4 处
#    （movz/movk 构造 0x4066800000000000=180.0 → movz x8,#0x4024,lsl#48 + nop，构造 0x4024000000000000=10.0）
# 检测间隔默认 2.0 已是目标值，不改。
# 兼容 universal（x86_64+arm64）与单架构 x86_64 两种格式。
patch_default_pollsettings() {
  local BIN="$1"
  python3 - "$BIN" <<'PY'
import sys, struct as st
p = sys.argv[1]
data = bytearray(open(p, "rb").read())

def patch_slice(buf, base, size, label, expect_data, expect_insn=0):
    pat180 = st.pack("<d", 180.0)
    pat10  = st.pack("<d", 10.0)
    hits = []
    s = base
    while True:
        i = buf.find(pat180, s, base + size)
        if i < 0: break
        hits.append(i); s = i + 1
    assert len(hits) == expect_data, f"{label} 期望 {expect_data} 处 180.0 数据，实际 {len(hits)}: {hits}"
    for off in hits:
        buf[off:off+8] = pat10
    print(f"{label} data patched 180->10 at {hits}")

    if expect_insn:
        pair = st.pack("<I", 0xd2d00008) + st.pack("<I", 0xf2e80cc8)
        new_pair = st.pack("<I", 0xd2e80488) + st.pack("<I", 0xd503201f)
        hits = []
        s = base
        while True:
            i = buf.find(pair, s, base + size)
            if i < 0: break
            hits.append(i); s = i + 1
        assert len(hits) == expect_insn, f"{label} 期望 {expect_insn} 处 movz/movk，实际 {len(hits)}: {hits}"
        for off in hits:
            buf[off:off+8] = new_pair
        print(f"{label} insn patched 180->10 at {hits}")

if data[:4] == b"\xca\xfe\xba\xbe":
    # universal fat：解析两个 slice
    nfat = st.unpack(">I", data[4:8])[0]
    archs = []
    for i in range(nfat):
        off = 8 + i * 20
        cputype, _, offset, size, _ = st.unpack(">IIIII", data[off:off+20])
        archs.append((cputype, offset, size))
    by_type = {ct: (off, sz) for ct, off, sz in archs}
    x86_base, x86_size = by_type[0x1000007]
    arm_base, arm_size = by_type[0x100000C]
    patch_slice(data, x86_base, x86_size, "x86_64", expect_data=2)
    patch_slice(data, arm_base, arm_size, "arm64", expect_data=1, expect_insn=4)
else:
    # 单架构：期望纯 x86_64（10.15 版），2 处数据常量
    patch_slice(data, 0, len(data), "x86_64-only", expect_data=2)

assert data.find(st.pack("<d", 180.0)) == -1, "180.0 仍有残留！"
open(p, "wb").write(bytes(data))
print("default pollsettings patched: finalTime 180->10 (interval stays 2.0)")
PY
}

# V25：首次安装默认值修正
#  A) globalSilent 默认 true→false（mov w0,#1 -> mov w0,#0 / movb $1,%al -> movb $0,%al）
#     arm64: PollSettings.init (+0x8160)、ContentView._settings 失败兜底 (+0x839c)
#     x86_64: PollSettings.init (+0x5344)、ContentView._settings 失败兜底 (+0xc937)
#  B) launchAtLogin 首次安装默认关闭：ensureLoginItemInstalledOnce 置为 no-op（直接 ret）
#     arm64 @+0xcefc（stp...  -> ret 0xd65f03c0）；x86_64 @+0xa410（pushq %rbp 0x55 -> ret 0xc3）
# V25：首次安装默认值修正
#  A) globalSilent 默认 true→false（mov w0,#1 -> mov w0,#0 / movb $1,%al -> movb $0,%al）
#     universal x86_64 slice: PollSettings.init (+0x5344)、ContentView 失败兜底 (+0xc937)
#     universal arm64   slice: PollSettings.init (+0x8160)、ContentView 失败兜底 (+0x839c)
#     10.15 单架构 x86_64（模块 main）: PollSettings.init (+0x5bd4)、ContentView 失败兜底 (+0xd3e7)
#  B) launchAtLogin 首次安装默认关闭：ensureLoginItemInstalledOnce 置为 no-op（直接 ret）
#     universal arm64 @+0xcefc（stp... -> ret 0xd65f03c0）
#     universal x86_64 @+0xa410、10.15 单架构 @+0xac60（pushq %rbp 0x55 -> ret 0xc3）
patch_defaults_v25() {
  local BIN="$1"
  python3 - "$BIN" <<'PY'
import sys, struct as st
p = sys.argv[1]
data = bytearray(open(p, "rb").read())

def is_fat(buf):
    return buf[:4] == b"\xca\xfe\xba\xbe"

def fat_slices(buf):
    nfat = st.unpack(">I", buf[4:8])[0]
    archs = []
    for i in range(nfat):
        off = 8 + i * 20
        ct, _, offset, size, _ = st.unpack(">IIIII", buf[off:off+20])
        archs.append((ct, offset, size))
    return {ct: (off, sz) for ct, off, sz in archs}

def apply(buf, base, rel, old_h, new_h, desc):
    off = base + rel
    old = bytes.fromhex(old_h); new = bytes.fromhex(new_h)
    assert off + len(old) <= len(buf), f"{desc}: 越界 @{off}"
    assert buf[off:off+len(old)].hex() == old_h, f"{desc}: 字节不匹配 @{off} (实际 {buf[off:off+len(old)].hex()})"
    buf[off:off+len(new)] = new
    print(f"  {desc} @ {off}")

if is_fat(data):
    by = fat_slices(data)
    x86_base, x86_size = by[0x1000007]
    arm_base, arm_size = by[0x100000C]
    # arm64: globalSilent 2 处 + ensureLogin no-op
    apply(data, arm_base, 0x8160, "20008052", "00008052", "arm64 PollSettings.init globalSilent true->false")
    apply(data, arm_base, 0x839c, "20008052", "00008052", "arm64 ContentView 失败兜底 globalSilent true->false")
    apply(data, arm_base, 0xcefc, "fc6fbaa9", "c0035fd6", "arm64 ensureLoginItemInstalledOnce -> ret")
    # x86_64 slice: globalSilent 2 处 + ensureLogin no-op
    apply(data, x86_base, 0x5344, "b001", "b000", "x86_64 PollSettings.init globalSilent true->false")
    apply(data, x86_base, 0xc937, "b001", "b000", "x86_64 ContentView 失败兜底 globalSilent true->false")
    apply(data, x86_base, 0xa410, "55", "c3", "x86_64 ensureLoginItemInstalledOnce -> ret")
else:
    # 10.15 单架构 x86_64（模块 main，偏移独立）
    apply(data, 0, 0x5bd4, "b001", "b000", "10.15 PollSettings.init globalSilent true->false")
    apply(data, 0, 0xd3e7, "b001", "b000", "10.15 ContentView 失败兜底 globalSilent true->false")
    apply(data, 0, 0xac60, "55", "c3", "10.15 ensureLoginItemInstalledOnce -> ret")

open(p, "wb").write(bytes(data))
print("v25 defaults patched: globalSilent=false, ensureLoginItemInstalledOnce=noop")
PY
}

# V36：检测总时长 stepper 步长 10 → 5 秒（V35 数据区 patch 无效，改为指令立即数 patch）
# 定位方法：反汇编找 Stepper init 调用点（_$s7SwiftUI7StepperV5value2in4step...lufC），
# 调用前构造 step 参数的指令：
#   universal x86_64 slice: movabsq $0x4024000000000000（10.0）@ slice 偏移 0x144B8，
#     存入 -0x460(%rbp) 后 leaq 传给 rdx（Stepper #1 检测总时长）
#     （其他 3 处 movabsq 10.0 是 VStack spacing，不动）
#   universal arm64   slice: movz x8,#0x4024,lsl#48（10.0）@ slice 偏移 0x12B10，
#     str x8,[x19,#0x4c0]（step 槽位，Stepper #1 的 x2）
#     （V24 默认值 10.0 的 movz 在 0x...4e8/0x...8f0/0x...8c8/0x...c4 4 处，不动）
#   10.15 单架构 x86_64: movabsq $0x4024000000000000（10.0）@ 文件偏移 0x10F6A，
#     同样存 -0x460(%rbp) 传给 rdx
# 改为 5.0（0x4014000000000000）：movabsq imm 低字节 24 40 -> 14 40；
#   arm64 movz imm16 0x4024 -> 0x4014（d2e80488 -> d2e80288）
patch_stepper_step() {
  local BIN="$1"
  python3 - "$BIN" <<'PY'
import sys, struct as st
p = sys.argv[1]
data = bytearray(open(p, "rb").read())

def is_fat(buf):
    return buf[:4] == b"\xca\xfe\xba\xbe"

def fat_slices(buf):
    nfat = st.unpack(">I", buf[4:8])[0]
    archs = []
    for i in range(nfat):
        off = 8 + i * 20
        ct, _, offset, size, _ = st.unpack(">IIIII", buf[off:off+20])
        archs.append((ct, offset, size))
    return {ct: (off, sz) for ct, off, sz in archs}

def apply(buf, base, rel, old_h, new_h, desc):
    off = base + rel
    old = bytes.fromhex(old_h); new = bytes.fromhex(new_h)
    assert off + len(old) <= len(buf), f"{desc}: 越界 @{off}"
    assert buf[off:off+len(old)].hex() == old_h, f"{desc}: 字节不匹配 @{off} (实际 {buf[off:off+len(old)].hex()})"
    buf[off:off+len(new)] = new
    print(f"  {desc} @ {off}")

if is_fat(data):
    by = fat_slices(data)
    x86_base, _ = by[0x1000007]
    arm_base, _ = by[0x100000C]
    # x86_64: movabsq 10.0 的 imm64 在 slice 偏移 0x104B8 + 2 = 0x104BA
    apply(data, x86_base, 0x104BA, "0000000000002440", "0000000000001440", "x86_64 stepper step 10->5 (movabsq imm)")
    # arm64: movz x8,#0x4024,lsl#48 -> movz x8,#0x4014,lsl#48
    apply(data, arm_base, 0x12B10, "8804e8d2", "8802e8d2", "arm64 stepper step 10->5 (movz)")
else:
    # 10.15 单架构: movabsq 10.0 的 imm64 在文件偏移 0x10F6A + 2 = 0x10F6C
    apply(data, 0, 0x10F6C, "0000000000002440", "0000000000001440", "10.15 stepper step 10->5 (movabsq imm)")

open(p, "wb").write(bytes(data))
print("stepper step patched (instruction immediates): 10 -> 5")
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
patch_default_pollsettings "$MACOS_12/SilentLauncher.real"
patch_defaults_v25 "$MACOS_12/SilentLauncher.real"
patch_stepper_step "$MACOS_12/SilentLauncher.real"
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
patch_default_pollsettings "$MACOS_15/SilentLauncher.real"
patch_defaults_v25 "$MACOS_15/SilentLauncher.real"
patch_stepper_step "$MACOS_15/SilentLauncher.real"
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
