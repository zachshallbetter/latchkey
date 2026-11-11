import Foundation

/// Turns a .env file into import items. Shared by `latchkey import` and the app's Import sheet.
public enum EnvImport {
    public struct Plan: Sendable {
        /// Sorted by id. Later lines win, as when the file is loaded.
        public var items: [ImportItem]
        /// Lines left alone, key → reason ("empty", "already a reference").
        public var ignored: [String: String]
        /// Each imported key → the id of the item that will hold it.
        public var references: [String: String]
    }

    /// `project` and `environment` place every item; both empty makes them shared items named after their keys.
    /// `location` (the file's path) is recorded on each item as a place it's used.
    public static func plan(_ text: String, source: String, location: String? = nil,
                            project: String = "", environment: String = "",
                            only: Set<String>? = nil, defaultKind: ItemKind = .token, kinds: [String: ItemKind] = [:],
                            agentSafe: Set<String> = [], allAgentSafe: Bool = false) -> Plan {
        var items: [String: ImportItem] = [:]
        var ignored: [String: String] = [:]
        for (key, value) in EnvFile.parse(text) {
            if let only, !only.contains(key) { continue }
            items[key] = nil
            ignored[key] = nil
            if value.isEmpty { ignored[key] = "empty"; continue }
            if value.contains(References.scheme) { ignored[key] = "already a reference"; continue }
            let id = ItemID(project: project, environment: project.isEmpty ? "" : environment, name: key).string
            items[key] = ImportItem(name: id, value: value, kind: kinds[key] ?? guessKind(key, value) ?? defaultKind,
                                    agentSafe: allAgentSafe || agentSafe.contains(key),
                                    note: "imported from \(source)", usedIn: location.map { [$0] },
                                    service: Services.guess(key: key, value: value))
        }
        return Plan(items: items.values.sorted { $0.name < $1.name }, ignored: ignored,
                    references: items.mapValues(\.name))
    }

    /// The environment a file's name implies: `.env` and `.env.local` are development, `.env.production` and
    /// `.env.production.local` are production, `.env.prod` is production, and an unknown suffix is used as is.
    public static func environment(forFile name: String) -> String {
        guard name.hasPrefix(".env") else { return "development" }
        let parts = name.dropFirst(4).split(separator: ".").map { $0.lowercased() }.filter { $0 != "local" }
        guard let first = parts.first else { return "development" }
        switch first {
        case "dev", "development": return "development"
        case "prod", "production": return "production"
        case "stage", "staging": return "staging"
        case "preview": return "preview"
        case "test", "testing": return "test"
        default: return ItemID.isValidPart(first) ? first : "development"
        }
    }

    /// The project a file belongs to: the name of the enclosing git repository's folder, or failing that the
    /// file's own folder, lowercased with anything outside letters, digits, `_`, `-` and `.` turned into `-`.
    public static func project(forFile url: URL) -> String {
        var dir = url.deletingLastPathComponent().standardizedFileURL
        let start = dir
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return slug(dir.lastPathComponent) }
            dir = dir.deletingLastPathComponent()
        }
        return slug(start.lastPathComponent)
    }

    static func slug(_ s: String) -> String {
        let mapped = s.lowercased().unicodeScalars.map { c -> Character in
            (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "_" || c == "-" || c == "." ? Character(c) : "-"
        }
        let out = String(String(mapped).prefix(64))
        return ItemID.isValidPart(out) ? out : "project"
    }

    /// Only the obvious cases; anything unclear stays the caller's default.
    static func guessKind(_ key: String, _ value: String) -> ItemKind? {
        if value.contains("-----BEGIN ") { return .key }
        let k = key.uppercased()
        if k.hasSuffix("PASSWORD") || k.hasSuffix("_PASS") || k.hasSuffix("PASSWD") { return .password }
        // A connection string with credentials in it: DATABASE_URL, DATABASE_URL_UNPOOLED, SENTRY_DSN.
        if (k.contains("_URL") || k.hasSuffix("URL") || k.contains("DSN")) && value.contains("://") && value.contains("@") {
            return .password
        }
        return nil
    }
}
