import Foundation
import Security

public enum StoreError: Error, CustomStringConvertible {
    case keychain(String, OSStatus)
    case notFound(String)
    case badName(String)

    public var description: String {
        switch self {
        case .keychain(let what, let status):
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "error"
            return "keychain \(what) failed: \(msg) (\(status))"
        case .notFound(let name): return "no item named \(name)"
        case .badName(let name): return "invalid name \(name) (letters, digits, _ - . only)"
        }
    }
}

/// Where values live. The broker is the only thing that talks to it; the CLI never does.
public protocol SecretStore: AnyObject, Sendable {
    /// One line for `latchkey status`, e.g. "iCloud Keychain storage (sync status not verified)".
    var location: String { get }
    func list() throws -> [SecretInfo]
    /// Values for the names that exist. Missing names are absent from the result.
    func values(_ names: [String]) throws -> [String: String]
    /// Creates or updates. A nil `value` keeps the stored value (and fails if there is none).
    /// Nil metadata keeps what is stored, or the default for a new item. `usedIn` paths are added to the
    /// item's list, never replace it. An empty `service` clears it; so does an empty `fillSites`.
    func save(name: String, value: String?, kind: ItemKind?, agentSafe: Bool?, note: String?, usedIn: [String]?,
              service: String?, fillSites: [String]?) throws
    /// True if something was removed.
    func remove(_ name: String) throws -> Bool
}

extension SecretStore {
    /// Keeps the item's fill sites.
    public func save(name: String, value: String?, kind: ItemKind?, agentSafe: Bool?, note: String?, usedIn: [String]?,
                     service: String?) throws {
        try save(name: name, value: value, kind: kind, agentSafe: agentSafe, note: note, usedIn: usedIn, service: service, fillSites: nil)
    }

    public func save(name: String, value: String?, kind: ItemKind?, agentSafe: Bool?, note: String?) throws {
        try save(name: name, value: value, kind: kind, agentSafe: agentSafe, note: note, usedIn: nil, service: nil)
    }

    public func save(name: String, value: String?, kind: ItemKind?, agentSafe: Bool?, note: String?, usedIn: [String]?) throws {
        try save(name: name, value: value, kind: kind, agentSafe: agentSafe, note: note, usedIn: usedIn, service: nil)
    }

    public func info(_ name: String) throws -> SecretInfo? {
        try list().first { $0.name == name }
    }
}

/// Generic-password items in the keychain, one per secret.
///
/// - `.iCloud`: the data-protection keychain with `kSecAttrSynchronizable`, which is iCloud Keychain, the
///   store behind the Passwords app. Items reach every Mac signed in to the same Apple Account, end-to-end
///   encrypted. Needs a process signed with a team and a `keychain-access-groups` entitlement (the app).
/// - `.thisMac`: the login keychain file. Works for unsigned development builds; does not sync.
///
/// Kind and agent-safe travel with the item (in `kSecAttrGeneric`), so they sync too.
public final class KeychainStore: SecretStore, @unchecked Sendable {
    public enum Mode: Equatable, Sendable {
        case iCloud(accessGroup: String?)
        case thisMac
    }

    public static let service = "latchkey"
    public let mode: Mode
    let service: String
    let synchronizable: Bool

    /// `service` and `synchronizable` exist so a probe can use a fixture service that never reaches iCloud.
    public init(mode: Mode, service: String = KeychainStore.service, synchronizable: Bool = true) {
        self.mode = mode
        self.service = service
        self.synchronizable = synchronizable
    }

    /// iCloud Keychain when this process is entitled to it, otherwise the login keychain.
    public static func automatic(accessGroup: String? = nil) -> KeychainStore {
        // Reads from an unentitled process just say "not found", so only a write tells.
        let probe = KeychainStore(mode: .iCloud(accessGroup: accessGroup))
        var q = probe.query("._probe")
        q[kSecAttrService as String] = service + ".probe"
        q[kSecAttrSynchronizable as String] = false
        var add = q
        add[kSecValueData as String] = Data()
        let status = SecItemAdd(add as CFDictionary, nil)
        SecItemDelete(q as CFDictionary)
        if status == errSecSuccess || status == errSecDuplicateItem { return probe }
        return KeychainStore(mode: .thisMac)
    }

    public var location: String {
        switch mode {
        case .iCloud: return "iCloud Keychain storage (sync status not verified)"
        case .thisMac: return "login keychain on this Mac only (local fallback; sync unavailable)"
        }
    }

    private struct Meta: Codable {
        var kind: ItemKind
        var agentSafe: Bool
        var usedIn: [String]?
        var service: String?
        var fillSites: [String]?
    }

