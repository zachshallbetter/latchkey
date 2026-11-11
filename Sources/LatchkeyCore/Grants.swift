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

    public init(id: String = Grant.newID(), names: [String], folder: String, expires: Date,
                created: Date = Date(), createdBy: String, repo: String? = nil) {
        self.id = id
        self.names = names.sorted()
        self.folder = Grant.normalize(folder)
        self.expires = expires
        self.created = created
        self.createdBy = createdBy
        self.repo = repo
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
            let live = cache.filter { $0.expires > now }
            if live.count != cache.count { cache = live; persist() }
            return live.sorted { $0.expires < $1.expires }
        }
    }

    /// The grant that lets `cwd` read `name` right now, if any.
    public func covering(_ name: String, cwd: String, now: Date = Date()) -> Grant? {
        all(now: now).first { $0.covers(name, cwd: cwd, now: now) }
    }

    @discardableResult
    public func add(names: [String], folder: String, duration: TimeInterval, createdBy: String, now: Date = Date()) -> Grant {
        let g = Grant(names: names, folder: folder, expires: now.addingTimeInterval(min(duration, Self.longest)),
                      created: now, createdBy: createdBy, repo: Repo.commonDir(for: folder))
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
