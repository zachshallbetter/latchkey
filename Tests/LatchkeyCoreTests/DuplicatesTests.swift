import XCTest
@testable import LatchkeyCore

final class DuplicatesTests: XCTestCase {
    let peer = PeerInfo(pid: 1, path: "/usr/local/bin/latchkey", cwd: "/tmp", chain: ["zsh"])

    func info(_ name: String, _ kind: ItemKind = .token) -> SecretInfo {
        SecretInfo(name: name, kind: kind, agentSafe: false, note: "", updatedAt: Date())
    }

    func testGroupsSkipPlainAndShortValues() {
        let items = [info("a/dev/OPENAI"), info("b/dev/OPENAI"), info("c/dev/KEY"), info("a/dev/PORT", .value), info("b/dev/PORT", .value),
                     info("a/dev/PIN"), info("b/dev/PIN"), info("a/dev/OTHER")]
        let values = ["a/dev/OPENAI": "sk-shared-123456", "b/dev/OPENAI": "sk-shared-123456", "c/dev/KEY": "sk-shared-123456",
                      "a/dev/PORT": "3000-3000", "b/dev/PORT": "3000-3000", "a/dev/PIN": "1234", "b/dev/PIN": "1234",
                      "a/dev/OTHER": "different-value"]
        XCTAssertEqual(Duplicates.groups(values: values, items: items), [["a/dev/OPENAI", "b/dev/OPENAI", "c/dev/KEY"]])
    }

    func testAdvicePutsProductionFirstThenSharedThenNames() {
        XCTAssertEqual(Duplicates.advice(for: ["shop/development/KEY", "shop/production/KEY"]), .separateProduction)
        XCTAssertEqual(Duplicates.advice(for: ["OPENAI_API_KEY", "shop/development/OPENAI_API_KEY"]), .useShared("OPENAI_API_KEY"))
        XCTAssertEqual(Duplicates.advice(for: ["a/dev/OPENAI_API_KEY", "b/dev/OPENAI_API_KEY"]), .share("OPENAI_API_KEY"))
        XCTAssertEqual(Duplicates.advice(for: ["a/dev/OPENAI", "b/dev/OPENAI", "c/dev/LLM_KEY"]), .shareRenamed(suggested: "OPENAI"))
        XCTAssertEqual(Duplicates.advice(for: ["a/production/K", "b/production/K"]), .share("K"), "all production: sharing is still an option")
    }

    func makeBroker(_ approver: Approver = CountingApprover(true)) throws -> (Broker, MemoryStore, MemoryEnvironmentStore) {
        let store = MemoryStore(), records = MemoryEnvironmentStore()
        try store.save(name: "a/development/OPENAI_API_KEY", value: "sk-shared-123456", kind: .token, agentSafe: false, note: "", usedIn: ["/tmp/a/.env"], service: "OpenAI")
        try store.save(name: "b/development/OPENAI_API_KEY", value: "sk-shared-123456", kind: .token, agentSafe: true, note: "", usedIn: ["/tmp/b/.env"], service: "OpenAI")
        try store.save(name: "b/development/OTHER", value: "something-else-9", kind: .token, agentSafe: false, note: "")
        return (Broker(store: store, approver: approver, logURL: nil, records: records), store, records)
    }

    func testFindingDuplicatesAsksEveryTimeAndReturnsNoValues() throws {
        let approver = CountingApprover(true)
        let (b, _, _) = try makeBroker(approver)
        let r = b.handle(Request(op: "duplicates"), peer: peer)
        XCTAssertEqual(r.groups, [["a/development/OPENAI_API_KEY", "b/development/OPENAI_API_KEY"]])
        XCTAssertNil(r.values)
        XCTAssertEqual(approver.reasons.count, 1)
        XCTAssertTrue(approver.reasons[0].contains("no value leaves Latchkey"), approver.reasons[0])
        var agent = Request(op: "duplicates")
        agent.origin = "mcp"
        XCTAssertFalse(b.handle(agent, peer: peer).ok)
        let (deny, _, _) = try makeBroker(CountingApprover(false))
        XCTAssertNil(deny.handle(Request(op: "duplicates"), peer: peer).groups)
    }

    func testCombiningMakesOneSharedItemAndRecordsFollow() throws {
        let (b, store, records) = try makeBroker()
        try records.save(EnvironmentRecord(scope: "a/development", variables: ["OPENAI_API_KEY": .credential("a/development/OPENAI_API_KEY")]))
        let ids = ["a/development/OPENAI_API_KEY", "b/development/OPENAI_API_KEY"]
        let r = b.handle(Request(op: "combine", names: ids, into: "OPENAI_API_KEY"), peer: peer)
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertEqual(r.moved, ["a/development/OPENAI_API_KEY": "OPENAI_API_KEY", "b/development/OPENAI_API_KEY": "OPENAI_API_KEY"])
        XCTAssertEqual(try store.values(["OPENAI_API_KEY"]), ["OPENAI_API_KEY": "sk-shared-123456"])
        let shared = try XCTUnwrap(store.info("OPENAI_API_KEY"))
        XCTAssertFalse(shared.agentSafe, "agents may read it only if they could read every one")
        XCTAssertEqual(shared.service, "OpenAI")
        XCTAssertEqual(Set(shared.usedIn ?? []), ["/tmp/a/.env", "/tmp/b/.env"])
        XCTAssertNil(try store.info("a/development/OPENAI_API_KEY"))
        XCTAssertEqual(try records.environments().first?.variables["OPENAI_API_KEY"], .credential("OPENAI_API_KEY"))
        XCTAssertEqual(Set(try b.versions.deleted(existing: Set(store.list().map(\.name))).map(\.item)), Set(ids), "the originals can be restored")
    }

    func testCombiningRefusesDifferentValuesAndAgents() throws {
        let (b, store, _) = try makeBroker()
        XCTAssertFalse(b.handle(Request(op: "combine", names: ["a/development/OPENAI_API_KEY", "b/development/OTHER"], into: "X_KEY"), peer: peer).ok)
        try store.save(name: "TAKEN", value: "another-value-1", kind: .token, agentSafe: false, note: "")
        XCTAssertFalse(b.handle(Request(op: "combine", names: ["a/development/OPENAI_API_KEY", "b/development/OPENAI_API_KEY"], into: "TAKEN"), peer: peer).ok)
        XCTAssertFalse(b.handle(Request(op: "combine", names: ["a/development/OPENAI_API_KEY", "b/development/OPENAI_API_KEY"], into: "a/development/X"), peer: peer).ok,
                       "only into a shared item")
        var agent = Request(op: "combine", names: ["a/development/OPENAI_API_KEY", "b/development/OPENAI_API_KEY"], into: "K_KEY")
        agent.origin = "mcp"
        XCTAssertFalse(b.handle(agent, peer: peer).ok)
        XCTAssertNotNil(try store.info("a/development/OPENAI_API_KEY"), "nothing changed")
    }
}
