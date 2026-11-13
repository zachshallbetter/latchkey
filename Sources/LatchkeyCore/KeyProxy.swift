import Foundation
import Network

// `latchkey run --proxy`: the command never holds the real API key. It gets a placeholder and a base URL on this
// Mac; requests to that URL that carry the placeholder go to the provider with the real key in its place. The real
// key stays in this process (the signed tool, which other programs can't read), and can only ever reach the
// provider's own host. The placeholder is a bearer token that other programs of the same user can read from the
// command's environment, so a request is only served when its TCP connection belongs to the command's process tree.

public enum ProxyError: Error, CustomStringConvertible {
    case notStarted
    case configuration(String)

    public var description: String {
        switch self {
        case .notStarted: return "the key proxy could not start"
        case .configuration(let message): return message
        }
    }
}

/// A provider whose SDKs take their address from an environment variable.
public struct ProxyProvider: Sendable {
    public var name: String
    public var keyVariable: String
    public var baseVariable: String
    /// What the base URL variable should say: the local address plus whatever path the SDK expects.
    public var basePath: String
    public var upstream: String
    /// The header the key travels in, and how its value is written.
    public var header: String
    public var format: @Sendable (String) -> String

    public init(name: String, keyVariable: String, baseVariable: String, basePath: String, upstream: String,
                header: String, format: @escaping @Sendable (String) -> String) {
        self.name = name; self.keyVariable = keyVariable; self.baseVariable = baseVariable; self.basePath = basePath
        self.upstream = upstream; self.header = header; self.format = format
    }

    public static let all: [ProxyProvider] = [
        ProxyProvider(name: "OpenAI", keyVariable: "OPENAI_API_KEY", baseVariable: "OPENAI_BASE_URL", basePath: "/v1",
                      upstream: "https://api.openai.com", header: "authorization", format: { "Bearer \($0)" }),
        ProxyProvider(name: "Anthropic", keyVariable: "ANTHROPIC_API_KEY", baseVariable: "ANTHROPIC_BASE_URL", basePath: "",
                      upstream: "https://api.anthropic.com", header: "x-api-key", format: { $0 }),
    ]
}

/// One provider's key, held back from the command.
public struct ProxyRoute: Sendable {
    public var provider: ProxyProvider
    public var placeholder: String
    public var key: String

    public init(provider: ProxyProvider, placeholder: String, key: String) {
        self.provider = provider; self.placeholder = placeholder; self.key = key
    }
}

/// Replaces supported provider keys with placeholders, or refuses the whole configuration. A custom base URL,
/// plaintext key, or a second delivery of a protected key must never silently fall back to releasing the key.
public func holdBackProxiedKeys(_ env: inout [String: String], values: [String: String], references: [String: String]) throws -> [ProxyRoute] {
    var routes: [ProxyRoute] = []
    let fileRefs = References.fileReferences(in: env)
    for p in ProxyProvider.all where env[p.keyVariable] != nil {
        guard let id = references[p.keyVariable], let key = values[id], !key.isEmpty else {
            throw ProxyError.configuration("--proxy requires \(p.keyVariable) to be a whole latchkey:// reference")
        }
        guard env[p.baseVariable] == nil else {
            throw ProxyError.configuration("--proxy cannot use an existing \(p.baseVariable); unset it before running")
        }
        let placeholder = "lk-proxy-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        routes.append(ProxyRoute(provider: p, placeholder: placeholder, key: key))
    }
    guard !routes.isEmpty else {
        throw ProxyError.configuration("--proxy needs an OPENAI_API_KEY or ANTHROPIC_API_KEY reference")
    }
    let protectedVariables = Set(routes.map { $0.provider.keyVariable })
    for (name, value) in env where !protectedVariables.contains(name) {
        for route in routes {
            if value.contains(route.key) || fileRefs[name].flatMap({ values[$0] }) == route.key {
                throw ProxyError.configuration("--proxy would also release a protected key through \(name); remove that delivery")
            }
        }
    }
    // Validate everything before changing the environment, so failure never leaves a partially protected run.
    for route in routes { env[route.provider.keyVariable] = route.placeholder }
    return routes
}

/// What a run may ask of the provider, shared by every proxy the run starts: the models it may name and how many
/// requests it may make. Unlimited by default.
public final class ProxyLimits: @unchecked Sendable {
    public let models: Set<String>?
    public let requests: Int?
    private let lock = NSLock()
    private var used = 0

    public init(models: Set<String>? = nil, requests: Int? = nil) {
        self.models = models; self.requests = requests
    }

    public var isLimited: Bool { models != nil || requests != nil }

    /// A sentence for the person running the command, saying what is enforced.
    public var summary: String {
        var parts: [String] = []
        if let models { parts.append("models " + models.sorted().joined(separator: ", ")) }
        if let requests { parts.append("at most \(requests) request\(requests == 1 ? "" : "s")") }
        return parts.joined(separator: "; ")
    }

