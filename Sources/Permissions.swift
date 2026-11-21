import Foundation
import AppKit

/// 判断本 App 是否已获得「完全磁盘访问权限」。
/// 其他 App 的沙盒容器（~/Library/Containers、Group Containers）受 TCC 保护，
/// 没有该权限时连 root 也无法修改，只有用户手动在系统设置中授权才可清理。
enum FullDiskAccess {

    /// TCC 数据库只有拿到完全磁盘访问权限后才能读取，用它作为探测点
    static var isGranted: Bool {
        let candidates = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        ]
        for path in candidates {
            if let handle = FileHandle(forReadingAtPath: path) {
                try? handle.close()
                return true
            }
        }
        return false
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
