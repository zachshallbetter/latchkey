import XCTest
@testable import LatchkeyCore

final class BrokerTests: XCTestCase {
    let peer = PeerInfo(pid: 1, path: "/usr/local/bin/latchkey", cwd: "/tmp/project", chain: ["zsh", "claude"])

    func makeBroker(approve: Bool, window: TimeInterval = 0) throws -> (Broker, MemoryStore) {
        let store = MemoryStore()
        try store.save(name: "SAFE_TOKEN", value: "safe-value-123", kind: .token, agentSafe: true, note: "")
        try store.save(name: "DB_PASS", value: "db-password-456", kind: .password, agentSafe: false, note: "")
        try store.save(name: "HOST", value: "10.0.0.1", kind: .value, agentSafe: true, note: "")
        return (Broker(store: store, approver: FixedApprover(approve), readApprovalWindow: window, logURL: nil), store)
    }

    func testAgentSafeReleasedWithoutApproval() throws {
        let (b, _) = try makeBroker(approve: false)
        let r = b.handle(Request(op: "get", names: ["SAFE_TOKEN", "HOST", "NOPE"]), peer: peer)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.values, ["SAFE_TOKEN": "safe-value-123", "HOST": "10.0.0.1"])
        XCTAssertEqual(r.masked, ["SAFE_TOKEN"])
        XCTAssertEqual(r.missing, ["NOPE"])
        XCTAssertNil(r.denied)
    }

    func testOtherItemsNeedApproval() throws {
        let (deny, _) = try makeBroker(approve: false)
        let r = deny.handle(Request(op: "get", names: ["DB_PASS", "SAFE_TOKEN"]), peer: peer)
        XCTAssertEqual(r.denied, ["DB_PASS"])
        XCTAssertEqual(r.values, [:])

        let (allow, _) = try makeBroker(approve: true)
        let r2 = allow.handle(Request(op: "get", names: ["DB_PASS"]), peer: peer)
        XCTAssertEqual(r2.values, ["DB_PASS": "db-password-456"])
    }

    func testChangesNeedApprovalAndKeepMetadata() throws {
        let (deny, store) = try makeBroker(approve: false)
        XCTAssertFalse(deny.handle(Request(op: "set", names: ["DB_PASS"], value: "x"), peer: peer).ok)
        XCTAssertFalse(deny.handle(Request(op: "rm", names: ["DB_PASS"]), peer: peer).ok)
        XCTAssertEqual(try store.values(["DB_PASS"]), ["DB_PASS": "db-password-456"])

        let (allow, store2) = try makeBroker(approve: true)
        XCTAssertTrue(allow.handle(Request(op: "set", names: ["DB_PASS"], value: "new-password-789"), peer: peer).ok)
        let info = try store2.info("DB_PASS")
        XCTAssertEqual(info?.kind, .password)
        XCTAssertEqual(info?.agentSafe, false)
        XCTAssertTrue(allow.handle(Request(op: "rm", names: ["DB_PASS"]), peer: peer).ok)
        XCTAssertNil(try store2.info("DB_PASS"))
        XCTAssertEqual(allow.handle(Request(op: "rm", names: ["DB_PASS"]), peer: peer).missing, ["DB_PASS"])
    }

    func testApprovalMemoryIsPerPlaceAndExpires() {
        let m = ApprovalMemory()
        let now = Date()
        let k = ApprovalMemory.key(["A"], peer)
        m.remember(k, for: 60, now: now)
        XCTAssertTrue(m.covers(k, now: now.addingTimeInterval(30)))
        XCTAssertFalse(m.covers(k, now: now.addingTimeInterval(61)))
        var elsewhere = peer
        elsewhere.cwd = "/tmp/other"
        XCTAssertFalse(m.covers(ApprovalMemory.key(["A"], elsewhere), now: now))
        XCTAssertFalse(m.covers(ApprovalMemory.key(["A", "B"], peer), now: now))
    }

    func testDescribe() {
        let s = Broker.describe(peer, Request(op: "get", cwd: NSHomeDirectory() + "/site", command: "npm test"))
        XCTAssertEqual(s, "zsh › claude in ~/site (running npm test)")
    }

    /// Writes to the real login keychain, so it runs only when asked: LATCHKEY_KEYCHAIN_TESTS=1 swift test
    func testKeychainRoundTrip() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LATCHKEY_KEYCHAIN_TESTS"] == "1")
        let store = KeychainStore(mode: .thisMac)
        let name = "latchkey-test-\(UUID().uuidString.prefix(8))"
        defer { _ = try? store.remove(name) }
        try store.save(name: name, value: "round-trip-value", kind: .key, agentSafe: true, note: "test item")
        XCTAssertEqual(try store.values([name]), [name: "round-trip-value"])
        try store.save(name: name, value: nil, kind: nil, agentSafe: false, note: nil)
        let info = try XCTUnwrap(store.info(name))
        XCTAssertEqual(info.kind, .key)
        XCTAssertFalse(info.agentSafe)
        XCTAssertEqual(info.note, "test item")
        XCTAssertEqual(try store.values([name]), [name: "round-trip-value"])
        XCTAssertTrue(try store.remove(name))
        XCTAssertFalse(try store.remove(name))
    }
}
