// main.swift — 静默启动管理器 (SilentLauncher)
//
// ⚠️ 本文件为「按行为重建版」：原项目的 main.swift 在打包时被当作临时文件清除，
//    本机及 Time Machine / iCloud / 外接盘 / 废纸篓 中均已找不到原件。
//    以下实现依据可观察到的行为重建：
//      - 配置存于 ~/Library/Application Support/SilentLauncher/config.json
//        （globalSilent 总开关、finalTime 静默持续秒数、interval 扫描间隔、apps 列表）
//      - 以 --silent 参数被 LaunchAgent 在登录时调用，循环隐藏已勾选应用的窗口；
//        普通 hide 无效时，用 AppleScript 兜底强制关闭。
//      - 不带参数启动则为 GUI，可勾选/增删/重命名应用、改设置、立即隐藏、设为开机启动。
//
// 构建：AppKit（非 SwiftUI，兼容 macOS 10.15），见 build_1015.sh。
// 入口模式：文件级语句（无 @main / 无 -parse-as-library）。

import Cocoa
import Foundation

// MARK: - 数据模型
struct AppItem: Codable {
    var id: String
    var name: String
    var bundleID: String
    var enabled: Bool
}

struct Config: Codable {
    var globalSilent: Bool
    var finalTime: Int   // 静默模式持续秒数（重建版假设；原版语义可能不同）
    var interval: Int    // 扫描间隔秒数
    var apps: [AppItem]
}

// MARK: - 路径
let supportDir = (NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first ?? "") + "/SilentLauncher"
let configPath = supportDir + "/config.json"
let mainLogPath = NSHomeDirectory() + "/Library/Logs/开机静默启动器.log"
let launchdLogPath = NSHomeDirectory() + "/Library/Logs/开机静默启动器-launchd.log"
let appVersion = "20"
let appCopyright = "Copyright © 2026 hwl513782273. 基于 MIT 许可证开源发布。"

// MARK: - 日志
func logLine(_ msg: String, to path: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    let fm = FileManager.default
    if fm.fileExists(atPath: path) {
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
        }
    } else {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - 配置读写
func defaultConfig() -> Config {
    return Config(globalSilent: true, finalTime: 180, interval: 5, apps: [])
}

func loadConfig() -> Config {
    let fm = FileManager.default
    guard fm.fileExists(atPath: configPath),
          let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
          let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
        return defaultConfig()
    }
    return cfg
}

func saveConfig(_ cfg: Config) {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(cfg) else { return }
    try? data.write(to: URL(fileURLWithPath: configPath))
    logLine("配置已保存（\(cfg.apps.count) 个应用，globalSilent=\(cfg.globalSilent)）", to: mainLogPath)
}

// MARK: - 隐藏逻辑
func hideEnabledApps() {
    let cfg = loadConfig()
    guard cfg.globalSilent else {
        logLine("globalSilent=关闭，跳过隐藏", to: mainLogPath)
        return
    }
    for app in cfg.apps where app.enabled {
        hideOne(bundleID: app.bundleID, name: app.name)
    }
}

func hideOne(bundleID: String, name: String) {
    let ws = NSWorkspace.shared
    guard let ra = ws.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
        logLine("[窗口扫描隐藏] \(name) 未运行，跳过", to: mainLogPath)
        return
    }
    let ok = ra.hide()
    if ok {
        logLine("[窗口扫描隐藏] \(name) 已隐藏", to: mainLogPath)
    } else {
        logLine("[窗口扫描隐藏] \(name) hide 失败，尝试 AppleScript 强制关闭", to: mainLogPath)
        forceClose(name: name)
    }
}

func forceClose(name: String) {
    let src = "tell application \"\(name)\"\n quit\nend tell"
    guard let script = NSAppleScript(source: src) else { return }
    var err: NSDictionary?
    script.executeAndReturnError(&err)
    if let err = err {
        logLine("[暴力关闭窗口] \(name) 失败: \(err)", to: mainLogPath)
    } else {
        logLine("[暴力关闭窗口] \(name) 已强制关闭", to: mainLogPath)
    }
}

// MARK: - 静默模式（登录时由 LaunchAgent 以 --silent 调用）
func runSilent() {
    let cfg = loadConfig()
    let duration = max(cfg.finalTime, 30)
    let interval = max(cfg.interval, 1)
    logLine("--silent 启动：持续 \(duration)s，间隔 \(interval)s", to: launchdLogPath)
    let start = Date()
    while Date().timeIntervalSince(start) < Double(duration) {
        hideEnabledApps()
        Thread.sleep(forTimeInterval: Double(interval))
    }
    logLine("--silent 结束", to: launchdLogPath)
    exit(0)
}

