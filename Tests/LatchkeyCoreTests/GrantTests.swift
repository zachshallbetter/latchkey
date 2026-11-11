import XCTest
@testable import LatchkeyCore

final class GrantTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCoversFolderAndBelowUntilExpiry() {
        let g = Grant(names: ["A", "B"], folder: "/Users/x/site/", expires: now.addingTimeInterval(3600), created: now, createdBy: "t")
        XCTAssertEqual(g.folder, "/Users/x/site")
        XCTAssertTrue(g.covers("A", cwd: "/Users/x/site", now: now))
        XCTAssertTrue(g.covers("B", cwd: "/Users/x/site/packages/api", now: now))
        XCTAssertFalse(g.covers("A", cwd: "/Users/x/site-other", now: now))
        XCTAssertFalse(g.covers("A", cwd: "/Users/x", now: now))
        XCTAssertFalse(g.covers("C", cwd: "/Users/x/site", now: now))
        XCTAssertFalse(g.covers("A", cwd: "", now: now))
        XCTAssertFalse(g.covers("A", cwd: "/Users/x/site", now: now.addingTimeInterval(3601)))
    }

    func testStorePersistsCapsAndRevokes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grants-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GrantStore(url: url)
        let g = store.add(names: ["A"], folder: "/tmp/p", duration: 30 * 86400, createdBy: "t", now: now)
        XCTAssertEqual(g.expires, now.addingTimeInterval(GrantStore.longest))
        store.add(names: ["B"], folder: "/tmp/q", duration: 60, createdBy: "t", now: now)
        let reloaded = GrantStore(url: url)
        XCTAssertEqual(reloaded.all(now: now).count, 2)
        XCTAssertEqual(reloaded.all(now: now.addingTimeInterval(120)).map(\.id), [g.id], "expired grants drop out")
        XCTAssertNotNil(reloaded.covering("A", cwd: "/tmp/p/sub", now: now))
        XCTAssertEqual(reloaded.revoke(g.id), 1)
        XCTAssertEqual(reloaded.revoke("nope"), 0)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testDurations() {
        XCTAssertEqual(GrantStore.parseDuration("30m"), 1800)
        XCTAssertEqual(GrantStore.parseDuration("2h"), 7200)
        XCTAssertEqual(GrantStore.parseDuration("1d"), 86400)
        XCTAssertNil(GrantStore.parseDuration("2x"))
        XCTAssertNil(GrantStore.parseDuration("-1h"))
        XCTAssertNil(GrantStore.parseDuration("h"))
    }
}

final class BrokerGrantTests: XCTestCase {
    let peer = PeerInfo(pid: 1, path: "/usr/local/bin/latchkey", cwd: "/tmp/site", chain: ["zsh", "claude"])

    func broker(_ decision: ApprovalDecision) throws -> Broker {
        let store = MemoryStore()
        try store.save(name: "DB", value: "db-value-123", kind: .password, agentSafe: false, note: "")
        try store.save(name: "API", value: "api-value-456", kind: .token, agentSafe: false, note: "")
        return Broker(store: store, approver: FixedApprover(decision), readApprovalWindow: 0, logURL: nil)
    }

    func testApprovalCanCreateAGrantThatLaterReadsUse() throws {
        let b = try broker(.grant(3600))
        let r = b.handle(Request(op: "get", names: ["DB"], cwd: "/tmp/site"), peer: peer)
        XCTAssertEqual(r.values, ["DB": "db-value-123"])
        XCTAssertEqual(b.grants.all().count, 1)
        XCTAssertEqual(b.grants.all().first?.folder, "/tmp/site")
        XCTAssertEqual(b.grants.all().first?.createdBy, "zsh › claude")

        // Same folder or below: allowed by the grant even though the approver now says no.
        let denyAll = Broker(store: b.store, approver: FixedApprover(false), readApprovalWindow: 0, logURL: nil, grants: b.grants)
        XCTAssertEqual(denyAll.handle(Request(op: "get", names: ["DB"], cwd: "/tmp/site/sub"), peer: peer).values, ["DB": "db-value-123"])
        // Elsewhere, or another item: asks, and is denied.
        XCTAssertEqual(denyAll.handle(Request(op: "get", names: ["DB"], cwd: "/tmp/other"), peer: peer).denied, ["DB"])
        XCTAssertEqual(denyAll.handle(Request(op: "get", names: ["DB", "API"], cwd: "/tmp/site"), peer: peer).denied, ["API"])
    }

