import Foundation

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
