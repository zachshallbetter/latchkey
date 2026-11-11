import XCTest
@testable import LatchkeyCore

/// Records commands instead of running them; answers list commands with canned output.
final class FakeRunner: RemoteRunner, @unchecked Sendable {
    var ran: [RemoteCommand] = []
    var listOutput = "[]"
    var failNames: Set<String> = []
    func run(_ command: RemoteCommand, timeout: TimeInterval) -> (status: Int32, stdout: String, stderr: String) {
        ran.append(command)
        if command.args.contains("list") || command.args.contains("ls") { return (0, listOutput, "") }
        if let name = command.args.dropFirst(2).first, failNames.contains(name) {
            return (1, "", "Error: could not set \(name) to \(command.stdin ?? "")")
        }
        return (0, "", "")
    }
}

final class RemoteTargetTests: XCTestCase {
    func testCommandsKeepValuesOnStandardInput() {
        let v = RemoteTarget(service: .vercel, project: "acp", environment: "production")
        let c = v.pushCommands([("DB", "s3cret", true)])
        XCTAssertEqual(c.first?.args, ["env", "add", "DB", "--environment", "production", "--force", "--yes", "--sensitive", "--project", "acp"])
        XCTAssertEqual(c.first?.stdin, "s3cret")
        XCTAssertEqual(RemoteTarget(service: .vercel, project: "acp", environment: "development").pushCommands([("A", "x", true)]).first?.args.contains("--no-sensitive"), true)

        let g = RemoteTarget(service: .github, environment: "production", repo: "me/acp").pushCommands([("TOKEN", "t", true)])
        XCTAssertEqual(g.first?.args, ["secret", "set", "TOKEN", "--repo", "me/acp", "--env", "production"])
        let r = RemoteTarget(service: .railway, environment: "production", serviceName: "api", directory: "~/p").pushCommands([("K", "v", true)])
        XCTAssertEqual(r.first?.args, ["variable", "set", "K", "--stdin", "--skip-deploys", "--environment", "production", "--service", "api"])
        XCTAssertEqual(r.first?.directory, "~/p")
        let f = RemoteTarget(service: .fly, app: "acp-api").pushCommands([("A", "1", true), ("B", "2", true)])
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].args, ["secrets", "import", "--stage", "--app", "acp-api"])
        XCTAssertEqual(f[0].stdin, "A=1\nB=2\n")
        for cmd in c + g + r + f { XCTAssertFalse(cmd.args.contains { $0.contains("s3cret") || $0 == "v" || $0 == "t" }) }
    }

    func testValidationProductionAndNames() {
        XCTAssertNotNil(RemoteTarget(service: .vercel, project: "acp", environment: "staging").problem)
        XCTAssertNotNil(RemoteTarget(service: .vercel, environment: "preview").problem, "needs a project or a linked folder")
        XCTAssertNotNil(RemoteTarget(service: .github, repo: "acp").problem)
        XCTAssertNil(RemoteTarget(service: .github, repo: "me/acp").problem)
        XCTAssertTrue(RemoteTarget(service: .vercel, project: "a", environment: "production").isProduction)
        XCTAssertFalse(RemoteTarget(service: .vercel, project: "a", environment: "preview").isProduction)
        XCTAssertTrue(RemoteTarget(service: .fly, app: "acp-api").isProduction)
        XCTAssertFalse(RemoteTarget(service: .fly, app: "acp-api-staging").isProduction)
        XCTAssertEqual(RemoteTarget(service: .vercel, project: "a", environment: "preview").suggestedEnvironment, "vercel.preview")

        XCTAssertEqual(RemoteTarget(service: .railway, environment: "p", serviceName: "s", directory: "d")
            .names(fromListOutput: #"{"B":"value-b","A":"value-a"}"#), ["A", "B"])
        XCTAssertEqual(RemoteTarget(service: .github, repo: "me/acp").names(fromListOutput: #"[{"name":"X"},{"name":"Y"}]"#), ["X", "Y"])
        XCTAssertEqual(RemoteTarget(service: .vercel, project: "a", environment: "preview")
            .names(fromListOutput: #"{"envs":[{"key":"DB","value":"x"},{"key":"API"}]}"#), ["API", "DB"])
        XCTAssertEqual(RemoteTarget(service: .fly, app: "a").names(fromListOutput: #"[{"Name":"F"}]"#), ["F"])
        XCTAssertNil(RemoteTarget(service: .github, repo: "me/acp").names(fromListOutput: "not json"))
    }
}

final class RemoteBrokerTests: XCTestCase {
    let peer = PeerInfo(pid: 1, path: "/usr/local/bin/latchkey", cwd: "/tmp", chain: ["zsh"])

    func make(_ decision: ApprovalDecision = .once, allowsPush: Bool = true) throws -> (Broker, FakeRunner, MemoryStore, CountingDecisions) {
        let store = MemoryStore()
        try store.save(name: "acp/vercel.preview/DB", value: "db-secret", kind: .password, agentSafe: false, note: "")
        try store.save(name: "acp/vercel.preview/HOST", value: "h.example", kind: .value, agentSafe: true, note: "")
        try store.save(name: "acp/development/DB", value: "local", kind: .password, agentSafe: false, note: "")
        let runner = FakeRunner(), approver = CountingDecisions(decision)
        return (Broker(store: store, approver: approver, logURL: nil, remotes: MemoryRemoteStore(), runner: runner, allowsPush: allowsPush),
                runner, store, approver)
    }

    func link(_ b: Broker, _ target: RemoteTarget, scope: String = "acp/vercel.preview") -> RemoteLink? {
        b.handle(Request(op: "link", names: [scope], target: target), peer: peer).links?.first
    }

    func testPushSendsTheEnvironmentOnStdinAndRecordsIt() throws {
        let (b, runner, _, approver) = try make()
        let l = try XCTUnwrap(link(b, RemoteTarget(service: .vercel, project: "acp", environment: "preview")))
        let r = b.handle(Request(op: "push", names: ["acp/vercel.preview"]), peer: peer)
        XCTAssertTrue(r.ok, r.error ?? "")
        let pushes = runner.ran.filter { $0.args.contains("add") }
        XCTAssertEqual(pushes.map { $0.args[2] }.sorted(), ["DB", "HOST"], "only that environment's items, by their names")
        XCTAssertEqual(Set(pushes.compactMap(\.stdin)), ["db-secret", "h.example"])
        XCTAssertFalse(approver.requests.last!.production)
        XCTAssertEqual(approver.requests.last!.targets, ["Vercel acp · preview"])
        let saved = try XCTUnwrap(b.remotes.all().first { $0.id == l.id })
        XCTAssertNotNil(saved.pushed["acp/vercel.preview/DB"])
        XCTAssertEqual(saved.state(of: "acp/vercel.preview/DB", valueChangedAt: nil), .current)
        XCTAssertEqual(saved.state(of: "acp/vercel.preview/DB", valueChangedAt: Date().addingTimeInterval(60)), .outOfDate)
    }

    func testProductionIsFlaggedDenialsSendNothingAndTheBrokerOnlyPushesInTheApp() throws {
        let (b, runner, _, approver) = try make(.deny)
        XCTAssertNotNil(link(CountingDecisions.allow(b), RemoteTarget(service: .fly, app: "acp-api"), scope: "acp/vercel.preview"))
        XCTAssertFalse(b.handle(Request(op: "push", names: ["acp/vercel.preview"]), peer: peer).ok)
        XCTAssertTrue(approver.requests.last!.production)
        XCTAssertTrue(runner.ran.isEmpty)
        XCTAssertEqual(SystemApprover().approve(approver.requests.last!), .deny, "the system sheet never approves production")

        let (headless, r2, _, _) = try make(allowsPush: false)
        _ = link(headless, RemoteTarget(service: .github, repo: "me/acp"))
        XCTAssertFalse(headless.handle(Request(op: "push", names: ["acp/vercel.preview"]), peer: peer).ok)
        XCTAssertTrue(r2.ran.isEmpty)
    }

    func testFailuresAreReportedWithoutValues() throws {
        let (b, runner, _, _) = try make()
        _ = link(b, RemoteTarget(service: .github, repo: "me/acp"))
        runner.failNames = ["DB"]
        let r = b.handle(Request(op: "push", names: ["acp/vercel.preview"]), peer: peer)
        XCTAssertFalse(r.ok)
        let failed = try XCTUnwrap(r.pushResults?.first { !$0.ok })
        XCTAssertEqual(failed.item, "acp/vercel.preview/DB")
        XCTAssertFalse(failed.error!.contains("db-secret"), failed.error!)
        XCTAssertTrue(failed.error!.contains("<value>"))
        XCTAssertEqual(r.pushResults?.filter(\.ok).map(\.item), ["acp/vercel.preview/HOST"])
    }

    func testStatusComparesNamesAndUnlinkNeedsNoApproval() throws {
        let (b, runner, _, _) = try make()
        let l = try XCTUnwrap(link(b, RemoteTarget(service: .github, repo: "me/acp")))
        runner.listOutput = #"[{"name":"HOST"},{"name":"OLD_ONLY_THERE"}]"#
        let s = try XCTUnwrap(b.handle(Request(op: "remote-status", names: ["acp/vercel.preview"]), peer: peer).remoteStatus?.first)
        XCTAssertEqual(s.missing, ["DB"])
        XCTAssertEqual(s.extra, ["OLD_ONLY_THERE"])
        XCTAssertFalse(b.handle(Request(op: "link", names: ["acp/vercel.preview"], target: RemoteTarget(service: .github, repo: "me/acp")), peer: peer).ok, "no duplicate links")
        XCTAssertFalse(b.handle(Request(op: "link", names: ["acp"], target: RemoteTarget(service: .github, repo: "me/acp")), peer: peer).ok)
        let denying = Broker(store: b.store, approver: FixedApprover(false), logURL: nil, remotes: b.remotes, runner: runner)
        XCTAssertTrue(denying.handle(Request(op: "unlink", names: [l.id]), peer: peer).ok)
        XCTAssertEqual(try b.remotes.all().count, 0)
    }
}

/// Answers every approval the same way and keeps the requests.
final class CountingDecisions: Approver, @unchecked Sendable {
    let decision: ApprovalDecision
    var requests: [ApprovalRequest] = []
    init(_ d: ApprovalDecision) { decision = d }
    var method: String { "test" }
    func approve(_ r: ApprovalRequest) -> ApprovalDecision { requests.append(r); return decision }

    /// The same broker's stores with an approver that allows, for setting up links in a test that denies.
    static func allow(_ b: Broker) -> Broker {
        Broker(store: b.store, approver: FixedApprover(true), logURL: nil, remotes: b.remotes, runner: b.runner)
    }
}
