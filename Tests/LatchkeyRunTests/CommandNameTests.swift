import Foundation
import XCTest

final class CommandNameTests: XCTestCase {
    func testEveryAliasRunsTheSameHelpWithoutConnectingToTheVault() throws {
        let tool = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("latchkey")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: tool.path))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pst-alias-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var expected: String?
        for name in ["pst", "pistachio", "lk", "latchkey"] {
            let alias = directory.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: tool)
            let process = Process()
            process.executableURL = alias
            process.arguments = ["help"]
            process.environment = ["PATH": "/usr/bin:/bin", "PISTACHIO_NO_LAUNCH": "1",
                                   "PISTACHIO_SOCKET": directory.appendingPathComponent("absent.sock").path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let help = String(decoding: data, as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, name)
            XCTAssertTrue(help.contains("pst run"), name)
            XCTAssertTrue(help.contains("pistachio is the full name"), name)
            if let expected { XCTAssertEqual(help, expected, name) } else { expected = help }
        }
    }
}
