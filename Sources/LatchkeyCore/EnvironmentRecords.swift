import Foundation
import Security

// What a project's environment is made of, kept apart from where its files happen to be on one Mac.
//
// An environment record (`shop/development`) is the source of truth for which variables the environment has and
// what each one is: a credential (an item ID, so a shared item works the same on every Mac) or a literal
// non-secret value (`PORT=3000`). Records sync with your items. An item's `usedIn` paths stay as history of where it
// was imported from; they no longer decide membership once a record exists.
//
// A project record ties a project name to the Git remotes its checkouts use, so a fresh clone on another Mac can be
// matched to it. Matching only finds the project: it never releases anything or widens a grant.

/// One variable in an environment record. Stored as `{"type": "literal", "value": …}` or
/// `{"type": "credential", "item": …}`; any other type is refused when read.
public enum EnvironmentEntry: Hashable, Sendable, Codable {
    case literal(String)
    case credential(String)

    enum CodingKeys: String, CodingKey { case type, value, item }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "literal":
            self = .literal(try c.decode(String.self, forKey: .value))
        case "credential":
            let item = try c.decode(String.self, forKey: .item)
            guard Wire.isValidName(item) else {
                throw DecodingError.dataCorruptedError(forKey: .item, in: c, debugDescription: "invalid item id \(item)")
            }
            self = .credential(item)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown variable type \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .literal(let v):
            try c.encode("literal", forKey: .type)
            try c.encode(v, forKey: .value)
        case .credential(let id):
            try c.encode("credential", forKey: .type)
            try c.encode(id, forKey: .item)
        }
    }

    /// The item ID for a credential.
    public var item: String? {
        if case .credential(let id) = self { return id }
        return nil
    }

    /// What the variable is set to before values are filled in: a `latchkey://` reference or the literal.
    public var envValue: String {
        switch self {
        case .literal(let v): return v
        case .credential(let id): return References.scheme + id
        }
    }
}

public struct EnvironmentRecord: Codable, Hashable, Sendable, Identifiable {
    /// `project/environment`.
    public var scope: String
    public var variables: [String: EnvironmentEntry]
    /// Variables `env migrate` found through old file locations and that nobody has confirmed yet. Sorted.
    public var inferred: [String]
    /// True once `env migrate` has compared this environment with the file locations recorded on its items. Until
    /// then `run --env` also loads what the older path-based lookup finds, so nothing that worked stops working.
    public var legacyChecked: Bool
    public var updatedAt: Date

    public var id: String { scope }

    public init(scope: String, variables: [String: EnvironmentEntry] = [:], inferred: [String] = [],
                legacyChecked: Bool = false, updatedAt: Date = Date()) {
        self.scope = scope
        self.variables = variables
        self.inferred = inferred.sorted()
        self.legacyChecked = legacyChecked
        self.updatedAt = updatedAt
    }

    /// A name an env file can hold: a letter or `_`, then letters, digits and `_`.
    public static func isValidVariable(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.utf8.count <= 128 else { return false }
        func letter(_ c: Unicode.Scalar) -> Bool { (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || c == "_" }
        return letter(first) && name.unicodeScalars.allSatisfy { letter($0) || ($0 >= "0" && $0 <= "9") }
    }

    /// True when a value given as a plain setting might be a secret: its name says so, it looks like a known
    /// provider's key or a connection string with a password, or it's a long run of letters and digits. Such values
    /// belong in an item, not in a record.
    public static func mayBeSecret(name: String, value: String) -> Bool {
        let n = name.uppercased()
        let words = ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PASS", "PWD", "CREDENTIAL", "AUTH", "PRIVATE", "DSN", "COOKIE", "SESSION"]
        if words.contains(where: { n == $0 || n.hasSuffix("_" + $0) || n.hasPrefix($0 + "_") || n.contains("_" + $0 + "_") }) { return true }
        if EnvImport.guessKind(name, value) != nil || Services.guess(key: name, value: value) != nil { return true }
        let compact = !value.contains(where: \.isWhitespace)
        return compact && value.count >= 24 && value.contains(where: \.isLetter) && value.contains(where: \.isNumber)
    }

    /// Sets a variable by an explicit action (import, set, `env set`): it's no longer inferred.
    public mutating func set(_ name: String, _ entry: EnvironmentEntry) {
        variables[name] = entry
        inferred.removeAll { $0 == name }
    }

    public mutating func unset(_ name: String) {
        variables[name] = nil
        inferred.removeAll { $0 == name }
    }

    /// The record's env file: references and literals, one per line, sorted by name.
    public func envFile(values: [String: String] = [:]) -> String {
        var out = "# Latchkey environment \(scope)\n"
        for name in variables.keys.sorted() {
            let entry = variables[name]!
            let value = entry.item.flatMap { values[$0] } ?? entry.envValue
            out += "\(name)=\(EnvFile.quoted(value))\n"
        }
        return out
    }
}

public struct ProjectRecord: Codable, Hashable, Sendable, Identifiable {
    /// Stable and random: the project keeps it if its name or remotes change.
    public var id: String
    /// The project part of item IDs (`shop` in `shop/development/DATABASE_URL`).
    public var name: String
    /// Normalized remote URLs (`github.com/me/shop`) its checkouts use. Never with credentials.
    public var origins: [String]
    public var createdAt: Date

