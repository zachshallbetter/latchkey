import AppKit
import LatchkeyCore
import ServiceManagement
import SwiftUI

@main
struct LatchkeyApp: App {
    init() {
        if CommandLine.arguments.contains("--broker-transport-self-test") {
            #if DEBUG && LATCHKEY_APP_STORE
            SandboxSelfTest.serveFixtureAndExit()
            #else
            FileHandle.standardError.write(Data("Transport probes require a development-signed sandbox Debug build.\n".utf8))
            exit(64)
            #endif
        }
        if CommandLine.arguments.contains("--sandbox-self-test") {
            #if DEBUG && LATCHKEY_APP_STORE
            SandboxSelfTest.runAndExit()
            #else
            FileHandle.standardError.write(Data("Sandbox probes require a development-signed sandbox Debug build.\n".utf8))
            exit(64)
            #endif
        }
        if CommandLine.arguments.contains("--vault-self-test") {
            #if DEBUG && LATCHKEY_APP_STORE
            SandboxSelfTest.runVaultAndExit()
            #else
            FileHandle.standardError.write(Data("Vault probes require a development-signed sandbox Debug build.\n".utf8))
            exit(64)
            #endif
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--file-access-self-test") {
            #if DEBUG && LATCHKEY_APP_STORE
            SandboxSelfTest.runFileAccessAndExit(phase: CommandLine.arguments.dropFirst(flag + 1).first ?? "")
            #else
            FileHandle.standardError.write(Data("File access probes require a development-signed sandbox Debug build.\n".utf8))
            exit(64)
            #endif
        }
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
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    #if !LATCHKEY_APP_STORE
    private let updater = AppUpdater.shared
    #endif

    var body: some Scene {
        Window("Latchkey", id: "main") {
            MainWindow(model: model)
                .frame(minWidth: 860, minHeight: 520)
                // In the Dock while the window is open; closing it (or quitting from the Dock) leaves the menu bar icon.
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }
        .defaultSize(width: 1080, height: 680)
        // Open the window on every launch, even if it was closed when Latchkey last quit.
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(after: .appInfo) {
                #if !LATCHKEY_APP_STORE
                CheckForUpdatesButton(updater: updater)
                #endif
                #if LATCHKEY_APP_STORE
                Link("Get the Command-Line Tool…", destination: AppModel.commandLineToolPage)
                #else
                Button("Install Command Line Tool…") { model.installCommandLineTool() }
                #endif
            }
            CommandGroup(replacing: .newItem) {
                Button("New Item…") { model.showingAdd = true }.keyboardShortcut("n")
                Button("Import .env File…") { model.chooseImportFile() }.keyboardShortcut("i", modifiers: [.command, .shift])
            }
            SettingsCommands(model: model)
            ItemCommands(model: model)
            CommandGroup(replacing: .help) {
                Link("Latchkey Help", destination: URL(string: "https://latchkey.snackstud.io/support.html")!)
                Link("Privacy Policy", destination: URL(string: "https://latchkey.snackstud.io/privacy.html")!)
                Link("Terms of Use", destination: URL(string: "https://latchkey.snackstud.io/terms.html")!)
                Divider()
                Link("Report a Security Issue", destination: URL(string: "mailto:latchkey@snackstud.io?subject=Security")!)
            }
        }

        MenuBarExtra("Latchkey", image: "MenuBarIcon") {
            MenuBarPanel(model: model)
        }
        .menuBarExtraStyle(.window)

    }
}

/// Quit from the Dock closes the window, which leaves Latchkey in the menu bar, still answering the command-line tool and
/// agents; Quit in the menu bar, the app menu, logging out and scripts quit it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        #if LATCHKEY_APP_STORE
        // Quitting means quitting unless the person chooses otherwise in Settings (guideline 2.4.5(iii)).
        UserDefaults.standard.register(defaults: [AppPreferences.Key.keepRunningFromDock: false])
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppPreferences().keepRunningFromDock, Self.quitFromDock else { return .terminateNow }
        for window in NSApp.windows where window.isVisible && window.canBecomeMain { window.close() }
        NSApp.setActivationPolicy(.accessory)
        return .terminateCancel
    }

    /// Whether the quit being handled is the Dock's: a quit Apple event sent by the Dock process.
    private static var quitFromDock: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication),
              let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        else { return false }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock"
    }
}

// MARK: - Model

enum SidebarFilter: Hashable {
    case overview, all, agentSafe, needsApproval, activity, grants, shared, deleted, settings
    case kind(ItemKind)
    case project(String)
    case service(String)

    /// Views that list items, where a selection shows its detail.
    var listsItems: Bool { ![.overview, .activity, .grants, .deleted, .settings].contains(self) }

