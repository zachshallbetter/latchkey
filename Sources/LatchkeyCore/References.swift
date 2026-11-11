import Foundation

/// `latchkey://NAME` inside an environment value stands for the secret NAME.
public enum References {
    public static let scheme = "latchkey://"

    private static let pattern = try! NSRegularExpression(pattern: "latchkey://([A-Za-z0-9_.-]+)")

    public static func names(in value: String) -> [String] {
        let ns = value as NSString
        return pattern.matches(in: value, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }

    public static func names(in env: [String: String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for key in env.keys.sorted() {
            for name in names(in: env[key]!) where seen.insert(name).inserted { out.append(name) }
        }
        return out
    }

    public static func resolve(_ value: String, with values: [String: String]) -> String {
        let ns = value as NSString
        var out = ""
        var last = 0
        for m in pattern.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            out += values[name] ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    public static func resolve(env: [String: String], with values: [String: String]) -> [String: String] {
        env.mapValues { $0.contains(scheme) ? resolve($0, with: values) : $0 }
    }
}

/// A plain KEY=VALUE file: comments, blank lines, `export`, single and double quotes.
public enum EnvFile {
    public static func parse(_ text: String) -> [(key: String, value: String)] {
        var out: [(String, String)] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\\"", with: "\"")
            } else if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast())
            } else if let hash = value.range(of: " #") {
                value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            out.append((key, value))
        }
        return out
    }

    public static func load(_ path: String) throws -> [(key: String, value: String)] {
        parse(try String(contentsOfFile: path, encoding: .utf8))
    }
}
