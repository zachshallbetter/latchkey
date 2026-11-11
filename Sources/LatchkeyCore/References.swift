import Darwin
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

/// Literal KEY=VALUE files, including quoted multiline values. Unsupported or malformed syntax is refused
/// before import or rewrite; diagnostics contain line numbers only, never the offending text.
public enum EnvFile {
    public enum ParseError: Error, LocalizedError {
        case malformed(line: Int)
        case changed

        public var errorDescription: String? {
            switch self {
            case .malformed(let line): return "Invalid .env syntax at line \(line). Use KEY=VALUE, with quotes around multiline values."
            case .changed: return "The file changed since it was read. Values were saved, but the file was not rewritten; review it and import again."
            }
        }
    }

    public enum ExportError: Error, LocalizedError {
        case symbolicLink(String)
        case notAFile(String)
        case exists(String)
        case noFolder(String)
        case write(String, Int32)

        public var errorDescription: String? {
            switch self {
            case .symbolicLink(let p): return "\(p) is a symbolic link; write to the file itself"
            case .notAFile(let p): return "\(p) isn't a regular file"
            case .exists(let p): return "\(p) already exists"
            case .noFolder(let p): return "no folder \(p)"
            case .write(let p, let e): return "couldn't write \(p): \(String(cString: strerror(e)))"
            }
        }
    }

    /// A value as this parser reads it back: bare when that's unambiguous, else double-quoted with `\`, `"`, newlines,
    /// carriage returns and tabs escaped.
    public static func quoted(_ value: String) -> String {
        let bare = value.unicodeScalars.allSatisfy { c in
            (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || "_-./:@%+,=".unicodeScalars.contains(c)
        }
        if bare { return value }
        var out = "\""
        for c in value {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out + "\""
    }

    /// The file at `path` lstat'd: nil if there's nothing there. A symbolic link or anything but a regular file is
    /// refused, so a write can never land somewhere the path doesn't name.
    public static func existingFile(_ path: String) throws -> stat? {
        var st = stat()
        if lstat(path, &st) != 0 { return nil }
        if (st.st_mode & S_IFMT) == S_IFLNK { throw ExportError.symbolicLink(path) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw ExportError.notAFile(path) }
        return st
    }

    /// Writes `text` to `path` in one step: a new owner-only file beside it is written, synced and given `mode`, then
    /// renamed into place. Without `replace`, an existing file is left alone; with it, the old file stays whole until
    /// the rename. Nothing at `path` is opened, truncated or followed.
    public static func writeAtomically(_ text: String, to path: String, mode: mode_t, replace: Bool) throws {
        let url = URL(fileURLWithPath: path)
        let folder = url.deletingLastPathComponent().path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else { throw ExportError.noFolder(folder) }
        if try existingFile(path) != nil, !replace { throw ExportError.exists(path) }
        let temp = folder + "/.latchkey-" + UUID().uuidString
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ExportError.write(path, errno) }
        defer { unlink(temp) }
        let data = Data(text.utf8)
        let ok = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return fsync(fd) == 0 && fchmod(fd, mode) == 0
        }
        let err = errno
        close(fd)
        guard ok else { throw ExportError.write(path, err) }
        // Checked again right before the rename: a link put there meanwhile is refused, not replaced.
        if try existingFile(path) != nil, !replace { throw ExportError.exists(path) }
        let flags: UInt32 = replace ? 0 : UInt32(RENAME_EXCL)
        guard renamex_np(temp, path, flags) == 0 else {
            let e = errno
            throw e == EEXIST ? ExportError.exists(path) : ExportError.write(path, e)
        }
    }

    private struct Line {
        var content: String
        var ending: String
        var raw: String { content + ending }
    }
    private struct Entry {
        var key: String
        var value: String
        var first: Int
        var last: Int
        var prefix: String
    }

    public static func parse(_ text: String) throws -> [(key: String, value: String)] {
        try entries(lines(text)).map { ($0.key, $0.value) }
    }

    public static func load(_ path: String) throws -> [(key: String, value: String)] {
        try parse(String(contentsOfFile: path, encoding: .utf8))
    }

    /// Replaces the entire assignment, including every physical line of a multiline value. Other lines and
    /// their original line endings stay byte-for-byte unchanged.
    public static func rewrite(_ text: String, toReferences references: [String: String]) throws -> String {
        let physical = lines(text)
        let assignments = try entries(physical)
        let byStart = Dictionary(uniqueKeysWithValues: assignments.map { ($0.first, $0) })
        var result = "", i = 0
        while i < physical.count {
            if let entry = byStart[i], let id = references[entry.key] {
                result += entry.prefix + References.scheme + id + physical[entry.last].ending
                i = entry.last + 1
            } else { result += physical[i].raw; i += 1 }
        }
        return result
    }

