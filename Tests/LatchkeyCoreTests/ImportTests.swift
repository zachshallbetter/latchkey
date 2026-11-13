import XCTest
@testable import LatchkeyCore

/// Counts approvals, so tests can check that a batch asks once.
final class CountingApprover: Approver, @unchecked Sendable {
    var reasons: [String] = []
    var actions: [ApprovalRequest.Action] = []
    let answer: Bool
    init(_ answer: Bool) { self.answer = answer }
    var method: String { "test" }
    func approve(_ request: ApprovalRequest) -> ApprovalDecision { reasons.append(request.reason); actions.append(request.action); return answer ? .once : .deny }
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
        XCTAssertTrue(approver.reasons[0].hasPrefix("add A and B from /tmp/project/.env"), approver.reasons[0])
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
        XCTAssertTrue(approver.reasons[0].hasPrefix("add NEW and overwrite OLD"), approver.reasons[0])
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
        XCTAssertEqual(Broker.count(["A"]), "A")
        XCTAssertEqual(Broker.count(["shop/development/DB", "shop/development/KEY"]), "DB and KEY from shop/development")
        XCTAssertEqual(Broker.count(["a/dev/A", "a/dev/B", "a/dev/C"]), "A, B and C from a/dev")
        XCTAssertEqual(Broker.count((1...17).map { "acp-gateway/development/K\($0)" }), "17 items from acp-gateway/development")
        XCTAssertEqual(Broker.count(["shop/development/A", "shop/development/B", "shop/preview/A", "shop/preview/C"]), "4 items from shop/development and shop/preview")
        XCTAssertEqual(Broker.count(["s/d/A", "s/p/A", "s/q/A", "B"]), "4 items from s/d and 3 other places")
        XCTAssertEqual(Broker.count(["A", "B", "C", "D"]), "4 items, shared")
        XCTAssertEqual(Broker.shortFolder("/Users/x/Projects/_worktrees/latchkey/grants"), "…/latchkey/grants")
    }

    func testRewriteKeepsEverythingElse() throws {
        let text = """
        # database
        export DB_PASS="s3cret value"
          API_KEY=abc123 # inline
        KEEP=unchanged
        REF=latchkey://REF

        """
        let out = try EnvFile.rewrite(text, toReferences: ["DB_PASS": "DB_PASS", "API_KEY": "site/development/API_KEY"])
        XCTAssertEqual(out, """
        # database
        export DB_PASS=latchkey://DB_PASS
          API_KEY=latchkey://site/development/API_KEY
        KEEP=unchanged
        REF=latchkey://REF

        """)
        XCTAssertEqual(try EnvFile.rewrite("A=1\r\nB=2\r\n", toReferences: ["A": "A"]), "A=latchkey://A\r\nB=2\r\n")
    }
}

final class EnvImportTests: XCTestCase {
    func testPlan() throws {
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
        let p = try EnvImport.plan(text, source: ".env", kinds: ["HOST": .value], agentSafe: ["HOST"])
        let byName = Dictionary(uniqueKeysWithValues: p.items.map { ($0.name, $0) })
        XCTAssertEqual(p.items.map(\.name), ["A", "DATABASE_URL", "DB_PASSWORD", "HOST", "PEM", "PUBLIC_URL"])
        XCTAssertEqual(byName["A"]?.value, "two")
        XCTAssertEqual(byName["DB_PASSWORD"]?.kind, .password)
        XCTAssertEqual(byName["DATABASE_URL"]?.kind, .password)
        XCTAssertEqual(byName["PUBLIC_URL"]?.kind, .value, "PUBLIC_* ships to browsers: a public value")
        XCTAssertEqual(byName["PEM"]?.kind, .key)
        XCTAssertEqual(byName["HOST"]?.kind, .value)
        XCTAssertEqual(byName["HOST"]?.agentSafe, true)
        XCTAssertEqual(byName["A"]?.agentSafe, false)
        XCTAssertEqual(byName["A"]?.note, "imported from .env")
        XCTAssertEqual(p.ignored, ["EMPTY": "empty", "REF": "already a reference"])
        XCTAssertEqual(try EnvImport.plan(text, source: "x", only: ["A"]).items.map(\.name), ["A"])
    }

    let mixed = """
    PORT=3000
    NODE_ENV=development
    LOG_LEVEL=debug
    FEATURE_X=true
    NEXT_PUBLIC_API_URL=https://api.example.test
    VITE_APP_NAME=shop
    STRIPE_PUBLISHABLE_KEY=pk_test_abcdefghijklmnop
    STRIPE_SECRET_KEY=sk_test_abcdefghijklmnop
    SITE_URL=https://example.test
    DATABASE_URL=postgres://u:p@h/db
    NEXT_PUBLIC_DB=postgres://u:p@h/db
    API_TOKEN=abc123
    UNKNOWN_THING=whatever
    REF=latchkey://X
    EMPTY=
    """

