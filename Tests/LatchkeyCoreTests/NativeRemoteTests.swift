import XCTest
import CryptoKit
@testable import LatchkeyCore

/// Answers requests from a closure instead of the network, and keeps what was asked.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Seen { var method: String; var url: URL; var headers: [String: String]; var body: Data }
    nonisolated(unsafe) static var handler: ((Seen) -> (status: Int, body: String, headers: [String: String])?)?
    nonisolated(unsafe) static var seen: [Seen] = []
    nonisolated(unsafe) static var failure: URLError.Code?
    static let lock = NSLock()

    static func reset(_ h: @escaping (Seen) -> (status: Int, body: String, headers: [String: String])?) {
        lock.withLock { handler = h; seen = []; failure = nil }
    }

    static var requests: [Seen] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
            stream.close()
        }
        let seen = Seen(method: request.httpMethod ?? "", url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: body)
        let (handler, failure): (((Seen) -> (status: Int, body: String, headers: [String: String])?)?, URLError.Code?) = Self.lock.withLock {
            Self.seen.append(seen)
            return (Self.handler, Self.failure)
        }
        if let failure { client?.urlProtocol(self, didFailWithError: URLError(failure)); return }
        guard let answer = handler?(seen) else { client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func transport() -> URLSessionTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSessionTransport(configuration: config)
    }
}

final class Pauses: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [TimeInterval] = []
    var values: [TimeInterval] { lock.withLock { all } }
    func add(_ t: TimeInterval) { lock.withLock { all.append(t) } }
}

class NativeRemoteTestCase: XCTestCase {
    let token = "tok_live_9f8e7d6c5b4a"
    var pauses = Pauses()

    func remote() -> NativeRemote {
        pauses = Pauses()
        let p = pauses
        return NativeRemote(transport: StubProtocol.transport(), pause: { p.add($0) })
    }

    func json(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }

    func ok(_ body: String = "{}", status: Int = 200) -> (status: Int, body: String, headers: [String: String]) { (status, body, [:]) }

    func succeeded(_ results: [Result<Void, NativeRemoteError>]) -> Bool { results.allSatisfy { if case .success = $0 { return true } else { return false } } }

    func error(_ results: [Result<Void, NativeRemoteError>], at i: Int = 0) -> NativeRemoteError? {
        if case .failure(let e) = results[i] { return e } else { return nil }
    }
}