    /// Nil when the request is within the limits (and counted); otherwise the status and reason to refuse with.
    /// With a model list, a request is served only if its body is a JSON object whose single `model` names a listed
    /// model: anything the proxy can't read that way is refused rather than guessed at.
    func admit(_ r: HTTPRequest) -> (status: Int, message: String)? {
        if let models {
            guard let model = Self.model(of: r), models.contains(model) else {
                return (403, "this run may only use the model\(models.count == 1 ? "" : "s"): " + models.sorted().joined(separator: ", "))
            }
        }
        guard let requests else { return nil }
        return lock.withLock {
            guard used < requests else { return (429, "this run's limit of \(requests) request\(requests == 1 ? "" : "s") is used up") }
            used += 1
            return nil
        }
    }

    /// The `model` string of a JSON object body. Nil for anything else: no body, a compressed body, invalid JSON,
    /// a non-string model, or a `model` key that appears twice (parsers disagree on which one wins).
    static func model(of r: HTTPRequest) -> String? {
        let encoding = r.headers["content-encoding"]?.lowercased()
        guard encoding == nil || encoding == "identity", !r.body.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any],
              let model = object["model"] as? String,
              topLevelKeys(r.body)?.filter({ $0 == "model" }).count == 1 else { return nil }
        return model
    }

    /// The keys of a JSON object's top level, escapes decoded, duplicates kept. The body must already be valid JSON.
    static func topLevelKeys(_ data: Data) -> [String]? {
        let b = [UInt8](data)
        var keys: [String] = []
        var depth = 0, i = 0
        var expectKey = false
        while i < b.count {
            switch b[i] {
            case UInt8(ascii: "{"): depth += 1; expectKey = depth == 1
            case UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
            case UInt8(ascii: ","): if depth == 1 { expectKey = true }
            case UInt8(ascii: "\""):
                var j = i + 1
                while j < b.count, b[j] != UInt8(ascii: "\"") { j += b[j] == UInt8(ascii: "\\") ? 2 : 1 }
                guard j < b.count else { return nil }
                if depth == 1, expectKey {
                    guard let key = try? JSONDecoder().decode(String.self, from: Data(b[i...j])) else { return nil }
                    keys.append(key)
                    expectKey = false
                }
                i = j
            default: break
            }
            i += 1
        }
        return depth == 0 ? keys : nil
    }
}

/// Listens on 127.0.0.1 for one provider and forwards each request, one per connection.
public final class KeyProxy: @unchecked Sendable {
    public let route: ProxyRoute
    public let limits: ProxyLimits
    private let listener: NWListener
    private let queue = DispatchQueue(label: "latchkey.proxy")
    private let state = NSCondition()
    private var root: ProcessStamp?
    private var stopped = false
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    static let maxHeader = 64 * 1024
    static let maxBody = 32 * 1024 * 1024

    public init(route: ProxyRoute, limits: ProxyLimits = ProxyLimits()) throws {
        self.route = route
        self.limits = limits
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    /// Starts listening and returns the port.
    public func start() throws -> UInt16 {
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e): failure = e; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        if let failure { throw failure }
        guard let port = listener.port?.rawValue else { throw ProxyError.notStarted }
        return port
    }

    /// Serves only connections made by `process` or its descendants. Until this is called every request is refused;
    /// a request that arrives in the instant between the command starting and this call waits briefly for it.
    public func bind(to process: ProcessStamp) {
        state.lock(); root = process; state.broadcast(); state.unlock()
    }

    /// Stops listening, cancels connections still open and refuses anything that arrives after.
    public func stop() {
        state.lock(); stopped = true; let open = Array(connections.values); connections = [:]; state.broadcast(); state.unlock()
        listener.cancel()
        open.forEach { $0.cancel() }
    }

    private func boundRoot() -> ProcessStamp? {
        state.lock(); defer { state.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while root == nil, !stopped, state.wait(until: deadline) {}
        return stopped ? nil : root
    }

    private func serve(_ c: NWConnection) {
        state.lock()
        let refuse = stopped
        if !refuse { connections[ObjectIdentifier(c)] = c }
        state.unlock()
        if refuse { c.cancel(); return }
        c.stateUpdateHandler = { [weak self] s in
            if case .cancelled = s { self?.state.lock(); self?.connections[ObjectIdentifier(c)] = nil; self?.state.unlock() }
        }
        c.start(queue: queue)
        readRequest(c, buffer: Data())
    }

    private func readRequest(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let request = HTTPRequest.parse(buf) {
                switch request {
                case .complete(let r): self.forward(r, on: c)
                case .tooLarge: self.reply(c, status: 413, message: "request too large")
                case .invalid: self.reply(c, status: 400, message: "not an HTTP/1.1 request")
                }
                return
            }
            if done || error != nil { c.cancel(); return }
            if buf.count > Self.maxHeader + Self.maxBody { self.reply(c, status: 413, message: "request too large"); return }
            self.readRequest(c, buffer: buf)
        }
    }

