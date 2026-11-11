import Foundation
import XCTest
import LatchkeyCore
@testable import latchkey

/// `run --env` against a real broker in memory: records, the older path-based lookup, and the two side by side.
final class EnvironmentRunTests: XCTestCase {
    let peer = PeerInfo(pid: 1, path: "/usr/local/bin/latchkey", cwd: "/tmp", chain: ["zsh"])
    var root: URL!
    var broker: Broker!
    var store: MemoryStore!
    var records: MemoryEnvironmentStore!
    var worktreeFile = "", mainFile = ""

    /// A main checkout holding the shared item's file and a worktree holding the environment's, laid out as git does.
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lk-run-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        let main = root.appendingPathComponent("Projects/shop"), worktree = root.appendingPathComponent("_worktrees/shop/feature")
        let gitWorktreeDir = main.appendingPathComponent(".git/worktrees/feature")
        try FileManager.default.createDirectory(at: gitWorktreeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(gitWorktreeDir.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: gitWorktreeDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        worktreeFile = worktree.appendingPathComponent(".env.local").path
        mainFile = main.appendingPathComponent(".env").path
        try "DATABASE_URL=latchkey://shop/development/DATABASE_URL\nOPENAI_API_KEY=latchkey://OPENAI_API_KEY\n"
            .write(toFile: worktreeFile, atomically: true, encoding: .utf8)

        store = MemoryStore()
        records = MemoryEnvironmentStore()
        try store.save(name: "shop/development/DATABASE_URL", value: "postgres://fixture", kind: .password, agentSafe: false, note: "", usedIn: [worktreeFile])
        try store.save(name: "OPENAI_API_KEY", value: "fixture-openai", kind: .token, agentSafe: false, note: "", usedIn: [mainFile])
        broker = Broker(store: store, approver: FixedApprover(true), logURL: nil, records: records)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func planned(base: [String: String] = [:]) throws -> (env: [String: String], notes: [String]) {
        var notes: [String] = []
        let env = try plannedEnvironment(RunSpec(scopes: ["shop/development"], cwd: "/tmp"), base: base,
                                         call: { self.broker.handle($0, peer: self.peer) }, notes: { notes.append($0) })
        return (env, notes)
    }

    func migrate() throws {
        let files = [worktreeFile: try String(contentsOfFile: worktreeFile, encoding: .utf8)]
        let plan = EnvironmentMigration.plan(items: try store.list(), existing: try records.environments(), files: files)
        XCTAssertTrue(broker.handle(Request(op: "environment-add", environments: plan.records), peer: peer).ok)
    }

    let expected = ["DATABASE_URL": "latchkey://shop/development/DATABASE_URL", "OPENAI_API_KEY": "latchkey://OPENAI_API_KEY"]

    func testAMigratedRecordLoadsWhatThePathLookupDid() throws {
        let before = try planned()
        XCTAssertEqual(before.env, expected)
        XCTAssertTrue(before.notes.first?.contains("no environment record") == true)
        try migrate()
        let after = try planned()
        XCTAssertEqual(after.env, before.env, "parity: the record loads the same variables")
        XCTAssertEqual(after.notes, [])
    }

    func testASharedItemStillLoadsAfterTheCheckoutMoves() throws {
        try migrate()
        try FileManager.default.removeItem(at: root)   // another Mac: none of those paths
        XCTAssertEqual(try planned().env, expected)

        records = MemoryEnvironmentStore()
        broker = Broker(store: store, approver: FixedApprover(true), logURL: nil, records: records)
        XCTAssertEqual(try planned().env, ["DATABASE_URL": "latchkey://shop/development/DATABASE_URL"],
                       "without a record, the path lookup drops the shared item: the failure records fix")
    }

    func testUntilMigratedTheOldLookupFillsGapsAndSaysSo() throws {
        // A record started by an import, before `env migrate`: the shared item isn't in it yet.
        try records.save(EnvironmentRecord(scope: "shop/development", variables: ["DATABASE_URL": .credential("shop/development/DATABASE_URL"),
                                                                                    "PORT": .literal("3000")]))
        let early = try planned()
        XCTAssertEqual(early.env, expected.merging(["PORT": "3000"]) { a, _ in a })
        XCTAssertTrue(early.notes.joined().contains("OPENAI_API_KEY; run `lk env migrate`"), early.notes.joined())

        // Checked: the record decides. Something removed from it stays out, and that's said.
        var checked = try XCTUnwrap(records.environments().first)
        checked.legacyChecked = true
        try records.save(checked)
        let late = try planned()
        XCTAssertNil(late.env["OPENAI_API_KEY"])
        XCTAssertTrue(late.notes.joined().contains("not loaded, not in shop/development's record: OPENAI_API_KEY"), late.notes.joined())
    }

    func testTheCallersOwnVariablesStillWinOverSharedItems() throws {
        let fromShell = try planned(base: ["OPENAI_API_KEY": "from-the-shell"])
        XCTAssertEqual(fromShell.env["OPENAI_API_KEY"], "from-the-shell", "as before records: a shared item never replaces a set variable")
        XCTAssertEqual(fromShell.env["DATABASE_URL"], "latchkey://shop/development/DATABASE_URL")
    }
}

/// The command-line tool itself, against a broker in memory on its own socket: link a checkout, migrate, then on a
/// fresh clone somewhere else, find the project, export its env file and run with it, then export values.
final class FreshCheckoutTests: XCTestCase {
    var root: URL!
    var socket = ""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lk-e2e-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        socket = "/tmp/lk-\(UUID().uuidString.prefix(8)).sock"   // short: socket paths are limited to 104 bytes
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        unlink(socket)
    }

    func checkout(_ path: String, origin: String) throws -> URL {
        let dir = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "[remote \"origin\"]\n\turl = \(origin)\n".write(to: dir.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        return dir
    }

    @discardableResult
    func lk(_ args: [String], in dir: URL, expect status: Int32 = 0) throws -> String {
        let tool = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("latchkey")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { throw XCTSkip("the latchkey tool isn't built next to the tests") }
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        p.currentDirectoryURL = dir
        p.environment = ["LATCHKEY_SOCKET": socket, "LATCHKEY_NO_LAUNCH": "1", "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(p.terminationStatus, status, "latchkey \(args.joined(separator: " ")):\n\(text)")
        return text
    }

    func testAFreshCloneElsewhereFindsItsEnvironmentExportsAndRuns() throws {
        let store = MemoryStore(), records = MemoryEnvironmentStore()
        let broker = Broker(store: store, approver: FixedApprover(true), logURL: nil, records: records)
        let path = socket
        Thread.detachNewThread { try? broker.serve(socketPath: path) }
        var waited = 0
        while (try? UnixSocket.connect(socket)).map({ close($0) }) == nil && waited < 50 { usleep(100_000); waited += 1 }

        // The first Mac: a worktree's env file and a shared key in the main checkout.
        let a = try checkout("old/Projects/shop", origin: "git@github.com:acme/shop.git")
        try "DATABASE_URL=latchkey://shop/development/DATABASE_URL\nOPENAI_API_KEY=latchkey://OPENAI_API_KEY\nPORT=3000\n"
            .write(to: a.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
        try store.save(name: "shop/development/DATABASE_URL", value: "postgres://fixture", kind: .password, agentSafe: false, note: "",
                       usedIn: [a.appendingPathComponent(".env.local").path])
        try store.save(name: "OPENAI_API_KEY", value: "fixture-openai-value", kind: .token, agentSafe: false, note: "",
                       usedIn: [a.appendingPathComponent("../other/.env").standardizedFileURL.path])
        try lk(["project", "link", "shop"], in: a)
        let migrated = try lk(["env", "migrate"], in: a)
        XCTAssertTrue(migrated.contains("recorded"), migrated)

        // The second Mac: a clone under another name and path, by HTTPS. The old checkout is gone.
        try FileManager.default.removeItem(at: root.appendingPathComponent("old"))
        let b = try checkout("new/Code/shop-app", origin: "https://github.com/acme/shop")
        let found = try lk(["project"], in: b)
        XCTAssertTrue(found.contains("project shop (through origin)"), found)
        XCTAssertTrue(found.contains("lk export shop/development"), found)

        try lk(["export", "shop/development", "--out", ".env.local"], in: b)
        let refs = try String(contentsOf: b.appendingPathComponent(".env.local"), encoding: .utf8)
        XCTAssertEqual(refs, "# Latchkey environment shop/development\nDATABASE_URL=latchkey://shop/development/DATABASE_URL\nOPENAI_API_KEY=latchkey://OPENAI_API_KEY\nPORT=3000\n")
        XCTAssertFalse(refs.contains("fixture"))
        try lk(["export", "shop/development", "--out", ".env.local"], in: b, expect: 73)   // exists: left alone

        let ran = try lk(["run", "--env-file", ".env.local", "--", "/bin/sh", "-c",
                          "test \"$OPENAI_API_KEY\" = fixture-openai-value && test \"$PORT\" = 3000 && echo shared-and-plain-ok"], in: b)
        XCTAssertTrue(ran.contains("shared-and-plain-ok"), ran)
        let byEnv = try lk(["run", "--env", "shop/development", "--", "/bin/sh", "-c", "test -n \"$OPENAI_API_KEY\" && echo env-ok"], in: b)
        XCTAssertTrue(byEnv.contains("env-ok"), byEnv)
        XCTAssertFalse(byEnv.contains("no environment record"), byEnv)

        try lk(["export", "shop/development", "--values"], in: b, expect: 64)   // values only to a named file
        try lk(["export", "shop/development", "--out", "values.env", "--values"], in: b)
        let values = b.appendingPathComponent("values.env").path
        XCTAssertTrue(try String(contentsOfFile: values, encoding: .utf8).contains("OPENAI_API_KEY=fixture-openai-value"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: values)[.posixPermissions] as? Int), 0o600)
    }
}
