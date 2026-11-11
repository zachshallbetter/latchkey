import AppKit
import LatchkeyCore
import SwiftUI

struct ItemDetail: View {
    let model: AppModel
    let item: SecretInfo
    @State private var noteDraft = ""
    @State private var serviceDraft = ""
    @State private var versions: [Version] = []
    @State private var confirmingForget = false
    @State private var changingValue = false
    @State private var confirmingDelete = false
    @State private var working = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    KindIcon(kind: item.kind, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.ref.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                        if !item.ref.isShared {
                            HStack(spacing: 6) {
                                Text(item.ref.project).font(.callout.weight(.medium))
                                EnvBadge(environment: item.ref.environment)
                            }
                        }
                        Text("Changed \(item.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent("Value") {
                    HStack(spacing: 8) {
                        if let v = model.revealed[item.name] {
                            Text(v).font(.body.monospaced()).textSelection(.enabled).lineLimit(item.kind == .key ? 12 : 3)
                        } else {
                            Text(String(repeating: "•", count: 14)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button {
                            if model.revealed[item.name] != nil { model.revealed[item.name] = nil }
                            else { act { await model.reveal(item.name) } }
                        } label: {
                            Image(systemName: model.revealed[item.name] == nil ? "eye" : "eye.slash")
                        }
                        .help(model.revealed[item.name] == nil ? "Show (asks for approval unless agent-safe)" : "Hide")
                        Button { act { await model.copyValue(item.name) } } label: { Image(systemName: "doc.on.doc") }
                            .help("Copy value; the clipboard clears after 60 seconds")
                    }
                    .buttonStyle(.borderless)
                }
                LabeledContent("Reference") {
                    HStack {
                        Text(References.scheme + item.name).font(.body.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button { model.copyReference(item.name) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy reference for a .env file")
                    }
                }
                Button("Change Value…") { changingValue = true }
            }

            Section {
                Picker("Kind", selection: Binding(get: { item.kind }, set: { k in
                    act { _ = await model.save(name: item.name, value: nil, kind: k, agentSafe: nil, note: nil) }
                })) {
                    ForEach(ItemKind.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                Toggle(isOn: Binding(get: { item.agentSafe }, set: { on in
                    act { _ = await model.save(name: item.name, value: nil, kind: nil, agentSafe: on, note: nil) }
                })) {
                    Text("Agents may read without asking")
                    Text(item.agentSafe
                         ? "Any command run through latchkey gets this value."
                         : "Each read asks for Touch ID, Apple Watch or your password.")
                }
                LabeledContent("Project") {
                    HStack {
                        Text(item.ref.isShared ? "Shared" : "\(item.ref.project) / \(item.ref.environment)")
                        Spacer()
                        Button("Move…") { model.moveRequest = MoveRequest(ids: [item.name]) }
                    }
                }
                TextField("Service", text: $serviceDraft, prompt: Text("Stripe, Neon, GitHub…"))
                    .onSubmit { saveService() }
                TextField("Note", text: $noteDraft, prompt: Text("What it's for, where it came from"))
                    .onSubmit { saveNote() }
            } footer: {
                Text(item.kind.isSecret ? "Masked in command output." : "Plain values are not masked in output.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            let itemGrants = model.grants(for: item.name)
            if !itemGrants.isEmpty {
                Section("Readable Without Asking") {
                    ForEach(itemGrants) { g in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Broker.tilde(g.folder)).font(.callout.monospaced())
                                Text("Until \(g.expires.formatted(date: .omitted, time: .shortened)) · from \(g.createdBy)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke") { act { await model.revoke(g.id) } }
                        }
                    }
                }
            }

            if let paths = item.usedIn, !paths.isEmpty {
                Section("Used In") {
                    ForEach(paths, id: \.self) { path in
                        HStack {
                            Text(Broker.tilde(path)).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                            Spacer()
                            if FileManager.default.fileExists(atPath: path) {
                                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.borderless).help("Show in Finder")
                            } else {
                                Text("missing").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                if versions.isEmpty {
                    Text("No earlier values yet. When this value changes, the old one is kept here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(versions) { v in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(v.savedAt.formatted(date: .abbreviated, time: .shortened)).font(.callout)
                                    Text("\(v.reason == .changed ? "Replaced" : v.reason == .restored ? "Replaced by a restore" : "Deleted") by \(v.by)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    if model.revealedVersions[v.id] != nil { model.revealedVersions[v.id] = nil }
                                    else { act { await model.revealVersion(v) } }
                                } label: { Image(systemName: model.revealedVersions[v.id] == nil ? "eye" : "eye.slash") }
                                .buttonStyle(.borderless).help("Show this earlier value (asks for approval)")
                                Button("Restore") { act { await model.restore(v) } }
                            }
                            if let value = model.revealedVersions[v.id] {
                                Text(value).font(.caption.monospaced()).textSelection(.enabled).lineLimit(4)
                            }
                        }
                    }
                }
            } header: {
                Text("History")
            } footer: {
                HStack {
                    Text("The last \(Versions.keep) values are kept. Restoring keeps the current value too.")
                    Spacer()
                    if !versions.isEmpty { Button("Forget History…") { confirmingForget = true }.buttonStyle(.link) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Recent Activity") {
                let entries = model.activity(for: item.name)
                if entries.isEmpty {
                    Text("Not used yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, e in ActivityRow(entry: e, showNames: false) }
                }
            }

            Section {
                Button("Delete \(item.name)…", role: .destructive) { confirmingDelete = true }
            }
        }
        .formStyle(.grouped)
        .disabled(working)
        .onAppear { noteDraft = item.note; serviceDraft = item.service ?? "" }
        .onChange(of: item.service) { _, s in serviceDraft = s ?? "" }
        .task(id: item.updatedAt) { versions = model.history(for: item.name) }
        .confirmationDialog("Forget the history of \(item.ref.name)?", isPresented: $confirmingForget) {
            Button("Forget \(versions.count) Earlier Value\(versions.count == 1 ? "" : "s")", role: .destructive) {
                act {
                    await model.forgetHistory([item.name])
                    versions = model.history(for: item.name)
                }
            }
        } message: {
            Text("The current value stays. The earlier ones are deleted\(model.synced ? " on all your Macs" : "") and can't be brought back.")
        }
        .onChange(of: item.note) { _, n in noteDraft = n }
        .onDisappear { if noteDraft != item.note { saveNote() } }
        .sheet(isPresented: $changingValue) { ChangeValueSheet(model: model, item: item) }
        .confirmationDialog("Delete \(item.name)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { act { _ = await model.remove(item.name) } }
        } message: {
            if let files = item.usedIn, !files.isEmpty {
                Text("It moves to Recently Deleted\(model.synced ? " on all your Macs" : "") and can be restored for \(Int(Versions.deletedFor / 86400)) days. Until then these files stop working: \(files.map(Broker.tilde).joined(separator: ", ")).")
            } else {
                Text("It moves to Recently Deleted\(model.synced ? " on all your Macs" : "") and can be restored for \(Int(Versions.deletedFor / 86400)) days. Until then, files that refer to latchkey://\(item.name) stop working.")
            }
        }
    }

    private func saveService() {
        guard serviceDraft != (item.service ?? "") else { return }
        let s = serviceDraft
        act {
            if let err = await model.setService(item.name, s) {
                model.notice = err
                serviceDraft = item.service ?? ""
            }
        }
    }

    private func saveNote() {
        guard noteDraft != item.note else { return }
        let n = noteDraft
        act {
            if let err = await model.save(name: item.name, value: nil, kind: nil, agentSafe: nil, note: n) {
                model.notice = err
                noteDraft = item.note
            }
        }
    }

    private func act(_ work: @escaping @MainActor () async -> Void) {
        working = true
        Task { await work(); working = false }
    }
}
