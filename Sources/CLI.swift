import Foundation

// MARK: - 命令行自检 / 调试入口
// 用法：
//   AppUninstaller --scan [--json]            扫描 App 列表
//   AppUninstaller --leftovers <App 路径> [--json] [--home <dir>]
//   AppUninstaller --plan <App 路径> [--permanent] [--no-system]
//   AppUninstaller --selftest                 运行内置匹配规则自测

enum CLI {

    static func run(_ args: [String]) -> Int32 {
        var mode = "help"
        var json = false
        var target: String?
        var home = NSHomeDirectory()
        var permanent = false
        var includeSystem = true
        var confirmed = false
        var registration = true

        var index = 1
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--scan":
                mode = "scan"
            case "--leftovers":
                mode = "leftovers"
                if index + 1 < args.count { index += 1; target = args[index] }
            case "--plan":
                mode = "plan"
                if index + 1 < args.count { index += 1; target = args[index] }
            case "--selftest":
                mode = "selftest"
            case "--fda":
                mode = "fda"
            case "--orphans":
                mode = "orphans"
            case "--json":
                json = true
            case "--home":
                if index + 1 < args.count { index += 1; home = args[index] }
            case "--permanent":
                permanent = true
            case "--yes":
                confirmed = true
            case "--no-registration":
                registration = false
            case "--uninstall":
                mode = "uninstall"
                if index + 1 < args.count { index += 1; target = args[index] }
            case "--no-system":
                includeSystem = false
            case "--help", "-h":
                mode = "help"
            default:
                break
            }
            index += 1
        }

        switch mode {
        case "scan":
            return scanJSON(json: json)
        case "leftovers":
            guard let target else { print("缺少 App 路径"); return 2 }
            return leftovers(target: target, json: json, home: home)
        case "plan":
            guard let target else { print("缺少 App 路径"); return 2 }
            let options = UninstallOptions(quitRunning: true,
                                           removeSystemLeftovers: includeSystem,
                                           cleanRegistration: true,
                                           permanent: permanent)
            return plan(target: target, options: options, home: home)
        case "uninstall":
            guard let target else { print("缺少 App 路径"); return 2 }
            guard confirmed else { print("需要 --yes 确认执行删除"); return 3 }
            let options = UninstallOptions(quitRunning: true,
                                           removeSystemLeftovers: includeSystem,
                                           cleanRegistration: registration,
                                           permanent: permanent)
            return uninstall(target: target, options: options, home: home)
        case "fda":
            print(FullDiskAccess.isGranted ? "完全磁盘访问权限：已授权" : "完全磁盘访问权限：未授权")
            return 0
        case "orphans":
            return listOrphans(json: json)
        case "selftest":
            return SelfTest.run()
        default:
            print("""
            应用卸载器 (AppUninstaller)

            无参数运行会打开图形界面；以下参数用于调试：
              --scan [--json]                     扫描并列出 App
              --leftovers <App.app> [--json]      列出某个 App 的关联残留
              --home <dir>                        覆盖 HOME（测试用）
              --plan <App.app> [--permanent]      打印卸载计划（不会真正删除）
              --selftest                          运行内置自测
              --fda                               查看完全磁盘访问权限状态
              --orphans [--json]                  列出找不到对应 App 的残留容器
            """)
            return 0
        }
    }

    // MARK: 扫描

    static func scanJSON(json: Bool) -> Int32 {
        let apps = AppScanner.scan(progress: { text in
            FileHandle.standardError.write(("[scan] " + text + "\n").data(using: .utf8)!)
        })
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(apps), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            return 0
        }
        print(String(format: "%-42@ %10@ %@", "名称" as NSString, "体积" as NSString, "Bundle ID" as NSString))
        var total: Int64 = 0
        for app in apps {
            total += app.size
            let name = app.name.count > 40 ? String(app.name.prefix(38)) + "…" : app.name
            print(String(format: "%-42@ %10@ %@", name as NSString, formatBytes(app.size) as NSString, (app.bundleID ?? "-") as NSString))
        }
        print("共 \(apps.count) 个 App，合计 \(formatBytes(total))")
        return 0
    }

    // MARK: 残留

    static func leftovers(target: String, json: Bool, home: String) -> Int32 {
        let url = URL(fileURLWithPath: target)
        guard let app = AppScanner.makeApp(at: url) else {
            print("无法读取 App：\(target)")
            return 2
        }
        let found = LeftoverFinder.find(for: app, home: home)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(found), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            return 0
        }
        print("\(app.name)  \(app.bundleID ?? "-")")
        for item in found {
            let flag = item.requiresAdmin ? "[管理员]" : ""
            print("  \(flag)[\(item.kind.title)] \(abbreviatePath(item.url.path))  \(formatBytes(item.size))  \(item.confidence)")
        }
        print("共 \(found.count) 项，\(formatBytes(found.reduce(0) { $0 + $1.size }))")
        return 0
    }

    // MARK: 孤儿残留

    static func listOrphans(json: Bool) -> Int32 {
        let apps = AppScanner.scan(progress: { text in
            FileHandle.standardError.write(("[scan] " + text + "\n").data(using: .utf8)!)
        })
        let items = OrphanScanner.scan(apps: apps) { text in
            FileHandle.standardError.write(("[orphan] " + text + "\n").data(using: .utf8)!)
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(items), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            return 0
        }
        for item in items {
            let flag = item.confidence == .high ? "  " : "? "
            print(String(format: "%@%10@  %@", flag, formatBytes(item.size) as NSString, abbreviatePath(item.url.path) as NSString))
        }
        print("共 \(items.count) 项，\(formatBytes(items.reduce(0) { $0 + $1.size }))")
        return 0
    }

    // MARK: 实际卸载（自测用）

    static func uninstall(target: String, options: UninstallOptions, home: String) -> Int32 {
        let url = URL(fileURLWithPath: target)
        guard let app = AppScanner.makeApp(at: url) else {
            print("无法读取 App：\(target)")
            return 2
        }
        let found = LeftoverFinder.find(for: app, home: home)
        let report = Uninstaller.perform(items: [(app, found)],
                                         options: options,
                                         progress: { print("· \($0)") },
                                         home: home)
        for entry in report.entries {
            print("\(entry.ok ? "✓" : "✗") \(entry.text)" + (entry.detail.map { "  — \($0)" } ?? ""))
        }
        print("释放 \(formatBytes(report.freed))，异常 \(report.failures) 项")
        return report.failures == 0 ? 0 : 4
    }

    // MARK: 计划

    static func plan(target: String, options: UninstallOptions, home: String) -> Int32 {
        let url = URL(fileURLWithPath: target)
        guard let app = AppScanner.makeApp(at: url) else {
            print("无法读取 App：\(target)")
            return 2
        }
        let found = LeftoverFinder.find(for: app, home: home)
        let lines = Uninstaller.plan(items: [(app, found)], options: options)
        print(lines.joined(separator: "\n"))
        print("\n提示：这是 dry-run，未删除任何文件。")
        return 0
    }
}

