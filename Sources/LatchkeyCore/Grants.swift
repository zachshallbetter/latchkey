import Foundation

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

    public init(id: String = Grant.newID(), names: [String], folder: String, expires: Date,
                created: Date = Date(), createdBy: String) {
        self.id = id
        self.names = names.sorted()
        self.folder = Grant.normalize(folder)
        self.expires = expires
        self.created = created
        self.createdBy = createdBy
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

    public func covers(_ name: String, cwd: String, now: Date = Date()) -> Bool {
        guard expires > now, names.contains(name), !cwd.isEmpty else { return false }
        let c = Grant.normalize(cwd)
        return c == folder || c.hasPrefix(folder == "/" ? "/" : folder + "/")
    }
}

/// Grants on disk (0600 JSON), or in memory for tests. Expired grants are dropped on every read.
public final class GrantStore: @unchecked Sendable {
    public static let longest: TimeInterval = 7 * 24 * 3600
    private let url: URL?
    private var cache: [Grant] = []
    private let lock = NSLock()

    public init(url: URL? = Paths.grants) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url) {
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
                      created: now, createdBy: createdBy)
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
        guard let url else { return }
        try? Paths.ensureSupportDir()
        guard let data = try? Wire.encoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
