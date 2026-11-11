import AppKit
import LatchkeyCore
import SwiftUI

struct ItemDetail: View {
    let model: AppModel
    let item: SecretInfo
    @State private var versions: [Version] = []
    @State private var confirmingForget = false
    @State private var changingValue = false
    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var showsFiles = false
    @State private var showsHistory = false
    @State private var working = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                valueCard
                detailsCard
                grantsCard
                usedIn
                remote
                history
                activity
            }
            .padding(16)
        }
        .disabled(working)
        .task(id: item.updatedAt) { versions = model.history(for: item.name) }
        .sheet(isPresented: $changingValue) { ChangeValueSheet(model: model, item: item) }
        .sheet(isPresented: $editing) { EditItemSheet(model: model, item: item) }
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

    // MARK: header and value

    private var header: some View {
        let type = ItemType(item)
        return HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: type.symbol, tint: type.tint, size: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.ref.name).font(.title2.weight(.semibold)).textSelection(.enabled).lineLimit(2)
                HStack(spacing: 6) {
                    if item.ref.isShared {
                        Chip(text: "Shared")
                    } else {
                        Chip(text: item.ref.project)
                        EnvBadge(environment: item.ref.environment)
                    }
                }
            }
            Spacer(minLength: 8)
            Menu {
                Button("Change Value…") { changingValue = true }
                Button("Edit Details…") { editing = true }
                Button("Move…") { model.moveRequest = MoveRequest(ids: [item.name]) }
                Divider()
                Button("Copy Reference") { model.copyReference(item.name) }
                Divider()
                Button("Delete \(item.ref.name)…", role: .destructive) { confirmingDelete = true }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .menuStyle(.button).buttonStyle(.bordered).menuIndicator(.hidden).fixedSize()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }

    private var valueCard: some View {
        Card {
            CardRow(label: "Value") {
                if let v = model.revealed[item.name] {
                    Text(v).font(.body.monospaced()).textSelection(.enabled).lineLimit(item.kind == .key ? 12 : 3)
                        .multilineTextAlignment(.trailing)
                } else {
                    Text(String(repeating: "•", count: 14)).foregroundStyle(.secondary)
                }
                Button {
                    if model.revealed[item.name] != nil { model.revealed[item.name] = nil }
                    else { act { await model.reveal(item.name) } }
                } label: { Image(systemName: model.revealed[item.name] == nil ? "eye" : "eye.slash") }
                .help(model.revealed[item.name] == nil ? "Show (asks unless a grant or No Approval setting permits it)" : "Hide")
                Button { act { await model.copyValue(item.name) } } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy the value to this Mac's clipboard; it clears after 60 seconds")
            }
            CardRow(label: "Reference", last: true) {
                Text(References.scheme + item.name).font(.callout.monospaced()).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(0.6)))
                Button { model.copyReference(item.name) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy the reference for an env file")
            }
        }
        .buttonStyle(.borderless)
    }

    // MARK: details

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Card {
                CardRow(label: "Kind") {
                    Text(item.kind.label).foregroundStyle(.secondary)
                }
                CardRow(label: "Access") {
                    Text(item.agentSafe ? "No approval" : "Requires approval").foregroundStyle(.secondary)
                    Toggle("", isOn: Binding(get: { item.agentSafe }, set: { on in
                        act { if let e = await model.updateDetails(item.name, kind: nil, agentSafe: on, service: nil, note: nil, fillSites: nil) { model.notice = e } }
                    }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .help(item.agentSafe ? "Any program in your Mac account may request this value." : "Reads ask for approval unless a grant covers them.")
                }
                CardRow(label: "Service") {
                    Text(item.service ?? "None").foregroundStyle(.secondary)
                    if let service = item.service, let page = Services.keyPages[service].flatMap(URL.init(string:)) {
                        Link(destination: page) { Image(systemName: "arrow.up.forward.square") }
                            .help("Make a new key at \(service). To rotate: make one there, revoke the old one, then Change Value here.")
                    }
                }
                CardRow(label: "Note") {
                    Text(item.note.isEmpty ? "None" : item.note).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
                }
                CardRow(label: "Fill in Safari on", last: true) {
                    Text(item.fillSites.map { $0.joined(separator: ", ") } ?? "Its service's site and deployment platforms")
                        .foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
                }
            }
            Text(item.kind.isSecret ? "Masked in command output." : "Plain values are not masked in output.")
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
        }
    }

    @ViewBuilder
    private var grantsCard: some View {
        let itemGrants = model.grants(for: item.name)
        if !itemGrants.isEmpty {
            Card {
                ForEach(Array(itemGrants.enumerated()), id: \.element.id) { i, g in
                    CardRow(label: Broker.tilde(g.folder), last: i == itemGrants.count - 1) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Until \(g.expires.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                            if !g.limits.isEmpty { Text(g.limits).font(.caption).foregroundStyle(.secondary) }
                        }
                        Button("Revoke") { act { await model.revoke(g.id) } }
                    }
                }
            }
        }
    }

    // MARK: where it's used, pushed and changed

    @ViewBuilder
    private var usedIn: some View {
        if let paths = item.usedIn, !paths.isEmpty {
            LinkCard(symbol: "folder", title: "Used In",
                     detail: paths.count == 1 ? Broker.tilde(paths[0]) : "\(Broker.tilde(paths[0])) and \(paths.count - 1) more") {
                withAnimation(.snappy) { showsFiles.toggle() }
            }
            if showsFiles {
                Card {
                    ForEach(Array(paths.enumerated()), id: \.element) { i, path in
                        CardRow(label: Broker.tilde(path), last: i == paths.count - 1) {
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
        }
    }

    @ViewBuilder
    private var remote: some View {
        if !item.ref.isShared {
            let states = model.remoteStates(of: item)
            let stale = states.contains { $0.state == .outOfDate }
            let detail = states.isEmpty ? "Not linked"
                : stale ? "Changed since last push"
                : states.contains { $0.state == .notPushed } ? "Not pushed everywhere"
                : "Up to date in \(states.count) location\(states.count == 1 ? "" : "s")"
            LinkCard(symbol: "cloud", title: "Remote", detail: detail,
                     dot: states.isEmpty ? .yellow : stale ? .orange : .green) {
                model.remoteRequest = RemoteRequest(scope: "\(item.ref.project)/\(item.ref.environment)")
            }
        }
    }

    @ViewBuilder
    private var history: some View {
        LinkCard(symbol: "clock.arrow.circlepath", title: "History",
                 detail: versions.isEmpty ? "No earlier values yet. The last \(Versions.keep) values are kept."
                    : "\(versions.count) earlier value\(versions.count == 1 ? "" : "s"), last replaced \(versions[0].savedAt.formatted(.relative(presentation: .named)))") {
            withAnimation(.snappy) { showsHistory.toggle() }
        }
        if showsHistory && !versions.isEmpty {
            Card {
                ForEach(Array(versions.enumerated()), id: \.element.id) { i, v in
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
                    .padding(.vertical, 10)
                    if i < versions.count - 1 { Divider() }
                }
            }
            HStack {
                Text("Restoring keeps the current value too.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Forget History…") { confirmingForget = true }.buttonStyle(.link).font(.caption)
            }
            .padding(.horizontal, 4)
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path.ecg").font(.title3).foregroundStyle(.secondary).frame(width: 26)
                Text("Recent Activity").font(.body.weight(.semibold))
            }
            .padding(.vertical, 12)
            let entries = model.activity(for: item.name)
            if entries.isEmpty {
                Text("Not used yet.").foregroundStyle(.secondary).padding(.bottom, 12)
            }
            ForEach(Array(entries.enumerated()), id: \.offset) { i, e in
                Divider()
                ActivityRow(entry: e, showNames: false).padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }

    private func act(_ work: @escaping @MainActor () async -> Void) {
        working = true
        Task { await work(); working = false }
    }
}