    var title: String {
        switch self {
        case .settings: return "Settings"
        case .overview: return "Review"
        case .all: return "All Items"
        case .agentSafe: return "No Approval"
        case .needsApproval: return "Ask First"
        case .activity: return "Activity"
        case .grants: return "Grants"
        case .shared: return "Shared"
        case .deleted: return "Recently Deleted"
        case .kind(let k): return k.label + "s"
        case .project(let p): return p
        case .service(let s): return s.isEmpty ? "Other Services" : s
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

/// The environment whose remote locations sheet is open.
struct RemoteRequest: Identifiable {
    let id = UUID()
    var scope: String
}

/// The environment whose Export sheet is open.
struct ExportRequest: Identifiable {
    let id = UUID()
    var scope: String
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
        /// What the line is. Settings stay in the file, so they start unchecked.
        var cls: ImportClass
        var include = true
        var id: String { key }

        /// Changes the class and the kind and checkbox that go with it: secrets are masked, anything else is a plain
        /// value, and a setting is left in the file.
        mutating func setClass(_ c: ImportClass) {
            cls = c
            item.kind = c == .secret ? .token : .value
            include = c != .setting
        }
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
    /// Looks again while a window is open, for changes made on your other Macs.
    @ObservationIgnored private var syncTimer: Timer?
    var items: [SecretInfo] = []
    var log: [Broker.LogEntry] = []
    var grants: [Grant] = []
    /// The latest deletion of each item deleted in the last 30 days.
    var deleted: [Version] = []
    /// Earlier values currently shown; each hides itself after a short while.
    var revealedVersions: [String: String] = [:]
    var grantRequest: GrantRequest?
    var remoteRequest: RemoteRequest?
    var exportRequest: ExportRequest?
    var links: [RemoteLink] = []
    /// Each item's worst state across the links covering it; absent when nothing covers it.
    var remoteStates: [String: RemoteState] = [:]
    var deleteRequest: DeleteRequest?
    var problem: String?
    /// One-line confirmation shown at the bottom of the window, e.g. after an import.
    var notice: String?

    var filter: SidebarFilter = .all
    var settingsSection: SettingsSection = .general
    @ObservationIgnored private var revealTokens: [String: UUID] = [:]
    @ObservationIgnored private var versionRevealTokens: [String: UUID] = [:]

    func openSettings(_ section: SettingsSection? = nil) {
        if let section { settingsSection = section }
        filter = .settings
    }

    func concealRevealedValues() {
        revealed.removeAll()
        revealedVersions.removeAll()
        revealTokens.removeAll()
        versionRevealTokens.removeAll()
    }
    var selection: Set<String> = []
    var search = ""
    var sort: SortOrder = .name
    var showingAdd = false
    /// Set when the broker refuses an op that needs Latchkey Pro.
    var showingUpgrade = false
    var importDraft: ImportDraft?
    /// What to do now that keys are in Latchkey, shown after an import or an item added in the window.
    var nextSteps: NextSteps?
    var moveRequest: MoveRequest?
    /// Open groups in item lists: a project name, "project/environment", or "shared". Everything starts closed.
    /// Values currently shown in the detail pane; each hides itself after a short while.
    var revealed: [String: String] = [:]

    #if LATCHKEY_APP_STORE
    private static let fileAccessKey = "securityScopedFileAccess"
    var fileAccess: SecurityScopedAccess?
    var authorizedResources: [SecurityScopedAccess.Record] = []
    #endif

    private let me = PeerInfo(pid: getpid(), path: Bundle.main.bundlePath, cwd: "", chain: [Broker.appCaller])

    init() {
        #if DEBUG
        if Snapshot.requested {
            store = KeychainStore(mode: .thisMac)
            broker = Broker(store: MemoryStore(), approver: FixedApprover(false), logURL: nil)
            Snapshot.startParts(self)
            return
        }
        #endif
        let group = Bundle.main.object(forInfoDictionaryKey: "LatchkeyAccessGroup") as? String
        store = KeychainStore.automatic(accessGroup: group)
        // 0.1.0 development builds were io.latchkey.Latchkey with items in another access group: bring both over.
        if let previous = Bundle.main.object(forInfoDictionaryKey: "LatchkeyPreviousAccessGroup") as? String {
            let r = StoreMigration.adopt(from: previous, into: store)
            if !r.moved.isEmpty { notice = "Moved \(r.moved.count) keychain item(s) to Latchkey's new access group." }
            if !r.skipped.isEmpty || !r.failed.isEmpty {
                problem = "\(r.skipped.count + r.failed.count) item(s) are still in the old access group: "
                    + (r.skipped + r.failed.keys.sorted()).joined(separator: ", ")
            }
        }
        #if LATCHKEY_APP_STORE
        let brokerPath = (Bundle.main.object(forInfoDictionaryKey: "LatchkeyAppGroup") as? String)
            .flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
            .map { BrokerEndpoint.appStorePath(container: $0) } ?? ""
        // The sandbox can't run the services' tools: pushes go through their APIs with token items.
        let pro = ProEntitlement.shared
        broker = Broker(store: store, approver: PanelApprover(), runner: UnavailableRunner(), nativeOnly: true, socketPath: brokerPath,
                        hasPro: { pro.current() })
        if ProEntitlement.onSale { pro.start() }
        #else
        broker = Broker(store: store, approver: PanelApprover())
        #endif
        #if LATCHKEY_APP_STORE
        do {
            let access = try SecurityScopedAccess(saved: UserDefaults.standard.data(forKey: Self.fileAccessKey)) {
                UserDefaults.standard.set($0, forKey: Self.fileAccessKey)
            }
            fileAccess = access
            let failed = access.restore()
            authorizedResources = access.records
            if !failed.isEmpty { notice = "Some file access needs attention in Settings. Unavailable folders remain remembered." }
        } catch { problem = "File permissions could not be loaded. Choose files or folders again in Settings." }
        #endif
        refresh()
        #if DEBUG
        if Snapshot.requested {   // draw and exit; do not take the socket from the running copy
            Snapshot.startParts(self)
            return
        }
        #endif
        broker.onChange = { [weak self] in Task { @MainActor in self?.refresh() } }
        // Changes made on your other Macs arrive through iCloud Keychain without any notice to the app, so look again
        // whenever Latchkey comes to the front, and every 30 seconds while one of its windows is open.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) }) else { return }
                self?.refresh()
            }
        }
        let broker = broker
        Thread.detachNewThread { [weak self] in
            do {
                #if LATCHKEY_APP_STORE
                guard !broker.socketPath.isEmpty else { throw CocoaError(.fileReadNoPermission) }
                try broker.serve(gate: .commandLineTool)
                #else
                try broker.serve()
                #endif
            } catch {
                let text = "\(error)"
                Task { @MainActor in self?.problem = text }
            }
        }
        // The Safari extension's own socket, in the App Group container it can reach from its sandbox. Only the signed
        // extension may connect, and only to list item names and save a value (Broker.Gate.safariExtension).
        if let group = Bundle.main.object(forInfoDictionaryKey: "LatchkeyAppGroup") as? String,
           let path = Paths.extensionSocket(group: group) {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            Thread.detachNewThread { try? broker.serve(socketPath: path, gate: .safariExtension) }
        }
    }

    var synced: Bool { if case .iCloud = store.mode { true } else { false } }

    func refresh() {
        #if DEBUG
        if Snapshot.requested { return }
        #endif
        #if DEBUG
        if Snapshot.usesSample { return }   // keep the example data; never load real items into a sample drawing
        #endif
        do {
            let listed = try store.list()
            if listed != items { items = listed; projectIcons = [:] }   // unchanged: leave the list (and what's being edited) alone
            problem = problem?.hasPrefix("keychain") == true ? nil : problem
        } catch { problem = "\(error)" }
        log = Broker.readLog(limit: 300).reversed()
        grants = broker.grants.all()
        deleted = (try? broker.versions.deleted(existing: Set(items.map(\.name)))) ?? []
        links = (try? broker.remotes.all()) ?? []
        records = (try? broker.records.environments()) ?? []
        remoteStates = computeRemoteStates()
        let names = Set(items.map(\.name))
        if !selection.isSubset(of: names) { selection = selection.intersection(names) }
    }

    // MARK: lists

    func matches(_ f: SidebarFilter, _ i: SecretInfo) -> Bool {
        switch f {
        case .overview, .all, .activity, .grants, .deleted, .settings: return true
        case .agentSafe: return i.agentSafe
        case .needsApproval: return !i.agentSafe
        case .shared: return i.ref.isShared
        case .kind(let k): return i.kind == k
        case .project(let p): return i.ref.project == p
        case .service(let s): return s.isEmpty ? i.service == nil : i.service == s
        }
    }

    /// Every project with items, in name order.
    var projects: [String] {
        Array(Set(items.map(\.ref.project).filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var services: [String] {
        Array(Set(items.compactMap(\.service))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Categories present, in a fixed order, for the list's filter.
    var categories: [String] {
        let order = ["Token", "API Key", "Database", "URL", "Password", "Key File", "Plain Value"]
        let present = Set(items.map { ItemType($0).label })
        return order.filter(present.contains)
    }

    /// Every environment any item is in, in their usual order.
    var allEnvironments: [String] {
        Array(Set(items.filter { !$0.ref.isShared }.map(\.ref.environment))).sorted(by: Environments.order)
    }

    /// Narrowing within the list, on top of what the sidebar shows: one environment, one kind, or by access.
    var environmentFilter: String?
    /// A category as the list shows it: Token, API Key, Database, URL and so on.
    var categoryFilter: String?
    /// True: only items agents may read; false: only items that ask first.
    var accessFilter: Bool?
    var filtersActive: Bool { environmentFilter != nil || categoryFilter != nil || accessFilter != nil }

    func clearFilters() { environmentFilter = nil; categoryFilter = nil; accessFilter = nil }

    /// Environment records, for Review's unconfirmed variables.
    var records: [EnvironmentRecord] = []
    /// What's selected in Review, Activity, Recently Deleted and Grants, for their detail panes.
    var selectedFinding: String?
    /// Groups of items holding the same value, from the last Find Duplicates. Only IDs: kept in memory, never saved,
    /// and nil until asked for.
    var duplicateGroups: [[String]]?
    /// The IDs among them whose values look like identifiers rather than secrets.
    var duplicateIdentifiers: Set<String> = []
    var selectedLog: String?
    var selectedVersion: String?
    var selectedGrant: String?

    /// Confirms variables found through old file locations: one approval per environment.
    func confirmVariables(_ variables: [(scope: String, name: String)]) async {
        for (scope, names) in Dictionary(grouping: variables, by: \.scope).sorted(by: { $0.key < $1.key }) {
            if let err = await run(Request(op: "environment-set", names: [scope], confirm: names.map(\.name))) {
                notice = err
                return
            }
        }
        refresh()
    }

    /// Sidebar sections (Projects, Services) the person has folded away.
    var collapsedSections: Set<String> = []

    func environments(in project: String) -> [String] {
        Array(Set(items.filter { $0.ref.project == project }.map(\.ref.environment))).sorted(by: Environments.order)
    }

    func count(_ f: SidebarFilter) -> Int {
        switch f {
        case .activity: return log.count
        case .grants: return grants.count
        case .deleted: return deleted.count
        default: return items.filter { matches(f, $0) }.count
        }
    }

    var visibleItems: [SecretInfo] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = items.filter { matches(filter, $0) }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.note.lowercased().contains(q)
                || ($0.service ?? "").lowercased().contains(q) }
            .filter { i in environmentFilter.map { !i.ref.isShared && i.ref.environment == $0 } ?? true }
            .filter { i in categoryFilter.map { ItemType(i).label == $0 } ?? true }
            .filter { i in accessFilter.map { i.agentSafe == $0 } ?? true }
        switch sort {
        case .name:
            // Alphabetical by name, as a password manager lists items; the same name in several places by project, then environment.
            return list.sorted { a, b in
                let c = a.ref.name.localizedStandardCompare(b.ref.name)
                return c != .orderedSame ? c == .orderedAscending : a.ref < b.ref
            }
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

    /// Groups closed by hand during a search, where groups otherwise start open to show the matches.
    /// The one selected item, when exactly one is selected.
    var selectedItem: SecretInfo? { selection.count == 1 ? item(selection.first) : nil }

    func ids(inProject project: String) -> [String] {
        items.filter { $0.ref.project == project }.map(\.name).sorted()
    }

    /// Files that refer to these items, as far as Latchkey knows.
    /// Project icons found in each project's own folder, by project. Nil entries are remembered too.
    @ObservationIgnored private var projectIcons: [String: NSImage?] = [:]

    /// The project's own site icon, if its checkout has one: a favicon or app icon in the usual places, found from the
    /// folders its env files are in (and their Git checkout's top). Read from disk only; nothing is fetched.
    func projectIcon(_ project: String) -> NSImage? {
        if let cached = projectIcons[project] { return cached }
        let icon = Self.findProjectIcon(folders: items.filter { $0.ref.project == project }.flatMap { $0.usedIn ?? [] }
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent() })
        projectIcons[project] = icon
        return icon
    }

    static let projectIconPaths = [
        "public/apple-touch-icon.png", "public/icon.png", "public/favicon.png", "public/favicon.ico",
        "app/apple-icon.png", "app/icon.png", "app/favicon.ico", "src/app/apple-icon.png", "src/app/icon.png",
        "src/app/favicon.ico", "static/apple-touch-icon.png", "static/favicon.png", "static/favicon.ico",
        "apps/web/public/apple-touch-icon.png", "apps/web/public/favicon.ico", "apps/web/app/icon.png",
        "apple-touch-icon.png", "favicon.png", "favicon.ico",
    ]

    static func findProjectIcon(folders: [URL]) -> NSImage? {
        let fm = FileManager.default
        var roots: [URL] = []
        for folder in folders {
            var dir = folder.standardizedFileURL
            roots.append(dir)
            for _ in 0..<4 where !fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                let up = dir.deletingLastPathComponent()
                if up.path == dir.path { break }
                dir = up
            }
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { roots.append(dir) }
        }
        var seen = Set<String>()
        for root in roots where seen.insert(root.path).inserted {
            for path in projectIconPaths {
                let url = root.appendingPathComponent(path)
                guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 0, size < 1_000_000,
                      let image = NSImage(contentsOf: url), image.isValid else { continue }
                return image
            }
        }
        return nil
    }

    func files(for ids: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { ids.contains($0.name) }.flatMap { $0.usedIn ?? [] }.filter { seen.insert($0).inserted }
    }

    // MARK: command-line tool

    /// The tool shipped inside the app (release builds); nil in development builds, where scripts/install.sh
    /// copies it instead.
    var bundledTool: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/latchkey")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Where users of the App Store version get the command-line tool: a separately signed download, since an App
    /// Store app may not install code outside its own container (guidelines 2.4.5, 2.5.2).
    static let commandLineToolPage = URL(string: "https://latchkey.snackstud.io/cli.html")!

    /// `latchkey`, and `lk` for short, in ~/.local/bin.
    static var toolLinks: [URL] {
        ["latchkey", "lk"].map { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/\($0)") }
    }

    /// Links ~/.local/bin/latchkey and ~/.local/bin/lk to the tool inside the app, so it updates with the app. Replaces
    /// only links; a file of either name is left alone and reported.
    func installCommandLineTool() {
        #if LATCHKEY_APP_STORE
        NSWorkspace.shared.open(Self.commandLineToolPage)
        #else
        guard let tool = bundledTool else {
            notice = "This copy of Latchkey doesn't include the command-line tool; scripts/install.sh installs it."
            return
        }
        let fm = FileManager.default
        var installed: [String] = [], inTheWay: [String] = []
        do {
            try fm.createDirectory(at: Self.toolLinks[0].deletingLastPathComponent(), withIntermediateDirectories: true)
            for link in Self.toolLinks {
                let name = "~/.local/bin/" + link.lastPathComponent
                if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                    if dest == tool.path { installed.append(name); continue }
                    try fm.removeItem(at: link)
                } else if fm.fileExists(atPath: link.path) {
                    inTheWay.append(name)
                    continue
                }
                try fm.createSymbolicLink(at: link, withDestinationURL: tool)
                installed.append(name)
            }
        } catch {
            notice = "Couldn't install the command-line tool: \(error.localizedDescription)"
            return
        }
        var text = installed.isEmpty ? "" : "Installed \(installed.joined(separator: " and ")). Make sure ~/.local/bin is on your PATH."
        if !inTheWay.isEmpty { text += (text.isEmpty ? "" : " ") + "\(inTheWay.joined(separator: " and ")) already exists and isn't a link to Latchkey; left as is." }
        notice = text
        #endif
    }

    // MARK: remote locations

    func links(for scope: String) -> [RemoteLink] { links.filter { $0.scope == scope } }

    private func computeRemoteStates() -> [String: RemoteState] {
        guard !links.isEmpty else { return [:] }
        let changed = Dictionary(grouping: (try? broker.versions.list(item: nil)) ?? [], by: \.item).mapValues { $0.map(\.savedAt).max() }
        var out: [String: RemoteState] = [:]
        for item in items {
            let states = links.filter { $0.tracks(item.name) }.map { $0.state(of: item.name, valueChangedAt: changed[item.name] ?? nil) }
            if states.contains(.outOfDate) { out[item.name] = .outOfDate }
            else if states.contains(.notPushed) { out[item.name] = .notPushed }
            else if !states.isEmpty { out[item.name] = .current }
        }
        return out
    }

    /// Per-link state of one item.
    func remoteStates(of item: SecretInfo) -> [(link: RemoteLink, state: RemoteState)] {
        let changed = history(for: item.name).first?.savedAt
        return links.filter { $0.tracks(item.name) }.map { ($0, $0.state(of: item.name, valueChangedAt: changed)) }
    }

    func addLink(_ scope: String, _ target: RemoteTarget) async -> String? {
        let err = await run(Request(op: "link", names: [scope], target: target))
        if err == nil { notice = "Linked \(scope) to \(target.label)." }
        return err
    }

    func unlink(_ link: RemoteLink) async {
        if let err = await run(Request(op: "unlink", names: [link.id])) { notice = err } else { notice = "Unlinked \(link.target.label)." }
    }

    func remoteStatus(_ scope: String) async -> [RemoteStatus] {
        (await send(Request(op: "remote-status", names: [scope]))).remoteStatus ?? []
    }

    /// Pushes, then reports per target. Returns the results for the sheet to show.
    func push(_ scope: String, link: String? = nil, only: [String]? = nil) async -> [PushResult] {
        let r = await send(Request(op: "push", names: [scope], link: link, only: only))
        let results = r.pushResults ?? []
        let ok = results.filter(\.ok).count, failed = results.count - ok
        notice = results.isEmpty ? (r.error ?? "Nothing pushed.") : "Pushed \(ok) value\(ok == 1 ? "" : "s")\(failed > 0 ? "; \(failed) failed" : "")."
        return results
    }

    // MARK: history

    /// Earlier values of an item, newest first. Records only; values need approval.
    func history(for name: String) -> [Version] {
        #if DEBUG
        if Snapshot.usesSample { return Snapshot.sampleVersions.filter { $0.item == name } }
        #endif
        return (try? broker.versions.list(item: name)) ?? []
    }

    func revealVersion(_ v: Version) async {
        let r = await send(Request(op: "version", version: v.id))
        guard let value = r.values?[v.id] else { notice = r.denied != nil ? "Not approved." : (r.error ?? "Couldn't read that version."); return }
        guard !AppPreferences().hideOnDeactivate || NSApp.isActive else { notice = Self.notInFront; return }
        revealedVersions[v.id] = value
        let token = UUID()
        versionRevealTokens[v.id] = token
        let seconds = AppPreferences().revealSeconds
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if versionRevealTokens[v.id] == token {
                revealedVersions[v.id] = nil
                versionRevealTokens[v.id] = nil
            }
        }
    }

    func restore(_ v: Version) async {
        if let err = await run(Request(op: "restore", version: v.id)) {
            notice = err
        } else {
            notice = "Restored \(v.item) to its value from \(v.savedAt.formatted(date: .abbreviated, time: .shortened))."
            revealed[v.item] = nil
            selection = [v.item]
            if filter == .deleted { filter = .all }
        }
    }

    func forgetHistory(_ names: [String]) async {
        if let err = await run(Request(op: "forget", names: names)) { notice = err } else { notice = "Forgot the earlier values." }
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

    /// The only sites Latchkey for Safari may fill this item on; an empty list goes back to the default.
    func setFillSites(_ name: String, _ sites: [String]) async -> String? {
        await run(Request(op: "update", names: [name], fillSites: sites))
    }

    /// Several settings of one item in one request, so one approval: only the ones given change.
    func updateDetails(_ name: String, kind: ItemKind?, agentSafe: Bool?, service: String?, note: String?, fillSites: [String]?) async -> String? {
        guard kind != nil || agentSafe != nil || service != nil || note != nil || fillSites != nil else { return nil }
        return await run(Request(op: "update", names: [name], kind: kind, agentSafe: agentSafe, note: note, service: service, fillSites: fillSites))
    }

    func setService(_ name: String, _ service: String) async -> String? {
        await run(Request(op: "set", names: [name], service: service))
    }

    /// Moves items, then points `latchkey://` references at their new ids in each file they're recorded as
    /// used in and in `files`.
    func moveItems(_ ids: [String], project: String, environment: String, files: [URL]) async -> String? {
        let usedIn = items.filter { ids.contains($0.name) }.flatMap { $0.usedIn ?? [] }.map { URL(fileURLWithPath: $0) }
        for url in files + usedIn {
            guard requestRewriteAccess(for: url) else { return "File access was cancelled. No items were moved." }
        }
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
        if !project.isEmpty { filter = .project(project) }
        return nil
    }

    /// Compares every secret's value inside the broker (one approval) and keeps the groups that match.
    func findDuplicates() async {
        let r = await send(Request(op: "duplicates"))
        guard r.ok, let groups = r.groups else { notice = r.error ?? "Finding duplicates failed."; return }
        duplicateGroups = groups
        duplicateIdentifiers = Set(r.identifiers ?? [])
        notice = groups.isEmpty ? "No two items hold the same value." : "Found \(groups.count) group\(groups.count == 1 ? "" : "s") of items holding the same value."
        selectedFinding = groups.first.map { "dup-\($0[0])" } ?? selectedFinding
    }

    /// Marks items as plain values: shown instead of masked, and left out of Find Duplicates.
    func makePlain(_ ids: [String]) async {
        if let err = await run(Request(op: "update", names: ids, kind: .value)) { notice = err; return }
        duplicateGroups = duplicateGroups?.filter { Set($0).isDisjoint(with: ids) }
        selectedFinding = nil
        notice = "Marked \(ids.count) item\(ids.count == 1 ? "" : "s") as plain values."
    }

    /// Makes `ids` one item, `into` (shared, or in the environment they're all in), then points references at it in each file they're recorded as used in.
    func combine(_ ids: [String], into: String) async -> String? {
        let usedIn = items.filter { ids.contains($0.name) }.flatMap { $0.usedIn ?? [] }.map { URL(fileURLWithPath: $0) }
        for url in usedIn {
            guard requestRewriteAccess(for: url) else { return "File access was cancelled. Nothing was combined." }
        }
        let r = await send(Request(op: "combine", names: ids, into: into))
        guard r.ok else { return r.error ?? (r.missing.map { "No item named \($0.joined(separator: ", "))." } ?? "Combining failed.") }
        let moved = r.moved ?? [:]
        var updated = 0, failed: [String] = []
        var seen = Set<String>()
        for url in usedIn where seen.insert(url.path).inserted && FileManager.default.fileExists(atPath: url.path) {
            do { if try EnvFile.renameReferences(in: url, moved) { updated += 1 } } catch { failed.append(url.lastPathComponent) }
        }
        var text = "Combined \(ids.count) items into \(into)"
        if updated > 0 { text += "; updated references in \(updated) file\(updated == 1 ? "" : "s")" }
        if !failed.isEmpty { text += "; couldn't update \(failed.joined(separator: ", "))" }
        notice = text + ". The originals are in Recently Deleted."
        duplicateGroups = duplicateGroups?.filter { Set($0).isDisjoint(with: ids) }
        selectedFinding = nil
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

    /// Asks for approval unless the item is available without approval or covered by a grant.
    func value(of name: String) async -> String? {
        let r = await send(Request(op: "get", names: [name]))
        if let v = r.values?[name] { return v }
        notice = r.denied != nil ? "Not approved." : (r.error ?? "Could not read \(name).")
        return nil
    }

    /// Why an approved value wasn't shown: Latchkey went to the back while it was asked for, and values hide then.
    static let notInFront = "Not shown: Latchkey wasn't in front, and values hide when it loses focus. Show it again."

    func reveal(_ name: String) async {
        guard let v = await value(of: name) else { return }
        guard !AppPreferences().hideOnDeactivate || NSApp.isActive else { notice = Self.notInFront; return }
        revealed[name] = v
        let token = UUID()
        revealTokens[name] = token
        let seconds = AppPreferences().revealSeconds
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if revealTokens[name] == token {
                revealed[name] = nil
                revealTokens[name] = nil
            }
        }
    }

    func copyValue(_ name: String) async {
        guard let v = await value(of: name) else { return }
        copyToClipboard(v, notice: "Copied \(name).")
    }

    /// This Mac only, concealed from compatible clipboard managers, and cleared on the chosen timer if unchanged.
    private func copyToClipboard(_ text: String, notice message: String) {
        let stamp = Clipboard.copy(text)
        let seconds = AppPreferences().clipboardSeconds
        notice = "\(message) The clipboard clears in \(seconds) seconds."
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            Clipboard.clear(ifUnchangedSince: stamp)
        }
    }

    /// The environment as an env block on the clipboard, for a dashboard that takes a pasted one. Asks every time,
    /// naming the environment and the clipboard; a record with no items to release copies without asking.
    func copyAsEnv(_ scope: String) async {
        guard let record = records.first(where: { $0.scope == scope }) else {
            notice = "\(scope) has no environment record. lk env migrate makes one."
            return
        }
        let credentials = Array(Set(record.variables.values.compactMap(\.item))).sorted()
        var released: [String: String] = [:]
        if !credentials.isEmpty {
            let r = await send(Request(op: "export", names: credentials, project: scope, clipboard: true,
                                       clearAfter: AppPreferences().clipboardSeconds))
            if let m = r.missing, !m.isEmpty { notice = "Not in Latchkey: \(m.joined(separator: ", "))."; return }
            guard r.ok, let values = r.values, credentials.allSatisfy({ values[$0] != nil }) else {
                notice = r.error ?? "Could not copy \(scope)."
                return
            }
            released = values
        }
        copyToClipboard(record.envFile(values: released, header: false), notice: "Copied \(scope) as .env.")
    }

    /// Writes the environment's env file through the same checks as `lk export`. Returns an error, or nil when written.
    func exportEnvironment(_ plan: EnvExport.Plan, scope: String, values: Bool) async -> String? {
        guard let record = records.first(where: { $0.scope == scope }) else { return "\(scope) has no environment record." }
        let credentials = Array(Set(record.variables.values.compactMap(\.item))).sorted()
        var released: [String: String] = [:]
        if values && !credentials.isEmpty {
            if let problem = EnvExport.gitProblem(plan.path) { return problem }
            let r = await send(Request(op: "export", names: credentials, project: scope, destination: plan.path))
            if let m = r.missing, !m.isEmpty { return "Not in Latchkey: \(m.joined(separator: ", "))." }
            guard r.ok, let v = r.values, credentials.allSatisfy({ v[$0] != nil }) else { return r.error ?? "Not approved." }
            released = v
        }
        do {
            let result = try EnvExport.write(plan, record: record, released: released)
            notice = plan.existing != nil ? "Merged \(result.added.count) added, \(result.updated.count) updated into \(Broker.tilde(plan.path))."
                                          : "Wrote \(Broker.tilde(plan.path))."
            return nil
        } catch { return error.localizedDescription }
    }

    func copyReference(_ name: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(References.scheme + name, forType: .string)
        notice = "Copied \(References.scheme)\(name)."
    }

    private func send(_ req: Request) async -> Response {
        let broker = broker, me = me
        let r = await Task.detached { broker.handle(req, peer: me) }.value
        if ProGate.isRefusal(r.error) { showingUpgrade = true }
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
        do { try rememberSelectedURL(url, isDirectory: false) }
        catch { notice = error.localizedDescription; return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            notice = "Could not read \(url.lastPathComponent)."
            return
        }
        let project = EnvImport.project(forFile: url), environment = EnvImport.environment(forFile: url.lastPathComponent)
        // Plan as shared so each item's name is its key; the sheet places them.
        let plan: EnvImport.Plan
        do { plan = try EnvImport.plan(text, source: url.lastPathComponent, location: url.path) }
        catch { notice = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"; return }
        guard !plan.items.isEmpty || !plan.settings.isEmpty else {
            notice = "Nothing to import in \(url.lastPathComponent)."
            return
        }
        let rows = (plan.items + plan.settings).sorted { $0.name < $1.name }
            .map { ImportDraft.Row(key: $0.name, item: $0, cls: plan.classes[$0.name] ?? .secret) }
        var draft = ImportDraft(url: url, text: text, rows: rows,
                                ignored: plan.ignored.filter { plan.classes[$0.key] != .setting },
                                project: project, environment: environment)
        let existing = Set(items.map(\.name))
        for i in draft.rows.indices { draft.rows[i].include = draft.rows[i].cls != .setting && !existing.contains(draft.itemID(draft.rows[i].key)) }
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
        guard !rewrite || requestRewriteAccess(for: draft.url) else { return "File access was cancelled. Nothing was imported." }
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
        let folder = draft.url.deletingLastPathComponent().path, file = draft.url.lastPathComponent
        let rewritten = rewrite && parts.contains { $0.contains("now uses latchkey://") }
        nextSteps = NextSteps(
            title: "Imported \(saved.count) item\(saved.count == 1 ? "" : "s")",
            body: rewritten
                ? "\(file) now holds latchkey:// references instead of values. Run your project through lk run, and the values are filled in as it starts. Replace npm run dev with your own command."
                : "The values are in Latchkey. Put latchkey:// references in your env file in their place, then run your project through lk run. Replace npm run dev with your own command.",
            commands: ["cd \(Broker.tilde(folder))", "lk run --env-file \(file) -- npm run dev"],
            agents: true)
        return nil
    }

    // MARK: moving to iCloud Keychain

    /// Items an unsigned copy left in this Mac's login keychain. Only looked for once this copy syncs.
    var legacyItems: [String] = []

    func checkLegacy() {
        #if DEBUG
        if Snapshot.requested { return }
        #endif
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

    // MARK: user-selected files

    /// The direct build needs no persistent sandbox extension. The store experiment retains only resources
    /// the user explicitly chose, following the same Foundation bookmark lifecycle as Peel's FolderAccess.
    func rememberSelectedURL(_ url: URL, isDirectory: Bool) throws {
        #if LATCHKEY_APP_STORE
        let container = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == container || path.hasPrefix(container + "/") { return }
        guard let fileAccess else { throw SecurityScopedAccess.AccessError.unavailable }
        try fileAccess.remember(url, isDirectory: isDirectory)
        authorizedResources = fileAccess.records
        #endif
    }

    /// Atomic replacement needs access to the parent folder, not only the selected .env file.
    func requestRewriteAccess(for file: URL) -> Bool {
        #if LATCHKEY_APP_STORE
        let folder = file.deletingLastPathComponent().standardizedFileURL
        let path = folder.path
        let container = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == container || path.hasPrefix(container + "/") { return true }
        if authorizedResources.contains(where: {
            $0.isDirectory && fileAccess?.isActive($0.id) == true &&
            (path == $0.path || path.hasPrefix($0.path == "/" ? "/" : $0.path + "/"))
        }) { return true }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = folder
        panel.prompt = "Allow"
        panel.message = "Choose this file’s folder, or a parent folder, so Latchkey can replace the file safely. Secret access still requires separate approval."
        guard panel.runModal() == .OK, let chosen = panel.url else { return false }
        let selected = chosen.standardizedFileURL.path
        guard path == selected || path.hasPrefix(selected == "/" ? "/" : selected + "/") else {
            notice = "Choose the file’s folder or one of its parents."
            return false
        }
        do { try rememberSelectedURL(chosen, isDirectory: true); return true }
        catch { notice = error.localizedDescription; return false }
        #else
        return true
        #endif
    }

    #if LATCHKEY_APP_STORE
    func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Allow"
        panel.message = "Choose a project folder Latchkey may read and update. Secret access still requires separate approval."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try rememberSelectedURL(url, isDirectory: true) }
        catch { notice = error.localizedDescription }
    }

    func forgetFileAccess(_ id: UUID) {
        do {
            try fileAccess?.forget(id)
            authorizedResources = fileAccess?.records ?? []
        } catch { notice = "Could not remove file access: \(error.localizedDescription)" }
    }
    #endif

    // MARK: settings

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