// MARK: - GUI
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var config = loadConfig()
    var appListStack: NSStackView!
    var globalSilentBtn: NSButton!
    var finalTimeField: NSTextField!
    var intervalField: NSTextField!
    var rows: [(item: AppItem, enabled: NSButton, name: NSTextField, bundle: NSTextField, view: NSView)] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildUI()
    }

    func buildUI() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "静默启动管理器 v\(appVersion)"
        w.center()
        let content = w.contentView!

        // 应用列表（可滚动）
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 250, width: 528, height: 320))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        appListStack = NSStackView()
        appListStack.orientation = .vertical
        appListStack.spacing = 6
        appListStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        scroll.documentView = appListStack
        content.addSubview(scroll)

        // 设置行
        globalSilentBtn = NSButton(checkboxWithTitle: "总开关：登录时静默隐藏已勾选的应用", target: self, action: #selector(toggleGlobal(_:)))
        globalSilentBtn.state = config.globalSilent ? .on : .off
        let fLabel = NSTextField(labelWithString: "静默持续(秒):")
        finalTimeField = NSTextField(string: "\(config.finalTime)")
        finalTimeField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let iLabel = NSTextField(labelWithString: "扫描间隔(秒):")
        intervalField = NSTextField(string: "\(config.interval)")
        intervalField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let settingsRow = NSStackView(views: [globalSilentBtn, fLabel, finalTimeField, iLabel, intervalField])
        settingsRow.spacing = 8
        settingsRow.setFrameOrigin(NSPoint(x: 16, y: 210))
        content.addSubview(settingsRow)

        // 按钮行
        let addBtn = NSButton(title: "+ 添加应用", target: self, action: #selector(addApp(_:)))
        let saveBtn = NSButton(title: "保存配置", target: self, action: #selector(save(_:)))
        let hideBtn = NSButton(title: "立即隐藏", target: self, action: #selector(hideNow(_:)))
        let loginBtn = NSButton(title: "设为开机启动", target: self, action: #selector(installLogin(_:)))
        let aboutBtn = NSButton(title: "关于", target: self, action: #selector(about(_:)))
        let btnRow = NSStackView(views: [addBtn, saveBtn, hideBtn, loginBtn, aboutBtn])
        btnRow.spacing = 8
        btnRow.setFrameOrigin(NSPoint(x: 16, y: 168))
        content.addSubview(btnRow)

        // 说明
        let hint = NSTextField(wrappingLabelWithString: "勾选应用后，开机时（LaunchAgent 以 --silent 调用）会自动隐藏其窗口；若普通隐藏无效则尝试强制关闭。\n应用名用于 AppleScript 兜底，Bundle ID 用于匹配运行中进程。点「设为开机启动」会把本 App 写入 LaunchAgent 实现登录自启。")
        hint.frame = NSRect(x: 16, y: 16, width: 528, height: 130)
        hint.textColor = .secondaryLabelColor
        content.addSubview(hint)

        rebuildList()
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    func rebuildList() {
        for r in rows { r.view.removeFromSuperview() }
        rows.removeAll()
        for (idx, item) in config.apps.enumerated() {
            let row = NSStackView()
            row.spacing = 6

            let en = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleItem(_:)))
            en.state = item.enabled ? .on : .off
            en.tag = idx

            let name = NSTextField(string: item.name)
            name.tag = idx
            name.target = self
            name.action = #selector(editName(_:))
            name.widthAnchor.constraint(equalToConstant: 150).isActive = true

            let bundle = NSTextField(string: item.bundleID)
            bundle.tag = idx
            bundle.target = self
            bundle.action = #selector(editBundle(_:))
            bundle.widthAnchor.constraint(equalToConstant: 210).isActive = true

            let del = NSButton(title: "✕", target: self, action: #selector(delRow(_:)))
            del.tag = idx

            row.addArrangedSubview(en)
            row.addArrangedSubview(name)
            row.addArrangedSubview(bundle)
            row.addArrangedSubview(del)
            appListStack.addArrangedSubview(row)
            rows.append((item: item, enabled: en, name: name, bundle: bundle, view: row))
        }
    }

    // MARK: actions
    @objc func toggleGlobal(_ s: NSButton) { config.globalSilent = (s.state == .on) }

    @objc func toggleItem(_ s: NSButton) {
        let i = s.tag
        guard config.apps.indices.contains(i) else { return }
        config.apps[i].enabled = (s.state == .on)
    }

    @objc func editName(_ s: NSTextField) {
        let i = s.tag
        guard config.apps.indices.contains(i) else { return }
        config.apps[i].name = s.stringValue
    }

    @objc func editBundle(_ s: NSTextField) {
        let i = s.tag
        guard config.apps.indices.contains(i) else { return }
        config.apps[i].bundleID = s.stringValue
    }

    @objc func delRow(_ s: NSButton) {
        let i = s.tag
        guard config.apps.indices.contains(i) else { return }
        config.apps.remove(at: i)
        rebuildList()
    }

    @objc func addApp(_ s: NSButton) {
        config.apps.append(AppItem(id: UUID().uuidString, name: "新应用", bundleID: "com.example.app", enabled: true))
        rebuildList()
    }

    @objc func save(_ s: NSButton) {
        config.globalSilent = (globalSilentBtn.state == .on)
        config.finalTime = Int(finalTimeField.stringValue) ?? config.finalTime
        config.interval = Int(intervalField.stringValue) ?? config.interval
        saveConfig(config)
    }

    @objc func hideNow(_ s: NSButton) { hideEnabledApps() }

    @objc func installLogin(_ s: NSButton) {
        let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.silentlauncher.login.plist"
        let bin = "/Applications/静默启动管理器.app/Contents/MacOS/静默启动管理器"
        let dict: [String: Any] = [
            "Label": "com.silentlauncher.login",
            "ProgramArguments": [bin, "--silent"],
            "RunAtLoad": true,
            "StandardOutPath": launchdLogPath,
            "StandardErrorPath": launchdLogPath
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else { return }
        try? data.write(to: URL(fileURLWithPath: plistPath))
        logLine("已写入 LaunchAgent: \(plistPath)", to: mainLogPath)
        _ = try? Process.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: ["load", "-w", plistPath])
    }

    @objc func about(_ s: NSButton) {
        let a = NSAlert()
        a.messageText = "静默启动管理器 v\(appVersion)"
        a.informativeText = """
        登录时自动隐藏指定应用窗口。
        本源码为按行为重建版（原 main.swift 已遗失）。

        \(appCopyright)
        开源许可证：MIT
        仓库：https://github.com/hwl513782273/silent-launcher
        """
        a.runModal()
    }
}

// MARK: - 入口
if CommandLine.arguments.contains("--silent") {
    runSilent()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
