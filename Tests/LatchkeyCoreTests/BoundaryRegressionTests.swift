import XCTest
@testable import LatchkeyCore

/// What an approval shows must be what it allows, and data a caller or another device supplies must not widen scope.
final class BoundaryRegressionTests: XCTestCase {
    let peer = PeerInfo(pid: 1, path: "/usr/local/bin/latchkey", cwd: "/tmp", chain: ["zsh"])
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lk-br-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testCallerTextCantCutTheApprovalSummaryShort() throws {
        let store = MemoryStore(), approver = RecordingApprover()
        try store.save(name: "X", value: "x-value-1", kind: .token, agentSafe: false, note: "")
        let b = Broker(store: store, approver: approver, logURL: nil)
        XCTAssertTrue(b.handle(Request(op: "update", names: ["X"], service: "s, asked by y", fillSites: ["attacker.example"]), peer: peer).ok)
        let r = try XCTUnwrap(approver.requests.first)
        XCTAssertTrue(r.summary.contains("attacker.example"), r.summary)
        XCTAssertTrue(r.touchIDReason.contains("attacker.example"), r.touchIDReason)
    }

    func testAnUnidentifiedCallerIsWarnedAboutAndNotSheetFirst() throws {
        let approver = RecordingApprover()
        let b = Broker(store: MemoryStore(), approver: approver, logURL: nil)
        _ = b.handle(Request(op: "set", names: ["A"], value: "a-value-1"), peer: PeerInfo(pid: 99999, path: "", cwd: "", chain: []))
        let r = try XCTUnwrap(approver.requests.first)
        XCTAssertEqual(r.program, Broker.unidentifiedProgram)
        XCTAssertFalse(r.sheetFirst, "the panel and its warning come first")
    }

    func testCombineAsksBeforeComparingValues() throws {
        let store = MemoryStore(), approver = CountingApprover(false)
        try store.save(name: "a/development/K", value: "value-one-123", kind: .token, agentSafe: false, note: "")
        try store.save(name: "b/development/K", value: "value-two-456", kind: .token, agentSafe: false, note: "")
        let b = Broker(store: store, approver: approver, logURL: nil, records: MemoryEnvironmentStore())
        let r = b.handle(Request(op: "combine", names: ["a/development/K", "b/development/K"], into: "SHARED_K"), peer: peer)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(approver.reasons.count, 1, "different values are only compared after approval")
        XCTAssertEqual(r.error, "combining was not approved", "a denial says nothing about the values")
    }

    func testAForgedGitFileOrSymlinkIsNoRepository() throws {
        let main = root.appendingPathComponent("main"), forged = root.appendingPathComponent("forged"), linked = root.appendingPathComponent("linked")
        for d in [main.appendingPathComponent(".git"), forged, linked] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try "gitdir: \(main.appendingPathComponent(".git").path)\n".write(to: forged.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent(".git"), withDestinationURL: main.appendingPathComponent(".git"))
        XCTAssertNotNil(Repo.commonDir(for: main.path))
        XCTAssertNil(Repo.commonDir(for: forged.path))
        XCTAssertNil(Repo.commonDir(for: linked.path))
        let g = GrantStore().add(names: ["K"], folder: main.path, duration: 3600, createdBy: "t")
        XCTAssertTrue(g.covers("K", cwd: main.path))
        XCTAssertFalse(g.covers("K", cwd: forged.path))
        XCTAssertFalse(g.covers("K", cwd: linked.path))
    }

