import Foundation
import Security

/// Moves items from one store to another: the login keychain an unsigned build used, into iCloud Keychain once
/// the app is signed. An item is removed from the old store only after the new store has it. Items whose names
/// already exist in the new store are left where they are, so nothing is overwritten.
public enum StoreMigration {
    public struct Result: Sendable, Equatable {
        public var moved: [String] = []
        public var skipped: [String] = []
        public var failed: [String: String] = [:]
    }

    public static func move(from old: SecretStore, to new: SecretStore) throws -> Result {
        var result = Result()
        let existing = Set(try new.list().map(\.name))
        for info in try old.list() {
            if existing.contains(info.name) { result.skipped.append(info.name); continue }
            do {
                guard let value = try old.values([info.name])[info.name] else {
                    result.failed[info.name] = "no value"
                    continue
                }
                try new.save(name: info.name, value: value, kind: info.kind, agentSafe: info.agentSafe, note: info.note,
                             usedIn: info.usedIn, service: info.service)
                guard try new.values([info.name])[info.name] == value else {
                    result.failed[info.name] = "the copy didn't read back"
                    continue
                }
                _ = try old.remove(info.name)
                result.moved.append(info.name)
            } catch {
                result.failed[info.name] = "\(error)"
            }
        }
        return result
    }
}

extension StoreMigration {
    /// Moves every Latchkey keychain item (items, versions and remote links) from an earlier access group into
    /// `store`'s group. Each item is moved in place by changing only its group, so values, dates and sync stay as
    /// they were and no value is read. An item whose ID already exists in the new group stays in the old one and is
    /// listed as skipped. Does nothing outside iCloud Keychain or when the groups are the same.
    public static func adopt(from oldGroup: String, into store: KeychainStore) -> Result {
        guard case .iCloud(let group?) = store.mode, group != oldGroup else { return Result() }
        let old = KeychainStore(mode: .iCloud(accessGroup: oldGroup))
        var result = Result()
        for service in [KeychainStore.service, KeychainVersionStore.service, KeychainRemoteStore.service] {
            var q = old.query(service: service)
            q[kSecMatchLimit as String] = kSecMatchLimitAll
            q[kSecReturnAttributes as String] = true
            var out: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess else {
                result.failed[service] = StoreError.keychain("list", status).description
                continue
            }
            for row in out as? [[String: Any]] ?? [] {
                guard let account = row[kSecAttrAccount as String] as? String else { continue }
                let label = service == KeychainStore.service ? account : "\(service) \(account)"
                var one = old.query(account, service: service)
                if let sync = row[kSecAttrSynchronizable as String] { one[kSecAttrSynchronizable as String] = sync }
                let moved = SecItemUpdate(one as CFDictionary, [kSecAttrAccessGroup as String: group] as CFDictionary)
                switch moved {
                case errSecSuccess: result.moved.append(label)
                case errSecDuplicateItem: result.skipped.append(label)
                default: result.failed[label] = StoreError.keychain("move", moved).description
                }
            }
        }
        return result
    }
}
