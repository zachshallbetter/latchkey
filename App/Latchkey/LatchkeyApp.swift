import AppKit
import LatchkeyCore
import ServiceManagement
import SwiftUI

@main
struct LatchkeyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Latchkey", id: "main") {
            MainWindow(model: model)
                .frame(minWidth: 860, minHeight: 520)
        }
        .defaultSize(width: 1080, height: 680)
        // Open the window on every launch, even if it was closed when Latchkey last quit.
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Item…") { model.showingAdd = true }.keyboardShortcut("n")
                Button("Import .env File…") { model.chooseImportFile() }.keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("Latchkey", image: "MenuBarIcon") {
            MenuBarPanel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

// MARK: - Model

enum SidebarFilter: Hashable {
    case all, agentSafe, needsApproval, activity, grants
    case kind(ItemKind)

    var title: String {
        switch self {
        case .all: return "All"
        case .agentSafe: return "Agent-Safe"
        case .needsApproval: return "Ask First"
        case .activity: return "Activity"
        case .grants: return "Grants"
        case .kind(let k): return k.label + "s"
        }
    }
}

enum SortOrder: String, CaseIterable {
    case name = "Name"
    case updated = "Recently Changed"
}

struct ImportDraft: Identifiable {
    struct Row: Identifiable {
        var item: ImportItem
        var include = true
        var exists: Bool
        var id: String { item.name }
    }
    let id = UUID()
    let url: URL
    let text: String
    var rows: [Row]
    var ignored: [String: String]
}

@Observable @MainActor
final class AppModel {
    let store: KeychainStore
    let broker: Broker
    var items: [SecretInfo] = []
    var log: [Broker.LogEntry] = []
    var grants: [Grant] = []
    var showingNewGrant = false
    var problem: String?
    /// One-line confirmation shown at the bottom of the window, e.g. after an import.
    var notice: String?

    var filter: SidebarFilter = .all
    var selection: String?
    var search = ""
    var sort: SortOrder = .name
    var showingAdd = false
    var importDraft: ImportDraft?
    /// Values currently shown in the detail pane; each hides itself after a short while.
    var revealed: [String: String] = [:]

    private let me = PeerInfo(pid: getpid(), path: Bundle.main.bundlePath, cwd: "", chain: [Broker.appCaller])
    static let approvalWindowKey = "readApprovalWindow"

    init() {
        let group = Bundle.main.object(forInfoDictionaryKey: "LatchkeyAccessGroup") as? String
        store = KeychainStore.automatic(accessGroup: group)
        let saved = UserDefaults.standard.object(forKey: Self.approvalWindowKey) as? Double ?? 120
        broker = Broker(store: store, approver: PanelApprover(), readApprovalWindow: saved)
        refresh()
        #if DEBUG
        if Snapshot.requested { return }   // draw and exit; do not take the socket from the running copy
        #endif
        broker.onChange = { [weak self] in Task { @MainActor in self?.refresh() } }
        let broker = broker
        Thread.detachNewThread { [weak self] in
            do { try broker.serve() } catch {
                let text = "\(error)"
                Task { @MainActor in self?.problem = text }
            }
        }
    }

    var synced: Bool { if case .iCloud = store.mode { true } else { false } }

    func refresh() {
        do {
            items = try store.list()
            problem = problem?.hasPrefix("keychain") == true ? nil : problem
        } catch { problem = "\(error)" }
        log = Broker.readLog(limit: 300).reversed()
        grants = broker.grants.all()
        if let s = selection, !items.contains(where: { $0.name == s }) { selection = nil }
    }

    // MARK: lists

    func matches(_ f: SidebarFilter, _ i: SecretInfo) -> Bool {
        switch f {
        case .all, .activity, .grants: return true
        case .agentSafe: return i.agentSafe
        case .needsApproval: return !i.agentSafe
        case .kind(let k): return i.kind == k
        }
    }

    func count(_ f: SidebarFilter) -> Int {
        switch f {
        case .activity: return log.count
        case .grants: return grants.count
        default: return items.filter { matches(f, $0) }.count
        }
    }

    var visibleItems: [SecretInfo] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = items.filter { matches(filter, $0) }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.note.lowercased().contains(q) }
        switch sort {
        case .name: return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .updated: return list.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    var visibleLog: [Broker.LogEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return log }
        return log.filter { e in
            e.names.contains { $0.lowercased().contains(q) } || e.op.contains(q) || e.cwd.lowercased().contains(q)
        }
    }

    func item(_ name: String?) -> SecretInfo? { items.first { $0.name == name } }

    func grants(for name: String) -> [Grant] { grants.filter { $0.names.contains(name) } }

    func createGrant(names: [String], folder: String, duration: TimeInterval) async -> String? {
        let err = await run(Request(op: "grant", names: names, folder: folder, duration: duration))
        if err == nil { notice = "Programs in \(Broker.tilde(folder)) can read \(names.count == 1 ? names[0] : "\(names.count) items") for \(GrantStore.describe(duration))." }
        return err
    }

    func revoke(_ id: String) async {
        if let err = await run(Request(op: "revoke", names: [id])) { notice = err }
    }

    func activity(for name: String) -> [Broker.LogEntry] {
        Array(log.filter { $0.names.contains(name) }.prefix(8))
    }

    // MARK: actions (all through the broker: same approval, same log)

    func save(name: String, value: String?, kind: ItemKind?, agentSafe: Bool?, note: String?) async -> String? {
        await run(Request(op: "set", names: [name], value: value, kind: kind, agentSafe: agentSafe, note: note))
    }

    func remove(_ name: String) async -> String? {
        let err = await run(Request(op: "rm", names: [name]))
        if err == nil { revealed[name] = nil; notice = "Deleted \(name)." }
        return err
    }

    /// Asks for approval unless the item is agent-safe or was approved moments ago.
    func value(of name: String) async -> String? {
        let r = await send(Request(op: "get", names: [name]))
        if let v = r.values?[name] { return v }
        notice = r.denied != nil ? "Not approved." : (r.error ?? "Could not read \(name).")
        return nil
    }

    func reveal(_ name: String) async {
        guard let v = await value(of: name) else { return }
        revealed[name] = v
        Task {
            try? await Task.sleep(for: .seconds(30))
            if revealed[name] == v { revealed[name] = nil }
        }
    }

    func copyValue(_ name: String) async {
        guard let v = await value(of: name) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(v, forType: .string)
        // Clipboard managers that honour this skip the entry.
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let stamp = pb.changeCount
        notice = "Copied \(name). The clipboard clears in 60 seconds."
        Task {
            try? await Task.sleep(for: .seconds(60))
            if pb.changeCount == stamp { pb.clearContents() }
        }
    }

    func copyReference(_ name: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(References.scheme + name, forType: .string)
        notice = "Copied \(References.scheme)\(name)."
    }

    private func send(_ req: Request) async -> Response {
        let broker = broker, me = me
        let r = await Task.detached { broker.handle(req, peer: me) }.value
        refresh()
        return r
    }

    private func run(_ req: Request) async -> String? {
        let r = await send(req)
        return r.ok ? nil : (r.error ?? "refused")
    }

    // MARK: import

    func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.title = "Import a .env File"
        panel.message = "Choose a file of KEY=VALUE lines. You will review the items before anything is saved."
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        beginImport(url)
    }

    func beginImport(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            notice = "Could not read \(url.lastPathComponent)."
            return
        }
        let plan = EnvImport.plan(text, source: url.lastPathComponent)
        guard !plan.items.isEmpty else {
            notice = "Nothing to import in \(url.lastPathComponent)."
            return
        }
        let existing = Set(items.map(\.name))
        importDraft = ImportDraft(url: url, text: text,
                                  rows: plan.items.map { .init(item: $0, include: !existing.contains($0.name), exists: existing.contains($0.name)) },
                                  ignored: plan.ignored)
    }

    func runImport(_ draft: ImportDraft, replace: Bool, rewrite: Bool) async -> String? {
        let chosen = draft.rows.filter(\.include).map(\.item)
        guard !chosen.isEmpty else { return "Nothing selected." }
        let r = await send(Request(op: "import", items: chosen, replace: replace, source: draft.url.path))
        guard r.ok else { return r.error ?? "Import failed." }
        let saved = Set((r.added ?? []) + (r.replaced ?? []))
        var parts = ["Imported \(saved.count) item\(saved.count == 1 ? "" : "s")"]
        if let s = r.skipped, !s.isEmpty { parts.append("skipped \(s.count) that already existed") }
        if rewrite, !saved.isEmpty {
            do {
                try EnvFile.rewriteFile(at: draft.url, original: draft.text, toReferences: saved)
                parts.append("\(draft.url.lastPathComponent) now uses latchkey:// references")
            } catch {
                parts.append("but \(draft.url.lastPathComponent) could not be rewritten: \(error.localizedDescription)")
            }
        }
        notice = parts.joined(separator: ", ") + "."
        return nil
    }

    // MARK: moving to iCloud Keychain

    /// Items an unsigned copy left in this Mac's login keychain. Only looked for once this copy syncs.
    var legacyItems: [String] = []

    func checkLegacy() {
        legacyItems = synced ? ((try? KeychainStore(mode: .thisMac).list().map(\.name)) ?? []) : []
    }

    func moveLegacyItems() async {
        let count = legacyItems.count
        let store = store
        let ok = await Task.detached {
            SystemApprover().confirm("move \(count) item\(count == 1 ? "" : "s") from this Mac's login keychain to iCloud Keychain")
        }.value
        guard ok else { notice = "Not approved."; return }
        do {
            let r = try await Task.detached { try StoreMigration.move(from: KeychainStore(mode: .thisMac), to: store) }.value
            var parts = ["Moved \(r.moved.count) item\(r.moved.count == 1 ? "" : "s") to iCloud Keychain"]
            if !r.skipped.isEmpty { parts.append("left \(r.skipped.joined(separator: ", ")) because iCloud Keychain already has that name") }
            if !r.failed.isEmpty { parts.append("couldn't move \(r.failed.keys.sorted().joined(separator: ", "))") }
            notice = parts.joined(separator: "; ") + "."
        } catch {
            notice = "Couldn't move items: \(error)"
        }
        refresh()
        checkLegacy()
    }

    // MARK: settings

    var approvalWindow: Double {
        get { broker.readApprovalWindow }
        set {
            broker.readApprovalWindow = newValue
            UserDefaults.standard.set(newValue, forKey: Self.approvalWindowKey)
        }
    }

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setOpensAtLogin(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
