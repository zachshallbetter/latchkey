import AppKit
import LatchkeyCore
import SwiftUI

extension ItemKind {
    var symbol: String {
        switch self {
        case .token: return "key.fill"
        case .password: return "lock.fill"
        case .key: return "key.horizontal.fill"
        case .value: return "tag.fill"
        }
    }

    var tint: Color {
        switch self {
        case .token: return .blue
        case .password: return .orange
        case .key: return .purple
        case .value: return .gray
        }
    }
}

struct KindIcon: View {
    let kind: ItemKind
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(kind.tint.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: kind.symbol).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white))
    }
}

/// The Latchkey key, tinted like an SF Symbol so it follows the context it sits in.
struct LogoMark: View {
    var size: CGFloat = 44
    var body: some View {
        Image("Logo").resizable().renderingMode(.template).scaledToFit().frame(width: size, height: size)
    }
}

struct MainWindow: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppPreferences.Key.appearance) private var appearance = "system"

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 320)
        } content: {
            Group {
                if model.filter == .settings {
                    SettingsSectionList(model: model)
                } else if model.filter == .overview {
                    ReviewList(model: model)
                } else if model.filter == .activity {
                    ActivityList(model: model)
                } else if model.filter == .grants {
                    GrantList(model: model)
                } else if model.filter == .deleted {
                    DeletedList(model: model)
                } else {
                    ItemList(model: model)
                }
            }
            .navigationSplitViewColumnWidth(min: model.filter == .settings ? 220 : 300, ideal: model.filter == .settings ? 250 : 360)
        } detail: {
            if model.filter == .settings {
                SettingsView(model: model).frame(minWidth: 360)
            } else if model.filter == .overview {
                if let f = model.findings.first(where: { $0.id == model.selectedFinding }) { FindingDetail(model: model, finding: f).id(f.id) }
                else { EmptyDetail(model: model) }
            } else if model.filter == .activity {
                if let e = model.log.first(where: { $0.key == model.selectedLog }) { ActivityDetail(entry: e).id(e.key) }
                else { EmptyDetail(model: model) }
            } else if model.filter == .deleted {
                if let v = model.deleted.first(where: { $0.id == model.selectedVersion }) { DeletedDetail(model: model, version: v).id(v.id) }
                else { EmptyDetail(model: model) }
            } else if model.filter == .grants {
                if let g = model.grants.first(where: { $0.id == model.selectedGrant }) { GrantDetail(model: model, grant: g).id(g.id) }
                else { EmptyDetail(model: model) }
            } else if model.filter.listsItems, let item = model.selectedItem {
                ItemDetail(model: model, item: item).id(item.name)
            } else if model.filter.listsItems, model.selection.count > 1 {
                BulkPanel(model: model, ids: model.selection.sorted())
            } else {
                EmptyDetail(model: model)
            }
        }
        .onChange(of: appearance) { _, value in applyAppearance(value) }
        .onDisappear { model.concealRevealedValues() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if AppPreferences().hideOnDeactivate { model.concealRevealedValues() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { NoticeBar(model: model) }
        .sheet(isPresented: $model.showingAdd) { AddItemSheet(model: model) }
        .sheet(item: $model.importDraft) { ImportSheet(model: model, draft: $0) }
        .sheet(item: $model.nextSteps) { NextStepsSheet(steps: $0) }
        .sheet(isPresented: $model.showingUpgrade) { UpgradeSheet(model: model) }
        .sheet(item: $model.grantRequest) { NewGrantSheet(model: model, request: $0) }
        .sheet(item: $model.remoteRequest) { RemoteSheet(model: model, scope: $0.scope) }
        .sheet(item: $model.exportRequest) { ExportSheet(model: model, scope: $0.scope) }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { model.deleteRequest != nil },
                                                              set: { if !$0 { model.deleteRequest = nil } }),
                            presenting: model.deleteRequest) { request in
            Button("Delete \(request.ids.count == 1 ? request.ids[0] : "\(request.ids.count) Items")", role: .destructive) {
                Task { await model.removeItems(request.ids) }
            }
        } message: { request in
            Text(deleteMessage(request.ids))
        }
        .sheet(item: $model.moveRequest) { MoveSheet(model: model, preselected: $0.ids) }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.filter != .settings, let url = urls.first else { return false }
            model.beginImport(url)
            return true
        }
        .onAppear {
            applyAppearance(appearance)
            model.refresh()
            #if !LATCHKEY_APP_STORE
            if Welcome.shouldOpenAtLaunch(hasItems: !model.items.isEmpty) { openWindow(id: Welcome.windowID) }
            #endif
            #if DEBUG
            Snapshot.runIfRequested(model)
            #endif
        }
    }
}

