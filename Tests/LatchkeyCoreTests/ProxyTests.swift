import Network
import XCTest
@testable import LatchkeyCore

/// The key proxy against a stand-in provider on this Mac that echoes what it was sent.
final class ProxyTests: XCTestCase {
    func testProxyRefusesCustomBaseURLsWithoutChangingTheEnvironment() {
        var env = ["OPENAI_API_KEY": "fixture-openai", "ANTHROPIC_API_KEY": "fixture-anthropic", "ANTHROPIC_BASE_URL": "https://gateway.example"]
        let original = env
        XCTAssertThrowsError(try holdBackProxiedKeys(&env, values: ["O": "fixture-openai", "A": "fixture-anthropic"],
                                                    references: ["OPENAI_API_KEY": "O", "ANTHROPIC_API_KEY": "A"]))
        XCTAssertEqual(env, original, "a partial configuration must fail atomically")
    }

    func testSwapsThePlaceholderForTheKeyAndRefusesAnythingElse() throws {
        let upstream = try EchoServer()
        defer { upstream.stop() }
        let provider = ProxyProvider(name: "Test", keyVariable: "T_KEY", baseVariable: "T_BASE", basePath: "",
                                     upstream: "http://127.0.0.1:\(upstream.port)", header: "authorization", format: { "Bearer \($0)" })
        let proxy = try KeyProxy(route: ProxyRoute(provider: provider, placeholder: "lk-proxy-abc", key: "real-key-123"))
        let port = try proxy.start()
        defer { proxy.stop() }
        proxy.bind(to: Self.thisProcess)

        let ok = try send(port, auth: "Bearer lk-proxy-abc", body: "hello")
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(ok.body, "auth=Bearer real-key-123;path=/v1/chat?x=1;body=hello")

        let refused = try send(port, auth: "Bearer guess", body: "hello")
        XCTAssertEqual(refused.status, 401)
        XCTAssertFalse(refused.body.contains("real-key-123"))
        XCTAssertEqual(upstream.requests, 1, "a refused request never reaches the provider")
    }

    private static var thisProcess: ProcessStamp {
        ProcessStamp(pid: getpid(), started: PeerInfo.started(getpid()) ?? 0)
    }

    private func provider(_ upstream: EchoServer) -> ProxyProvider {
        ProxyProvider(name: "Test", keyVariable: "T_KEY", baseVariable: "T_BASE", basePath: "",
                      upstream: "http://127.0.0.1:\(upstream.port)", header: "authorization", format: { "Bearer \($0)" })
    }

    func testRefusesConnectionsFromOutsideTheCommandsProcessTree() throws {
        let upstream = try EchoServer()
        defer { upstream.stop() }
        let proxy = try KeyProxy(route: ProxyRoute(provider: provider(upstream), placeholder: "lk-proxy-abc", key: "real-key-123"))
        let port = try proxy.start()
        defer { proxy.stop() }

        // The command is a sleeping child; this test process knows the placeholder (as any same-user program can
        // from the command's environment) but isn't the command or its descendant.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate(); sleeper.waitUntilExit() }
        proxy.bind(to: ProcessStamp(pid: sleeper.processIdentifier, started: PeerInfo.started(sleeper.processIdentifier) ?? 0))

        let refused = try send(port, auth: "Bearer lk-proxy-abc", body: "hello")
        XCTAssertEqual(refused.status, 403)
        XCTAssertFalse(refused.body.contains("real-key-123"))
        XCTAssertEqual(upstream.requests, 0, "a request from outside the tree never reaches the provider")
    }

    func testServesDescendantsOfTheCommandAndNotAReusedProcessID() throws {
        let upstream = try EchoServer()
        defer { upstream.stop() }
        let proxy = try KeyProxy(route: ProxyRoute(provider: provider(upstream), placeholder: "lk-proxy-abc", key: "real-key-123"))
        let port = try proxy.start()
        defer { proxy.stop() }

        // The command is a shell; its request comes from curl, a grandchild.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "/usr/bin/curl -s -H 'Authorization: Bearer lk-proxy-abc' -d hello http://127.0.0.1:\(port)/v1/chat; true"]
        let out = Pipe()
        shell.standardOutput = out
        try shell.run()
        let stamp = ProcessStamp(pid: shell.processIdentifier, started: PeerInfo.started(shell.processIdentifier) ?? 0)
        proxy.bind(to: stamp)
        let body = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        shell.waitUntilExit()
        XCTAssertTrue(body.contains("auth=Bearer real-key-123"), "got: \(body)")
        XCTAssertEqual(upstream.requests, 1)

        // The same process ID with another start time is not the command.
        XCTAssertFalse(LoopbackPeer.isDescendant(getpid(), of: ProcessStamp(pid: getpid(), started: stamp.started)))
        XCTAssertFalse(LoopbackPeer.isDescendant(shell.processIdentifier, of: stamp), "the command has exited")
    }

