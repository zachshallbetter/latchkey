import Foundation
import Security

/// An earlier value of an item, kept when the value was replaced or the item deleted. The value itself lives in
/// the store, behind the same approval as any read; this record never carries it.
public struct Version: Codable, Identifiable, Hashable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case changed      // replaced by a new value
        case deleted      // the item was deleted
        case restored     // replaced by restoring an older version
    }

    /// `<item id>#<milliseconds since 1970>`.
    public var id: String
    /// The item it belongs to. Updated when the item moves.
    public var item: String
    public var savedAt: Date
    public var reason: Reason
    /// Who replaced or deleted it, as the approval described them.
    public var by: String
    public var kind: ItemKind
    public var agentSafe: Bool
    public var note: String
    public var service: String?
    public var usedIn: [String]?

    public init(id: String, item: String, savedAt: Date, reason: Reason, by: String, kind: ItemKind, agentSafe: Bool,
                note: String, service: String?, usedIn: [String]?) {
        self.id = id
        self.item = item
        self.savedAt = savedAt
        self.reason = reason
        self.by = by
        self.kind = kind
        self.agentSafe = agentSafe
        self.note = note
        self.service = service
        self.usedIn = usedIn
    }

    static func makeID(item: String, at date: Date) -> String {
        "\(item)#\(Int64((date.timeIntervalSince1970 * 1000).rounded()))"
    }
}

/// Where versions live.
public protocol VersionStore: AnyObject, Sendable {
    /// Newest first. Every item's versions when `item` is nil.
    func list(item: String?) throws -> [Version]
    func value(_ id: String) throws -> String?
    func add(_ version: Version, value: String) throws
    func remove(_ id: String) throws
}

extension VersionStore {
    /// Records `value` as the version of `info` being replaced or deleted now.
    @discardableResult
    public func record(_ info: SecretInfo, value: String, reason: Version.Reason, by: String, at date: Date = Date()) throws -> Version {
        var at = date
        // Two changes in the same millisecond get distinct ids.
        while try list(item: info.name).contains(where: { $0.id == Version.makeID(item: info.name, at: at) }) {
            at = at.addingTimeInterval(0.001)
        }
        let v = Version(id: Version.makeID(item: info.name, at: at), item: info.name, savedAt: at, reason: reason, by: by,
                        kind: info.kind, agentSafe: info.agentSafe, note: info.note, service: info.service, usedIn: info.usedIn)
        try add(v, value: value)
        return v
    }

    /// Re-files an item's versions under its new id after a move.
    public func rename(from old: String, to new: String) throws {
        for v in try list(item: old) {
            guard let value = try value(v.id) else { continue }
            var moved = v
            moved.item = new
            moved.id = Version.makeID(item: new, at: v.savedAt)
            try add(moved, value: value)
            try remove(v.id)
        }
    }

    /// Keeps the newest `keep` versions of each item, and forgets every version of an item that has been deleted
    /// for longer than `deletedFor`. `existing` is the set of items that exist now.
    public func prune(existing: Set<String>, keep: Int = Versions.keep, deletedFor: TimeInterval = Versions.deletedFor,
               now: Date = Date()) throws {
        let byItem = Dictionary(grouping: try list(item: nil), by: \.item)
        for (item, versions) in byItem {
            let newest = versions.sorted { $0.savedAt > $1.savedAt }
            if !existing.contains(item), let last = newest.first, now.timeIntervalSince(last.savedAt) > deletedFor {
                for v in newest { try remove(v.id) }
                continue
            }
            for v in newest.dropFirst(keep) { try remove(v.id) }
        }
    }

    /// The most recent deletion of each item that doesn't exist now, newest first.
    public func deleted(existing: Set<String>) throws -> [Version] {
        let latest = Dictionary(grouping: try list(item: nil).filter { !existing.contains($0.item) }, by: \.item)
            .compactMap { $0.value.max { $0.savedAt < $1.savedAt } }
        return latest.filter { $0.reason == .deleted }.sorted { $0.savedAt > $1.savedAt }
    }
}

public enum Versions {
    /// Versions kept per item.
    public static let keep = 10
    /// How long a deleted item can be restored.
    public static let deletedFor: TimeInterval = 30 * 86400
}

/// Versions as keychain items under their own service, in the same keychain and access group as the items, so
/// they sync (or stay on this Mac) the same way.
public final class KeychainVersionStore: VersionStore, @unchecked Sendable {
    public static let service = "latchkey.history"
    let items: KeychainStore

    public init(mode: KeychainStore.Mode) {
        items = KeychainStore(mode: mode)
    }

    func query(_ id: String? = nil) -> [String: Any] { items.query(id, service: Self.service) }

    public func list(item: String?) throws -> [Version] {
        var q = query()
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw StoreError.keychain("list versions", status) }
        let dec = Wire.decoder()
        return (out as? [[String: Any]] ?? []).compactMap { row in
            guard let data = row[kSecAttrGeneric as String] as? Data, let v = try? dec.decode(Version.self, from: data) else { return nil }
            return v
        }
        .filter { item == nil || $0.item == item }
        .sorted { $0.savedAt > $1.savedAt }
    }

    public func value(_ id: String) throws -> String? {
        var q = query(id)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw StoreError.keychain("read version", status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func add(_ version: Version, value: String) throws {
        var add = query(version.id)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrGeneric as String] = try Wire.encoder().encode(version)
        add[kSecAttrLabel as String] = "Latchkey history: \(version.item)"
        if case .iCloud = items.mode {
            add[kSecAttrSynchronizable as String] = true
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain("save version", status) }
    }

    public func remove(_ id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.keychain("delete version", status) }
    }
}

/// For tests.
public final class MemoryVersionStore: VersionStore, @unchecked Sendable {
    private var rows: [String: (Version, String)] = [:]
    private let lock = NSLock()
    public init() {}

    public func list(item: String?) throws -> [Version] {
        lock.withLock { rows.values.map(\.0).filter { item == nil || $0.item == item }.sorted { $0.savedAt > $1.savedAt } }
    }
    public func value(_ id: String) throws -> String? { lock.withLock { rows[id]?.1 } }
    public func add(_ version: Version, value: String) throws { lock.withLock { rows[version.id] = (version, value) } }
    public func remove(_ id: String) throws { _ = lock.withLock { rows.removeValue(forKey: id) } }
}