extension MainWindow {
    private func applyAppearance(_ value: String) {
        NSApp.appearance = value == "dark" ? NSAppearance(named: .darkAqua) : value == "light" ? NSAppearance(named: .aqua) : nil
    }

    var deleteTitle: String {
        guard let ids = model.deleteRequest?.ids else { return "Delete?" }
        return ids.count == 1 ? "Delete \(ids[0])?" : "Delete \(ids.count) items?"
    }

    func deleteMessage(_ ids: [String]) -> String {
        let place = model.synced ? " on all your Macs" : ""
        let days = Int(Versions.deletedFor / 86400)
        let files = model.files(for: ids)
        if files.isEmpty {
            return "They move to Recently Deleted\(place) and can be restored for \(days) days. Until then, files that refer to them stop working."
        }
        let shown = files.prefix(4).map(Broker.tilde).joined(separator: ", ") + (files.count > 4 ? ", …" : "")
        return "They move to Recently Deleted\(place) and can be restored for \(days) days. Until then these files stop working: \(shown)."
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        LogoMark(size: 30).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Latchkey").font(.title3.weight(.semibold))
                            Text("Development secrets").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8).padding(.top, 2)
                    Divider().padding(.vertical, 12).padding(.horizontal, 8)

                    nav(.all, "square.grid.2x2", count: model.items.count)
                    NavRow(title: SidebarFilter.overview.title, symbol: "shield", count: model.findings.isEmpty ? nil : model.findings.count,
                           badge: true, selected: model.filter == .overview) { model.filter = .overview }
                    nav(.activity, "waveform.path.ecg")

                    if !model.items.isEmpty {
                        SidebarSection(model: model, title: "Projects") {
                            ForEach(model.projects, id: \.self) { p in
                                NavRow(title: p, symbol: "folder", count: model.count(.project(p)), selected: model.filter == .project(p)) { model.filter = .project(p) }
                                    .contextMenu { ProjectMenu(model: model, project: p) }
                            }
                            if model.items.contains(where: { $0.ref.isShared }) {
                                NavRow(title: "Shared", symbol: "tray.full", count: model.count(.shared), selected: model.filter == .shared) { model.filter = .shared }
                            }
                        }
                        if !model.services.isEmpty {
                            SidebarSection(model: model, title: "Services") {
                                ForEach(model.services, id: \.self) { s in
                                    ServiceRow(name: s, count: model.count(.service(s)), selected: model.filter == .service(s)) { model.filter = .service(s) }
                                }
                            }
                        }
                    }

                    Divider().padding(.vertical, 10).padding(.horizontal, 8)
                    nav(.grants, "checkmark.shield", count: model.grants.isEmpty ? nil : model.grants.count)
                    nav(.deleted, "trash", count: model.deleted.isEmpty ? nil : model.deleted.count)
                }
                .padding(10)
            }
            Divider().padding(.horizontal, 18)
            nav(.settings, "gearshape").padding(.horizontal, 10).padding(.top, 8)
            StorageBadge(model: model).padding(10)
        }
    }

    private func nav(_ filter: SidebarFilter, _ symbol: String, count: Int? = nil) -> some View {
        NavRow(title: filter.title, symbol: symbol, count: count, selected: model.filter == filter) { model.filter = filter }
    }
}

/// A sidebar heading that folds its rows away.
struct SidebarSection<Content: View>: View {
    let model: AppModel
    let title: String
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        let collapsed = model.collapsedSections.contains(title)
        Button {
            withAnimation(.snappy) {
                if collapsed { model.collapsedSections.remove(title) } else { model.collapsedSections.insert(title) }
            }
        } label: {
            HStack {
                Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                Spacer()
                // Shown on hover, or while folded, so the headings stay quiet.
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .opacity(collapsed || hovering ? 1 : 0)
            }
            .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(title), \(collapsed ? "collapsed" : "expanded")")
        if !collapsed { content() }
    }
}

