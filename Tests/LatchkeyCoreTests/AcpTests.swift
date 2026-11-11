import CryptoKit
import XCTest
@testable import LatchkeyCore

/// Stands in for ACP's /internal/verify-capability.
struct FakeVerifier: AcpVerifier {
    var answer: Result<String?, Error> = .success(nil)
    func check(_ token: String, trust: Acp.Trust, bearer: String) -> Result<String?, Error> { answer }
}

final class AcpTests: XCTestCase {
    let key = Curve25519.Signing.PrivateKey()
    var trust: Acp.Trust!
    var root: URL!

    override func setUpWithError() throws {
        trust = Acp.Trust(url: "https://acp.example.test", keyID: "lk-1", publicKey: key.publicKey.rawRepresentation.base64EncodedString(),
                          gatewayTokenItem: "ACP_GATEWAY_TOKEN")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lk-acp-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        let git = root.appendingPathComponent("acp-gateway/.git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:me/acp-gateway.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
            .write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("acp-gateway/api"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func claims(items: [String] = ["acp-gateway/development/*"], exp: Double = Date().timeIntervalSince1970 + 300,
                aud: String = "latchkey", kid: String = "lk-1", duration: Double = 3600, repo: String = "acp-gateway") -> Acp.Claims {
        Acp.Claims(v: 1, aud: aud, kid: kid, jti: UUID().uuidString, iat: Date().timeIntervalSince1970, exp: exp,
                   sub: "sub-agent-7", act: "coordinator-2", ticket: "LAT-42",
                   repository: .init(owner: "me", name: repo), items: items, duration: duration, requestID: "r1")
    }

    func testSignatureAudienceKeyAndExpiry() throws {
        let good = try Acp.sign(claims(), with: key)
        XCTAssertEqual(try Acp.verify(good, trust: trust).sub, "sub-agent-7")
        XCTAssertThrowsError(try Acp.verify(try Acp.sign(claims(), with: Curve25519.Signing.PrivateKey()), trust: trust)) { XCTAssertEqual($0 as? Acp.Refusal, .signature) }
        XCTAssertThrowsError(try Acp.verify(try Acp.sign(claims(aud: "other"), with: key), trust: trust)) { XCTAssertEqual($0 as? Acp.Refusal, .audience) }
        XCTAssertThrowsError(try Acp.verify(try Acp.sign(claims(kid: "lk-2"), with: key), trust: trust)) { XCTAssertEqual($0 as? Acp.Refusal, .keyID) }
        XCTAssertThrowsError(try Acp.verify(try Acp.sign(claims(exp: 1), with: key), trust: trust)) { XCTAssertEqual($0 as? Acp.Refusal, .expired) }
        XCTAssertThrowsError(try Acp.verify("not.a token", trust: trust))
        // A changed payload under the old signature fails.
        let parts = good.split(separator: ".")
        let tampered = Acp.b64url(try JSONEncoder().encode(claims(items: ["acp-gateway/production/*"]))) + "." + parts[1]
        XCTAssertThrowsError(try Acp.verify(tampered, trust: trust)) { XCTAssertEqual($0 as? Acp.Refusal, .signature) }
    }

    func testLimitsNeverReachProduction() throws {
        XCTAssertNoThrow(try Acp.checkLimits(claims(items: ["acp-gateway/development/*", "acp-gateway/vercel.preview/DB"]), trust: trust))
        for bad in [["acp-gateway/production/*"], ["acp-gateway/*"], ["GEMINI_API_KEY"], ["acp-gateway/staging/*"], ["acp-gateway/vercel.production/X"]] {
            XCTAssertThrowsError(try Acp.checkLimits(claims(items: bad), trust: trust), "\(bad)")
        }
        var t = trust!
        t.environments = ["development", "production"]
        XCTAssertNotNil(t.problem, "trust can't include production")
        t = trust!; t.url = "http://acp.example.test"
        XCTAssertNotNil(t.problem)
        XCTAssertNil(trust.problem)
        XCTAssertEqual(Acp.originRepository(commonDir: root.appendingPathComponent("acp-gateway/.git").path)?.name, "acp-gateway")
    }

    func broker(_ verifier: FakeVerifier = FakeVerifier(), trusted: Bool = true) throws -> Broker {
        let store = MemoryStore()
        try store.save(name: "ACP_GATEWAY_TOKEN", value: "gateway-bearer", kind: .token, agentSafe: false, note: "")
        try store.save(name: "acp-gateway/development/DB", value: "db", kind: .password, agentSafe: false, note: "")
        return Broker(store: store, approver: FixedApprover(false), readApprovalWindow: 0, logURL: nil,
                      acpTrust: MemoryAcpTrustStore(trusted ? trust : nil), acpVerifier: verifier)
    }

    func testRedeemMakesAnACPGrantOnceAndReadsUseIt() throws {
        let b = try broker()
        let cwd = root.appendingPathComponent("acp-gateway/api").path
        let peer = PeerInfo(pid: 1, path: "/usr/local/bin/latchkey", cwd: cwd, chain: ["zsh", "claude"])
        let token = try Acp.sign(claims(duration: 99_999), with: key)
        let r = b.handle(Request(op: "acp-redeem", cwd: cwd, capability: token), peer: peer)
        XCTAssertTrue(r.ok, r.error ?? "")
        let g = try XCTUnwrap(r.grants?.first)
        XCTAssertEqual(g.issuer, "acp")
        XCTAssertEqual(g.agent, "sub-agent-7")
        XCTAssertEqual(g.ticket, "LAT-42")
        XCTAssertEqual(g.folder, root.appendingPathComponent("acp-gateway").path, "the repository's main checkout")
        XCTAssertLessThanOrEqual(g.expires.timeIntervalSinceNow, 7200 + 1, "capped at the owner's limit")
        // The approver denies everything, so this read only works through the ACP grant.
        XCTAssertEqual(b.handle(Request(op: "get", names: ["acp-gateway/development/DB"], cwd: cwd), peer: peer).values?["acp-gateway/development/DB"], "db")
        XCTAssertFalse(b.handle(Request(op: "acp-redeem", cwd: cwd, capability: token), peer: peer).ok, "single use")

        // Stop trusting ACP: its grants end, and nothing else needs approving.
        _ = b.grants.add(names: ["X"], folder: "/tmp", duration: 60, createdBy: "owner")
        XCTAssertTrue(b.handle(Request(op: "acp-untrust"), peer: peer).ok)
        XCTAssertEqual(b.grants.all().map(\.createdBy), ["owner"])
        XCTAssertFalse(b.handle(Request(op: "acp-redeem", cwd: cwd, capability: try Acp.sign(claims(), with: key)), peer: peer).ok)
    }

    func testRefusalsFromACPFromTheRepositoryAndWithoutTrust() throws {
        let cwd = root.appendingPathComponent("acp-gateway").path
        let peer = PeerInfo(pid: 1, path: "", cwd: cwd, chain: ["zsh"])
        let invalid = try broker(FakeVerifier(answer: .success("REVOKED")))
        XCTAssertTrue(invalid.handle(Request(op: "acp-redeem", cwd: cwd, capability: try Acp.sign(claims(), with: key)), peer: peer).error!.contains("REVOKED"))
        let down = try broker(FakeVerifier(answer: .failure(Acp.Refusal.unreachable("timed out"))))
        XCTAssertFalse(down.handle(Request(op: "acp-redeem", cwd: cwd, capability: try Acp.sign(claims(), with: key)), peer: peer).ok, "fails closed")
        XCTAssertTrue(down.grants.all().isEmpty)
        let wrongRepo = try broker()
        XCTAssertTrue(wrongRepo.handle(Request(op: "acp-redeem", cwd: cwd, capability: try Acp.sign(claims(repo: "other"), with: key)), peer: peer).error!.contains("wrong repository"))
        XCTAssertFalse(wrongRepo.handle(Request(op: "acp-redeem", cwd: FileManager.default.temporaryDirectory.path, capability: try Acp.sign(claims(), with: key)), peer: peer).ok)
        let untrusted = try broker(trusted: false)
        XCTAssertTrue(untrusted.handle(Request(op: "acp-redeem", cwd: cwd, capability: try Acp.sign(claims(), with: key)), peer: peer).error!.contains("isn't trusted"))
    }

    func testTrustingAsksAndNeedsTheGatewayTokenItem() throws {
        let store = MemoryStore()
        let deny = Broker(store: store, approver: FixedApprover(false), logURL: nil, acpTrust: MemoryAcpTrustStore())
        XCTAssertTrue(deny.handle(Request(op: "acp-trust", acpTrust: trust), peer: PeerInfo(pid: 1, path: "", cwd: "", chain: ["zsh"])).error!.contains("no item named"))
        try store.save(name: "ACP_GATEWAY_TOKEN", value: "t", kind: nil, agentSafe: nil, note: nil)
        XCTAssertFalse(deny.handle(Request(op: "acp-trust", acpTrust: trust), peer: PeerInfo(pid: 1, path: "", cwd: "", chain: ["zsh"])).ok)
        XCTAssertNil(deny.acpTrust?.load())
        let allow = Broker(store: store, approver: FixedApprover(true), logURL: nil, acpTrust: MemoryAcpTrustStore())
        XCTAssertTrue(allow.handle(Request(op: "acp-trust", acpTrust: trust), peer: PeerInfo(pid: 1, path: "", cwd: "", chain: ["zsh"])).ok)
        XCTAssertEqual(allow.acpTrust?.load()?.keyID, "lk-1")
    }
}
