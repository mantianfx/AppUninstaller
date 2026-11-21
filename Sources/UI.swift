import SwiftUI
import AppKit

// MARK: - 主界面

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            if !state.hasFullDiskAccess && !state.fdaBannerDismissed {
                PermissionBanner()
            }
            Divider()
            HSplitView {
                AppListView()
                    .frame(minWidth: 560, idealWidth: 680)
                DetailPane()
                    .frame(minWidth: 360, idealWidth: 420, maxWidth: 560)
            }
            if !state.selection.isEmpty {
                SelectedBar()
            }
            Divider()
            FooterBar()
        }
        .frame(minWidth: 980, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if state.apps.isEmpty { state.refresh() } }
        .sheet(isPresented: $state.showConfirm) {
            ConfirmSheet().environmentObject(state)
        }
        .sheet(item: $state.report) { report in
            ReportSheet(report: report)
        }
        .sheet(isPresented: $state.showOrphanSheet) {
            OrphanSheet().environmentObject(state)
        }
        .overlay {
            if state.isUninstalling { ProgressOverlay().environmentObject(state) }
        }
    }
}

// MARK: - 顶栏

struct HeaderBar: View {
    @EnvironmentObject var state: AppState
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("应用卸载器").font(.system(size: 17, weight: .semibold))
                HStack(spacing: 5) {
                    if state.isScanning {
                        ProgressView().controlSize(.mini).scaleEffect(0.8)
                    }
                    Text(state.scanStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索 App、Bundle ID 或路径", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 190)
                    .focused($searchFocused)
                if !state.query.isEmpty {
                    Button { state.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.18), lineWidth: 1))

            Toggle("系统 App", isOn: $state.showSystemApps)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

            Picker("筛选", selection: $state.filterMode) {
                ForEach(AppState.FilterMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 88)

            Picker("排序", selection: $state.sortMode) {
                ForEach(AppState.SortMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 86)

            Button {
                state.openOrphanSheet()
            } label: {
                Image(systemName: "broom")
            }
            .buttonStyle(.borderless)
            .help("清理已卸载 App 的残留容器")
            .disabled(state.isScanning)

            Button {
                state.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("重新扫描")
            .disabled(state.isScanning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: state.focusSearchToken) { _ in searchFocused = true }
    }
}

// MARK: - 权限提示

struct PermissionBanner: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 14))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("未授予「完全磁盘访问权限」")
                    .font(.system(size: 11.5, weight: .medium))
                Text("其他 App 的沙盒容器受系统保护，缺少此权限时无法清理（通常是残留里体积最大的部分）。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("打开系统设置") { FullDiskAccess.openSettings() }
                .controlSize(.small)
            Button {
                state.dismissFDABanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("暂时隐藏")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.09))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - 列表

struct AppListView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.filteredApps) { app in
                        AppRow(app: app)
                        Divider().padding(.leading, 58)
                    }
                }
                .padding(.vertical, 4)
            }

            if state.isScanning && state.apps.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text(state.scanStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else if !state.isScanning && state.filteredApps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text(state.apps.isEmpty ? "没有找到 App" : "没有匹配的 App")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }
}

struct AppRow: View {
    @EnvironmentObject var state: AppState
    let app: InstalledApp
    @State private var hovering = false

