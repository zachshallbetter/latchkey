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
                    Button("New Grant…") { model.showingNewGrant = true }
                }
            }
        }
        .navigationTitle("Grants")
        .navigationSubtitle("\(model.grants.count) in effect")
        .toolbar {
            ToolbarItemGroup {
                Button { model.showingNewGrant = true } label: { Label("New Grant", systemImage: "plus") }
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
    @State private var chosen: Set<String> = []
    @State private var folder: URL?
    @State private var duration: TimeInterval = 2 * 3600
    @State private var error: String?
    @State private var working = false

    /// Agent-safe items never ask, so they don't need grants.
    var candidates: [SecretInfo] { model.items.filter { !$0.agentSafe } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Grant").font(.title3.weight(.semibold))
                Text("Commands run from the folder, or any folder inside it, can read the chosen items without asking until the grant ends.")
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
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("Creating it asks for Touch ID.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Grant") {
                    guard let folder else { return }
                    working = true
                    Task {
                        error = await model.createGrant(names: chosen.sorted(), folder: folder.path, duration: duration)
                        working = false
                        if error == nil { model.filter = .grants; dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(folder == nil || chosen.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 480, height: 520)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the project folder the grant covers."
        if panel.runModal() == .OK { folder = panel.url }
    }
}
