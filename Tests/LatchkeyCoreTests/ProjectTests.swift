import XCTest
@testable import LatchkeyCore

final class ItemIDTests: XCTestCase {
    func testParsesSharedAndProjectIDs() throws {
        XCTAssertEqual(ItemID("API_KEY")?.isShared, true)
        let id = try XCTUnwrap(ItemID("acp/production/DATABASE_URL"))
        XCTAssertEqual(id.project, "acp")
        XCTAssertEqual(id.environment, "production")
        XCTAssertEqual(id.name, "DATABASE_URL")
        XCTAssertEqual(id.string, "acp/production/DATABASE_URL")
        for bad in ["", "a/b", "a/b/c/d", "a//c", "/b/c", "a/b/", "has space", "acp/prod/BAD NAME"] {
            XCTAssertNil(ItemID(bad), bad)
        }
        XCTAssertTrue(Wire.isValidName("acp/development/PGHOST"))
    }

    func testOrdersProjectsThenEnvironmentsThenNames() {
        let ids = ["Z_SHARED", "web/production/B", "acp/test/A", "acp/development/B", "acp/production/A", "acp/development/A", "acp/custom/A"]
        XCTAssertEqual(ids.compactMap(ItemID.init).sorted().map(\.string),
                       ["acp/development/A", "acp/development/B", "acp/production/A", "acp/test/A", "acp/custom/A",
                        "web/production/B", "Z_SHARED"])
    }

    func testReferencesWithProjectsResolveAndRename() {
        let env = ["DB": "latchkey://acp/production/DATABASE_URL", "K": "x latchkey://KEY y", "U": "postgres://u:latchkey://db.pass@h/db"]
        XCTAssertEqual(Set(References.names(in: env)), ["acp/production/DATABASE_URL", "KEY", "db.pass"])
        XCTAssertEqual(References.resolve(env: env, with: ["acp/production/DATABASE_URL": "D", "KEY": "k", "db.pass": "p"]),
                       ["DB": "D", "K": "x k y", "U": "postgres://u:p@h/db"])
        XCTAssertEqual(References.renaming("A=latchkey://KEY\nB=latchkey://KEY2\nC=latchkey://OTHER", ["KEY": "acp/development/KEY", "KEY2": "acp/development/KEY2"]),
                       "A=latchkey://acp/development/KEY\nB=latchkey://acp/development/KEY2\nC=latchkey://OTHER")
    }
}

final class ImportPlacementTests: XCTestCase {
    func testEnvironmentFromFileName() {
        let cases = [".env": "development", ".env.local": "development", ".env.development.local": "development",
                     ".env.production": "production", ".env.prod": "production", ".env.production.local": "production",
                     ".env.staging": "staging", ".env.preview": "preview", ".env.test": "test", ".env.qa": "qa"]
        for (file, env) in cases { XCTAssertEqual(EnvImport.environment(forFile: file), env, file) }
    }

    func testProjectFromRepositoryFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Latchkey Repo \(UUID().uuidString.prefix(4))")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("apps/web"), withIntermediateDirectories: true)
        let project = EnvImport.project(forFile: root.appendingPathComponent("apps/web/.env.local"))
        XCTAssertTrue(project.hasPrefix("latchkey-repo-"), project)
        XCTAssertTrue(ItemID.isValidPart(project))
    }

    func testPlanPlacesItemsAndMapsKeys() throws {
        let p = try EnvImport.plan("PGHOST=h\nPGPASSWORD=pw\nDATABASE_URL_UNPOOLED=postgres://u:p@h/db\nREF=latchkey://X",
                               source: ".env.local", location: "/r/.env.local", project: "acp", environment: "development")
        XCTAssertEqual(p.items.map(\.name), ["acp/development/DATABASE_URL_UNPOOLED", "acp/development/PGHOST", "acp/development/PGPASSWORD"])
        XCTAssertEqual(p.references["PGHOST"], "acp/development/PGHOST")
        XCTAssertEqual(p.items.first { $0.name.hasSuffix("PGPASSWORD") }?.kind, .password)
        XCTAssertEqual(p.items.first { $0.name.hasSuffix("UNPOOLED") }?.kind, .password)
        XCTAssertEqual(p.items.first?.usedIn, ["/r/.env.local"])
        XCTAssertEqual(try EnvImport.plan("A=1", source: "x").items.map(\.name), ["A"], "no project: shared")
    }
}

