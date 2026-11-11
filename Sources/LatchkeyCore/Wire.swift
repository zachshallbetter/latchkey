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

/// An item's id. `NAME` is a shared item; `project/environment/NAME` belongs to one environment of a project.
/// The id is the only place project and environment are stored, so grouping can never disagree with the id.
public struct ItemID: Hashable, Sendable, Comparable {
    public var project: String
    public var environment: String
    public var name: String

    public init(project: String = "", environment: String = "", name: String) {
        self.project = project
        self.environment = environment
        self.name = name
    }

    /// Nil unless `id` is `NAME` or `project/environment/NAME` with every part valid.
    public init?(_ id: String) {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1: self.init(name: parts[0])
        case 3: self.init(project: parts[0], environment: parts[1], name: parts[2])
        default: return nil
        }
        guard isValid else { return nil }
    }

    public var isShared: Bool { project.isEmpty }
    public var string: String { isShared ? name : "\(project)/\(environment)/\(name)" }

    var isValid: Bool {
        guard ItemID.isValidPart(name) else { return false }
        if isShared { return environment.isEmpty }
        return ItemID.isValidPart(project) && ItemID.isValidPart(environment)
    }

    /// Letters, digits, `_`, `-` and `.`, at most 64 bytes.
    public static func isValidPart(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 64 else { return false }
        return s.unicodeScalars.allSatisfy { c in
            (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "_" || c == "-" || c == "."
        }
    }

    /// Projects first by name, then environments in their usual order, then names; shared items last.
    public static func < (a: ItemID, b: ItemID) -> Bool {
        if a.isShared != b.isShared { return !a.isShared }
        if a.project != b.project { return a.project.localizedStandardCompare(b.project) == .orderedAscending }
        if a.environment != b.environment { return Environments.order(a.environment, b.environment) }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// The environments Latchkey knows by name. Others are allowed and sort after these.
public enum Environments {
    public static let known = ["development", "preview", "staging", "production", "test"]

    /// `production`, `prod`, or a service's production (`vercel.production`).
    public static func isProduction(_ environment: String) -> Bool {
        let e = environment.lowercased()
        return e == "production" || e == "prod" || e.hasSuffix(".production") || e.hasSuffix(".prod")
    }

    public static func order(_ a: String, _ b: String) -> Bool {
        let ia = known.firstIndex(of: a) ?? known.count, ib = known.firstIndex(of: b) ?? known.count
        return ia != ib ? ia < ib : a < b
    }
}

/// What the app knows about one item. Never carries the value.
public struct SecretInfo: Codable, Identifiable, Hashable, Sendable {
    /// The item id: `NAME` or `project/environment/NAME`.
    public var name: String
    public var kind: ItemKind
    public var agentSafe: Bool
    public var note: String
    public var updatedAt: Date
    /// Files that reference this item, recorded when it was imported from them or moved.
    public var usedIn: [String]?
    /// The service that issued it ("Stripe", "Neon"), set by hand or guessed on import.
    public var service: String?
    public var id: String { name }

    public init(name: String, kind: ItemKind = .token, agentSafe: Bool, note: String, updatedAt: Date,
                usedIn: [String]? = nil, service: String? = nil) {
        self.name = name
        self.kind = kind
        self.agentSafe = agentSafe
        self.note = note
        self.updatedAt = updatedAt
        self.usedIn = usedIn
        self.service = service
    }

    public var ref: ItemID { ItemID(name) ?? ItemID(name: name) }
}

/// One item in an `import` request.
public struct ImportItem: Codable, Sendable, Hashable {
    public var name: String
    public var value: String
    public var kind: ItemKind?
    public var agentSafe: Bool?
    public var note: String?
    public var usedIn: [String]?
    public var service: String?

    public init(name: String, value: String, kind: ItemKind? = nil, agentSafe: Bool? = nil, note: String? = nil,
                usedIn: [String]? = nil, service: String? = nil) {
        self.name = name
        self.value = value
        self.kind = kind
        self.agentSafe = agentSafe
        self.note = note
        self.usedIn = usedIn
        self.service = service
    }
}

/// One line of JSON from the CLI to the broker.
public struct Request: Codable, Sendable {
    public var op: String            // status | list | check | get | set | rm | import | grants | grant | revoke | move | update
                                     // | history | deleted | version | restore | forget
                                     // | links | link | unlink | remote-status | push
    public var names: [String]?
    public var value: String?
    public var kind: ItemKind?
    public var agentSafe: Bool?
    public var note: String?
    public var items: [ImportItem]?  // import
    public var replace: Bool?        // import: overwrite items that already exist
    public var source: String?       // import: the file the items came from, for the approval and the log
    public var folder: String?       // grant: the folder it covers (defaults to the caller's working folder)
    public var duration: Double?     // grant: seconds
    public var project: String?      // move: target project ("" for shared)
    public var environment: String?  // move: target environment
    public var service: String?      // set: the issuing service ("" clears it)
    public var version: String?      // restore, version: a version id
    public var target: RemoteTarget? // link: where the environment's values go
    public var link: String?         // push: only this link
    public var only: [String]?       // push: only these item ids
    public var origin: String?       // "mcp" when an agent asks through `latchkey mcp`: shown in approvals, and
                                     // grants it asks for are limited (see Broker.grant)
    public var session: Bool?        // grant: only while the caller's agent runs
    public var commands: [[String]]? // grant: only for these commands (each a list of words)
    public var uses: Int?            // grant: only this many requests
    public var intended: [String]?   // check: the command the caller means to run, to test command-limited grants.
                                     // Nothing is released by a check, so this claim decides nothing.
    public var remote: RemoteClaim?  // a request forwarded over SSH: what the tool on the other computer says it is
                                     // doing. Shown as unverified; it decides nothing.
    public var page: String?         // from the Safari extension: the site the value was found on, as Safari reported
                                     // it to the extension. Shown in the approval; it decides nothing.

    public init(op: String, names: [String]? = nil, value: String? = nil, kind: ItemKind? = nil,
                agentSafe: Bool? = nil, note: String? = nil,
                items: [ImportItem]? = nil, replace: Bool? = nil, source: String? = nil,
                folder: String? = nil, duration: Double? = nil, project: String? = nil, environment: String? = nil,
                service: String? = nil, version: String? = nil, target: RemoteTarget? = nil, link: String? = nil,
                only: [String]? = nil, origin: String? = nil, session: Bool? = nil, commands: [[String]]? = nil,
                uses: Int? = nil, intended: [String]? = nil, remote: RemoteClaim? = nil, page: String? = nil) {
        self.op = op
        self.names = names
        self.value = value
        self.kind = kind
        self.agentSafe = agentSafe
        self.note = note
        self.items = items
        self.replace = replace
        self.source = source
        self.folder = folder
        self.duration = duration
        self.project = project
        self.environment = environment
        self.service = service
        self.version = version
        self.target = target
        self.link = link
        self.only = only
        self.origin = origin
        self.session = session
        self.commands = commands
        self.uses = uses
        self.intended = intended
        self.remote = remote
        self.page = page
    }
}

/// What a `latchkey` on another computer says about itself when it reaches the app through an SSH forward. The app
/// can't check any of it, so it's only shown, marked as unverified.
public struct RemoteClaim: Codable, Sendable, Hashable {
    public var host: String
    public var cwd: String
    public var command: String

    public init(host: String, cwd: String, command: String) {
        self.host = host
        self.cwd = cwd
        self.command = command
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
    public var grants: [Grant]?
    /// move: old id to new id.
    public var moved: [String: String]?
    /// history, deleted: version records, newest first. Never values.
    public var versions: [Version]?
    public var links: [RemoteLink]?
    public var remoteStatus: [RemoteStatus]?
    public var pushResults: [PushResult]?
    /// check: what `get` would do with each name, without asking or releasing anything. `missing` and `grants`
    /// (the grants that cover `granted`) are filled in too.
    public var agentSafe: [String]?
    public var granted: [String]?
    public var remembered: [String]?
    public var needsApproval: [String]?

    public init(ok: Bool, error: String? = nil, secrets: [SecretInfo]? = nil, values: [String: String]? = nil,
                masked: [String]? = nil, denied: [String]? = nil, missing: [String]? = nil,
                info: [String: String]? = nil, added: [String]? = nil, replaced: [String]? = nil,
                skipped: [String]? = nil, grants: [Grant]? = nil, moved: [String: String]? = nil,
                versions: [Version]? = nil, links: [RemoteLink]? = nil, remoteStatus: [RemoteStatus]? = nil,
                pushResults: [PushResult]? = nil, agentSafe: [String]? = nil, granted: [String]? = nil,
                remembered: [String]? = nil, needsApproval: [String]? = nil) {
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
        self.grants = grants
        self.moved = moved
        self.versions = versions
        self.links = links
        self.remoteStatus = remoteStatus
        self.pushResults = pushResults
        self.agentSafe = agentSafe
        self.granted = granted
        self.remembered = remembered
        self.needsApproval = needsApproval
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

    /// An item id (`NAME` or `project/environment/NAME`): what goes after `latchkey://` and in the keychain
    /// account field.
    public static func isValidName(_ name: String) -> Bool { ItemID(name) != nil }
}

public enum Paths {
    public static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Latchkey", isDirectory: true)
    }
    public static var socket: String { supportDir.appendingPathComponent("broker.sock").path }
    /// Where the command-line tool connects: LATCHKEY_SOCKET (a socket forwarded over SSH from the Mac running the
    /// app), or the app's own socket.
    public static var clientSocket: String { forwardedSocket ?? socket }
    public static var forwardedSocket: String? {
        ProcessInfo.processInfo.environment["LATCHKEY_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
    }
    public static var accessLog: URL { supportDir.appendingPathComponent("access.jsonl") }

    /// The socket for Latchkey's Safari extension, in the App Group container the app and the sandboxed extension
    /// share. Nil when this process isn't entitled to the group (an unsigned build).
    public static func extensionSocket(group: String) -> String? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("extension.sock").path
    }

    public static func ensureSupportDir() throws {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}
