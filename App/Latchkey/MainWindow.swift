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
                } else if model.filter == .deleted {
                    DeletedList(model: model)
                } else {
                    ItemList(model: model)
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 330)
        } detail: {
            if model.filter != .activity, model.filter != .grants, model.filter != .deleted, let item = model.selectedItem {
                ItemDetail(model: model, item: item).id(item.name)
            } else if model.filter != .activity, model.filter != .grants, model.filter != .deleted, model.selection.count > 1 {
                BulkPanel(model: model, ids: model.selection.sorted())
            } else {
                EmptyDetail(model: model)
            }
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: "Search")
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
                    SidebarRow(model: model, filter: .deleted, symbol: "trash.fill", tint: .gray)
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
            if model.sort == .name {
                // A tree, never a flat list of every key: project, then environment, then items, all closed
                // until opened. In a project's own view the tree starts at its environments.
                let inProject: Bool = { if case .project = model.filter { return true } else { return false } }()
                let groups = ItemTree.build(list)
                ForEach(groups) { group in
                    if inProject {
                        ForEach(group.environments) { env in
                            EnvironmentGroup(model: model, project: group.project, env: env, indent: 0)
                        }
                    } else if group.project.isEmpty {
                        let open = model.isOpen("shared")
                        TreeHeader(open: open, toggle: { model.toggle("shared") }) {
                            GroupHeader(symbol: "tray.full", title: "Shared", count: group.count)
                        }
                        if open {
                            ForEach(group.environments.flatMap(\.items)) { item in
                                ItemRow(item: item, showsProject: false).padding(.leading, 18).tag(item.name)
                            }
                        }
                    } else {
                        let open = model.isOpen(group.project)
                        TreeHeader(open: open, toggle: { model.toggle(group.project) }) {
                            GroupHeader(symbol: "folder", title: group.project, count: group.count,
                                        environments: group.environments.map { ($0.name, $0.items.count) })
                        }
                        .contextMenu { ProjectMenu(model: model, project: group.project) }
                        if open {
                            ForEach(group.environments) { env in
                                EnvironmentGroup(model: model, project: group.project, env: env, indent: 18)
                            }
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

/// Items arranged as projects → environments → items, in the list's order (shared items last).
enum ItemTree {
    struct Environment: Identifiable {
        let name: String
        var items: [SecretInfo]
        var id: String { name }
    }

    struct Project: Identifiable {
        let project: String
        var environments: [Environment]
        var id: String { project }
        var count: Int { environments.reduce(0) { $0 + $1.items.count } }
    }

    static func build(_ items: [SecretInfo]) -> [Project] {
        var out: [Project] = []
        for item in items.sorted(by: { $0.ref < $1.ref }) {
            let p = item.ref.project, e = item.ref.environment
            if out.last?.project != p { out.append(Project(project: p, environments: [])) }
            if out[out.count - 1].environments.last?.name != e {
                out[out.count - 1].environments.append(Environment(name: e, items: []))
            }
            out[out.count - 1].environments[out[out.count - 1].environments.count - 1].items.append(item)
        }
        return out
    }
}

/// A header row that opens and closes its group. Plain rows rather than a disclosure control, so opening a
/// group from code (selecting an item elsewhere) and clicking behave the same, on screen and in snapshots.
struct TreeHeader<Label: View>: View {
    let open: Bool
    let toggle: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 12)
                label()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(open ? "Collapse" : "Expand")
        // A group header opens and closes; it isn't an item, so it never takes the selection.
        .selectionDisabled()
    }
}

/// A collapsible environment inside a project, with the bulk actions for everything in it.
struct EnvironmentGroup: View {
    let model: AppModel
    let project: String
    let env: ItemTree.Environment
    var indent: CGFloat = 18

    var body: some View {
        let key = "\(project)/\(env.name)"
        let open = model.isOpen(key)
        TreeHeader(open: open, toggle: { model.toggle(key) }) {
            HStack(spacing: 6) {
                EnvBadge(environment: env.name)
                Text("\(env.items.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                let safe = env.items.filter(\.agentSafe).count
                if safe > 0 { Text("\(safe) agent-safe").font(.caption).foregroundStyle(.green) }
                PlaceLabel(links: model.links(for: key), local: env.items.contains { !($0.usedIn ?? []).isEmpty })
            }
        }
        .padding(.leading, indent)
        .contextMenu {
            GroupMenu(model: model, title: key, ids: env.items.map(\.name), pattern: "\(key)/*")
        }
        if open {
            ForEach(env.items) { item in
                ItemRow(item: item, showsProject: false, remote: model.remoteStates[item.name]).padding(.leading, indent + 18).tag(item.name)
            }
        }
    }
}

struct GroupHeader: View {
    let symbol: String
    let title: String
    let count: Int
    var environments: [(String, Int)] = []

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(title).font(.body.weight(.semibold)).lineLimit(1)
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            Spacer(minLength: 4)
            // Which environments the project has, at a glance, while it's collapsed.
            HStack(spacing: 3) {
                ForEach(environments.prefix(4), id: \.0) { EnvBadge(environment: $0.0, compact: true) }
                if environments.count > 4 { Text("+\(environments.count - 4)").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 2)
    }
}

struct ItemRow: View {
    let item: SecretInfo
    var showsProject = true
    var showsEnvironment = false
    /// Out of date or never pushed somewhere this item's environment is linked.
    var remote: RemoteState? = nil

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
            if remote == .outOfDate {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                    .help("Changed since it was last pushed to a remote location")
            } else if remote == .notPushed {
                Image(systemName: "icloud.slash").foregroundStyle(.secondary)
                    .help("Not pushed yet to a remote location its environment is linked to")
            }
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
        List(model.deleted) { v in
            HStack(spacing: 10) {
                KindIcon(kind: v.kind, size: 28).opacity(0.6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(v.item).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    let left = max(0, Int((Versions.deletedFor - Date().timeIntervalSince(v.savedAt)) / 86400))
                    Text("Deleted \(v.savedAt.formatted(.relative(presentation: .named))) by \(v.by) · \(left) day\(left == 1 ? "" : "s") left")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Restore") { Task { await model.restore(v) } }
            }
            .contextMenu {
                Button("Restore") { Task { await model.restore(v) } }
                Button("Forget for Good…", role: .destructive) { forgetting = v }
            }
        }
        .overlay {
            if model.deleted.isEmpty {
                ContentUnavailableView("Nothing Deleted", systemImage: "trash",
                                       description: Text("Items you delete stay here for \(Int(Versions.deletedFor / 86400)) days."))
            }
        }
        .navigationTitle("Recently Deleted")
        .navigationSubtitle("\(model.deleted.count) item\(model.deleted.count == 1 ? "" : "s")")
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
