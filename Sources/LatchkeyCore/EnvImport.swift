import Foundation

/// What a line of an env file is. Decided by `EnvImport.classify`, shown in reviews, and changeable before saving.
/// Import-only: never sent to the broker or stored.
public enum ImportClass: String, CaseIterable, Sendable {
    /// Saved masked, as a token, password or key file.
    case secret
    /// An ordinary setting (`PORT`, `NODE_ENV`): left in the file.
    case setting
    /// Not secret, but worth keeping: a client-side key, an ID, a web address. Saved as a plain value.
    case publicValue = "public"
    /// Already a `latchkey://` reference. Not a choice.
    case reference

    public var label: String {
        switch self {
        case .secret: return "Secret"
        case .setting: return "Setting"
        case .publicValue: return "Public"
        case .reference: return "Reference"
        }
    }

    /// The classes a person can pick for a line.
    public static let choices: [ImportClass] = [.secret, .setting, .publicValue]
}

/// Turns a .env file into import items. Shared by `latchkey import` and the app's Import sheet.
public enum EnvImport {
    public struct Plan: Sendable {
        /// Sorted by id. Later lines win, as when the file is loaded.
        public var items: [ImportItem]
        /// Lines left alone, key → reason ("empty", "already a reference", "setting: left in the file").
        public var ignored: [String: String]
        /// Each imported key → the id of the item that will hold it.
        public var references: [String: String]
        /// Each classified line's class, including settings and references. Empty and skipped lines have none.
        public var classes: [String: ImportClass] = [:]
        /// What each setting would be saved as if you changed its class, sorted by id.
        public var settings: [ImportItem] = []
    }

    /// Names whose values reach browsers or apps; their values are public by design.
    public static let publicPrefixes = ["NEXT_PUBLIC_", "NUXT_PUBLIC_", "VITE_", "PUBLIC_", "EXPO_PUBLIC_", "REACT_APP_"]
    static let settingNames: Set<String> = ["PORT", "HOST", "HOSTNAME", "NODE_ENV", "APP_ENV", "ENV", "ENVIRONMENT", "LOG_LEVEL",
                                            "LOG_FORMAT", "DEBUG", "TZ", "LANG", "CI", "TIMEOUT", "WORKERS", "VERBOSE"]
    static let settingSuffixes = ["_PORT", "_ENABLED", "_DISABLED", "_LEVEL", "_TIMEOUT", "_TIMEOUT_MS", "_MODE", "_ENV", "_DEBUG", "_VERBOSE"]

    /// Decides a line's class from its name and value, never by sending them anywhere. Anything unclear is a secret.
    /// A value that looks like credentials (a key block, a connection string with a password) is a secret whatever
    /// its name says.
    public static func classify(key: String, value: String, agentSafePatterns: [String] = []) -> ImportClass {
        if value.contains(References.scheme) { return .reference }
        if guessKind(key, value) != nil { return .secret }
        if let url = URL(string: value), url.host != nil, url.user != nil || url.password != nil { return .secret }
        let k = key.uppercased()
        if matches(key, agentSafePatterns) || publicPrefixes.contains(where: k.hasPrefix) { return .publicValue }
        if k.contains("PUBLISHABLE") || k.hasSuffix("PUBLIC_KEY") || value.hasPrefix("pk_live_") || value.hasPrefix("pk_test_") {
            return .publicValue
        }
        if EnvironmentRecord.mayBeSecret(name: key, value: value) { return .secret }
        if Duplicates.looksLikeIdentifier(name: key, value: value) { return .publicValue }
        if settingNames.contains(k) || settingSuffixes.contains(where: k.hasSuffix) || ["true", "false"].contains(value.lowercased()) {
            return .setting
        }
        return .secret
    }

    /// `project` and `environment` place every item; both empty makes them shared items named after their keys.
    /// `location` (the file's path) is recorded on each item as a place it's used.
    /// Names `vercel env pull` writes that expire within hours. Importing them would only store stale tokens.
    public static let defaultSkip = ["VERCEL_OIDC_TOKEN", "VERCEL_*", "TURBO_*"]

    /// Shell-style patterns: `*` matches any run of characters, everything else matches itself.
    public static func matches(_ name: String, _ patterns: [String]) -> Bool {
        patterns.contains { fnmatch($0, name, 0) == 0 }
    }