    public init(id: String = Grant.newID(), name: String, origins: [String], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.origins = Array(Set(origins)).sorted()
        self.createdAt = createdAt
    }
}

/// Git remotes, read from git's own config file rather than by running git.
public enum GitRemotes {
    /// `host/path` in lowercase, with no scheme, user, password, port or `.git`: the same for the HTTPS and SSH forms
    /// of one repository. Nil for anything that isn't a remote URL (a local path, for example).
    public static func normalize(_ url: String) -> String? {
        var s = url.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var host: Substring, path: Substring
        if let r = s.range(of: "://") {
            s = String(s[r.upperBound...])
            guard let slash = s.firstIndex(of: "/") else { return nil }
            host = s[..<slash]
            path = s[s.index(after: slash)...]
            if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
            if let colon = host.lastIndex(of: ":") { host = host[..<colon] }
        } else if let colon = s.firstIndex(of: ":"), !s.hasPrefix("/"), !s.hasPrefix(".") {
            // scp form: git@github.com:me/shop.git
            host = s[..<colon]
            path = s[s.index(after: colon)...]
            if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        } else if !s.hasPrefix("/"), !s.hasPrefix("."), let slash = s.firstIndex(of: "/") {
            // Already normalized: host/path.
            host = s[..<slash]
            path = s[s.index(after: slash)...]
        } else {
            return nil
        }
        var p = String(path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if p.hasSuffix(".git") { p.removeLast(4) }
        guard !host.isEmpty, !p.isEmpty, host.contains(".") || host == "localhost" else { return nil }
        return "\(host)/\(p)".lowercased()
    }

    /// The remotes of the repository `path` is in, by name, normalized. Empty outside a repository.
    public static func remotes(for path: String) -> [String: String] {
        guard let common = Repo.commonDir(for: path),
              let text = try? String(contentsOfFile: common + "/config", encoding: .utf8) else { return [:] }
        return parse(config: text)
    }

    static func parse(config text: String) -> [String: String] {
        var out: [String: String] = [:]
        var remote: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                remote = nil
                if line.hasPrefix("[remote \""), let end = line.lastIndex(of: "\"") {
                    let start = line.index(line.startIndex, offsetBy: 9)
                    if start < end { remote = String(line[start..<end]) }
                }
                continue
            }
            guard let name = remote, let eq = line.firstIndex(of: "="),
                  line[..<eq].trimmingCharacters(in: .whitespaces).lowercased() == "url" else { continue }
            if out[name] == nil, let n = normalize(String(line[line.index(after: eq)...])) { out[name] = n }
        }
        return out
    }
}

/// What a checkout's remotes say about which project it is. Only a lead: confirming it is up to you.
public struct ProjectMatch: Sendable, Hashable {
    public var project: ProjectRecord
    /// The remotes that matched, by name.
    public var remotes: [String]
    /// True if `origin` (or the only remote) matched. A match through another remote, such as `upstream`, is how a
    /// fork looks, so it's never taken as the project without asking.
    public var throughOrigin: Bool
}

public enum ProjectMatching {
    public static func matches(remotes: [String: String], projects: [ProjectRecord]) -> [ProjectMatch] {
        let primary = remotes["origin"] != nil ? "origin" : (remotes.count == 1 ? remotes.keys.first : nil)
        return projects.compactMap { p in
            let names = remotes.filter { p.origins.contains($0.value) }.keys.sorted()
            guard !names.isEmpty else { return nil }
            return ProjectMatch(project: p, remotes: names, throughOrigin: primary.map(names.contains) ?? false)
        }.sorted { ($0.throughOrigin ? 0 : 1, $0.project.name) < ($1.throughOrigin ? 0 : 1, $1.project.name) }
    }

