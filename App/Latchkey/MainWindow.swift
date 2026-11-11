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
                if model.filter == .activity {
                    ActivityList(model: model)
                } else if model.filter == .grants {
                    GrantList(model: model)
                } else {
                    ItemList(model: model)
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 330)
        } detail: {
            if model.filter != .activity, model.filter != .grants, let item = model.selectedItem {
                ItemDetail(model: model, item: item).id(item.name)
            } else if model.filter != .activity, model.filter != .grants, model.selection.count > 1 {
                BulkPanel(model: model, ids: model.selection.sorted())
            } else {
                EmptyDetail(model: model)
            }
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: "Search")
        .safeAreaInset(edge: .bottom, spacing: 0) { NoticeBar(model: model) }
        .sheet(isPresented: $model.showingAdd) { AddItemSheet(model: model) }
        .sheet(item: $model.importDraft) { ImportSheet(model: model, draft: $0) }
        .sheet(item: $model.grantRequest) { NewGrantSheet(model: model, request: $0) }
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
        let files = model.files(for: ids)
        if files.isEmpty {
            return "They're removed from the keychain\(place). Files that refer to them stop working, and a file that holds only references loses those values for good."
        }
        let shown = files.prefix(4).map(Broker.tilde).joined(separator: ", ") + (files.count > 4 ? ", …" : "")
        return "They're removed from the keychain\(place). These files still refer to them and will stop working: \(shown). If they hold only references, those values are gone for good."
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Tile(model: model, filter: .all, symbol: "square.grid.2x2.fill", color: .blue)
                        Tile(model: model, filter: .agentSafe, symbol: "person.badge.shield.checkmark.fill", color: .green)
                    }
                    GridRow {
                        Tile(model: model, filter: .needsApproval, symbol: "hand.raised.fill", color: .red)
                        Tile(model: model, filter: .activity, symbol: "clock.arrow.circlepath", color: .indigo)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kinds").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 8)
                    ForEach(ItemKind.allCases, id: \.self) { k in
                        SidebarRow(model: model, filter: .kind(k), kind: k)
                    }
                }
                ProjectsSection(model: model)
                if !model.services.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Services").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 8)
                        ForEach(model.services, id: \.self) { s in
                            SidebarRow(model: model, filter: .service(s), symbol: "server.rack", tint: .gray)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Access").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 8)
                    SidebarRow(model: model, filter: .grants, symbol: "hourglass", tint: .teal)
                }
                Spacer(minLength: 0)
                StorageBadge(model: model)
            }
            .padding(10)
        }
    }
}

struct Tile: View {
    let model: AppModel
    let filter: SidebarFilter
    let symbol: String
    let color: Color

    var body: some View {
        let on = model.filter == filter
        Button {
            model.filter = filter
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(on ? color : .white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(on ? AnyShapeStyle(.white) : AnyShapeStyle(color.gradient)))
                    Spacer()
                    Text("\(model.count(filter))").font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(on ? .white : .secondary)
                }
                Text(filter.title).font(.headline).foregroundStyle(on ? .white : .primary).lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(on ? AnyShapeStyle(color.gradient) : AnyShapeStyle(.quaternary.opacity(0.6))))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

struct SidebarRow: View {
    let model: AppModel
    let filter: SidebarFilter
    var kind: ItemKind? = nil
    var symbol: String? = nil
    var tint: Color = .gray

