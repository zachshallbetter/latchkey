import Foundation

/// Turns a .env file into import items. Shared by `latchkey import` and the app's Import sheet.
public enum EnvImport {
    public struct Plan: Sendable {
        /// Sorted by name. Later lines win, as when the file is loaded.
        public var items: [ImportItem]
        /// Lines left alone, name → reason ("empty", "already a reference").
        public var ignored: [String: String]
    }

    public static func plan(_ text: String, source: String, only: Set<String>? = nil,
                            defaultKind: ItemKind = .token, kinds: [String: ItemKind] = [:],
                            agentSafe: Set<String> = [], allAgentSafe: Bool = false) -> Plan {
        var items: [String: ImportItem] = [:]
        var ignored: [String: String] = [:]
        for (key, value) in EnvFile.parse(text) {
            if let only, !only.contains(key) { continue }
            items[key] = nil
            ignored[key] = nil
            if value.isEmpty { ignored[key] = "empty"; continue }
            if value.contains(References.scheme) { ignored[key] = "already a reference"; continue }
            items[key] = ImportItem(name: key, value: value, kind: kinds[key] ?? guessKind(key, value) ?? defaultKind,
                                    agentSafe: allAgentSafe || agentSafe.contains(key),
                                    note: "imported from \(source)")
        }
        return Plan(items: items.values.sorted { $0.name < $1.name }, ignored: ignored)
    }

    /// Only the obvious cases; anything unclear stays the caller's default.
    static func guessKind(_ key: String, _ value: String) -> ItemKind? {
        if value.contains("-----BEGIN ") { return .key }
        let k = key.uppercased()
        if k.hasSuffix("_PASSWORD") || k.hasSuffix("_PASS") || k == "PASSWORD" { return .password }
        if (k.hasSuffix("_URL") || k.hasSuffix("_DSN")) && value.contains("://") && value.contains("@") { return .password }
        return nil
    }
}
