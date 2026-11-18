import XCTest
@testable import LatchkeyCore

/// A request waiting for approval doesn't hold the broker, and its answer counts only for what was shown.
final class ApprovalOutsideLockTests: XCTestCase {
    let peer = PeerInfo(pid: 1, path: "/usr/local/bin/latchkey", cwd: "/tmp/p", chain: ["zsh", "claude"], isLatchkeyTool: true,
                        ancestors: [ProcessStamp(pid: 10, started: 1), ProcessStamp(pid: 11, started: 2)])
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lk-ao-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// Runs the next of `during` before answering: what other requests do while the person decides.
    final class ScriptedApprover: Approver, @unchecked Sendable {
        var requests: [ApprovalRequest] = []
        var during: [() -> Void] = []
        var method: String { "test" }
        var groupsRequests: Bool { true }
        func approve(_ request: ApprovalRequest) -> ApprovalDecision {
            requests.append(request)
            if !during.isEmpty { during.removeFirst()() }
            return .once
        }
    }

    private func secret(_ store: MemoryStore, _ name: String, _ value: String) throws {
        try store.save(name: name, value: value, kind: .token, agentSafe: false, note: "")
    }

    func testOtherRequestsRunWhileAPersonDecides() throws {
        let store = MemoryStore(), approver = ScriptedApprover()
        try secret(store, "A", "a-value-1")
        let b = Broker(store: store, approver: approver, logURL: nil)
        var inner: Response?
        approver.during = [{ inner = b.handle(Request(op: "list"), peer: self.peer) }]
        let r = b.handle(Request(op: "get", names: ["A"]), peer: peer)
        XCTAssertEqual(r.values?["A"], "a-value-1")
        XCTAssertEqual(inner?.ok, true, "the broker wasn't held while the approval waited")
        XCTAssertEqual(approver.requests.count, 1, "one question for one request")
    }

    func testAValueChangedWhileWaitingIsAskedAgain() throws {
        let store = MemoryStore(), approver = ScriptedApprover()
        try secret(store, "A", "a-value-1")
        let b = Broker(store: store, approver: approver, logURL: nil)
        approver.during = [{ try? self.secret(store, "A", "a-value-2") }]
        let r = b.handle(Request(op: "get", names: ["A"]), peer: peer)
        XCTAssertEqual(approver.requests.count, 2, "the first answer was for the value as it was")
        XCTAssertEqual(r.values?["A"], "a-value-2")
    }

    func testAnAnswerCountsOnlyForTheQuestionShown() throws {
        let store = MemoryStore(), approver = ScriptedApprover()
        let b = Broker(store: store, approver: approver, logURL: nil)
        approver.during = [{ try? self.secret(store, "B", "b-value-0") }]
        XCTAssertTrue(b.handle(Request(op: "set", names: ["B"], value: "b-value-1"), peer: peer).ok)
        XCTAssertEqual(approver.requests.map(\.action), [.add, .change], "adding B was approved, not changing it")
        XCTAssertEqual(try store.values(["B"])["B"], "b-value-1")
    }

    func testADenialStillDenies() throws {
        let store = MemoryStore()
        try secret(store, "A", "a-value-1")
        let b = Broker(store: store, approver: GrantsOnlyApprover(), logURL: nil)
        let r = b.handle(Request(op: "get", names: ["A"]), peer: peer)
        XCTAssertNil(r.values?["A"])
        XCTAssertEqual(r.denied, ["A"])
    }

    func testLinesWrittenBeforeTheQuestionAreWrittenOnce() throws {
        let store = MemoryStore(), approver = ScriptedApprover(), grants = GrantStore()
        try secret(store, "A", "a-value-1")
        try secret(store, "B", "b-value-1")
        _ = grants.add(names: ["A"], folder: "/tmp/p", duration: 3600, createdBy: "test")
        let log = root.appendingPathComponent("access.log")
        let b = Broker(store: store, approver: approver, logURL: log, grants: grants)
        let r = b.handle(Request(op: "get", names: ["A", "B"]), peer: peer)
        XCTAssertEqual(r.values?.count, 2)
        let lines = Broker.readLog(limit: 50, from: log).map { "\($0.names) \($0.decision)" }
        XCTAssertEqual(lines.filter { $0.contains("allowed (grant") }.count, 1, lines.joined(separator: "\n"))
        XCTAssertEqual(lines.filter { $0.hasSuffix(" approved") }.count, 1, lines.joined(separator: "\n"))
    }

    /// The system sheet can show one question at a time.
    func testAnApproverThatDoesntGroupIsAskedOneAtATime() throws {
        final class Counting: Approver, @unchecked Sendable {
            let lock = NSLock()
            var now = 0, most = 0
            var method: String { "test" }
            func approve(_ request: ApprovalRequest) -> ApprovalDecision {
                lock.withLock { now += 1; most = max(most, now) }
                Thread.sleep(forTimeInterval: 0.05)
                lock.withLock { now -= 1 }
                return .once
            }
        }
        let store = MemoryStore(), approver = Counting()
        for n in ["A", "B", "C", "D"] { try secret(store, n, "\(n.lowercased())-value-1") }
        let b = Broker(store: store, approver: approver, logURL: nil)
        DispatchQueue.concurrentPerform(iterations: 4) { i in
            _ = b.handle(Request(op: "get", names: [["A", "B", "C", "D"][i]]), peer: peer)
        }
        XCTAssertEqual(approver.most, 1)
    }

    func testTheCallerIsTheProcessTreeAndNoneOverSSH() throws {
        let store = MemoryStore(), approver = ScriptedApprover()
        try secret(store, "A", "a-value-1")
        let b = Broker(store: store, approver: approver, logURL: nil)
        _ = b.handle(Request(op: "get", names: ["A"]), peer: peer)
        var ssh = peer
        ssh.path = "/usr/bin/ssh"
        _ = b.handle(Request(op: "get", names: ["A"]), peer: ssh)
        XCTAssertEqual(approver.requests.map(\.caller), ["10@1.0 11@2.0", ""])
    }

    func testAReleaseApprovedForMoreItemsCoversFewer() {
        var approved = ApprovalRequest(action: .read, names: ["A", "B"], chain: ["zsh"], folder: "/tmp/p", reason: "release A and B")
        approved.caller = "10@1.0"
        var asked = approved
        asked.names = ["B"]
        asked.reason = "release B"
        XCTAssertTrue(Broker.covers(approved, asked))
        XCTAssertFalse(Broker.covers(asked, approved), "an answer for B isn't one for A and B")
        var elsewhere = asked
        elsewhere.folder = "/tmp/q"
        XCTAssertFalse(Broker.covers(approved, elsewhere))
        var change = approved
        change.action = .change
        var fewer = change
        fewer.names = ["B"]
        XCTAssertFalse(Broker.covers(change, fewer), "only releases narrow; a change must be the same question")
    }
}
