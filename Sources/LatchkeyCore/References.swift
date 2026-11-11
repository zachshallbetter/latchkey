import Foundation

/// `latchkey://NAME` or `latchkey://project/environment/NAME` inside an environment value stands for that item.
public enum References {
    public static let scheme = "latchkey://"

    private static let pattern = try! NSRegularExpression(
        pattern: "latchkey://((?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/)?[A-Za-z0-9_.-]+)")

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

    /// The same text with each `latchkey://OLD` reference whose id is in `renames` pointing at the new id.
    public static func renaming(_ text: String, _ renames: [String: String]) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range(at: 1))
            guard let new = renames[id] else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + scheme + new
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// `latchkey-file://ID` as a whole value: the command gets the path of a temporary file holding the value,
    /// for tools that want a file (a .p8 key, a service-account JSON).
    public static let fileScheme = "latchkey-file://"

    /// Variables whose whole value is a file reference → the item id.
    public static func fileReferences(in env: [String: String]) -> [String: String] {
        env.compactMapValues { v in
            guard v.hasPrefix(fileScheme) else { return nil }
            let id = String(v.dropFirst(fileScheme.count))
            return Wire.isValidName(id) ? id : nil
        }
    }

    public static func resolve(env: [String: String], with values: [String: String]) -> [String: String] {
        env.mapValues { $0.contains(scheme) ? resolve($0, with: values) : $0 }
    }
}

/// A plain KEY=VALUE file: comments, blank lines, `export`, single and double quotes.
public enum EnvFile {
    public static func parse(_ text: String) -> [(key: String, value: String)] {
        lines(text).compactMap(parseLine)
    }

    public static func load(_ path: String) throws -> [(key: String, value: String)] {
        parse(try String(contentsOfFile: path, encoding: .utf8))
    }

    /// The same text with each KEY in `references` set to `latchkey://` plus its item id. Comments, order, blank
    /// lines, `export`, indentation and line endings are kept; every other line is untouched.
    public static func rewrite(_ text: String, toReferences references: [String: String]) -> String {
        let out = lines(text).map { line -> String in
            guard let (key, _) = parseLine(line), let id = references[key] else { return String(line) }
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let body = line.drop { $0 == " " || $0 == "\t" }
            let export = body.hasPrefix("export ") ? "export " : ""
            return "\(indent)\(export)\(key)=\(References.scheme)\(id)"
        }
        return out.joined(separator: text.contains("\r\n") ? "\r\n" : "\n")
    }

    /// Rewrites the file in place (atomically), keeping its permissions.
    public static func rewriteFile(at url: URL, original text: String, toReferences references: [String: String]) throws {
        try write(rewrite(text, toReferences: references), to: url)
    }

    /// Points `latchkey://OLD` references in a file at new ids, keeping its permissions. False if nothing changed.
    @discardableResult
    public static func renameReferences(in url: URL, _ renames: [String: String]) throws -> Bool {
        let text = try String(contentsOf: url, encoding: .utf8)
        let new = References.renaming(text, renames)
        guard new != text else { return false }
        try write(new, to: url)
        return true
    }

    private static func write(_ text: String, to url: URL) throws {
        let perms = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        try Data(text.utf8).write(to: url, options: .atomic)
        if let perms { try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path) }
    }

    private static func lines(_ text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
    }

    static func parseLine(_ raw: Substring) -> (key: String, value: String)? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { return nil }
        if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
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
        return (key, value)
    }
}
