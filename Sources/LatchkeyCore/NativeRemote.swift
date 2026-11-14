import Foundation

// Pushing straight to each service's HTTPS API with an access token the user keeps as an ordinary Latchkey item,
// for the sandboxed App Store build (which can't run `vercel`, `gh`, `railway` or `flyctl`) and for anyone who
// links a token item in the direct build.
//
// APIs relied on (checked 2026-11-13):
//   Vercel   https://vercel.com/docs/rest-api/reference/endpoints/projects/create-one-or-more-environment-variables
//            https://vercel.com/docs/rest-api/reference/endpoints/projects/retrieve-the-environment-variables-of-a-project-by-id-or-name
//   GitHub   https://docs.github.com/en/rest/actions/secrets
//            https://docs.github.com/en/rest/guides/encrypting-secrets-for-the-rest-api   (libsodium sealed box, base64)
//   Railway  https://docs.railway.com/integrations/api/manage-variables
//            https://docs.railway.com/integrations/api/manage-projects   (project → environments, services)
//            https://docs.railway.com/reference/public-api               (endpoint, Bearer token)
//   Fly      https://docs.fly.io/api/machines/openapi.json   (Machines API: /v1/apps/{app}/secrets)

/// Why a native request didn't succeed. Messages never contain a token, a value or a response body.
public enum NativeRemoteError: Error, Equatable, Sendable {
    case invalidTarget(String)
    case invalidName(String)
    case badToken
    case hostNotAllowed
    case unauthorized
    case notFound
    case rateLimited
    case unavailable(Int)
    case rejected(status: Int, code: String?)
    case timedOut
    case network
    case tooLarge
    case badResponse(String)

    public var message: String {
        switch self {
        case .invalidTarget(let why): return why
        case .invalidName(let name): return "\(name) can't be used as a variable name here (letters, digits and underscores)"
        case .badToken: return "the token item is empty or isn't a single line"
        case .hostNotAllowed: return "refused: not this service's API host"
        case .unauthorized: return "the service refused the token (expired, wrong service, or without access to this target)"
        case .notFound: return "the service didn't find this target (check the names and the token's access)"
        case .rateLimited: return "the service is rate limiting requests; try again shortly"
        case .unavailable(let s): return "the service is unavailable right now (HTTP \(s))"
        case .rejected(let s, let code): return "the service rejected the request (HTTP \(s)\(code.map { ", \($0)" } ?? ""))"
        case .timedOut: return "the service didn't answer in time"
        case .network: return "couldn't reach the service"
        case .tooLarge: return "the service's response was larger than Latchkey accepts"
        case .badResponse(let why): return "the service's response wasn't what was expected (\(why))"
        }
    }
}

public struct NativeResponse: Sendable {
    public var status: Int
    public var body: Data
    public var retryAfter: TimeInterval?

    public init(status: Int, body: Data, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
    }
}

/// Sends one request. Throws `.timedOut`, `.network` or `.tooLarge`; HTTP statuses come back as a response.
public protocol NativeTransport: Sendable {
    func send(_ request: URLRequest, maxBytes: Int, timeout: TimeInterval) throws -> NativeResponse
}

