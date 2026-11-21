import AppKit
import SwiftUI

// MARK: - 界面离屏快照（开发自检用）
// 用法：AppUninstaller --render-ui /path/to/out.png

enum Snapshot {

    static func render(to path: String, mode: String = "main") -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let state = AppState()
        state.refresh()
        wait(until: { !state.isScanning }, timeout: 90)

        if mode == "report" {
            return renderReport(to: path)
        }

        let rootView: AnyView
        var size = NSSize(width: 1140, height: 740)
        if mode == "orphans" {
            state.scanOrphans()
            wait(until: { !state.orphanLoading }, timeout: 180)
            rootView = AnyView(OrphanSheet().environmentObject(state))
            size = NSSize(width: 660, height: 560)
        } else if mode == "confirm" {
            for app in state.apps.filter({ !$0.isSystem }).prefix(2) {
                state.setSelected(app, true)
                state.loadLeftovers(for: app)
            }
            let ids = state.selection
            wait(until: { ids.allSatisfy { state.leftovers[$0] != nil } }, timeout: 60)
            rootView = AnyView(ConfirmSheet().environmentObject(state))
            size = NSSize(width: 620, height: 540)
        } else {
            rootView = AnyView(ContentView().environmentObject(state))
        }

        let wrapped = AnyView(rootView.background(Color(nsColor: .windowBackgroundColor)))
        let host = NSHostingController(rootView: wrapped)
        let window = NSWindow(contentViewController: host)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor.windowBackgroundColor
        window.setContentSize(size)
        window.styleMask = [.titled, .resizable]
        window.title = "应用卸载器"
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()

        if mode == "main" {
            if let target = state.apps.first(where: { $0.name.contains("Bitwarden") }) ?? state.apps.first(where: { !$0.isSystem }) {
                state.focus = target.id
                state.loadLeftovers(for: target)
                wait(until: { state.leftovers[target.id] != nil }, timeout: 60)
            }
            if let other = state.apps.first(where: { $0.name.contains("IINA") }) {
                state.setSelected(other, true)
            }
            for app in state.apps.filter({ !$0.isSystem }).prefix(2) {
                state.setSelected(app, true)
            }
        }

        // 给 SwiftUI 一点时间完成布局与绘制
        pump(1.2)
        window.contentView?.layoutSubtreeIfNeeded()

        return capture(window: window, to: path)
    }

    private static func renderReport(to path: String) -> Int32 {
        let entries: [LogEntry] = [
            LogEntry(ok: true, text: "已退出 Bitwarden"),
            LogEntry(ok: true, text: "注销 LaunchServices 记录", detail: "com.bitwarden.desktop"),
            LogEntry(ok: true, text: "重置 TCC 隐私权限", detail: "com.bitwarden.desktop"),
            LogEntry(ok: true, text: "删除 Bitwarden.app", detail: "~/Applications/Bitwarden.app"),
            LogEntry(ok: true, text: "删除 com.bitwarden.desktop", detail: "~/Library/Caches/com.bitwarden.desktop"),
            LogEntry(ok: true, text: "删除 com.bitwarden.desktop", detail: "~/Library/Preferences/com.bitwarden.desktop.plist"),
            LogEntry(ok: false, text: "删除 Bitwarden Helper", detail: "文件仍存在，可能被系统保护"),
            LogEntry(ok: true, text: "删除 LTZ2PFU5D6.com.bitwarden.desktop", detail: "~/Library/Group Containers/LTZ2PFU5D6.com.bitwarden.desktop")
        ]
        let report = UninstallReport(appCount: 2, freed: 1_062_000_000, failures: 1,
                                     entries: entries, trashedSomething: true)
        let host = NSHostingController(rootView: ReportSheet(report: report).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentViewController: host)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor.windowBackgroundColor
        window.setContentSize(NSSize(width: 620, height: 520))
        window.styleMask = [.titled]
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        pump(0.8)
        return capture(window: window, to: path)
    }

    private static func capture(window: NSWindow, to path: String) -> Int32 {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return 1 }
        try? data.write(to: URL(fileURLWithPath: path))
        print("已保存快照：\(path)")
        return 0
    }

    private static func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private static func wait(until condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
