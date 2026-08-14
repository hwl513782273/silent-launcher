# 静默启动管理器 (SilentLauncher)

登录时自动隐藏指定应用窗口的 macOS 原生小工具。原名「开机静默启动器」，后改名为「静默启动管理器」。

> ⚠️ **关于本仓库源码**
> 原项目的 `main.swift` 在打包发布时被当作临时文件清除，本机及 Time Machine / iCloud / 外接盘 / 废纸篓 中均已找不到原件。
> 本仓库的 `main.swift` 为**按可观察行为重建版**：配置结构、`--silent` 静默隐藏循环、GUI 应用列表、AppleScript 兜底强制关闭、LaunchAgent 自启等行为均依据原版表现重建，可能与原版实现存在细节差异。

## 功能

- **静默模式（登录时）**：由 LaunchAgent 以 `--silent` 调用，在设定的持续时间内按间隔循环隐藏「已勾选应用」的窗口；普通 `hide` 无效时，用 AppleScript 兜底强制关闭（针对 Hidden Bar 这类难以隐藏的菜单栏应用）。
- **GUI 管理**：列出需隐藏的应用（勾选启用 / 增删 / 改名 / 改 Bundle ID），设置总开关、静默持续秒数、扫描间隔，可「立即隐藏」测试。
- **开机自启**：点「设为开机启动」写入 `~/Library/LaunchAgents/com.silentlauncher.login.plist`（`RunAtLoad` + `--silent`）。

## 配置

配置文件：`~/Library/Application Support/SilentLauncher/config.json`

```json
{
  "globalSilent": true,
  "finalTime": 180,
  "interval": 5,
  "apps": [
    { "id": "uuid", "name": "应用显示名", "bundleID": "com.example.app", "enabled": true }
  ]
}
```

- `globalSilent`：总开关
- `finalTime`：静默模式持续秒数（重建版假设）
- `interval`：扫描间隔秒数
- `apps`：需隐藏的应用列表（`name` 用于 AppleScript 兜底，`bundleID` 用于匹配运行中进程）

日志：`~/Library/Logs/开机静默启动器.log`（GUI / 隐藏）、`~/Library/Logs/开机静默启动器-launchd.log`（静默模式）。

## 构建

需安装 Xcode 命令行工具（`xcode-select --install`）。

```bash
bash build_1015.sh
```

脚本会：用 `swiftc` 编译 `main.swift` 为 **x86_64 @ macOS 10.15** → 组装 `.app` 并嵌入 Swift 运行时（传递闭包，含 CoreGraphics 等）→ 打包为 `10.15-静默启动管理器-V20.dmg`。
`build_1015.sh` 顶部常量可改（`APP_NAME` / `APP_VERSION` / `APP_BUNDLE_ID` / `OUT_DIR`）。

> 兼容 macOS 12+ 的 universal 包另走原生 arm64 构建（不在本脚本内），详见发行版。

## 发行包（DMG）

- `10.15-静默启动管理器-V20.dmg`（x86_64，macOS 10.15+，需 Rosetta 2）
- `12-静默启动管理器-V20.dmg`（universal，macOS 12+）

安装：把 `.app` 拖进「应用程序」，首次打开后点「设为开机启动」即可。

## 许可证

自用工具，无明确许可证。
