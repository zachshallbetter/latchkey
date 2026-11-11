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

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 320)
        } content: {
            Group {
                if model.filter == .overview {
                    ReviewView(model: model)
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
            .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            if model.filter.listsItems, let item = model.selectedItem {
                ItemDetail(model: model, item: item).id(item.name)
            } else if model.filter.listsItems, model.selection.count > 1 {
                BulkPanel(model: model, ids: model.selection.sorted())
            } else {
                EmptyDetail(model: model)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { NoticeBar(model: model) }
        .sheet(isPresented: $model.showingAdd) { AddItemSheet(model: model) }
        .sheet(item: $model.importDraft) { ImportSheet(model: model, draft: $0) }
        .sheet(item: $model.nextSteps) { NextStepsSheet(steps: $0) }
        .sheet(item: $model.grantRequest) { NewGrantSheet(model: model, request: $0) }
        .sheet(item: $model.remoteRequest) { RemoteSheet(model: model, scope: $0.scope) }
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
            guard let url = urls.first else { return false }
            model.beginImport(url)
            return true
        }
        .onAppear {
            model.refresh()
            #if DEBUG
            Snapshot.runIfRequested(model)
            #endif
        }
    }
}

extension MainWindow {
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
                    nav(.overview, "shield", count: model.reviewCount > 0 ? model.reviewCount : nil)
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
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            SelectionMenu(model: model, ids: ids.sorted())
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

/// The list's top: what's shown and how many, its menu, and the search field (⌘F).
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
            let projects = model.projects.count, shared = model.count(.shared)
            parts.append("\(projects) project\(projects == 1 ? "" : "s")")
            if shared > 0 { parts.append("\(shared) shared") }
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
                    ViewThatFits(in: .horizontal) {
                        Text(subtitle).fixedSize()
                        Text("\(count) item\(count == 1 ? "" : "s")")
                    }
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Menu {
                    Button("New Item…") { model.showingAdd = true }
                    Button("Import .env File…") { model.chooseImportFile() }
                    if !model.selection.isEmpty {
                        Divider()
                        Button("Move Selected to a Project…") { model.moveRequest = MoveRequest(ids: model.selection.sorted()) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button).buttonStyle(.bordered).menuIndicator(.hidden).fixedSize().focusEffectDisabled()
                .help("New item, import, move")
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
/// access and sort order.
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
            } label: {
                Image(systemName: "line.3.horizontal").foregroundStyle(model.accessFilter == nil ? Color.secondary : Color.accentColor)
                    .frame(width: 30, height: 26)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.3)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator.opacity(0.8)))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusEffectDisabled()
            .help("Sort order and access")
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

/// Review: what may need a look, the way 1Password's Watchtower lists what to fix. Each card leads to the items.
struct ReviewView: View {
    let model: AppModel

    var body: some View {
        let stale = model.items.filter { model.remoteStates[$0.name] == .outOfDate }
        let unpushed = model.items.filter { model.remoteStates[$0.name] == .notPushed }
        let open = model.items.filter(\.agentSafe)
        let unnamed = model.items.filter { $0.service == nil }
        let soon = model.grants.filter { $0.expires.timeIntervalSinceNow < 3600 }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "Review", subtitle: model.reviewCount == 0 ? "Nothing needs a look" : "\(model.reviewCount) thing\(model.reviewCount == 1 ? "" : "s") to look at")
                if model.reviewCount == 0 {
                    Card {
                        HStack(spacing: 12) {
                            IconTile(symbol: "checkmark", tint: .green, size: 32)
                            Text("Every pushed value is current, and nothing is waiting on you.").foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)
                    }
                }
                if !stale.isEmpty {
                    ReviewCard(symbol: "arrow.triangle.2.circlepath", tint: .orange, title: "Changed since last push",
                               detail: "These values changed in Latchkey after they were pushed. Push again so the services have them.",
                               items: stale, model: model)
                }
                if !unpushed.isEmpty {
                    ReviewCard(symbol: "icloud.slash", tint: .blue, title: "Not pushed yet",
                               detail: "Their environment is linked to a service that doesn't have them yet.", items: unpushed, model: model)
                }
                if !soon.isEmpty {
                    ReviewLink(symbol: "hourglass", tint: .teal, title: "Grants ending within the hour",
                               detail: "Commands relying on them will start asking again.", count: soon.count) { model.filter = .grants }
                }
                Text("For reference").font(.headline).padding(.top, 6)
                ReviewLink(symbol: "person.badge.shield.checkmark.fill", tint: .green, title: "Readable without approval",
                           detail: "Any program in your Mac account can read these. Fine for values that aren't really secret.",
                           count: open.count) { model.filter = .agentSafe }
                ReviewLink(symbol: "server.rack", tint: .gray, title: "No service named",
                           detail: "Naming the service adds a link to make a new key there, and lists the item under Services.",
                           count: unnamed.count) { model.filter = .service("") }
                ReviewLink(symbol: "hourglass", tint: .teal, title: "Grants in effect",
                           detail: "Folders whose commands read items without asking, until each grant ends.",
                           count: model.grants.count) { model.filter = .grants }
            }
            .padding(16)
        }
        .navigationTitle("Review")
        .toolbar(removing: .title)
    }
}