    func testGrantAheadOfTimeAndRevoke() throws {
        let b = try broker(.once)
        let r = b.handle(Request(op: "grant", names: ["DB", "API"], cwd: "/tmp/x", folder: "/tmp/site", duration: 7200), peer: peer)
        XCTAssertTrue(r.ok, r.error ?? "")
        let g = try XCTUnwrap(r.grants?.first)
        XCTAssertEqual(g.names, ["API", "DB"])
        XCTAssertEqual(g.folder, "/tmp/site")
        XCTAssertEqual(b.handle(Request(op: "grants"), peer: peer).grants?.count, 1)
        XCTAssertEqual(b.handle(Request(op: "grant", names: ["NOPE"], folder: "/tmp/site"), peer: peer).missing, ["NOPE"])
        XCTAssertFalse(b.handle(Request(op: "grant", names: ["DB"], folder: "/"), peer: peer).ok)
        XCTAssertEqual(b.handle(Request(op: "revoke", names: [g.id]), peer: peer).info?["revoked"], "1")
        XCTAssertEqual(b.handle(Request(op: "revoke", names: [g.id]), peer: peer).missing, [g.id])
    }

    func testCheckReportsWithoutAskingOrReleasing() throws {
        let store = MemoryStore()
        try store.save(name: "DB", value: "db-value-123", kind: .password, agentSafe: false, note: "")
        try store.save(name: "API", value: "api-value-456", kind: .token, agentSafe: false, note: "")
        try store.save(name: "HOST", value: "db.example", kind: .value, agentSafe: true, note: "")
        let grants = GrantStore(url: nil)
        let g = grants.add(names: ["DB"], folder: "/tmp/site", duration: 3600, createdBy: "t")
        let asked = CountingApprover(true)
        let b = Broker(store: store, approver: asked, readApprovalWindow: 60, logURL: nil, grants: grants)

        let r = b.handle(Request(op: "check", names: ["DB", "API", "HOST", "NOPE"], cwd: "/tmp/site/sub"), peer: peer)
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertEqual(r.agentSafe, ["HOST"])
        XCTAssertEqual(r.granted, ["DB"])
        XCTAssertEqual(r.needsApproval, ["API"])
        XCTAssertNil(r.remembered)
        XCTAssertEqual(r.missing, ["NOPE"])
        XCTAssertEqual(r.grants?.map(\.id), [g.id])
        XCTAssertNil(r.values)
        XCTAssertEqual(asked.reasons.count, 0, "check never asks")

        // After an approval, the same request from the same caller is covered for the approval window.
        XCTAssertEqual(b.handle(Request(op: "get", names: ["API"], cwd: "/tmp/site"), peer: peer).values, ["API": "api-value-456"])
        XCTAssertEqual(asked.reasons.count, 1)
        let again = b.handle(Request(op: "check", names: ["API"], cwd: "/tmp/site"), peer: peer)
        XCTAssertEqual(again.remembered, ["API"])
        XCTAssertNil(again.needsApproval)
        // Outside the grant's folder, DB needs approval again.
        XCTAssertEqual(b.handle(Request(op: "check", names: ["DB"], cwd: "/tmp/other"), peer: peer).needsApproval, ["DB"])
    }