    func testClassifiesEachLine() throws {
        let p = try EnvImport.plan(mixed, source: ".env")
        XCTAssertEqual(p.classes, [
            "PORT": .setting, "NODE_ENV": .setting, "LOG_LEVEL": .setting, "FEATURE_X": .setting,
            "NEXT_PUBLIC_API_URL": .publicValue, "VITE_APP_NAME": .publicValue, "STRIPE_PUBLISHABLE_KEY": .publicValue,
            "STRIPE_SECRET_KEY": .secret, "SITE_URL": .publicValue, "DATABASE_URL": .secret,
            "NEXT_PUBLIC_DB": .secret, "API_TOKEN": .secret, "UNKNOWN_THING": .secret, "REF": .reference,
        ], "empty lines have no class; credentials beat a public-looking name; anything unclear is a secret")
        XCTAssertEqual(p.items.map(\.name), ["API_TOKEN", "DATABASE_URL", "NEXT_PUBLIC_API_URL", "NEXT_PUBLIC_DB", "SITE_URL",
                                             "STRIPE_PUBLISHABLE_KEY", "STRIPE_SECRET_KEY", "UNKNOWN_THING", "VITE_APP_NAME"])
        XCTAssertEqual(p.settings.map(\.name), ["FEATURE_X", "LOG_LEVEL", "NODE_ENV", "PORT"])
        XCTAssertEqual(p.ignored["PORT"], "setting: left in the file")
        XCTAssertEqual(p.ignored["REF"], "already a reference")
        XCTAssertNil(p.references["PORT"], "a setting has no item, so it is never rewritten")
        let byName = Dictionary(uniqueKeysWithValues: p.items.map { ($0.name, $0) })
        XCTAssertEqual(byName["NEXT_PUBLIC_API_URL"]?.kind, .value)
        XCTAssertEqual(byName["NEXT_PUBLIC_API_URL"]?.agentSafe, false, "public is not agent-safe unless you say so")
        XCTAssertEqual(byName["DATABASE_URL"]?.kind, .password)
        XCTAssertEqual(byName["API_TOKEN"]?.kind, .token)
    }

    func testChangingAClass() throws {
        let p = try EnvImport.plan(mixed, source: ".env", classes: ["PORT": .publicValue, "API_TOKEN": .setting, "UNKNOWN_THING": .publicValue, "REF": .secret])
        XCTAssertEqual(p.classes["PORT"], .publicValue)
        XCTAssertEqual(p.items.first { $0.name == "PORT" }?.kind, .value)
        XCTAssertEqual(p.classes["API_TOKEN"], .setting)
        XCTAssertNil(p.items.first { $0.name == "API_TOKEN" })
        XCTAssertEqual(p.settings.map(\.name), ["API_TOKEN", "FEATURE_X", "LOG_LEVEL", "NODE_ENV"])
        XCTAssertEqual(p.items.first { $0.name == "UNKNOWN_THING" }?.kind, .value)
        XCTAssertEqual(p.classes["REF"], .reference, "a reference can't be reclassed")

        let named = try EnvImport.plan(mixed, source: ".env", kinds: ["PORT": .token, "API_TOKEN": .value], agentSafe: ["NODE_ENV"])
        XCTAssertEqual(named.classes["PORT"], .secret, "--kind says what you want")
        XCTAssertEqual(named.classes["API_TOKEN"], .publicValue)
        XCTAssertEqual(named.classes["NODE_ENV"], .publicValue, "a setting you mark agent-safe is saved")
        XCTAssertEqual(named.items.first { $0.name == "NODE_ENV" }?.agentSafe, true)
    }

    func testPatternsAndNamesAreClassifiedByName() {
        XCTAssertEqual(EnvImport.classify(key: "AWS_ACCESS_KEY_ID", value: "AKIAABCDEFGHIJKLMNOP"), .secret)
        XCTAssertEqual(EnvImport.classify(key: "SENTRY_DSN", value: "https://k@o1.ingest.sentry.test/1"), .secret)
        XCTAssertEqual(EnvImport.classify(key: "WEBHOOK_URL", value: "https://hooks.example.test/T0123456789ABCDEFG"), .secret)
        XCTAssertEqual(EnvImport.classify(key: "CLIENT_ID", value: "abc"), .publicValue)
        XCTAssertEqual(EnvImport.classify(key: "ANALYTICS_KEY", value: "x1", agentSafePatterns: ["ANALYTICS_*"]), .publicValue)
        XCTAssertEqual(EnvImport.classify(key: "PORT", value: "latchkey://PORT"), .reference)
        XCTAssertEqual(EnvImport.classify(key: "RETRIES", value: "3"), .secret, "a bare number isn't enough to call it a setting")
    }

    func testBatchKeepsClasses() throws {
        let plan = try EnvImport.batch([(URL(fileURLWithPath: "/r/acp/.env"), "PORT=3000\nTOKEN_X=abc\nVITE_A=1")],
                                       classes: ["TOKEN_X": .setting])
        XCTAssertEqual(plan.files[0].classes, ["PORT": .setting, "TOKEN_X": .setting, "VITE_A": .publicValue])
        XCTAssertEqual(plan.items.map(\.name), ["acp/development/VITE_A"])
        XCTAssertEqual(plan.files[0].references, ["VITE_A": "acp/development/VITE_A"])
        XCTAssertEqual(plan.files[0].ignored["PORT"], "setting: left in the file")
    }
}