/// A Review finding with the items it's about, each opening its detail.
struct ReviewCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let items: [SecretInfo]
    let model: AppModel

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: symbol, tint: tint, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text("\(items.count)").font(.title3.weight(.semibold).monospacedDigit())
            }
            .padding(.vertical, 12)
            ForEach(items.prefix(6)) { item in
                Divider()
                Button {
                    model.filter = .all
                    model.selection = [item.name]
                } label: {
                    ItemRow(item: item).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if items.count > 6 {
                Divider()
                Text("and \(items.count - 6) more").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            }
        }
    }
}

/// A Review line that leads to a filtered list.
struct ReviewLink: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: symbol, tint: tint, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text("\(count)").font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.callout.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 4)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
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

    /// Project · environment · service, leaving out what the view already says; the type when nothing else is left.
    private var subtitle: String {
        var parts: [String] = []
        if item.ref.isShared { parts.append("Shared") } else {
            if showsProject { parts.append(item.ref.project) }
            if showsEnvironment { parts.append(item.ref.environment) }
        }
        if let s = item.service { parts.append(s) }
        return parts.isEmpty ? ItemType(item).label : parts.joined(separator: " · ")
    }

    var body: some View {
        let type = ItemType(item)
        HStack(spacing: 12) {
            Image(systemName: type.symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(type.tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.ref.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
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
        .listRowSeparator(.hidden)
    }
}

/// The right-click menu for the selected items; with one item it also copies.
struct SelectionMenu: View {
    let model: AppModel
    let ids: [String]

    var body: some View {
        let items = ids.compactMap { model.item($0) }
        if items.count == 1, let item = items.first {
            Button("Copy Value") { Task { await model.copyValue(item.name) } }
            Button("Copy Reference") { model.copyReference(item.name) }
            Divider()
        }
        if !items.isEmpty {
            let allSafe = items.allSatisfy(\.agentSafe)
            Button(allSafe ? "Require Approval" : "Let Agents Read Without Asking") {
                Task { await model.updateItems(ids, agentSafe: !allSafe) }
            }
            Menu("Kind") {
                ForEach(ItemKind.allCases, id: \.self) { k in
                    Button(k.label) { Task { await model.updateItems(ids, kind: k) } }
                }
            }
            Button("Move to a Project…") { model.moveRequest = MoveRequest(ids: ids) }
            Button("Grant Access…") { model.grantRequest = GrantRequest(ids: ids) }
            Divider()
            Button(items.count == 1 ? "Delete…" : "Delete \(items.count) Items…", role: .destructive) {
                model.deleteRequest = DeleteRequest(ids: ids)
            }
        }
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
                Button("Move to a Project…") { model.moveRequest = MoveRequest(ids: ids) }
                Button("Grant Access…") { model.grantRequest = GrantRequest(ids: ids) }
            }
            Section {
                Button("Delete \(items.count) Items…", role: .destructive) { model.deleteRequest = DeleteRequest(ids: ids) }
            }
        }
        .formStyle(.grouped)
    }
}

struct ActivityList: View {
    let model: AppModel

    var body: some View {
        let entries = model.visibleLog
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Activity", subtitle: "\(entries.count) entries · values are never logged")
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            List(Array(entries.enumerated()), id: \.offset) { _, e in
                ActivityRow(entry: e, showNames: true).listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No Activity", systemImage: "clock",
                                       description: Text("Every read and change shows up here, never the values."))
            }
        }
        .navigationTitle("Activity")
        .toolbar(removing: .title)
    }
}

/// One access-log entry on one line: what happened to what, then who asked and when; the rest is in its tooltip.
struct ActivityRow: View {
    let entry: Broker.LogEntry
    var showNames = true

    var icon: (String, Color) {
        let d = entry.decision
        if d.hasPrefix("denied") || d.hasPrefix("refused") { return ("xmark.circle.fill", .red) }
        if d.hasPrefix("approved") { return ("touchid", .blue) }
        return ("checkmark.circle.fill", .green)
    }

