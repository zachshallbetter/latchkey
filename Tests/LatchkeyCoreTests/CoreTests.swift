import XCTest
@testable import LatchkeyCore

final class CoreTests: XCTestCase {
    func testMaskerReplacesWholeValue() {
        var m = Masker(secrets: ["fixture-value-000000"])
        var out = m.feed(Data("out=fixture-value-000000 done\n".utf8))
        out.append(m.flush())
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "out=<concealed by latchkey> done\n")
    }

    func testMaskerHandlesSplitAcrossChunks() {
        let sample = "fixture-value-000000"
        for cut in 1..<sample.count {
            var m = Masker(secrets: [sample])
            let text = "a " + sample + " b"
            let bytes = Array(text.utf8)
            let at = 2 + cut
            var out = m.feed(Data(bytes[..<at]))
            out.append(m.feed(Data(bytes[at...])))
            out.append(m.flush())
            XCTAssertEqual(String(decoding: out, as: UTF8.self), "a <concealed by latchkey> b", "cut at \(cut)")
        }
    }

    func testMaskerPassesOrdinaryOutputPromptly() {
        var m = Masker(secrets: ["fixture-value-000000"])
        let out = m.feed(Data("hello world\n".utf8))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "hello world\n")
    }

    func testMaskerIgnoresShortValuesAndMasksEachLine() {
        var m = Masker(secrets: ["abc", "line-one-secret\nline-two-secret"])
        var out = m.feed(Data("abc line-two-secret".utf8))
        out.append(m.flush())
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "abc <concealed by latchkey>")
    }

    func testEnvFileParsing() {
        let text = """
        # comment
        export A=1
        B="two words"
        C='single # kept'
        D=plain # trailing comment
        E=latchkey://gemini
        bad line
        """
        let parsed = Dictionary(uniqueKeysWithValues: EnvFile.parse(text).map { ($0.key, $0.value) })
        XCTAssertEqual(parsed, ["A": "1", "B": "two words", "C": "single # kept", "D": "plain", "E": "latchkey://gemini"])
    }

    func testReferences() {
        let env = ["A": "latchkey://gemini", "URL": "postgres://u:latchkey://db.pass@host/db", "C": "plain"]
        XCTAssertEqual(References.names(in: env), ["gemini", "db.pass"])
        let out = References.resolve(env: env, with: ["gemini": "G", "db.pass": "P"])
        XCTAssertEqual(out, ["A": "G", "URL": "postgres://u:P@host/db", "C": "plain"])
        XCTAssertEqual(References.resolve("latchkey://missing", with: [:]), "latchkey://missing")
    }

    func testNames() {
        XCTAssertTrue(Wire.isValidName("GEMINI_API_KEY"))
        XCTAssertTrue(Wire.isValidName("db.pass-1"))
        XCTAssertFalse(Wire.isValidName("has space"))
        XCTAssertFalse(Wire.isValidName(""))
    }
}
