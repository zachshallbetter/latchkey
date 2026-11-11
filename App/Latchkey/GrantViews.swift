import AppKit
import LatchkeyCore
import SwiftUI

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
            SheetHeader(symbol: "checkmark.shield", tint: .teal, title: "New Grant",
                        subtitle: "Let one folder read items without asking, for a while")
            Text("Programs in this folder, its subfolders and its repository’s Git worktrees can read these items until the grant ends. Revoking stops future reads, not values already released.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Card {
                FieldRow(label: "Folder") {
                    Text(folder.map { Broker.tilde($0.path) } ?? "None chosen")
                        .font(.callout.monospaced()).foregroundStyle(folder == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                }
                FieldRow(label: "For", last: true) {
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
            SheetFooter(note: "Creating it asks for Touch ID.", noteSymbol: "touchid") {
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
        .padding(24)
        .frame(width: 540, height: 600)
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
