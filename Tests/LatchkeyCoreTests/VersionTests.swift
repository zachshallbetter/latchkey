import XCTest
@testable import LatchkeyCore

final class VersionTests: XCTestCase {
    let peer = PeerInfo(pid: 1, path: "/usr/local/bin/latchkey", cwd: "/tmp", chain: ["zsh"])

    func make(_ approve: Bool = true) throws -> (Broker, MemoryStore, MemoryVersionStore) {
        let store = MemoryStore(), versions = MemoryVersionStore()
        try store.save(name: "acp/development/DB", value: "one", kind: .password, agentSafe: false, note: "n", usedIn: ["/r/.env"], service: "Neon")
        return (Broker(store: store, approver: FixedApprover(approve), logURL: nil, versions: versions), store, versions)
    }

    func testChangesAndDeletesKeepTheOldValue() throws {
        let (b, store, versions) = try make()
        XCTAssertTrue(b.handle(Request(op: "set", names: ["acp/development/DB"], value: "two"), peer: peer).ok)
        XCTAssertTrue(b.handle(Request(op: "set", names: ["acp/development/DB"], value: "two"), peer: peer).ok)
        let h = try XCTUnwrap(b.handle(Request(op: "history", names: ["acp/development/DB"]), peer: peer).versions)
        XCTAssertEqual(h.count, 1, "an unchanged value adds no version")
        XCTAssertEqual(h[0].reason, .changed)
        XCTAssertEqual(h[0].by, "zsh")
        XCTAssertEqual(try versions.value(h[0].id), "one")

        XCTAssertTrue(b.handle(Request(op: "rm", names: ["acp/development/DB"]), peer: peer).ok)
        XCTAssertNil(try store.info("acp/development/DB"))
        let gone = try XCTUnwrap(b.handle(Request(op: "deleted"), peer: peer).versions)
        XCTAssertEqual(gone.map(\.item), ["acp/development/DB"])
        XCTAssertEqual(try versions.value(gone[0].id), "two")

        XCTAssertTrue(b.handle(Request(op: "restore", version: gone[0].id), peer: peer).ok)
        let back = try XCTUnwrap(store.info("acp/development/DB"))
        XCTAssertEqual(back.kind, .password)
        XCTAssertEqual(back.service, "Neon")
        XCTAssertEqual(back.usedIn, ["/r/.env"])
        XCTAssertEqual(try store.values(["acp/development/DB"]), ["acp/development/DB": "two"])
        XCTAssertEqual(try XCTUnwrap(b.handle(Request(op: "deleted"), peer: peer).versions).count, 0)
    }

    func testRestoreOverExistingKeepsCurrentAndShowingNeedsApproval() throws {
        let (b, store, _) = try make()
        _ = b.handle(Request(op: "set", names: ["acp/development/DB"], value: "two"), peer: peer)
        let first = try XCTUnwrap(b.handle(Request(op: "history", names: ["acp/development/DB"]), peer: peer).versions?.first)
        XCTAssertTrue(b.handle(Request(op: "restore", version: first.id), peer: peer).ok)
        XCTAssertEqual(try store.values(["acp/development/DB"]), ["acp/development/DB": "one"])
        let h = try XCTUnwrap(b.handle(Request(op: "history", names: ["acp/development/DB"]), peer: peer).versions)
        XCTAssertEqual(h.first?.reason, .restored)

        XCTAssertEqual(b.handle(Request(op: "version", version: first.id), peer: peer).values?[first.id], "one")
        let denying = Broker(store: store, approver: FixedApprover(false), logURL: nil, versions: b.versions)
        XCTAssertEqual(denying.handle(Request(op: "version", version: first.id), peer: peer).denied, ["acp/development/DB"])
        XCTAssertFalse(denying.handle(Request(op: "restore", version: first.id), peer: peer).ok)
    }

    func testMoveCarriesHistoryAndForgetClearsIt() throws {
        let (b, _, versions) = try make()
        _ = b.handle(Request(op: "set", names: ["acp/development/DB"], value: "two"), peer: peer)
        XCTAssertTrue(b.handle(Request(op: "move", names: ["acp/development/DB"], project: "acp", environment: "production"), peer: peer).ok)
        XCTAssertEqual(try versions.list(item: "acp/development/DB").count, 0)
        let moved = try versions.list(item: "acp/production/DB")
        XCTAssertEqual(moved.count, 1)
        XCTAssertTrue(moved[0].id.hasPrefix("acp/production/DB#"))
        XCTAssertTrue(b.handle(Request(op: "forget", names: ["acp/production/DB"]), peer: peer).ok)
        XCTAssertEqual(try versions.list(item: nil).count, 0)
    }

    func testPruneKeepsTenAndForgetsLongDeletedItems() throws {
        let versions = MemoryVersionStore()
        let info = SecretInfo(name: "A", agentSafe: false, note: "", updatedAt: Date())
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<12 { try versions.record(info, value: "v\(i)", reason: .changed, by: "t", at: start.addingTimeInterval(Double(i))) }
        try versions.record(SecretInfo(name: "GONE", agentSafe: false, note: "", updatedAt: start), value: "x", reason: .deleted, by: "t", at: start)
        try versions.prune(existing: ["A", "OTHER"], now: start.addingTimeInterval(20))
        let kept = try versions.list(item: "A")
        XCTAssertEqual(kept.count, 10)
        XCTAssertEqual(try versions.value(kept[0].id), "v11", "newest kept")
        XCTAssertEqual(try versions.list(item: "GONE").count, 1, "deleted 20 seconds ago: still restorable")
        try versions.prune(existing: ["A"], now: start.addingTimeInterval(Versions.deletedFor + 1))
        XCTAssertEqual(try versions.list(item: "GONE").count, 0, "past 30 days: forgotten")
        XCTAssertEqual(try versions.list(item: "A").count, 10)
    }
}

final class KeychainVersionTests: XCTestCase {
    /// Writes to the real login keychain, so it runs only when asked: LATCHKEY_KEYCHAIN_TESTS=1 swift test
    func testKeychainVersionRoundTrip() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LATCHKEY_KEYCHAIN_TESTS"] == "1")
        let versions = KeychainVersionStore(mode: .thisMac)
        let item = "latchkey-test-\(UUID().uuidString.prefix(8))"
        let v = try versions.record(SecretInfo(name: item, kind: .token, agentSafe: false, note: "t", updatedAt: Date()),
                                    value: "old-value", reason: .changed, by: "test")
        defer { try? versions.remove(v.id) }
        XCTAssertEqual(try versions.list(item: item).map(\.id), [v.id])
        XCTAssertEqual(try versions.value(v.id), "old-value")
        try versions.remove(v.id)
        XCTAssertEqual(try versions.list(item: item).count, 0)
    }
}