    public static func rewriteFile(at url: URL, original text: String, toReferences references: [String: String]) throws {
        let rewritten = try rewrite(text, toReferences: references)
        try coordinatedWrite(to: url) { target in
            guard try Data(contentsOf: target) == Data(text.utf8) else { throw ParseError.changed }
            try write(rewritten, to: target, expected: Data(text.utf8))
        }
    }

    @discardableResult
    public static func renameReferences(in url: URL, _ renames: [String: String]) throws -> Bool {
        let text = try String(contentsOf: url, encoding: .utf8)
        let new = References.renaming(text, renames)
        guard new != text else { return false }
        try coordinatedWrite(to: url) { target in
            guard try Data(contentsOf: target) == Data(text.utf8) else { throw ParseError.changed }
            try write(new, to: target, expected: Data(text.utf8))
        }
        return true
    }

    /// Participate in document coordination for user-selected files, including files in cloud-backed folders.
    private static func coordinatedWrite(to url: URL, operation: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try operation(target) } catch { operationError = error }
        }
        if let error = coordinationError { throw error }
        if let error = operationError { throw error }
    }

    private static func write(_ text: String, to url: URL, expected: Data) throws {
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        let temp = url.deletingLastPathComponent().appendingPathComponent(".latchkey-" + UUID().uuidString)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temp) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(text.utf8))
            try handle.synchronize()
            try handle.close()
        } catch { try? handle.close(); throw error }
        if let perms { try FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: temp.path) }
        // Check again immediately before replacement, after the temporary file is fully prepared.
        guard try Data(contentsOf: url) == expected else { throw ParseError.changed }
        guard rename(temp.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func lines(_ text: String) -> [Line] {
        var result: [Line] = [], start = text.startIndex
        for i in text.indices where text[i].isNewline {
            result.append(Line(content: String(text[start..<i]), ending: String(text[i])))
            start = text.index(after: i)
        }
        if start < text.endIndex { result.append(Line(content: String(text[start...]), ending: "")) }
        return result
    }

    private static func entries(_ lines: [Line]) throws -> [Entry] {
        var result: [Entry] = [], i = 0
        while i < lines.count {
            let first = i, raw = lines[i].content
            var body = raw.trimmingCharacters(in: .whitespaces)
            if body.isEmpty || body.hasPrefix("#") { i += 1; continue }
            var exported = false
            if body.hasPrefix("export"), body.count > 6, body[body.index(body.startIndex, offsetBy: 6)].isWhitespace {
                exported = true
                body = String(body.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            guard let eq = body.firstIndex(of: "=") else { throw ParseError.malformed(line: first + 1) }
            let key = body[..<eq].trimmingCharacters(in: .whitespaces)
            let asciiLetters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"
            guard let initial = key.first, asciiLetters.contains(initial),
                  key.allSatisfy({ asciiLetters.contains($0) || "0123456789".contains($0) }) else {
                throw ParseError.malformed(line: first + 1)
            }
            var tail = String(body[body.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            var value = ""
            if let quote = tail.first, quote == "\"" || quote == "'" {
                tail.removeFirst()
                var closed = false, escaped = false
                while !closed {
                    var cursor = tail.startIndex
                    while cursor < tail.endIndex {
                        let c = tail[cursor]
                        cursor = tail.index(after: cursor)
                        if escaped {
                            switch c {
                            case "n": value += "\n"
                            case "r": value += "\r"
                            case "t": value += "\t"
                            case "\"", "\\": value.append(c)
                            default: value += "\\"; value.append(c)
                            }
                            escaped = false
                        } else if quote == "\"", c == "\\" { escaped = true }
                        else if c == quote {
                            let remainder = tail[cursor...].trimmingCharacters(in: .whitespaces)
                            guard remainder.isEmpty || remainder.hasPrefix("#") else { throw ParseError.malformed(line: first + 1) }
                            closed = true
                            break
                        } else { value.append(c) }
                    }
                    if !closed {
                        guard i + 1 < lines.count else { throw ParseError.malformed(line: first + 1) }
                        // A backslash at a line boundary is preserved literally; no shell continuation/expansion.
                        if escaped { value += "\\"; escaped = false }
                        value += lines[i].ending
                        i += 1
                        tail = lines[i].content
                    }
                }
            } else {
                if let hash = tail.indices.first(where: { tail[$0] == "#" && ($0 == tail.startIndex || tail[tail.index(before: $0)].isWhitespace) }) {
                    tail = String(tail[..<hash]).trimmingCharacters(in: .whitespaces)
                }
                value = tail
            }
            let indent = raw.prefix { $0 == " " || $0 == "\t" }
            result.append(Entry(key: key, value: value, first: first, last: i, prefix: String(indent) + (exported ? "export " : "") + key + "="))
            i += 1
        }
        return result
    }
}
