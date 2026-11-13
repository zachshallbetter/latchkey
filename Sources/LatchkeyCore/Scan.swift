import Foundation

/// Finds plain values left in env files: what `latchkey scan` looks for before it asks the broker which of them equal
/// stored items.
public enum Scan {
    /// One assignment found in a file.
    public struct Candidate: Equatable, Sendable {
        public var path: String
        public var line: Int
        public var key: String
        public var value: String
    }

    /// `.env`, `.env.*` (not examples, templates or backups) and `*.env`.
    public static func isScannable(_ name: String) -> Bool {
        if EnvScan.isEnvFile(name) { return true }
        let lower = name.lowercased()
        return lower.hasSuffix(".env") && !EnvScan.backupMarkers.contains { lower.contains($0 + ".") }
    }

    /// The assignments in `text` that hold a plain value: not empty, not a reference. With `only`, just those that start
    /// on one of those (1-based) lines. A file that doesn't parse has none.
    public static func candidates(in text: String, path: String, only: Set<Int>? = nil) -> [Candidate] {
        guard let entries = try? EnvFile.located(text) else { return [] }
        return entries.compactMap { e in
            guard !e.value.isEmpty, !e.value.contains(References.scheme), only?.contains(e.line) ?? true else { return nil }
            return Candidate(path: path, line: e.line, key: e.key, value: e.value)
        }
    }

    /// Whether a plain value looks like a secret rather than a setting: a private key, a password or credentialed
    /// connection string, a token with a known prefix, or a long value under a name that says it is one. Identifiers
    /// (IDs, hosts, public addresses) and short values don't.
    public static func looksSecret(key: String, value: String) -> Bool {
        guard value.count >= Duplicates.shortest, !Duplicates.looksLikeIdentifier(name: key, value: value) else { return false }
        if EnvImport.guessKind(key, value) != nil { return true }
        if Services.valuePrefixes.contains(where: { value.hasPrefix($0.0) }) { return true }
        let upper = key.uppercased()
        let words = ["SECRET", "TOKEN", "PASSWORD", "PASSWD", "PRIVATE_KEY", "API_KEY", "APIKEY", "ACCESS_KEY", "AUTH_KEY", "CREDENTIAL"]
        return words.contains(where: upper.contains) && !value.contains(where: \.isWhitespace) && Double(value) == nil
    }

    /// The lines added in each file by a `git diff --unified=0` (1-based, in the new file), for `scan --staged`.
    public static func addedLines(inDiff diff: String) -> [String: Set<Int>] {
        var out: [String: Set<Int>] = [:]
        var path: String?
        var next = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++ ") {
                path = line.hasPrefix("+++ b/") ? String(line.dropFirst(6)) : nil
            } else if line.hasPrefix("@@"), let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }) {
                next = Int(plus.dropFirst().split(separator: ",")[0]) ?? 0
            } else if line.hasPrefix("+"), let path {
                out[path, default: []].insert(next)
                next += 1
            }
        }
        return out
    }

    /// Marks a hook this tool wrote, so it can be rewritten without `--force`.
    public static let hookMarker = "# installed by latchkey scan --install-hook"

    /// The pre-commit hook: refuses a commit whose staged env files add plain values that equal stored items or look
    /// secret. Skip it for one commit with `git commit --no-verify`.
    public static let hook = """
    #!/bin/sh
    \(hookMarker)
    lk=$(command -v lk || command -v latchkey)
    if [ -z "$lk" ]; then
        echo "latchkey: not found on PATH; staged env files were not scanned" >&2
        exit 0
    fi
    exec "$lk" scan --staged

    """
}