    func testStoppedProxyServesNothing() throws {
        let upstream = try EchoServer()
        defer { upstream.stop() }
        let proxy = try KeyProxy(route: ProxyRoute(provider: provider(upstream), placeholder: "lk-proxy-abc", key: "real-key-123"))
        let port = try proxy.start()
        proxy.bind(to: Self.thisProcess)
        XCTAssertEqual(try send(port, auth: "Bearer lk-proxy-abc", body: "hello").status, 200)
        proxy.stop()
        XCTAssertEqual(upstream.requests, 1)
        let after = try? send(port, auth: "Bearer lk-proxy-abc", body: "hello")
        XCTAssertNotEqual(after?.status, 200, "a stopped proxy serves nothing")
        XCTAssertEqual(upstream.requests, 1)
    }

    func testModelLimitIsEnforcedOnTheBody() throws {
        let upstream = try EchoServer()
        defer { upstream.stop() }
        let limits = ProxyLimits(models: ["gpt-a", "gpt-b"])
        let proxy = try KeyProxy(route: ProxyRoute(provider: provider(upstream), placeholder: "lk-proxy-abc", key: "real-key-123"), limits: limits)
        let port = try proxy.start()
        defer { proxy.stop() }
        proxy.bind(to: Self.thisProcess)

        XCTAssertEqual(try send(port, auth: "Bearer lk-proxy-abc", body: #"{"model":"gpt-b","input":"x"}"#).status, 200)
        for body in [#"{"model":"gpt-c"}"#, #"{"input":"x"}"#, "not json", #"{"model":["gpt-a"]}"#, "",
                     #"{"model":"gpt-a","model":"gpt-c"}"#, #"{"model":"gpt-c","mod\u0065l":"gpt-a"}"#] {
            let r = try send(port, auth: "Bearer lk-proxy-abc", body: body)
            XCTAssertEqual(r.status, 403, "body \(body) must be refused")
            XCTAssertFalse(r.body.contains("real-key-123"))
        }
        XCTAssertEqual(upstream.requests, 1)
    }

    func testRequestLimitCountsOnlyForwardedRequests() throws {
        let upstream = try EchoServer()
        defer { upstream.stop() }
        let proxy = try KeyProxy(route: ProxyRoute(provider: provider(upstream), placeholder: "lk-proxy-abc", key: "real-key-123"),
                                 limits: ProxyLimits(requests: 2))
        let port = try proxy.start()
        defer { proxy.stop() }
        proxy.bind(to: Self.thisProcess)

        XCTAssertEqual(try send(port, auth: "Bearer wrong", body: "x").status, 401, "refused requests aren't counted")
        XCTAssertEqual(try send(port, auth: "Bearer lk-proxy-abc", body: "1").status, 200)
        XCTAssertEqual(try send(port, auth: "Bearer lk-proxy-abc", body: "2").status, 200)
        XCTAssertEqual(try send(port, auth: "Bearer lk-proxy-abc", body: "3").status, 429)
        XCTAssertEqual(upstream.requests, 2)
    }

    func testLimitsSummaryAndKeyScanner() {
        XCTAssertEqual(ProxyLimits(models: ["b", "a"], requests: 1).summary, "models a, b; at most 1 request")
        XCTAssertFalse(ProxyLimits().isLimited)
        XCTAssertEqual(ProxyLimits.topLevelKeys(Data(#"{"a":{"model":1},"b":["x",{"model":2}],"c\"d":"{\"model\":3}"}"#.utf8)), ["a", "b", "c\"d"])
    }

    func testRunOptionsWithValuesAreSkippedWhenReadingTheCommand() {
        let peer = PeerInfo(pid: 1, path: "/x/latchkey", cwd: "/", chain: [],
                            arguments: ["latchkey", "run", "--proxy", "--proxy-models", "a,b", "--proxy-requests", "5", "--", "npm", "test"],
                            isLatchkeyTool: true)
        XCTAssertEqual(peer.runCommand, ["npm", "test"])
    }

    func testParsesChunkedBodies() {
        let raw = Data("POST /v1/x HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8)
        guard case .complete(let r)? = HTTPRequest.parse(raw) else { return XCTFail("should parse") }
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "hello world")
        XCTAssertNil(HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc".utf8)), "waits for the rest")
    }

    func testMalformedBodyLengthsAreRefusedBeforeSlicing() {
        for header in ["Content-Length: -1", "Transfer-Encoding: chunked"] {
            let body = header.hasPrefix("Transfer") ? "-1\r\n" : ""
            guard case .invalid? = HTTPRequest.parse(Data(("POST / HTTP/1.1\r\n" + header + "\r\n\r\n" + body).utf8)) else {
                return XCTFail("negative lengths must be rejected")
            }
        }
        let huge = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n7fffffffffffffff\r\n"
        guard case .tooLarge? = HTTPRequest.parse(Data(huge.utf8)) else { return XCTFail("oversized chunks must be rejected") }
    }

    func testUpstreamRedirectsAreNotFollowed() throws {
        let connection = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        let streamer = ResponseStreamer(connection: connection)
        let url = try XCTUnwrap(URL(string: "https://provider.example/v1"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil,
                                                   headerFields: ["Location": "https://other.example/"]))
        var called = false
        streamer.urlSession(.shared, task: URLSession.shared.dataTask(with: url), willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: "https://other.example/")!)) { request in
            called = true
            XCTAssertNil(request, "URLSession must never forward a provider credential to a redirect destination")
        }
        XCTAssertTrue(called)
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
