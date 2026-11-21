import Foundation

// MARK: - 残留文件发现

struct LeftoverFinder {

    struct Spec {
        let root: String
        let kind: LeftoverKind
        let admin: Bool
        let maxDepth: Int
    }

    static func specs(home: String) -> [Spec] {
        let library = home + "/Library"
        return [
            Spec(root: library + "/Containers",                  kind: .container,      admin: false, maxDepth: 1),
            Spec(root: library + "/Group Containers",            kind: .groupContainer, admin: false, maxDepth: 1),
            Spec(root: library + "/Application Support",         kind: .appSupport,     admin: false, maxDepth: 2),
            Spec(root: library + "/Application Support/CrashReporter", kind: .logs,     admin: false, maxDepth: 1),
            Spec(root: library + "/Caches",                      kind: .cache,          admin: false, maxDepth: 2),
            Spec(root: library + "/Preferences",                 kind: .preferences,    admin: false, maxDepth: 1),
            Spec(root: library + "/Preferences/ByHost",          kind: .preferences,    admin: false, maxDepth: 1),
            Spec(root: library + "/Saved Application State",     kind: .savedState,     admin: false, maxDepth: 1),
            Spec(root: library + "/Logs",                        kind: .logs,           admin: false, maxDepth: 2),
            Spec(root: library + "/Application Scripts",         kind: .scripts,        admin: false, maxDepth: 1),
            Spec(root: library + "/HTTPStorages",                kind: .webStorage,     admin: false, maxDepth: 1),
            Spec(root: library + "/WebKit",                      kind: .webStorage,     admin: false, maxDepth: 1),
            Spec(root: library + "/Cookies",                     kind: .webStorage,     admin: false, maxDepth: 1),
            Spec(root: library + "/LaunchAgents",                kind: .launchAgent,    admin: false, maxDepth: 1),
            Spec(root: library + "/Autosave Information",        kind: .autosave,       admin: false, maxDepth: 1),
            Spec(root: NSTemporaryDirectory(),                   kind: .cache,          admin: false, maxDepth: 2),
            Spec(root: "/Library/Application Support",           kind: .appSupport,     admin: true,  maxDepth: 2),
            Spec(root: "/Library/Caches",                        kind: .cache,          admin: true,  maxDepth: 1),
            Spec(root: "/Library/Preferences",                   kind: .preferences,    admin: true,  maxDepth: 1),
            Spec(root: "/Library/Logs",                          kind: .logs,           admin: true,  maxDepth: 1),
            Spec(root: "/Library/LaunchAgents",                  kind: .launchAgent,    admin: true,  maxDepth: 1),
            Spec(root: "/Library/LaunchDaemons",                 kind: .launchDaemon,   admin: true,  maxDepth: 1),
            Spec(root: "/Library/PrivilegedHelperTools",         kind: .helper,         admin: true,  maxDepth: 1),
            Spec(root: "/Library/Receipts",                      kind: .receipt,        admin: true,  maxDepth: 1),
            Spec(root: "/private/var/db/receipts",               kind: .receipt,        admin: true,  maxDepth: 1)
        ]
    }

    // MARK: 名称匹配

    struct Matcher {
        let bundleID: String
        /// 强特征词：来自 App 名称，允许前缀匹配
        let strong: [String]
        /// 弱特征词：来自 Bundle ID 末段，只允许精确匹配，避免 "chrome-browser" 之类的误伤
        let weak: [String]

        static let stopwords: Set<String> = [
            "desktop", "helper", "renderer", "agent", "client", "service", "services",
            "updater", "update", "app", "apps", "application", "mac", "macos", "osx",
            "player", "share", "shared", "sync", "core", "pro", "lite", "studio",
            "launcher", "plugin", "extension", "xpc", "main", "electron", "release",
            "utility", "utilities", "tool", "tools", "beta", "stable", "native"
        ]

        init(app: InstalledApp) {
            self.bundleID = (app.bundleID ?? "").lowercased()

            var strong: [String] = []
            for candidate in [app.name, app.url.deletingPathExtension().lastPathComponent] {
                let compact = Matcher.normalize(candidate)
                if compact.count >= 4, !Matcher.stopwords.contains(compact), !strong.contains(compact) {
                    strong.append(compact)
                }
            }
            self.strong = strong

            var weak: [String] = []
            if let last = app.bundleID?.components(separatedBy: ".").last {
                let compact = Matcher.normalize(last)
                if compact.count >= 4, !Matcher.stopwords.contains(compact),
                   !strong.contains(compact), !weak.contains(compact) {
                    weak.append(compact)
                }
            }
            self.weak = weak
        }

