import Foundation

// MARK: - 匹配可信度

enum Confidence: Int, Codable, Comparable {
    case low = 0
    case medium = 1
    case high = 2

    static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - 残留类型

enum LeftoverKind: String, Codable, CaseIterable {
    case appBundle
    case cache
    case preferences
    case appSupport
    case container
    case groupContainer
    case logs
    case savedState
    case scripts
    case webStorage
    case launchAgent
    case launchDaemon
    case helper
    case receipt
    case autosave

    var title: String {
        switch self {
        case .appBundle:      return "App 本体"
        case .cache:          return "缓存"
        case .preferences:    return "偏好设置"
        case .appSupport:     return "应用支持数据"
        case .container:      return "沙盒容器"
        case .groupContainer: return "共享容器"
        case .logs:           return "日志"
        case .savedState:     return "窗口状态"
        case .scripts:        return "应用脚本"
        case .webStorage:     return "网页存储"
        case .launchAgent:    return "用户启动项"
        case .launchDaemon:   return "系统启动项"
        case .helper:         return "特权 Helper"
        case .receipt:        return "安装收据"
        case .autosave:       return "自动保存"
        }
    }

    var symbol: String {
        switch self {
        case .appBundle:      return "app.dashed"
        case .cache:          return "internaldrive"
        case .preferences:    return "gearshape"
        case .appSupport:     return "folder"
        case .container:      return "shippingbox"
        case .groupContainer: return "shippingbox.fill"
        case .logs:           return "doc.text"
        case .savedState:     return "clock.arrow.circlepath"
        case .scripts:        return "chevron.left.forwardslash.chevron.right"
        case .webStorage:     return "globe"
        case .launchAgent:    return "bolt"
        case .launchDaemon:   return "bolt.fill"
        case .helper:         return "wrench.and.screwdriver"
        case .receipt:        return "doc.text.magnifyingglass"
        case .autosave:       return "arrow.down.doc"
        }
    }

    /// 这类残留通常体积大、删除收益高，界面上会排在前面
    var weight: Int {
        switch self {
        case .appBundle:      return 0
        case .container:      return 1
        case .cache:          return 2
        case .groupContainer: return 3
        case .appSupport:     return 4
        case .preferences:    return 5
        case .savedState:     return 6
        case .logs:           return 7
        case .webStorage:     return 8
        case .autosave:       return 9
        case .scripts:        return 10
        case .launchAgent:    return 11
        case .launchDaemon:   return 12
        case .helper:         return 13
        case .receipt:        return 14
        }
    }
}

// MARK: - 已安装 App

struct InstalledApp: Identifiable, Codable, Hashable {
    var path: String
    var name: String
    var bundleID: String?
    var version: String
    var size: Int64
    var isSystem: Bool
    var isRunning: Bool
    var teamID: String?
    var modified: Date?
    /// 内嵌的扩展 / XPC / 登录项 Bundle ID
    var embeddedIDs: [String] = []
    /// 签名里的 App Group（共享容器）
    var appGroups: [String] = []

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var location: String { url.deletingLastPathComponent().path }
    var executableName: String? { url.deletingPathExtension().lastPathComponent }
}

// MARK: - 残留项

struct Leftover: Identifiable, Codable, Hashable {
    var url: URL
    var kind: LeftoverKind
    var size: Int64
    var requiresAdmin: Bool
    var confidence: Confidence

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var parentPath: String { url.deletingLastPathComponent().path }
}

// MARK: - 卸载配置 / 结果

struct UninstallOptions {
    var quitRunning: Bool = true
    var removeSystemLeftovers: Bool = true
    var cleanRegistration: Bool = true
    var permanent: Bool = false
    /// 受系统保护的容器（~/Library/Containers 等）改由管理员重试
    var adminFallback: Bool = true
}

struct LogEntry: Identifiable {
    let id = UUID()
    var ok: Bool
    var text: String
    var detail: String?
}

struct UninstallReport: Identifiable {
    let id = UUID()
    var appCount: Int
    var freed: Int64
    var failures: Int
    var entries: [LogEntry]
    var trashedSomething: Bool
    var hint: String? = nil
}

// MARK: - 工具

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: bytes)
}

func abbreviatePath(_ path: String, home: String = NSHomeDirectory()) -> String {
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
