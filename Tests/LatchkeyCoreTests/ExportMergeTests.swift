import AppKit
import XCTest
@testable import LatchkeyCore

final class ExportMergeTests: XCTestCase {
    let peer = PeerInfo(pid: 1, path: "/usr/local/bin/latchkey", cwd: "/tmp/project", chain: ["zsh"])
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lk-merge-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func path(_ name: String = ".env.local") -> String { root.appendingPathComponent(name).path }
    func read(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

    // MARK: merging text

    func testMergeUpdatesAppendsAndKeepsEverythingElseByteForByte() throws {
        let text = "# my settings\n\n  export API=old # keep?\nKEEP = as is\nMULTI=\"a\nb\"\n\n# end\nSAME=\"x y\"\nTAIL=1"
        let merged = try EnvFile.merge(text, with: ["API": "latchkey://shop/development/API", "SAME": "x y", "MULTI": "one", "NEW": "a b", "ZED": "9"])
        XCTAssertEqual(merged.updated, ["API", "MULTI"])
        XCTAssertEqual(merged.added, ["NEW", "ZED"])
        XCTAssertEqual(merged.text, "# my settings\n\n  export API=latchkey://shop/development/API\nKEEP = as is\nMULTI=one\n\n# end\nSAME=\"x y\"\nTAIL=1\nNEW=\"a b\"\nZED=9\n")
    }

    func testMergeKeepsLineEndingsAndLeavesAFileAloneWhenNothingChanges() throws {
        let crlf = "# c\r\nA=1\r\nB=2\r\n"
        let merged = try EnvFile.merge(crlf, with: ["A": "9", "C": "3"])
        XCTAssertEqual(merged.text, "# c\r\nA=9\r\nB=2\r\nC=3\r\n")
        let same = "B=2\n# keep\nA=1"
        let none = try EnvFile.merge(same, with: ["A": "1", "B": "2"])
        XCTAssertEqual(none.text, same)
        XCTAssertEqual(none.added + none.updated, [])
        XCTAssertEqual(try EnvFile.merge("", with: ["A": "1"]).text, "A=1\n")
        XCTAssertEqual(try EnvFile.merge("# only\n", with: ["A": "1"]).text, "# only\nA=1\n")
    }

    func testMergeUpdatesEveryAssignmentOfADuplicatedNameAndRefusesWhatItCantRead() throws {
        XCTAssertEqual(try EnvFile.merge("A=1\nB=2\nA=3\n", with: ["A": "9"]).text, "A=9\nB=2\nA=9\n")
        XCTAssertThrowsError(try EnvFile.merge("A=1\nnot an assignment\n", with: ["A": "2"]))
        XCTAssertThrowsError(try EnvFile.merge("A=\"open\n", with: ["A": "2"]))
    }

    func testPendingNamesCountAsUpdatedWhereTheyAreAlready() throws {
        let merged = try EnvFile.merge("A=1\nB=2\n", with: ["A": "latchkey://A", "B": "2", "C": "latchkey://C"], pending: ["A", "B", "C"])
        XCTAssertEqual(merged.updated, ["A", "B"], "values aren't known yet, so a present name may change")
        XCTAssertEqual(merged.added, ["C"])
    }

    // MARK: planning and writing

    let record = EnvironmentRecord(scope: "shop/development",
                                   variables: ["PORT": .literal("3000"), "DATABASE_URL": .credential("shop/development/DATABASE_URL")])

    func testPlanNamesWhatChangesAndMergeKeepsPermissions() throws {
        let file = path()
        try "# mine\nPORT=3000\nOTHER=1\n".write(toFile: file, atomically: true, encoding: .utf8)
        chmod(file, 0o640)
        let plan = try EnvExport.plan(path: file, record: record, values: false, mode: .merge)
        XCTAssertEqual(plan.added, ["DATABASE_URL"])
        XCTAssertEqual(plan.updated, [])
        let result = try EnvExport.write(plan, record: record)
        XCTAssertEqual(result.added, ["DATABASE_URL"])
        XCTAssertEqual(try read(file), "# mine\nPORT=3000\nOTHER=1\nDATABASE_URL=latchkey://shop/development/DATABASE_URL\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int), 0o640)

        let again = try EnvExport.plan(path: file, record: record, values: false, mode: .merge)
        XCTAssertFalse(again.changes)
    }

    func testValuesMergeListsPresentCredentialsAsUpdatedAndWritesOwnerOnly() throws {
        let file = path()
        try "DATABASE_URL=old\nKEEP=1\n".write(toFile: file, atomically: true, encoding: .utf8)
        chmod(file, 0o644)
        let plan = try EnvExport.plan(path: file, record: record, values: true, mode: .merge)
        XCTAssertEqual(plan.updated, ["DATABASE_URL"])
        XCTAssertEqual(plan.added, ["PORT"])
        let result = try EnvExport.write(plan, record: record, released: ["shop/development/DATABASE_URL": "postgres://u:p w@h/db"])
        XCTAssertEqual(try read(file), "DATABASE_URL=\"postgres://u:p w@h/db\"\nKEEP=1\nPORT=3000\n")
        XCTAssertEqual(result.updated, ["DATABASE_URL"])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int), 0o600)
    }

    func testMergeIntoAMissingFileCreatesItAndOtherModesKeepTheirRules() throws {
        let fresh = path("fresh")
        let plan = try EnvExport.plan(path: fresh, record: record, values: false, mode: .merge)
        XCTAssertNil(plan.existing)
        XCTAssertEqual(plan.added, ["DATABASE_URL", "PORT"])
        try EnvExport.write(plan, record: record)
        XCTAssertEqual(try read(fresh), record.envFile())

        XCTAssertThrowsError(try EnvExport.plan(path: fresh, record: record, values: false, mode: .create), "an existing file needs --merge or --replace")
        let replaced = try EnvExport.plan(path: fresh, record: record, values: false, mode: .replace)
        try "junk\n".write(toFile: fresh, atomically: true, encoding: .utf8)
        try EnvExport.write(replaced, record: record)
        XCTAssertEqual(try read(fresh), record.envFile())
    }