    func testGrantsAnAgentAsksForAreLimited() throws {
        let store = MemoryStore()
        for id in ["shop/production/DB", "shop/development/DB", "shop/vercel.production/DB", "SHARED"] {
            try store.save(name: id, value: "value-\(id)", kind: .password, agentSafe: false, note: "")
        }
        let b = Broker(store: store, approver: FixedApprover(.once), readApprovalWindow: 0, logURL: nil)
        func ask(_ names: [String], folder: String = "/tmp/site", duration: Double = 3600) -> Response {
            b.handle(Request(op: "grant", names: names, cwd: "/tmp/site", folder: folder, duration: duration, origin: "mcp"), peer: peer)
        }
        XCTAssertFalse(ask(["shop/production/DB"]).ok)
        XCTAssertFalse(ask(["shop/vercel.production/DB"]).ok)
        XCTAssertFalse(ask(["shop/*"]).ok, "a whole project includes production")
        XCTAssertFalse(ask(["shop/production/*"]).ok)
        XCTAssertFalse(ask(["shop/development/DB"], folder: "/tmp/elsewhere").ok, "only the agent's own folder")
        let r = ask(["shop/development/*", "SHARED"], duration: 3 * 86400)
        XCTAssertTrue(r.ok, r.error ?? "")
        let g = try XCTUnwrap(r.grants?.first)
        XCTAssertLessThanOrEqual(g.expires.timeIntervalSince(g.created), Broker.longestAgentGrant + 1)
        // The owner's own grants keep the usual limits.
        XCTAssertTrue(b.handle(Request(op: "grant", names: ["shop/production/DB"], folder: "/tmp/site", duration: 3 * 86400), peer: peer).ok)
    }

    func testProductionEnvironments() {
        XCTAssertTrue(Environments.isProduction("production"))
        XCTAssertTrue(Environments.isProduction("railway.production"))
        XCTAssertTrue(Environments.isProduction("Prod"))
        XCTAssertFalse(Environments.isProduction("preview"))
        XCTAssertFalse(Environments.isProduction("productionish"))
    }

    func testDeniedGrantIsNotCreated() throws {
        let b = try broker(.deny)
        XCTAssertFalse(b.handle(Request(op: "grant", names: ["DB"], folder: "/tmp/site"), peer: peer).ok)
        XCTAssertTrue(b.grants.all().isEmpty)
    }

    func testApprovalRequestCarriesContext() {
        let r = ApprovalRequest(action: .read, names: ["A"], chain: ["zsh"], folder: "/tmp", reason: "x")
        XCTAssertTrue(r.canGrant)
        XCTAssertFalse(r.fromApp)
        XCTAssertFalse(ApprovalRequest(action: .add, names: ["A"], chain: ["zsh"], folder: "/tmp", reason: "x").canGrant)
        XCTAssertTrue(ApprovalRequest(action: .read, names: ["A"], chain: [Broker.appCaller], folder: "", reason: "x").fromApp)
    }
}

final class MigrationTests: XCTestCase {
    func testMovesKeepsMetadataAndNeverOverwrites() throws {
        let old = MemoryStore(), new = MemoryStore()
        try old.save(name: "A", value: "value-a", kind: .password, agentSafe: true, note: "from old")
        try old.save(name: "B", value: "value-b-old", kind: .token, agentSafe: false, note: "")
        try new.save(name: "B", value: "value-b-new", kind: .token, agentSafe: false, note: "")
        let r = try StoreMigration.move(from: old, to: new)
        XCTAssertEqual(r.moved, ["A"])
        XCTAssertEqual(r.skipped, ["B"])
        XCTAssertTrue(r.failed.isEmpty)
        let a = try XCTUnwrap(new.info("A"))
        XCTAssertEqual(a.kind, .password)
        XCTAssertTrue(a.agentSafe)
        XCTAssertEqual(a.note, "from old")
        XCTAssertEqual(try new.values(["A", "B"]), ["A": "value-a", "B": "value-b-new"])
        XCTAssertEqual(try old.list().map(\.name), ["B"], "moved items leave the old store; skipped ones stay")
    }
}