final class ProjectBrokerTests: XCTestCase {
    let peer = PeerInfo(pid: 1, path: "/usr/local/bin/latchkey", cwd: "/tmp/acp", chain: ["zsh"])

    func testMoveKeepsMetadataRefusesCollisionsAndMergesUsedIn() throws {
        let store = MemoryStore()
        try store.save(name: "PGHOST", value: "h", kind: .value, agentSafe: true, note: "n", usedIn: ["/a/.env.local"])
        try store.save(name: "PGPASSWORD", value: "pw", kind: .password, agentSafe: false, note: "", usedIn: nil)
        try store.save(name: "acp/development/TAKEN", value: "t", kind: .token, agentSafe: false, note: "", usedIn: nil)
        try store.save(name: "TAKEN", value: "t2", kind: .token, agentSafe: false, note: "", usedIn: nil)
        let b = Broker(store: store, approver: FixedApprover(true), logURL: nil)

        let clash = b.handle(Request(op: "move", names: ["PGHOST", "TAKEN"], project: "acp", environment: "development"), peer: peer)
        XCTAssertFalse(clash.ok)
        XCTAssertNotNil(try store.info("PGHOST"), "nothing moves when one target is taken")

        let r = b.handle(Request(op: "move", names: ["PGHOST", "PGPASSWORD"], project: "acp", environment: "development"), peer: peer)
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertEqual(r.moved, ["PGHOST": "acp/development/PGHOST", "PGPASSWORD": "acp/development/PGPASSWORD"])
        let moved = try XCTUnwrap(store.info("acp/development/PGHOST"))
        XCTAssertEqual(moved.kind, .value)
        XCTAssertTrue(moved.agentSafe)
        XCTAssertEqual(moved.usedIn, ["/a/.env.local"])
        XCTAssertNil(try store.info("PGHOST"))
        XCTAssertEqual(try store.values(["acp/development/PGPASSWORD"]), ["acp/development/PGPASSWORD": "pw"])

        try store.save(name: "acp/development/PGHOST", value: nil, kind: nil, agentSafe: nil, note: nil, usedIn: ["/a/.env.local", "/b/.env"])
        XCTAssertEqual(try store.info("acp/development/PGHOST")?.usedIn, ["/a/.env.local", "/b/.env"])

        let back = b.handle(Request(op: "move", names: ["acp/development/PGHOST"], project: ""), peer: peer)
        XCTAssertEqual(back.moved, ["acp/development/PGHOST": "PGHOST"])
    }

    func testDeniedMoveChangesNothing() throws {
        let store = MemoryStore()
        try store.save(name: "A", value: "v", kind: nil, agentSafe: nil, note: nil)
        let r = Broker(store: store, approver: FixedApprover(false), logURL: nil)
            .handle(Request(op: "move", names: ["A"], project: "p", environment: "development"), peer: peer)
        XCTAssertFalse(r.ok)
        XCTAssertNotNil(try store.info("A"))
    }

    func testProjectWideGrants() throws {
        XCTAssertTrue(Grant.isPattern("acp/*"))
        XCTAssertTrue(Grant.isPattern("acp/production/*"))
        XCTAssertFalse(Grant.isPattern("*"))
        XCTAssertFalse(Grant.isPattern("acp/production/X/*"))
        let g = Grant(names: ["acp/production/*"], folder: "/tmp/acp", expires: Date().addingTimeInterval(60), createdBy: "t")
        XCTAssertTrue(g.covers("acp/production/NEW_LATER", cwd: "/tmp/acp"))
        XCTAssertFalse(g.covers("acp/development/X", cwd: "/tmp/acp"))
        XCTAssertFalse(g.covers("acpx/production/X", cwd: "/tmp/acp"))

        let store = MemoryStore()
        try store.save(name: "acp/production/DB", value: "v", kind: nil, agentSafe: nil, note: nil)
        let b = Broker(store: store, approver: FixedApprover(true), logURL: nil)
        XCTAssertTrue(b.handle(Request(op: "grant", names: ["acp/*"], folder: "/tmp/acp"), peer: peer).ok)
        XCTAssertEqual(b.handle(Request(op: "grant", names: ["nope/*"], folder: "/tmp/acp"), peer: peer).missing, ["nope/*"])
    }
}

