import CryptoKit
import Foundation

/// Short-lived AWS credentials for one run. The long-lived access key stays in Latchkey; the command gets a session
/// key from STS that expires (15 minutes by default), from GetSessionToken or, with a role, AssumeRole.
public enum AWSSTS {
    public struct Credentials: Equatable, Sendable {
        public var accessKeyID: String
        public var secretAccessKey: String
        public var sessionToken: String
        public var expiration: String
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case aws(code: String, message: String)
        case unreadable
        case network(String)

        public var description: String {
            switch self {
            case .aws(let code, let message): return "AWS refused: \(code): \(message)"
            case .unreadable: return "AWS's answer wasn't the credentials it should have been"
            case .network(let m): return "couldn't reach AWS STS: \(m)"
            }
        }
    }

    static let endpoint = URL(string: "https://sts.amazonaws.com/")!
    /// STS allows 15 minutes to 12 hours for a role, up to 36 hours for a session token; Latchkey stays within 12.
    public static let shortest: TimeInterval = 900
    public static let longest: TimeInterval = 12 * 3600

    /// The form body for GetSessionToken, or AssumeRole when `role` is given.
    static func body(role: String?, duration: TimeInterval, sessionName: String) -> String {
        let seconds = Int(min(max(duration, shortest), longest))
        var fields: [(String, String)] = [("Version", "2011-06-15"), ("DurationSeconds", String(seconds))]
        if let role {
            fields += [("Action", "AssumeRole"), ("RoleArn", role), ("RoleSessionName", sessionName)]
        } else {
            fields += [("Action", "GetSessionToken")]
        }
        return fields.sorted { $0.0 < $1.0 }.map { "\($0.0)=\(formEncode($0.1))" }.joined(separator: "&")
    }

    /// Asks STS for credentials, signing with the long-lived key. Times out after 20 seconds.
    public static func mint(accessKeyID: String, secret: String, role: String?, duration: TimeInterval,
                            sessionName: String = "latchkey", now: Date = Date()) -> Result<Credentials, Failure> {
        let form = body(role: role, duration: duration, sessionName: sessionName)
        var req = URLRequest(url: endpoint, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.httpBody = Data(form.utf8)
        for (k, v) in SigV4.headers(method: "POST", host: "sts.amazonaws.com", path: "/", body: Data(form.utf8),
                                    contentType: "application/x-www-form-urlencoded; charset=utf-8",
                                    accessKeyID: accessKeyID, secret: secret, region: "us-east-1", service: "sts", now: now) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Result<Credentials, Failure> = .failure(.network("no answer"))
        URLSession(configuration: .ephemeral).dataTask(with: req) { data, _, error in
            if let error { outcome = .failure(.network(error.localizedDescription)) }
            else if let data, data.count < 64 * 1024 { outcome = parse(String(decoding: data, as: UTF8.self)) }
            else { outcome = .failure(.unreadable) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 25)
        return outcome
    }

    /// Credentials from an STS answer, or the error it carries.
    static func parse(_ xml: String) -> Result<Credentials, Failure> {
        func tag(_ name: String) -> String? {
            guard let a = xml.range(of: "<\(name)>"), let b = xml.range(of: "</\(name)>", range: a.upperBound..<xml.endIndex) else { return nil }
            return String(xml[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let code = tag("Code") { return .failure(.aws(code: code, message: tag("Message") ?? "")) }
        guard let id = tag("AccessKeyId"), let secret = tag("SecretAccessKey"), let token = tag("SessionToken"),
              let expiration = tag("Expiration"), id.hasPrefix("ASIA"), !secret.isEmpty, !token.isEmpty else { return .failure(.unreadable) }
        return .success(Credentials(accessKeyID: id, secretAccessKey: secret, sessionToken: token, expiration: expiration))
    }

    static func formEncode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// AWS Signature Version 4, for one request with no query string.
public enum SigV4 {
    static func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static func sha256(_ d: Data) -> String { hex(SHA256.hash(data: d)) }
    static func hmac(_ key: Data, _ text: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key))) }

    /// kSigning = HMAC(HMAC(HMAC(HMAC("AWS4" + secret, date), region), service), "aws4_request").
    public static func signingKey(secret: String, date: String, region: String, service: String) -> Data {
        let kDate = hmac(Data(("AWS4" + secret).utf8), date)
        return hmac(hmac(hmac(kDate, region), service), "aws4_request")
    }

    /// The headers to add: Host, X-Amz-Date, Content-Type (if any) and Authorization.
    public static func headers(method: String, host: String, path: String, query: String = "", body: Data, contentType: String?,
                               accessKeyID: String, secret: String, region: String, service: String, now: Date) -> [String: String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = f.string(from: now)
        let date = String(amzDate.prefix(8))
        var signed: [(String, String)] = [("host", host), ("x-amz-date", amzDate)]
        if let contentType { signed.append(("content-type", contentType)) }
        signed.sort { $0.0 < $1.0 }
        let canonicalHeaders = signed.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = signed.map(\.0).joined(separator: ";")
        let canonical = [method, path, query, canonicalHeaders, signedHeaders, sha256(body)].joined(separator: "\n")
        let scope = "\(date)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256(Data(canonical.utf8))].joined(separator: "\n")
        let signature = hex(hmac(signingKey(secret: secret, date: date, region: region, service: service), toSign))
        var out = ["Host": host, "X-Amz-Date": amzDate,
                   "Authorization": "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"]
        if let contentType { out["Content-Type"] = contentType }
        return out
    }
}
