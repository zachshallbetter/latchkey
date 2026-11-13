import AppKit
import LatchkeyCore
import ServiceManagement
import SwiftUI

struct MenuBarPanel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""

    private func open(select name: String? = nil) {
        if let name { model.filter = .all; model.selection = [name] }
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
    #if !LATCHKEY_APP_STORE
    @State private var checksForUpdates = false
    #else
    @ObservedObject private var pro = ProEntitlement.shared
    #endif

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
                    Text("This copy could not access iCloud Keychain. For a development build, check your signing team in App/project.yml and rebuild. Other Macs need Latchkey signed by the same team and iCloud Keychain enabled.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            #if LATCHKEY_APP_STORE
            Section("File Access") {
                Text("File access permits reading or rewriting selected project files. It does not authorize releasing secrets.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.authorizedResources) { resource in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(resource.path).font(.caption.monospaced()).lineLimit(2)
                            if model.fileAccess?.isActive(resource.id) != true {
                                Text("Unavailable; choose it again when connected.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Remove") { model.forgetFileAccess(resource.id) }
                    }
                }
                Button("Allow Project Folder…") { model.chooseProjectFolder() }
            }
            #endif
            #if LATCHKEY_APP_STORE
            Section("Latchkey Pro") {
                LabeledContent("Status", value: pro.isPro ? "Latchkey Pro is on" : "Not purchased")
                if let date = pro.purchaseDate {
                    LabeledContent("Purchased", value: date.formatted(date: .long, time: .omitted))
                }
                if !pro.isPro {
                    LabeledContent {
                        Button(pro.product.map { "Buy for \($0.displayPrice)" } ?? "Buy") { Task { await pro.buy() } }
                            .disabled(pro.product == nil || pro.busy)
                    } label: {
                        Text("Latchkey Pro")
                        Text("One purchase, no subscription. Everything in Latchkey today stays free.")
                    }
                }
                LabeledContent("Already bought it?") {
                    Button("Restore Purchases") { Task { await pro.restore() } }.disabled(pro.busy)
                }
                if let message = pro.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            #else
            Section("Latchkey Pro") {
                Text("Latchkey Pro is in the Mac App Store version.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Learn more", destination: ProLinks.pricing)
            }
            #endif
            Section("Approval") {
                LabeledContent("Method", value: model.broker.approver.method)
                Text("Allow Once authorizes one read request. Repeated reads need an explicit grant or an item set to allow reads without approval. Revoking a grant stops future reads through it; it cannot recall values already released.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Open Latchkey at login", isOn: Binding(get: { atLogin }, set: { on in
                    loginError = model.setOpensAtLogin(on)
                    atLogin = model.opensAtLogin
                }))
                Text("The command-line tool starts Latchkey when needed.").font(.caption).foregroundStyle(.secondary)
                if model.bundledTool != nil {
                    LabeledContent("Command-line tool") {
                        Button("Install") { model.installCommandLineTool() }
                    }
                    Text("Links ~/.local/bin/latchkey to the copy inside Latchkey, so it updates with the app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                #if !LATCHKEY_APP_STORE
                if let updater = AppUpdater.shared.controller?.updater {
                    Toggle("Check for updates automatically", isOn: Binding(get: { checksForUpdates }, set: { on in
                        updater.automaticallyChecksForUpdates = on
                        checksForUpdates = updater.automaticallyChecksForUpdates
                    }))
                }
                #endif
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
            #if !LATCHKEY_APP_STORE
            checksForUpdates = AppUpdater.shared.controller?.updater.automaticallyChecksForUpdates ?? false
            #endif
            model.checkLegacy()
        }
    }
}