/// A service in the sidebar: its initial in a small tile, its name, and how many items it issued.
struct ServiceRow: View {
    let name: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(selected ? Color.white.opacity(0.8) : Color.secondary.opacity(0.6), lineWidth: 1.2)
                    .frame(width: 20, height: 20)
                    .overlay(Text(String(name.prefix(1)).uppercased()).font(.system(size: 11, weight: .bold))
                        .foregroundStyle(selected ? Color.white : Color.secondary))
                Text(name).lineLimit(1).foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 4)
                Text("\(count)").monospacedDigit().foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct StorageBadge: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: model.synced ? "icloud" : "desktopcomputer").foregroundStyle(.secondary)
                Text(model.synced ? "iCloud Keychain" : "This Mac only").font(.callout.weight(.medium))
                Spacer(minLength: 4)
                Circle().fill(model.problem == nil ? (model.synced ? Color.green : Color.orange) : Color.red).frame(width: 7, height: 7)
                Text(model.problem == nil ? (model.synced ? "On" : "Local") : "Problem").font(.caption).foregroundStyle(.secondary)
            }
            if let p = model.problem {
                Text(p).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        .help(model.synced
              ? "Items are kept in iCloud Keychain and sync to your Macs signed in to the same Apple Account. Latchkey can't confirm when another Mac has received a change."
              : "Items are kept in this Mac's login keychain and don't sync. See Settings.")
    }
}

// MARK: - Lists

struct ItemList: View {
    @Bindable var model: AppModel

    @FocusState private var searching: Bool

    var body: some View {
        let list = model.visibleItems
        VStack(spacing: 0) {
            ListHeader(model: model, count: list.count, searching: $searching)
            itemList(list)
        }
        .navigationTitle(model.filter.title)
        .toolbar(removing: .title)
    }

    /// Every item that matches, in one list, as 1Password lists them: each row says its project and environment
    /// unless the view already does.
    @ViewBuilder
    private func itemList(_ list: [SecretInfo]) -> some View {
        let inProject: Bool = { if case .project = model.filter { return true } else { return false } }()
        List(selection: $model.selection) {
            ForEach(list) { item in
                ItemRow(model: model, item: item, showsProject: !inProject,
                        showsEnvironment: model.environmentFilter == nil, remote: model.remoteStates[item.name])
                    .tag(item.name)
                    .listRowSeparator(.visible)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty { SelectionMenu(model: model, ids: ids.sorted()) }
        }
        // The Item menu acts on the selected rows that are shown, and only while the list has focus.
        .focusedValue(\.itemSelection, list.map(\.name).filter(model.selection.contains))
        .onDeleteCommand {
            let ids = list.map(\.name).filter(model.selection.contains)
            if !ids.isEmpty { model.deleteRequest = DeleteRequest(ids: ids) }
        }
        .overlay { emptyOverlay(list) }
    }

    @ViewBuilder
    private func emptyOverlay(_ list: [SecretInfo]) -> some View {
            if list.isEmpty {
                ContentUnavailableView {
                    Label { Text(model.items.isEmpty ? "No Items Yet" : "No Matches") } icon: { LogoMark() }
                } description: {
                    Text(model.items.isEmpty
                         ? "Add a token, or drop a .env file here to import it."
                         : "Nothing in \(model.filter.title) matches.")
                } actions: {
                    if model.items.isEmpty {
                        Button("New Item…") { model.showingAdd = true }
                        Button("Import .env File…") { model.chooseImportFile() }
                    }
                }
            }
    }
}

/// The list's top: what's shown and how many, the New Item button, and the search field (⌘F).
struct ListHeader: View {
    @Bindable var model: AppModel
    let count: Int
    var searching: FocusState<Bool>.Binding

    private var subtitle: String {
        var parts = ["\(count) item\(count == 1 ? "" : "s")"]
        switch model.filter {
        case .project(let p):
            let envs = model.environments(in: p)
            parts.append(envs.count == 1 ? envs[0] : "\(envs.count) environments")
        case .all where model.search.isEmpty:
            let projects = model.projects.count, services = model.services.count
            parts.append("\(projects) project\(projects == 1 ? "" : "s")")
            if services > 0 { parts.append("\(services) service\(services == 1 ? "" : "s")") }
        default:
            break
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.filter.title).font(.title2.weight(.semibold)).lineLimit(1)
                    if case .project(let p) = model.filter {
                        HStack(spacing: 6) {
                            ForEach(model.environments(in: p), id: \.self) { EnvBadge(environment: $0, compact: true).fixedSize() }
                            Text("· \(count) item\(count == 1 ? "" : "s")").font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                    ViewThatFits(in: .horizontal) {
                        Text(subtitle).fixedSize()
                        Text("\(count) item\(count == 1 ? "" : "s")")
                    }
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button { model.showingAdd = true } label: { Label("New Item", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).fixedSize()
                    .help("Add a token, password, key or value")
            }
            HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search items…", text: $model.search).textFieldStyle(.plain).focused(searching)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                } else {
                    Text("⌘F").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary.opacity(0.8)))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.8)))
            .background(Button("") { searching.wrappedValue = true }.keyboardShortcut("f").hidden())
            }
            FilterBar(model: model)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
    }
}

