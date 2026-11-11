import XCTest
@testable import LatchkeyCore

final class BrokerTests: XCTestCase {
    let peer = PeerInfo(pid: 1, path: "/usr/local/bin/latchkey", cwd: "/tmp/project", chain: ["zsh", "claude"])

    func makeBroker(approve: Bool) throws -> (Broker, MemoryStore) {
        let store = MemoryStore()
        try store.save(name: "SAFE_TOKEN", value: "safe-value-123", kind: .token, agentSafe: true, note: "")
        try store.save(name: "DB_PASS", value: "db-password-456", kind: .password, agentSafe: false, note: "")
        try store.save(name: "HOST", value: "10.0.0.1", kind: .value, agentSafe: true, note: "")
        return (Broker(store: store, approver: FixedApprover(approve), logURL: nil), store)
    }

    func testAgentSafeReleasedWithoutApproval() throws {
        let (b, _) = try makeBroker(approve: false)
        let r = b.handle(Request(op: "get", names: ["SAFE_TOKEN", "HOST", "NOPE"]), peer: peer)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.values, ["SAFE_TOKEN": "safe-value-123", "HOST": "10.0.0.1"])
        XCTAssertEqual(r.masked, ["SAFE_TOKEN"])
        XCTAssertEqual(r.missing, ["NOPE"])
        XCTAssertNil(r.denied)
    }

    func testOtherItemsNeedApproval() throws {
        let (deny, _) = try makeBroker(approve: false)
        let r = deny.handle(Request(op: "get", names: ["DB_PASS", "SAFE_TOKEN"]), peer: peer)
        XCTAssertEqual(r.denied, ["DB_PASS"])
        XCTAssertEqual(r.values, [:])

        let (allow, _) = try makeBroker(approve: true)
        let r2 = allow.handle(Request(op: "get", names: ["DB_PASS"]), peer: peer)
        XCTAssertEqual(r2.values, ["DB_PASS": "db-password-456"])
    }

    func testChangesNeedApprovalAndKeepMetadata() throws {
        let (deny, store) = try makeBroker(approve: false)
        XCTAssertFalse(deny.handle(Request(op: "set", names: ["DB_PASS"], value: "x"), peer: peer).ok)
        XCTAssertFalse(deny.handle(Request(op: "rm", names: ["DB_PASS"]), peer: peer).ok)
        XCTAssertEqual(try store.values(["DB_PASS"]), ["DB_PASS": "db-password-456"])

        let (allow, store2) = try makeBroker(approve: true)
        XCTAssertTrue(allow.handle(Request(op: "set", names: ["DB_PASS"], value: "new-password-789"), peer: peer).ok)
        let info = try store2.info("DB_PASS")
        XCTAssertEqual(info?.kind, .password)
        XCTAssertEqual(info?.agentSafe, false)
        XCTAssertTrue(allow.handle(Request(op: "rm", names: ["DB_PASS"]), peer: peer).ok)
        XCTAssertNil(try store2.info("DB_PASS"))
        XCTAssertEqual(allow.handle(Request(op: "rm", names: ["DB_PASS"]), peer: peer).missing, ["DB_PASS"])
    }

    func testTheTouchIDLineSaysWhatWhoAndWhere() {
        var r = ApprovalRequest(action: .add, names: ["shop/development/DB"], chain: ["zsh", "claude", "disclaimer", "Claude"],
                                folder: NSHomeDirectory() + "/Projects/shop",
                                reason: "add shop/development/DB, asked by zsh › claude in ~/Projects/shop (running latchkey set shop/development/DB)")
        XCTAssertEqual(r.asker, "Claude", "the nearest program that isn't a shell")
        r.sessionName = "codex"
        XCTAssertEqual(r.touchIDReason, "add shop/development/DB, asked by Codex in ~/Projects/shop")
        var read = ApprovalRequest(action: .read, names: ["A", "B"], chain: ["zsh", "claude"], folder: "/tmp/x", reason: "release A and B, asked by zsh")
        XCTAssertEqual(read.touchIDReason, "give A and B to Claude in /tmp/x")
        read.fromApp = true
        XCTAssertEqual(read.touchIDReason, "release A and B", "the window asking for itself names no one")
        let fill = ApprovalRequest(action: .read, names: ["A"], chain: [], folder: "", reason: "fill A into a field on vercel.com")
        XCTAssertEqual(fill.touchIDReason, "fill A into a field on vercel.com")
    }

    func testOnlyChangesWithoutWarningsGoStraightToTheSheet() {
        func req(_ a: ApprovalRequest.Action) -> ApprovalRequest { ApprovalRequest(action: a, names: ["A"], chain: ["zsh"], folder: "/tmp", reason: "r") }
        for a in [ApprovalRequest.Action.add, .change, .delete, .importItems, .move, .restore, .link] { XCTAssertTrue(req(a).sheetFirst, "\(a)") }
        for a in [ApprovalRequest.Action.read, .readVersion, .grant, .push] { XCTAssertFalse(req(a).sheetFirst, "\(a)") }
        var foreign = req(.delete); foreign.program = "/tmp/evil"
        XCTAssertFalse(foreign.sheetFirst, "a program that isn't Latchkey's tool: its warning comes first")
        var ssh = req(.add); ssh.overSSH = true
        XCTAssertFalse(ssh.sheetFirst)
    }

    func testOnlyAReleaseOffersAGrant() throws {
        let approver = RecordingApprover()
        let store = MemoryStore()
        try store.save(name: "A", value: "a", kind: .token, agentSafe: false, note: "")
        let b = Broker(store: store, approver: approver, logURL: nil)
        _ = b.handle(Request(op: "get", names: ["A"]), peer: peer)
        _ = b.handle(Request(op: "export", names: ["A"], destination: "/tmp/project/.env"), peer: peer)
        XCTAssertEqual(approver.requests.map(\.canGrant), [true, false], "an export asks like a read but can't become a grant")
    }

    func testDescribeUsesTheKernelsViewNotTheRequest() {
        let caller = PeerInfo(pid: 7, path: "/Users/x/.local/bin/latchkey", cwd: NSHomeDirectory() + "/site", chain: ["zsh", "claude"],
                              arguments: ["/Users/x/.local/bin/latchkey", "run", "--", "npm", "test"])
        let s = Broker.describe(caller, Request(op: "get"))
        XCTAssertEqual(s, "zsh › claude in ~/site (running latchkey run -- npm test)")
        XCTAssertEqual(PeerInfo(pid: 1, path: "", cwd: "", chain: [], arguments: ["sh", "-c", "echo $HOME"]).commandLine, "sh -c 'echo $HOME'")
    }

    func testLogIsChainedAndEditsShow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryLogKeyStore()
        let store = MemoryStore()
        try store.save(name: "A", value: "a-value-123", kind: .token, agentSafe: true, note: "")
        let b = Broker(store: store, approver: FixedApprover(true), logURL: url, logKeys: keys)
        for _ in 0..<3 { _ = b.handle(Request(op: "get", names: ["A"]), peer: peer) }
        XCTAssertEqual(LogChain.verify(url, keys: keys), .intact(signed: 3, unsigned: 0))
        XCTAssertEqual(b.handle(Request(op: "verify-log"), peer: peer).info?["result"], "intact")

        let original = try String(contentsOf: url, encoding: .utf8)
        var lines = original.split(separator: "\n").map(String.init)
        // Changing an entry
        try (lines.enumerated().map { $0.offset == 1 ? $0.element.replacingOccurrences(of: "allowed", with: "denied") : $0.element }.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        guard case .broken(2, _) = LogChain.verify(url, keys: keys) else { return XCTFail("an edited entry should show") }
        // Removing one from the middle
        try ([lines[0], lines[2]].joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        guard case .broken(2, _) = LogChain.verify(url, keys: keys) else { return XCTFail("a missing entry should show") }
        // Removing the last
        lines.removeLast()
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        guard case .broken = LogChain.verify(url, keys: keys) else { return XCTFail("a truncated log should show") }
    }

    func testCommandLinesLoseLikelySecrets() {
        XCTAssertEqual(Redact.arguments(["curl", "-H", "Authorization: Bearer abc", "https://api.example.com/x"]),
                       ["curl", "-H", Redact.mask, "https://api.example.com/x"])
        XCTAssertEqual(Redact.arguments(["deploy", "--token", "hunter2", "--env", "prod"]), ["deploy", "--token", Redact.mask, "--env", "prod"])
        XCTAssertEqual(Redact.arguments(["--api-key=xyz", "API_TOKEN=abc", "PORT=3000"]), ["--api-key=" + Redact.mask, "API_TOKEN=" + Redact.mask, "PORT=3000"])
        XCTAssertEqual(Redact.arguments(["sk_live_51HxAbCdEfGh"]), [Redact.mask])
        XCTAssertEqual(Redact.arguments(["npm", "test", "--", "--watch=false", "./src/app/page.tsx"]), ["npm", "test", "--", "--watch=false", "./src/app/page.tsx"])
        let p = PeerInfo(pid: 1, path: "", cwd: "", chain: [], arguments: ["/bin/lk", "run", "--", "psql", "--password", "s3cret"])
        XCTAssertEqual(p.redactedCommandLine, "lk run -- psql --password '<redacted>'".replacingOccurrences(of: "'", with: ""))
    }

    /// Writes to the real login keychain, so it runs only when asked: LATCHKEY_KEYCHAIN_TESTS=1 swift test
    func testKeychainRoundTrip() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LATCHKEY_KEYCHAIN_TESTS"] == "1")
        let store = KeychainStore(mode: .thisMac)
        let name = "latchkey-test-\(UUID().uuidString.prefix(8))"
        defer { _ = try? store.remove(name) }
        try store.save(name: name, value: "round-trip-value", kind: .key, agentSafe: true, note: "test item")
        XCTAssertEqual(try store.values([name]), [name: "round-trip-value"])
        try store.save(name: name, value: nil, kind: nil, agentSafe: false, note: nil)
        let info = try XCTUnwrap(store.info(name))
        XCTAssertEqual(info.kind, .key)
        XCTAssertFalse(info.agentSafe)
        XCTAssertEqual(info.note, "test item")
        XCTAssertEqual(try store.values([name]), [name: "round-trip-value"])
        XCTAssertTrue(try store.remove(name))
        XCTAssertFalse(try store.remove(name))
    }
}
