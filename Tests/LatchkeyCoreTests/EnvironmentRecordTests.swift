import XCTest
@testable import LatchkeyCore

final class EnvironmentRecordTests: XCTestCase {
    let peer = PeerInfo(pid: 1, path: "/usr/local/bin/latchkey", cwd: "/tmp/project", chain: ["zsh"])
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lk-env-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func info(_ name: String, usedIn: [String]? = nil, kind: ItemKind = .token) -> SecretInfo {
        SecretInfo(name: name, kind: kind, agentSafe: false, note: "", updatedAt: Date(), usedIn: usedIn)
    }

    // MARK: shape

    func testEntriesAreTypedAndUnknownTypesAreRefused() throws {
        let record = EnvironmentRecord(scope: "shop/development",
                                       variables: ["PORT": .literal("3000"), "OPENAI_API_KEY": .credential("OPENAI_API_KEY"),
                                                   "DATABASE_URL": .credential("shop/development/DATABASE_URL")],
                                       updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try Wire.encoder().encode(record)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""PORT":{"type":"literal","value":"3000"}"#), text)
        XCTAssertTrue(text.contains(#""OPENAI_API_KEY":{"item":"OPENAI_API_KEY","type":"credential"}"#), text)
        XCTAssertEqual(try Wire.decoder().decode(EnvironmentRecord.self, from: data), record)

        let unknown = Data(text.replacingOccurrences(of: #""type":"literal""#, with: #""type":"command""#).utf8)
        XCTAssertThrowsError(try Wire.decoder().decode(EnvironmentRecord.self, from: unknown))
        let badItem = Data(text.replacingOccurrences(of: #""item":"OPENAI_API_KEY""#, with: #""item":"a/b""#).utf8)
        XCTAssertThrowsError(try Wire.decoder().decode(EnvironmentRecord.self, from: badItem))
    }

    func testTheEnvFileReadsBackAsWritten() throws {
        let record = EnvironmentRecord(scope: "shop/development", variables: [
            "PORT": .literal("3000"), "GREETING": .literal("hello \"world\" #1\nline two"),
            "DATABASE_URL": .credential("shop/development/DATABASE_URL"),
        ])
        let parsed = Dictionary(try EnvFile.parse(record.envFile()).map { ($0.key, $0.value) }) { _, b in b }
        XCTAssertEqual(parsed, ["PORT": "3000", "GREETING": "hello \"world\" #1\nline two",
                                "DATABASE_URL": "latchkey://shop/development/DATABASE_URL"])
        let withValues = Dictionary(try EnvFile.parse(record.envFile(values: ["shop/development/DATABASE_URL": "postgres://u:p w@h/db"])).map { ($0.key, $0.value) }) { _, b in b }
        XCTAssertEqual(withValues["DATABASE_URL"], "postgres://u:p w@h/db")
    }

    func testRemotesNormalizeAndNeverKeepCredentials() {
        for url in ["git@github.com:Me/Shop.git", "https://github.com/me/shop", "https://user:ghp_secret@github.com/me/shop.git/",
                    "ssh://git@github.com:22/me/shop.git"] {
            XCTAssertEqual(GitRemotes.normalize(url), "github.com/me/shop", url)
        }
        XCTAssertNil(GitRemotes.normalize("/Users/me/repos/shop"))
        XCTAssertNil(GitRemotes.normalize("../shop"))
        let config = """
        [core]
        \trepositoryformatversion = 0
        [remote "origin"]
        \turl = git@github.com:me/shop-fork.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [remote "upstream"]
        \turl = https://github.com/acme/shop.git
        """
        XCTAssertEqual(GitRemotes.parse(config: config), ["origin": "github.com/me/shop-fork", "upstream": "github.com/acme/shop"])
    }

    func testAForkIsFlaggedAndOnlyItsOwnOriginNamesAProject() {
        let shop = ProjectRecord(name: "shop", origins: ["github.com/acme/shop"])
        let fork = ["origin": "github.com/me/shop-fork", "upstream": "github.com/acme/shop"]
        let matches = ProjectMatching.matches(remotes: fork, projects: [shop])
        XCTAssertEqual(matches.map(\.project.name), ["shop"])
        XCTAssertEqual(matches.first?.throughOrigin, false, "a match through upstream is how a fork looks")
        XCTAssertNil(ProjectMatching.project(remotes: fork, projects: [shop]))
        XCTAssertEqual(ProjectMatching.project(remotes: ["origin": "github.com/acme/shop"], projects: [shop])?.name, "shop")
        XCTAssertEqual(ProjectMatching.project(remotes: ["github": "github.com/acme/shop"], projects: [shop])?.name, "shop", "a lone remote counts as origin")
        let other = ProjectRecord(name: "shop-two", origins: ["github.com/acme/shop"])
        XCTAssertNil(ProjectMatching.project(remotes: ["origin": "github.com/acme/shop"], projects: [shop, other]), "two claims: none taken")
    }

    // MARK: the regression

    /// A shared item imported in the main checkout and an environment's items imported in a worktree: on the Mac that
    /// did it, the path-based lookup ties them together through the repository. On a Mac where those paths don't
    /// exist it can't, and the shared item is silently left out. The record keeps it.
    func testASharedItemResolvesFromAnotherCheckoutPath() throws {
        let main = root.appendingPathComponent("old-mac/Projects/shop")
        let worktree = root.appendingPathComponent("old-mac/_worktrees/shop/feature")
        let gitWorktreeDir = main.appendingPathComponent(".git/worktrees/feature")
        try FileManager.default.createDirectory(at: gitWorktreeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(gitWorktreeDir.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: gitWorktreeDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        let worktreeFile = worktree.appendingPathComponent(".env.local").path
        let mainFile = main.appendingPathComponent(".env").path
        try "DATABASE_URL=latchkey://shop/development/DATABASE_URL\nOPENAI_API_KEY=latchkey://OPENAI_API_KEY\nPORT=3000\n"
            .write(toFile: worktreeFile, atomically: true, encoding: .utf8)

        let items = [info("shop/development/DATABASE_URL", usedIn: [worktreeFile]), info("OPENAI_API_KEY", usedIn: [mainFile])]
        XCTAssertEqual(EnvironmentRecords.legacy(scope: "shop/development", items: items)["OPENAI_API_KEY"], "OPENAI_API_KEY",
                       "where the paths exist, the old lookup finds the shared item")

        let files = [worktreeFile: try String(contentsOfFile: worktreeFile, encoding: .utf8)]
        let plan = EnvironmentMigration.plan(items: items, existing: [], files: files)
        let record = try XCTUnwrap(plan.records.first)
        XCTAssertEqual(record.variables, ["DATABASE_URL": .credential("shop/development/DATABASE_URL"),
                                          "OPENAI_API_KEY": .credential("OPENAI_API_KEY"), "PORT": .literal("3000")])
        XCTAssertEqual(record.inferred, ["OPENAI_API_KEY", "PORT"], "only membership by ID is certain")
        XCTAssertTrue(record.legacyChecked)

        // Another Mac: same synced items and record, none of those paths.
        try FileManager.default.removeItem(at: root.appendingPathComponent("old-mac"))
        XCTAssertNil(EnvironmentRecords.legacy(scope: "shop/development", items: items)["OPENAI_API_KEY"],
                     "the old lookup loses the shared item when the checkout isn't where it was")
        XCTAssertEqual(record.variables["OPENAI_API_KEY"], .credential("OPENAI_API_KEY"))
        let again = EnvironmentMigration.plan(items: items, existing: [record], files: [:])
        XCTAssertEqual(EnvironmentRecords.adding(again.records[0], to: record).added, [], "migrating again here adds and removes nothing")
        XCTAssertEqual(again.unreadable, [worktreeFile])
    }

    // MARK: migration

    func testMigrationReportsInsteadOfChoosing() throws {
        let file = root.appendingPathComponent(".env.local").path
        let text = """
        DATABASE_URL=latchkey://shop/development/DATABASE_URL
        STRIPE_KEY=latchkey://STRIPE_KEY
        GHOST=latchkey://NOT_THERE
        SESSION_SECRET=abc123def456ghi789jkl012
        DEBUG=true
        """
        let items = [info("shop/development/DATABASE_URL", usedIn: [file]), info("shop/development/STRIPE_KEY", usedIn: [file]),
                     info("STRIPE_KEY")]
        let stored = EnvironmentRecord(scope: "shop/development", variables: ["DEBUG": .literal("false")], legacyChecked: false)
        let plan = EnvironmentMigration.plan(items: items, existing: [stored], files: [file: text])
        let record = try XCTUnwrap(plan.records.first)
        XCTAssertEqual(record.variables["STRIPE_KEY"], .credential("shop/development/STRIPE_KEY"), "the environment's own item stands")
        XCTAssertNil(record.variables["SESSION_SECRET"], "a plain value that may be secret is never stored")
        XCTAssertNil(record.variables["GHOST"])
        let notes = plan.notRecorded["shop/development"]?.joined(separator: "\n") ?? ""
        XCTAssertTrue(notes.contains("SESSION_SECRET: plain value"), notes)
        XCTAssertTrue(notes.contains("GHOST: refers to NOT_THERE"), notes)
        let conflicts = plan.conflicts["shop/development"]?.joined(separator: "\n") ?? ""
        XCTAssertTrue(conflicts.contains("STRIPE_KEY"), conflicts)
        XCTAssertTrue(conflicts.contains("DEBUG: stored as \"false\""), conflicts)

        let merged = EnvironmentRecords.adding(record, to: stored)
        XCTAssertEqual(merged.record.variables["DEBUG"], .literal("false"), "a stored variable is never overwritten")
        XCTAssertEqual(merged.added, ["DATABASE_URL", "STRIPE_KEY"])
        XCTAssertTrue(merged.record.legacyChecked)
    }

    // MARK: broker

    func makeBroker(_ approver: Approver = RecordingApprover()) throws -> (Broker, MemoryStore, MemoryEnvironmentStore) {
        let store = MemoryStore(), records = MemoryEnvironmentStore()
        return (Broker(store: store, approver: approver, logURL: nil, records: records), store, records)
    }

    func testImportRecordsTheFilesVariablesInTheSameApproval() throws {
        let approver = CountingApprover(true)
        let (b, store, records) = try makeBroker(approver)
        try store.save(name: "OPENAI_API_KEY", value: "sk-shared", kind: .token, agentSafe: false, note: "")
        try store.save(name: "shop/development/OLD", value: "x", kind: .token, agentSafe: false, note: "")
        let file = EnvironmentRecord(scope: "shop/development", variables: ["DATABASE_URL": .credential("shop/development/DATABASE_URL"),
                                                                            "OPENAI_API_KEY": .credential("OPENAI_API_KEY"),
                                                                            "MISSING": .credential("NOT_SAVED")])
        let r = b.handle(Request(op: "import", items: [ImportItem(name: "shop/development/DATABASE_URL", value: "postgres://a")],
                                 source: "/x/.env.local", environments: [file]), peer: peer)
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertEqual(approver.reasons.count, 1)
        XCTAssertTrue(approver.reasons[0].contains("record which variables shop/development has"), approver.reasons[0])
        let saved = try XCTUnwrap(records.environments().first)
        XCTAssertEqual(saved.variables, ["DATABASE_URL": .credential("shop/development/DATABASE_URL"),
                                         "OPENAI_API_KEY": .credential("OPENAI_API_KEY"), "OLD": .credential("shop/development/OLD")],
                       "items already in the environment are kept; a reference to an item that doesn't exist isn't recorded")
        XCTAssertFalse(saved.legacyChecked)
    }

    func testSetAndMoveKeepRecordsCurrentButNeverStartOne() throws {
        let (b, store, records) = try makeBroker()
        XCTAssertTrue(b.handle(Request(op: "set", names: ["shop/staging/A"], value: "a"), peer: peer).ok)
        XCTAssertEqual(try records.environments(), [], "no record yet: the environment keeps working as before")

        try records.save(EnvironmentRecord(scope: "shop/development", variables: ["TOKEN": .credential("TOKEN")]))
        try store.save(name: "TOKEN", value: "t", kind: .token, agentSafe: false, note: "")
        XCTAssertTrue(b.handle(Request(op: "set", names: ["shop/development/NEW"], value: "n"), peer: peer).ok)
        XCTAssertEqual(try records.environments().first?.variables["NEW"], .credential("shop/development/NEW"))

        XCTAssertTrue(b.handle(Request(op: "move", names: ["TOKEN"], project: "shop", environment: "development"), peer: peer).ok)
        XCTAssertEqual(try records.environments().first?.variables["TOKEN"], .credential("shop/development/TOKEN"))
    }

    func testMigrationAddsOnlyAndAsksOnce() throws {
        let approver = CountingApprover(true)
        let (b, _, records) = try makeBroker(approver)
        try records.save(EnvironmentRecord(scope: "shop/development", variables: ["A": .literal("1")]))
        let proposed = EnvironmentRecord(scope: "shop/development", variables: ["A": .literal("2"), "B": .credential("B")],
                                         inferred: ["B"], legacyChecked: true)
        let r = b.handle(Request(op: "environment-add", environments: [proposed]), peer: peer)
        XCTAssertTrue(r.ok, r.error ?? "")
        let saved = try XCTUnwrap(records.environments().first)
        XCTAssertEqual(saved.variables, ["A": .literal("1"), "B": .credential("B")])
        XCTAssertEqual(saved.inferred, ["B"])
        XCTAssertTrue(saved.legacyChecked)
        XCTAssertEqual(approver.reasons.count, 1)
        XCTAssertTrue(b.handle(Request(op: "environment-add", environments: [proposed]), peer: peer).ok)
        XCTAssertEqual(approver.reasons.count, 1, "nothing new: nothing asked")
    }

    func testEnvironmentChangesAreCheckedAndAsked() throws {
        let (deny, _, denied) = try makeBroker(FixedApprover(false))
        XCTAssertFalse(deny.handle(Request(op: "environment-set", names: ["shop/development"],
                                           environments: [EnvironmentRecord(scope: "shop/development", variables: ["PORT": .literal("3000")])]), peer: peer).ok)
        XCTAssertEqual(try denied.environments(), [])

        let (b, store, records) = try makeBroker()
        func set(_ vars: [String: EnvironmentEntry]) -> Response {
            b.handle(Request(op: "environment-set", names: ["shop/development"], environments: [EnvironmentRecord(scope: "shop/development", variables: vars)]), peer: peer)
        }
        XCTAssertTrue(set(["PORT": .literal("3000")]).ok)
        XCTAssertFalse(set(["API_TOKEN": .literal("abc")]).ok, "a plain value named like a secret is refused")
        XCTAssertFalse(set(["X": .literal("latchkey://OPENAI")]).ok, "a plain value can't hide a reference")
        XCTAssertEqual(set(["X": .credential("NOPE")]).missing, ["NOPE"])
        try store.save(name: "OPENAI", value: "sk", kind: .token, agentSafe: false, note: "")
        XCTAssertTrue(set(["OPENAI_API_KEY": .credential("OPENAI")]).ok)
        XCTAssertTrue(b.handle(Request(op: "environment-set", names: ["shop/development"], unset: ["PORT"]), peer: peer).ok)
        XCTAssertEqual(try records.environments().first?.variables, ["OPENAI_API_KEY": .credential("OPENAI")])
        XCTAssertFalse(b.handle(Request(op: "environment-set", names: ["shop/development"], unset: ["NOPE"]), peer: peer).ok)
    }

    func testExportAsksEveryTimeNamingTheFileAndAgentsCant() throws {
        let approver = RecordingApprover()
        let (b, store, _) = try makeBroker(approver)
        try store.save(name: "shop/development/DB", value: "postgres://secret", kind: .password, agentSafe: true, note: "")
        let req = Request(op: "export", names: ["shop/development/DB"], project: "shop/development", destination: "/tmp/x/.env.local")
        let r = b.handle(req, peer: peer)
        XCTAssertEqual(r.values, ["shop/development/DB": "postgres://secret"])
        XCTAssertEqual(approver.requests.count, 1, "even an agent-safe item asks before it's written out in plain text")
        XCTAssertTrue(approver.requests[0].reason.contains("in plain text to /tmp/x/.env.local"), approver.requests[0].reason)

        var agent = req
        agent.origin = "mcp"
        XCTAssertFalse(b.handle(agent, peer: peer).ok)
        XCTAssertFalse(b.handle(Request(op: "export", names: ["shop/development/DB"], destination: "relative/.env"), peer: peer).ok)
        XCTAssertEqual(approver.requests.count, 1)
        let (deny, store2, _) = try makeBroker(FixedApprover(false))
        try store2.save(name: "A", value: "a", kind: .token, agentSafe: false, note: "")
        XCTAssertNil(deny.handle(Request(op: "export", names: ["A"], destination: "/tmp/a"), peer: peer).values)
    }

    func testARemoteBelongsToOneProject() throws {
        let (b, _, records) = try makeBroker()
        XCTAssertTrue(b.handle(Request(op: "project-link", project: "shop", origins: ["github.com/acme/shop"]), peer: peer).ok)
        let id = try XCTUnwrap(records.projects().first?.id)
        XCTAssertFalse(b.handle(Request(op: "project-link", project: "other", origins: ["github.com/acme/shop"]), peer: peer).ok)
        XCTAssertFalse(b.handle(Request(op: "project-link", project: "shop", origins: ["https://github.com/acme/shop.git"]), peer: peer).ok,
                       "only normalized remotes are stored")
        XCTAssertTrue(b.handle(Request(op: "project-link", project: "shop", origins: ["github.com/acme/shop-renamed"]), peer: peer).ok)
        XCTAssertEqual(try records.projects().first?.id, id, "the project keeps its id as remotes change")
        XCTAssertTrue(b.handle(Request(op: "project-unlink", project: "shop", origins: ["github.com/acme/shop"]), peer: peer).ok)
        XCTAssertEqual(try records.projects().first?.origins, ["github.com/acme/shop-renamed"])
    }

    // MARK: writing files

    func testExportWritesAtomicallyAndRefusesLinks() throws {
        let path = root.appendingPathComponent(".env.local").path
        try EnvFile.writeAtomically("A=1\n", to: path, mode: 0o600, replace: false)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "A=1\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int), 0o600)
        XCTAssertThrowsError(try EnvFile.writeAtomically("A=2\n", to: path, mode: 0o600, replace: false))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "A=1\n", "an existing file is left whole")
        try EnvFile.writeAtomically("A=2\n", to: path, mode: 0o644, replace: true)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "A=2\n")

        let target = root.appendingPathComponent("elsewhere").path
        try "keep\n".write(toFile: target, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent(".env.linked").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        XCTAssertThrowsError(try EnvFile.writeAtomically("A=3\n", to: link, mode: 0o600, replace: true))
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "keep\n")
        XCTAssertThrowsError(try EnvFile.writeAtomically("A=3\n", to: root.path, mode: 0o600, replace: true), "a folder isn't a file")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".latchkey-") }
        XCTAssertEqual(leftovers, [], "no temporary files left behind")
    }

    func testSecretLookingSettingsAreRecognized() {
        XCTAssertFalse(EnvironmentRecord.mayBeSecret(name: "PORT", value: "3000"))
        XCTAssertFalse(EnvironmentRecord.mayBeSecret(name: "NODE_ENV", value: "development"))
        XCTAssertFalse(EnvironmentRecord.mayBeSecret(name: "API_BASE", value: "https://api.example.com"))
        XCTAssertTrue(EnvironmentRecord.mayBeSecret(name: "STRIPE_KEY", value: "x"))
        XCTAssertTrue(EnvironmentRecord.mayBeSecret(name: "DATABASE_URL", value: "postgres://u:p@h/db"))
        XCTAssertTrue(EnvironmentRecord.mayBeSecret(name: "THING", value: "a8f9d7s6f5g4h3j2k1l0qwerty"))
    }
}
