# SilentLauncher / 静默启动管理器

> 一款 macOS 原生的「登录时自动隐藏指定应用窗口」小工具。/ A native macOS utility that auto-hides selected app windows at login.

> **作者 Author：banqiu**
>
> **开源许可证 Open Source License：MIT**（详见 [LICENSE](LICENSE)）。可自由使用、修改与再分发，须保留版权与许可证声明。

[下载最新版 / Download](https://github.com/hwl513782273/silent-launcher/releases/latest) · [问题反馈 / Issues](https://github.com/hwl513782273/silent-launcher/issues)

## 中文

### 主要功能

- **登录静默隐藏**：由 LaunchAgent 以 `--silent` 调用，在设定持续时间内按间隔循环隐藏「已勾选应用」的窗口。
- **GUI 管理**：列出需隐藏的应用（勾选启用 / 增删 / 改名 / 改 Bundle ID），设置总开关、静默持续秒数、扫描间隔，可「立即隐藏」测试。
- **开机自启**：点「设为开机启动」写入 `~/Library/LaunchAgents/com.silentlauncher.login.plist`（`RunAtLoad` + `--silent`），无需密码。
- **兜底强制关闭**：普通 `hide` 无效时（如菜单栏类应用 Hidden Bar），用 AppleScript 兜底强制关闭窗口。
- **关于菜单**：dylib 注入在 app 菜单追加「关于」「退出」项（原版无此菜单，使用 AppleScript 弹窗渲染版本与 MIT 许可信息）。
- **首次启动权限引导**：首次启动弹一次说明框，并直接拉起系统「辅助功能」授权窗、触发「自动化」授权，引导用户完成必要授权。

### 所需权限

- **辅助功能（必须）**：用于自动隐藏指定 App 的窗口。授权后需【退出并重新打开】本应用才生效。
- **自动化（必须）**：向目标 App 发送指令关闭窗口。首次隐藏时系统会逐个弹窗，请全部点「允许」。
- **登录项**：开机自启无需密码，在「系统设置 ▸ 通用 ▸ 登录项」中管理，无需额外授权弹窗。
- **不需要屏幕录制权限。**

### 快速开始

1. 在 [Releases](https://github.com/hwl513782273/silent-launcher/releases/latest) 下载对应系统的 DMG。
2. 把 `.app` 拖进「应用程序」。
3. 首次打开：自动弹出权限说明框 + 系统「辅助功能」授权窗，按引导完成授权。
4. 点「设为开机启动」，之后登录时即自动隐藏指定窗口。
5. 点左上角菜单「关于」可查看版本与 MIT 许可信息。

> ⚠️ **关于本仓库源码**：原项目 `main.swift` 在打包发布时遗失，本仓库的 `main.swift` 为**按可观察行为重建版**（配置结构、`--silent` 静默隐藏循环、GUI、AppleScript 兜底、LaunchAgent 自启等均依据原版表现重建，可能与原版存在细节差异）。V21 在原版 V20 二进制基础上仅做 dylib 注入（关于菜单 + 首次启动引导），**行为 100% 保留原版**。

配置（可选 / Advanced）：

配置文件位于 `~/Library/Application Support/SilentLauncher/config.json`，记录总开关、静默持续秒数、扫描间隔与需隐藏的应用列表（`name` / `bundleID` / `enabled`）。普通用户无需手动修改。

从源码运行：

> Release 包直接可用，普通用户无需从源码构建。开发者如需从源码重建，需要准备原版 V20 DMG（作为二进制来源）并在 macOS 上执行构建脚本。

```bash
bash build_v21_from_v20.sh
```

构建脚本会：从原版 V20 DMG 抽取 `.app` → 改 `Info.plist`（版本 20→21 + 注入版权）→ 写入 `about_inject.dylib` 与 `strings.txt` → 用壳脚本包裹 `DYLD_INSERT_LIBRARIES` → ad-hoc 重签 → 产出两份 DMG：

- `12-silent-launcher-universal.dmg`（universal arm64 + x86_64，macOS 12+）
- `10.15-silent-launcher-x86_64.dmg`（x86_64，macOS 10.15+，需 Rosetta 2）

### macOS 版本选择

- **Apple Silicon（M1 及更新）/ macOS 12+**：下载 `12-silent-launcher-universal.dmg`（原生 arm64 + x86_64）。
- **Intel Mac / macOS 10.15+**：下载 `10.15-silent-launcher-x86_64.dmg`（x86_64，在 Apple Silicon 上需 Rosetta 2）。

两份包均**未签名、未公证**（ad-hoc 签名仅用于满足 DYLD 注入），首次打开可能触发 Gatekeeper，需在「系统设置 ▸ 隐私与安全性」中允许。应用内功能在 macOS 11–15 上可用。

## English

### Highlights

- **Login silent hiding:** a LaunchAgent invokes the app with `--silent` and loops to hide checked apps' windows for a configured duration.
- **GUI management:** list apps to hide (enable/disable, add/remove, rename, edit Bundle ID), global toggle, silent duration, scan interval, and an "hide now" test.
- **Login auto-start:** "Set as login item" writes `~/Library/LaunchAgents/com.silentlauncher.login.plist` (`RunAtLoad` + `--silent`), no password needed.
- **AppleScript fallback:** when a normal `hide` fails (e.g. menu-bar apps like Hidden Bar), an AppleScript fallback force-closes the window.
- **About menu:** a dylib injects "About" and "Quit" items (the original app had no menu); the About dialog shows the version and MIT license via AppleScript.
- **First-launch permission guide:** on first launch a one-time dialog explains the required permissions and opens the system Accessibility prompt and triggers the Automation prompt.

### Required permissions

- **Accessibility (required):** to auto-hide target app windows. After granting, quit and reopen the app for it to take effect.
- **Automation (required):** to send commands to target apps to close windows. The system prompts per-app on first hide; allow all.
- **Login item:** no extra prompt; managed in System Settings ▸ General ▸ Login Items.
- **Screen Recording is NOT required.**

### Quick start

1. Download the DMG for your system from [Releases](https://github.com/hwl513782273/silent-launcher/releases/latest).
2. Drag the `.app` into Applications.
3. On first launch a permission dialog and the system Accessibility prompt appear; follow the guide to grant access.
4. Click "Set as login item"; selected windows will auto-hide at login.
5. Open the top-left menu "About" to view the version and MIT license.

> The Release builds are ready to use; ordinary users don't need to build from source. Developers who want to rebuild from source need the original V20 DMG (as the binary source) and a Mac to run the build script.

Configuration (optional):

The config file lives at `~/Library/Application Support/SilentLauncher/config.json` and stores the global toggle, silent duration, scan interval, and the list of apps to hide (`name` / `bundleID` / `enabled`). Ordinary users don't need to edit it manually.

To build:

```bash
bash build_v21_from_v20.sh
```

The script extracts the `.app` from the original V20 DMG, bumps `Info.plist` (version 20→21 + copyright), copies `about_inject.dylib` and `strings.txt`, wraps the binary with a `DYLD_INSERT_LIBRARIES` shell shim, ad-hoc re-signs, and produces two DMGs (see above).

### Choose a macOS build

- **Apple Silicon (M1 or newer) / macOS 12+:** use `12-silent-launcher-universal.dmg` (native arm64 + x86_64).
- **Intel Mac / macOS 10.15+:** use `10.15-silent-launcher-x86_64.dmg` (x86_64; needs Rosetta 2 on Apple Silicon).

Both builds are **unsigned and unnotarized** (ad-hoc signing only, to keep DYLD injection working) and may trigger Gatekeeper on first open; allow the app in System Settings ▸ Privacy & Security. In-app features work on macOS 11–15.

## 隐私与安全 / Privacy and security

- 窗口隐藏完全在本地完成，不联网、不上传任何屏幕内容或文件。/ Window hiding is fully local; the app does not connect to the network or upload any screen content or files.
- 辅助功能 / 自动化授权仅用于识别并隐藏你勾选的应用窗口，不会读取或与第三方共享数据。/ Accessibility/Automation access is used only to identify and hide the apps you selected; no data is read or shared with third parties.
- 包体未签名、未公证；首次打开可能触发 Gatekeeper，属于正常现象。/ Builds are unsigned and unnotarized; Gatekeeper warnings on first open are expected.

## 许可证 / License

**MIT License** — 作者：banqiu。

允许个人与商业免费使用、修改、再分发，须保留版权与许可证声明。完整条款见 [LICENSE](LICENSE)。

/ Released under the MIT License. Free for personal and commercial use, modification, and redistribution, provided the copyright and license notice are retained. Full text in [LICENSE](LICENSE).

## 支持 / Support

静默启动管理器免费、开源、无广告。如果它帮到了你，欢迎在 GitHub 上点个 Star，或提 Issue 反馈。/ SilentLauncher is free, open-source, and ad-free. If it helped you, a GitHub Star or an Issue is welcome.
