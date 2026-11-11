import XCTest
@testable import LatchkeyCore

final class EnvSafetyTests: XCTestCase {
    func testMultilinePrivateKeysAreImportedWholeAndCompletelyRewritten() throws {
        let text = "# heading\r\n  export PRIVATE_KEY=\"-----BEGIN PRIVATE KEY-----\r\nfixture-body\r\n-----END PRIVATE KEY-----\" # comment\r\nKEEP=unchanged\n"
        let plan = try EnvImport.plan(text, source: ".env")
        XCTAssertEqual(plan.items.first { $0.name == "PRIVATE_KEY" }?.value, "-----BEGIN PRIVATE KEY-----\r\nfixture-body\r\n-----END PRIVATE KEY-----")
        XCTAssertEqual(plan.items.first { $0.name == "PRIVATE_KEY" }?.kind, .key)
        let rewritten = try EnvFile.rewrite(text, toReferences: ["PRIVATE_KEY": "p/dev/PRIVATE_KEY"])
        XCTAssertEqual(rewritten, "# heading\r\n  export PRIVATE_KEY=latchkey://p/dev/PRIVATE_KEY\r\nKEEP=unchanged\n")
        XCTAssertFalse(rewritten.contains("fixture-body"))
    }

    func testQuotesEscapesAndDuplicateAssignments() throws {
        let text = "A=\"first\\\"part\\\\path\\nnext\" # note\nB='literal\\n\nsecond line'\nA=last\nexported=plain\n"
        let parsed = try EnvFile.parse(text)
        XCTAssertEqual(parsed[0].value, "first\"part\\path\nnext")
        XCTAssertEqual(parsed[1].value, "literal\\n\nsecond line")
        XCTAssertEqual(try EnvImport.plan(text, source: ".env").items.first?.value, "last")
        let rewritten = try EnvFile.rewrite(text, toReferences: ["A": "A", "exported": "exported"])
        XCTAssertFalse(rewritten.contains("first"))
        XCTAssertTrue(rewritten.hasSuffix("exported=latchkey://exported\n"))
        XCTAssertEqual(try EnvFile.parse("EMPTY=\nHASH=abc#def\nCOMMENT=abc\t#comment").map(\.value), ["", "abc#def", "abc"])
    }

    func testMalformedFilesAreRefusedWithoutExposingTheirContents() throws {
        for text in ["KEY=\"fixture-sensitive\nbody", "KEY='fixture-sensitive", "KEY=\"ok\" trailing", "GOOD=1\nunsupported fixture-sensitive"] {
            XCTAssertThrowsError(try EnvImport.plan(text, source: ".env")) { error in
                XCTAssertFalse(error.localizedDescription.contains("fixture-sensitive"))
            }
            XCTAssertThrowsError(try EnvFile.rewrite(text, toReferences: ["KEY": "KEY"]))
        }
        XCTAssertThrowsError(try EnvImport.batch([(URL(fileURLWithPath: "/tmp/.env"), "KEY=\"unterminated")]))
    }

    func testRewriteRefusesToOverwriteAFileChangedDuringApproval() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = "KEY=fixture-original\n"
        let changed = "KEY=fixture-new\nOTHER=keep\n"
        try changed.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try EnvFile.rewriteFile(at: url, original: original, toReferences: ["KEY": "KEY"]))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), changed)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try EnvFile.rewriteFile(at: url, original: changed, toReferences: ["KEY": "KEY"])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "KEY=latchkey://KEY\nOTHER=keep\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
