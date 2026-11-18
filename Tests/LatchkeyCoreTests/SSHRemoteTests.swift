import XCTest
@testable import LatchkeyCore

/// Pushing to a credential script on a Linux host over ssh: nothing a caller or a synced link supplies reaches the
/// remote shell as anything but a literal word, and values travel on standard input only.
final class SSHRemoteTests: XCTestCase {
    let peer = PeerInfo(pid: 1, path: "/usr/local/bin/latchkey", cwd: "/tmp", chain: ["zsh"])
    static let script = "/ai/projects/distribution-mcp/current/deploy/titan/add-credential.sh"
    let titan = RemoteTarget(service: .ssh, host: "titan", script: SSHRemoteTests.script)

    /// Answers like the credential script, and records what it was given.
    final class ScriptRunner: RemoteRunner, @unchecked Sendable {
        var ran: [RemoteCommand] = []
        var reply: ((RemoteCommand) -> (Int32, String, String))?
        func run(_ command: RemoteCommand, timeout: TimeInterval) -> (status: Int32, stdout: String, stderr: String) {
            ran.append(command)
            if let reply { return reply(command) }
            let n = command.args.count
            return (0, "stored \(command.args[n - 3]).\(command.args[n - 2]); the worker restarted with it\n", "")
        }
    }

    private func broker(_ runner: ScriptRunner, _ items: [String: String], approver: Approver = RecordingApprover()) throws -> Broker {
        let store = MemoryStore()
        for (name, value) in items { try store.save(name: name, value: value, kind: .token, agentSafe: false, note: "") }
        return Broker(store: store, approver: approver, logURL: nil, remotes: MemoryRemoteStore(), runner: runner,
                      records: MemoryEnvironmentStore())
    }

    func testCredentialNamesSplitAtTheFirstDot() {
        XCTAssertEqual(RemoteTarget.credential("bluesky.zshallbetter.bsky.social")?.adapter, "bluesky")
        XCTAssertEqual(RemoteTarget.credential("bluesky.zshallbetter.bsky.social")?.account, "zshallbetter.bsky.social")
        XCTAssertEqual(RemoteTarget.credential("hugging-face.me_2")?.adapter, "hugging-face")
        for bad in ["bluesky", ".account", "bluesky.", "-x.account", "bluesky.-account", "blue.sky;rm", "x.$(id)", "x.a b",
                    "x.a`b`", "x.a'b", "x.é", "a_b.c\nd", "a/b.c", String(repeating: "a", count: 130) + ".b"] {
            XCTAssertNil(RemoteTarget.credential(bad), bad)
        }
    }

    func testHostAndScriptHoldOnlyLiteralCharacters() {
        XCTAssertNil(titan.problem)
        for host in ["-oProxyCommand=x", "titan;id", "ti tan", "", "user@titan", "titan:22", "$(id)"] {
            XCTAssertNotNil(RemoteTarget(service: .ssh, host: host, script: Self.script).problem, host)
        }
        for script in ["add.sh", "/a/../b.sh", "/a/./b.sh", "/a//b.sh", "/a b.sh", "/a;b.sh", "/a$(id).sh", "/a/b.sh\n"] {
            XCTAssertNotNil(RemoteTarget(service: .ssh, host: "titan", script: script).problem, script)
        }
        XCTAssertNotNil(RemoteTarget(service: .ssh, tokenItem: "x/y/T", host: "titan", script: Self.script).problem, "no token route")
        XCTAssertNotNil(RemoteTarget(service: .ssh, project: "p", host: "titan", script: Self.script).problem, "only a host and a script")
        XCTAssertNotNil(RemoteTarget(service: .fly, app: "a", host: "titan").problem, "a host is only for SSH")
        XCTAssertTrue(titan.isProduction, "the script restarts the service that reads it")
        XCTAssertTrue(titan.approvalLabel.contains("SSH titan") && titan.approvalLabel.contains(Self.script), titan.approvalLabel)
    }