    public static func plan(_ text: String, source: String, location: String? = nil,
                            project: String = "", environment: String = "",
                            only: Set<String>? = nil, defaultKind: ItemKind = .token, kinds: [String: ItemKind] = [:],
                            agentSafe: Set<String> = [], allAgentSafe: Bool = false,
                            skip: [String] = defaultSkip, agentSafePatterns: [String] = [],
                            classes overrides: [String: ImportClass] = [:]) throws -> Plan {
        var items: [String: ImportItem] = [:]
        var settings: [String: ImportItem] = [:]
        var ignored: [String: String] = [:]
        var classes: [String: ImportClass] = [:]
        for (key, value) in try EnvFile.parse(text) {
            if let only, !only.contains(key) { continue }
            items[key] = nil
            settings[key] = nil
            ignored[key] = nil
            classes[key] = nil
            if matches(key, skip) { ignored[key] = "skipped: expires, or excluded by --skip"; continue }
            if value.isEmpty { ignored[key] = "empty"; continue }
            var cls = classify(key: key, value: value, agentSafePatterns: agentSafePatterns)
            if cls == .reference { classes[key] = cls; ignored[key] = "already a reference"; continue }
            // A line you chose a class for, or named in --kind or --agent-safe, is what you said it is.
            if let chosen = overrides[key], chosen != .reference { cls = chosen }
            else if let kind = kinds[key] { cls = kind == .value ? .publicValue : .secret }
            else if agentSafe.contains(key), cls == .setting { cls = .publicValue }
            classes[key] = cls
            let id = ItemID(project: project, environment: project.isEmpty ? "" : environment, name: key).string
            let isSecret = cls == .secret
            // Public values (NEXT_PUBLIC_*, VITE_*) are saved as plain values; only the names you pass are agent-safe.
            let item = ImportItem(name: id, value: value,
                                  kind: isSecret ? (kinds[key] ?? guessKind(key, value) ?? defaultKind) : .value,
                                  agentSafe: allAgentSafe || agentSafe.contains(key) || (cls == .publicValue && matches(key, agentSafePatterns)),
                                  note: "imported from \(source)", usedIn: location.map { [$0] },
                                  service: Services.guess(key: key, value: value))
            if cls == .setting {
                ignored[key] = "setting: left in the file"
                settings[key] = item
            } else {
                items[key] = item
            }
        }
        return Plan(items: items.values.sorted { $0.name < $1.name }, ignored: ignored,
                    references: items.mapValues(\.name), classes: classes,
                    settings: settings.values.sorted { $0.name < $1.name })
    }

    // MARK: several files

    public struct FilePlan: Sendable {
        public var url: URL
        public var text: String
        public var project: String
        public var environment: String
        /// Each imported key → the id of the item that holds it, after sharing and conflicts.
        public var references: [String: String]
        public var ignored: [String: String]
        /// Each classified line's class, including settings and references.
        public var classes: [String: ImportClass] = [:]
    }

    public struct BatchPlan: Sendable {
        public var files: [FilePlan]
        /// One item per id, sorted. A value shared by several files is one item used in all of them.
        public var items: [ImportItem]
        /// Names whose value was the same in every file that has them (and in at least two), now one shared item:
        /// name → how many files.
        public var shared: [String: Int]
        /// Ids two files gave different values; left out, and their lines left as they are.
        public var conflicts: [String: [String]]
    }

