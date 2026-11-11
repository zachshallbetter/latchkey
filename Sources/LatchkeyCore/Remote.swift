import Foundation
import Security

/// A place outside this Mac that holds an environment's values: a Vercel project's environment, a GitHub
/// repository's (or GitHub environment's) Actions secrets, a Railway service, or a Fly app.
public struct RemoteTarget: Codable, Hashable, Sendable {
    public enum Service: String, Codable, CaseIterable, Sendable {
        case vercel, github, railway, fly

        public var label: String {
            switch self {
            case .vercel: return "Vercel"
            case .github: return "GitHub Actions"
            case .railway: return "Railway"
            case .fly: return "Fly"
            }
        }

        /// The command-line tool that talks to it, signed in as you.
        public var tool: String {
            switch self {
            case .vercel: return "vercel"
            case .github: return "gh"
            case .railway: return "railway"
            case .fly: return "flyctl"
            }
        }
    }

    public var service: Service
    /// Vercel project name or ID; Railway project ID. Optional when `directory` is linked to one.
    public var project: String?
    /// Vercel: development, preview or production. GitHub: a GitHub environment (none means repository
    /// secrets). Railway: the environment.
    public var environment: String?
    /// GitHub: owner/repo.
    public var repo: String?
    /// Railway: the service.
    public var serviceName: String?
    /// Fly: the app.
    public var app: String?
    /// Vercel preview: one Git branch.
    public var branch: String?
    /// Where to run the tool, for tools that read a linked project from the folder (`vercel link`, `railway link`).
    public var directory: String?

    public init(service: Service, project: String? = nil, environment: String? = nil, repo: String? = nil,
                serviceName: String? = nil, app: String? = nil, branch: String? = nil, directory: String? = nil) {
        self.service = service
        self.project = project
        self.environment = environment
        self.repo = repo
        self.serviceName = serviceName
        self.app = app
        self.branch = branch
        self.directory = directory
    }

