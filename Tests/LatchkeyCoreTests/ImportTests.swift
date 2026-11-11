import XCTest
@testable import LatchkeyCore

/// Counts approvals, so tests can check that a batch asks once.
final class CountingApprover: Approver, @unchecked Sendable {
    var reasons: [String] = []
    let answer: Bool
    init(_ answer: Bool) { self.answer = answer }
    var method: String { "test" }
    func approve(_ request: ApprovalRequest) -> ApprovalDecision { reasons.append(request.reason); return answer ? .once : .deny }
}

final class ImportTests: XCTestCase {
    let peer = PeerInfo(pid: 1, path: "/usr/local/bin/latchkey", cwd: "/tmp/project", chain: ["zsh"])

    func items(_ names: String...) -> [ImportItem] {
        names.map { ImportItem(name: $0, value: "value-of-\($0)", kind: .token, agentSafe: false, note: "n") }
    }

    func testOneApprovalForTheBatchAndExistingSkipped() throws {
        let store = MemoryStore()
        try store.save(name: "OLD", value: "old-value", kind: .password, agentSafe: true, note: "")
        let approver = CountingApprover(true)
        let b = Broker(store: store, approver: approver, logURL: nil)
        let r = b.handle(Request(op: "import", items: items("A", "B", "OLD"), source: "/tmp/project/.env"), peer: peer)
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertEqual(r.added, ["A", "B"])
        XCTAssertEqual(r.skipped, ["OLD"])
        XCTAssertEqual(r.replaced, [])
        XCTAssertEqual(approver.reasons.count, 1)
        XCTAssertTrue(approver.reasons[0].hasPrefix("add 2 items (A, B) from /tmp/project/.env"), approver.reasons[0])
        XCTAssertEqual(try store.values(["A", "OLD"]), ["A": "value-of-A", "OLD": "old-value"])
    }

    func testReplace() throws {
        let store = MemoryStore()
        try store.save(name: "OLD", value: "old-value", kind: .password, agentSafe: true, note: "")
        let approver = CountingApprover(true)
        let r = Broker(store: store, approver: approver, logURL: nil)
            .handle(Request(op: "import", items: items("OLD", "NEW"), replace: true), peer: peer)
        XCTAssertEqual(r.added, ["NEW"])
        XCTAssertEqual(r.replaced, ["OLD"])
        XCTAssertTrue(approver.reasons[0].hasPrefix("add 1 item (NEW) and overwrite 1 item (OLD)"), approver.reasons[0])
        XCTAssertEqual(try store.values(["OLD"]), ["OLD": "value-of-OLD"])
    }

    func testDeniedWritesNothingAndNothingNewAsksNothing() throws {
        let store = MemoryStore()
        let deny = CountingApprover(false)
        let r = Broker(store: store, approver: deny, logURL: nil).handle(Request(op: "import", items: items("A")), peer: peer)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(try store.list().count, 0)

        try store.save(name: "A", value: "x-value", kind: nil, agentSafe: nil, note: nil)
        let quiet = CountingApprover(false)
        let r2 = Broker(store: store, approver: quiet, logURL: nil).handle(Request(op: "import", items: items("A")), peer: peer)
        XCTAssertTrue(r2.ok)
        XCTAssertEqual(r2.skipped, ["A"])
        XCTAssertEqual(quiet.reasons.count, 0)
    }

    func testRejectsBadInput() {
        let b = Broker(store: MemoryStore(), approver: FixedApprover(true), logURL: nil)
        XCTAssertFalse(b.handle(Request(op: "import", items: []), peer: peer).ok)
        XCTAssertFalse(b.handle(Request(op: "import", items: [ImportItem(name: "bad name", value: "v")]), peer: peer).ok)
        XCTAssertFalse(b.handle(Request(op: "import", items: [ImportItem(name: "E", value: "")]), peer: peer).ok)
    }

    func testCountShortensLongLists() {
        XCTAssertEqual(Broker.count(["A"]), "1 item (A)")
        XCTAssertEqual(Broker.count(["A", "B", "C", "D", "E", "F", "G"]), "7 items (A, B, C, D, E, …)")
    }

    func testRewriteKeepsEverythingElse() {
        let text = """
        # database
        export DB_PASS="s3cret value"
          API_KEY=abc123 # inline
        KEEP=unchanged
        REF=latchkey://REF

        """
        let out = EnvFile.rewrite(text, toReferences: ["DB_PASS", "API_KEY"])
        XCTAssertEqual(out, """
        # database
        export DB_PASS=latchkey://DB_PASS
          API_KEY=latchkey://API_KEY
        KEEP=unchanged
        REF=latchkey://REF

        """)
        XCTAssertEqual(EnvFile.rewrite("A=1\r\nB=2\r\n", toReferences: ["A"]), "A=latchkey://A\r\nB=2\r\n")
    }
}

final class EnvImportTests: XCTestCase {
    func testPlan() {
        let text = """
        A=one
        A=two
        DB_PASSWORD=hunter22
        DATABASE_URL=postgres://u:p@h/db
        PUBLIC_URL=https://example.test
        PEM="-----BEGIN KEY-----\\nabc\\n-----END KEY-----"
        HOST=example.test
        EMPTY=
        REF=latchkey://X
        """
        let p = EnvImport.plan(text, source: ".env", kinds: ["HOST": .value], agentSafe: ["HOST"])
        let byName = Dictionary(uniqueKeysWithValues: p.items.map { ($0.name, $0) })
        XCTAssertEqual(p.items.map(\.name), ["A", "DATABASE_URL", "DB_PASSWORD", "HOST", "PEM", "PUBLIC_URL"])
        XCTAssertEqual(byName["A"]?.value, "two")
        XCTAssertEqual(byName["DB_PASSWORD"]?.kind, .password)
        XCTAssertEqual(byName["DATABASE_URL"]?.kind, .password)
        XCTAssertEqual(byName["PUBLIC_URL"]?.kind, .token)
        XCTAssertEqual(byName["PEM"]?.kind, .key)
        XCTAssertEqual(byName["HOST"]?.kind, .value)
        XCTAssertEqual(byName["HOST"]?.agentSafe, true)
        XCTAssertEqual(byName["A"]?.agentSafe, false)
        XCTAssertEqual(byName["A"]?.note, "imported from .env")
        XCTAssertEqual(p.ignored, ["EMPTY": "empty", "REF": "already a reference"])
        XCTAssertEqual(EnvImport.plan(text, source: "x", only: ["A"]).items.map(\.name), ["A"])
    }
}
