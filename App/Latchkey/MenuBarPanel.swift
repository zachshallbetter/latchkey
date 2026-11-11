import AppKit
import LatchkeyCore
import ServiceManagement
import SwiftUI

struct MenuBarPanel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""

    private func open(select name: String? = nil) {
        if let name { model.filter = .all; model.selection = [name]; model.reveal([name]) }
        openWindow(id: "main")
        NSApp.activate()
    }

    var body: some View {
        let q = query.lowercased()
        let list = model.items.filter { q.isEmpty || $0.name.lowercased().contains(q) }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(model.synced ? "iCloud Keychain" : "This Mac only", systemImage: model.synced ? "icloud" : "desktopcomputer")
                    .font(.headline)
                Spacer()
                Button { model.showingAdd = true; open() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("New item")
            }
            TextField("Search", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(list) { item in
                        HStack(spacing: 8) {
                            KindIcon(kind: item.kind, size: 22)
                            Text(item.name).font(.callout.monospaced()).lineLimit(1)
                            Spacer()
                            if item.agentSafe { Image(systemName: "person.badge.shield.checkmark.fill").foregroundStyle(.green) }
                            Button { Task { await model.copyValue(item.name) } } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help("Copy value")
                        }
                        .padding(.vertical, 3).padding(.horizontal, 4)
                        .contentShape(Rectangle())
                        .onTapGesture { open(select: item.name) }
                    }
                    if list.isEmpty {
                        Text(model.items.isEmpty ? "No items yet." : "No matches.").foregroundStyle(.secondary).padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: 280)
            if let e = model.log.first {
                Divider()
                ActivityRow(entry: e).font(.caption)
            }
            Divider()
            HStack {
                Button("Open Latchkey") { open() }
                Spacer()
                SettingsLink { Text("Settings…") }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { model.refresh() }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var atLogin = false
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("Where values live", value: model.store.location)
                if model.synced && !model.legacyItems.isEmpty {
                    LabeledContent {
                        Button("Move to iCloud Keychain") { Task { await model.moveLegacyItems() } }
                    } label: {
                        Text("\(model.legacyItems.count) item\(model.legacyItems.count == 1 ? "" : "s") still in this Mac's login keychain")
                        Text("Saved before this copy was signed. macOS may ask for your login password once per item while they move.")
                    }
                }
                if !model.synced {
                    Text("To sync through iCloud Keychain, sign in to Xcode with your Apple Account, set DEVELOPMENT_TEAM in App/project.yml, and run scripts/install.sh again. Every Mac needs a copy signed by the same team.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Approval") {
                LabeledContent("Method", value: model.broker.approver.method)
                Picker("Remember a read approval for", selection: $model.approvalWindow) {
                    Text("Don't remember").tag(0.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                    Text("15 minutes").tag(900.0)
                }
                Text("Applies to the same items asked for from the same folder by the same program. Changes always ask.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Open Latchkey at login", isOn: Binding(get: { atLogin }, set: { on in
                    loginError = model.setOpensAtLogin(on)
                    atLogin = model.opensAtLogin
                }))
                Text("The command-line tool only works while Latchkey is running.").font(.caption).foregroundStyle(.secondary)
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                LabeledContent("Access log") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.accessLog]) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear {
            atLogin = model.opensAtLogin
            model.checkLegacy()
        }
    }
}