    private var subtitle: String {
        var parts: [String] = []
        if !app.version.isEmpty { parts.append("v\(app.version)") }
        if let bid = app.bundleID, !bid.isEmpty { parts.append(bid) }
        if let list = state.leftovers[app.id], !list.isEmpty {
            parts.append("关联文件 \(list.count) 项")
        }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { state.isSelected(app) },
                set: { state.setSelected(app, $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(app.isSystem)
            .opacity(app.isSystem ? 0.35 : 1)

            Image(nsImage: state.icon(for: app))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .opacity(app.isSystem ? 0.7 : 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if app.isRunning { Pill(text: "运行中", color: .green) }
                    if app.isSystem { Pill(text: "系统", color: .secondary) }
                }
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Text(formatBytes(app.size))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(state.focus == app.id ? Color.accentColor : Color.secondary.opacity(0.35))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            state.focus = app.id
            if !app.isSystem { state.loadLeftovers(for: app) }
        }
        .onHover { hovering = $0 }
        .help(app.path)
    }

    private var rowBackground: Color {
        if state.focus == app.id { return Color.accentColor.opacity(0.12) }
        if hovering { return Color.primary.opacity(0.045) }
        return Color.clear
    }
}

// MARK: - 详情

struct DetailPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if let app = state.focusedApp {
                DetailContent(app: app)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right").font(.system(size: 24)).foregroundStyle(.tertiary)
                    Text("选择左侧 App 查看关联文件").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct DetailContent: View {
    @EnvironmentObject var state: AppState
    let app: InstalledApp

    private var found: [Leftover] { state.leftovers(for: app) }
    private var chosen: [Leftover] { state.selectedLeftovers(for: app) }
    private var isLoading: Bool { state.loadingLeftovers.contains(app.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 应用信息
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: state.icon(for: app))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(app.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        if app.isRunning { Pill(text: "运行中", color: .green) }
                        if app.isSystem { Pill(text: "系统 App", color: .secondary) }
                    }
                    Text(app.bundleID ?? "无 Bundle ID")
                        .font(.system(size: 10.5).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(abbreviatePath(app.path))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(app.path)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            HStack(spacing: 14) {
                Stat(label: "App 体积", value: formatBytes(app.size))
                Stat(label: "残留文件", value: "\(found.count) 项")
                Stat(label: "残留体积", value: formatBytes(found.reduce(0) { $0 + $1.size }))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()

            HStack(spacing: 8) {
                Text("关联文件")
                    .font(.system(size: 12, weight: .semibold))
                if !found.isEmpty {
                    Text("已选 \(chosen.count)/\(found.count)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("全选") { state.selectAllLeftovers(for: app, selected: true) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .disabled(found.isEmpty)
                Button("全不选") { state.selectAllLeftovers(for: app, selected: false) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .disabled(found.isEmpty)
                Button {
                    state.loadLeftovers(for: app, force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("重新扫描关联文件")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Text("带「名称相似」标记的项目由名称推断，默认不勾选，请确认后再删除。")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            Divider()

            if isLoading {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在扫描关联文件…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if found.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("未发现可清理的残留文件").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Text(app.isSystem ? "系统 App 不可卸载" : "可能已清理，或数据存放在沙盒容器之外")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(found) { leftover in
                            LeftoverRow(leftover: leftover, app: app)
                            Divider().padding(.leading, 34)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if !app.isSystem {
                Divider()
                HStack(spacing: 8) {
                    Button {
                        state.setSelected(app, true)
                    } label: {
                        Label(state.isSelected(app) ? "已加入卸载列表" : "加入卸载列表",
                              systemImage: state.isSelected(app) ? "checkmark.square.fill" : "square")
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))
                    .disabled(state.isSelected(app))

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([app.url])
                    } label: {
                        Label("在 Finder 中显示", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))

                    Spacer()
                    Text(abbreviatePath(app.location))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }
}

struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LeftoverRow: View {
    @EnvironmentObject var state: AppState
    let leftover: Leftover
    let app: InstalledApp

    private var isOn: Binding<Bool> {
        Binding(
            get: { state.isLeftoverSelected(leftover, for: app) },
            set: { state.setLeftover(leftover, for: app, selected: $0) }
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .padding(.top, 1)

            Image(systemName: leftover.kind.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(leftover.name)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(leftover.kind.title)
                    Text("·")
                    Text(abbreviatePath(leftover.parentPath))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            if leftover.confidence == .medium {
                Pill(text: "名称相似", color: .orange)
            } else if leftover.confidence == .low {
                Pill(text: "低可信", color: .red)
            }
            if leftover.requiresAdmin {
                Pill(text: "管理员", color: .blue)
            }

            Text(formatBytes(leftover.size))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .help(leftover.url.path)
    }
}

// MARK: - 已选清单

struct SelectedBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(state.selectedApps) { app in
                    HStack(spacing: 4) {
                        Image(nsImage: state.icon(for: app))
                            .resizable()
                            .frame(width: 13, height: 13)
                        Text(app.name)
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                        Button {
                            state.removeFromSelection(app)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("从列表移除")
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
        .frame(height: 34)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - 底栏

struct FooterBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            if state.selection.isEmpty {
                Text("勾选 App 后可一键卸载，并清理缓存、偏好、容器与启动项等残留。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("已选 \(state.selection.count) 个 App · 预计释放 \(formatBytes(state.totalSelectedSize))")
                    .font(.system(size: 12, weight: .medium))
            }

            Spacer()

            Button("全不选") { state.clearSelection() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.selection.isEmpty)
            Button("全选") { state.selectAllVisible() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.filteredApps.isEmpty)

            Button {
                state.beginUninstall()
            } label: {
                Label("卸载所选", systemImage: "trash")
            }
            .buttonStyle(DangerButtonStyle(large: true))
            .disabled(state.selection.isEmpty || state.isUninstalling)
            .opacity(state.selection.isEmpty ? 0.45 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - 确认弹窗

struct ConfirmSheet: View {
    @EnvironmentObject var state: AppState

    private var items: [InstalledApp] { state.selectedApps }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 16))
                Text("确认卸载 \(items.count) 个 App")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }

            Text("预计释放 \(formatBytes(state.totalSelectedSize))。App 本体默认移入废纸篓，缓存、偏好、容器等残留将被删除。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: state.icon(for: app))
                                .resizable()
                                .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name).font(.system(size: 12, weight: .medium))
                                if state.leftovers[app.id] == nil {
                                    Text("正在扫描关联文件…")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("\(state.selectedLeftovers(for: app).count) 个关联项 · \(formatBytes(app.size + state.selectedLeftovers(for: app).reduce(0) { $0 + $1.size }))")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if app.isRunning {
                                Pill(text: "运行中", color: .green)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        Divider()
                    }
                }
            }
            .frame(height: 190)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15)))

            if state.protectedContainerCount > 0 {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: state.hasFullDiskAccess ? "checkmark.shield" : "exclamationmark.shield")
                        .font(.system(size: 10))
                        .foregroundStyle(state.hasFullDiskAccess ? Color.green : Color.orange)
                    Text(state.hasFullDiskAccess
                         ? "已获得完全磁盘访问权限，可清理 \(state.protectedContainerCount) 个受系统保护的容器。"
                         : "选中的 \(state.protectedContainerCount) 个沙盒容器需要「完全磁盘访问权限」，否则会被跳过。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !state.hasFullDiskAccess {
                        Button("去授权") { FullDiskAccess.openSettings() }
                            .buttonStyle(.link)
                            .font(.system(size: 10))
                    }
                }
            }

            if state.hasAdminTargets && state.optSystem {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("部分项目位于 /Library 或受系统保护，执行时会弹出一次管理员授权窗口。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("卸载前自动退出正在运行的 App", isOn: $state.optQuit)
                Toggle("同时清理系统级残留（/Library，需要管理员密码）", isOn: $state.optSystem)
                Toggle("清理 LaunchServices 注册与 TCC 隐私权限", isOn: $state.optRegistration)
                Toggle("永久删除（不放入废纸篓，无法恢复）", isOn: $state.optPermanent)
            }
            .font(.system(size: 11.5))
            .toggleStyle(.checkbox)

            if state.optPermanent {
                Text("警告：永久删除模式下，App 本体与所有残留都将直接移除，无法从废纸篓恢复。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            HStack {
                Button("取消") { state.showConfirm = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    state.startUninstall()
                } label: {
                    Label("开始卸载", systemImage: "trash.fill")
                }
                .buttonStyle(DangerButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620, height: 478)
    }
}

// MARK: - 残留清理

struct OrphanSheet: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "broom")
                    .font(.system(size: 16))
                    .foregroundStyle(.orange)
                Text("残留清理").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button {
                    state.scanOrphans()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(state.orphanLoading)
                .help("重新扫描")
            }

            Text("以下容器在「已安装 App」中找不到对应条目，通常是已经卸载但没清干净的数据。标有「同厂商」的项目可能是某个已安装 App 的扩展容器，默认不勾选，请确认后再删除。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if state.orphanLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(state.orphanProgress)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.orphanItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("没有发现孤儿容器残留").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Spacer()
                    Button("关闭") { state.showOrphanSheet = false }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                HStack(spacing: 10) {
                    Text("\(state.orphanItems.count) 项 · 已选 \(state.orphanSelection.count) · \(formatBytes(state.selectedOrphanSize))")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Button("全选") { state.selectAllOrphans(true) }
                        .buttonStyle(.plain).font(.system(size: 10.5))
                    Button("全不选") { state.selectAllOrphans(false) }
                        .buttonStyle(.plain).font(.system(size: 10.5))
                }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(state.orphanItems) { item in
                            OrphanRow(item: item)
                            Divider().padding(.leading, 34)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15)))

                if !state.hasFullDiskAccess {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.shield")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Text("容器受 TCC 保护，需要「完全磁盘访问权限」才能真正删除，否则会全部失败。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("去授权") { FullDiskAccess.openSettings() }
                            .buttonStyle(.link)
                            .font(.system(size: 10))
                    }
                }

                HStack {
                    Text("删除后不可恢复（如需保留请先备份）")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("取消") { state.showOrphanSheet = false }
                        .keyboardShortcut(.cancelAction)
                    Button {
                        state.cleanOrphans()
                    } label: {
                        Label("清理所选", systemImage: "trash")
                    }
                    .buttonStyle(DangerButtonStyle())
                    .disabled(state.orphanSelection.isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: 660, height: 560)
    }
}

struct OrphanRow: View {
    @EnvironmentObject var state: AppState
    let item: Leftover

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { state.isOrphanSelected(item) },
                set: { state.setOrphan(item, selected: $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Image(systemName: item.kind.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.kind.title) · \(abbreviatePath(item.parentPath))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            if item.confidence == .medium {
                Pill(text: "同厂商", color: .orange)
            }

            Text(formatBytes(item.size))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .help(item.url.path)
    }
}

// MARK: - 结果弹窗

struct ReportSheet: View {
    let report: UninstallReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: report.failures == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(report.failures == 0 ? Color.green : Color.orange)
                    .font(.system(size: 18))
                Text(report.appCount == 0
                     ? (report.failures == 0 ? "残留清理完成" : "残留清理完成（\(report.failures) 个问题）")
                     : (report.failures == 0 ? "卸载完成" : "卸载完成（\(report.failures) 个问题）"))
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }

            HStack(spacing: 18) {
                Stat(label: report.appCount == 0 ? "清理项目" : "处理 App",
                     value: report.appCount == 0 ? "\(report.entries.count) 项" : "\(report.appCount) 个")
                Stat(label: report.trashedSomething ? "已移入废纸篓" : "已释放空间",
                     value: formatBytes(report.freed))
                Stat(label: "异常", value: "\(report.failures) 项")
            }

            if report.trashedSomething {
                Text("以上项目都在废纸篓中，清空废纸篓后才会真正释放磁盘空间。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            if let hint = report.hint {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(hint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(report.entries) { entry in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: entry.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(entry.ok ? Color.green : Color.red)
                                .font(.system(size: 10))
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.text).font(.system(size: 11))
                                if let detail = entry.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.5)))

            HStack {
                if report.trashedSomething {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
                    } label: {
                        Label("打开废纸篓", systemImage: "trash")
                    }
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620, height: 520)
    }
}

// MARK: - 进度遮罩

struct ProgressOverlay: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            Color.black.opacity(0.22).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("正在卸载…").font(.system(size: 13, weight: .semibold))
                Text(state.progressText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 320)
            }
            .padding(26)
            .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.18)))
        }
    }
}

// MARK: - 小组件

struct Pill: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
    }
}


// MARK: - 危险操作按钮

struct DangerButtonStyle: ButtonStyle {
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 12.5 : 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 16 : 14)
            .padding(.vertical, large ? 8 : 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(red: 0.85, green: 0.22, blue: 0.24).opacity(configuration.isPressed ? 0.82 : 1))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}
