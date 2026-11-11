import XCTest
@testable import LatchkeyCore

/// A main checkout and a worktree elsewhere, laid out the way git writes them.
final class WorktreeTests: XCTestCase {
    var root: URL!
    var main: URL!
    var worktree: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lk-wt-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        main = root.appendingPathComponent("Projects/Site App")
        worktree = root.appendingPathComponent("Projects/_worktrees/site/fix-login")
        let fm = FileManager.default
        let gitWorktreeDir = main.appendingPathComponent(".git/worktrees/fix-login")
        try fm.createDirectory(at: gitWorktreeDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: worktree.appendingPathComponent("apps/web"), withIntermediateDirectories: true)
        try "gitdir: \(gitWorktreeDir.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: gitWorktreeDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testWorktreeAndMainShareARepository() {
        let common = main.appendingPathComponent(".git").path
        XCTAssertEqual(Repo.commonDir(for: main.path), common)
        XCTAssertEqual(Repo.commonDir(for: worktree.appendingPathComponent("apps/web").path), common)
        XCTAssertEqual(Repo.mainCheckout(for: worktree.path), main.path)
        XCTAssertNil(Repo.commonDir(for: root.path))
    }

    func testImportNamesTheProjectAfterTheMainCheckout() {
        XCTAssertEqual(EnvImport.project(forFile: worktree.appendingPathComponent("apps/web/.env.local")), "site-app")
        XCTAssertEqual(EnvImport.project(forFile: main.appendingPathComponent(".env")), "site-app")
    }

    func testAGrantForTheCheckoutCoversItsWorktrees() {
        let store = GrantStore(url: nil)
        let g = store.add(names: ["site/development/*"], folder: main.path, duration: 3600, createdBy: "t")
        XCTAssertEqual(g.repo, main.appendingPathComponent(".git").path)
        XCTAssertTrue(g.covers("site/development/DB", cwd: worktree.appendingPathComponent("apps/web").path))
        XCTAssertTrue(g.covers("site/development/DB", cwd: main.path))
        XCTAssertFalse(g.covers("site/development/DB", cwd: root.path))
        XCTAssertFalse(g.covers("site/production/DB", cwd: worktree.path))
    }
}

final class FileReferenceTests: XCTestCase {
    func testWholeValueFileReferencesOnly() {
        let env = ["GOOGLE_APPLICATION_CREDENTIALS": "latchkey-file://gcp/production/SA", "X": "prefix latchkey-file://A",
                   "BAD": "latchkey-file://not a name", "R": "latchkey://acp/production/DB"]
        XCTAssertEqual(References.fileReferences(in: env), ["GOOGLE_APPLICATION_CREDENTIALS": "gcp/production/SA"])
        XCTAssertEqual(References.names(in: env), ["acp/production/DB"], "file references aren't value references")
    }
}