final class ServiceTests: XCTestCase {
    func testGuessesFromValueHostThenKey() {
        XCTAssertEqual(Services.guess(key: "PAYMENTS", value: "sk_live_abc"), "Stripe", "value prefix beats a generic key")
        XCTAssertEqual(Services.guess(key: "DATABASE_URL", value: "postgres://u:p@ep-x.us-east-2.aws.neon.tech/db"), "Neon")
        XCTAssertEqual(Services.guess(key: "PGHOST", value: "ep-x.neon.tech"), nil, "a bare host without a scheme or @ is not trusted")
        XCTAssertEqual(Services.guess(key: "GITHUB_TOKEN", value: "plain"), "GitHub")
        XCTAssertNil(Services.guess(key: "PORT", value: "3000"))
    }

    func testStoreKeepsClearsAndImportFillsService() throws {
        let store = MemoryStore()
        try store.save(name: "A", value: "v", kind: nil, agentSafe: nil, note: nil, usedIn: nil, service: "Neon")
        try store.save(name: "A", value: nil, kind: nil, agentSafe: true, note: nil)
        XCTAssertEqual(try store.info("A")?.service, "Neon", "nil keeps")
        try store.save(name: "A", value: nil, kind: nil, agentSafe: nil, note: nil, usedIn: nil, service: "")
        XCTAssertNil(try store.info("A")?.service, "empty clears")
        XCTAssertEqual(try EnvImport.plan("STRIPE_SECRET=sk_test_1", source: "x").items.first?.service, "Stripe")
    }
}

final class BulkTests: XCTestCase {
    let peer = PeerInfo(pid: 1, path: "/usr/local/bin/latchkey", cwd: "/tmp", chain: ["zsh"])

    func store() throws -> MemoryStore {
        let s = MemoryStore()
        for n in ["acp/development/A", "acp/development/B", "acp/production/A"] {
            try s.save(name: n, value: "v-\(n)", kind: .token, agentSafe: true, note: "")
        }
        return s
    }

    func testDeleteManyWithOneApprovalOrNothing() throws {
        let s = try store()
        let approver = CountingApprover(true)
        let b = Broker(store: s, approver: approver, logURL: nil)
        let partial = b.handle(Request(op: "rm", names: ["acp/development/A", "nope"]), peer: peer)
        XCTAssertFalse(partial.ok)
        XCTAssertEqual(try s.list().count, 3, "a missing name deletes nothing")
        XCTAssertTrue(b.handle(Request(op: "rm", names: ["acp/development/A", "acp/development/B"]), peer: peer).ok)
        XCTAssertEqual(approver.reasons.count, 1)
        XCTAssertEqual(try s.list().map(\.name), ["acp/production/A"])
        XCTAssertEqual(b.handle(Request(op: "rm", names: ["gone"]), peer: peer).missing, ["gone"])
    }

    func testUpdateManyKeepsValues() throws {
        let s = try store()
        let approver = CountingApprover(true)
        let b = Broker(store: s, approver: approver, logURL: nil)
        let names = try s.list().map(\.name)
        let r = b.handle(Request(op: "update", names: names, kind: .password, agentSafe: false, service: "Neon"), peer: peer)
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertEqual(approver.reasons.count, 1)
        XCTAssertTrue(approver.reasons[0].hasPrefix("require approval for and set the kind to password for and set the service to Neon for 3 items"), approver.reasons[0])
        for i in try s.list() {
            XCTAssertFalse(i.agentSafe)
            XCTAssertEqual(i.kind, .password)
            XCTAssertEqual(i.service, "Neon")
        }
        XCTAssertEqual(try s.values(["acp/production/A"]), ["acp/production/A": "v-acp/production/A"])
        XCTAssertFalse(b.handle(Request(op: "update", names: names), peer: peer).ok, "nothing to change")
        XCTAssertFalse(Broker(store: s, approver: FixedApprover(false), logURL: nil)
            .handle(Request(op: "update", names: names, agentSafe: true), peer: peer).ok)
        XCTAssertFalse(try s.list().contains { $0.agentSafe })
    }
}