    /// Plans an import of several files at once. Each file is placed in its own project and environment (from its
    /// repository and name) unless `project` or `environment` is given; `shared` makes every item shared.
    /// `projectFor` names a file's project when its checkout is linked to one (see `ProjectMatching`).
    /// With `shareIdentical`, a name holding the same value in every file that has it becomes one shared item.
    public static func batch(_ files: [(url: URL, text: String)], project: String? = nil, environment: String? = nil,
                             shared allShared: Bool = false, shareIdentical: Bool = false,
                             defaultKind: ItemKind = .token, kinds: [String: ItemKind] = [:],
                             agentSafe: Set<String> = [], allAgentSafe: Bool = false,
                             skip: [String] = defaultSkip, agentSafePatterns: [String] = [],
                             classes: [String: ImportClass] = [:],
                             projectFor: (URL) -> String? = { _ in nil }) throws -> BatchPlan {
        var filePlans: [FilePlan] = []
        var itemsByFile: [[String: ImportItem]] = []   // key → item, per file
        for f in files {
            let proj = allShared ? "" : (project ?? projectFor(f.url) ?? self.project(forFile: f.url))
            let env = allShared ? "" : (environment ?? self.environment(forFile: f.url.lastPathComponent))
            let p = try plan(f.text, source: f.url.lastPathComponent, location: f.url.path, project: proj, environment: env,
                         defaultKind: defaultKind, kinds: kinds, agentSafe: agentSafe, allAgentSafe: allAgentSafe,
                         skip: skip, agentSafePatterns: agentSafePatterns, classes: classes)
            var byKey: [String: ImportItem] = [:]
            for (key, id) in p.references { byKey[key] = p.items.first { $0.name == id } }
            itemsByFile.append(byKey)
            filePlans.append(FilePlan(url: f.url, text: f.text, project: proj, environment: env, references: p.references, ignored: p.ignored, classes: p.classes))
        }

        // Same value everywhere a name appears (two files or more): one shared item.
        var shared: [String: Int] = [:]
        if shareIdentical && !allShared {
            var occurrences: [String: [Int]] = [:]
            for (i, byKey) in itemsByFile.enumerated() { for key in byKey.keys { occurrences[key, default: []].append(i) } }
            for (key, idx) in occurrences where idx.count >= 2 {
                let values = Set(idx.map { itemsByFile[$0][key]!.value })
                guard values.count == 1 else { continue }
                shared[key] = idx.count
                for i in idx {
                    itemsByFile[i][key]!.name = key
                    filePlans[i].references[key] = key
                }
            }
        }

        // Merge by id. Two different values for one id is a conflict: neither is imported.
        var merged: [String: ImportItem] = [:]
        var conflicting: [String: Set<String>] = [:]
        for (i, byKey) in itemsByFile.enumerated() {
            for (_, item) in byKey {
                if var existing = merged[item.name] {
                    if existing.value != item.value {
                        conflicting[item.name, default: []].formUnion((existing.usedIn ?? []) + [filePlans[i].url.path])
                        continue
                    }
                    existing.usedIn = StoreSupport.merge(existing.usedIn, item.usedIn)
                    merged[item.name] = existing
                } else {
                    merged[item.name] = item
                }
            }
        }
        for id in conflicting.keys {
            merged[id] = nil
            for i in filePlans.indices {
                for (key, ref) in filePlans[i].references where ref == id {
                    filePlans[i].references[key] = nil
                    filePlans[i].ignored[key] = "conflict: another file gives \(id) a different value"
                }
            }
        }
        return BatchPlan(files: filePlans, items: merged.values.sorted { $0.name < $1.name }, shared: shared,
                         conflicts: conflicting.mapValues { $0.sorted() })
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

    /// The project a file belongs to: the folder name of the repository's main checkout (so a worktree at
    /// `~/Projects/_worktrees/site/fix-login` is still `site`), or failing that the file's own folder, lowercased
    /// with anything outside letters, digits, `_`, `-` and `.` turned into `-`.
    public static func project(forFile url: URL) -> String {
        if let main = Repo.mainCheckout(for: url.path) { return slug(URL(fileURLWithPath: main).lastPathComponent) }
        return slug(url.deletingLastPathComponent().standardizedFileURL.lastPathComponent)
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

/// Finds env files to import under a folder: `.env` and `.env.*`, but not examples or templates, and not inside
/// dependency, build or version-control folders. Doesn't follow symbolic links.
public enum EnvScan {
    static let skippedFolders: Set<String> = ["node_modules", ".git", ".build", "build", "dist", "out", "vendor", "Pods",
                                              ".next", ".nuxt", ".svelte-kit", ".turbo", ".venv", "venv", "target",
                                              "DerivedData", ".cache", "coverage", "Library"]
    static let skippedSuffixes = [".example", ".sample", ".template", ".dist", ".defaults", ".schema"]
    /// Backup copies, wherever the marker sits: `.env.bak`, `.env.publish.bak.20260720`, `.env.local.old`.
    static let backupMarkers = [".bak", ".backup", ".old", ".orig", ".copy", ".save", ".swp"]

    public static func isEnvFile(_ name: String) -> Bool {
        guard name == ".env" || name.hasPrefix(".env.") else { return false }
        let lower = name.lowercased()
        if lower.hasSuffix("~") || backupMarkers.contains(where: { lower.hasSuffix($0) || lower.contains($0 + ".") }) { return false }
        return !skippedSuffixes.contains { lower.hasSuffix($0) }
    }

    public static func files(under root: URL, depth: Int = 4, matching isMatch: (String) -> Bool = isEnvFile) -> [String] {
        var out: [String] = []
        func walk(_ dir: URL, _ level: Int) {
            guard level <= depth,
                  let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
            for e in entries.sorted(by: { $0.path < $1.path }) {
                let values = try? e.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                let name = e.lastPathComponent
                if values?.isDirectory == true {
                    if !skippedFolders.contains(name) && !(name.hasPrefix(".") && name != ".config") { walk(e, level + 1) }
                } else if isMatch(name) {
                    out.append(e.path)
                }
            }
        }
        walk(root, 0)
        return out
    }
}
