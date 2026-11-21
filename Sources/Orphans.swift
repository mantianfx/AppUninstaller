import Foundation

/// 找出「找不到对应已安装 App」的沙盒容器残留。
/// 只扫描 ~/Library/Containers 与 ~/Library/Group Containers，
/// 并且只接受反向域名形态的目录名，尽量降低误判。
enum OrphanScanner {

    private static let extensionKeywords: [String] = [
        "extension", "widget", "finderhelper", "findersync", "quicklook", "qlx",
        "docktile", "helper", "renderer", "xpc", "agent", "share", "explinder"
    ]

    private static let knownTLDs: Set<String> = [
        "com", "org", "net", "io", "cn", "me", "app", "dev", "co", "uk", "de", "fr",
        "jp", "ru", "us", "tv", "xyz", "gg", "ai", "cloud", "tech", "hk", "tw", "sg",
        "au", "ca", "ch", "se", "no", "fi", "nl", "it", "es", "kr", "in", "br",
        "edu", "gov", "info", "biz", "so", "sh", "cc", "to", "fm", "site", "online"
    ]

    static func scan(apps: [InstalledApp],
                     home: String = NSHomeDirectory(),
                     progress: ((String) -> Void)? = nil) -> [Leftover] {

        var installedIDs = Set(apps.compactMap { $0.bundleID?.lowercased() }.filter { !$0.isEmpty })
        for app in apps {
            for id in app.embeddedIDs { installedIDs.insert(id.lowercased()) }
            for group in app.appGroups { installedIDs.insert(group.lowercased()) }
        }
        let installedNames = apps.map { LeftoverFinder.Matcher.normalize($0.name) }.filter { $0.count >= 5 }
        // 厂商前缀（com.xxx / org.xxx），用于识别「同厂商、可能是扩展」的可疑项
        let vendorPrefixes = Set(apps.compactMap { app -> String? in
            guard let bid = app.bundleID?.lowercased() else { return nil }
            let parts = bid.split(separator: ".")
            guard parts.count >= 2 else { return nil }
            let prefix = parts.prefix(2).joined(separator: ".")
            return prefix.count >= 8 ? prefix : nil
        })

        var matches: [(url: URL, kind: LeftoverKind, confidence: Confidence)] = []
        let bases: [(String, LeftoverKind)] = [
            (home + "/Library/Containers", .container),
            (home + "/Library/Group Containers", .groupContainer)
        ]

        for (base, kind) in bases {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { continue }
            for name in names {
                if name.hasPrefix(".") { continue }
                let lower = name.lowercased()
                guard !lower.contains("com.apple."), !lower.hasPrefix("group.com.apple.") else { continue }
                guard looksLikeAppContainer(lower) else { continue }
                guard !matchesInstalled(lower, ids: installedIDs, names: installedNames) else { continue }
                let sameVendor = vendorPrefixes.contains { lower.hasPrefix($0 + ".") }
                let looksLikeExtension = extensionKeywords.contains { lower.contains($0) }
                // 同厂商 + 像扩展/助手：可能是已安装 App 的一部分，降级为待确认
                let confidence: Confidence = (sameVendor && looksLikeExtension) ? .medium : .high
                matches.append((URL(fileURLWithPath: base + "/" + name), kind, confidence))
            }
        }

        progress?("正在统计 \(matches.count) 个残留的体积…")
        var sizes = [Int64](repeating: 0, count: matches.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: matches.count) { index in
            let size = AppScanner.directorySize(matches[index].url)
            lock.lock(); sizes[index] = size; lock.unlock()
        }

        let items = zip(matches, sizes).map { pair -> Leftover in
            Leftover(url: pair.0.url,
                     kind: pair.0.kind,
                     size: pair.1,
                     requiresAdmin: false,
                     confidence: pair.0.confidence)
        }
        return items.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            return lhs.size > rhs.size
        }
    }

    /// com.foo.bar / TEAMID.com.foo.bar / group.com.foo.bar 这类形态才认为是 App 容器
    static func looksLikeAppContainer(_ name: String) -> Bool {
        var candidate = name
        if let dot = candidate.firstIndex(of: ".") {
            let prefix = String(candidate[..<dot])
            let isTeamID = prefix.count == 10 && prefix.allSatisfy { $0.isLetter || $0.isNumber }
            if isTeamID { candidate = String(candidate[candidate.index(after: dot)...]) }
        }
        if candidate.hasPrefix("group.") { candidate = String(candidate.dropFirst("group.".count)) }
        let parts = candidate.split(separator: ".")
        guard parts.count >= 2 else { return false }
        return knownTLDs.contains(parts[0].lowercased())
    }

    static func matchesInstalled(_ name: String,
                                 ids: Set<String>,
                                 names: [String]) -> Bool {
        var candidates: [String] = [name]

        var stripped = name
        if let dot = stripped.firstIndex(of: ".") {
            let prefix = String(stripped[..<dot])
            let isTeamID = prefix.count == 10 && prefix.allSatisfy { $0.isLetter || $0.isNumber }
            if isTeamID { stripped = String(stripped[stripped.index(after: dot)...]) }
        }
        if stripped.hasPrefix("group.") { stripped = String(stripped.dropFirst("group.".count)) }
        candidates.append(stripped)

        for candidate in candidates {
            for id in ids {
                if candidate == id || candidate.hasSuffix("." + id) || candidate.hasPrefix(id + ".") || candidate.contains(id) {
                    return true
                }
                // 容器名是已安装 Bundle ID 的前缀（例：com.tencent.xin 之于 com.tencent.xinWeChat）
                if candidate.count >= 12, id.contains(candidate) {
                    return true
                }
            }
            let compact = LeftoverFinder.Matcher.normalize(candidate)
            for installedName in names where compact.contains(installedName) {
                return true
            }
        }
        return false
    }
}