/// `URLSession` with a fresh ephemeral session per request: no cookies, no cache, no redirects (a redirect could carry
/// the token to another host), and the body is dropped once it passes the size cap.
public final class URLSessionTransport: NativeTransport, @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    /// Tests pass a configuration whose `protocolClasses` answer instead of the network.
    public init(configuration: URLSessionConfiguration = .ephemeral) { self.configuration = configuration }

    private final class Collector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let maxBytes: Int
        var data = Data()
        var response: HTTPURLResponse?
        var tooLarge = false
        var failure: Error?
        let done = DispatchSemaphore(value: 0)
        init(maxBytes: Int) { self.maxBytes = maxBytes }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            self.response = response as? HTTPURLResponse
            if response.expectedContentLength > Int64(maxBytes) { tooLarge = true; completionHandler(.cancel) } else { completionHandler(.allow) }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            self.data.append(data)
            if self.data.count > maxBytes { tooLarge = true; self.data = Data(); dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            failure = error
            done.signal()
        }
    }

    public func send(_ request: URLRequest, maxBytes: Int, timeout: TimeInterval) throws -> NativeResponse {
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let collector = Collector(maxBytes: maxBytes)
        let session = URLSession(configuration: config, delegate: collector, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = request
        request.timeoutInterval = timeout
        session.dataTask(with: request).resume()
        guard collector.done.wait(timeout: .now() + timeout + 5) == .success else { throw NativeRemoteError.timedOut }
        if collector.tooLarge { throw NativeRemoteError.tooLarge }
        if let error = collector.failure {
            throw (error as? URLError)?.code == .timedOut ? NativeRemoteError.timedOut : NativeRemoteError.network
        }
        guard let response = collector.response else { throw NativeRemoteError.network }
        return NativeResponse(status: response.statusCode, body: collector.data,
                              retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
    }
}

/// What a push needs to say about one variable.
public typealias NativeValue = (name: String, value: String, secret: Bool)

public struct NativeRemote: Sendable {
    /// Encrypts a value to GitHub's public key (`LatchkeySeal`'s `SealedBox.seal`). Without it, GitHub pushes are
    /// refused: the App Store build leaves the sealed box out so it uses only the operating system's encryption.
    public typealias Seal = @Sendable (_ message: [UInt8], _ recipient: [UInt8]) throws -> [UInt8]

    let transport: NativeTransport
    let pause: @Sendable (TimeInterval) -> Void
    let seal: Seal?

    /// Answers larger than this are refused.
    public static let maxResponseBytes = 1_000_000
    public static let timeout: TimeInterval = 30
    /// Total tries for a request: one, plus up to two more after a rate limit or a 502/503/504.
    public static let maxAttempts = 3
    static let maxPause: TimeInterval = 5

    public init(seal: Seal?, transport: NativeTransport = URLSessionTransport(), pause: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.seal = seal
        self.transport = transport
        self.pause = pause
    }

    /// Why GitHub pushes are refused in a build without the sealed box.
    public static let githubUnavailable = "GitHub pushes aren't available in this version of Latchkey"

    // MARK: public operations

    /// Sets each value at the target. One result per value, in order.
    public func push(_ target: RemoteTarget, token rawToken: String, values: [NativeValue]) -> [Result<Void, NativeRemoteError>] {
        func all(_ e: NativeRemoteError) -> [Result<Void, NativeRemoteError>] { values.map { _ in .failure(e) } }
        let token: String
        do { token = try Self.checked(token: rawToken); try Self.check(target) } catch { return all(error as? NativeRemoteError ?? .network) }
        if let bad = values.first(where: { !Self.isVariableName($0.name) }) { return all(.invalidName(bad.name)) }
        switch target.service {
        case .vercel: return pushVercel(target, token, values)
        case .github: return pushGitHub(target, token, values)
        case .railway: return pushRailway(target, token, values)
        case .fly: return pushFly(target, token, values)
        }
    }

    /// Names at the target. Values that come back with them are dropped here.
    public func names(_ target: RemoteTarget, token rawToken: String) throws -> [String] {
        let token = try Self.checked(token: rawToken)
        try Self.check(target)
        switch target.service {
        case .vercel: return try namesVercel(target, token)
        case .github: return try namesGitHub(target, token)
        case .railway: return try namesRailway(target, token)
        case .fly: return try namesFly(target, token)
        }
    }

    // MARK: checks

    /// Each service's API host. Nothing else is contacted, whatever a link says.
    public static func host(_ service: RemoteTarget.Service) -> String {
        switch service {
        case .vercel: return "api.vercel.com"
        case .github: return "api.github.com"
        case .railway: return "backboard.railway.com"
        case .fly: return "api.machines.dev"
        }
    }

    static func check(_ target: RemoteTarget) throws {
        if let problem = target.nativeProblem { throw NativeRemoteError.invalidTarget(problem) }
    }

    /// A header value can't carry a line break, so a token with one is refused rather than sent.
    static func checked(token: String) throws -> String {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == " " }) else { throw NativeRemoteError.badToken }
        return t
    }

    static func isVariableName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, !s.isEmpty, s.utf8.count <= 255 else { return false }
        func word(_ c: Unicode.Scalar) -> Bool { (c.value < 128) && (c == "_" || CharacterSet.alphanumerics.contains(c)) }
        return !CharacterSet.decimalDigits.contains(first) && s.unicodeScalars.allSatisfy(word)
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }

    /// One path segment, percent-encoded; never empty, `.` or `..`.
    static func segment(_ s: String) throws -> String {
        guard !s.isEmpty, s != ".", s != "..", s.utf8.count <= 255 else { throw NativeRemoteError.invalidTarget("\"\(s.prefix(40))\" isn't a valid name here") }
        return encode(s)
    }

    func url(_ service: RemoteTarget.Service, _ segments: [String], query: [(String, String)] = []) throws -> URL {
        var s = "https://\(Self.host(service))/" + (try segments.map(Self.segment)).joined(separator: "/")
        if !query.isEmpty { s += "?" + query.map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }.joined(separator: "&") }
        guard let url = URL(string: s) else { throw NativeRemoteError.invalidTarget("couldn't form the request") }
        return url
    }

    // MARK: sending

    /// One request with the token, checked against the allowlist, retried (at most `maxAttempts` tries) only after a
    /// rate limit or a 502/503/504. Returns the successful (2xx) response.
    func call(_ service: RemoteTarget.Service, _ url: URL, method: String, token: String, headers: [String: String] = [:],
              body: Data? = nil, sending values: [String] = []) throws -> NativeResponse {
        guard url.scheme == "https", url.host == Self.host(service), url.port == nil, url.user == nil else { throw NativeRemoteError.hostNotAllowed }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Latchkey", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        var attempt = 1
        while true {
            let response = try transport.send(request, maxBytes: Self.maxResponseBytes, timeout: Self.timeout)
            let failure: NativeRemoteError
            switch response.status {
            case 200..<300: return response
            case 401, 403: throw NativeRemoteError.unauthorized
            case 404: throw NativeRemoteError.notFound
            case 429: failure = .rateLimited
            case 502, 503, 504: failure = .unavailable(response.status)
            default: throw NativeRemoteError.rejected(status: response.status, code: Self.errorCode(response.body, excluding: values + [token]))
            }
            guard attempt < Self.maxAttempts else { throw failure }
            pause(min(response.retryAfter ?? Double(attempt), Self.maxPause))
            attempt += 1
        }
    }

    /// The service's short error code (Vercel's `error.code`), only when it looks like one and isn't something that was
    /// sent (a service could echo a value as its "code"). Messages are never kept: they can echo what was sent.
    static func errorCode(_ body: Data, excluding sent: [String]) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return ((json["error"] as? [String: Any])?["code"] as? String).flatMap { safeCode($0, excluding: sent) }
    }

    static func safeCode(_ code: String, excluding sent: [String]) -> String? {
        guard (1...64).contains(code.count), code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) }) else { return nil }
        // Sent text of any length: a short value that happens to be inside a code is still caught by the broker's redaction.
        return sent.contains(where: { !$0.isEmpty && code.contains($0) }) ? nil : code
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NativeRemoteError.badResponse("not a JSON object") }
        return json
    }

    static func jsonBody(_ object: [String: Any]) throws -> Data {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { throw NativeRemoteError.badResponse("couldn't encode the request") }
        return data
    }

    /// Runs `body` for each value, or reports one failure for all of them.
    private func each(_ values: [NativeValue], _ body: (NativeValue) throws -> Void) -> [Result<Void, NativeRemoteError>] {
        values.map { v in
            do { try body(v); return .success(()) } catch { return .failure(error as? NativeRemoteError ?? .network) }
        }
    }

    // MARK: Vercel

    private func vercelQuery(_ t: RemoteTarget, upsert: Bool) -> [(String, String)] {
        var q: [(String, String)] = []
        if upsert { q.append(("upsert", "true")) }
        if let team = t.team, !team.isEmpty { q.append((team.hasPrefix("team_") ? "teamId" : "slug", team)) }
        return q
    }

    private func pushVercel(_ t: RemoteTarget, _ token: String, _ values: [NativeValue]) -> [Result<Void, NativeRemoteError>] {
        each(values) { v in
            let env = t.environment ?? ""
            // Sensitive values can't be read back from Vercel; development doesn't allow them.
            let type = !v.secret ? "plain" : (env == "development" ? "encrypted" : "sensitive")
            var body: [String: Any] = ["key": v.name, "value": v.value, "type": type, "target": [env]]
            if let b = t.branch, !b.isEmpty { body["gitBranch"] = b }
            let r = try call(.vercel, try url(.vercel, ["v10", "projects", t.project ?? "", "env"], query: vercelQuery(t, upsert: true)),
                             method: "POST", token: token, body: try Self.jsonBody(body), sending: [v.value])
            guard r.status == 200 || r.status == 201 else { throw NativeRemoteError.badResponse("HTTP \(r.status)") }
            let json = try Self.object(r.body)
            guard let failed = json["failed"] as? [Any] else { throw NativeRemoteError.badResponse("no failed list") }
            if let first = failed.first {
                let code = ((first as? [String: Any])?["error"] as? [String: Any])?["code"] as? String
                throw NativeRemoteError.rejected(status: r.status, code: code.flatMap { Self.safeCode($0, excluding: [v.value, token]) })
            }
        }
    }

    private func namesVercel(_ t: RemoteTarget, _ token: String) throws -> [String] {
        var q = vercelQuery(t, upsert: false)
        if let b = t.branch, !b.isEmpty { q.append(("gitBranch", b)) }
        let r = try call(.vercel, try url(.vercel, ["v10", "projects", t.project ?? "", "env"], query: q), method: "GET", token: token)
        let json = try Self.object(r.body)
        guard let envs = json["envs"] as? [[String: Any]] else { throw NativeRemoteError.badResponse("no envs list") }
        if let next = (json["pagination"] as? [String: Any])?["next"], !(next is NSNull) { throw NativeRemoteError.badResponse("more than one page of variables") }
        let env = t.environment ?? ""
        var out: [String] = []
        for e in envs {
            guard let key = e["key"] as? String else { throw NativeRemoteError.badResponse("a variable without a key") }
            let targets = (e["target"] as? [String]) ?? (e["target"] as? String).map { [$0] } ?? []
            guard targets.contains(env) else { continue }
            // A branch link sees that branch's variables; without one, the ones that apply to every branch.
            if ((e["gitBranch"] as? String) ?? "") == (t.branch ?? "") { out.append(key) }
        }
        return Array(Set(out)).sorted()
    }

    // MARK: GitHub Actions

    private static let githubHeaders = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2026-03-10"]

    /// `/repos/{owner}/{repo}/actions` or `/repos/{owner}/{repo}/environments/{env}`, as path segments.
    private func githubBase(_ t: RemoteTarget) throws -> [String] {
        let parts = (t.repo ?? "").split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { throw NativeRemoteError.invalidTarget("GitHub needs a repository as owner/repo") }
        for p in parts where p.isEmpty || !p.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) {
            throw NativeRemoteError.invalidTarget("\"\(p.prefix(40))\" isn't a valid owner or repository name")
        }
        var base = ["repos", parts[0], parts[1]]
        if let e = t.environment, !e.isEmpty { base += ["environments", e] } else { base.append("actions") }
        return base
    }

    static func isGitHubSecretName(_ s: String) -> Bool { isVariableName(s) && !s.uppercased().hasPrefix("GITHUB_") }

    private func pushGitHub(_ t: RemoteTarget, _ token: String, _ values: [NativeValue]) -> [Result<Void, NativeRemoteError>] {
        guard let seal else { return values.map { _ in .failure(.invalidTarget(Self.githubUnavailable)) } }
        let base: [String], keyID: String, publicKey: [UInt8]
        do {
            base = try githubBase(t)
            if let bad = values.first(where: { !Self.isGitHubSecretName($0.name) }) { throw NativeRemoteError.invalidName(bad.name) }
            let r = try call(.github, try url(.github, base + ["secrets", "public-key"]), method: "GET", token: token, headers: Self.githubHeaders)
            let json = try Self.object(r.body)
            guard let id = json["key_id"] as? String, !id.isEmpty, let key = json["key"] as? String,
                  let raw = Data(base64Encoded: key), raw.count == 32 else { throw NativeRemoteError.badResponse("no usable public key") }
            keyID = id
            publicKey = Array(raw)
        } catch { return values.map { _ in .failure(error as? NativeRemoteError ?? .network) } }
        return each(values) { v in
            let sealed: [UInt8]
            do { sealed = try seal(Array(v.value.utf8), publicKey) } catch { throw NativeRemoteError.badResponse("unusable public key") }
            let body = try Self.jsonBody(["encrypted_value": Data(sealed).base64EncodedString(), "key_id": keyID])
            let r = try call(.github, try url(.github, base + ["secrets", v.name]), method: "PUT", token: token, headers: Self.githubHeaders, body: body, sending: [v.value])
            guard r.status == 201 || r.status == 204 else { throw NativeRemoteError.badResponse("HTTP \(r.status)") }
        }
    }

    private func namesGitHub(_ t: RemoteTarget, _ token: String) throws -> [String] {
        let base = try githubBase(t)
        var out: [String] = []
        for page in 1...20 {
            let r = try call(.github, try url(.github, base + ["secrets"], query: [("per_page", "100"), ("page", String(page))]),
                             method: "GET", token: token, headers: Self.githubHeaders)
            let json = try Self.object(r.body)
            guard let total = json["total_count"] as? Int, let rows = json["secrets"] as? [[String: Any]] else { throw NativeRemoteError.badResponse("no secrets list") }
            let names = try rows.map { row -> String in
                guard let n = row["name"] as? String else { throw NativeRemoteError.badResponse("a secret without a name") }
                return n
            }
            out += names
            if out.count >= total || names.isEmpty { return Array(Set(out)).sorted() }
        }
        throw NativeRemoteError.badResponse("more than 2000 secrets")
    }

    // MARK: Railway

    private static let railwayURL = "https://backboard.railway.com/graphql/v2"

    /// A GraphQL call. Railway can answer 200 with `errors`; that's a failure, and the messages aren't kept.
    private func graphQL(_ token: String, _ query: String, _ variables: [String: Any], sending: [String] = []) throws -> [String: Any] {
        guard let url = URL(string: Self.railwayURL) else { throw NativeRemoteError.hostNotAllowed }
        let r = try call(.railway, url, method: "POST", token: token, body: try Self.jsonBody(["query": query, "variables": variables]), sending: sending)
        let json = try Self.object(r.body)
        if let errors = json["errors"] as? [Any], !errors.isEmpty {
            let text = errors.compactMap { ($0 as? [String: Any])?["message"] as? String }.joined(separator: " ").lowercased()
            if text.contains("not authorized") || text.contains("unauthorized") || text.contains("unauthenticated") { throw NativeRemoteError.unauthorized }
            if text.contains("not found") { throw NativeRemoteError.notFound }
            throw NativeRemoteError.rejected(status: r.status, code: "graphql_error")
        }
        guard let data = json["data"] as? [String: Any] else { throw NativeRemoteError.badResponse("no data") }
        return data
    }

    /// The project's environment and service IDs for the names (or IDs) a link holds.
    private func railwayIDs(_ t: RemoteTarget, _ token: String, needService: Bool) throws -> (project: String, environment: String, service: String?) {
        let project = t.project ?? ""
        let data = try graphQL(token, """
            query project($id: String!) { project(id: $id) { id environments { edges { node { id name } } } services { edges { node { id name } } } } }
            """, ["id": project])
        guard let p = data["project"] as? [String: Any] else { throw NativeRemoteError.notFound }
        func find(_ key: String, _ wanted: String, _ what: String) throws -> String {
            guard let edges = (p[key] as? [String: Any])?["edges"] as? [[String: Any]] else { throw NativeRemoteError.badResponse("no \(what) list") }
            let nodes = edges.compactMap { $0["node"] as? [String: Any] }.compactMap { n -> (String, String)? in
                guard let id = n["id"] as? String, let name = n["name"] as? String else { return nil }
                return (id, name)
            }
            if let byID = nodes.first(where: { $0.0 == wanted }) { return byID.0 }
            let byName = nodes.filter { $0.1 == wanted }
            guard byName.count == 1 else {
                throw NativeRemoteError.invalidTarget(byName.isEmpty ? "Railway has no \(what) named \"\(wanted.prefix(40))\" in this project" : "more than one Railway \(what) is named \"\(wanted.prefix(40))\"; use its ID")
            }
            return byName[0].0
        }
        return (project, try find("environments", t.environment ?? "", "environment"), needService ? try find("services", t.serviceName ?? "", "service") : nil)
    }

    private func pushRailway(_ t: RemoteTarget, _ token: String, _ values: [NativeValue]) -> [Result<Void, NativeRemoteError>] {
        let ids: (project: String, environment: String, service: String?)
        do { ids = try railwayIDs(t, token, needService: true) } catch { return values.map { _ in .failure(error as? NativeRemoteError ?? .network) } }
        return each(values) { v in
            // skipDeploys: setting a variable on Railway starts a deploy otherwise.
            let input: [String: Any] = ["projectId": ids.project, "environmentId": ids.environment, "serviceId": ids.service ?? "",
                                        "name": v.name, "value": v.value, "skipDeploys": true]
            let data = try graphQL(token, "mutation variableUpsert($input: VariableUpsertInput!) { variableUpsert(input: $input) }", ["input": input], sending: [v.value])
            guard let ok = data["variableUpsert"] as? Bool, ok else { throw NativeRemoteError.badResponse("variableUpsert wasn't true") }
        }
    }

    private func namesRailway(_ t: RemoteTarget, _ token: String) throws -> [String] {
        let ids = try railwayIDs(t, token, needService: true)
        let data = try graphQL(token, """
            query variables($projectId: String!, $environmentId: String!, $serviceId: String) { variables(projectId: $projectId, environmentId: $environmentId, serviceId: $serviceId) }
            """, ["projectId": ids.project, "environmentId": ids.environment, "serviceId": ids.service ?? ""])
        // A map of NAME: value. Only the names are kept.
        guard let map = data["variables"] as? [String: Any] else { throw NativeRemoteError.badResponse("no variables map") }
        return map.keys.sorted()
    }

    // MARK: Fly

    private func pushFly(_ t: RemoteTarget, _ token: String, _ values: [NativeValue]) -> [Result<Void, NativeRemoteError>] {
        func fail(_ e: Error) -> [Result<Void, NativeRemoteError>] { values.map { _ in .failure(e as? NativeRemoteError ?? .network) } }
        do {
            // One request carries every value; Fly stages them, so nothing is deployed.
            var map: [String: String] = [:]
            for v in values { map[v.name] = v.value }
            let r = try call(.fly, try url(.fly, ["v1", "apps", t.app ?? "", "secrets"]), method: "POST", token: token, body: try Self.jsonBody(["values": map]), sending: Array(map.values))
            guard r.status == 200 else { throw NativeRemoteError.badResponse("HTTP \(r.status)") }
            let json = try Self.object(r.body)
            guard json["version"] is NSNumber, let echoed = json["secrets"] as? [[String: Any]] else { throw NativeRemoteError.badResponse("no version and secrets") }
            // The response repeats the values; only the names are looked at.
            let names = Set(echoed.compactMap { $0["name"] as? String })
            guard Set(map.keys).isSubset(of: names) else { throw NativeRemoteError.badResponse("not every secret was set") }
            return values.map { _ in .success(()) }
        } catch { return fail(error) }
    }

    private func namesFly(_ t: RemoteTarget, _ token: String) throws -> [String] {
        let r = try call(.fly, try url(.fly, ["v1", "apps", t.app ?? "", "secrets"]), method: "GET", token: token)
        guard let rows = try Self.object(r.body)["secrets"] as? [[String: Any]] else { throw NativeRemoteError.badResponse("no secrets list") }
        return try rows.map { row in
            guard let n = row["name"] as? String else { throw NativeRemoteError.badResponse("a secret without a name") }
            return n
        }.sorted()
    }
}