    var body: some View {
        let on = model.filter == filter
        Button { model.filter = filter } label: {
            HStack(spacing: 8) {
                if let kind {
                    KindIcon(kind: kind, size: 20)
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.gradient).frame(width: 20, height: 20)
                        .overlay(Image(systemName: symbol ?? "circle").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white))
                }
                Text(filter.title)
                Spacer()
                Text("\(model.count(filter))").foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? AnyShapeStyle(.selection.opacity(0.35)) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct StorageBadge: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(model.synced ? "iCloud Keychain" : "This Mac only", systemImage: model.synced ? "icloud.fill" : "desktopcomputer")
                .font(.callout.weight(.medium))
            Text(model.synced
                 ? "Items sync to your other Macs."
                 : "Not syncing: this copy isn't signed with your team. See Settings.")
                .font(.caption).foregroundStyle(.secondary)
            if let p = model.problem {
                Text(p).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}

// MARK: - Lists

struct ItemList: View {
    @Bindable var model: AppModel

    var body: some View {
        let list = model.visibleItems
        List(selection: $model.selection) {
            if case .project(let p) = model.filter, model.sort == .name {
                // One section per environment, in their usual order.
                ForEach(model.environments(in: p), id: \.self) { env in
                    let rows = list.filter { $0.ref.environment == env }
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows) { item in
                                ItemRow(item: item, showsProject: false).tag(item.name)
                            }
                        } header: {
                            HStack { EnvBadge(environment: env); Text("\(rows.count)").foregroundStyle(.secondary) }
                        }
                    }
                }
            } else if model.sort == .name {
                // Every other view spans projects: one section per project, shared items last, so the same
                // name in several projects reads as separate items.
                ForEach(Self.groups(list), id: \.project) { group in
                    Section {
                        ForEach(group.items) { item in
                            ItemRow(item: item, showsProject: false, showsEnvironment: true).tag(item.name)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: group.project.isEmpty ? "tray.full" : "folder")
                            Text(group.project.isEmpty ? "Shared" : group.project).font(.headline)
                            Text("\(group.items.count)").foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ForEach(list) { item in
                    ItemRow(item: item).tag(item.name)
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            SelectionMenu(model: model, ids: ids.sorted())
        }
        .overlay {
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
        .navigationTitle(model.filter.title)
        .navigationSubtitle("\(list.count) item\(list.count == 1 ? "" : "s")")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Picker("Sort By", selection: $model.sort) {
                        ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                Menu {
                    Button("New Item…") { model.showingAdd = true }
                    Button("Import .env File…") { model.chooseImportFile() }
                    Divider()
                    Button("Move Items to a Project…") { model.moveRequest = MoveRequest(ids: model.selection.sorted()) }
                } label: { Label("Add", systemImage: "plus") }
            }
        }
    }
}

extension ItemList {
    /// Items split by project in the list's order (projects by name, shared last).
    static func groups(_ items: [SecretInfo]) -> [(project: String, items: [SecretInfo])] {
        var out: [(project: String, items: [SecretInfo])] = []
        for item in items {
            if out.last?.project == item.ref.project { out[out.count - 1].items.append(item) }
            else { out.append((item.ref.project, [item])) }
        }
        return out
    }
}

struct ItemRow: View {
    let item: SecretInfo
    var showsProject = true
    var showsEnvironment = false

    var body: some View {
        HStack(spacing: 10) {
            KindIcon(kind: item.kind)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.ref.name).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 5) {
                    // Headings already name the project (and, in a project view, the environment).
                    if !item.ref.isShared && (showsProject || showsEnvironment) {
                        if showsProject { Text(item.ref.project).font(.caption.weight(.medium)) }
                        EnvBadge(environment: item.ref.environment, compact: true)
                    }
                    if let s = item.service { Text(s).font(.caption).foregroundStyle(.secondary) }
                    if (item.ref.isShared || !(showsProject || showsEnvironment)) && item.service == nil {
                        Text(item.note.isEmpty ? item.kind.label : item.note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            }
            Spacer()
            if item.agentSafe {
                Image(systemName: "person.badge.shield.checkmark.fill").foregroundStyle(.green)
                    .help("Agents may read this without asking")
            }
        }
        .padding(.vertical, 4)
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
        List(Array(entries.enumerated()), id: \.offset) { _, e in
            ActivityRow(entry: e, showNames: true)
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No Activity", systemImage: "clock",
                                       description: Text("Every read and change shows up here, never the values."))
            }
        }
        .navigationTitle("Activity")
        .navigationSubtitle("\(entries.count) entries")
    }
}

struct ActivityRow: View {
    let entry: Broker.LogEntry
    var showNames = true

    var icon: (String, Color) {
        let d = entry.decision
        if d.hasPrefix("denied") { return ("xmark.octagon.fill", .red) }
        if d.hasPrefix("approved") { return ("touchid", .blue) }
        return ("checkmark.circle.fill", .green)
    }

    var verb: String {
        switch entry.op {
        case "get": return "Read"
        case "set": return "Saved"
        case "rm": return "Deleted"
        case "import": return "Imported"
        default: return entry.op
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon.0).foregroundStyle(icon.1).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(showNames ? "\(verb) \(entry.names.joined(separator: ", "))" : verb)
                    .font(.callout.weight(.medium)).lineLimit(2)
                Text("\(entry.decision) · \(entry.chain.prefix(3).joined(separator: " › "))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !entry.cwd.isEmpty {
                    Text(Broker.tilde(entry.cwd)).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer()
            Text(entry.time.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct EmptyDetail: View {
    let model: AppModel

    var body: some View {
        if model.filter == .activity {
            ContentUnavailableView("Activity", systemImage: "clock.arrow.circlepath",
                                   description: Text("Who read or changed what, from where. Values are never logged."))
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
