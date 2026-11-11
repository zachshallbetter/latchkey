import Foundation

/// Items holding the same value, found inside the broker so no value leaves it, and what to do about each group.
public enum Duplicates {
    /// Values shorter than this, and plain values, are left out: `3000` or `true` in several places isn't a shared key.
    public static let shortest = 8

    /// Groups of item IDs whose values are equal, each sorted, largest groups first. Plain values and short values are
    /// skipped.
    public static func groups(values: [String: String], items: [SecretInfo]) -> [[String]] {
        let kinds = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.kind) })
        var byValue: [String: [String]] = [:]
        for (id, value) in values where value.count >= shortest && kinds[id]?.isSecret == true {
            byValue[value, default: []].append(id)
        }
        return byValue.values.filter { $0.count > 1 }.map { $0.sorted() }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0[0] < $1[0] }
    }

    /// Whether a value saved as a secret looks like an identifier instead: a project or service ID, a host, a public
    /// key, or a web address with no credentials in it. Sharing one of these between environments is expected. A name
    /// that says secret, token, password, webhook or DSN never counts, and neither does a URL with a user, a password,
    /// a query, or a long random path segment (as webhook URLs have).
    public static func looksLikeIdentifier(name: String, value: String) -> Bool {
        let upper = name.uppercased()
        let secretWords = ["SECRET", "TOKEN", "PASSWORD", "PRIVATE", "WEBHOOK_URL", "DSN", "CREDENTIAL", "API_KEY"]
        guard !secretWords.contains(where: upper.contains), !value.contains(where: \.isWhitespace) else { return false }
        if upper.hasSuffix("PUBLIC_KEY") { return true }
        if let url = URL(string: value), let scheme = url.scheme, url.host != nil {
            guard ["http", "https"].contains(scheme.lowercased()), url.user == nil, url.password == nil, url.query == nil else { return false }
            return !url.pathComponents.contains { $0.count >= 20 && $0.contains(where: \.isNumber) && $0.contains(where: \.isLetter) }
        }
        return ["_ID", "_HOST", "_DOMAIN", "_REGION"].contains(where: upper.hasSuffix)
    }

    /// What a group suggests, in order of how much it matters.
    public enum Advice: Equatable, Sendable {
        /// Identifiers rather than secrets: mark them plain values.
        case plain
        /// The same value in production and elsewhere: give each environment its own key.
        case separateProduction
        /// Already one shared item among them: point the rest at it.
        case useShared(String)
        /// Several names for one value in the same environment: keep one item, every variable points at it.
        case alias(keep: String)
        /// The same name everywhere: one shared item by that name.
        case share(String)
        /// Different names: one shared item, named by you.
        case shareRenamed(suggested: String)

        /// The item to combine the group into, when combining is the advice.
        public var into: String? {
            switch self {
            case .plain, .separateProduction: return nil
            case .useShared(let id), .alias(let id): return id
            case .share(let name), .shareRenamed(let name): return name
            }
        }

        /// A stable name for scripts.
        public var code: String {
            switch self {
            case .plain: return "plain"
            case .separateProduction: return "separate-production"
            case .useShared: return "use-shared"
            case .alias: return "alias"
            case .share: return "share"
            case .shareRenamed: return "share-renamed"
            }
        }

        public var summary: String {
            switch self {
            case .plain:
                return "These look like identifiers rather than secrets (IDs, hosts, public addresses), so the same value in several places is expected. Mark them plain values: they're shown instead of masked and left out of this check."
            case .separateProduction:
                return "Production shares this value with another environment. Give production its own key, so a leak elsewhere can't reach it."
            case .useShared(let id):
                return "\(id) already holds this value as a shared item. Point the others at it, so rotating it is one change."
            case .alias(let id):
                return "Several names for one value in the same environment. Keep \(ItemID(id)?.name ?? id) and point the other variables at it, so there's one item to rotate."
            case .share(let name):
                return "The same key under the same name. Make it one shared item, \(name), so rotating it is one change."
            case .shareRenamed(let name):
                return "The same key under different names. Make it one shared item (suggested: \(name)), and the references follow."
            }
        }
    }

    /// Advice for one group. `identifiers` are the IDs whose values look like identifiers, as the broker reports them.
    public static func advice(for group: [String], identifiers: Set<String> = []) -> Advice {
        let refs = group.compactMap(ItemID.init)
        if !group.isEmpty && group.allSatisfy(identifiers.contains) { return .plain }
        let production = refs.filter { !$0.isShared && Environments.isProduction($0.environment) }
        if !production.isEmpty && production.count < refs.count { return .separateProduction }
        if let shared = refs.first(where: \.isShared) { return .useShared(shared.string) }
        if Set(refs.map { "\($0.project)/\($0.environment)" }).count == 1, let keep = preferred(refs) { return .alias(keep: keep.string) }
        let names = Set(refs.map(\.name))
        if names.count == 1, let name = names.first { return .share(name) }
        return .shareRenamed(suggested: preferred(refs)?.name ?? "")
    }

    /// Advice for every group at once, so two groups never suggest the same new shared name and a suggestion never
    /// takes the name of an item that already exists (`existing`): those get the first project as a prefix, such as
    /// MANAGER_DATABASE_URL.
    public static func advice(for groups: [[String]], identifiers: Set<String> = [], existing: Set<String> = []) -> [Advice] {
        let first = groups.map { advice(for: $0, identifiers: identifiers) }
        var uses: [String: Int] = [:]
        for a in first {
            switch a {
            case .share(let n), .shareRenamed(let n): uses[n, default: 0] += 1
            default: break
            }
        }
        return zip(groups, first).map { group, a in
            func qualified(_ name: String) -> String {
                guard uses[name, default: 0] > 1 || existing.contains(name),
                      let project = group.compactMap(ItemID.init).map(\.project).filter({ !$0.isEmpty }).sorted().first else { return name }
                return String(project.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }) + "_" + name
            }
            switch a {
            case .share(let n): return qualified(n) == n ? a : .shareRenamed(suggested: qualified(n))
            case .shareRenamed(let n): return .shareRenamed(suggested: qualified(n))
            default: return a
            }
        }
    }

    /// The name most of them use; on a tie the shortest (PGHOST over POSTGRES_HOST), then alphabetical.
    private static func preferred(_ refs: [ItemID]) -> ItemID? {
        let counts = Dictionary(refs.map { ($0.name, 1) }, uniquingKeysWith: +)
        return refs.min { a, b in
            let (ca, cb) = (counts[a.name] ?? 0, counts[b.name] ?? 0)
            if ca != cb { return ca > cb }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            return a.string < b.string
        }
    }
}
