import CryptoKit
import Foundation
import Security

/// Grants a coordinator agent arranges through ACP instead of the owner approving each one.
/// See docs/internal/acp-grants.md for the contract with acp-gateway.
///
/// ACP decides whether a sub-agent may read some items for a repository and a ticket, and issues a capability
/// signed with its Latchkey key (Ed25519, so Latchkey can check a signature but never make one). Latchkey checks it
/// against limits the owner set once, asks ACP whether it's still valid, and turns it into an ordinary grant.
public enum Acp {
    /// The owner's standing decision to accept ACP capabilities, and its limits. Kept per Mac.
    public struct Trust: Codable, Equatable, Sendable {
        /// The deployment's base URL, for `/internal/verify-capability`.
        public var url: String
        /// The capability `kid` this key answers to.
        public var keyID: String
        /// Ed25519 public key, raw 32 bytes, base64.
        public var publicKey: String
        /// The Latchkey item holding ACP's gateway bearer token, used for the validity check.
        public var gatewayTokenItem: String
        /// Environments ACP may grant (an entry's environment part, compared after any `service.` prefix).
        public var environments: [String]
        /// Longest grant ACP may make, in seconds.
        public var maxDuration: TimeInterval
        public var trustedAt: Date

        public init(url: String, keyID: String, publicKey: String, gatewayTokenItem: String,
                    environments: [String] = ["development", "preview"], maxDuration: TimeInterval = 7200, trustedAt: Date = Date()) {
            self.url = url
            self.keyID = keyID
            self.publicKey = publicKey
            self.gatewayTokenItem = gatewayTokenItem
            self.environments = environments
            self.maxDuration = maxDuration
            self.trustedAt = trustedAt
        }

        /// What's wrong with this trust record, or nil.
        public var problem: String? {
            guard let u = URL(string: url), u.scheme == "https", u.host != nil else { return "the ACP URL must be https://…" }
            guard let raw = Data(base64Encoded: publicKey), raw.count == 32,
                  (try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil else { return "the public key must be a base64 Ed25519 key (32 bytes)" }
            if keyID.isEmpty { return "the key id is missing" }
            if !Wire.isValidName(gatewayTokenItem) { return "the gateway token item must be an item ID" }
            if environments.isEmpty { return "allow at least one environment" }
            if environments.contains(where: { Acp.isProductionLike($0) }) { return "ACP grants never cover production" }
            if maxDuration <= 0 || maxDuration > GrantStore.longest { return "the longest grant must be under 7 days" }
            return nil
        }
    }

    /// The signed part of a capability.
    public struct Claims: Codable, Equatable, Sendable {
        public struct Repository: Codable, Equatable, Sendable {
            public var owner: String
            public var name: String
        }
        public var v: Int
        public var aud: String
        public var kid: String
        public var jti: String
        public var iat: Double
        /// Redeem by (seconds since 1970).
        public var exp: Double
        /// The agent the grant is for.
        public var sub: String
        /// The coordinator that delegated it.
        public var act: String
        public var ticket: String
        public var repository: Repository
        /// Item ids or `project/environment/*` patterns. Never a whole project.
        public var items: [String]
        /// How long the grant lasts once redeemed, in seconds.
        public var duration: Double
        public var requestID: String?

        enum CodingKeys: String, CodingKey {
            case v, aud, kid, jti, iat, exp, sub, act, ticket, repository, items, duration
            case requestID = "request_id"
        }
    }

    public enum Refusal: Error, CustomStringConvertible, Equatable {
        case notTrusted, malformed, signature, audience, keyID, expired, replayed
        case outsideLimits(String), repository(String), notValid(String), unreachable(String)

        public var description: String {
            switch self {
            case .notTrusted: return "ACP isn't trusted on this Mac (latchkey acp trust)"
            case .malformed: return "not a Latchkey capability"
            case .signature: return "the signature doesn't verify with the trusted ACP key"
            case .audience: return "the capability isn't addressed to Latchkey"
            case .keyID: return "the capability was signed with a different ACP key"
            case .expired: return "the capability has expired; ask ACP for a new one"
            case .replayed: return "the capability was already used"
            case .outsideLimits(let why): return "outside what ACP may grant here: \(why)"
            case .repository(let why): return "wrong repository: \(why)"
            case .notValid(let reason): return "ACP says it's no longer valid (\(reason))"
            case .unreachable(let why): return "couldn't confirm with ACP (\(why)); try again when it's reachable"
            }
        }
    }

