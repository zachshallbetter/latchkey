import XCTest
@testable import LatchkeyCore

final class ScanTests: XCTestCase {
    let peer = PeerInfo(pid: 1, path: "/usr/local/bin/latchkey", cwd: "/tmp", chain: ["zsh"])

    func makeBroker(_ approver: Approver = CountingApprover(true)) throws -> Broker {
        let store = MemoryStore()
        try store.save(name: "a/development/OPENAI_API_KEY", value: "sk-shared-123456", kind: .token, agentSafe: false, note: "")
        try store.save(name: "OPENAI_API_KEY", value: "sk-shared-123456", kind: .token, agentSafe: true, note: "")
        try store.save(name: "a/development/PORT", value: "3000-3000", kind: .value, agentSafe: true, note: "")
        return Broker(store: store, approver: approver, logURL: nil)
    }

    func candidates(_ values: String...) -> [ImportItem] {
        values.enumerated().map { ImportItem(name: String($0.offset), value: $0.element) }
    }

    func testMatchesReturnOnlyItemIDsAndAskOnce() throws {
        let approver = CountingApprover(true)
        let b = try makeBroker(approver)
        let r = b.handle(Request(op: "scan", items: candidates("sk-shared-123456", "something-else", "3000-3000", "latchkey://X_KEY_LONG")), peer: peer)
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertEqual(r.matches, ["0": ["OPENAI_API_KEY", "a/development/OPENAI_API_KEY"]], "plain items aren't compared; references are left out")
        XCTAssertNil(r.values)
        XCTAssertEqual(approver.actions, [.compare])
        XCTAssertTrue(approver.reasons[0].contains("no stored value leaves Latchkey"), approver.reasons[0])
    }

    func testNothingToCompareAsksNothing() throws {
        let approver = CountingApprover(true)
        let b = try makeBroker(approver)
        XCTAssertEqual(b.handle(Request(op: "scan", items: candidates("short")), peer: peer).matches, [:])
        XCTAssertEqual(b.handle(Request(op: "scan"), peer: peer).matches, [:])
        XCTAssertEqual(approver.actions, [])
    }

    func testRefusesAgentsSafariAndDenial() throws {
        let b = try makeBroker()
        var agent = Request(op: "scan", items: candidates("sk-shared-123456"))
        agent.origin = "mcp"
        XCTAssertFalse(b.handle(agent, peer: peer).ok)
        let safari = PeerInfo(pid: 1, path: "/Applications/Latchkey.app/Contents/PlugIns/Safari.appex", cwd: "/tmp", chain: ["Safari"])
        XCTAssertFalse(b.handle(Request(op: "scan", items: candidates("sk-shared-123456")), peer: safari, gate: .safariExtension).ok)
        let denied = try makeBroker(CountingApprover(false)).handle(Request(op: "scan", items: candidates("sk-shared-123456")), peer: peer)
        XCTAssertFalse(denied.ok)
        XCTAssertNil(denied.matches)
        XCTAssertTrue(Broker.Gate.commandLineTool.ops.contains("scan"))
    }

    func testCandidatesCarryLinesAndSkipEmptyAndReferences() {
        let text = "# c\nA=1\nB=\nC=latchkey://C\nexport D=\"multi\nline\"\nE=x\n"
        let found = Scan.candidates(in: text, path: ".env")
        XCTAssertEqual(found.map(\.key), ["A", "D", "E"])
        XCTAssertEqual(found.map(\.line), [2, 5, 7])
        XCTAssertEqual(Scan.candidates(in: text, path: ".env", only: [7]).map(\.key), ["E"])
        XCTAssertEqual(Scan.candidates(in: "not an assignment", path: ".env"), [])
    }

    func testWhichFilesAreScanned() {
        for name in [".env", ".env.local", ".env.production", "prod.env", "Local.ENV"] { XCTAssertTrue(Scan.isScannable(name), name) }
        for name in [".env.example", ".env.bak", "environment.txt", "env.sample", ".env.local.old"] { XCTAssertFalse(Scan.isScannable(name), name) }
    }

    func testLooksSecret() {
        XCTAssertTrue(Scan.looksSecret(key: "ANYTHING", value: "sk_live_abcdef123456"))
        XCTAssertTrue(Scan.looksSecret(key: "DATABASE_URL", value: "postgres://u:p@db.example.com/x"))
        XCTAssertTrue(Scan.looksSecret(key: "SIGNING_KEY", value: "-----BEGIN PRIVATE KEY-----\nabc"))
        XCTAssertTrue(Scan.looksSecret(key: "SESSION_SECRET", value: "k3j2h4g5f6d7s8a9"))
        XCTAssertFalse(Scan.looksSecret(key: "PORT", value: "3000"))
        XCTAssertFalse(Scan.looksSecret(key: "SESSION_SECRET", value: "short"))
        XCTAssertFalse(Scan.looksSecret(key: "NODE_ENV", value: "development"))
        XCTAssertFalse(Scan.looksSecret(key: "TOKEN_TTL", value: "86400000"))
        XCTAssertFalse(Scan.looksSecret(key: "NEON_PROJECT_ID", value: "4c1d8a9e-0000-4000-8000-000000000000"))
        XCTAssertFalse(Scan.looksSecret(key: "SITE_URL", value: "https://example.com"))
    }

    func testAddedLinesFromADiff() {
        let diff = """
        diff --git a/.env b/.env
        --- a/.env
        +++ b/.env
        @@ -1,0 +2,2 @@
        +A=1
        +B=2
        @@ -9 +11 @@
        -C=1
        +C=2
        diff --git a/gone b/gone
        --- a/gone
        +++ /dev/null
        @@ -1 +0,0 @@
        -x
        """
        XCTAssertEqual(Scan.addedLines(inDiff: diff), [".env": [2, 3, 11]])
    }

    func testHookRefusesAndIsMarked() {
        XCTAssertTrue(Scan.hook.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(Scan.hook.contains(Scan.hookMarker))
        XCTAssertTrue(Scan.hook.contains("scan --staged"))
    }
}