    /// "Vercel shop · production", "GitHub Actions owner/repo", "Fly shop-api".
    public var label: String {
        var parts: [String] = []
        switch service {
        case .vercel: parts = [project ?? directory.map { ($0 as NSString).lastPathComponent } ?? "linked project", environment ?? ""]
        case .github: parts = [repo ?? "", environment.map { "environment \($0)" } ?? ""]
        case .railway: parts = [serviceName ?? project ?? "linked project", environment ?? ""]
        case .fly: parts = [app ?? ""]
        }
        if let b = branch, !b.isEmpty { parts.append("branch \(b)") }
        return service.label + " " + parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Production gets an extra confirmation on every push. Fly secrets apply to the running app, so a Fly app
    /// counts as production unless its name says otherwise.
    public var isProduction: Bool {
        let env = (environment ?? "").lowercased()
        switch service {
        case .vercel: return env == "production"
        case .github, .railway: return env.contains("prod")
        case .fly:
            let a = (app ?? "").lowercased()
            return !(a.contains("staging") || a.contains("preview") || a.contains("dev"))
        }
    }

    /// What's missing for this target to be usable, or nil.
    public var problem: String? {
        func set(_ s: String?) -> Bool { !(s ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        switch service {
        case .vercel:
            guard let e = environment, ["development", "preview", "production"].contains(e) else {
                return "Vercel needs an environment: development, preview or production"
            }
            if !set(project) && !set(directory) { return "Vercel needs a project, or a folder linked with `vercel link`" }
            if set(branch) && e != "preview" { return "A Git branch only applies to Vercel preview" }
        case .github:
            guard let r = repo, r.split(separator: "/").count == 2 else { return "GitHub needs a repository as owner/repo" }
        case .railway:
            if !set(project) && !set(directory) { return "Railway needs a project ID, or a folder linked with `railway link`" }
            if !set(environment) { return "Railway needs an environment" }
            if !set(serviceName) { return "Railway needs a service" }
        case .fly:
            if !set(app) { return "Fly needs an app" }
        }
        return nil
    }

    /// The environment name Latchkey suggests for values that go here: `vercel.preview`, `railway.production`.
    public var suggestedEnvironment: String {
        switch service {
        case .fly: return "fly"
        case .github: return environment.map { "github.\($0)" } ?? "github"
        default: return "\(service.rawValue).\(environment ?? "")"
        }
    }
}

/// One command to run: a tool, its arguments, and what to write to its standard input. Values only ever travel
/// on standard input, never in arguments, so they don't show in a process listing.
public struct RemoteCommand: Equatable, Sendable {
    public var tool: String
    public var args: [String]
    public var stdin: String?
    public var directory: String?
}

extension RemoteTarget {
    private var vercelScope: [String] {
        var a: [String] = []
        if let p = project, !p.isEmpty { a += ["--project", p] }
        return a
    }

    private var railwayScope: [String] {
        var a: [String] = []
        if let p = project, !p.isEmpty { a += ["--project", p] }
        if let e = environment, !e.isEmpty { a += ["--environment", e] }
        if let s = serviceName, !s.isEmpty { a += ["--service", s] }
        return a
    }

    /// Commands that set these values. One per item, except Fly, which takes them all at once (staged, so
    /// nothing redeploys until you deploy).
    public func pushCommands(_ values: [(name: String, value: String, secret: Bool)]) -> [RemoteCommand] {
        switch service {
        case .vercel:
            return values.map { v in
                var a = ["env", "add", v.name, "--environment", environment ?? "", "--force", "--yes"]
                if let b = branch, !b.isEmpty { a += ["--git-branch", b] }
                // Sensitive values can't be read back from Vercel; development doesn't allow them.
                a.append(v.secret && environment != "development" ? "--sensitive" : "--no-sensitive")
                return RemoteCommand(tool: service.tool, args: a + vercelScope, stdin: v.value, directory: directory)
            }
        case .github:
            return values.map { v in
                var a = ["secret", "set", v.name, "--repo", repo ?? ""]
                if let e = environment, !e.isEmpty { a += ["--env", e] }
                return RemoteCommand(tool: service.tool, args: a, stdin: v.value, directory: directory)
            }
        case .railway:
            // --skip-deploys: setting a variable on Railway starts a deploy otherwise.
            return values.map { v in
                RemoteCommand(tool: service.tool, args: ["variable", "set", v.name, "--stdin", "--skip-deploys"] + railwayScope,
                              stdin: v.value, directory: directory)
            }
        case .fly:
            let lines = values.map { "\($0.name)=\($0.value)" }.joined(separator: "\n") + "\n"
            return [RemoteCommand(tool: service.tool, args: ["secrets", "import", "--stage", "--app", app ?? ""], stdin: lines, directory: directory)]
        }
    }

    /// A command that lists what's there. Its output can include values (Railway's does); only names are kept.
    public var listCommand: RemoteCommand {
        switch service {
        case .vercel:
            var a = ["env", "ls", "--environment", environment ?? "", "--json"]
            if let b = branch, !b.isEmpty { a += ["--git-branch", b] }
            return RemoteCommand(tool: service.tool, args: a + vercelScope, stdin: nil, directory: directory)
        case .github:
            var a = ["secret", "list", "--repo", repo ?? "", "--json", "name"]
            if let e = environment, !e.isEmpty { a += ["--env", e] }
            return RemoteCommand(tool: service.tool, args: a, stdin: nil, directory: directory)
        case .railway:
            return RemoteCommand(tool: service.tool, args: ["variable", "list", "--json"] + railwayScope, stdin: nil, directory: directory)
        case .fly:
            return RemoteCommand(tool: service.tool, args: ["secrets", "list", "--app", app ?? "", "--json"], stdin: nil, directory: directory)
        }
    }

    /// Variable names from a list command's JSON output, or nil if it can't be read. Values are discarded here.
    public func names(fromListOutput output: String) -> [String]? {
        guard let data = output.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var out: [String] = []
        switch service {
        case .railway:
            // An object of NAME: value.
            guard let obj = json as? [String: Any] else { return nil }
            out = Array(obj.keys)
        case .vercel:
            // Objects with a "key" field, wherever they are in the response.
            func walk(_ x: Any) {
                if let d = x as? [String: Any] {
                    if let k = d["key"] as? String { out.append(k) }
                    d.values.forEach(walk)
                } else if let a = x as? [Any] { a.forEach(walk) }
            }
            walk(json)
        case .github, .fly:
            guard let rows = json as? [[String: Any]] else { return nil }
            out = rows.compactMap { ($0["name"] ?? $0["Name"]) as? String }
        }
        return Array(Set(out)).sorted()
    }
}

/// An environment of a project linked to a remote target. Every item in the environment belongs to it,
/// including items added later.
public struct RemoteLink: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    /// `project/environment`.
    public var scope: String
    public var target: RemoteTarget
    public var created: Date
    /// When each item was last pushed here.
    public var pushed: [String: Date]

    public init(id: String = Grant.newID(), scope: String, target: RemoteTarget, created: Date = Date(), pushed: [String: Date] = [:]) {
        self.id = id
        self.scope = scope
        self.target = target
        self.created = created
        self.pushed = pushed
    }

    public static func isValidScope(_ scope: String) -> Bool {
        let parts = scope.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 2 && parts.allSatisfy(ItemID.isValidPart)
    }

    public func covers(_ item: String) -> Bool { item.hasPrefix(scope + "/") && ItemID(item)?.isShared == false }

    /// Whether this link's state matters for an item: it's the environment's own, or it has been pushed here (a shared
    /// item the environment's record names, say).
    public func tracks(_ item: String) -> Bool { covers(item) || pushed[item] != nil }
}

/// How an item stands against one link.
public enum RemoteState: String, Codable, Sendable {
    case notPushed, current, outOfDate
}

extension RemoteLink {
    /// `valueChangedAt`: when the item's current value was set, if known (from its newest version).
    public func state(of item: String, valueChangedAt: Date?) -> RemoteState {
        guard let at = pushed[item] else { return .notPushed }
        if let changed = valueChangedAt, changed > at { return .outOfDate }
        return .current
    }
}

/// What a status check found for one link. Names only.
public struct RemoteStatus: Codable, Sendable, Identifiable {
    public var link: String
    public var label: String
    public var error: String?
    /// In Latchkey but not there.
    public var missing: [String]
    /// There but not in Latchkey.
    public var extra: [String]
    /// There, but Latchkey's value changed since it was pushed.
    public var outOfDate: [String]
    public var id: String { link }

    public init(link: String, label: String, error: String? = nil, missing: [String] = [], extra: [String] = [], outOfDate: [String] = []) {
        self.link = link
        self.label = label
        self.error = error
        self.missing = missing
        self.extra = extra
        self.outOfDate = outOfDate
    }
}

/// The outcome of pushing one item to one link.
public struct PushResult: Codable, Sendable, Hashable {
    public var link: String
    public var item: String
    public var ok: Bool
    public var error: String?

    public init(link: String, item: String, ok: Bool, error: String? = nil) {
        self.link = link
        self.item = item
        self.ok = ok
        self.error = error
    }
}

// MARK: - running tools

/// Runs a remote command. The app uses `ProcessRunner`; tests use a fake.
public protocol RemoteRunner: Sendable {
    func run(_ command: RemoteCommand, timeout: TimeInterval) -> (status: Int32, stdout: String, stderr: String)
}

/// Runs the real tools as you, with their own sign-ins. Finds them where Homebrew, mise and the usual installers
/// put them, since an app doesn't get your shell's PATH.
public struct ProcessRunner: RemoteRunner {
    public init() {}

    static var searchPath: [String] {
        let home = NSHomeDirectory()
        let fromEnv = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/share/mise/shims",
                "\(home)/.fly/bin", "\(home)/.npm-global/bin", "/usr/bin", "/bin"] + fromEnv
    }

    public static func locate(_ tool: String) -> String? {
        searchPath.map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func run(_ command: RemoteCommand, timeout: TimeInterval) -> (status: Int32, stdout: String, stderr: String) {
        guard let path = Self.locate(command.tool) else {
            return (127, "", "\(command.tool) isn't installed (looked in \(Self.searchPath.prefix(5).joined(separator: ", ")))")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = command.args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.searchPath.joined(separator: ":")
        env["NO_COLOR"] = "1"
        p.environment = env
        if let d = command.directory { p.currentDirectoryURL = URL(fileURLWithPath: (d as NSString).expandingTildeInPath) }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        do { try p.run() } catch { return (126, "", "couldn't start \(command.tool): \(error.localizedDescription)") }
        if let s = command.stdin { input.fileHandleForWriting.write(Data(s.utf8)) }
        try? input.fileHandleForWriting.close()
        // Read both pipes while waiting, so a chatty tool can't fill a pipe and stall.
        nonisolated(unsafe) var out = Data(), err = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { out = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { err = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = DispatchTime.now() + timeout
        while p.isRunning && DispatchTime.now() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); _ = group.wait(timeout: .now() + 2); return (124, "", "\(command.tool) took longer than \(Int(timeout)) seconds") }
        _ = group.wait(timeout: .now() + 2)
        return (p.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}

// MARK: - storage

/// Links, kept as keychain items (no secret in them) so they sync with your items, or in memory for tests.
public protocol RemoteStore: AnyObject, Sendable {
    func all() throws -> [RemoteLink]
    func save(_ link: RemoteLink) throws
    func remove(_ id: String) throws
}

public final class KeychainRemoteStore: RemoteStore, @unchecked Sendable {
    public static let service = "latchkey.remote"
    let items: KeychainStore

    public init(mode: KeychainStore.Mode) { items = KeychainStore(mode: mode) }

    public func all() throws -> [RemoteLink] {
        var q = items.query(nil, service: Self.service)
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw StoreError.keychain("list links", status) }
        let dec = Wire.decoder()
        return (out as? [[String: Any]] ?? []).compactMap { row in
            (row[kSecAttrGeneric as String] as? Data).flatMap { try? dec.decode(RemoteLink.self, from: $0) }
        }.sorted { ($0.scope, $0.target.label) < ($1.scope, $1.target.label) }
    }

    public func save(_ link: RemoteLink) throws {
        let data = try Wire.encoder().encode(link)
        let q = items.query(link.id, service: Self.service)
        let update: [String: Any] = [kSecAttrGeneric as String: data, kSecAttrLabel as String: "Latchkey link: \(link.scope) → \(link.target.label)"]
        var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = q.merging(update) { $1 }
            add[kSecValueData as String] = Data()
            if case .iCloud = items.mode {
                add[kSecAttrSynchronizable as String] = true
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError.keychain("save link", status) }
    }

    public func remove(_ id: String) throws {
        let status = SecItemDelete(items.query(id, service: Self.service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.keychain("delete link", status) }
    }
}

public final class MemoryRemoteStore: RemoteStore, @unchecked Sendable {
    private var links: [String: RemoteLink] = [:]
    private let lock = NSLock()
    public init() {}
    public func all() throws -> [RemoteLink] { lock.withLock { links.values.sorted { $0.id < $1.id } } }
    public func save(_ link: RemoteLink) throws { lock.withLock { links[link.id] = link } }
    public func remove(_ id: String) throws { _ = lock.withLock { links.removeValue(forKey: id) } }
}
