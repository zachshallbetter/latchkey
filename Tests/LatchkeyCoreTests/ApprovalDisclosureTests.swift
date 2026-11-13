import XCTest
@testable import LatchkeyCore

/// Approvals name every change to who may read an item without asking, and to whether it's treated as a secret; a
/// restore changes only the value of an item that still exists; Safari never fills on a customer's own subdomain.
final class ApprovalDisclosureTests: XCTestCase {
    let peer = PeerInfo(pid: 1, path: "/usr/local/bin/latchkey", cwd: "/tmp/project", chain: ["zsh"])

    func testSetNamesAnAgentSafeOrKindChange() throws {
        let store = MemoryStore()
        try store.save(name: "acp/development/KEY", value: "one", kind: .token, agentSafe: false, note: "")
        let approver = CountingApprover(true)
        let b = Broker(store: store, approver: approver, logURL: nil)

        XCTAssertTrue(b.handle(Request(op: "set", names: ["acp/development/KEY"], agentSafe: true), peer: peer).ok)
        XCTAssertTrue(approver.reasons[0].hasPrefix("change the settings of acp/development/KEY and let agents read it without approval"),
                      approver.reasons[0])
        XCTAssertEqual(try store.info("acp/development/KEY")?.agentSafe, true)
        XCTAssertEqual(try store.values(["acp/development/KEY"]), ["acp/development/KEY": "one"], "the value is untouched")

        XCTAssertTrue(b.handle(Request(op: "set", names: ["acp/development/KEY"], value: "two", kind: .value), peer: peer).ok)
        XCTAssertTrue(approver.reasons[1].contains("make it a plain value"), approver.reasons[1])

        XCTAssertTrue(b.handle(Request(op: "set", names: ["acp/development/KEY"], value: "three", agentSafe: true), peer: peer).ok)
        XCTAssertTrue(approver.reasons[2].hasPrefix("change acp/development/KEY, asked by"), "no change named when nothing changes: \(approver.reasons[2])")

        XCTAssertTrue(b.handle(Request(op: "set", names: ["acp/development/NEW"], value: "v", agentSafe: true), peer: peer).ok)
        XCTAssertTrue(approver.reasons[3].hasPrefix("add acp/development/NEW and let agents read it without approval"), approver.reasons[3])
    }

    func testImportNamesItemsThatBecomeAgentReadableOrPlain() throws {
        let store = MemoryStore()
        try store.save(name: "acp/development/A", value: "old", kind: .token, agentSafe: false, note: "")
        let approver = CountingApprover(true)
        let b = Broker(store: store, approver: approver, logURL: nil)
        let items = [ImportItem(name: "acp/development/A", value: "new", kind: .token, agentSafe: true, note: nil),
                     ImportItem(name: "acp/development/B", value: "b-value", kind: .value, agentSafe: false, note: nil)]
        XCTAssertTrue(b.handle(Request(op: "import", items: items, replace: true), peer: peer).ok)
        XCTAssertTrue(approver.reasons[0].contains("let agents read A from acp/development without approval"), approver.reasons[0])
        XCTAssertTrue(approver.reasons[0].contains("save B from acp/development as plain values"), approver.reasons[0])
    }

    func testRestoreOfAnExistingItemChangesOnlyItsValue() throws {
        let store = MemoryStore(), versions = MemoryVersionStore()
        try store.save(name: "acp/development/KEY", value: "one", kind: .token, agentSafe: true, note: "", usedIn: nil,
                       service: "Stripe", fillSites: ["dashboard.stripe.com"])
        let approver = CountingApprover(true)
        let b = Broker(store: store, approver: approver, logURL: nil, versions: versions)
        _ = b.handle(Request(op: "set", names: ["acp/development/KEY"], value: "two"), peer: peer)
        _ = b.handle(Request(op: "update", names: ["acp/development/KEY"], agentSafe: false, fillSites: ["stripe.com"]), peer: peer)
        let first = try XCTUnwrap(b.handle(Request(op: "history", names: ["acp/development/KEY"]), peer: peer).versions?.first)

        XCTAssertTrue(b.handle(Request(op: "restore", version: first.id), peer: peer).ok)
        let info = try XCTUnwrap(store.info("acp/development/KEY"))
        XCTAssertEqual(try store.values(["acp/development/KEY"]), ["acp/development/KEY": "one"])
        XCTAssertFalse(info.agentSafe, "the later tightening stays")
        XCTAssertEqual(info.fillSites, ["stripe.com"])
        XCTAssertTrue(approver.reasons.last!.hasPrefix("restore acp/development/KEY to its value from"))
    }

    func testBringingBackADeletedAgentSafeItemSaysSo() throws {
        let store = MemoryStore(), versions = MemoryVersionStore()
        try store.save(name: "acp/development/KEY", value: "one", kind: .token, agentSafe: true, note: "")
        let approver = CountingApprover(true)
        let b = Broker(store: store, approver: approver, logURL: nil, versions: versions)
        _ = b.handle(Request(op: "rm", names: ["acp/development/KEY"]), peer: peer)
        let gone = try XCTUnwrap(b.handle(Request(op: "deleted"), peer: peer).versions?.first)
        XCTAssertTrue(b.handle(Request(op: "restore", version: gone.id), peer: peer).ok)
        XCTAssertTrue(approver.reasons.last!.contains("and let agents read it without approval"), approver.reasons.last!)
        XCTAssertEqual(try store.info("acp/development/KEY")?.agentSafe, true)
    }

    func testSummaryIsTheReasonWithoutTheAsker() {
        let r = ApprovalRequest(action: .change, names: ["X"], chain: [], folder: "",
                                reason: "change the settings of X and let agents read it without approval, asked by zsh")
        XCTAssertEqual(r.summary, "change the settings of X and let agents read it without approval")
    }

    func testSafariNeverFillsOnACustomersOwnSubdomain() {
        for host in ["x.up.railway.app", "railway.app", "myapp.netlify.app", "myapp.vercel.app", "myapp.onrender.com",
                     "myapp.fly.dev", "myapp.herokuapp.com", "abc.supabase.co"] {
            XCTAssertFalse(Services.mayFill(origin: "https://\(host)", service: nil), host)
        }
        XCTAssertFalse(Services.mayFill(origin: "https://sites.google.com", service: "Google"), "Google's own key page host, not all of google.com")
        XCTAssertFalse(Services.mayFill(origin: "https://www.amazon.com", service: "AWS"))
        XCTAssertTrue(Services.mayFill(origin: "https://console.cloud.google.com", service: "Google"))
        XCTAssertTrue(Services.mayFill(origin: "https://railway.com", service: nil))
        XCTAssertTrue(Services.mayFill(origin: "https://app.netlify.com", service: nil))
        XCTAssertTrue(Services.mayFill(origin: "https://dashboard.render.com", service: nil))
        XCTAssertTrue(Services.mayFill(origin: "https://dashboard.heroku.com", service: nil))
    }
}