/// Dropdowns under the search field: type, environment, project and service, each showing its choice, then a menu for
/// sort order, access, importing and moving.
struct FilterBar: View {
    @Bindable var model: AppModel

    private var project: String? { if case .project(let p) = model.filter { return p } else { return nil } }
    private var service: String? { if case .service(let s) = model.filter { return s } else { return nil } }

    var body: some View {
        HStack(spacing: 6) {
            pill("Type", model.categoryFilter) {
                Button("Any Type") { model.categoryFilter = nil }
                Divider()
                ForEach(model.categories, id: \.self) { c in Button(c) { model.categoryFilter = c } }
            }
            pill("Environment", model.environmentFilter) {
                Button("Any Environment") { model.environmentFilter = nil }
                Divider()
                ForEach(model.allEnvironments, id: \.self) { e in Button(e) { model.environmentFilter = e } }
            }
            pill("Project", project) {
                Button("Any Project") { model.filter = .all }
                Divider()
                ForEach(model.projects, id: \.self) { p in Button(p) { model.filter = .project(p) } }
                Button("Shared") { model.filter = .shared }
            }
            pill("Service", service.map { $0.isEmpty ? "None" : $0 }) {
                Button("Any Service") { model.filter = .all }
                Divider()
                ForEach(model.services, id: \.self) { s in Button(s) { model.filter = .service(s) } }
            }
            Spacer(minLength: 0)
            Menu {
                Picker("Sort By", selection: $model.sort) {
                    ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Access", selection: $model.accessFilter) {
                    Text("Any Access").tag(Bool?.none)
                    Text("No Approval").tag(Bool?.some(true))
                    Text("Ask First").tag(Bool?.some(false))
                }
                if model.filtersActive || project != nil || service != nil {
                    Divider()
                    Button("Clear Filters") { model.clearFilters(); model.filter = .all }
                }
                Divider()
                Button("Import .env File…") { model.chooseImportFile() }
                if !model.selection.isEmpty {
                    Button("Move Selected to a Project…") { model.moveRequest = MoveRequest(ids: model.selection.sorted()) }
                }
            } label: {
                Image(systemName: "line.3.horizontal").foregroundStyle(model.accessFilter == nil ? Color.secondary : Color.accentColor)
                    .frame(width: 30, height: 26)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.3)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator.opacity(0.8)))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusEffectDisabled()
            .help("Sort order, access, import and move")
        }
    }

    /// A dropdown that names its choice, highlighted while one is made.
    private func pill<Items: View>(_ title: String, _ choice: String?, @ViewBuilder _ items: () -> Items) -> some View {
        Menu { items() } label: {
            HStack(spacing: 4) {
                Text(choice ?? title).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.callout)
            .foregroundStyle(choice == nil ? Color.primary : Color.accentColor)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(choice == nil ? AnyShapeStyle(.quaternary.opacity(0.3)) : AnyShapeStyle(Color.accentColor.opacity(0.15))))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator.opacity(0.8)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusEffectDisabled()
    }
}

/// A page's title and summary, for views without the item list's header.
struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
    }
}

struct ItemRow: View {
    var model: AppModel? = nil
    let item: SecretInfo
    var showsProject = true
    var showsEnvironment = false
    /// Out of date or never pushed somewhere this item's environment is linked.
    var remote: RemoteState? = nil
    @State private var hovering = false

