import Foundation
import AppKit
import Combine

final class AppState: ObservableObject {

    enum FilterMode: String, CaseIterable, Identifiable {
        case all, selected, running, large
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .selected: return "仅已选"
            case .running: return "运行中"
            case .large: return "大于 1 GB"
            }
        }
    }

    enum SortMode: String, CaseIterable, Identifiable {
        case name, size, date
        var id: String { rawValue }
        var title: String {
            switch self {
            case .name: return "名称"
            case .size: return "体积"
            case .date: return "最近修改"
            }
        }
    }

    @Published var apps: [InstalledApp] = []
    @Published var selection: Set<String> = []
    @Published var focus: String?
    @Published var query: String = ""
    @Published var showSystemApps: Bool = false
    @Published var sortMode: SortMode = .name
    @Published var filterMode: FilterMode = .all
    @Published var isScanning: Bool = false
    @Published var focusSearchToken = 0
    @Published var scanStatus: String = "尚未扫描"

    @Published var leftovers: [String: [Leftover]] = [:]
    @Published var leftoverSelection: [String: Set<String>] = [:]
    @Published var loadingLeftovers: Set<String> = []

    @Published var optQuit = true
    @Published var optSystem = true
    @Published var optRegistration = true
    @Published var optPermanent = false
    @Published var optAdminFallback = true
    @Published var hasFullDiskAccess = FullDiskAccess.isGranted
    @Published var fdaBannerDismissed = false

    @Published var showConfirm = false
    @Published var showOrphanSheet = false
    @Published var orphanItems: [Leftover] = []
    @Published var orphanSelection: Set<String> = []
    @Published var orphanLoading = false
    @Published var orphanProgress = ""
    @Published var isUninstalling = false
    @Published var progressText = ""
    @Published var report: UninstallReport?

    private var iconCache: [String: NSImage] = [:]

    /// 残留扫描会遍历 ~/Library 下多个目录，限制并发避免打满磁盘
    private let leftoverQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
        return queue
    }()

    // MARK: 派生数据

    var filteredApps: [InstalledApp] {
        var list = apps
        if !showSystemApps { list = list.filter { !$0.isSystem } }
        switch filterMode {
        case .all:
            break
        case .selected:
            list = list.filter { selection.contains($0.id) }
        case .running:
            list = list.filter { $0.isRunning }
        case .large:
            list = list.filter { $0.size >= 1_000_000_000 }
        }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !keyword.isEmpty {
            list = list.filter {
                $0.name.lowercased().contains(keyword)
                    || ($0.bundleID ?? "").lowercased().contains(keyword)
                    || $0.path.lowercased().contains(keyword)
            }
        }
        switch sortMode {
        case .name:
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            list.sort { $0.size > $1.size }
        case .date:
            list.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
        return list
    }

    var selectedApps: [InstalledApp] {
        apps.filter { selection.contains($0.id) }
    }

    var focusedApp: InstalledApp? {
        guard let focus else { return nil }
        return apps.first { $0.id == focus }
    }

    func isSelected(_ app: InstalledApp) -> Bool { selection.contains(app.id) }

    func leftovers(for app: InstalledApp) -> [Leftover] { leftovers[app.id] ?? [] }

    func selectedLeftovers(for app: InstalledApp) -> [Leftover] {
        let chosen = leftoverSelection[app.id] ?? []
        return leftovers(for: app).filter { chosen.contains($0.id) }
    }

    var totalSelectedSize: Int64 {
        var total: Int64 = 0
        for app in selectedApps {
            total += app.size
            total += selectedLeftovers(for: app).reduce(0) { $0 + $1.size }
        }
        return total
    }

    var totalAppSize: Int64 { apps.reduce(0) { $0 + $1.size } }

    /// 当前选择里是否包含需要管理员授权的项目（/Library 或受保护的 App 本体）
    var hasAdminTargets: Bool {
        selectedApps.contains { app in
            selectedLeftovers(for: app).contains { $0.requiresAdmin }
                || !Uninstaller.isParentWritable(app.url)
        }
    }

    func refreshPermissions() {
        let granted = FullDiskAccess.isGranted
        if granted != hasFullDiskAccess { hasFullDiskAccess = granted }
    }

    func dismissFDABanner() {
        fdaBannerDismissed = true
    }

    /// 选中项里受 TCC 保护的容器数量
    var protectedContainerCount: Int {
        selectedApps.reduce(0) { total, app in
            total + selectedLeftovers(for: app).filter { $0.kind == .container || $0.kind == .groupContainer }.count
        }
    }

    func requestSearchFocus() {
        focusSearchToken += 1
    }

    func removeFromSelection(_ app: InstalledApp) {
        selection.remove(app.id)
    }

    // MARK: 图标

    func icon(for app: InstalledApp) -> NSImage {
        if let image = iconCache[app.path] { return image }
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 64, height: 64)
        iconCache[app.path] = image
        return image
    }

    // MARK: 扫描

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        scanStatus = "正在扫描 /Applications…"
        let previousSelection = selection
        leftovers.removeAll()
        leftoverSelection.removeAll()
        DispatchQueue.global(qos: .userInitiated).async {
            let scanned = AppScanner.scan { text in
                DispatchQueue.main.async { self.scanStatus = text }
            }
            let runningPaths = AppScanner.runningAppPaths()
            DispatchQueue.main.async {
                self.apps = scanned.map { app in
                    var copy = app
                    if runningPaths.contains(app.url.standardizedFileURL.path) {
                        copy.isRunning = true
                    } else if let bid = app.bundleID, !bid.isEmpty,
                              !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
                        copy.isRunning = true
                    }
                    return copy
                }
                self.selection = previousSelection.intersection(Set(self.apps.map { $0.id }))
                if self.focus == nil || !self.apps.contains(where: { $0.id == self.focus }) {
                    self.focus = self.apps.first(where: { !$0.isSystem })?.id
                }
                self.isScanning = false
                let uninstallable = self.apps.filter { !$0.isSystem }
                self.scanStatus = "共 \(self.apps.count) 个 App，可卸载 \(uninstallable.count) 个 · \(formatBytes(uninstallable.reduce(0) { $0 + $1.size }))"
                for app in self.selectedApps { self.loadLeftovers(for: app) }
                if let app = self.focusedApp { self.loadLeftovers(for: app) }
            }
        }
    }

    // MARK: 选择

    func setSelected(_ app: InstalledApp, _ selected: Bool) {
        guard !app.isSystem else { return }
        if selected {
            selection.insert(app.id)
            if leftovers[app.id] == nil { loadLeftovers(for: app) }
        } else {
            selection.remove(app.id)
        }
    }

    func toggle(_ app: InstalledApp) {
        setSelected(app, !isSelected(app))
    }

    func selectAllVisible() {
        for app in filteredApps where !app.isSystem {
            selection.insert(app.id)
            if leftovers[app.id] == nil { loadLeftovers(for: app) }
        }
    }

    func clearSelection() { selection.removeAll() }

    // MARK: 残留

    func loadLeftovers(for app: InstalledApp, force: Bool = false) {
        if !force, leftovers[app.id] != nil { return }
        if loadingLeftovers.contains(app.id) { return }
        loadingLeftovers.insert(app.id)
        leftoverQueue.addOperation { [weak self] in
            let found = LeftoverFinder.find(for: app)
            DispatchQueue.main.async {
                guard let self else { return }
                self.leftovers[app.id] = found
                if force || self.leftoverSelection[app.id] == nil {
                    self.leftoverSelection[app.id] = Set(found.filter { $0.confidence == .high }.map { $0.id })
                }
                self.loadingLeftovers.remove(app.id)
            }
        }
    }

    func isLeftoverSelected(_ leftover: Leftover, for app: InstalledApp) -> Bool {
        (leftoverSelection[app.id] ?? []).contains(leftover.id)
    }

    func setLeftover(_ leftover: Leftover, for app: InstalledApp, selected: Bool) {
        var current = leftoverSelection[app.id] ?? []
        if selected { current.insert(leftover.id) } else { current.remove(leftover.id) }
        leftoverSelection[app.id] = current
    }

    func selectAllLeftovers(for app: InstalledApp, selected: Bool) {
        leftoverSelection[app.id] = selected ? Set(leftovers(for: app).map { $0.id }) : []
    }

    // MARK: 孤儿残留

    func openOrphanSheet() {
        showOrphanSheet = true
        scanOrphans()
    }

    func scanOrphans() {
        guard !orphanLoading else { return }
        orphanLoading = true
        orphanProgress = "正在扫描容器目录…"
        let snapshotApps = apps
        DispatchQueue.global(qos: .userInitiated).async {
            let found = OrphanScanner.scan(apps: snapshotApps) { text in
                DispatchQueue.main.async { self.orphanProgress = text }
            }
            DispatchQueue.main.async {
                self.orphanItems = found
                self.orphanSelection = Set(found.filter { $0.confidence == .high }.map { $0.id })
                self.orphanLoading = false
            }
        }
    }

    func isOrphanSelected(_ item: Leftover) -> Bool { orphanSelection.contains(item.id) }

    func setOrphan(_ item: Leftover, selected: Bool) {
        if selected { orphanSelection.insert(item.id) } else { orphanSelection.remove(item.id) }
    }

    func selectAllOrphans(_ selected: Bool) {
        orphanSelection = selected ? Set(orphanItems.map { $0.id }) : []
    }

    var selectedOrphanSize: Int64 {
        orphanItems.filter { orphanSelection.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    func cleanOrphans() {
        let targets = orphanItems.filter { orphanSelection.contains($0.id) }
        guard !targets.isEmpty, !isUninstalling else { return }
        refreshPermissions()
        let options = UninstallOptions(quitRunning: false,
                                       removeSystemLeftovers: true,
                                       cleanRegistration: false,
                                       permanent: false,
                                       adminFallback: true)
        showOrphanSheet = false
        isUninstalling = true
        progressText = "准备清理残留…"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            Uninstaller.removeOrphans(targets, options: options, progress: { text in
                DispatchQueue.main.async { self.progressText = text }
            }, completion: { report in
                self.isUninstalling = false
                self.report = report
                self.scanOrphans()
            })
        }
    }

    // MARK: 卸载

    func beginUninstall() {
        guard !selectedApps.isEmpty, !isUninstalling else { return }
        refreshPermissions()
        for app in selectedApps where leftovers[app.id] == nil {
            loadLeftovers(for: app)
        }
        showConfirm = true
    }

    func startUninstall() {
        refreshPermissions()
        let chosen = selectedApps
        guard !chosen.isEmpty else { return }
        let leftoverSnapshot = leftovers
        let selectionSnapshot = leftoverSelection
        let options = UninstallOptions(quitRunning: optQuit,
                                       removeSystemLeftovers: optSystem,
                                       cleanRegistration: optRegistration,
                                       permanent: optPermanent,
                                       adminFallback: optAdminFallback)

        showConfirm = false
        isUninstalling = true
        progressText = "准备中…"

        DispatchQueue.global(qos: .userInitiated).async {
            var items: [(app: InstalledApp, leftovers: [Leftover])] = []
            for app in chosen {
                var found = leftoverSnapshot[app.id] ?? LeftoverFinder.find(for: app)
                if let chosenIDs = selectionSnapshot[app.id] {
                    found = found.filter { chosenIDs.contains($0.id) }
                } else {
                    found = found.filter { $0.confidence == .high }
                }
                if !options.removeSystemLeftovers { found = found.filter { !$0.requiresAdmin } }
                items.append((app, found))
            }
            Uninstaller.run(items: items, options: options, progress: { text in
                DispatchQueue.main.async { self.progressText = text }
            }, completion: { report in
                self.isUninstalling = false
                self.report = report
                self.selection.removeAll()
                self.leftovers.removeAll()
                self.leftoverSelection.removeAll()
                self.refresh()
            })
        }
    }
}
