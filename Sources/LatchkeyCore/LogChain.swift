import CryptoKit
import Foundation
import Security

/// Makes the access log tamper-evident. Each entry carries the MAC of the one before it (`prev`) and its own
/// (`mac`, HMAC-SHA256 over the entry's canonical JSON without `mac`). The key, and the MAC and count of the latest
/// entry, live where only Latchkey can reach them, so an edited, removed or truncated entry shows on verification.
public protocol LogKeyStore: Sendable {
    /// The MAC key, made on first use.
    func key() -> SymmetricKey?
    func head() -> LogHead?
    func setHead(_ head: LogHead)
}

/// The latest signed entry: its MAC and how many signed entries the log holds.
public struct LogHead: Codable, Sendable, Equatable {
    public var mac: String
    public var count: Int
}

public enum LogChain {
    /// HMAC-SHA256 of the entry with `mac` left out, over the same sorted-keys JSON the log is written in.
    public static func mac(_ entry: Broker.LogEntry, key: SymmetricKey) -> String {
        var unsigned = entry
        unsigned.mac = nil
        let data = (try? Wire.encoder().encode(unsigned)) ?? Data()
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: key)).map { String(format: "%02x", $0) }.joined()
    }

    public enum Verdict: Equatable {
        case intact(signed: Int, unsigned: Int)
        case broken(line: Int, reason: String)
    }

    /// Checks every signed entry's MAC and link, then that the last one is the head kept apart from the file.
    /// Entries written before signing began (no `mac`) are counted, not checked; one after a signed entry is a break.
    public static func verify(_ url: URL, keys: LogKeyStore) -> Verdict {
        guard let key = keys.key() else { return .broken(line: 0, reason: "no log key: this copy of Latchkey can't check the log") }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let dec = Wire.decoder()
        var prev: String?
        var signed = 0, unsigned = 0
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let entry = try? dec.decode(Broker.LogEntry.self, from: Data(line.utf8)) else {
                return .broken(line: i + 1, reason: "not a log entry")
            }
            guard let mac = entry.mac else {
                if signed > 0 { return .broken(line: i + 1, reason: "an unsigned entry after signed ones") }
                unsigned += 1
                continue
            }
            guard mac == Self.mac(entry, key: key) else { return .broken(line: i + 1, reason: "changed after it was written") }
            guard entry.prev == prev else { return .broken(line: i + 1, reason: "an entry before it is missing or out of order") }
            prev = mac
            signed += 1
        }
        if let head = keys.head() {
            guard head.count == signed, head.mac == prev else {
                return .broken(line: signed + unsigned, reason: "entries at the end are missing (\(head.count) signed entries were written, \(signed) remain)")
            }
        } else if signed > 0 {
            return .broken(line: signed + unsigned, reason: "the log's head is missing")
        }
        return .intact(signed: signed, unsigned: unsigned)
    }
}

/// The key and head in two keychain items only Latchkey can read or change, on this Mac only.
public final class KeychainLogKeyStore: LogKeyStore, @unchecked Sendable {
    static let keyService = "latchkey.logkey"
    static let headService = "latchkey.loghead"
    let items: KeychainStore
    private let lock = NSLock()
    private var cached: SymmetricKey?

    public init(mode: KeychainStore.Mode) { items = KeychainStore(mode: mode) }

    public func key() -> SymmetricKey? {
        lock.withLock {
            if let cached { return cached }
            if let data = read(Self.keyService) { cached = SymmetricKey(data: data); return cached }
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
            guard write(Self.keyService, Data(bytes), label: "Latchkey log key") else { return nil }
            cached = SymmetricKey(data: Data(bytes))
            return cached
        }
    }

    public func head() -> LogHead? {
        read(Self.headService).flatMap { try? JSONDecoder().decode(LogHead.self, from: $0) }
    }

    public func setHead(_ head: LogHead) {
        guard let data = try? JSONEncoder().encode(head) else { return }
        _ = write(Self.headService, data, label: "Latchkey log head")
    }

    private func read(_ service: String) -> Data? {
        var q = items.query("log", service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    private func write(_ service: String, _ data: Data, label: String) -> Bool {
        let q = items.query("log", service: service)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        if case .iCloud = items.mode { add[kSecAttrSynchronizable as String] = false }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// For tests and the windowless broker.
public final class MemoryLogKeyStore: LogKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private let k = SymmetricKey(size: .bits256)
    private var h: LogHead?
    public init() {}
    public func key() -> SymmetricKey? { k }
    public func head() -> LogHead? { lock.withLock { h } }
    public func setHead(_ head: LogHead) { lock.withLock { h = head } }
}

/// Keeps likely secrets out of command lines written to the log or shown in the system sheet: the value after a
/// flag such as --token or --password, NAME=VALUE where NAME says it's secret, Authorization headers, values with
/// a known token prefix, and long random-looking strings.
public enum Redact {
    static let secretFlags: Set<String> = ["--token", "--password", "--passwd", "--secret", "--api-key", "--apikey", "--key",
                                           "-p", "--auth", "--access-token", "--client-secret", "-u", "--user"]
    static let secretNames = ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "API_KEY", "APIKEY", "PRIVATE", "CREDENTIAL", "AUTH"]
    public static let mask = "<redacted>"

    public static func arguments(_ args: [String]) -> [String] {
        var out: [String] = []
        var hideNext = false
        for a in args {
            if hideNext { out.append(mask); hideNext = false; continue }
            if secretFlags.contains(a.lowercased()) { out.append(a); hideNext = true; continue }
            if let eq = a.firstIndex(of: "="), a.hasPrefix("-") || a.first?.isUppercase == true {
                let name = a[..<eq].uppercased(), value = a[a.index(after: eq)...]
                if secretFlags.contains(String(a[..<eq]).lowercased()) || secretNames.contains(where: { name.contains($0) }) || looksSecret(String(value)) {
                    out.append(String(a[...eq]) + mask)
                    continue
                }
            }
            if a.lowercased().hasPrefix("authorization:") || a.lowercased().hasPrefix("bearer ") { out.append(mask); continue }
            out.append(looksSecret(a) ? mask : redactURLs(a))
        }
        return out
    }

    /// URL credentials can occur inside an assignment or a shell argument, so redact them wherever they appear.
    private static let urlCredentials = try! NSRegularExpression(pattern: "([A-Za-z][A-Za-z0-9+.-]*://)[^\\s/@]*:[^\\s/@]*@")
    private static let urlSecrets = try! NSRegularExpression(pattern: "(?i)([?&](?:token|access_token|api_key|apikey|secret|password)=)[^&#\\s]*")

    private static func redactURLs(_ text: String) -> String {
        let credentials = urlCredentials.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                                  withTemplate: "$1<redacted>@")
        return urlSecrets.stringByReplacingMatches(in: credentials, range: NSRange(credentials.startIndex..., in: credentials),
                                                   withTemplate: "$1<redacted>")
    }

    /// A known token prefix, or 24+ characters of letters, digits and _-+/= with both letters and digits and no
    /// path or URL punctuation.
    static func looksSecret(_ s: String) -> Bool {
        if Services.valuePrefixes.contains(where: { s.hasPrefix($0.0) }) && s.count >= 12 { return true }
        guard s.count >= 24, !s.contains("/") || s.hasSuffix("=") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-+/="))
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return s.contains(where: \.isNumber) && s.contains(where: \.isLetter)
    }
}