    private func forward(_ r: HTTPRequest, on c: NWConnection) {
        let p = route.provider
        // Only requests carrying this run's placeholder: anything else on this Mac can't borrow the key.
        guard r.headers[p.header] == p.format(route.placeholder) else {
            reply(c, status: 401, message: "Latchkey's key proxy: this request doesn't carry the key it was given")
            return
        }
        // The placeholder alone isn't enough: other programs of the same user can read it from the command's
        // environment. The connection must also come from the command or something it started.
        guard belongsToCommand(c) else {
            reply(c, status: 403, message: "Latchkey's key proxy: this request didn't come from the command it was started for")
            return
        }
        guard r.target.hasPrefix("/"), let url = URL(string: p.upstream + r.target), url.host == URL(string: p.upstream)?.host else {
            reply(c, status: 400, message: "bad path")
            return
        }
        if let refusal = limits.admit(r) {
            reply(c, status: refusal.status, message: "Latchkey's key proxy: " + refusal.message)
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = r.method
        let dropped: Set<String> = ["host", "connection", "keep-alive", "proxy-connection", "proxy-authorization",
                                    "content-length", "transfer-encoding", "accept-encoding", "te", "upgrade", p.header]
        for (k, v) in r.headers where !dropped.contains(k) { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(p.format(route.key), forHTTPHeaderField: p.header)
        if !r.body.isEmpty { req.httpBody = r.body }
        req.timeoutInterval = 600
        let streamer = ResponseStreamer(connection: c)
        let session = URLSession(configuration: .ephemeral, delegate: streamer, delegateQueue: nil)
        session.dataTask(with: req).resume()
        session.finishTasksAndInvalidate()
    }

    private func belongsToCommand(_ c: NWConnection) -> Bool {
        guard let root = boundRoot(), case .hostPort(_, let client) = c.endpoint, let server = listener.port else { return false }
        return LoopbackPeer.connection(clientPort: client.rawValue, serverPort: server.rawValue, belongsTo: root)
    }

    private func reply(_ c: NWConnection, status: Int, message: String) {
        let body = Data("{\"error\":{\"type\":\"latchkey_proxy\",\"message\":\"\(message)\"}}".utf8)
        let head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// Writes the provider's response back as it arrives, so streamed answers stream.
final class ResponseStreamer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let connection: NWConnection
    private var started = false

    init(connection: NWConnection) { self.connection = connection }

    /// Never let URLSession forward a provider credential to a redirect destination. The caller receives the
    /// redirect response and can decide what to do, carrying only its placeholder.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        // URLSession has already undone any compression, so its length and encoding no longer apply.
        let skip: Set<String> = ["content-length", "content-encoding", "transfer-encoding", "connection", "keep-alive"]
        var head = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\n"
        for (k, v) in http.allHeaderFields {
            guard let k = k as? String, let v = v as? String, !skip.contains(k.lowercased()) else { continue }
            head += "\(k): \(v)\r\n"
        }
        head += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .idempotent)
        started = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        connection.send(content: Data(String(data.count, radix: 16).utf8) + Data("\r\n".utf8) + data + Data("\r\n".utf8),
                        completion: .idempotent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let c = connection
        if started {
            c.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in c.cancel() })
        } else {
            let body = Data("{\"error\":{\"type\":\"latchkey_proxy\",\"message\":\"couldn't reach the provider\"}}".utf8)
            let head = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}

/// An HTTP/1.1 request, read whole: request line, headers (names lowercased), and a body by Content-Length or
/// chunked encoding.
struct HTTPRequest {
    var method: String
    var target: String
    var headers: [String: String]
    var body: Data

    enum Parsed { case complete(HTTPRequest), tooLarge, invalid }

    /// Nil while more bytes are needed.
    static func parse(_ data: Data) -> Parsed? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > KeyProxy.maxHeader ? .tooLarge : nil
        }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let rest = data[end.upperBound...]
        var body = Data()
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            var i = rest.startIndex
            while true {
                guard let lineEnd = rest[i...].range(of: Data("\r\n".utf8)) else { return nil }
                let sizeText = String(decoding: rest[i..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else { return .invalid }
                guard size <= KeyProxy.maxBody - body.count else { return .tooLarge }
                let start = lineEnd.upperBound
                if size == 0 { break }
                guard rest.distance(from: start, to: rest.endIndex) >= size + 2 else { return nil }
                body.append(rest[start..<rest.index(start, offsetBy: size)])
                if body.count > KeyProxy.maxBody { return .tooLarge }
                i = rest.index(start, offsetBy: size + 2)
            }
        } else if let length = headers["content-length"].flatMap({ Int($0) }) {
            guard length >= 0 else { return .invalid }
            guard length <= KeyProxy.maxBody else { return .tooLarge }
            guard rest.count >= length else { return nil }
            body = Data(rest.prefix(length))
        }
        return .complete(HTTPRequest(method: String(parts[0]), target: String(parts[1]), headers: headers, body: body))
    }
}
