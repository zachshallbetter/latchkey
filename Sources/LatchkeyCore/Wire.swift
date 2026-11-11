import Foundation

/// What an item is. The kind decides whether output is masked and how the item is best delivered.
public enum ItemKind: String, Codable, CaseIterable, Sendable {
    case token      // API token or key: one line, masked
    case password   // password or connection string: one line, masked
    case key        // key material: SSH, GPG, .p8, .pem. Multi-line, masked
    case value      // not secret: IP address, host name, account id. Not masked

    public var isSecret: Bool { self != .value }

    public var label: String {
        switch self {
        case .token: return "Token"
        case .password: return "Password"
        case .key: return "Key file"
        case .value: return "Plain value"
        }
    }
}

/// What the app knows about one item. Never carries the value.
public struct SecretInfo: Codable, Identifiable, Hashable, Sendable {
    public var name: String
    public var kind: ItemKind
    public var agentSafe: Bool
    public var note: String
    public var updatedAt: Date
    public var id: String { name }

    public init(name: String, kind: ItemKind = .token, agentSafe: Bool, note: String, updatedAt: Date) {
        self.name = name
        self.kind = kind
        self.agentSafe = agentSafe
        self.note = note
        self.updatedAt = updatedAt
    }
}

/// One item in an `import` request.
public struct ImportItem: Codable, Sendable, Hashable {
    public var name: String
    public var value: String
    public var kind: ItemKind?
    public var agentSafe: Bool?
    public var note: String?

    public init(name: String, value: String, kind: ItemKind? = nil, agentSafe: Bool? = nil, note: String? = nil) {
        self.name = name
        self.value = value
        self.kind = kind
        self.agentSafe = agentSafe
        self.note = note
    }
}

/// One line of JSON from the CLI to the broker.
public struct Request: Codable, Sendable {
    public var op: String            // status | list | get | set | rm | import
    public var names: [String]?
    public var value: String?
    public var kind: ItemKind?
    public var agentSafe: Bool?
    public var note: String?
    public var cwd: String?
    public var command: String?      // what `run` is about to start, for the log
    public var items: [ImportItem]?  // import
    public var replace: Bool?        // import: overwrite items that already exist
    public var source: String?       // import: the file the items came from, for the approval and the log

    public init(op: String, names: [String]? = nil, value: String? = nil, kind: ItemKind? = nil,
                agentSafe: Bool? = nil, note: String? = nil, cwd: String? = nil, command: String? = nil,
                items: [ImportItem]? = nil, replace: Bool? = nil, source: String? = nil) {
        self.op = op
        self.names = names
        self.value = value
        self.kind = kind
        self.agentSafe = agentSafe
        self.note = note
        self.cwd = cwd
        self.command = command
        self.items = items
        self.replace = replace
        self.source = source
    }
}

/// One line of JSON back.
public struct Response: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var secrets: [SecretInfo]?
    public var values: [String: String]?
    /// Names among `values` whose output should be masked.
    public var masked: [String]?
    public var denied: [String]?
    public var missing: [String]?
    public var info: [String: String]?
    /// import: what was created, overwritten, and left alone because it already existed.
    public var added: [String]?
    public var replaced: [String]?
    public var skipped: [String]?

    public init(ok: Bool, error: String? = nil, secrets: [SecretInfo]? = nil, values: [String: String]? = nil,
                masked: [String]? = nil, denied: [String]? = nil, missing: [String]? = nil,
                info: [String: String]? = nil, added: [String]? = nil, replaced: [String]? = nil,
                skipped: [String]? = nil) {
        self.ok = ok
        self.error = error
        self.secrets = secrets
        self.values = values
        self.masked = masked
        self.denied = denied
        self.missing = missing
        self.info = info
        self.added = added
        self.replaced = replaced
        self.skipped = skipped
    }
}

public enum Wire {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// A secret's name: what goes after `latchkey://` and in the keychain account field.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 128 else { return false }
        return name.unicodeScalars.allSatisfy { c in
            (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "_" || c == "-" || c == "."
        }
    }
}

public enum Paths {
    public static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Latchkey", isDirectory: true)
    }
    public static var socket: String { supportDir.appendingPathComponent("broker.sock").path }
    public static var accessLog: URL { supportDir.appendingPathComponent("access.jsonl") }

    public static func ensureSupportDir() throws {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}