final class NativeVercelTests: NativeRemoteTestCase {
    func testUpsertsEachVariableWithTheTokenAndTheEnvironmentsTarget() throws {
        StubProtocol.reset { _ in self.ok(#"{"created":{"key":"DB"},"failed":[]}"#, status: 201) }
        let t = RemoteTarget(service: .vercel, project: "my shop", environment: "preview", branch: "feature/x", tokenItem: "VERCEL_TOKEN", team: "acme")
        let r = remote().push(t, token: token, values: [("DB", "s3cret", true), ("PORT", "3000", false)])
        XCTAssertTrue(succeeded(r))
        let seen = StubProtocol.requests
        XCTAssertEqual(seen.count, 2)
        let first = seen[0]
        XCTAssertEqual(first.method, "POST")
        XCTAssertEqual(first.url.absoluteString, "https://api.vercel.com/v10/projects/my%20shop/env?upsert=true&slug=acme")
        XCTAssertEqual(first.headers["Authorization"], "Bearer \(token)")
        XCTAssertEqual(first.headers["Content-Type"], "application/json")
        let body = json(first.body)
        XCTAssertEqual(body["key"] as? String, "DB")
        XCTAssertEqual(body["value"] as? String, "s3cret")
        XCTAssertEqual(body["type"] as? String, "sensitive")
        XCTAssertEqual(body["target"] as? [String], ["preview"])
        XCTAssertEqual(body["gitBranch"] as? String, "feature/x")
        XCTAssertEqual(json(seen[1].body)["type"] as? String, "plain", "a plain setting isn't secret")
        XCTAssertFalse(seen.contains { $0.url.absoluteString.contains("s3cret") || $0.url.absoluteString.contains(token) }, "values and the token never go in the URL")
    }

    func testSecretsInDevelopmentAreEncryptedNotSensitiveAndTeamIDsUseTeamId() {
        StubProtocol.reset { _ in self.ok(#"{"failed":[]}"#) }
        let t = RemoteTarget(service: .vercel, project: "p", environment: "development", tokenItem: "T", team: "team_123")
        XCTAssertTrue(succeeded(remote().push(t, token: token, values: [("A", "x", true)])))
        XCTAssertEqual(json(StubProtocol.requests[0].body)["type"] as? String, "encrypted")
        XCTAssertTrue(StubProtocol.requests[0].url.absoluteString.hasSuffix("?upsert=true&teamId=team_123"))
        XCTAssertNil(json(StubProtocol.requests[0].body)["gitBranch"])
    }

    func testFailedEntriesAndUnexpectedShapesAreFailuresNotSuccess() {
        let t = RemoteTarget(service: .vercel, project: "p", environment: "production", tokenItem: "T")
        StubProtocol.reset { _ in self.ok(#"{"created":[],"failed":[{"error":{"code":"ENV_ALREADY_EXISTS","message":"s3cret exists"}}]}"#, status: 201) }
        let a = remote().push(t, token: token, values: [("A", "s3cret", true)])
        XCTAssertEqual(error(a), .rejected(status: 201, code: "ENV_ALREADY_EXISTS"))
        StubProtocol.reset { _ in self.ok(#"{"created":{}}"#, status: 201) }
        guard case .badResponse = error(remote().push(t, token: token, values: [("A", "x", true)])) else { return XCTFail("no failed list") }
        StubProtocol.reset { _ in self.ok("<html>", status: 200) }
        guard case .badResponse = error(remote().push(t, token: token, values: [("A", "x", true)])) else { return XCTFail("not JSON") }
        StubProtocol.reset { _ in self.ok(#"{"failed":[]}"#, status: 202) }
        guard case .badResponse = error(remote().push(t, token: token, values: [("A", "x", true)])) else { return XCTFail("202 isn't what the API documents") }
    }

    func testNamesComeFromTheEnvironmentAndBranchOnly() throws {
        StubProtocol.reset { _ in self.ok(#"""
            {"envs":[{"key":"A","value":"v1","target":["production","preview"]},{"key":"B","target":"preview"},
                     {"key":"C","target":["preview"],"gitBranch":"x"},{"key":"D","target":["development"]}]}
            """#) }
        let r = remote()
        XCTAssertEqual(try r.names(RemoteTarget(service: .vercel, project: "p", environment: "preview", tokenItem: "T"), token: token), ["A", "B"])
        XCTAssertEqual(try r.names(RemoteTarget(service: .vercel, project: "p", environment: "preview", branch: "x", tokenItem: "T"), token: token), ["C"])
        XCTAssertEqual(StubProtocol.requests[0].method, "GET")
        XCTAssertEqual(StubProtocol.requests[0].url.absoluteString, "https://api.vercel.com/v10/projects/p/env")
        XCTAssertEqual(StubProtocol.requests[1].url.absoluteString, "https://api.vercel.com/v10/projects/p/env?gitBranch=x")
        StubProtocol.reset { _ in self.ok(#"{"envs":[],"pagination":{"count":0,"next":1700000000000,"prev":null}}"#) }
        XCTAssertThrowsError(try remote().names(RemoteTarget(service: .vercel, project: "p", environment: "preview", tokenItem: "T"), token: token), "an incomplete list isn't reported as complete")
    }
}

final class NativeGitHubTests: NativeRemoteTestCase {
    let recipient = Curve25519.KeyAgreement.PrivateKey()

    func publicKeyJSON() -> String { #"{"key_id":"568250167242549743","key":"\#(Data(recipient.publicKey.rawRepresentation).base64EncodedString())"}"# }

    func testFetchesTheKeyThenPutsASealedValueForRepositoryAndEnvironment() throws {
        StubProtocol.reset { s in s.method == "GET" ? self.ok(self.publicKeyJSON()) : self.ok("", status: 201) }
        let r = remote()
        let repo = RemoteTarget(service: .github, repo: "me/acp", tokenItem: "GH_TOKEN")
        XCTAssertTrue(succeeded(r.push(repo, token: token, values: [("API_KEY", "value-1", true), ("OTHER", "value-2", true)])))
        var seen = StubProtocol.requests
        XCTAssertEqual(seen.map { "\($0.method) \($0.url.path)" }, [
            "GET /repos/me/acp/actions/secrets/public-key", "PUT /repos/me/acp/actions/secrets/API_KEY", "PUT /repos/me/acp/actions/secrets/OTHER",
        ], "the key is fetched once for the whole push")
        XCTAssertEqual(seen[1].headers["Authorization"], "Bearer \(token)")
        XCTAssertEqual(seen[1].headers["Accept"], "application/vnd.github+json")
        XCTAssertNotNil(seen[1].headers["X-GitHub-Api-Version"])
        let body = json(seen[1].body)
        XCTAssertEqual(body["key_id"] as? String, "568250167242549743")
        let sealed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(body["encrypted_value"] as? String)))
        XCTAssertEqual(sealed.count, 32 + 16 + "value-1".utf8.count)
        XCTAssertFalse(String(decoding: seen[1].body, as: UTF8.self).contains("value-1"), "the value is only in sealed form")

        StubProtocol.reset { s in s.method == "GET" ? self.ok(self.publicKeyJSON()) : self.ok("", status: 204) }
        let env = RemoteTarget(service: .github, environment: "prod/blue", repo: "me/acp", tokenItem: "GH_TOKEN")
        XCTAssertTrue(succeeded(remote().push(env, token: token, values: [("API_KEY", "v", true)])))
        seen = StubProtocol.requests
        XCTAssertEqual(seen[0].url.absoluteString, "https://api.github.com/repos/me/acp/environments/prod%2Fblue/secrets/public-key", "an environment name is one path segment")
        XCTAssertEqual(seen[1].url.absoluteString, "https://api.github.com/repos/me/acp/environments/prod%2Fblue/secrets/API_KEY")
    }

    func testRefusesBadNamesAndUnusableKeysAndUnexpectedStatuses() {
        let t = RemoteTarget(service: .github, repo: "me/acp", tokenItem: "T")
        StubProtocol.reset { _ in self.ok(self.publicKeyJSON()) }
        XCTAssertEqual(error(remote().push(t, token: token, values: [("GITHUB_X", "v", true)])), .invalidName("GITHUB_X"))
        XCTAssertTrue(StubProtocol.requests.isEmpty, "a refused name sends nothing, not even the key request")
        XCTAssertEqual(error(remote().push(t, token: token, values: [("A/../B", "v", true)])), .invalidName("A/../B"))
        for repo in ["me", "me/acp/x", "../acp", "me/.."] {
            let e = error(remote().push(RemoteTarget(service: .github, repo: repo, tokenItem: "T"), token: token, values: [("A", "v", true)]))
            XCTAssertNotNil(e, repo)
        }
        StubProtocol.reset { _ in self.ok(#"{"key_id":"1","key":"AAAA"}"#) }
        guard case .badResponse = error(remote().push(t, token: token, values: [("A", "v", true)])) else { return XCTFail("short key") }
        StubProtocol.reset { s in s.method == "GET" ? self.ok(self.publicKeyJSON()) : self.ok("", status: 200) }
        guard case .badResponse = error(remote().push(t, token: token, values: [("A", "v", true)])) else { return XCTFail("200 isn't a documented answer to PUT") }
    }

    func testListPagesUntilTheTotalAndKeepsNamesOnly() throws {
        StubProtocol.reset { s in
            s.url.query?.contains("page=2") == true ? self.ok(#"{"total_count":3,"secrets":[{"name":"C","created_at":"x"}]}"#)
                : self.ok(#"{"total_count":3,"secrets":[{"name":"A"},{"name":"B"}]}"#)
        }
        XCTAssertEqual(try remote().names(RemoteTarget(service: .github, repo: "me/acp", tokenItem: "T"), token: token), ["A", "B", "C"])
        XCTAssertEqual(StubProtocol.requests.map(\.url.query), ["per_page=100&page=1", "per_page=100&page=2"])
        StubProtocol.reset { _ in self.ok(#"{"secrets":"no"}"#) }
        XCTAssertThrowsError(try remote().names(RemoteTarget(service: .github, repo: "me/acp", tokenItem: "T"), token: token))
    }
}

final class NativeRailwayTests: NativeRemoteTestCase {
    let projectReply = #"{"data":{"project":{"id":"p1","environments":{"edges":[{"node":{"id":"e1","name":"production"}},{"node":{"id":"e2","name":"staging"}}]},"services":{"edges":[{"node":{"id":"s1","name":"api"}},{"node":{"id":"s2","name":"web"}}]}}}}"#

    func stub(upsert: String = #"{"data":{"variableUpsert":true}}"#) {
        StubProtocol.reset { s in String(decoding: s.body, as: UTF8.self).contains("variableUpsert") ? self.ok(upsert) : self.ok(self.projectReply) }
    }

    func testResolvesNamesToIDsThenUpsertsWithoutDeploying() throws {
        stub()
        let t = RemoteTarget(service: .railway, project: "p1", environment: "production", serviceName: "api", tokenItem: "RAILWAY_TOKEN")
        XCTAssertTrue(succeeded(remote().push(t, token: token, values: [("DB", "s3cret", true), ("PORT", "3000", false)])))
        let seen = StubProtocol.requests
        XCTAssertEqual(seen.count, 3, "one lookup, then one upsert per value")
        XCTAssertEqual(seen[0].url.absoluteString, "https://backboard.railway.com/graphql/v2")
        XCTAssertEqual(seen[0].headers["Authorization"], "Bearer \(token)")
        XCTAssertNil(seen[0].headers["Project-Access-Token"])
        XCTAssertEqual((json(seen[0].body)["variables"] as? [String: Any])?["id"] as? String, "p1")
        let input = try XCTUnwrap((json(seen[1].body)["variables"] as? [String: Any])?["input"] as? [String: Any])
        XCTAssertEqual(input["projectId"] as? String, "p1")
        XCTAssertEqual(input["environmentId"] as? String, "e1")
        XCTAssertEqual(input["serviceId"] as? String, "s1")
        XCTAssertEqual(input["name"] as? String, "DB")
        XCTAssertEqual(input["value"] as? String, "s3cret")
        XCTAssertEqual(input["skipDeploys"] as? Bool, true)
        XCTAssertTrue((json(seen[1].body)["query"] as? String)?.contains("variableUpsert(input: $input)") == true)
        XCTAssertFalse(String(decoding: seen[0].body, as: UTF8.self).contains("s3cret"), "the lookup carries no values")
    }

    func testUnknownOrAmbiguousNamesAndGraphQLErrorsAreFailures() {
        stub()
        let base = RemoteTarget(service: .railway, project: "p1", environment: "production", serviceName: "api", tokenItem: "T")
        var t = base; t.serviceName = "worker"
        guard case .invalidTarget = error(remote().push(t, token: token, values: [("A", "v", true)])) else { return XCTFail("no such service") }
        XCTAssertEqual(StubProtocol.requests.count, 1, "nothing is set when the target can't be resolved")
        t = base; t.environment = "e2"
        XCTAssertTrue(succeeded(remote().push(t, token: token, values: [("A", "v", true)])), "an ID works as well as a name")

        StubProtocol.reset { _ in self.ok(#"{"data":{"project":{"environments":{"edges":[{"node":{"id":"a","name":"x"}},{"node":{"id":"b","name":"x"}}]},"services":{"edges":[]}}}}"#) }
        t = base; t.environment = "x"
        guard case .invalidTarget(let why) = error(remote().push(t, token: token, values: [("A", "v", true)])) else { return XCTFail("ambiguous") }
        XCTAssertTrue(why.contains("more than one"))

        stub(upsert: #"{"errors":[{"message":"Problem processing request s3cret"}],"data":null}"#)
        XCTAssertEqual(error(remote().push(base, token: token, values: [("A", "s3cret", true)])), .rejected(status: 200, code: "graphql_error"))
        stub(upsert: #"{"data":{"variableUpsert":false}}"#)
        guard case .badResponse = error(remote().push(base, token: token, values: [("A", "v", true)])) else { return XCTFail("false isn't success") }
        StubProtocol.reset { _ in self.ok(#"{"errors":[{"message":"Not Authorized"}]}"#) }
        XCTAssertEqual(error(remote().push(base, token: token, values: [("A", "v", true)])), .unauthorized)
        StubProtocol.reset { _ in self.ok(#"{"data":{"project":null}}"#) }
        XCTAssertEqual(error(remote().push(base, token: token, values: [("A", "v", true)])), .notFound)
    }

    func testNamesKeepOnlyTheKeysOfTheVariablesMap() throws {
        StubProtocol.reset { s in
            String(decoding: s.body, as: UTF8.self).contains("query variables") ? self.ok(#"{"data":{"variables":{"B":"value-b","A":"value-a"}}}"#) : self.ok(self.projectReply)
        }
        let t = RemoteTarget(service: .railway, project: "p1", environment: "production", serviceName: "api", tokenItem: "T")
        XCTAssertEqual(try remote().names(t, token: token), ["A", "B"])
    }
}

final class NativeFlyTests: NativeRemoteTestCase {
    func testOneRequestSetsEverySecretAndMultiLineValuesAreFine() throws {
        StubProtocol.reset { _ in self.ok(#"{"version":7,"secrets":[{"name":"A","value":"1","digest":"d"},{"name":"B","digest":"e"}]}"#) }
        let t = RemoteTarget(service: .fly, app: "shop-api", tokenItem: "FLY_TOKEN")
        XCTAssertTrue(succeeded(remote().push(t, token: token, values: [("A", "1", true), ("B", "line1\nline2", true)])))
        let seen = StubProtocol.requests
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].method, "POST")
        XCTAssertEqual(seen[0].url.absoluteString, "https://api.machines.dev/v1/apps/shop-api/secrets")
        XCTAssertEqual(seen[0].headers["Authorization"], "Bearer \(token)")
        XCTAssertEqual(json(seen[0].body)["values"] as? [String: String], ["A": "1", "B": "line1\nline2"])
    }

    func testResponsesMissingTheVersionOrASecretFail() {
        let t = RemoteTarget(service: .fly, app: "shop-api", tokenItem: "T")
        StubProtocol.reset { _ in self.ok(#"{"secrets":[{"name":"A"}]}"#) }
        guard case .badResponse = error(remote().push(t, token: token, values: [("A", "1", true)])) else { return XCTFail("no version") }
        StubProtocol.reset { _ in self.ok(#"{"version":1,"secrets":[{"name":"A"}]}"#) }
        let r = remote().push(t, token: token, values: [("A", "1", true), ("B", "2", true)])
        XCTAssertEqual(r.count, 2)
        guard case .badResponse = error(r, at: 1) else { return XCTFail("B wasn't echoed") }
    }

    func testNames() throws {
        StubProtocol.reset { _ in self.ok(#"{"secrets":[{"name":"B","digest":"x"},{"name":"A"}]}"#) }
        XCTAssertEqual(try remote().names(RemoteTarget(service: .fly, app: "shop-api", tokenItem: "T"), token: token), ["A", "B"])
        XCTAssertEqual(StubProtocol.requests[0].url.absoluteString, "https://api.machines.dev/v1/apps/shop-api/secrets")
    }
}

final class NativeTransportTests: NativeRemoteTestCase {
    let target = RemoteTarget(service: .fly, app: "shop-api", tokenItem: "T")

    func testOnlyTheServicesHostIsEverContactedAndRedirectsAreNotFollowed() throws {
        let r = remote()
        StubProtocol.reset { _ in self.ok("{}") }
        for url in ["https://evil.example/v1/apps/x/secrets", "http://api.machines.dev/v1/apps/x/secrets", "https://api.machines.dev:8443/x",
                    "https://user@api.machines.dev/x", "https://api.vercel.com/v10/x"] {
            XCTAssertThrowsError(try r.call(.fly, URL(string: url)!, method: "GET", token: token), url) { XCTAssertEqual($0 as? NativeRemoteError, .hostNotAllowed) }
        }
        XCTAssertTrue(StubProtocol.requests.isEmpty, "refused before anything is sent")

        StubProtocol.reset { _ in (302, "", ["Location": "https://evil.example/steal"]) }
        let e = r.push(target, token: token, values: [("A", "1", true)])
        XCTAssertEqual(error(e), .rejected(status: 302, code: nil))
        XCTAssertEqual(StubProtocol.requests.map(\.url.host), ["api.machines.dev"], "the token never follows a redirect")
    }

    func testEveryProvidersRequestsStayOnItsHost() {
        StubProtocol.reset { _ in self.ok("{}") }
        let r = remote()
        _ = r.push(RemoteTarget(service: .vercel, project: "p", environment: "preview", tokenItem: "T"), token: token, values: [("A", "1", true)])
        _ = r.push(RemoteTarget(service: .github, repo: "me/acp", tokenItem: "T"), token: token, values: [("A", "1", true)])
        _ = r.push(RemoteTarget(service: .railway, project: "p", environment: "e", serviceName: "s", tokenItem: "T"), token: token, values: [("A", "1", true)])
        _ = r.push(target, token: token, values: [("A", "1", true)])
        XCTAssertEqual(Set(StubProtocol.requests.map { $0.url.host ?? "" }), ["api.vercel.com", "api.github.com", "backboard.railway.com", "api.machines.dev"])
        XCTAssertEqual(NativeRemote.host(.fly), "api.machines.dev")
    }

    func testResponsesOverTheCapAreRefusedWhetherDeclaredOrStreamed() throws {
        StubProtocol.reset { _ in self.ok(String(repeating: "x", count: 5000)) }
        let t = StubProtocol.transport()
        var request = URLRequest(url: URL(string: "https://api.machines.dev/v1/apps/x/secrets")!)
        request.httpMethod = "GET"
        XCTAssertThrowsError(try t.send(request, maxBytes: 1000, timeout: 5)) { XCTAssertEqual($0 as? NativeRemoteError, .tooLarge) }
        XCTAssertEqual(try t.send(request, maxBytes: 10_000, timeout: 5).body.count, 5000)

        StubProtocol.reset { _ in self.ok(String(repeating: "x", count: Int(NativeRemote.maxResponseBytes) + 10)) }
        XCTAssertEqual(error(remote().push(target, token: token, values: [("A", "1", true)])), .tooLarge)
    }

    func testStatusesMapToTypedErrorsAndOnlyTransientOnesRetryUpToTheBound() {
        func run(_ status: Int, headers: [String: String] = [:]) -> (NativeRemoteError?, Int) {
            StubProtocol.reset { _ in (status, #"{"error":{"code":"bad_thing","message":"nope"}}"#, headers) }
            let e = error(remote().push(target, token: token, values: [("A", "1", true)]))
            return (e, StubProtocol.requests.count)
        }
        XCTAssertEqual(run(401).0, .unauthorized); XCTAssertEqual(run(401).1, 1)
        XCTAssertEqual(run(403).0, .unauthorized)
        XCTAssertEqual(run(404).0, .notFound)
        XCTAssertEqual(run(400).0, .rejected(status: 400, code: "bad_thing")); XCTAssertEqual(run(400).1, 1)
        XCTAssertEqual(run(500).0, .rejected(status: 500, code: "bad_thing")); XCTAssertEqual(run(500).1, 1, "500 isn't retried")
        let limited = run(429, headers: ["Retry-After": "2"])
        XCTAssertEqual(limited.0, .rateLimited)
        XCTAssertEqual(limited.1, NativeRemote.maxAttempts)
        XCTAssertEqual(pauses.values, [2, 2], "waits as told, between tries only")
        XCTAssertEqual(run(503).0, .unavailable(503)); XCTAssertEqual(run(503).1, NativeRemote.maxAttempts)
        _ = run(429, headers: ["Retry-After": "3600"])
        XCTAssertEqual(pauses.values.max(), NativeRemote.maxPause, "a long Retry-After is capped")
    }

    func testARateLimitThatClearsSucceeds() {
        StubProtocol.reset { _ in StubProtocol.requests.count < 2 ? (429, "", [:]) : self.ok(#"{"version":1,"secrets":[{"name":"A"}]}"#) }
        XCTAssertTrue(succeeded(remote().push(target, token: token, values: [("A", "1", true)])))
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    func testTimeoutsAndNetworkFailuresAreTypedAndNotRetried() {
        StubProtocol.reset { _ in nil }
        StubProtocol.lock.withLock { StubProtocol.failure = .timedOut }
        XCTAssertEqual(error(remote().push(target, token: token, values: [("A", "1", true)])), .timedOut)
        StubProtocol.lock.withLock { StubProtocol.failure = .notConnectedToInternet }
        XCTAssertEqual(error(remote().push(target, token: token, values: [("A", "1", true)])), .network)
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    func testNoErrorMessageContainsTheTokenOrAValueEvenIfTheServiceEchoesThem() {
        let value = "super-secret-value-123"
        let echoing = #"{"error":{"code":"x","message":"bad \#(token) and \#(value)"},"message":"\#(token) \#(value)","errors":[{"message":"\#(value)"}],"failed":[{"error":{"code":"\#(value)","message":"\#(token)"}}]}"#
        let targets: [RemoteTarget] = [
            RemoteTarget(service: .vercel, project: "p", environment: "preview", tokenItem: "T"),
            RemoteTarget(service: .github, repo: "me/acp", tokenItem: "T"),
            RemoteTarget(service: .railway, project: "p", environment: "e", serviceName: "s", tokenItem: "T"),
            target,
        ]
        for status in [200, 201, 400, 401, 404, 409, 422, 429, 500, 503] {
            for t in targets {
                StubProtocol.reset { _ in (status, echoing, [:]) }
                let r = remote()
                var messages = r.push(t, token: token, values: [("A", value, true)]).compactMap { if case .failure(let e) = $0 { return e.message } else { return nil } }
                do { _ = try r.names(t, token: token) } catch { messages.append((error as? NativeRemoteError)?.message ?? "not a NativeRemoteError") }
                for m in messages { XCTAssertFalse(m.contains(token) || m.contains(value), "\(t.service) \(status): \(m)") }
            }
        }
        XCTAssertFalse(NativeRemoteError.badToken.message.contains(token))
    }

    func testATokenThatCouldSmuggleAHeaderIsRefusedBeforeAnyRequest() {
        StubProtocol.reset { _ in self.ok("{}") }
        for bad in ["", "   ", "abc\r\nX-Evil: 1", "two words", "tab\there"] {
            XCTAssertEqual(error(remote().push(target, token: bad, values: [("A", "1", true)])), .badToken, bad.debugDescription)
        }
        XCTAssertTrue(StubProtocol.requests.isEmpty)
        _ = remote().push(target, token: "  \(token)\n", values: [("A", "1", true)])
        XCTAssertEqual(StubProtocol.requests.first?.headers["Authorization"], "Bearer \(token)", "surrounding whitespace is trimmed")
    }

    func testTargetsTheAPICantUseAreRefused() {
        StubProtocol.reset { _ in self.ok("{}") }
        let dirOnly = RemoteTarget(service: .vercel, environment: "preview", directory: "/tmp/p", tokenItem: "T")
        guard case .invalidTarget(let why)? = error(remote().push(dirOnly, token: token, values: [("A", "1", true)])) else { return XCTFail() }
        XCTAssertTrue(why.contains("linked folder"))
        XCTAssertNotNil(RemoteTarget(service: .railway, environment: "e", serviceName: "s", directory: "/tmp/p").nativeProblem)
        XCTAssertNotNil(RemoteTarget(service: .github, repo: "me/acp", team: "acme").nativeProblem)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }
}

final class RemoteLinkCompatibilityTests: XCTestCase {
    func testLinksSavedBeforeTheTokenFieldDecodeUnchangedAndOmitItWhenEmpty() throws {
        let old = #"{"id":"L1","scope":"acp/production","created":"2026-01-02T03:04:05Z","pushed":{},"target":{"service":"vercel","project":"acp","environment":"production"}}"#
        let link = try Wire.decoder().decode(RemoteLink.self, from: Data(old.utf8))
        XCTAssertNil(link.target.tokenItem)
        XCTAssertNil(link.target.team)
        XCTAssertEqual(link.target, RemoteTarget(service: .vercel, project: "acp", environment: "production"))
        let encoded = String(decoding: try Wire.encoder().encode(link), as: UTF8.self)
        XCTAssertFalse(encoded.contains("tokenItem"))
        XCTAssertFalse(encoded.contains("team"))

        var withToken = link
        withToken.target.tokenItem = "VERCEL_TOKEN"
        let back = try Wire.decoder().decode(RemoteLink.self, from: try Wire.encoder().encode(withToken))
        XCTAssertEqual(back.target.tokenItem, "VERCEL_TOKEN")
    }
}

final class NativeBrokerTests: NativeRemoteTestCase {
    let peer = PeerInfo(pid: 1, path: "/usr/local/bin/latchkey", cwd: "/tmp", chain: ["zsh"])

    func make(_ decision: ApprovalDecision = .once, nativeOnly: Bool = false, remotes: MemoryRemoteStore = MemoryRemoteStore()) throws
        -> (Broker, FakeRunner, CountingDecisions) {
        let store = MemoryStore()
        try store.save(name: "acp/production/DB", value: "db-secret-value", kind: .password, agentSafe: false, note: "")
        try store.save(name: "acp/production/HOST", value: "h.example", kind: .value, agentSafe: true, note: "")
        try store.save(name: "VERCEL_TOKEN", value: token, kind: .token, agentSafe: false, note: "")
        let runner = FakeRunner(), approver = CountingDecisions(decision)
        return (Broker(store: store, approver: approver, logURL: nil, remotes: remotes, runner: runner, native: remote(), nativeOnly: nativeOnly), runner, approver)
    }

    func link(_ b: Broker, _ target: RemoteTarget) -> Response {
        b.handle(Request(op: "link", names: ["acp/production"], target: target), peer: peer)
    }

    let vercel = RemoteTarget(service: .vercel, project: "acp", environment: "production", tokenItem: "VERCEL_TOKEN")

    func testAPushThroughATokenItemUsesTheTokenAndNamesItInTheApproval() throws {
        StubProtocol.reset { _ in self.ok(#"{"failed":[]}"#, status: 201) }
        let (b, runner, approver) = try make()
        let l = try XCTUnwrap(link(b, vercel).links?.first)
        XCTAssertTrue(approver.requests.last!.targets.first!.contains("VERCEL_TOKEN"), "approving a link names the token item")
        let r = b.handle(Request(op: "push", names: ["acp/production"]), peer: peer)
        XCTAssertTrue(r.ok, r.error ?? "")
        let asked = approver.requests.last!
        XCTAssertEqual(asked.action, .push)
        XCTAssertEqual(asked.targets, ["Vercel acp · production (token: VERCEL_TOKEN)"])
        XCTAssertTrue(asked.reason.contains("VERCEL_TOKEN"))
        XCTAssertTrue(asked.production, "production confirmation is unchanged")
        XCTAssertFalse(asked.names.contains("VERCEL_TOKEN"), "the token isn't one of the pushed items")
        XCTAssertTrue(runner.ran.isEmpty, "no command-line tool runs for a link with a token item")
        XCTAssertEqual(Set(StubProtocol.requests.map { json($0.body)["key"] as? String ?? "" }), ["DB", "HOST"])
        XCTAssertTrue(StubProtocol.requests.allSatisfy { $0.headers["Authorization"] == "Bearer \(token)" })
        XCTAssertNotNil(try b.remotes.all().first { $0.id == l.id }?.pushed["acp/production/DB"])
        let wire = String(decoding: try Wire.encoder().encode(r), as: UTF8.self)
        XCTAssertFalse(wire.contains(token) || wire.contains("db-secret-value"), "the response carries neither the token nor a value")
    }

    func testADenialOrAMissingTokenSendsNothing() throws {
        StubProtocol.reset { _ in self.ok(#"{"failed":[]}"#) }
        let (denying, _, approver) = try make(.deny)
        XCTAssertNotNil(CountingDecisions.allow(denying).handle(Request(op: "link", names: ["acp/production"], target: vercel), peer: peer).links)
        XCTAssertFalse(denying.handle(Request(op: "push", names: ["acp/production"]), peer: peer).ok)
        XCTAssertTrue(approver.requests.last!.production)
        XCTAssertTrue(StubProtocol.requests.isEmpty)

        // A link saved with a token item that has since been deleted is refused before anyone is asked.
        let remotes = MemoryRemoteStore()
        let (b, _, approver2) = try make(remotes: remotes)
        try remotes.save(RemoteLink(scope: "acp/production", target: RemoteTarget(service: .vercel, project: "acp", environment: "production", tokenItem: "GONE")))
        let r = b.handle(Request(op: "push", names: ["acp/production"]), peer: peer)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.error!.contains("GONE"))
        XCTAssertTrue(approver2.requests.isEmpty)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testLinkingChecksTheTokenItem() throws {
        let (b, _, _) = try make()
        var t = vercel
        t.tokenItem = "NOPE"
        XCTAssertTrue(link(b, t).error!.contains("no item NOPE"))
        t.tokenItem = "acp/production/DB"
        XCTAssertTrue(link(b, t).error!.contains("inside acp/production"), "the token can't be one of the values pushed with it")
        t.tokenItem = "not valid"
        XCTAssertFalse(link(b, t).ok)
        t = RemoteTarget(service: .vercel, environment: "production", directory: "/tmp/p", tokenItem: "VERCEL_TOKEN")
        XCTAssertTrue(link(b, t).error!.contains("linked folder"))
        XCTAssertTrue(link(b, vercel).ok)
    }

    func testTheDirectBuildKeepsTheToolPathUnlessATokenIsLinked() throws {
        StubProtocol.reset { _ in self.ok(#"{"failed":[]}"#) }
        let (b, runner, _) = try make()
        XCTAssertTrue(link(b, RemoteTarget(service: .vercel, project: "acp", environment: "production")).ok)
        XCTAssertTrue(b.handle(Request(op: "push", names: ["acp/production"]), peer: peer).ok)
        XCTAssertEqual(runner.ran.count, 2, "no token item: the vercel tool, as before")
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testTheStoreBuildNeverRunsATool() throws {
        StubProtocol.reset { _ in self.ok(#"{"failed":[]}"#) }
        let remotes = MemoryRemoteStore()
        let (b, runner, approver) = try make(nativeOnly: true, remotes: remotes)
        XCTAssertTrue(link(b, RemoteTarget(service: .vercel, project: "acp", environment: "production")).error!.contains("token"))
        // A link made before (by the direct build, say) with no token item can't push or list here.
        try remotes.save(RemoteLink(scope: "acp/production", target: RemoteTarget(service: .github, repo: "me/acp")))
        let r = b.handle(Request(op: "push", names: ["acp/production"]), peer: peer)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.error!.contains("token"))
        XCTAssertTrue(approver.requests.isEmpty)
        let status = try XCTUnwrap(b.handle(Request(op: "remote-status", names: ["acp/production"]), peer: peer).remoteStatus?.first)
        XCTAssertNotNil(status.error)
        XCTAssertTrue(runner.ran.isEmpty)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
        let result = UnavailableRunner().run(RemoteCommand(tool: "vercel", args: [], stdin: nil, directory: nil), timeout: 1)
        XCTAssertEqual(result.status, 126)
    }

    func testStatusListsNamesThroughTheTokenAndReportsFailuresWithoutIt() throws {
        StubProtocol.reset { _ in self.ok(#"{"envs":[{"key":"HOST","value":"leaked?","target":["production"]},{"key":"ONLY_THERE","target":["production"]}]}"#) }
        let (b, runner, _) = try make()
        XCTAssertTrue(link(b, vercel).ok)
        let s = try XCTUnwrap(b.handle(Request(op: "remote-status", names: ["acp/production"]), peer: peer).remoteStatus?.first)
        XCTAssertEqual(s.missing, ["DB"])
        XCTAssertEqual(s.extra, ["ONLY_THERE"])
        XCTAssertEqual(StubProtocol.requests.first?.headers["Authorization"], "Bearer \(token)")
        XCTAssertTrue(runner.ran.isEmpty)
        let wire = String(decoding: try Wire.encoder().encode(s), as: UTF8.self)
        XCTAssertFalse(wire.contains("leaked?"), "values that come back with names are dropped")

        StubProtocol.reset { _ in (401, #"{"error":{"message":"bad token \#(self.token)"}}"#, [:]) }
        let failed = try XCTUnwrap(b.handle(Request(op: "remote-status", names: ["acp/production"]), peer: peer).remoteStatus?.first)
        XCTAssertEqual(failed.error, NativeRemoteError.unauthorized.message)
        XCTAssertFalse(failed.error!.contains(token))
    }

    func testAFailedPushIsReportedWithoutTheTokenOrTheValue() throws {
        StubProtocol.reset { _ in (400, #"{"error":{"code":"invalid_value","message":"\#(self.token) db-secret-value"}}"#, [:]) }
        let (b, _, _) = try make()
        XCTAssertTrue(link(b, vercel).ok)
        let r = b.handle(Request(op: "push", names: ["acp/production"]), peer: peer)
        XCTAssertFalse(r.ok)
        let failures = r.pushResults?.filter { !$0.ok } ?? []
        XCTAssertEqual(failures.count, 2)
        for f in failures { XCTAssertFalse(f.error!.contains(token) || f.error!.contains("db-secret-value"), f.error!) }
        XCTAssertTrue(failures.first!.error!.contains("invalid_value"))
        XCTAssertNil(try b.remotes.all().first?.pushed["acp/production/DB"], "a failed push isn't recorded")
    }
}