    func testAFailedGrantSaveIsReportedNotHidden() throws {
        let backing = FailingGrantBacking()
        let store = MemoryStore()
        try store.save(name: "K", value: "k-value-1", kind: .token, agentSafe: false, note: "")
        let b = Broker(store: store, approver: RecordingApprover(), logURL: nil, grants: GrantStore(backing: backing))
        let g = b.grants.add(names: ["K"], folder: "/tmp", duration: 3600, createdBy: "t")
        let r = b.handle(Request(op: "revoke", names: [g.id]), peer: peer)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.error?.contains("couldn't save") ?? false, r.error ?? "")
        XCTAssertNil(b.grants.covering("K", cwd: "/tmp"), "ended for this session even so")
    }

    func testRemoteStatusErrorsNeverQuoteListOutput() throws {
        let store = MemoryStore()
        let runner = ScriptedRunner(status: 1, stdout: #"[{"name":"DB","value":"db-secret-value"}]"#, stderr: "")
        let b = Broker(store: store, approver: RecordingApprover(), logURL: nil, remotes: MemoryRemoteStore(), runner: runner)
        try b.remotes.save(RemoteLink(scope: "acp/production", target: RemoteTarget(service: .railway, environment: "production", serviceName: "api")))
        let s = try XCTUnwrap(b.handle(Request(op: "remote-status", names: ["acp/production"]), peer: peer).remoteStatus?.first)
        XCTAssertFalse(s.error?.contains("db-secret-value") ?? false, s.error ?? "")
        runner.status = 0
        let parsed = try XCTUnwrap(b.handle(Request(op: "remote-status", names: ["acp/production"]), peer: peer).remoteStatus?.first)
        XCTAssertFalse(parsed.error?.contains("db-secret-value") ?? false)
    }

    func testPushRefusesAnInvalidVariableNameFromARecord() throws {
        let store = MemoryStore(), runner = FakeRunner()
        try store.save(name: "acp/production/DB", value: "db-secret", kind: .password, agentSafe: false, note: "")
        let b = Broker(store: store, approver: RecordingApprover(), logURL: nil, remotes: MemoryRemoteStore(), runner: runner,
                       records: MemoryEnvironmentStore())
        try b.records.save(EnvironmentRecord(scope: "acp/production", variables: ["EVIL=1\nPAD": .credential("acp/production/DB")], legacyChecked: true))
        try b.remotes.save(RemoteLink(scope: "acp/production", target: RemoteTarget(service: .fly, app: "acp-api")))
        let r = b.handle(Request(op: "push", names: ["acp/production"]), peer: peer)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(runner.ran.isEmpty, "nothing reaches the tool")
    }

    func testLinkAndPushApprovalsNameTheProjectAndFolder() {
        let t = RemoteTarget(service: .railway, project: "P1", environment: "production", serviceName: "api", directory: "/tmp/p")
        XCTAssertTrue(t.approvalLabel.contains("project P1"), t.approvalLabel)
        XCTAssertTrue(t.approvalLabel.contains("folder /tmp/p"), t.approvalLabel)
        XCTAssertNotEqual(t.approvalLabel, RemoteTarget(service: .railway, project: "P2", environment: "production", serviceName: "api").approvalLabel)
    }

    func testEnvironmentApprovalNamesWhatEachVariableResolvesTo() throws {
        let store = MemoryStore(), approver = CountingApprover(true)
        try store.save(name: "shop/production/DB", value: "db-secret", kind: .password, agentSafe: false, note: "")
        let b = Broker(store: store, approver: approver, logURL: nil, records: MemoryEnvironmentStore())
        let rec = EnvironmentRecord(scope: "shop/development", variables: ["API_BASE_URL": .literal("https://api.example.com"),
                                                                           "DB": .credential("shop/production/DB")])
        XCTAssertTrue(b.handle(Request(op: "environment-set", names: ["shop/development"], environments: [rec]), peer: peer).ok)
        let reason = try XCTUnwrap(approver.reasons.first)
        XCTAssertTrue(reason.contains("API_BASE_URL to https://api.example.com"), reason)
        XCTAssertTrue(reason.contains("DB to item shop/production/DB"), reason)
    }

    func testRewritingASymlinkedEnvFileRewritesItsTarget() throws {
        let target = root.appendingPathComponent("target.env"), link = root.appendingPathComponent(".env")
        let text = "KEY=value-secret\nPORT=1\n"
        try text.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try EnvFile.rewriteFile(at: link, original: text, toReferences: ["KEY": "p/e/KEY"])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path, "the link stays a link")
        let rewritten = try String(contentsOf: target, encoding: .utf8)
        XCTAssertFalse(rewritten.contains("value-secret"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int, 0o600)
    }

    func testExportGitCheckSeesACheckoutThroughASymlink() throws {
        let repo = root.appendingPathComponent("repo"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: outside.appendingPathComponent("into"), withDestinationURL: repo)
        // The lexical folder has no .git; resolved, it's the checkout, so the check runs (and git, finding no real
        // repository here, makes it refuse rather than skip).
        XCTAssertNotNil(EnvExport.gitProblem(outside.appendingPathComponent("into/.env.local").path))
    }
}

final class FailingGrantBacking: GrantBacking, @unchecked Sendable {
    func load() -> Data? { nil }
    func save(_ data: Data) -> Bool { false }
}

final class ScriptedRunner: RemoteRunner, @unchecked Sendable {
    var status: Int32, stdout: String, stderr: String
    init(status: Int32, stdout: String, stderr: String) { self.status = status; self.stdout = stdout; self.stderr = stderr }
    func run(_ command: RemoteCommand, timeout: TimeInterval) -> (status: Int32, stdout: String, stderr: String) { (status, stdout, stderr) }
}
