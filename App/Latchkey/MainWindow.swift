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
            if model.filter != .activity, model.filter != .grants, let item = model.item(model.selection) {
                ItemDetail(model: model, item: item).id(item.name)
            } else {
                EmptyDetail(model: model)
            }
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: "Search")
        .safeAreaInset(edge: .bottom, spacing: 0) { NoticeBar(model: model) }
        .sheet(isPresented: $model.showingAdd) { AddItemSheet(model: model) }
        .sheet(item: $model.importDraft) { ImportSheet(model: model, draft: $0) }
        .sheet(isPresented: $model.showingNewGrant) { NewGrantSheet(model: model) }
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
            ForEach(list) { item in
                ItemRow(item: item).tag(item.name)
                    .contextMenu { ItemMenu(model: model, item: item) }
            }
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
                } label: { Label("Add", systemImage: "plus") }
            }
        }
    }
}

struct ItemRow: View {
    let item: SecretInfo

    var body: some View {
        HStack(spacing: 10) {
            KindIcon(kind: item.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                Text(item.note.isEmpty ? item.kind.label : item.note)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
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

struct ItemMenu: View {
    let model: AppModel
    let item: SecretInfo

    var body: some View {
        Button("Copy Value") { Task { await model.copyValue(item.name) } }
        Button("Copy Reference") { model.copyReference(item.name) }
        Divider()
        Button(item.agentSafe ? "Require Approval" : "Mark Agent-Safe") {
            Task { _ = await model.save(name: item.name, value: nil, kind: nil, agentSafe: !item.agentSafe, note: nil) }
        }
        Divider()
        Button("Delete", role: .destructive) { Task { _ = await model.remove(item.name) } }
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
                Text("Files keep latchkey://NAME references; Latchkey keeps the values.")
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
