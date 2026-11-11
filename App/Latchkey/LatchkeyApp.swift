import AppKit
import LatchkeyCore
import ServiceManagement
import SwiftUI

@main
struct LatchkeyApp: App {
    init() {
        // A second copy started outside Launch Services (from a shell, another build) hands over to the one
        // already running and quits, before it touches the keychain or the broker socket.
        #if DEBUG
        let snapshot = Snapshot.requested
        #else
        let snapshot = false
        #endif
        if !snapshot, let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != getpid() }) {
            other.activate()
            exit(0)
        }
        _model = State(initialValue: AppModel())
    }

    @State private var model: AppModel

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
    case all, agentSafe, needsApproval, activity, grants, shared
    case kind(ItemKind)
    case project(String)
    case service(String)

    var title: String {
        switch self {
        case .all: return "All"
        case .agentSafe: return "Agent-Safe"
        case .needsApproval: return "Ask First"
        case .activity: return "Activity"
        case .grants: return "Grants"
        case .shared: return "Shared"
        case .kind(let k): return k.label + "s"
        case .project(let p): return p
        case .service(let s): return s
        }
    }
}

/// Items picked for the Move sheet.
struct MoveRequest: Identifiable {
    let id = UUID()
    var ids: [String]
}

/// What the New Grant sheet starts with: chosen items, or a whole project or environment (`acp/*`).
struct GrantRequest: Identifiable {
    let id = UUID()
    var ids: [String] = []
    var pattern: String?
}

/// Items waiting for the delete confirmation.
struct DeleteRequest: Identifiable {
    let id = UUID()
    var ids: [String]
}

enum SortOrder: String, CaseIterable {
    case name = "Name"
    case updated = "Recently Changed"
}

struct ImportDraft: Identifiable {
    struct Row: Identifiable {
        /// The .env key; the item id comes from the draft's project and environment.
        let key: String
        var item: ImportItem
        var include = true
        var id: String { key }
    }
    let id = UUID()
    let url: URL
    let text: String
    var rows: [Row]
    var ignored: [String: String]
    var project: String
    var environment: String
    var shared = false

    func itemID(_ key: String) -> String {
        shared ? key : ItemID(project: project, environment: environment, name: key).string
    }

    var placeIsValid: Bool { shared || (ItemID.isValidPart(project) && ItemID.isValidPart(environment)) }
}

@Observable @MainActor
final class AppModel {
    let store: KeychainStore
    let broker: Broker
    var items: [SecretInfo] = []
    var log: [Broker.LogEntry] = []
    var grants: [Grant] = []
    var grantRequest: GrantRequest?
    var deleteRequest: DeleteRequest?
    var problem: String?
    /// One-line confirmation shown at the bottom of the window, e.g. after an import.
    var notice: String?