    /// Project · environment · service, leaving out what the view already says. In a project's view: type · service,
    /// with the environment as a badge on the right.
    private var subtitle: String {
        var parts: [String] = []
        if !showsProject && !item.ref.isShared { parts.append(ItemType(item).label) }
        else if item.ref.isShared { parts.append("Shared") }
        else {
            parts.append(item.ref.project)
            if showsEnvironment { parts.append(item.ref.environment) }
        }
        if let s = item.service { parts.append(s) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let type = ItemType(item)
        HStack(spacing: 12) {
            Image(systemName: type.symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(type.tint).frame(width: 24)
                .help(type.label)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.ref.name).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if !showsProject && showsEnvironment && !item.ref.isShared {
                EnvBadge(environment: item.ref.environment, compact: true).fixedSize()
            }
            if hovering, let model {
                Button { model.copyReference(item.name) } label: { Image(systemName: "link") }
                    .buttonStyle(.borderless).help("Copy latchkey://\(item.name)")
            }
            if remote == .outOfDate {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                    .help("Changed since it was last pushed to a remote location")
            } else if remote == .notPushed {
                Image(systemName: "icloud.slash").foregroundStyle(.secondary)
                    .help("Not pushed yet to a remote location its environment is linked to")
            }
            if item.agentSafe {
                Image(systemName: "person.badge.shield.checkmark.fill").foregroundStyle(.green)
                    .help("Any program in your Mac account may request this value without approval")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(item.name)
    }
}

/// What can be done to the selected items, with shortcuts: the right-click menu and the menu bar's Item menu. Copying a
/// value takes one item; everything else applies to all of them with one approval.
struct SelectionMenu: View {
    let model: AppModel
    let ids: [String]

    var body: some View {
        let items = ids.compactMap { model.item($0) }
        let several = items.count > 1
        Button("Copy Value") { if let item = items.first { Task { await model.copyValue(item.name) } } }
            .keyboardShortcut("c", modifiers: [.command, .option]).disabled(items.count != 1)
        Button(several ? "Copy \(items.count) References" : "Copy Reference") { model.copyReferences(items.map(\.name)) }
            .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(items.isEmpty)
        Button("Copy as Env File Lines") { model.copyReferences(items.map(\.name), envLines: true) }
            .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(items.isEmpty)
        Divider()
        let allSafe = !items.isEmpty && items.allSatisfy(\.agentSafe)
        Button(allSafe ? "Require Approval" : "Let Agents Read Without Asking") {
            Task { await model.updateItems(items.map(\.name), agentSafe: !allSafe) }
        }
        .keyboardShortcut("a", modifiers: [.command, .option]).disabled(items.isEmpty)
        Menu("Kind") {
            ForEach(ItemKind.allCases, id: \.self) { k in
                Button(k.label) { Task { await model.updateItems(items.map(\.name), kind: k) } }
            }
        }
        .disabled(items.isEmpty)
        Button("Move to a Project…") { model.moveRequest = MoveRequest(ids: items.map(\.name)) }
            .keyboardShortcut("m", modifiers: [.command, .shift]).disabled(items.isEmpty)
        Button("Grant Access…") { model.grantRequest = GrantRequest(ids: items.map(\.name)) }
            .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(items.isEmpty)
        Divider()
        Button(several ? "Delete \(items.count) Items…" : "Delete…", role: .destructive) {
            model.deleteRequest = DeleteRequest(ids: items.map(\.name))
        }
        .keyboardShortcut(.delete, modifiers: .command).disabled(items.isEmpty)
    }
}

extension FocusedValues {
    /// The rows selected in the item list while it has focus, so the Item menu never acts on keys typed into a field.
    @Entry var itemSelection: [String]?
}

/// The menu bar's Item menu: the selection menu, for the rows selected in the focused list.
struct ItemCommands: Commands {
    let model: AppModel
    @FocusedValue(\.itemSelection) private var selection

    var body: some Commands {
        CommandMenu("Item") {
            SelectionMenu(model: model, ids: selection ?? [])
        }
    }
}

extension AppModel {
    /// One `latchkey://` reference per line, or `NAME=latchkey://ID` lines to paste into an env file.
    func copyReferences(_ ids: [String], envLines: Bool = false) {
        guard !ids.isEmpty else { return }
        if ids.count == 1 && !envLines { return copyReference(ids[0]) }
        let lines = ids.map { envLines ? "\(ItemID($0)?.name ?? $0)=\(References.scheme)\($0)" : References.scheme + $0 }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n") + (envLines ? "\n" : ""), forType: .string)
        notice = "Copied \(ids.count) \(envLines ? "env file line" : "reference")\(ids.count == 1 ? "" : "s")."
    }
}

/// Shown in the detail pane when several items are selected.
struct BulkPanel: View {
    let model: AppModel
    let ids: [String]
    @State private var service = ""

    var body: some View {
        let items = ids.compactMap { model.item($0) }
        let projects = Set(items.map { $0.ref.isShared ? "Shared" : $0.ref.project })
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(items.count) items selected").font(.title2.weight(.semibold))
                    Text(projects.count == 1 ? "In \(projects.first!)" : "Across \(projects.count) projects")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section {
                LabeledContent("Agents") {
                    HStack {
                        Button("Require Approval") { Task { await model.updateItems(ids, agentSafe: false) } }
                        Button("Let Agents Read") { Task { await model.updateItems(ids, agentSafe: true) } }
                    }
                }
                LabeledContent("Kind") {
                    Menu("Set Kind") {
                        ForEach(ItemKind.allCases, id: \.self) { k in
                            Button(k.label) { Task { await model.updateItems(ids, kind: k) } }
                        }
                    }
                    .fixedSize()
                }
                LabeledContent("Service") {
                    HStack {
                        TextField("", text: $service, prompt: Text("Stripe, Neon…")).frame(maxWidth: 180)
                        Button("Set") { Task { await model.updateItems(ids, service: service) } }
                    }
                }
            } footer: {
                Text("Each change applies to all \(items.count) items and asks for Touch ID once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Copy \(items.count) References") { model.copyReferences(items.map(\.name)) }
                Button("Copy as Env File Lines") { model.copyReferences(items.map(\.name), envLines: true) }
                Button("Move to a Project…") { model.moveRequest = MoveRequest(ids: ids) }
                Button("Grant Access…") { model.grantRequest = GrantRequest(ids: ids) }
            } footer: {
                Text("⌘-click or Shift-click rows to change the selection, and ⌘A to select every row shown. The Item menu's shortcuts act on every selected row.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Delete \(items.count) Items…", role: .destructive) { model.deleteRequest = DeleteRequest(ids: ids) }
            }
        }
        .formStyle(.grouped)
    }
}

struct EmptyDetail: View {
    let model: AppModel

    var body: some View {
        if model.filter == .activity {
            ContentUnavailableView("Activity", systemImage: "clock.arrow.circlepath",
                                   description: Text("Who read or changed what, from where. Values are never logged."))
        } else if model.filter == .deleted {
            ContentUnavailableView("Recently Deleted", systemImage: "trash",
                                   description: Text("Deleted items can be brought back for \(Int(Versions.deletedFor / 86400)) days, with the settings they had."))
        } else if model.filter == .grants {
            ContentUnavailableView("Grants", systemImage: "hourglass",
                                   description: Text("A grant lets commands run from one folder read some items without asking, until it ends. Make one before you step away from an agent, or choose “Allow from this folder” on an approval."))
        } else {
            ContentUnavailableView {
                Label { Text("No Item Selected") } icon: { LogoMark() }
            } description: {
                Text("Files keep latchkey://ID references; Latchkey keeps the values.")
            }
        }
    }
}

struct NoticeBar: View {
    @Bindable var model: AppModel

    var body: some View {
        if let n = model.notice {
            HStack {
                Image(systemName: "info.circle")
                Text(n).lineLimit(2)
                Spacer()
                Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.bar)
            .task(id: n) {
                try? await Task.sleep(for: .seconds(8))
                if model.notice == n { model.notice = nil }
            }
        }
    }
}

/// Where an environment's values live: the services it's linked to, or "Local" when it's only used from files on
/// this Mac, so a header answers "is this what Vercel has?" without opening anything.
struct PlaceLabel: View {
    let links: [RemoteLink]
    let local: Bool

    var body: some View {
        let services = Array(Set(links.map(\.target.service))).sorted { $0.rawValue < $1.rawValue }
        if !services.isEmpty {
            Label(services.map { $0.label.replacingOccurrences(of: " Actions", with: "") }.joined(separator: ", "), systemImage: "icloud")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            .help("Linked: \(links.map(\.target.label).joined(separator: "; "))")
        } else if local {
            Label("Local", systemImage: "laptopcomputer")
                .font(.caption).foregroundStyle(.secondary)
            .help("Used from files on this Mac; not linked to Vercel, GitHub Actions, Railway or Fly")
        } else {
            Text("Not linked").font(.caption).foregroundStyle(.tertiary)
        }
    }
}
