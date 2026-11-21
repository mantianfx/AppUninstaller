import AppKit
import SwiftUI
import Combine

// MARK: - 入口

let arguments = CommandLine.arguments

if arguments.count > 2, arguments[1] == "--render-ui" {
    let mode = arguments.count > 4 && arguments[3] == "--sheet" ? arguments[4] : "main"
    exit(Snapshot.render(to: arguments[2], mode: mode))
}
if arguments.count > 1, arguments[1].hasPrefix("--") {
    exit(CLI.run(arguments))
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow?
    private let state = AppState()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        let rootView = ContentView().environmentObject(state)
        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: controller)
        window.title = "应用卸载器"
        window.setContentSize(NSSize(width: 1140, height: 740))
        window.minSize = NSSize(width: 980, height: 640)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        window.setFrameAutosaveName("MainWindowFrame")
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        self.window = window

        // 卸载过程中禁止关闭窗口，避免删到一半被中断
        state.$isUninstalling
            .receive(on: RunLoop.main)
            .sink { [weak self] running in
                self?.window?.standardWindowButton(.closeButton)?.isEnabled = !running
            }
            .store(in: &cancellables)

        NSApp.activate(ignoringOtherApps: true)
        state.refresh()

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            self?.state.refreshPermissions()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard state.isUninstalling else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "正在卸载"
        alert.informativeText = "卸载尚未完成，请等待进度条结束再退出，否则可能留下删了一半的文件。"
        alert.alertStyle = .warning
        alert.runModal()
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    @objc private func menuRefresh() {
        state.refresh()
    }

    @objc private func menuSearch() {
        state.requestSearchFocus()
    }

    @objc private func menuOpenFDA() {
        FullDiskAccess.openSettings()
    }

    @objc private func menuOrphans() {
        state.openOrphanSheet()
    }

    @objc private func menuUninstall() {
        state.beginUninstall()
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "应用卸载器")
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 应用卸载器",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 应用卸载器",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他",
                                        action: #selector(NSApplication.hideOtherApplications(_:)),
                                        keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 应用卸载器",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")

        let actionMenuItem = NSMenuItem()
        mainMenu.addItem(actionMenuItem)
        let actionMenu = NSMenu(title: "操作")
        actionMenuItem.submenu = actionMenu
        let refreshItem = actionMenu.addItem(withTitle: "重新扫描", action: #selector(menuRefresh), keyEquivalent: "r")
        refreshItem.target = self
        let searchItem = actionMenu.addItem(withTitle: "搜索", action: #selector(menuSearch), keyEquivalent: "f")
        searchItem.target = self
        actionMenu.addItem(.separator())
        let fdaItem = actionMenu.addItem(withTitle: "完全磁盘访问权限…", action: #selector(menuOpenFDA), keyEquivalent: "")
        fdaItem.target = self
        actionMenu.addItem(.separator())
        let uninstallItem = actionMenu.addItem(withTitle: "卸载所选…", action: #selector(menuUninstall), keyEquivalent: "\u{8}")
        uninstallItem.keyEquivalentModifierMask = [.command, .shift]
        uninstallItem.target = self

        let orphanItem = actionMenu.addItem(withTitle: "残留清理…", action: #selector(menuOrphans), keyEquivalent: "o")
        orphanItem.keyEquivalentModifierMask = [.command, .shift]
        orphanItem.target = self

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
