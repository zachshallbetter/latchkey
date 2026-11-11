import XCTest
@testable import LatchkeyCore

final class BatchImportTests: XCTestCase {
    func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testSkipListAndPublicPatterns() {
        let p = EnvImport.plan("VERCEL_OIDC_TOKEN=x\nVERCEL_ENV=dev\nTURBO_TEAM=t\nNEXT_PUBLIC_API=https://a\nDB=v",
                               source: ".env", agentSafePatterns: ["NEXT_PUBLIC_*", "VITE_*"])
        XCTAssertEqual(p.items.map(\.name), ["DB", "NEXT_PUBLIC_API"])
        XCTAssertEqual(p.ignored.keys.sorted(), ["TURBO_TEAM", "VERCEL_ENV", "VERCEL_OIDC_TOKEN"])
        let pub = p.items.first { $0.name == "NEXT_PUBLIC_API" }!
        XCTAssertEqual(pub.kind, .value)
        XCTAssertEqual(pub.agentSafe, true)
        XCTAssertEqual(EnvImport.plan("VERCEL_ENV=dev", source: ".env", skip: []).items.map(\.name), ["VERCEL_ENV"], "--no-default-skip")
        XCTAssertTrue(EnvImport.matches("SENTRY_AUTH_TOKEN", ["SENTRY_*"]))
        XCTAssertFalse(EnvImport.matches("MY_SENTRY", ["SENTRY_*"]))
    }

    func testSharesIdenticalValuesAndPlacesTheRestPerProject() {
        let plan = EnvImport.batch([
            (url("/r/acp/.env.local"), "GEMINI_API_KEY=g\nDATABASE_URL=postgres://u:a@h/acp\nONLY_ACP=1"),
            (url("/r/site/.env.local"), "GEMINI_API_KEY=g\nDATABASE_URL=postgres://u:s@h/site"),
            (url("/r/web/.env.production"), "GEMINI_API_KEY=g"),
        ], shareIdentical: true)
        XCTAssertEqual(plan.shared, ["GEMINI_API_KEY": 3])
        let names = plan.items.map(\.name)
        XCTAssertTrue(names.contains("GEMINI_API_KEY"))
        XCTAssertTrue(names.contains("acp/development/DATABASE_URL"))
        XCTAssertTrue(names.contains("site/development/DATABASE_URL"))
        XCTAssertTrue(names.contains("acp/development/ONLY_ACP"), "a name in one file stays with its project")
        XCTAssertEqual(plan.items.first { $0.name == "GEMINI_API_KEY" }?.usedIn?.count, 3)
        XCTAssertEqual(plan.files[2].project, "web")
        XCTAssertEqual(plan.files[2].environment, "production")
        XCTAssertEqual(plan.files[0].references["GEMINI_API_KEY"], "GEMINI_API_KEY")
        XCTAssertEqual(plan.files[1].references["DATABASE_URL"], "site/development/DATABASE_URL")

        let noShare = EnvImport.batch([(url("/r/acp/.env"), "K=1"), (url("/r/site/.env"), "K=1")])
        XCTAssertEqual(noShare.items.map(\.name), ["acp/development/K", "site/development/K"], "sharing is opt-in")
    }

    func testDifferentValuesForOneIDAreAConflictLeftAlone() {
        let plan = EnvImport.batch([(url("/r/acp/.env"), "DB=one\nSAME=s"), (url("/r/acp/.env.local"), "DB=two\nSAME=s")])
        XCTAssertEqual(plan.conflicts.keys.sorted(), ["acp/development/DB"])
        XCTAssertEqual(plan.items.map(\.name), ["acp/development/SAME"])
        XCTAssertNil(plan.files[0].references["DB"])
        XCTAssertNil(plan.files[1].references["DB"])
        XCTAssertTrue(plan.files[1].ignored["DB"]!.hasPrefix("conflict"))
        XCTAssertEqual(plan.items[0].usedIn, ["/r/acp/.env", "/r/acp/.env.local"], "the same value from two files is one item used in both")
    }
}
