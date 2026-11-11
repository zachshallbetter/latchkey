import Network
import XCTest
@testable import LatchkeyCore

/// The key proxy against a stand-in provider on this Mac that echoes what it was sent.
final class ProxyTests: XCTestCase {
    func testHoldsBackOnlyWholeReferencesToKnownKeys() {
        var env = ["OPENAI_API_KEY": "real-openai", "ANTHROPIC_API_KEY": "real-anthropic", "ANTHROPIC_BASE_URL": "https://gateway.example",
                   "OTHER": "x"]
        let routes = holdBackProxiedKeys(&env, values: ["shop/development/OPENAI": "real-openai", "A": "real-anthropic"],
                                         references: ["OPENAI_API_KEY": "shop/development/OPENAI", "ANTHROPIC_API_KEY": "A"])
        XCTAssertEqual(routes.map(\.provider.name), ["OpenAI"], "a provider whose base URL is already set is left alone")
        XCTAssertTrue(env["OPENAI_API_KEY"]!.hasPrefix("lk-proxy-"))
        XCTAssertEqual(routes.first?.key, "real-openai")
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "real-anthropic")
    }

    func testSwapsThePlaceholderForTheKeyAndRefusesAnythingElse() throws {
        let upstream = try EchoServer()
        defer { upstream.stop() }
        let provider = ProxyProvider(name: "Test", keyVariable: "T_KEY", baseVariable: "T_BASE", basePath: "",
                                     upstream: "http://127.0.0.1:\(upstream.port)", header: "authorization", format: { "Bearer \($0)" })
        let proxy = try KeyProxy(route: ProxyRoute(provider: provider, placeholder: "lk-proxy-abc", key: "real-key-123"))
        let port = try proxy.start()
        defer { proxy.stop() }

        let ok = try send(port, auth: "Bearer lk-proxy-abc", body: "hello")
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(ok.body, "auth=Bearer real-key-123;path=/v1/chat?x=1;body=hello")

        let refused = try send(port, auth: "Bearer guess", body: "hello")
        XCTAssertEqual(refused.status, 401)
        XCTAssertFalse(refused.body.contains("real-key-123"))
        XCTAssertEqual(upstream.requests, 1, "a refused request never reaches the provider")
    }

    func testParsesChunkedBodies() {
        let raw = Data("POST /v1/x HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8)
        guard case .complete(let r)? = HTTPRequest.parse(raw) else { return XCTFail("should parse") }
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "hello world")
        XCTAssertNil(HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc".utf8)), "waits for the rest")
    }

    private func send(_ port: UInt16, auth: String, body: String) throws -> (status: Int, body: String) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat?x=1")!)
        req.httpMethod = "POST"
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.httpBody = Data(body.utf8)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Int, String) = (0, "")
        URLSession(configuration: .ephemeral).dataTask(with: req) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data ?? Data(), as: UTF8.self))
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        return result
    }
}

/// Answers each request with what it received: the Authorization header, the path and the body.
final class EchoServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "echo")
    private let lock = NSLock()
    private var count = 0
    private(set) var port: UInt16 = 0
    var requests: Int { lock.withLock { count } }

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port!.rawValue
    }

    func stop() { listener.cancel() }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, _ in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if case .complete(let r)? = HTTPRequest.parse(buf) {
                self.lock.withLock { self.count += 1 }
                let body = Data("auth=\(r.headers["authorization"] ?? "");path=\(r.target);body=\(String(decoding: r.body, as: UTF8.self))".utf8)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
            } else if done {
                c.cancel()
            } else {
                self.read(c, buf)
            }
        }
    }
}
