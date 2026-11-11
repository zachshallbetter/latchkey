import XCTest
@testable import LatchkeyCore

private final class SwitchingApprover: Approver, @unchecked Sendable {
    var next: ApprovalDecision = .once
    var calls = 0
    var method: String { "test" }
    func approve(_ request: ApprovalRequest) -> ApprovalDecision { calls += 1; return next }
}

final class AuthorizationTests: XCTestCase {
    private func fixture() throws -> (Broker, SwitchingApprover, PeerInfo) {
        let store = MemoryStore()
        try store.save(name: "KEY", value: "fixture-key", kind: .token, agentSafe: false, note: "")
        let approver = SwitchingApprover()
        let broker = Broker(store: store, approver: approver, logURL: nil)
        let peer = PeerInfo(pid: 123, path: "/test/lk", cwd: "/tmp/project", chain: ["zsh", "agent"],
                            arguments: ["lk", "run", "--", "npm", "test"], isLatchkeyTool: true)
        return (broker, approver, peer)
    }

    func testAllowOnceRequiresApprovalOnTheNextRequest() throws {
        let (broker, approver, peer) = try fixture()
        XCTAssertNotNil(broker.handle(Request(op: "get", names: ["KEY"]), peer: peer).values?["KEY"])
        let check = broker.handle(Request(op: "check", names: ["KEY"]), peer: peer)
        XCTAssertEqual(check.needsApproval, ["KEY"])
        XCTAssertNil(check.remembered)
        approver.next = .deny
        XCTAssertNil(broker.handle(Request(op: "get", names: ["KEY"]), peer: peer).values?["KEY"])
        XCTAssertEqual(approver.calls, 2)
    }

    func testCommandGrantCannotAuthorizeRawGetAndRevocationTakesEffectImmediately() throws {
        let (broker, approver, peer) = try fixture()
        approver.next = .grant(GrantChoice(duration: 3600, thisCommandOnly: true))
        XCTAssertNotNil(broker.handle(Request(op: "get", names: ["KEY"]), peer: peer).values?["KEY"])
        let grant = try XCTUnwrap(broker.grants.all().first)
        approver.next = .deny
        var raw = peer; raw.arguments = ["lk", "get", "KEY"]
        XCTAssertNil(broker.handle(Request(op: "get", names: ["KEY"]), peer: raw).values?["KEY"])
        XCTAssertNotNil(broker.handle(Request(op: "get", names: ["KEY"]), peer: peer).values?["KEY"])
        _ = broker.handle(Request(op: "revoke", names: [grant.id]), peer: peer)
        XCTAssertNil(broker.handle(Request(op: "get", names: ["KEY"]), peer: peer).values?["KEY"])
    }

    func testSessionAndOneUseLimitsHaveNoCachedEscape() throws {
        let (broker, approver, original) = try fixture()
        let stamp = ProcessStamp(pid: getpid(), started: try XCTUnwrap(PeerInfo.started(getpid())))
        var peer = original; peer.chain = ["agent"]; peer.ancestors = [stamp]
        approver.next = .grant(GrantChoice(duration: 3600, untilAgentQuits: true))
        _ = broker.handle(Request(op: "get", names: ["KEY"]), peer: peer)
        approver.next = .deny
        var otherSession = peer; otherSession.ancestors = []
        XCTAssertNil(broker.handle(Request(op: "get", names: ["KEY"]), peer: otherSession).values?["KEY"])
        _ = broker.handle(Request(op: "revoke", names: ["all"]), peer: peer)
        broker.grants.add(names: ["KEY"], folder: peer.cwd, duration: 3600, createdBy: "test", uses: 1)
        XCTAssertNotNil(broker.handle(Request(op: "get", names: ["KEY"]), peer: peer).values?["KEY"])
        XCTAssertNil(broker.handle(Request(op: "get", names: ["KEY"]), peer: peer).values?["KEY"])
    }

    func testURLCredentialsNeverReachTheActivityLog() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MemoryStore()
        try store.save(name: "KEY", value: "fixture-key", kind: .token, agentSafe: true, note: "")
        let broker = Broker(store: store, approver: FixedApprover(true), logURL: url, logKeys: MemoryLogKeyStore())
        let peer = PeerInfo(pid: 123, path: "/test/lk", cwd: "/tmp", chain: ["zsh"],
                            arguments: ["lk", "run", "--", "psql", "postgres://user:fixture-password@host/db", "https://host/?access_token=fixture-query"])
        _ = broker.handle(Request(op: "get", names: ["KEY"]), peer: peer)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("fixture-password"))
        XCTAssertFalse(text.contains("fixture-query"))
        XCTAssertEqual(broker.handle(Request(op: "verify-log"), peer: peer).info?["result"], "intact")
        let shell = Redact.arguments(["-c", "psql postgres://u:fixture-password@host/db"])
        XCTAssertFalse(shell.joined().contains("fixture-password"))
    }
}