    func query(_ name: String? = nil, service: String? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service ?? self.service,
        ]
        if let name { q[kSecAttrAccount as String] = name }
        if case .iCloud(let group) = mode {
            q[kSecUseDataProtectionKeychain as String] = true
            q[kSecAttrSynchronizable as String] = synchronizable ? kSecAttrSynchronizableAny : false
            if let group { q[kSecAttrAccessGroup as String] = group }
        }
        return q
    }

    public func list() throws -> [SecretInfo] {
        var q = query()
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw StoreError.keychain("list", status) }
        let rows = out as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let name = row[kSecAttrAccount as String] as? String else { return nil }
            let meta = (row[kSecAttrGeneric as String] as? Data).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
            return SecretInfo(name: name,
                              kind: meta?.kind ?? .token,
                              agentSafe: meta?.agentSafe ?? false,
                              note: row[kSecAttrComment as String] as? String ?? "",
                              updatedAt: row[kSecAttrModificationDate as String] as? Date ?? .distantPast,
                              usedIn: meta?.usedIn,
                              service: meta?.service,
                              fillSites: meta?.fillSites)
        }.sorted { $0.name < $1.name }
    }

    public func values(_ names: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in names {
            var q = query(name)
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            q[kSecReturnData as String] = true
            var out: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let data = out as? Data else { throw StoreError.keychain("read \(name)", status) }
            result[name] = String(decoding: data, as: UTF8.self)
        }
        return result
    }

    public func save(name: String, value: String?, kind: ItemKind?, agentSafe: Bool?, note: String?, usedIn: [String]?,
                     service: String?, fillSites: [String]?) throws {
        guard Wire.isValidName(name) else { throw StoreError.badName(name) }
        let existing = try list().first { $0.name == name }
        if existing == nil && value == nil { throw StoreError.notFound(name) }
        let paths = StoreSupport.merge(existing?.usedIn, usedIn)
        let meta = Meta(kind: kind ?? existing?.kind ?? .token, agentSafe: agentSafe ?? existing?.agentSafe ?? false,
                        usedIn: paths.isEmpty ? nil : paths,
                        service: StoreSupport.service(service, existing?.service),
                        fillSites: StoreSupport.fillSites(fillSites, existing?.fillSites))
        var attrs: [String: Any] = [
            kSecAttrGeneric as String: try JSONEncoder().encode(meta),
            kSecAttrComment as String: note ?? existing?.note ?? "",
            kSecAttrLabel as String: "Latchkey: \(name)",
            kSecAttrDescription as String: "Latchkey \(meta.kind.label.lowercased())",
        ]
        if let value { attrs[kSecValueData as String] = Data(value.utf8) }

        if existing != nil {
            let status = SecItemUpdate(query(name) as CFDictionary, attrs as CFDictionary)
            guard status == errSecSuccess else { throw StoreError.keychain("update \(name)", status) }
            return
        }
        var add = query(name).merging(attrs) { $1 }
        if case .iCloud = mode {
            add[kSecAttrSynchronizable as String] = synchronizable
            // Synced items cannot be device-only; this is the strictest class that still syncs and
            // still lets the broker answer while the screen is locked (for scheduled jobs).
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain("add \(name)", status) }
    }

    public func remove(_ name: String) throws -> Bool {
        let status = SecItemDelete(query(name) as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw StoreError.keychain("delete \(name)", status) }
        return true
    }
}

/// For tests and previews.
public final class MemoryStore: SecretStore, @unchecked Sendable {
    private var items: [String: (info: SecretInfo, value: String)] = [:]
    private let lock = NSLock()
    public init() {}
    public var location: String { "memory" }

    public func list() throws -> [SecretInfo] {
        lock.withLock { items.values.map(\.info).sorted { $0.name < $1.name } }
    }

    public func values(_ names: [String]) throws -> [String: String] {
        lock.withLock {
            var out: [String: String] = [:]
            for n in names { if let i = items[n] { out[n] = i.value } }
            return out
        }
    }

    public func save(name: String, value: String?, kind: ItemKind?, agentSafe: Bool?, note: String?, usedIn: [String]?,
                     service: String?, fillSites: [String]?) throws {
        guard Wire.isValidName(name) else { throw StoreError.badName(name) }
        try lock.withLock {
            let old = items[name]
            guard let v = value ?? old?.value else { throw StoreError.notFound(name) }
            let paths = StoreSupport.merge(old?.info.usedIn, usedIn)
            let info = SecretInfo(name: name, kind: kind ?? old?.info.kind ?? .token,
                                  agentSafe: agentSafe ?? old?.info.agentSafe ?? false,
                                  note: note ?? old?.info.note ?? "", updatedAt: Date(),
                                  usedIn: paths.isEmpty ? nil : paths,
                                  service: StoreSupport.service(service, old?.info.service),
                                  fillSites: StoreSupport.fillSites(fillSites, old?.info.fillSites))
            items[name] = (info, v)
        }
    }

    public func remove(_ name: String) throws -> Bool {
        lock.withLock { items.removeValue(forKey: name) != nil }
    }
}

enum StoreSupport {
    /// Nil keeps the stored sites; an empty list clears them (back to the default).
    static func fillSites(_ new: [String]?, _ old: [String]?) -> [String]? {
        guard let new else { return old }
        return new.isEmpty ? nil : new
    }

    /// Nil keeps the stored service; an empty string clears it.
    static func service(_ new: String?, _ old: String?) -> String? {
        guard let new else { return old }
        let t = new.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// Existing paths first, new ones after, no repeats.
    static func merge(_ old: [String]?, _ new: [String]?) -> [String] {
        var seen = Set<String>()
        return ((old ?? []) + (new ?? [])).filter { seen.insert($0).inserted }
    }
}