    func testTheCommandCarriesNamesAsWordsAndTheValueOnStandardInput() {
        let c = titan.pushCommands([(name: "bluesky.zshallbetter.bsky.social", value: "app-pass-1234", secret: true)])
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].tool, "ssh")
        XCTAssertEqual(c[0].args, ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", "titan",
                                   "sudo", "-n", "bash", Self.script, "bluesky", "zshallbetter.bsky.social", "--stdin"])
        XCTAssertEqual(c[0].stdin, "app-pass-1234\n", "the script strips one newline, so the value arrives exactly")
        XCTAssertFalse(c[0].args.contains { $0.contains("app-pass") })
    }

    func testAPushStoresEachCredentialAndRecordsIt() throws {
        let runner = ScriptRunner()
        let b = try broker(runner, ["distribution/production/bluesky.me.bsky.social": "bsky-value-1",
                                    "distribution/production/devto.me": "devto-value-1"])
        try b.remotes.save(RemoteLink(scope: "distribution/production", target: titan))
        let r = b.handle(Request(op: "push", names: ["distribution/production"]), peer: peer)
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertEqual(runner.ran.count, 2)
        XCTAssertEqual(Set(runner.ran.map { $0.stdin ?? "" }), ["bsky-value-1\n", "devto-value-1\n"])
        let link = try XCTUnwrap(b.remotes.all().first)
        XCTAssertNotNil(link.pushed["distribution/production/devto.me"])
        let s = try XCTUnwrap(b.handle(Request(op: "remote-status", names: ["distribution/production"]), peer: peer).remoteStatus?.first)
        XCTAssertNil(s.error)
        XCTAssertEqual(s.missing, [], "status reports from Latchkey's own push record")
        XCTAssertEqual(runner.ran.count, 2, "status runs nothing on the host")
    }

    func testAnUnconfirmedOrFailedPushIsAFailure() throws {
        let runner = ScriptRunner()
        runner.reply = { _ in (0, "something else\n", "") }
        let b = try broker(runner, ["distribution/production/x.me": "x-value-1"])
        try b.remotes.save(RemoteLink(scope: "distribution/production", target: titan))
        var r = b.handle(Request(op: "push", names: ["distribution/production"]), peer: peer)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.pushResults?.first?.error?.contains("didn't confirm") == true, r.pushResults?.first?.error ?? "")
        runner.reply = { c in (1, "", "sudo: a password is required for \(c.stdin ?? "")") }
        r = b.handle(Request(op: "push", names: ["distribution/production"]), peer: peer)
        XCTAssertFalse(r.ok)
        XCTAssertFalse(r.pushResults?.first?.error?.contains("x-value-1") ?? true, "a value echoed back is redacted")
        XCTAssertNil(try b.remotes.all().first?.pushed["distribution/production/x.me"])
    }

    func testANameThatIsntACredentialStopsThePushBeforeAnythingRuns() throws {
        let runner = ScriptRunner()
        let b = try broker(runner, ["distribution/production/x.me": "x-value-1", "distribution/production/PLAIN": "plain-value"])
        try b.remotes.save(RemoteLink(scope: "distribution/production", target: titan))
        let r = b.handle(Request(op: "push", names: ["distribution/production"]), peer: peer)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.error?.contains("ADAPTER.ACCOUNT") == true, r.error ?? "")
        XCTAssertTrue(runner.ran.isEmpty)
    }

    func testAValueTooLongForTheScriptIsntSent() throws {
        let runner = ScriptRunner()
        let b = try broker(runner, ["distribution/production/x.me": String(repeating: "v", count: RemoteTarget.sshValueLimit)])
        try b.remotes.save(RemoteLink(scope: "distribution/production", target: titan))
        let r = b.handle(Request(op: "push", names: ["distribution/production"]), peer: peer)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(runner.ran.isEmpty)
    }

    func testATamperedSyncedLinkIsCheckedAgainBeforeItsUsed() throws {
        let runner = ScriptRunner()
        let b = try broker(runner, ["distribution/production/x.me": "x-value-1"])
        try b.remotes.save(RemoteLink(scope: "distribution/production",
                                      target: RemoteTarget(service: .ssh, host: "titan", script: "/tmp/x.sh; curl evil")))
        let r = b.handle(Request(op: "push", names: ["distribution/production"]), peer: peer)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(runner.ran.isEmpty, "the link is refused before anyone is asked")
    }

    func testThePushApprovalNamesTheHostAndScriptAsProduction() throws {
        let runner = ScriptRunner(), approver = RecordingApprover()
        let b = try broker(runner, ["distribution/production/x.me": "x-value-1"], approver: approver)
        try b.remotes.save(RemoteLink(scope: "distribution/production", target: titan))
        _ = b.handle(Request(op: "push", names: ["distribution/production"]), peer: peer)
        let ask = try XCTUnwrap(approver.requests.first)
        XCTAssertTrue(ask.production)
        XCTAssertTrue(ask.targets.joined().contains(Self.script), ask.targets.joined())
    }

    func testTheAppStoreBuildCantLinkOverSSH() throws {
        let b = Broker(store: MemoryStore(), approver: RecordingApprover(), logURL: nil, remotes: MemoryRemoteStore(),
                       runner: UnavailableRunner(), nativeOnly: true)
        XCTAssertFalse(b.handle(Request(op: "link", names: ["distribution/production"], target: titan), peer: peer).ok)
    }
}