    static func isProductionLike(_ env: String) -> Bool {
        let instance = env.split(separator: ".").last.map { $0.lowercased() } ?? env.lowercased()
        return instance.contains("prod") || instance == "live"
    }

    static func b64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func unb64url(_ s: Substring) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    /// Parses and checks a capability's signature, audience, key and expiry. Limits, repository, replay and the
    /// online check come after, in `Broker`.
    public static func verify(_ token: String, trust: Trust, now: Date = Date()) throws -> Claims {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 2, let payload = unb64url(parts[0]), let signature = unb64url(parts[1]) else { throw Refusal.malformed }
        guard let raw = Data(base64Encoded: trust.publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              key.isValidSignature(signature, for: payload) else { throw Refusal.signature }
        guard let claims = try? JSONDecoder().decode(Claims.self, from: payload), claims.v == 1 else { throw Refusal.malformed }
        guard claims.aud == "latchkey" else { throw Refusal.audience }
        guard claims.kid == trust.keyID else { throw Refusal.keyID }
        guard Date(timeIntervalSince1970: claims.exp) > now else { throw Refusal.expired }
        return claims
    }

    /// Every entry must name an environment ACP may grant: an item id or `project/environment/*`, never production.
    public static func checkLimits(_ claims: Claims, trust: Trust) throws {
        guard !claims.items.isEmpty else { throw Refusal.outsideLimits("no items") }
        for entry in claims.items {
            let env: String
            if Grant.isPattern(entry) {
                let parts = entry.dropLast(2).split(separator: "/").map(String.init)
                guard parts.count == 2 else { throw Refusal.outsideLimits("\(entry) covers a whole project; name an environment") }
                env = parts[1]
            } else if let id = ItemID(entry), !id.isShared {
                env = id.environment
            } else {
                throw Refusal.outsideLimits("\(entry) isn't a project item or pattern")
            }
            let instance = env.split(separator: ".").last.map(String.init) ?? env
            if isProductionLike(env) || !(trust.environments.contains(env) || trust.environments.contains(instance)) {
                throw Refusal.outsideLimits("\(entry) is in \(env), and ACP may grant only \(trust.environments.joined(separator: ", "))")
            }
        }
        guard claims.duration > 0 else { throw Refusal.outsideLimits("no duration") }
    }

    /// The GitHub owner/name of a repository's `origin`, read from its git config.
    public static func originRepository(commonDir: String) -> (owner: String, name: String)? {
        guard let config = try? String(contentsOfFile: commonDir + "/config", encoding: .utf8) else { return nil }
        var inOrigin = false
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inOrigin = line == #"[remote "origin"]"#; continue }
            guard inOrigin, line.hasPrefix("url") , let eq = line.firstIndex(of: "=") else { continue }
            var url = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if url.hasSuffix(".git") { url = String(url.dropLast(4)) }
            // https://github.com/owner/name or git@github.com:owner/name
            let tail = url.replacingOccurrences(of: ":", with: "/").split(separator: "/").suffix(2).map(String.init)
            if tail.count == 2 { return (tail[0], tail[1]) }
        }
        return nil
    }

    /// Makes a capability. Tests only: in use, only ACP holds a signing key.
    public static func sign(_ claims: Claims, with key: Curve25519.Signing.PrivateKey) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let payload = try enc.encode(claims)
        return b64url(payload) + "." + b64url(try key.signature(for: payload))
    }
}

// MARK: - storage

/// Where the trust record lives. In the app: the data-protection keychain, in the app's access group and not
/// synced, so only the signed app can write it and trusting ACP on one Mac doesn't reach another.
public protocol AcpTrustStore: AnyObject, Sendable {
    func load() -> Acp.Trust?
    func save(_ trust: Acp.Trust?) throws
    /// Redeemed capability ids and when they stop mattering (their redeem-by time).
    func used() -> [String: Date]
    func markUsed(_ jti: String, until: Date) throws
}

