import Foundation
import AppKit

// MARK: - 进程执行

enum Shell {
    struct Result {
        var status: Int32
        var out: String
        var err: String
        var ok: Bool { status == 0 }
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch {
            return Result(status: -1, out: "", err: error.localizedDescription)
        }

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        return Result(status: process.terminationStatus,
                      out: String(data: outData, encoding: .utf8) ?? "",
                      err: String(data: errData, encoding: .utf8) ?? "")
    }
}

// MARK: - 卸载引擎

enum Uninstaller {

    static let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    // MARK: 对外入口

    static func run(items: [(app: InstalledApp, leftovers: [Leftover])],
                    options: UninstallOptions,
                    progress: @escaping (String) -> Void,
                    completion: @escaping (UninstallReport) -> Void) {

        DispatchQueue.global(qos: .userInitiated).async {
            let report = perform(items: items, options: options, progress: progress)
            DispatchQueue.main.async { completion(report) }
        }
    }

    /// 只清理残留（不涉及 App 本体），用于「残留清理」页面
    static func removeOrphans(_ targets: [Leftover],
                              options: UninstallOptions,
                              progress: @escaping (String) -> Void,
                              completion: @escaping (UninstallReport) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let report = perform(items: [], extraTargets: targets, options: options, progress: progress)
            DispatchQueue.main.async { completion(report) }
        }
    }

    // MARK: 执行

    static func perform(items: [(app: InstalledApp, leftovers: [Leftover])],
                        extraTargets: [Leftover] = [],
                        options: UninstallOptions,
                        progress: @escaping (String) -> Void,
                        home: String = NSHomeDirectory()) -> UninstallReport {

        var entries: [LogEntry] = []
        var adminQueue: [(url: URL, label: String, size: Int64)] = []
        var failureDetails: [String: String] = [:]
        var freed: Int64 = 0
        var failures = 0
        var trashed = false
        var protectionDenied = false
        let hasFDA = FullDiskAccess.isGranted

        func handleTarget(_ target: Leftover) {
            progress("正在清理 \(target.name)…")

            if target.kind == .launchAgent || target.kind == .launchDaemon {
                bootout(target)
            }

            if isProtected(target.url, home: home) {
                failures += 1
                entries.append(LogEntry(ok: false, text: "跳过受保护路径", detail: target.url.path))
                return
            }

            var userLevelError: String?
            if !target.requiresAdmin {
                userLevelError = removeNow(target.url, permanent: options.permanent, home: home)
            }
            if !target.requiresAdmin, userLevelError == nil {
                freed += target.size
                if !options.permanent { trashed = true }
                entries.append(LogEntry(ok: true,
                                        text: "删除 \(target.name)",
                                        detail: abbreviatePath(target.url.path, home: home)))
            } else if target.requiresAdmin || target.kind == .appBundle || !isParentWritable(target.url) {
                // App 本体受 macOS「App 管理」权限保护，被拒时退回管理员方式
                adminQueue.append((target.url, target.name, target.size))
            } else if isContainerTarget(target), !hasFDA {
                // 容器受 TCC 保护，root 也绕不过，必须用户授予完全磁盘访问权限
                failures += 1
                let reason = userLevelError ?? "系统拒绝访问"
                entries.append(LogEntry(ok: false, text: "删除失败 \(target.name)",
                                        detail: "\(reason)：需要「完全磁盘访问权限」才能清理容器"))
                protectionDenied = true
            } else if options.adminFallback {
                // 其他被拒绝的项目（如 /Applications 下受 App 管理的 App）交给管理员重试
                if let error = userLevelError { failureDetails[target.url.path] = error }
                adminQueue.append((target.url, target.name, target.size))
            } else {
                failures += 1
                let reason = userLevelError ?? "未知原因"
                entries.append(LogEntry(ok: false, text: "删除失败 \(target.name)",
                                        detail: "\(reason)：\(abbreviatePath(target.url.path, home: home))"))
            }
        }

        for item in items {
            let app = item.app
            progress("正在退出 \(app.name)…")

            // 1. 退出正在运行的 App 及其子进程
            if options.quitRunning {
                let running = runningProcesses(for: app)
                if !running.isEmpty {
                    let quit = quitApp(app, pids: running)
                    if quit {
                        entries.append(LogEntry(ok: true, text: "已退出 \(app.name)"))
                    } else {
                        failures += 1
                        entries.append(LogEntry(ok: false, text: "无法退出 \(app.name)，已跳过",
                                                detail: "仍有进程占用，请手动退出后重试"))
                        continue
                    }
                }
            }

            // 2. 清理注册类信息（LaunchServices / TCC / 包收据）
            if options.cleanRegistration {
                if let bid = app.bundleID, !bid.isEmpty {
                    let reg = Shell.run(lsregisterPath, ["-u", app.path])
                    entries.append(LogEntry(ok: reg.ok, text: "注销 LaunchServices 记录",
                                            detail: reg.ok ? bid : (reg.err.isEmpty ? bid : reg.err)))
                    let tcc = Shell.run("/usr/bin/tccutil", ["reset", "All", bid])
                    if tcc.ok {
                        entries.append(LogEntry(ok: true, text: "重置 TCC 隐私权限", detail: bid))
                    } else if !(tcc.err.contains("-10814") || tcc.err.contains("No such bundle identifier")) {
                        entries.append(LogEntry(ok: false, text: "重置 TCC 隐私权限失败", detail: tcc.err))
                    }
                    // -10814：该 App 从未申请过隐私权限，属于正常情况，不记为异常
                }
            }

            // 3. App 本体 + 用户勾选的残留
            var targets: [Leftover] = item.leftovers
            if !options.removeSystemLeftovers { targets = targets.filter { !$0.requiresAdmin } }
            targets.insert(Leftover(url: app.url, kind: .appBundle, size: app.size,
                                    requiresAdmin: !isParentWritable(app.url), confidence: .high),
                           at: 0)

            for target in targets { handleTarget(target) }
        }

        if !extraTargets.isEmpty {
            progress("正在清理残留…")
            for target in extraTargets { handleTarget(target) }
        }

        // 4. 需要 root 的部分合并成一次授权
        adminQueue = adminQueue.filter { !isProtected($0.url, home: home) }
        if !adminQueue.isEmpty {
            progress("需要管理员权限，请在弹出的系统窗口中输入密码…")
            let queue = adminQueue.map { (url: $0.url, label: $0.label) }
            let script = makeAdminScript(targets: queue, permanent: options.permanent, home: home)
            let result = runPrivileged(script)

            if result.ok {
                for target in adminQueue {
                    if !FileManager.default.fileExists(atPath: target.url.path) {
                        freed += target.size
                        entries.append(LogEntry(ok: true, text: "删除 \(target.label)（管理员）",
                                                detail: abbreviatePath(target.url.path, home: home)))
                        if !options.permanent { trashed = true }
                    } else {
                        failures += 1
                        let reason = failureDetails[target.url.path] ?? "文件仍存在，可能被系统保护"
                        if reason.contains("not permitted") || reason.contains("拒绝访问") { protectionDenied = true }
                        entries.append(LogEntry(ok: false, text: "删除失败 \(target.label)",
                                                detail: "\(reason)（管理员权限仍不足）：\(abbreviatePath(target.url.path, home: home))"))
                    }
                }
            } else {
                failures += 1
                let cancelled = result.err.contains("-128") || result.err.contains("User canceled")
                entries.append(LogEntry(ok: false,
                                        text: cancelled ? "已取消管理员授权" : "管理员操作失败",
                                        detail: cancelled ? "未删除 \(adminQueue.count) 个需要授权的项目"
                                                          : result.err.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }

        var hint: String?
        if protectionDenied {
            hint = hasFDA
                ? "部分容器仍被系统拒绝：请确认对应 App 已完全退出，或重启后再试。"
                : "部分容器受 macOS 保护：请在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」中勾选本 App，然后重新卸载。"
        }
        let report = UninstallReport(appCount: items.count,
                                     freed: freed,
                                     failures: failures,
                                     entries: entries,
                                     trashedSomething: trashed,
                                     hint: hint)
        DispatchQueue.main.async {
            NSWorkspace.shared.noteFileSystemChanged(home)
        }
        return report
    }

    // MARK: 进程

    static func runningProcesses(for app: InstalledApp) -> [pid_t] {
        var pids = Set<pid_t>()
        if let bid = app.bundleID, !bid.isEmpty {
            for running in NSRunningApplication.runningApplications(withBundleIdentifier: bid) {
                pids.insert(running.processIdentifier)
            }
        }
        let result = Shell.run("/bin/ps", ["-axo", "pid=,command="])
        let bundlePrefix = app.path + "/"
        let selfPID = ProcessInfo.processInfo.processIdentifier
        for line in result.out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = pid_t(trimmed[..<space]), pid != selfPID else { continue }
            let command = String(trimmed[trimmed.index(after: space)...])
            if command.contains(bundlePrefix) { pids.insert(pid) }
        }
        return Array(pids)
    }

    static func quitApp(_ app: InstalledApp, pids: [pid_t]) -> Bool {
        var runningApps: [NSRunningApplication] = []
        if let bid = app.bundleID, !bid.isEmpty {
            runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
        }
        runningApps.forEach { $0.terminate() }

        for _ in 0..<20 {
            usleep(150_000)
            let stillRunning = runningApps.contains { !$0.isTerminated }
            let pidsAlive = pids.filter { kill($0, 0) == 0 }
            if !stillRunning && pidsAlive.isEmpty { return true }
        }

        runningApps.forEach { $0.forceTerminate() }
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }

        for _ in 0..<12 {
            usleep(150_000)
            let alive = pids.filter { kill($0, 0) == 0 }
            if alive.isEmpty { return true }
        }
        return pids.allSatisfy { kill($0, 0) != 0 }
    }

    static func bootout(_ leftover: Leftover) {
        guard leftover.name.hasSuffix(".plist") else { return }
        if leftover.kind == .launchAgent {
            Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())", leftover.url.path])
        } else if leftover.kind == .launchDaemon {
            Shell.run("/bin/launchctl", ["bootout", "system", leftover.url.path])
        }
    }

    // MARK: 文件删除

    /// 是否位于其他 App 的沙盒容器内（这类路径受 TCC 保护）
    static func isContainerTarget(_ target: Leftover) -> Bool {
        if target.kind == .container || target.kind == .groupContainer { return true }
        let path = target.url.path
        return path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/")
    }

    static func isParentWritable(_ url: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }

    /// 绝不允许删除这些目录本身（防止匹配规则出 bug 时误伤）
    static func isProtected(_ url: URL, home: String = NSHomeDirectory()) -> Bool {
        let path = url.standardizedFileURL.path
        let protected: Set<String> = [
            "/", "/Applications", "/Library", "/System", "/Users", "/private", "/private/var",
            "/private/var/db", "/private/var/db/receipts", "/usr", "/etc", "/var", "/tmp",
            home, home + "/Library", home + "/Library/Caches", home + "/Library/Preferences",
            home + "/Library/Containers", home + "/Library/Group Containers",
            home + "/Library/Application Support", home + "/Desktop", home + "/Documents",
            home + "/Downloads", home + "/.Trash"
        ]
        return protected.contains(path) || path.count < 5
    }

    /// 返回 nil 表示删除成功，否则返回可读的错误原因
    static func removeNow(_ url: URL, permanent: Bool, home: String = NSHomeDirectory()) -> String? {
        let fm = FileManager.default
        guard !isProtected(url, home: home) else { return "受保护路径，已跳过" }
        guard fm.fileExists(atPath: url.path) else { return nil }
        do {
            if permanent {
                try fm.removeItem(at: url)
            } else {
                var resulting: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &resulting)
            }
            return nil
        } catch {
            // trashItem 在某些受保护条目上会失败，退一步自己 rename 进废纸篓
            if !permanent {
                let destination = uniqueTrashDestination(for: url.lastPathComponent, home: home, used: [])
                if (try? fm.moveItem(at: url, to: URL(fileURLWithPath: destination))) != nil {
                    return nil
                }
            }
            return describe(error)
        }
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            if underlying.domain == NSPOSIXErrorDomain {
                switch underlying.code {
                case 1: return "系统拒绝访问（Operation not permitted）"
                case 13: return "没有权限（Permission denied）"
                case 16: return "文件正被占用（Resource busy）"
                default: break
                }
            }
            return underlying.localizedDescription
        }
        return ns.localizedDescription
    }

    // MARK: 管理员脚本

    static func uniqueTrashDestination(for name: String, home: String, used: Set<String>) -> String {
        let trash = home + "/.Trash"
        let fm = FileManager.default
        var candidate = trash + "/" + name
        var index = 2
        while fm.fileExists(atPath: candidate) || used.contains(candidate) {
            candidate = trash + "/" + name + " \(index)"
            index += 1
            if index > 500 { break }
        }
        return candidate
    }

    static func makeAdminScript(targets: [(url: URL, label: String)], permanent: Bool, home: String) -> String {
        var lines = ["#!/bin/bash", "set -u"]
        if !permanent {
            lines.append("/bin/mkdir -p \(shellQuote(home + "/.Trash"))")
        }
        var used = Set<String>()
        for target in targets {
            if isProtected(target.url, home: home) { continue }
            if permanent {
                lines.append("/bin/rm -rf -- \(shellQuote(target.url.path))")
            } else {
                let dest = uniqueTrashDestination(for: target.url.lastPathComponent, home: home, used: used)
                used.insert(dest)
                lines.append("/bin/mv -f -- \(shellQuote(target.url.path)) \(shellQuote(dest))")
            }
        }
        lines.append("exit 0")
        return lines.joined(separator: "\n") + "\n"
    }

    static func runPrivileged(_ script: String) -> Shell.Result {
        let path = NSTemporaryDirectory() + "appuninstaller-\(UUID().uuidString).sh"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        } catch {
            return Shell.Result(status: -1, out: "", err: error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(atPath: path) }

        let command = "do shell script \"/bin/bash " + path.replacingOccurrences(of: "\"", with: "\\\"") + "\" with administrator privileges"
        return Shell.run("/usr/bin/osascript", ["-e", command])
    }

    // MARK: 计划（dry-run，供 CLI 与界面预览）

    static func plan(items: [(app: InstalledApp, leftovers: [Leftover])], options: UninstallOptions) -> [String] {
        var lines: [String] = []
        let hasFDA = FullDiskAccess.isGranted
        for item in items {
            let app = item.app
            lines.append("▸ \(app.name)  [\(app.bundleID ?? "无 Bundle ID")]")
            var targets = item.leftovers
            if !options.removeSystemLeftovers { targets = targets.filter { !$0.requiresAdmin } }
            let bundleAdmin = !isParentWritable(app.url)
            lines.append("   \(bundleAdmin ? "[管理员] " : "")删除 App 本体  \(abbreviatePath(app.path))  (\(formatBytes(app.size)))")
            for target in targets {
                var who = target.requiresAdmin ? "[管理员] " : ""
                if isContainerTarget(target), !hasFDA { who = "[需完全磁盘访问] " }
                lines.append("   \(who)删除 \(target.kind.title)  \(abbreviatePath(target.url.path))  (\(formatBytes(target.size)))")
            }
            if options.cleanRegistration, let bid = app.bundleID {
                lines.append("   注销 LaunchServices / TCC  \(bid)")
            }
        }
        return lines
    }
}
