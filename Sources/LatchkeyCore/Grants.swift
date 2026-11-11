import Foundation
import Security

/// Standing permission to read some items from one folder (and the folders inside it) until a set time,
/// without asking. Made from an approval ("Allow here for 1 hour") or ahead of time, e.g. before stepping
/// away while an agent works. Kept on this Mac only: folders are per-machine.
public struct Grant: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var names: [String]
    /// Absolute path. Covers this folder and everything below it.
    public var folder: String
    public var expires: Date
    public var created: Date
    /// Who asked for it, as the approval described them ("zsh › claude", "the Latchkey app").
    public var createdBy: String
    /// The git repository (its common `.git` directory) the folder belongs to, if any. Commands run from any of
    /// that repository's worktrees are covered too, wherever the worktree lives.
    public var repo: String?
    /// Only for programs started under this process (an agent), and only while it runs.
    public var session: GrantSession?
    /// Only for these commands, started by Latchkey's own `latchkey run`. An entry covers a command that is the
    /// same words or starts with them: "npm test" covers "npm test -- --watch=false".
    public var commands: [[String]]?
    /// How many more requests it covers; nil for no limit.
    public var usesLeft: Int?

    public init(id: String = Grant.newID(), names: [String], folder: String, expires: Date,
                created: Date = Date(), createdBy: String, repo: String? = nil, session: GrantSession? = nil,
                commands: [[String]]? = nil, usesLeft: Int? = nil) {
        self.id = id
        self.names = names.sorted()
        self.folder = Grant.normalize(folder)
        self.expires = expires
        self.created = created
        self.createdBy = createdBy
        self.repo = repo
        self.session = session
        self.commands = commands
        self.usesLeft = usesLeft
    }

    /// Whether it covers `name` for this caller now: the folder and time, then any session, command and use limits.
    /// `command` is what the caller is about to run, when known.
    public func allows(_ name: String, cwd: String, ancestors: [ProcessStamp], command: [String]?, now: Date = Date()) -> Bool {
        guard covers(name, cwd: cwd, now: now) else { return false }
        if let usesLeft, usesLeft <= 0 { return false }
        if let session {
            guard session.process.isRunning, ancestors.contains(session.process) else { return false }
        }
        if let commands {
            guard let command, commands.contains(where: { command.starts(with: $0) }) else { return false }
        }
        return true
    }

    /// The limits beyond folder and time, as words: "only npm test, until claude quits, 1 use left".
    public var limits: String {
        var parts: [String] = []
        if let commands { parts.append("only " + commands.map { $0.joined(separator: " ") }.joined(separator: " or ")) }
        if let session { parts.append("until \(session.name) quits") }
        if let usesLeft { parts.append("\(usesLeft) use\(usesLeft == 1 ? "" : "s") left") }
        return parts.joined(separator: ", ")
    }

    public static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
    }

    static func normalize(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        p = (p as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// An entry is an item id, or a pattern for a whole project (`site/*`) or one environment of it
    /// (`site/production/*`), which also covers items added to it later.
    public static func isPattern(_ entry: String) -> Bool {
        guard entry.hasSuffix("/*") else { return false }
        let parts = entry.dropLast(2).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return (parts.count == 1 || parts.count == 2) && parts.allSatisfy(ItemID.isValidPart)
    }

    public static func entry(_ entry: String, matches id: String) -> Bool {
        isPattern(entry) ? id.hasPrefix(String(entry.dropLast())) : entry == id
    }

    public func covers(_ name: String, cwd: String, now: Date = Date()) -> Bool {
        guard expires > now, names.contains(where: { Grant.entry($0, matches: name) }), !cwd.isEmpty else { return false }
        let c = Grant.normalize(cwd)
        if c == folder || c.hasPrefix(folder == "/" ? "/" : folder + "/") { return true }
        if let repo, Repo.commonDir(for: c) == repo { return true }
        return false
    }
}

/// The process a session grant lasts as long as.
public struct GrantSession: Codable, Hashable, Sendable {
    public var process: ProcessStamp
    /// Its name, for showing: "claude".
    public var name: String

    public init(process: ProcessStamp, name: String) {
        self.process = process
        self.name = name
    }
}

/// Where grants are kept between launches.
public protocol GrantBacking: Sendable {
    func load() -> Data?
    func save(_ data: Data)
}

/// Grants in one keychain item that only Latchkey can read or change, on this Mac only (not synced). A file would
/// let any program running as you write itself a grant.
public final class KeychainGrantBacking: GrantBacking, @unchecked Sendable {
    public static let service = "latchkey.grants"
    static let account = "grants"
    let items: KeychainStore

    public init(mode: KeychainStore.Mode) { items = KeychainStore(mode: mode) }

    public func load() -> Data? {
        var q = items.query(Self.account, service: Self.service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    public func save(_ data: Data) {
        let q = items.query(Self.account, service: Self.service)
        if SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary) != errSecItemNotFound { return }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Latchkey grants"
        if case .iCloud = items.mode { add[kSecAttrSynchronizable as String] = false }
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Grants kept for the life of the object, for tests and the windowless broker.
public final class MemoryGrantBacking: GrantBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    public init() {}
    public func load() -> Data? { lock.withLock { data } }
    public func save(_ data: Data) { lock.withLock { self.data = data } }
}

/// The grants in effect. Expired grants are dropped on every read.
public final class GrantStore: @unchecked Sendable {
    public static let longest: TimeInterval = 7 * 24 * 3600
    private let backing: GrantBacking
    private var cache: [Grant] = []
    private let lock = NSLock()

    public init(backing: GrantBacking = MemoryGrantBacking()) {
        self.backing = backing
        if let data = backing.load() {
            cache = (try? Wire.decoder().decode([Grant].self, from: data)) ?? []
        }
    }

    public func all(now: Date = Date()) -> [Grant] {
        lock.withLock {
            let live = cache.filter { g in
                g.expires > now && (g.usesLeft ?? 1) > 0 && (g.session.map { $0.process.isRunning } ?? true)
            }
            if live.count != cache.count { cache = live; persist() }
            return live.sorted { $0.expires < $1.expires }
        }
    }

    /// The grant that lets this caller read `name` right now, if any.
    public func covering(_ name: String, cwd: String, ancestors: [ProcessStamp] = [], command: [String]? = nil,
                         now: Date = Date()) -> Grant? {
        all(now: now).first { $0.allows(name, cwd: cwd, ancestors: ancestors, command: command, now: now) }
    }

    /// Counts one use against each of these grants; a grant with no uses left ends.
    public func used(_ ids: [String]) {
        lock.withLock {
            var changed = false
            for i in cache.indices where ids.contains(cache[i].id) {
                if let n = cache[i].usesLeft { cache[i].usesLeft = n - 1; changed = true }
            }
            if changed { cache.removeAll { ($0.usesLeft ?? 1) <= 0 }; persist() }
        }
    }

    @discardableResult
    public func add(names: [String], folder: String, duration: TimeInterval, createdBy: String, now: Date = Date(),
                    session: GrantSession? = nil, commands: [[String]]? = nil, uses: Int? = nil) -> Grant {
        let g = Grant(names: names, folder: folder, expires: now.addingTimeInterval(min(duration, Self.longest)),
                      created: now, createdBy: createdBy, repo: Repo.commonDir(for: folder), session: session,
                      commands: commands, usesLeft: uses)
        lock.withLock {
            cache.append(g)
            persist()
        }
        return g
    }

    /// Removes the grant with this id, or every grant for "all". Returns how many were removed.
    @discardableResult
    public func revoke(_ id: String) -> Int {
        lock.withLock {
            let before = cache.count
            cache.removeAll { id == "all" || $0.id == id }
            persist()
            return before - cache.count
        }
    }

    private func persist() {
        guard let data = try? Wire.encoder().encode(cache) else { return }
        backing.save(data)
    }

    /// "30m", "2h", "1d", "90s". Nil for anything else.
    public static func parseDuration(_ s: String) -> TimeInterval? {
        guard let unit = s.last, let n = Double(s.dropLast()), n > 0 else { return nil }
        switch unit {
        case "s": return n
        case "m": return n * 60
        case "h": return n * 3600
        case "d": return n * 86400
        default: return nil
        }
    }

    /// "1 hour", "45 minutes", "2 days".
    public static func describe(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = t >= 86400 ? [.day, .hour] : (t >= 3600 ? [.hour, .minute] : [.minute])
        f.unitsStyle = .full
        f.maximumUnitCount = 2
        return f.string(from: t) ?? "\(Int(t)) seconds"
    }
}