    var filter: SidebarFilter = .all
    var selection: Set<String> = []
    var search = ""
    var sort: SortOrder = .name
    var showingAdd = false
    var importDraft: ImportDraft?
    var moveRequest: MoveRequest?
    /// Open groups in item lists: a project name, "project/environment", or "shared". Everything starts closed.
    var expanded: Set<String> = []
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
        if Snapshot.requested {   // draw and exit; do not take the socket from the running copy
            Snapshot.startParts(self)
            return
        }
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
        let names = Set(items.map(\.name))
        if !selection.isSubset(of: names) { selection = selection.intersection(names) }
    }

    // MARK: lists

    func matches(_ f: SidebarFilter, _ i: SecretInfo) -> Bool {
        switch f {
        case .all, .activity, .grants: return true
        case .agentSafe: return i.agentSafe
        case .needsApproval: return !i.agentSafe
        case .shared: return i.ref.isShared
        case .kind(let k): return i.kind == k
        case .project(let p): return i.ref.project == p
        case .service(let s): return i.service == s
        }
    }

    /// Every project with items, in name order.
    var projects: [String] {
        Array(Set(items.map(\.ref.project).filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var services: [String] {
        Array(Set(items.compactMap(\.service))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func environments(in project: String) -> [String] {
        Array(Set(items.filter { $0.ref.project == project }.map(\.ref.environment))).sorted(by: Environments.order)
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
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.note.lowercased().contains(q)
                || ($0.service ?? "").lowercased().contains(q) }
        switch sort {
        case .name: return list.sorted { $0.ref < $1.ref }
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

    /// Whether a list group is open. The only group in a list, and every group while searching, stay open.
    func isOpen(_ key: String, single: Bool = false) -> Bool {
        single || !search.trimmingCharacters(in: .whitespaces).isEmpty || expanded.contains(key)
    }

    func toggle(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    /// Opens the groups that contain these items, so a selection made elsewhere is visible.
    func reveal(_ ids: [String]) {
        for id in ids {
            guard let ref = ItemID(id) else { continue }
            if ref.isShared { expanded.insert("shared") } else { expanded.formUnion([ref.project, "\(ref.project)/\(ref.environment)"]) }
        }
    }

    /// The one selected item, when exactly one is selected.
    var selectedItem: SecretInfo? { selection.count == 1 ? item(selection.first) : nil }

    func ids(inProject project: String) -> [String] {
        items.filter { $0.ref.project == project }.map(\.name).sorted()
    }

    /// Files that refer to these items, as far as Latchkey knows.
    func files(for ids: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { ids.contains($0.name) }.flatMap { $0.usedIn ?? [] }.filter { seen.insert($0).inserted }
    }

    // MARK: several items, one approval

    func updateItems(_ ids: [String], agentSafe: Bool? = nil, kind: ItemKind? = nil, service: String? = nil) async {
        guard !ids.isEmpty else { return }
        if let err = await run(Request(op: "update", names: ids, kind: kind, agentSafe: agentSafe, service: service)) {
            notice = err
        } else {
            notice = "Updated \(ids.count) item\(ids.count == 1 ? "" : "s")."
        }
    }

    func removeItems(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        if let err = await run(Request(op: "rm", names: ids)) {
            notice = err
        } else {
            for id in ids { revealed[id] = nil }
            notice = "Deleted \(ids.count) item\(ids.count == 1 ? "" : "s")."
        }
    }

    func grants(for name: String) -> [Grant] { grants.filter { $0.names.contains { Grant.entry($0, matches: name) } } }

    func setService(_ name: String, _ service: String) async -> String? {
        await run(Request(op: "set", names: [name], service: service))
    }

    /// Moves items, then points `latchkey://` references at their new ids in each file they're recorded as
    /// used in and in `files`.
    func moveItems(_ ids: [String], project: String, environment: String, files: [URL]) async -> String? {
        let usedIn = items.filter { ids.contains($0.name) }.flatMap { $0.usedIn ?? [] }.map { URL(fileURLWithPath: $0) }
        let r = await send(Request(op: "move", names: ids, project: project, environment: environment))
        guard r.ok else { return r.error ?? (r.missing.map { "No item named \($0.joined(separator: ", "))." } ?? "Move failed.") }
        let moved = r.moved ?? [:]
        var updated = 0, failed: [String] = []
        var seen = Set<String>()
        for url in files + usedIn where seen.insert(url.path).inserted && FileManager.default.fileExists(atPath: url.path) {
            do { if try EnvFile.renameReferences(in: url, moved) { updated += 1 } } catch { failed.append(url.lastPathComponent) }
        }
        let place = project.isEmpty ? "shared items" : "\(project)/\(environment)"
        var text = "Moved \(moved.count) item\(moved.count == 1 ? "" : "s") to \(place)"
        if updated > 0 { text += "; updated references in \(updated) file\(updated == 1 ? "" : "s")" }
        if !failed.isEmpty { text += "; couldn't update \(failed.joined(separator: ", "))" }
        notice = text + "."
        selection = Set(selection.map { moved[$0] ?? $0 })
        reveal(Array(selection))
        if !project.isEmpty { filter = .project(project) }
        return nil
    }

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
        let project = EnvImport.project(forFile: url), environment = EnvImport.environment(forFile: url.lastPathComponent)
        // Plan as shared so each item's name is its key; the sheet places them.
        let plan = EnvImport.plan(text, source: url.lastPathComponent, location: url.path)
        guard !plan.items.isEmpty else {
            notice = "Nothing to import in \(url.lastPathComponent)."
            return
        }
        var draft = ImportDraft(url: url, text: text, rows: plan.items.map { .init(key: $0.name, item: $0) },
                                ignored: plan.ignored, project: project, environment: environment)
        let existing = Set(items.map(\.name))
        for i in draft.rows.indices { draft.rows[i].include = !existing.contains(draft.itemID(draft.rows[i].key)) }
        importDraft = draft
    }

    func runImport(_ draft: ImportDraft, replace: Bool, rewrite: Bool) async -> String? {
        guard draft.placeIsValid else { return "The project and environment can use letters, digits, _ - . only." }
        var references: [String: String] = [:]
        let chosen = draft.rows.filter(\.include).map { row -> ImportItem in
            var item = row.item
            item.name = draft.itemID(row.key)
            references[row.key] = item.name
            return item
        }
        guard !chosen.isEmpty else { return "Nothing selected." }
        let r = await send(Request(op: "import", items: chosen, replace: replace, source: draft.url.path))
        guard r.ok else { return r.error ?? "Import failed." }
        let saved = Set((r.added ?? []) + (r.replaced ?? []))
        var parts = ["Imported \(saved.count) item\(saved.count == 1 ? "" : "s")"]
        if let s = r.skipped, !s.isEmpty { parts.append("skipped \(s.count) that already existed") }
        if rewrite, !saved.isEmpty {
            do {
                try EnvFile.rewriteFile(at: draft.url, original: draft.text, toReferences: references.filter { saved.contains($0.value) })
                parts.append("\(draft.url.lastPathComponent) now uses latchkey:// references")
            } catch {
                parts.append("but \(draft.url.lastPathComponent) could not be rewritten: \(error.localizedDescription)")
            }
        }
        notice = parts.joined(separator: ", ") + "."
        if !draft.shared { filter = .project(draft.project) }
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
