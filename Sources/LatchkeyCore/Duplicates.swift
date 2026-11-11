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

    /// What a group suggests, in order of how much it matters.
    public enum Advice: Equatable, Sendable {
        /// The same value in production and elsewhere: give each environment its own key.
        case separateProduction
        /// Already one shared item among them: point the rest at it.
        case useShared(String)
        /// The same name everywhere: one shared item by that name.
        case share(String)
        /// Different names: one shared item, named by you.
        case shareRenamed(suggested: String)

        /// The shared item to combine the group into, when combining is the advice.
        public var into: String? {
            switch self {
            case .separateProduction: return nil
            case .useShared(let id): return id
            case .share(let name), .shareRenamed(let name): return name
            }
        }

        /// A stable name for scripts.
        public var code: String {
            switch self {
            case .separateProduction: return "separate-production"
            case .useShared: return "use-shared"
            case .share: return "share"
            case .shareRenamed: return "share-renamed"
            }
        }

        public var summary: String {
            switch self {
            case .separateProduction:
                return "Production shares this value with another environment. Give production its own key, so a leak elsewhere can't reach it."
            case .useShared(let id):
                return "\(id) already holds this value as a shared item. Point the others at it, so rotating it is one change."
            case .share(let name):
                return "The same key under the same name. Make it one shared item, \(name), so rotating it is one change."
            case .shareRenamed(let name):
                return "The same key under different names. Make it one shared item (suggested: \(name)), and the references follow."
            }
        }
    }

    public static func advice(for group: [String]) -> Advice {
        let refs = group.compactMap(ItemID.init)
        let production = refs.filter { !$0.isShared && Environments.isProduction($0.environment) }
        if !production.isEmpty && production.count < refs.count { return .separateProduction }
        if let shared = refs.first(where: \.isShared) { return .useShared(shared.string) }
        let names = Set(refs.map(\.name))
        if names.count == 1, let name = names.first { return .share(name) }
        let counts = Dictionary(refs.map { ($0.name, 1) }, uniquingKeysWith: +)
        let suggested = counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key ?? refs.first?.name ?? ""
        return .shareRenamed(suggested: suggested)
    }
}
