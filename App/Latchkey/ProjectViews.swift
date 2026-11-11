import AppKit
import LatchkeyCore
import SwiftUI

/// A coloured capsule naming an environment. Known environments keep the same colour everywhere.
struct EnvBadge: View {
    let environment: String
    var compact = false

    /// `vercel.preview` → ("Vercel", "preview"): values kept for one service's instance.
    var parts: (service: String?, instance: String) {
        let bits = environment.split(separator: ".", maxSplits: 1).map(String.init)
        if bits.count == 2, let s = RemoteTarget.Service(rawValue: bits[0]) { return (s.label.replacingOccurrences(of: " Actions", with: ""), bits[1]) }
        if bits.count == 2, bits[0] == "local" { return ("Local", bits[1]) }
        return (nil, environment)
    }

    var tint: Color {
        switch parts.instance {
        case "development": return .blue
        case "preview": return .purple
        case "staging": return .orange
        case "production": return .red
        case "test": return .gray
        default: return .teal
        }
    }

    var body: some View {
        Text(parts.service.map { "\($0) · \(parts.instance)" } ?? environment)
            .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            .padding(.horizontal, compact ? 5 : 7).padding(.vertical, compact ? 1 : 2)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.15)))
    }
}

/// Projects in the sidebar. With many projects a filter field appears, so hundreds stay usable.
/// Actions on every item in a project, from its card in the list.
struct ProjectMenu: View {
    let model: AppModel
    let project: String

    var body: some View {
        GroupMenu(model: model, title: project, ids: model.ids(inProject: project), pattern: "\(project)/*", isProject: true)
    }
}

/// Actions on every item in a group (a project, or one environment of it), each with one approval.
struct GroupMenu: View {
    let model: AppModel
    let title: String
    let ids: [String]
    let pattern: String
    var isProject = false

    var body: some View {
        Button("Select All \(ids.count) Items") {
            model.selection = Set(ids)
        }
        Divider()
        Button("Require Approval for All") { Task { await model.updateItems(ids, agentSafe: false) } }
        Button("Let Agents Read All Without Asking") { Task { await model.updateItems(ids, agentSafe: true) } }
        Button("Grant Access to \(title)…") { model.grantRequest = GrantRequest(pattern: pattern) }
        if !isProject {
            Button("Remote Locations…") { model.remoteRequest = RemoteRequest(scope: title) }
        }
        Divider()
        Button(isProject ? "Move or Rename Project…" : "Move to Another Environment…") { model.moveRequest = MoveRequest(ids: ids) }
        Button(isProject ? "Delete Project…" : "Delete \(title)…", role: .destructive) { model.deleteRequest = DeleteRequest(ids: ids) }
    }
}

struct MoveSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String>
    @State private var project: String
    @State private var environment: String
    @State private var shared = false
    @State private var files: [URL] = []
    @State private var query = ""
    @State private var error: String?
    @State private var working = false

    init(model: AppModel, preselected: [String]) {
        self.model = model
        _chosen = State(initialValue: Set(preselected))
        let first = preselected.first.flatMap { model.item($0) }?.ref
        let current: String? = { if case .project(let p) = model.filter { return p } else { return nil } }()
        _project = State(initialValue: (first?.isShared == false ? first?.project : nil) ?? current ?? "")
        _environment = State(initialValue: (first?.isShared == false ? first?.environment : nil) ?? "development")
    }

    var placeIsValid: Bool { shared || (ItemID.isValidPart(project) && ItemID.isValidPart(environment)) }

    var candidates: [SecretInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.items.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.note.lowercased().contains(q) }
            .sorted { $0.ref < $1.ref }
    }

    /// Files that will have their references updated: where the chosen items were imported from, plus any added.
    var updatedFiles: [String] {
        var seen = Set<String>()
        let recorded = model.items.filter { chosen.contains($0.name) }.flatMap { $0.usedIn ?? [] }
        return (files.map(\.path) + recorded).filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SheetHeader(symbol: "folder", tint: .indigo, title: "Move to a Project")
                Text("Items keep their values and settings; their IDs change, and references in the files below are updated.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Picker("", selection: $shared) {
                    Text("Project").tag(false)
                    Text("Shared").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if !shared {
                    TextField("Project", text: $project).frame(width: 150)
                    Menu {
                        ForEach(model.projects, id: \.self) { p in Button(p) { project = p } }
                    } label: { Image(systemName: "folder") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(model.projects.isEmpty)
                    TextField("Environment", text: $environment).frame(width: 130)
                    Menu {
                        ForEach(Environments.known, id: \.self) { e in Button(e) { environment = e } }
                    } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Spacer()
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Text("Items").font(.callout.weight(.medium))
                Spacer()
                TextField("Filter", text: $query).textFieldStyle(.roundedBorder).frame(width: 180)
                Button("Select Shown") { chosen.formUnion(candidates.map(\.name)) }.disabled(candidates.isEmpty)
            }
            List(candidates) { item in
                Toggle(isOn: Binding(get: { chosen.contains(item.name) },
                                     set: { if $0 { chosen.insert(item.name) } else { chosen.remove(item.name) } })) {
                    HStack(spacing: 8) {
                        KindIcon(kind: item.kind, size: 18)
                        Text(item.name).font(.callout.monospaced())
                        Text(item.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .frame(minHeight: 180)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Update references in").font(.callout.weight(.medium))
                    Spacer()
                    Button("Add File…") { addFile() }
                }
                if updatedFiles.isEmpty {
                    Text("No files recorded for these items. Add the .env file that refers to them, or update it yourself.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(updatedFiles, id: \.self) { Text(Broker.tilde($0)).font(.caption.monospaced()).lineLimit(1).truncationMode(.head) }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("Moving asks for Touch ID once.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move \(chosen.count) Item\(chosen.count == 1 ? "" : "s")") {
                    working = true
                    Task {
                        error = await model.moveItems(chosen.sorted(), project: shared ? "" : project,
                                                      environment: shared ? "" : environment, files: files)
                        working = false
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || !placeIsValid || working)
            }
        }
        .padding(20)
        .frame(width: 640, height: 620)
    }

    private func addFile() {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose the .env files that refer to these items."
        if panel.runModal() == .OK { files.append(contentsOf: panel.urls.filter { !files.contains($0) }) }
    }
}
