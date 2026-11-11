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
        let backing = MemoryGrantBacking()
        let store = GrantStore(backing: backing)
        let g = store.add(names: ["A"], folder: "/tmp/p", duration: 30 * 86400, createdBy: "t", now: now)
        XCTAssertEqual(g.expires, now.addingTimeInterval(GrantStore.longest))
        store.add(names: ["B"], folder: "/tmp/q", duration: 60, createdBy: "t", now: now)
        let reloaded = GrantStore(backing: backing)
        XCTAssertEqual(reloaded.all(now: now).count, 2)
        XCTAssertEqual(reloaded.all(now: now.addingTimeInterval(120)).map(\.id), [g.id], "expired grants drop out")
        XCTAssertNotNil(reloaded.covering("A", cwd: "/tmp/p/sub", now: now))
        XCTAssertEqual(reloaded.revoke(g.id), 1)
        XCTAssertEqual(reloaded.revoke("nope"), 0)
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
        return Broker(store: store, approver: FixedApprover(decision), logURL: nil)
    }

    func testApprovalCanCreateAGrantThatLaterReadsUse() throws {
        let b = try broker(.grant(GrantChoice(duration: 3600)))
        let r = b.handle(Request(op: "get", names: ["DB"]), peer: peer)
        XCTAssertEqual(r.values, ["DB": "db-value-123"])
        XCTAssertEqual(b.grants.all().count, 1)
        XCTAssertEqual(b.grants.all().first?.folder, "/tmp/site")
        XCTAssertEqual(b.grants.all().first?.createdBy, "zsh › claude")

        // Same folder or below: allowed by the grant even though the approver now says no.
        let denyAll = Broker(store: b.store, approver: FixedApprover(false), logURL: nil, grants: b.grants)
        XCTAssertEqual(denyAll.handle(Request(op: "get", names: ["DB"]), peer: at("/tmp/site/sub")).values, ["DB": "db-value-123"])
        // Elsewhere, or another item: asks, and is denied.
        XCTAssertEqual(denyAll.handle(Request(op: "get", names: ["DB"]), peer: at("/tmp/other")).denied, ["DB"])
        XCTAssertEqual(denyAll.handle(Request(op: "get", names: ["DB", "API"]), peer: peer).denied, ["API"])
        // A folder the request claims counts for nothing: only where the caller really runs.
        XCTAssertEqual(denyAll.handle(Request(op: "get", names: ["DB"]), peer: at("/tmp/other")).denied, ["DB"])
        XCTAssertEqual(denyAll.handle(Request(op: "check", names: ["DB"]), peer: at("/tmp/other")).needsApproval, ["DB"])
    }

    func at(_ cwd: String) -> PeerInfo { PeerInfo(pid: 1, path: peer.path, cwd: cwd, chain: peer.chain) }

    /// This test process stands in for a running agent: a session grant needs a live process to tie to.
    var me: ProcessStamp { ProcessStamp(pid: getpid(), started: PeerInfo.started(getpid())!) }
    var agentPeer: PeerInfo { PeerInfo(pid: 1, path: peer.path, cwd: "/tmp/site", chain: ["zsh", "claude"], ancestors: [ProcessStamp(pid: 2, started: 1), me]) }

    func tool(_ args: [String], cwd: String = "/tmp/site", ancestors: [ProcessStamp] = []) -> PeerInfo {
        PeerInfo(pid: 1, path: "/Users/x/.local/bin/latchkey", cwd: cwd, chain: ["zsh", "claude"], arguments: args,
                 isLatchkeyTool: true, ancestors: ancestors)
    }

    func testRunCommandIsReadOnlyFromTheSignedTool() {
        XCTAssertEqual(tool(["lk", "run", "--env", "shop/development", "--no-masking", "--", "npm", "test"]).runCommand, ["npm", "test"])
        XCTAssertEqual(tool(["latchkey", "run", "--env-file", ".env", "npm", "run", "dev"]).runCommand, ["npm", "run", "dev"])
        XCTAssertNil(tool(["latchkey", "get", "X"]).runCommand)
        var other = tool(["latchkey", "run", "--", "npm", "test"])
        other.isLatchkeyTool = false
        XCTAssertNil(other.runCommand, "another program's command line can't be trusted")
        XCTAssertEqual(agentPeer.sessionProcess?.name, "claude")
        XCTAssertNil(PeerInfo(pid: 1, path: "", cwd: "", chain: ["zsh", "lk"], ancestors: [me, me]).sessionProcess)
    }

    func testSessionCommandAndOnceLimits() throws {
        // Grants are approved; reads never are, so anything released came from a grant.
        let store = MemoryStore()
        try store.save(name: "DB", value: "db-value-123", kind: .password, agentSafe: false, note: "")
        try store.save(name: "API", value: "api-value-456", kind: .token, agentSafe: false, note: "")
        let b = Broker(store: store, approver: GrantsOnlyApprover(), logURL: nil)
        // Until the agent quits: covers programs under it, not elsewhere.
        let session = b.handle(Request(op: "grant", names: ["DB"], folder: "/tmp/site", session: true), peer: agentPeer)
        XCTAssertTrue(session.ok, session.error ?? "")
        XCTAssertEqual(session.grants?.first?.session?.name, "claude")
        XCTAssertEqual(b.handle(Request(op: "get", names: ["DB"]), peer: tool(["lk", "run", "--", "x"], ancestors: [me])).values, ["DB": "db-value-123"])
        XCTAssertEqual(b.handle(Request(op: "get", names: ["DB"]), peer: tool(["lk", "run", "--", "x"])).denied, ["DB"], "not under the agent")
        // A session that has ended covers nothing, and the grant drops out.
        let gone = Grant(names: ["API"], folder: "/tmp/site", expires: Date().addingTimeInterval(3600), createdBy: "t",
                         session: GrantSession(process: ProcessStamp(pid: getpid(), started: 1), name: "old"))
        XCTAssertFalse(gone.allows("API", cwd: "/tmp/site", ancestors: [ProcessStamp(pid: getpid(), started: 1)], command: nil))
        _ = b.handle(Request(op: "revoke", names: ["all"]), peer: peer)

        // One command: only a signed `latchkey run` of it.
        XCTAssertTrue(b.handle(Request(op: "grant", names: ["API"], folder: "/tmp/site", commands: [["npm", "test"]]), peer: peer).ok)
        XCTAssertEqual(b.handle(Request(op: "get", names: ["API"]), peer: tool(["lk", "run", "--", "npm", "test", "--ci"])).values, ["API": "api-value-456"])
        XCTAssertEqual(b.handle(Request(op: "get", names: ["API"]), peer: tool(["lk", "run", "--", "npm", "run", "dev"])).denied, ["API"])
        XCTAssertEqual(b.handle(Request(op: "get", names: ["API"]), peer: tool(["lk", "get", "API"])).denied, ["API"])
        XCTAssertEqual(b.handle(Request(op: "check", names: ["API"], intended: ["npm", "test"]), peer: peer).granted, ["API"])
        _ = b.handle(Request(op: "revoke", names: ["all"]), peer: peer)

        // Once: one request, then it's gone.
        XCTAssertTrue(b.handle(Request(op: "grant", names: ["DB", "API"], folder: "/tmp/site", uses: 1), peer: peer).ok)
        XCTAssertEqual(b.handle(Request(op: "get", names: ["DB", "API"]), peer: peer).values?.count, 2)
        XCTAssertEqual(b.handle(Request(op: "get", names: ["DB"]), peer: peer).denied, ["DB"])
        XCTAssertTrue(b.grants.all().isEmpty)
    }

    func testNoGrantForTheWholeDisk() throws {
        let b = try broker(.grant(GrantChoice(duration: 3600)))
        let atRoot = PeerInfo(pid: 1, path: "/usr/libexec/somejob", cwd: "/", chain: ["launchd"])
        XCTAssertEqual(b.handle(Request(op: "get", names: ["DB"]), peer: atRoot).values, ["DB": "db-value-123"])
        XCTAssertTrue(b.grants.all().isEmpty, "approving from / must not grant every folder")
        XCTAssertFalse(ApprovalRequest(action: .read, names: ["A"], chain: [], folder: "/", reason: "x").canGrant)
    }

    func testOverSSHEveryRequestAsks() throws {
        let ssh = PeerInfo(pid: 1, path: "/usr/bin/ssh", cwd: "/tmp/site", chain: ["zsh", "Terminal"],
                           arguments: ["ssh", "-R", "/tmp/lk.sock:/x/broker.sock", "devmac"])
        let recorder = RecordingApprover()
        let store = MemoryStore()
        try store.save(name: "DB", value: "db-value-123", kind: .password, agentSafe: false, note: "")
        let b = Broker(store: store, approver: recorder, logURL: nil)
        // A grant on the ssh client's folder must not cover requests from the other computer.
        b.grants.add(names: ["DB"], folder: "/tmp/site", duration: 3600, createdBy: "t")
        let claim = RemoteClaim(host: "devmac", cwd: "/Users/x/shop", command: "run -- npm test")
        _ = b.handle(Request(op: "get", names: ["DB"], remote: claim), peer: ssh)
        _ = b.handle(Request(op: "get", names: ["DB"], remote: claim), peer: ssh)
        XCTAssertEqual(recorder.requests.count, 2, "no grant or recent approval stands in over SSH")
        let r = try XCTUnwrap(recorder.requests.first)
        XCTAssertTrue(r.overSSH)
        XCTAssertEqual(r.remote, claim)
        XCTAssertFalse(r.canGrant)
        XCTAssertNil(r.program)
        XCTAssertFalse(b.handle(Request(op: "grant", names: ["DB"], folder: "/tmp/site"), peer: ssh).ok)
        XCTAssertEqual(b.handle(Request(op: "check", names: ["DB"]), peer: ssh).needsApproval, ["DB"])
    }

    func testTheSafariExtensionCanOnlyListSaveAndFill() throws {
        let recorder = RecordingApprover()
        let store = MemoryStore()
        try store.save(name: "DB", value: "db-value-123", kind: .password, agentSafe: true, note: "")
        let b = Broker(store: store, approver: recorder, logURL: nil)
        var ext = PeerInfo(pid: 1, path: "/Applications/Latchkey.app/Contents/PlugIns/LatchkeySafari.appex/Contents/MacOS/LatchkeySafari", cwd: "/", chain: [])
        ext.isSafariExtension = true
        let gate = Broker.Gate.safariExtension
        // Even an agent-safe value can't be read through the extension's socket.
        XCTAssertFalse(b.handle(Request(op: "get", names: ["DB"]), peer: ext, gate: gate).ok)
        XCTAssertFalse(b.handle(Request(op: "grant", names: ["DB"], folder: "/tmp"), peer: ext, gate: gate).ok)
        XCTAssertFalse(b.handle(Request(op: "rm", names: ["DB"]), peer: ext, gate: gate).ok)
        XCTAssertEqual(b.handle(Request(op: "list"), peer: ext, gate: gate).secrets?.map(\.name), ["DB"])
        let saved = b.handle(Request(op: "set", names: ["shop/production/STRIPE_KEY"], value: "sk_test_example", kind: .token,
                                     service: "Stripe", page: "https://dashboard.stripe.com"), peer: ext, gate: gate)
        XCTAssertTrue(saved.ok, saved.error ?? "")
        let asked = try XCTUnwrap(recorder.requests.last)
        XCTAssertTrue(asked.fromSafari)
        XCTAssertEqual(asked.page, "https://dashboard.stripe.com")
        XCTAssertNil(asked.program, "named as the extension, not by its path")
        XCTAssertFalse(asked.canGrant)
        XCTAssertTrue(asked.reason.contains("Latchkey's Safari extension on https://dashboard.stripe.com"), asked.reason)
    }

    func testFillSitesAreHttpsDeployPlatformsOrTheServicesOwnSite() {
        XCTAssertTrue(Services.mayFill(origin: "https://vercel.com", service: nil))
        XCTAssertTrue(Services.mayFill(origin: "https://github.com", service: "OpenAI"))
        XCTAssertTrue(Services.mayFill(origin: "https://us-east-1.console.aws.amazon.com", service: nil))
        XCTAssertTrue(Services.mayFill(origin: "https://dashboard.stripe.com", service: "Stripe"))
        XCTAssertFalse(Services.mayFill(origin: "https://dashboard.stripe.com", service: "OpenAI"), "not another service's site")
        XCTAssertFalse(Services.mayFill(origin: "https://example.com", service: "Stripe"))
        XCTAssertFalse(Services.mayFill(origin: "http://vercel.com", service: nil), "https only")
        XCTAssertFalse(Services.mayFill(origin: "https://vercel.com:8443", service: nil))
        XCTAssertFalse(Services.mayFill(origin: "https://vercel.com.example.net", service: nil))
        XCTAssertFalse(Services.mayFill(origin: "https://notvercel.com", service: nil))
        XCTAssertFalse(Services.mayFill(origin: "https://user@vercel.com", service: nil))
        XCTAssertFalse(Services.mayFill(origin: "vercel.com", service: nil))
    }

    func testTheSafariExtensionFillsOneItemOnAnAllowedSiteAndAsksEveryTime() throws {
        let recorder = RecordingApprover()
        let store = MemoryStore()
        try store.save(name: "shop/production/STRIPE_KEY", value: "stripe-value-123", kind: .token, agentSafe: true, note: "",
                       usedIn: nil, service: "Stripe")
        let b = Broker(store: store, approver: recorder, logURL: nil)
        var ext = PeerInfo(pid: 1, path: "/Applications/Latchkey.app/Contents/PlugIns/LatchkeySafari.appex/Contents/MacOS/LatchkeySafari", cwd: "/", chain: [])
        ext.isSafariExtension = true
        let gate = Broker.Gate.safariExtension
        let fill = Request(op: "fill", names: ["shop/production/STRIPE_KEY"], page: "https://vercel.com")
        XCTAssertEqual(b.handle(fill, peer: ext, gate: gate).values, ["shop/production/STRIPE_KEY": "stripe-value-123"])
        XCTAssertEqual(b.handle(fill, peer: ext, gate: gate).values?.count, 1)
        XCTAssertEqual(recorder.requests.count, 2, "agent-safe or just approved, every fill asks")
        let asked = try XCTUnwrap(recorder.requests.last)
        XCTAssertTrue(asked.fromSafari)
        XCTAssertFalse(asked.canGrant)
        XCTAssertTrue(asked.reason.contains("into a field on vercel.com"), asked.reason)
        XCTAssertTrue(b.grants.all().isEmpty)

        // A site it may not go to is refused before anyone is asked; so is more than one item, or no page.
        let elsewhere = b.handle(Request(op: "fill", names: ["shop/production/STRIPE_KEY"], page: "https://example.com"), peer: ext, gate: gate)
        XCTAssertFalse(elsewhere.ok)
        XCTAssertNil(elsewhere.values)
        XCTAssertFalse(b.handle(Request(op: "fill", names: ["shop/production/STRIPE_KEY"]), peer: ext, gate: gate).ok)
        XCTAssertFalse(b.handle(Request(op: "fill", names: ["shop/production/STRIPE_KEY", "X"], page: "https://vercel.com"), peer: ext, gate: gate).ok)
        XCTAssertEqual(recorder.requests.count, 2)

        // Only the extension fills, and a denial releases nothing.
        XCTAssertFalse(b.handle(fill, peer: tool(["lk", "get"])).ok)
        let denied = Broker(store: store, approver: FixedApprover(false), logURL: nil).handle(fill, peer: ext, gate: gate)
        XCTAssertFalse(denied.ok)
        XCTAssertNil(denied.values)
    }

    func testAnItemsOwnFillSitesReplaceTheDefault() throws {
        XCTAssertEqual(try Services.fillSites([" https://App.Netlify.com/teams ", "vercel.com", "vercel.com", "*.example.org", ""]).get(),
                       ["app.netlify.com", "example.org", "vercel.com"])
        for bad in ["localhost", "vercel.com:8443", "user@vercel.com", "not a site", "-x.com", "http://"] {
            XCTAssertThrowsError(try Services.fillSites([bad]).get(), bad)
        }
        XCTAssertThrowsError(try Services.fillSites((0..<21).map { "s\($0).example.com" }).get())

        let recorder = RecordingApprover()
        let store = MemoryStore()
        try store.save(name: "STRIPE_KEY", value: "stripe-value-123", kind: .token, agentSafe: false, note: "", usedIn: nil, service: "Stripe")
        let b = Broker(store: store, approver: recorder, logURL: nil)
        var ext = PeerInfo(pid: 1, path: "/x", cwd: "/", chain: [])
        ext.isSafariExtension = true
        let gate = Broker.Gate.safariExtension
        func fills(_ page: String) -> Bool { b.handle(Request(op: "fill", names: ["STRIPE_KEY"], page: page), peer: ext, gate: gate).ok }

        XCTAssertTrue(fills("https://vercel.com"), "default: a deployment platform")
        // Its own list: only those sites and their subdomains, not the defaults.
        let set = b.handle(Request(op: "update", names: ["STRIPE_KEY"], fillSites: ["Example.org"]), peer: tool(["lk", "update"]))
        XCTAssertTrue(set.ok, set.error ?? "")
        XCTAssertEqual(try store.info("STRIPE_KEY")?.fillSites, ["example.org"])
        XCTAssertTrue(recorder.requests.last?.reason.contains("let Safari fill only on example.org") ?? false)
        XCTAssertTrue(fills("https://example.org"))
        XCTAssertTrue(fills("https://app.example.org"))
        XCTAssertFalse(fills("https://vercel.com"))
        XCTAssertFalse(fills("https://dashboard.stripe.com"))
        XCTAssertFalse(fills("http://example.org"))
        // Other changes keep the list; moving keeps it; an empty list goes back to the default.
        _ = b.handle(Request(op: "update", names: ["STRIPE_KEY"], note: "n"), peer: tool(["lk", "update"]))
        XCTAssertEqual(try store.info("STRIPE_KEY")?.fillSites, ["example.org"])
        XCTAssertFalse(b.handle(Request(op: "update", names: ["STRIPE_KEY"], fillSites: ["not a site"]), peer: tool(["lk", "update"])).ok)
        XCTAssertTrue(b.handle(Request(op: "move", names: ["STRIPE_KEY"], project: "shop", environment: "production"), peer: tool(["lk", "move"])).ok)
        XCTAssertEqual(try store.info("shop/production/STRIPE_KEY")?.fillSites, ["example.org"])
        _ = b.handle(Request(op: "update", names: ["shop/production/STRIPE_KEY"], fillSites: []), peer: tool(["lk", "update"]))
        XCTAssertNil(try store.info("shop/production/STRIPE_KEY")?.fillSites)
        XCTAssertTrue(b.handle(Request(op: "fill", names: ["shop/production/STRIPE_KEY"], page: "https://vercel.com"), peer: ext, gate: gate).ok)
        // The extension can't change where an item may be filled.
        XCTAssertFalse(b.handle(Request(op: "update", names: ["shop/production/STRIPE_KEY"], fillSites: ["evil.example"]), peer: ext, gate: gate).ok)
    }

    func testApprovalCanGrantForTheSessionOrTheCommand() throws {
        let store = MemoryStore()
        try store.save(name: "DB", value: "db-value-123", kind: .password, agentSafe: false, note: "")
        let b = Broker(store: store, approver: FixedApprover(.grant(GrantChoice(duration: 3600, untilAgentQuits: true, thisCommandOnly: true))),
                       logURL: nil)
        let caller = tool(["lk", "run", "--", "npm", "test"], ancestors: [ProcessStamp(pid: 2, started: 1), me])
        XCTAssertEqual(b.handle(Request(op: "get", names: ["DB"]), peer: caller).values, ["DB": "db-value-123"])
        let g = try XCTUnwrap(b.grants.all().first)
        XCTAssertEqual(g.session?.name, "claude")
        XCTAssertEqual(g.commands, [["npm", "test"]])
        XCTAssertEqual(g.limits, "only npm test, until claude quits")
    }

    func testGrantAheadOfTimeAndRevoke() throws {
        let b = try broker(.once)
        let r = b.handle(Request(op: "grant", names: ["DB", "API"], folder: "/tmp/site", duration: 7200), peer: peer)
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
        let grants = GrantStore()
        let g = grants.add(names: ["DB"], folder: "/tmp/site", duration: 3600, createdBy: "t")
        let asked = CountingApprover(true)
        let b = Broker(store: store, approver: asked, logURL: nil, grants: grants)

        let r = b.handle(Request(op: "check", names: ["DB", "API", "HOST", "NOPE"]), peer: at("/tmp/site/sub"))
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertEqual(r.agentSafe, ["HOST"])
        XCTAssertEqual(r.granted, ["DB"])
        XCTAssertEqual(r.needsApproval, ["API"])
        XCTAssertNil(r.remembered)
        XCTAssertEqual(r.missing, ["NOPE"])
        XCTAssertEqual(r.grants?.map(\.id), [g.id])
        XCTAssertNil(r.values)
        XCTAssertEqual(asked.reasons.count, 0, "check never asks")

        // A once-only approval never authorizes a later request.
        XCTAssertEqual(b.handle(Request(op: "get", names: ["API"]), peer: peer).values, ["API": "api-value-456"])
        XCTAssertEqual(asked.reasons.count, 1)
        let again = b.handle(Request(op: "check", names: ["API"]), peer: peer)
        XCTAssertNil(again.remembered)
        XCTAssertEqual(again.needsApproval, ["API"])
        // Outside the grant's folder, DB needs approval again.
        XCTAssertEqual(b.handle(Request(op: "check", names: ["DB"]), peer: at("/tmp/other")).needsApproval, ["DB"])
    }

    func testGrantsAnAgentAsksForAreLimited() throws {
        let store = MemoryStore()
        for id in ["shop/production/DB", "shop/development/DB", "shop/vercel.production/DB", "SHARED"] {
            try store.save(name: id, value: "value-\(id)", kind: .password, agentSafe: false, note: "")
        }
        let b = Broker(store: store, approver: FixedApprover(.once), logURL: nil)
        func ask(_ names: [String], folder: String = "/tmp/site", duration: Double = 3600) -> Response {
            b.handle(Request(op: "grant", names: names, folder: folder, duration: duration, origin: "mcp", session: true), peer: agentPeer)
        }
        XCTAssertFalse(ask(["shop/production/DB"]).ok)
        XCTAssertFalse(ask(["shop/vercel.production/DB"]).ok)
        XCTAssertFalse(ask(["shop/*"]).ok, "a whole project includes production")
        XCTAssertFalse(ask(["shop/production/*"]).ok)
        XCTAssertFalse(ask(["shop/development/DB"], folder: "/tmp/elsewhere").ok, "only the agent's own folder")
        XCTAssertFalse(b.handle(Request(op: "grant", names: ["shop/development/DB"], folder: "/tmp/elsewhere", origin: "mcp"), peer: peer).ok,
                       "claiming another folder doesn't make it the agent's own")
        XCTAssertFalse(b.handle(Request(op: "grant", names: ["shop/development/DB"], folder: "/tmp/site", origin: "mcp"), peer: peer).ok,
                       "an agent's grant lasts only for its session")
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
        // Only a request from the app's own process counts as from the app, whatever a parent process is called.
        let b = Broker(store: MemoryStore(), approver: RecordingApprover(), logURL: nil)
        _ = b.handle(Request(op: "set", names: ["A"], value: "a-value"), peer: PeerInfo(pid: 4242, path: "/tmp/fake", cwd: "/tmp", chain: [Broker.appCaller]))
        _ = b.handle(Request(op: "set", names: ["B"], value: "b-value"), peer: PeerInfo(pid: getpid(), path: "/Applications/Latchkey.app", cwd: "", chain: [Broker.appCaller]))
        let seen = (b.approver as! RecordingApprover).requests
        XCTAssertEqual(seen.map(\.fromApp), [false, true])
        XCTAssertEqual(seen.first?.program, "/tmp/fake", "a program that isn't the signed tool is shown by its path")
        XCTAssertNil(seen.last?.program)
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


/// Keeps every request it's shown and allows them all.
final class RecordingApprover: Approver, @unchecked Sendable {
    var requests: [ApprovalRequest] = []
    var method: String { "test" }
    func approve(_ request: ApprovalRequest) -> ApprovalDecision { requests.append(request); return .once }
}

/// Allows grants and refuses everything else.
struct GrantsOnlyApprover: Approver {
    var method: String { "test" }
    func approve(_ request: ApprovalRequest) -> ApprovalDecision { request.action == .grant ? .once : .deny }
}