    /// The one project a checkout's own origin points at, or nil when there's none or more than one.
    public static func project(remotes: [String: String], projects: [ProjectRecord]) -> ProjectRecord? {
        let direct = matches(remotes: remotes, projects: projects).filter(\.throughOrigin)
        return direct.count == 1 ? direct[0].project : nil
    }
}

// MARK: - storage

/// Records, kept as keychain items with nothing secret in them (literals are non-secret by definition), so they sync
/// with your items; or in memory for tests.
public protocol EnvironmentStore: AnyObject, Sendable {
    func environments() throws -> [EnvironmentRecord]
    func save(_ record: EnvironmentRecord) throws
    func projects() throws -> [ProjectRecord]
    func save(_ project: ProjectRecord) throws
    func removeProject(_ id: String) throws
}

public final class KeychainEnvironmentStore: EnvironmentStore, @unchecked Sendable {
    public static let environmentService = "latchkey.environment"
    public static let projectService = "latchkey.project"
    let items: KeychainStore

    public init(mode: KeychainStore.Mode) { items = KeychainStore(mode: mode) }

    public func environments() throws -> [EnvironmentRecord] {
        try all(Self.environmentService, EnvironmentRecord.self).sorted { $0.scope < $1.scope }
    }

    public func save(_ record: EnvironmentRecord) throws {
        try put(record, account: record.scope, service: Self.environmentService, label: "Latchkey environment: \(record.scope)")
    }

    public func projects() throws -> [ProjectRecord] {
        try all(Self.projectService, ProjectRecord.self).sorted { $0.name < $1.name }
    }

    public func save(_ project: ProjectRecord) throws {
        try put(project, account: project.id, service: Self.projectService, label: "Latchkey project: \(project.name)")
    }

    public func removeProject(_ id: String) throws {
        let status = SecItemDelete(items.query(id, service: Self.projectService) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.keychain("delete project", status) }
    }

    /// A record that can't be read (an unknown variable type from a newer version, say) fails the whole read rather
    /// than being skipped, so nothing acts on half an environment.
    private func all<T: Decodable>(_ service: String, _ type: T.Type) throws -> [T] {
        var q = items.query(nil, service: service)
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw StoreError.keychain("list \(service)", status) }
        let dec = Wire.decoder()
        return try (out as? [[String: Any]] ?? []).map { row in
            guard let data = row[kSecAttrGeneric as String] as? Data else { throw StoreError.keychain("read \(service)", errSecDecode) }
            return try dec.decode(T.self, from: data)
        }
    }

    private func put<T: Encodable>(_ value: T, account: String, service: String, label: String) throws {
        let data = try Wire.encoder().encode(value)
        let q = items.query(account, service: service)
        let update: [String: Any] = [kSecAttrGeneric as String: data, kSecAttrLabel as String: label]
        var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = q.merging(update) { $1 }
            add[kSecValueData as String] = Data()
            if case .iCloud = items.mode {
                add[kSecAttrSynchronizable as String] = true
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError.keychain("save \(service)", status) }
    }
}

public final class MemoryEnvironmentStore: EnvironmentStore, @unchecked Sendable {
    private var envs: [String: EnvironmentRecord] = [:]
    private var projs: [String: ProjectRecord] = [:]
    private let lock = NSLock()
    public init() {}
    public func environments() throws -> [EnvironmentRecord] { lock.withLock { envs.values.sorted { $0.scope < $1.scope } } }
    public func save(_ record: EnvironmentRecord) throws { lock.withLock { envs[record.scope] = record } }
    public func projects() throws -> [ProjectRecord] { lock.withLock { projs.values.sorted { $0.name < $1.name } } }
    public func save(_ project: ProjectRecord) throws { lock.withLock { projs[project.id] = project } }
    public func removeProject(_ id: String) throws { _ = lock.withLock { projs.removeValue(forKey: id) } }
}

// MARK: - resolving and updating

