import AppKit
import LatchkeyCore
import SwiftUI

struct GrantList: View {
    let model: AppModel

    var body: some View {
        List {
            ForEach(model.grants) { g in GrantRow(model: model, grant: g) }
        }
        .overlay {
            if model.grants.isEmpty {
                ContentUnavailableView {
                    Label("No Grants", systemImage: "hourglass")
                } description: {
                    Text("Every read of an item that isn't agent-safe asks first.")
                } actions: {
                    Button("New Grant…") { model.grantRequest = GrantRequest() }
                }
            }
        }
        .navigationTitle("Grants")
        .navigationSubtitle("\(model.grants.count) in effect")
        .toolbar {
            ToolbarItemGroup {
                Button { model.grantRequest = GrantRequest() } label: { Label("New Grant", systemImage: "plus") }
                    .help("Let one folder read some items without asking, for a while")
                if !model.grants.isEmpty {
                    Button { Task { await model.revoke("all") } } label: { Label("Revoke All", systemImage: "xmark.circle") }
                        .help("End every grant now")
                }
            }
        }
    }
}

struct GrantRow: View {
    let model: AppModel
    let grant: Grant

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hourglass").foregroundStyle(.teal).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(Broker.tilde(grant.folder)).font(.callout.monospaced().weight(.medium)).lineLimit(1).truncationMode(.head)
                Text(grant.names.joined(separator: ", ")).font(.callout).lineLimit(2)
                if grant.repo != nil { Text("Includes repository worktrees").font(.caption).foregroundStyle(.secondary) }
                if !grant.limits.isEmpty { Text(grant.limits.prefix(1).capitalized + grant.limits.dropFirst()).font(.caption).foregroundStyle(.secondary) }
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text("Ends \(grant.expires.formatted(.relative(presentation: .named))) · from \(grant.createdBy)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button("Revoke") { Task { await model.revoke(grant.id) } }.buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Show Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: grant.folder)]) }
            Button("Revoke", role: .destructive) { Task { await model.revoke(grant.id) } }
        }
    }
}

struct NewGrantSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String>
    /// A whole project or environment (`acp/*`), which also covers items added to it later.
    @State private var pattern: String?
    @State private var folder: URL?

    init(model: AppModel, request: GrantRequest) {
        self.model = model
        _chosen = State(initialValue: Set(request.ids))
        _pattern = State(initialValue: request.pattern)
        // Start from the folder the items were imported from, when that's known.
        let ids = request.pattern.map { p in model.items.filter { Grant.entry(p, matches: $0.name) }.map(\.name) } ?? request.ids
        let file = model.files(for: ids).first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        _folder = State(initialValue: file)
    }
    @State private var duration: TimeInterval = 2 * 3600
    @State private var error: String?
    @State private var working = false

    /// Agent-safe items never ask, so they don't need grants.
    var candidates: [SecretInfo] { model.items.filter { !$0.agentSafe } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SheetHeader(symbol: "checkmark.shield", tint: .teal, title: "New Grant")
                Text("Programs in this folder, its subfolders and its repository’s Git worktrees can read these items until the grant ends. Revoking stops future reads, not values already released.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Folder").frame(width: 70, alignment: .leading)
                Text(folder.map { Broker.tilde($0.path) } ?? "None chosen")
                    .font(.callout.monospaced()).foregroundStyle(folder == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                Button("Choose…") { chooseFolder() }
            }
            HStack {
                Text("For").frame(width: 70, alignment: .leading)
                Picker("", selection: $duration) {
                    Text("30 minutes").tag(1800.0)
                    Text("2 hours").tag(7200.0)
                    Text("8 hours").tag(28800.0)
                    Text("1 day").tag(86400.0)
                    Text("7 days").tag(604800.0)
                }
                .labelsHidden().fixedSize()
                Spacer()
            }
            if let pattern {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Items").font(.callout.weight(.medium))
                    Text("Everything in \(pattern.dropLast(2)), including items added to it later.")
                    Button("Choose Items Instead") {
                        chosen = Set(model.items.filter { Grant.entry(pattern, matches: $0.name) && !$0.agentSafe }.map(\.name))
                        self.pattern = nil
                    }
                }
                Spacer()
            } else {
            Text("Items").font(.callout.weight(.medium))
            List(candidates) { item in
                Toggle(isOn: Binding(get: { chosen.contains(item.name) },
                                     set: { if $0 { chosen.insert(item.name) } else { chosen.remove(item.name) } })) {
                    HStack(spacing: 8) {
                        KindIcon(kind: item.kind, size: 20)
                        Text(item.name).font(.callout.monospaced())
                    }
                }
            }
            .frame(minHeight: 160)
            .overlay {
                if candidates.isEmpty { Text("Every item is agent-safe already.").foregroundStyle(.secondary) }
            }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("Creating it asks for Touch ID.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Grant") {
                    guard let folder else { return }
                    working = true
                    Task {
                        error = await model.createGrant(names: pattern.map { [$0] } ?? chosen.sorted(), folder: folder.path, duration: duration)
                        working = false
                        if error == nil { model.filter = .grants; dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(folder == nil || (pattern == nil && chosen.isEmpty) || working)
            }
        }
        .padding(20)
        .frame(width: 480, height: 520)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the project folder the grant covers. In the sandbox build, this also allows Latchkey to read and update project files."
        if panel.runModal() == .OK, let url = panel.url {
            do { try model.rememberSelectedURL(url, isDirectory: true); folder = url }
            catch { self.error = error.localizedDescription }
        }
    }
}