// MARK: - 内置自测

enum SelfTest {

    static func run() -> Int32 {
        var failures = 0
        let fm = FileManager.default
        let base = fm.currentDirectoryPath + "/.selftest"
        try? fm.removeItem(atPath: base)
        do {
            try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        } catch {
            print("✗ 无法创建测试目录: \(error)")
            return 1
        }
        defer { try? fm.removeItem(atPath: base) }

        func makeDir(_ path: String) {
            try? fm.createDirectory(atPath: base + "/" + path, withIntermediateDirectories: true)
        }
        func writeFile(_ path: String, _ content: String) {
            let full = base + "/" + path
            try? fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? content.write(toFile: full, atomically: true, encoding: .utf8)
        }

        // 1. 构造假 App
        let bundle = base + "/Apps/FooApp.app"
        makeDir("Apps/FooApp.app/Contents/MacOS")
        writeFile("Apps/FooApp.app/Contents/Info.plist", plist(bundleID: "com.example.fooapp", name: "FooApp"))
        writeFile("Apps/FooApp.app/Contents/MacOS/FooApp", String(repeating: "x", count: 4096))

        // 2. 构造关联文件
        makeDir("Library/Caches/com.example.fooapp")
        writeFile("Library/Caches/com.example.fooapp/blob.bin", String(repeating: "y", count: 2048))
        writeFile("Library/Preferences/com.example.fooapp.plist", "plist")
        makeDir("Library/Containers/com.example.fooapp")
        makeDir("Library/Application Support/FooApp")
        writeFile("Library/LaunchAgents/com.example.fooapp.agent.plist", "plist")
        makeDir("Library/Caches/com.unrelated.other")

        let scanned = AppScanner.scan(roots: [URL(fileURLWithPath: base + "/Apps")])
        if scanned.count == 1, scanned[0].bundleID == "com.example.fooapp", scanned[0].size > 0 {
            print("✓ 扫描：找到 \(scanned[0].name) (\(scanned[0].bundleID!)), \(formatBytes(scanned[0].size))")
        } else {
            print("✗ 扫描失败：\(scanned)")
            failures += 1
        }

        guard let app = scanned.first else {
            print("✗ 无法继续，扫描结果为空")
            return 1
        }

        let found = LeftoverFinder.find(for: app, home: base)
        let paths = found.map { $0.url.path }
        let expected = [
            base + "/Library/Caches/com.example.fooapp",
            base + "/Library/Preferences/com.example.fooapp.plist",
            base + "/Library/Containers/com.example.fooapp",
            base + "/Library/Application Support/FooApp",
            base + "/Library/LaunchAgents/com.example.fooapp.agent.plist"
        ]
        for path in expected {
            if paths.contains(path) {
                print("✓ 匹配残留：\(abbreviatePath(path, home: base))")
            } else {
                print("✗ 漏掉残留：\(abbreviatePath(path, home: base))")
                failures += 1
            }
        }
        if paths.contains(base + "/Library/Caches/com.unrelated.other") {
            print("✗ 误匹配无关目录")
            failures += 1
        } else {
            print("✓ 未误匹配无关目录")
        }

        // 3. 孤儿容器识别
        makeDir("Library/Containers/com.example.fooapp")
        makeDir("Library/Containers/com.example.goneapp")
        makeDir("Library/Group Containers/ABCDE12345.group.com.example.goneapp")
        makeDir("Library/Containers/com.apple.Safari")   // 系统项应忽略
        makeDir("Library/Containers/NotABundleName")     // 非反向域名应忽略
        let orphans = OrphanScanner.scan(apps: [app], home: base)
        let orphanNames = Set(orphans.map { $0.url.lastPathComponent })
        if orphanNames.contains("com.example.goneapp"),
           orphanNames.contains("ABCDE12345.group.com.example.goneapp"),
           !orphanNames.contains("com.example.fooapp"),
           !orphanNames.contains("com.apple.Safari"),
           !orphanNames.contains("NotABundleName") {
            print("✓ 孤儿容器识别正确（\(orphans.count) 项）")
        } else {
            print("✗ 孤儿容器识别异常：\(orphanNames)")
            failures += 1
        }

        // 4. 计划输出
        let plan = Uninstaller.plan(items: [(app, found)], options: UninstallOptions())
        if plan.joined().contains("FooApp") {
            print("✓ dry-run 计划生成成功（\(plan.count) 行）")
        } else {
            print("✗ dry-run 计划异常")
            failures += 1
        }

        // 5. 管理员脚本与路径保护
        let badPath = URL(fileURLWithPath: base + "/Library/Caches/'quote test")
        let script = Uninstaller.makeAdminScript(targets: [(badPath, "quote")], permanent: true, home: base)
        if script.contains("'\\''") {
            print("✓ shell 引号转义正确")
        } else {
            print("✗ shell 引号转义异常：\(script)")
            failures += 1
        }
        let protectedURL = URL(fileURLWithPath: base + "/Library/Caches")
        if Uninstaller.isProtected(protectedURL, home: base), Uninstaller.removeNow(protectedURL, permanent: true, home: base) != nil {
            print("✓ 受保护目录不会被删除")
        } else {
            print("✗ 受保护目录保护失败")
            failures += 1
        }

        print(failures == 0 ? "\n全部自测通过" : "\n自测失败 \(failures) 项")
        return failures == 0 ? 0 : 1
    }

    static func plist(bundleID: String, name: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key><string>\(bundleID)</string>
            <key>CFBundleName</key><string>\(name)</string>
            <key>CFBundleShortVersionString</key><string>1.2.3</string>
            <key>CFBundleExecutable</key><string>\(name)</string>
        </dict>
        </plist>
        """
    }
}