extension AcpTrustStore {
    /// The gateway token the validity check sends to ACP, from the owner's item. Nil when the item is missing.
    func gatewayToken(_ items: SecretStore, _ id: String) throws -> String? { try items.values([id])[id] }
}

public final class KeychainAcpTrustStore: AcpTrustStore, @unchecked Sendable {
    static let service = "latchkey.acp"
    let items: KeychainStore

    /// Nil outside the data-protection keychain: a file or the login keychain could be edited by any program
    /// running as the owner, including an agent, which could then trust its own key.
    public init?(mode: KeychainStore.Mode) {
        guard case .iCloud = mode else { return nil }
        items = KeychainStore(mode: mode)
    }

    private func query(_ account: String) -> [String: Any] {
        var q = items.query(account, service: Self.service)
        q[kSecAttrSynchronizable as String] = false
        return q
    }

    private func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    private func write(_ account: String, _ data: Data?) throws {
        let q = query(account)
        guard let data else {
            let s = SecItemDelete(q as CFDictionary)
            guard s == errSecSuccess || s == errSecItemNotFound else { throw StoreError.keychain("forget ACP trust", s) }
            return
        }
        var s = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if s == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            s = SecItemAdd(add as CFDictionary, nil)
        }
        guard s == errSecSuccess else { throw StoreError.keychain("save ACP trust", s) }
    }

    public func load() -> Acp.Trust? { read("trust").flatMap { try? Wire.decoder().decode(Acp.Trust.self, from: $0) } }
    public func save(_ trust: Acp.Trust?) throws { try write("trust", try trust.map { try Wire.encoder().encode($0) }) }
    public func used() -> [String: Date] { read("used").flatMap { try? Wire.decoder().decode([String: Date].self, from: $0) } ?? [:] }
    public func markUsed(_ jti: String, until: Date) throws {
        let now = Date()
        var u = used().filter { $0.value > now }
        u[jti] = until
        try write("used", try Wire.encoder().encode(u))
    }
}

public final class MemoryAcpTrustStore: AcpTrustStore, @unchecked Sendable {
    private var trust: Acp.Trust?
    private var usedIDs: [String: Date] = [:]
    private let lock = NSLock()
    public init(_ trust: Acp.Trust? = nil) { self.trust = trust }
    public func load() -> Acp.Trust? { lock.withLock { trust } }
    public func save(_ t: Acp.Trust?) throws { lock.withLock { trust = t } }
    public func used() -> [String: Date] { lock.withLock { usedIDs } }
    public func markUsed(_ jti: String, until: Date) throws { lock.withLock { usedIDs[jti] = until } }
}

// MARK: - asking ACP

/// Asks ACP whether a capability is still valid (and, on its side, consumes it).
public protocol AcpVerifier: Sendable {
    /// `.success(nil)` when valid, `.success(reason)` when ACP says no, `.failure` when ACP can't be reached.
    func check(_ token: String, trust: Acp.Trust, bearer: String) -> Result<String?, Error>
}

public struct HTTPAcpVerifier: AcpVerifier {
    public init() {}

    public func check(_ token: String, trust: Acp.Trust, bearer: String) -> Result<String?, Error> {
        guard let url = URL(string: trust.url)?.appendingPathComponent("internal/verify-capability") else {
            return .failure(Acp.Refusal.unreachable("bad URL"))
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["capability_token": token])
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<String?, Error> = .failure(Acp.Refusal.unreachable("no answer"))
        URLSession.shared.dataTask(with: req) { data, response, error in
            defer { done.signal() }
            if let error { result = .failure(Acp.Refusal.unreachable(error.localizedDescription)); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, data.count <= 16_384,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let valid = json["valid"] as? Bool else {
                result = .failure(Acp.Refusal.unreachable("unexpected response (HTTP \(status))"))
                return
            }
            result = .success(valid ? nil : (json["reason"] as? String ?? "INVALID"))
        }.resume()
        if done.wait(timeout: .now() + 12) == .timedOut { return .failure(Acp.Refusal.unreachable("timed out")) }
        return result
    }
}