    /// What happened, in a word or two, past tense.
    var verb: String {
        switch entry.op {
        case "get": return "Read"
        case "set": return "Saved"
        case "rm": return "Deleted"
        case "import": return "Imported"
        case "update": return "Settings changed"
        case "move": return "Moved"
        case "grant": return "Granted"
        case "revoke": return "Grant revoked"
        case "restore": return "Restored"
        case "forget": return "History forgotten"
        case "version": return "Earlier value shown"
        case "fill": return "Filled in Safari"
        case "export": return "Exported"
        case "push": return "Pushed"
        case "link": return "Linked"
        case "unlink": return "Unlinked"
        case "environment-add", "environment-set", "environment-remove": return "Record changed"
        case "project-link", "project-unlink": return "Remotes changed"
        default: return entry.op.prefix(1).uppercased() + entry.op.dropFirst()
        }
    }

    /// The one item or environment, shortened to its name, or how many.
    private var subject: String {
        guard let first = entry.names.first else { return "" }
        if entry.names.count > 1 { return "\(entry.names.count) items" }
        return ItemID(first)?.name ?? first
    }

    private var place: (project: String, environment: String)? {
        guard entry.names.count == 1, let first = entry.names.first else { return nil }
        let parts = first.split(separator: "/").map(String.init)
        return parts.count >= 2 ? (parts[0], parts[1]) : nil
    }

    private var who: String {
        if let p = entry.program { return p }
        let shells: Set<String> = ["zsh", "bash", "sh", "fish", "login", "sudo", "env", "tmux", "screen", "sshd-session", "latchkey", "lk"]
        let name = entry.chain.first { !shells.contains($0.lowercased()) } ?? entry.chain.first ?? ""
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Approved, denied, allowed or refused; nothing for entries whose verb already says it (a revoke).
    private var outcome: String {
        let word = entry.decision.split(separator: " ").first.map(String.init) ?? entry.decision
        guard ["approved", "denied", "allowed", "refused"].contains(word) else { return "" }
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon.0).foregroundStyle(icon.1).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(showNames && !subject.isEmpty ? subject : verb).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if showNames, let place {
                        Chip(text: place.project).font(.caption)
                        EnvBadge(environment: place.environment, compact: true).fixedSize()
                    }
                }
                Text([showNames && !subject.isEmpty ? verb : nil, outcome, who].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(entry.time.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary).fixedSize()
        }
        .padding(.vertical, 4)
        .help([entry.names.joined(separator: ", "), entry.decision, entry.chain.joined(separator: " › "),
               entry.cwd.isEmpty ? "" : Broker.tilde(entry.cwd), entry.command.map { "$ \($0)" } ?? ""]
              .filter { !$0.isEmpty }.joined(separator: "\n"))
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

/// Items deleted in the last 30 days, with a way back.
struct DeletedList: View {
    let model: AppModel
    @State private var forgetting: Version?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Recently Deleted",
                       subtitle: "\(model.deleted.count) item\(model.deleted.count == 1 ? "" : "s") · kept for \(Int(Versions.deletedFor / 86400)) days")
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            List(model.deleted) { v in
                let info = SecretInfo(name: v.item, kind: v.kind, agentSafe: false, note: "", updatedAt: v.savedAt)
                let type = ItemType(info)
                let left = max(0, Int((Versions.deletedFor - Date().timeIntervalSince(v.savedAt)) / 86400))
                HStack(spacing: 12) {
                    Image(systemName: type.symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(type.tint.opacity(0.7)).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(info.ref.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            if !info.ref.isShared {
                                Chip(text: info.ref.project).font(.caption)
                                EnvBadge(environment: info.ref.environment, compact: true).fixedSize()
                            }
                        }
                        Text("Deleted \(v.savedAt.formatted(.relative(presentation: .named))) · \(left) day\(left == 1 ? "" : "s") left")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Button("Restore") { Task { await model.restore(v) } }.buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
                .listRowSeparator(.hidden)
                .help("\(v.item)\nDeleted by \(v.by)")
                .contextMenu {
                    Button("Restore") { Task { await model.restore(v) } }
                    Button("Forget for Good…", role: .destructive) { forgetting = v }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .overlay {
            if model.deleted.isEmpty {
                ContentUnavailableView("Nothing Deleted", systemImage: "trash",
                                       description: Text("Items you delete stay here for \(Int(Versions.deletedFor / 86400)) days."))
            }
        }
        .navigationTitle("Recently Deleted")
        .toolbar(removing: .title)
        .confirmationDialog("Forget \(forgetting?.item ?? "")?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            presenting: forgetting) { v in
            Button("Forget for Good", role: .destructive) { Task { await model.forgetHistory([v.item]) } }
        } message: { _ in
            Text("Its value and every earlier value are deleted and can't be brought back.")
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