        static func normalize(_ value: String) -> String {
            let lowered = value.lowercased()
            let filtered = lowered.unicodeScalars.filter { scalar in
                CharacterSet.alphanumerics.contains(scalar) || CharacterSet.letters.contains(scalar)
            }
            return String(String.UnicodeScalarView(filtered))
        }

        func confidence(for fileName: String) -> Confidence? {
            let lower = fileName.lowercased()
            if !bundleID.isEmpty {
                if lower == bundleID { return .high }
                if lower.hasPrefix(bundleID + ".") { return .high }
                if lower.contains(bundleID) { return .high }
            }
            let compact = Matcher.normalize(fileName)
            for token in strong {
                if compact == token { return .high }
                if compact.hasPrefix(token) { return .high }
                if token.count >= 5, compact.contains(token) { return .medium }
            }
            for token in weak {
                if compact == token { return .high }
                if token.count >= 7, compact.hasPrefix(token) { return .medium }
            }
            return nil
        }
    }

    // MARK: 查找

    /// Apple 系统缓存 / 容器目录，既不可能是第三方 App 的残留，读取时还可能被 TCC 卡住
    static let appleSystemNames: Set<String> = [
        "cloudkit", "familycircle", "familycircled", "gamekit", "passkit", "homekit",
        "music", "safari", "maps", "photos", "messages", "mail", "addressbook",
        "callhistorydb", "apple", "icloud", "clouddocs", "mobileme", "findmy",
        "shazam", "stocks", "news", "podcasts", "reminders", "calendar", "contacts",
        "notes", "shortcuts", "siri", "assistant", "spotlight", "tv", "wallet",
        "com.apple.homekit", "com.apple.music", "com.apple.safari",
        "com.apple.findmy.fmfcore", "com.apple.findmy.fmipcore"
    ]

    static func shouldDescend(name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("com.apple.") { return false }
        return !appleSystemNames.contains(lower)
    }

    static func find(for app: InstalledApp, home: String = NSHomeDirectory()) -> [Leftover] {
        let matcher = Matcher(app: app)
        var results: [Leftover] = []
        var seen = Set<String>()
        // 单个 App 的残留扫描最多花 8 秒，避免个别异常目录拖住整个队列
        let deadline = Date().addingTimeInterval(8)

        for spec in specs(home: home) {
            guard Date() < deadline else { break }
            walk(spec: spec,
                 current: URL(fileURLWithPath: spec.root),
                 depth: 0,
                 matcher: matcher,
                 results: &results,
                 seen: &seen,
                 deadline: deadline)
        }

        return results.sorted { lhs, rhs in
            if lhs.requiresAdmin != rhs.requiresAdmin { return !lhs.requiresAdmin }
            if lhs.kind.weight != rhs.kind.weight { return lhs.kind.weight < rhs.kind.weight }
            return lhs.size > rhs.size
        }
    }

    private static func walk(spec: Spec,
                             current: URL,
                             depth: Int,
                             matcher: Matcher,
                             results: inout [Leftover],
                             seen: inout Set<String>,
                             deadline: Date) {
        guard depth <= spec.maxDepth, Date() < deadline else { return }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: current.path) else { return }

        for name in names {
            if name.hasPrefix(".") { continue }
            if Date() > deadline { return }

            let child = current.appendingPathComponent(name)
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }

            if let confidence = matcher.confidence(for: name) {
                let path = child.standardizedFileURL.path
                if seen.insert(path).inserted {
                    let isDirectory = values?.isDirectory ?? false
                    let size = isDirectory ? AppScanner.directorySize(child) : fileSize(child)
                    results.append(Leftover(url: child,
                                            kind: spec.kind,
                                            size: size,
                                            requiresAdmin: spec.admin,
                                            confidence: confidence))
                }
                continue
            }

            guard values?.isDirectory == true, depth + 1 <= spec.maxDepth else { continue }
            guard shouldDescend(name: name) else { continue }
            walk(spec: spec,
                 current: child,
                 depth: depth + 1,
                 matcher: matcher,
                 results: &results,
                 seen: &seen,
                 deadline: deadline)
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
            if let allocated = values.totalFileAllocatedSize { return Int64(allocated) }
            if let size = values.fileSize { return Int64(size) }
        }
        return 0
    }
}
