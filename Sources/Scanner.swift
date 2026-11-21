import Foundation
import AppKit
import Security

// MARK: - 扫描已安装的 App

enum AppScanner {

    /// 扫描根目录：系统中所有常见 App 安装位置
    static func defaultRoots() -> [URL] {
        let home = NSHomeDirectory()
        let candidates = [
            "/Applications",
            "/Applications/Utilities",
            home + "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities"
        ]
        var roots: [URL] = []
        var seen = Set<String>()
        for path in candidates {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            let key = (path as NSString).standardizingPath
            if seen.insert(key).inserted { roots.append(URL(fileURLWithPath: key)) }
        }
        return roots
    }

    static func scan(roots: [URL]? = nil, progress: ((String) -> Void)? = nil) -> [InstalledApp] {
        let fm = FileManager.default
        let searchRoots = roots ?? defaultRoots()
        var found = Set<String>()

        progress?("正在查找 App…")
        for root in searchRoots {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            guard let en = fm.enumerator(at: root,
                                         includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                         errorHandler: { _, _ in true }) else { continue }
            while let child = en.nextObject() as? URL {
                if en.level > 4 { en.skipDescendants(); continue }
                guard child.pathExtension.lowercased() == "app" else { continue }
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                found.insert(child.standardizedFileURL.path)
            }
        }

        let urls = found.sorted().map { URL(fileURLWithPath: $0) }
        progress?("正在读取 \(urls.count) 个 App 的信息…")

        var results = [InstalledApp?](repeating: nil, count: urls.count)
        let lock = NSLock()
        var completed = 0
        DispatchQueue.concurrentPerform(iterations: urls.count) { index in
            let app = makeApp(at: urls[index])
            lock.lock()
            results[index] = app
            completed += 1
            let count = completed
            lock.unlock()
            if count % 8 == 0 { progress?("已分析 \(count)/\(urls.count) 个 App…") }
        }

        let selfPath = Bundle.main.bundleURL.standardizedFileURL.path
        return results
            .compactMap { $0 }
            .filter { $0.path != selfPath }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func makeApp(at url: URL) -> InstalledApp? {
        let info = Bundle(url: url)?.infoDictionary
        var name = url.deletingPathExtension().lastPathComponent
        if name.isEmpty { return nil }
        if let display = info?["CFBundleDisplayName"] as? String, !display.isEmpty, name.count < 3 {
            name = display
        }

        let bundleID = (info?["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (info?["CFBundleShortVersionString"] as? String)
            ?? (info?["CFBundleVersion"] as? String)
            ?? ""
        let isSystem = url.path.hasPrefix("/System/")
            || (bundleID?.hasPrefix("com.apple.") ?? false)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let size = directorySize(url)

        let signing = signingDetails(for: url)
        return InstalledApp(path: url.path,
                            name: name,
                            bundleID: bundleID,
                            version: version,
                            size: size,
                            isSystem: isSystem,
                            isRunning: false,
                            teamID: signing.teamID,
                            modified: modified,
                            embeddedIDs: embeddedBundleIDs(in: url),
                            appGroups: signing.groups)
    }

    /// 递归统计目录体积（按磁盘实际占用）
    static func directorySize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let en = FileManager.default.enumerator(at: url,
                                                      includingPropertiesForKeys: Array(keys),
                                                      options: [],
                                                      errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        while let child = en.nextObject() as? URL {
            guard let values = try? child.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// 代码签名信息：Team ID 与 App Group（用于匹配共享容器）
    static func signingDetails(for url: URL) -> (teamID: String?, groups: [String]) {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return (nil, []) }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dict = information as? [String: Any] else { return (nil, []) }
        let team = dict["teamid"] as? String
        let entitlements = dict["entitlements"] as? [String: Any]
        let groups = entitlements?["com.apple.security.application-groups"] as? [String] ?? []
        return (team, groups)
    }

    /// App 内嵌的扩展 / XPC / 登录项，它们往往有独立的容器
    static func embeddedBundleIDs(in appURL: URL) -> [String] {
        let fm = FileManager.default
        let subdirectories = [
            "Contents/PlugIns",
            "Contents/XPCServices",
            "Contents/Library/LoginItems",
            "Contents/Library/SystemExtensions",
            "Contents/Library/QuickLook",
            "Contents/Library/Spotlight"
        ]
        var ids: [String] = []
        for sub in subdirectories {
            let dir = appURL.appendingPathComponent(sub)
            guard fm.fileExists(atPath: dir.path) else { continue }
            guard let en = fm.enumerator(at: dir,
                                         includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                         errorHandler: { _, _ in true }) else { continue }
            while let child = en.nextObject() as? URL {
                let ext = child.pathExtension.lowercased()
                guard ["appex", "xpc", "app"].contains(ext) else { continue }
                if let bid = Bundle(url: child)?.bundleIdentifier, !bid.isEmpty {
                    ids.append(bid)
                }
                en.skipDescendants()
            }
        }
        return ids
    }

    /// 当前正在运行的 App（路径 -> 进程）
    static func runningAppPaths() -> Set<String> {
        var paths = Set<String>()
        for running in NSWorkspace.shared.runningApplications {
            if let url = running.bundleURL { paths.insert(url.standardizedFileURL.path) }
        }
        return paths
    }

    static func isRunning(_ app: InstalledApp) -> Bool {
        if let bid = app.bundleID, !bid.isEmpty,
           !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
            return true
        }
        return runningAppPaths().contains(app.url.standardizedFileURL.path)
    }
}