public enum EnvironmentRecords {
    /// What the path-based lookup (before records) loads for `scope`: its own items by name, then shared items whose
    /// recorded files are in the same checkout as one of its items' files.
    public static func legacy(scope: String, items: [SecretInfo]) -> [String: String] {
        var env: [String: String] = [:]
        let inScope = items.filter { $0.name.hasPrefix(scope + "/") }
        for item in inScope { env[item.ref.name] = item.name }
        let folders = Set(inScope.flatMap { $0.usedIn ?? [] }.map { Repo.mainCheckout(for: $0) ?? URL(fileURLWithPath: $0).deletingLastPathComponent().path })
        for item in items where item.ref.isShared && env[item.name] == nil {
            if (item.usedIn ?? []).contains(where: { path in folders.contains { path.hasPrefix($0 + "/") } }) { env[item.name] = item.name }
        }
        return env
    }

    /// The record after an explicit change (import or set). With no record yet, one is started from the
    /// environment's own items, so a first import never hides items that were already there. Not `legacyChecked`:
    /// `run --env` keeps adding what the old lookup finds until `env migrate` has run.
    public static func applying(_ given: [String: EnvironmentEntry], to existing: EnvironmentRecord?, scope: String,
                                items: [SecretInfo], now: Date = Date()) -> EnvironmentRecord {
        var record = existing ?? seeded(scope: scope, items: items, now: now)
        for (name, entry) in given { record.set(name, entry) }
        record.updatedAt = now
        return record
    }

    /// The variables an imported file gives its environment: each imported key's item, and lines that already
    /// hold a whole `latchkey://` reference. Nil if there are none or the scope isn't valid.
    public static func fromFile(_ text: String, references: [String: String], scope: String) -> EnvironmentRecord? {
        guard RemoteLink.isValidScope(scope) else { return nil }
        var vars: [String: EnvironmentEntry] = [:]
        for (key, value) in (try? EnvFile.parse(text)) ?? [] where EnvironmentRecord.isValidVariable(key) && value.hasPrefix(References.scheme) {
            let id = String(value.dropFirst(References.scheme.count))
            if Wire.isValidName(id) { vars[key] = .credential(id) }
        }
        for (key, id) in references where EnvironmentRecord.isValidVariable(key) { vars[key] = .credential(id) }
        return vars.isEmpty ? nil : EnvironmentRecord(scope: scope, variables: vars)
    }

    static func seeded(scope: String, items: [SecretInfo], now: Date) -> EnvironmentRecord {
        var vars: [String: EnvironmentEntry] = [:]
        for item in items where item.name.hasPrefix(scope + "/") { vars[item.ref.name] = .credential(item.name) }
        return EnvironmentRecord(scope: scope, variables: vars, updatedAt: now)
    }

    /// Records whose credentials point at moved items, pointing at the new IDs. Only changed records are returned.
    public static func renaming(_ records: [EnvironmentRecord], _ moved: [String: String], now: Date = Date()) -> [EnvironmentRecord] {
        records.compactMap { r in
            var r = r, changed = false
            for (name, entry) in r.variables {
                if let id = entry.item, let to = moved[id] { r.variables[name] = .credential(to); changed = true }
            }
            if changed { r.updatedAt = now }
            return changed ? r : nil
        }
    }

    /// Adds `proposed`'s variables that `existing` doesn't have. Never changes or removes an existing variable, so
    /// running a migration again, or one built from older data, can't undo a newer change.
    public static func adding(_ proposed: EnvironmentRecord, to existing: EnvironmentRecord?, now: Date = Date()) -> (record: EnvironmentRecord, added: [String]) {
        var record = existing ?? EnvironmentRecord(scope: proposed.scope, updatedAt: now)
        var added: [String] = []
        for name in proposed.variables.keys.sorted() where record.variables[name] == nil {
            record.variables[name] = proposed.variables[name]
            if proposed.inferred.contains(name) { record.inferred.append(name) }
            added.append(name)
        }
        record.inferred = Array(Set(record.inferred)).sorted()
        let checked = proposed.legacyChecked && !record.legacyChecked
        if checked { record.legacyChecked = true }
        if !added.isEmpty || checked { record.updatedAt = now }
        return (record, added)
    }
}

// MARK: - migration

/// Builds records for environments from what Latchkey already knows: each environment's own items (certain, by their
/// IDs), and from the files recorded on those items, if they're on this Mac, the shared items and plain settings
/// those files use (inferred until confirmed). Reports what it can't settle instead of choosing.
public enum EnvironmentMigration {
    public struct Plan: Sendable {
        /// Proposed variables per environment, to add to whatever is stored (`EnvironmentRecords.adding`).
        public var records: [EnvironmentRecord]
        /// scope → variables that differ between sources or from the stored record; left as they are.
        public var conflicts: [String: [String]]
        /// scope → variables that can't be recorded: a plain value that may be secret, or a reference to a missing
        /// item.
        public var notRecorded: [String: [String]]
        /// Files recorded on items that aren't on this Mac (or can't be read): anything only they knew is missing.
        public var unreadable: [String]
    }

