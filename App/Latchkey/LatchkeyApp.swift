import LatchkeyCore
import SwiftUI

@main
struct LatchkeyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Latchkey", systemImage: "key.horizontal") {
            MenuView(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Add Item", id: "add") {
            AddItemView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

@Observable @MainActor
final class AppModel {
    let store: KeychainStore
    let broker: Broker
    var items: [SecretInfo] = []
    var log: [Broker.LogEntry] = []
    var problem: String?

    private let me = PeerInfo(pid: getpid(), path: Bundle.main.bundlePath, cwd: "", chain: ["the Latchkey app"])

    init() {
        let group = Bundle.main.object(forInfoDictionaryKey: "LatchkeyAccessGroup") as? String
        store = KeychainStore.automatic(accessGroup: group)
        broker = Broker(store: store, approver: SystemApprover())
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            refresh()
            DispatchQueue.main.async { Snapshot.write(MenuView(model: self), to: path) }
            return
        }
        #endif
        let broker = broker
        Thread.detachNewThread { [weak self] in
            do { try broker.serve() } catch {
                let text = "\(error)"
                Task { @MainActor in self?.problem = text }
            }
        }
        refresh()
    }

    var synced: Bool { if case .iCloud = store.mode { true } else { false } }

    func refresh() {
        do { items = try store.list() } catch { problem = "\(error)" }
        log = Broker.readLog(limit: 15).reversed()
    }

    /// Goes through the broker so the app's own changes get the same approval and the same log line.
    func save(name: String, value: String?, kind: ItemKind?, agentSafe: Bool?, note: String?) async -> String? {
        let req = Request(op: "set", names: [name], value: value, kind: kind, agentSafe: agentSafe, note: note)
        return await run(req)
    }

    func remove(_ name: String) async -> String? {
        await run(Request(op: "rm", names: [name]))
    }

    private func run(_ req: Request) async -> String? {
        let broker = broker, me = me
        let r = await Task.detached { broker.handle(req, peer: me) }.value
        refresh()
        return r.ok ? nil : (r.error ?? "refused")
    }
}

struct MenuView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.synced ? "iCloud Keychain" : "This Mac only",
                      systemImage: model.synced ? "icloud" : "desktopcomputer")
                    .font(.headline)
                Spacer()
                Button { openWindow(id: "add"); NSApp.activate() } label: { Image(systemName: "plus") }
                    .help("Add an item")
            }
            if !model.synced {
                Text("Not syncing: this build is not signed with a team, so items stay in this Mac's login keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let p = model.problem {
                Text(p).font(.caption).foregroundStyle(.red)
            }
            Divider()
            if model.items.isEmpty {
                Text("No items yet.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.items) { ItemRow(item: $0, model: model) }
                    }
                }
                .frame(maxHeight: 260)
            }
            if !model.log.isEmpty {
                Divider()
                Text("Recent").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(Array(model.log.prefix(5).enumerated()), id: \.offset) { _, e in
                    Text("\(e.time.formatted(date: .omitted, time: .shortened))  \(e.op) \(e.names.joined(separator: ", ")): \(e.decision)")
                        .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                }
            }
            Divider()
            HStack {
                Text("Approvals: \(model.broker.approver.method)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 360)
        .onAppear { model.refresh() }
    }
}

struct ItemRow: View {
    let item: SecretInfo
    let model: AppModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.body.monospaced())
                Text(item.note.isEmpty ? item.kind.label : "\(item.kind.label) · \(item.note)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: item.agentSafe ? "person.badge.shield.checkmark" : "hand.raised")
                .foregroundStyle(item.agentSafe ? .green : .secondary)
                .help(item.agentSafe ? "Agents may read this without asking" : "Asks for approval")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(item.agentSafe ? "Require Approval" : "Mark Agent-Safe") {
                Task { _ = await model.save(name: item.name, value: nil, kind: nil, agentSafe: !item.agentSafe, note: nil) }
            }
            Button("Copy Reference") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(References.scheme + item.name, forType: .string)
            }
            Divider()
            Button("Delete…", role: .destructive) { Task { _ = await model.remove(item.name) } }
        }
    }
}

struct AddItemView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var value = ""
    @State private var kind = ItemKind.token
    @State private var agentSafe = false
    @State private var note = ""
    @State private var error: String?

    var body: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("GEMINI_API_KEY"))
            Picker("Kind", selection: $kind) {
                ForEach(ItemKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if kind == .value || kind == .key {
                TextField("Value", text: $value, axis: .vertical).lineLimit(3...8).font(.body.monospaced())
            } else {
                SecureField("Value", text: $value)
            }
            TextField("Note", text: $note)
            Toggle("Agents may read without asking", isOn: $agentSafe)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        error = await model.save(name: name, value: value, kind: kind, agentSafe: agentSafe, note: note)
                        if error == nil { value = ""; name = ""; note = ""; dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!Wire.isValidName(name) || value.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

#if DEBUG
/// `Latchkey --snapshot out.png` draws the menu bar panel off screen and exits, without starting the broker.
/// For screenshots in docs and for checking the UI without clicking.
@MainActor
enum Snapshot {
    static func write<V: View>(_ view: V, to path: String) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            do { try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path)) }
            catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
            exit(0)
        }
    }
}
#endif
