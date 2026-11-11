import Foundation

/// Owns the original URLs carrying App Sandbox extensions. File permission is separate from permission to
/// read a secret: retaining a bookmark never creates a broker grant. Call from one actor (the app's main actor).
public final class SecurityScopedAccess {
    public struct Record: Codable, Identifiable, Equatable {
        public let id: UUID
        public var path: String
        public let isDirectory: Bool
        fileprivate var bookmark: Data
    }

    public enum AccessError: Error, LocalizedError {
        case unavailable
        public var errorDescription: String? { "File access could not be restored. Choose the file or folder again." }
    }

    public private(set) var records: [Record]
    private var active: [UUID: URL] = [:]
    private let driver: ScopedBookmarkDriver
    private let persist: (Data) throws -> Void

    public convenience init(saved: Data?, persist: @escaping (Data) throws -> Void) throws {
        try self.init(saved: saved, driver: FoundationBookmarkDriver(), persist: persist)
    }

    init(saved: Data?, driver: ScopedBookmarkDriver, persist: @escaping (Data) throws -> Void) throws {
        records = try saved.map { try JSONDecoder().decode([Record].self, from: $0) } ?? []
        self.driver = driver
        self.persist = persist
    }

    deinit { for url in active.values { driver.stop(url) } }

    public func isActive(_ id: UUID) -> Bool { active[id] != nil }

    /// Unavailable volumes remain remembered. Calling again does not acquire duplicate sandbox extensions.
    /// Returns IDs requiring attention, without logging bookmark data or file contents.
    @discardableResult
    public func restore() -> [UUID] {
        var failed: [UUID] = []
        for i in records.indices where active[records[i].id] == nil {
            do {
                let resolved = try driver.resolve(records[i].bookmark)
                guard driver.start(resolved.url) else { failed.append(records[i].id); continue }
                active[records[i].id] = resolved.url
                if resolved.stale {
                    var renewed = records
                    renewed[i].bookmark = try driver.create(resolved.url)
                    renewed[i].path = resolved.url.standardizedFileURL.path
                    try save(renewed)
                    records = renewed
                }
            } catch { failed.append(records[i].id) }
        }
        return failed
    }

    /// Only pass URLs explicitly selected through an Open panel or provided by a user drag/drop operation.
    public func remember(_ url: URL, isDirectory: Bool) throws {
        let data = try driver.create(url)
        let resolved = try driver.resolve(data)
        guard driver.start(resolved.url) else { throw AccessError.unavailable }
        let path = resolved.url.standardizedFileURL.path
        let existing = records.first { $0.path == path }
        let record = Record(id: existing?.id ?? UUID(), path: path, isDirectory: isDirectory, bookmark: data)
        let updated = records.filter { $0.id != record.id } + [record]
        do { try save(updated) }
        catch { driver.stop(resolved.url); throw error }
        let previous = active.updateValue(resolved.url, forKey: record.id)
        records = updated
        if let previous { driver.stop(previous) }
    }

    /// Releasing the original scoped URL matters: a standardized URL may not carry its sandbox extension.
    public func forget(_ id: UUID) throws {
        let updated = records.filter { $0.id != id }
        try save(updated)
        records = updated
        if let original = active.removeValue(forKey: id) { driver.stop(original) }
    }

    private func save(_ records: [Record]) throws {
        try persist(JSONEncoder().encode(records))
    }
}

protocol ScopedBookmarkDriver {
    func create(_ url: URL) throws -> Data
    func resolve(_ data: Data) throws -> (url: URL, stale: Bool)
    func start(_ url: URL) -> Bool
    func stop(_ url: URL)
}

private struct FoundationBookmarkDriver: ScopedBookmarkDriver {
    func create(_ url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    func resolve(_ data: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }
    func start(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stop(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}