    /// Plain values safe to keep in a synced record without asking: a number up to six digits, or true/false.
    public static func isPlainSetting(_ value: String) -> Bool {
        let v = value.lowercased()
        if v == "true" || v == "false" { return true }
        return !v.isEmpty && v.count <= 6 && v.allSatisfy(\.isASCII) && v.allSatisfy(\.isNumber)
    }

    /// `files`: path → text, for the recorded files that could be read here.
    public static func plan(items: [SecretInfo], existing: [EnvironmentRecord], files: [String: String]) -> Plan {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        let stored = Dictionary(uniqueKeysWithValues: existing.map { ($0.scope, $0) })
        let scopes = Set(items.filter { !$0.ref.isShared }.map { "\($0.ref.project)/\($0.ref.environment)" })
        var records: [EnvironmentRecord] = []
        var conflicts: [String: [String]] = [:], notRecorded: [String: [String]] = [:]
        var unreadable = Set<String>()

        for scope in scopes.sorted() {
            var vars: [String: EnvironmentEntry] = [:]
            var inferred = Set<String>()
            var problems: [String] = [], skipped: [String] = []
            let own = items.filter { $0.name.hasPrefix(scope + "/") }
            for item in own { vars[item.ref.name] = .credential(item.name) }

            func propose(_ name: String, _ entry: EnvironmentEntry, from source: String) {
                if let have = vars[name] {
                    if have != entry { problems.append("\(name): \(describe(have)) or \(describe(entry)) (\(source))") }
                    return
                }
                vars[name] = entry
                inferred.insert(name)
            }

            // Shared items the older lookup would load: kept, so the record covers everything that worked before.
            for (name, id) in EnvironmentRecords.legacy(scope: scope, items: items) where byID[id]?.ref.isShared == true {
                propose(name, .credential(id), from: "used in the same checkout")
            }

            // The files this environment's items came from.
            let paths = Set(own.flatMap { $0.usedIn ?? [] }).sorted()
            for path in paths {
                guard let text = files[path], let lines = try? EnvFile.parse(text) else { unreadable.insert(path); continue }
                let file = Broker.tilde(path)
                for (key, value) in lines {
                    guard EnvironmentRecord.isValidVariable(key), !value.isEmpty else { continue }
                    // Already set (a shared item the checkout uses): a plain copy of its value in the file says nothing new.
                    if vars[key] != nil && !value.hasPrefix(References.scheme) { continue }
                    if value.hasPrefix(References.scheme) {
                        let id = String(value.dropFirst(References.scheme.count))
                        guard Wire.isValidName(id) else { continue }
                        if byID[id] == nil { skipped.append("\(key): refers to \(id), which isn't in Latchkey (\(file))"); continue }
                        propose(key, .credential(id), from: file)
                    } else if value.contains(References.scheme) || value.contains(References.fileScheme) {
                        skipped.append("\(key): mixes text and references (\(file))")
                    } else if isPlainSetting(value) && !EnvImport.matches(key, EnvImport.defaultSkip) {
                        propose(key, .literal(value), from: file)
                    } else {
                        skipped.append("\(key): plain value in \(file), not stored in case it's secret; add it with lk env set \(scope) \(key)=VALUE if it isn't")
                    }
                }
            }

            // A stored variable always stands; a different proposal for it is reported.
            if let record = stored[scope] {
                for (name, entry) in vars where record.variables[name] != nil && record.variables[name] != entry {
                    problems.append("\(name): stored as \(describe(record.variables[name]!)), found \(describe(entry)); kept as stored")
                }
            }
            records.append(EnvironmentRecord(scope: scope, variables: vars, inferred: Array(inferred), legacyChecked: true))
            if !problems.isEmpty { conflicts[scope] = problems.sorted() }
            if !skipped.isEmpty { notRecorded[scope] = Array(Set(skipped)).sorted() }
        }
        return Plan(records: records, conflicts: conflicts, notRecorded: notRecorded, unreadable: unreadable.sorted())
    }

    static func describe(_ e: EnvironmentEntry) -> String {
        switch e {
        case .credential(let id): return id
        case .literal(let v): return "\"\(v)\""
        }
    }
}