    func testMergeRefusesLinksFoldersBinaryFilesAndAFileThatChangedMeanwhile() throws {
        let target = path("target")
        try "keep\n".write(toFile: target, atomically: true, encoding: .utf8)
        let link = path("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        XCTAssertThrowsError(try EnvExport.plan(path: link, record: record, values: false, mode: .merge))
        XCTAssertThrowsError(try EnvExport.plan(path: root.path, record: record, values: false, mode: .merge))
        let binary = path("binary")
        try Data([0xff, 0xfe, 0x00, 0x41]).write(to: URL(fileURLWithPath: binary))
        XCTAssertThrowsError(try EnvExport.plan(path: binary, record: record, values: false, mode: .merge))

        let file = path()
        try "A=1\n".write(toFile: file, atomically: true, encoding: .utf8)
        let plan = try EnvExport.plan(path: file, record: record, values: false, mode: .merge)
        try "A=2\nSOMEONE=else\n".write(toFile: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try EnvExport.write(plan, record: record)) { XCTAssertTrue("\($0)".contains("changed") || $0.localizedDescription.contains("changed while waiting")) }
        XCTAssertEqual(try read(file), "A=2\nSOMEONE=else\n")
        XCTAssertEqual(try read(target), "keep\n")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".latchkey-") }
        XCTAssertEqual(leftovers, [])
    }

    // MARK: the clipboard

    func makeBroker(_ approver: Approver, log: URL? = nil) throws -> (Broker, MemoryStore) {
        let store = MemoryStore()
        try store.save(name: "shop/development/DB", value: "postgres://secret", kind: .password, agentSafe: true, note: "")
        return (Broker(store: store, approver: approver, logURL: log, logKeys: log == nil ? nil : MemoryLogKeyStore(), records: MemoryEnvironmentStore()), store)
    }

    func testCopyAsksEveryTimeNamingTheEnvironmentAndTheClipboardAndLogsIt() throws {
        let log = root.appendingPathComponent("log")
        let approver = CountingApprover(true)
        let (b, _) = try makeBroker(approver, log: log)
        let req = Request(op: "export", names: ["shop/development/DB"], project: "shop/development", clipboard: true)
        XCTAssertEqual(b.handle(req, peer: peer).values, ["shop/development/DB": "postgres://secret"])
        XCTAssertEqual(b.handle(req, peer: peer).ok, true)
        XCTAssertEqual(approver.reasons.count, 2, "agent-safe or not, every copy asks")
        XCTAssertTrue(approver.reasons[0].contains("from shop/development to the clipboard"), approver.reasons[0])
        XCTAssertTrue(approver.reasons[0].contains("this Mac"), approver.reasons[0])
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("copied to the clipboard"), text)
        XCTAssertFalse(text.contains("postgres://secret"))
    }

    func testCopyIsRefusedToAgentsSafariAndAnotherComputerAndWhenDenied() throws {
        let approver = CountingApprover(true)
        let (b, _) = try makeBroker(approver)
        var agent = Request(op: "export", names: ["shop/development/DB"], project: "shop/development", clipboard: true)
        agent.origin = "mcp"
        XCTAssertFalse(b.handle(agent, peer: peer).ok)
        var safari = peer
        safari.isSafariExtension = true
        XCTAssertFalse(b.handle(Request(op: "export", names: ["shop/development/DB"], project: "shop/development", clipboard: true), peer: safari).ok)
        let ssh = PeerInfo(pid: 2, path: "/usr/bin/ssh", cwd: "/tmp", chain: ["zsh"])
        XCTAssertFalse(b.handle(Request(op: "export", names: ["shop/development/DB"], project: "shop/development", clipboard: true), peer: ssh).ok)
        XCTAssertFalse(b.handle(Request(op: "export", names: ["shop/development/DB"], clipboard: true), peer: peer).ok, "the environment is named")
        XCTAssertEqual(approver.reasons.count, 0, "refused before anything is asked")

        let (deny, _) = try makeBroker(FixedApprover(false))
        XCTAssertNil(deny.handle(Request(op: "export", names: ["shop/development/DB"], project: "shop/development", clipboard: true), peer: peer).values)
    }

    func testClipboardIsConcealedTransientAndClearsOnlyIfUnchanged() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("io.snackstud.latchkey.test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let stamp = Clipboard.copy("A=1\n", to: pb)
        XCTAssertEqual(pb.string(forType: .string), "A=1\n")
        XCTAssertTrue(pb.types?.contains(Clipboard.concealed) == true)
        XCTAssertTrue(pb.types?.contains(Clipboard.transient) == true)
        XCTAssertEqual(Clipboard.concealed.rawValue, "org.nspasteboard.ConcealedType")
        XCTAssertEqual(Clipboard.transient.rawValue, "org.nspasteboard.TransientType")
        XCTAssertEqual(Clipboard.clearAfter, 60)

        pb.clearContents()
        pb.setString("something else", forType: .string)
        XCTAssertFalse(Clipboard.clear(ifUnchangedSince: stamp, on: pb))
        XCTAssertEqual(pb.string(forType: .string), "something else")

        let second = Clipboard.copy("B=2\n", to: pb)
        XCTAssertTrue(Clipboard.clear(ifUnchangedSince: second, on: pb))
        XCTAssertNil(pb.string(forType: .string))
    }
}
