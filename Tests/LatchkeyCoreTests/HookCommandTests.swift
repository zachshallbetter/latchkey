import Foundation
import XCTest
@testable import LatchkeyCore

final class HookCommandTests: XCTestCase {
    func testHookPrefersCurrentNamesAndPropagatesRefusalThroughLegacyFallbacks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pst-hook-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hook = directory.appendingPathComponent("pre-commit")
        try Scan.hook.write(to: hook, atomically: true, encoding: .utf8)
        let names = ["pst", "pist", "pistachio", "lk", "latchkey"]
        for name in names {
            let stub = directory.appendingPathComponent(name)
            try "#!/bin/sh\nprintf '\(name):%s\\n' \"$*\"\nexit 77\n".write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }
        for name in names {
            let result = try run(hook, path: directory.path)
            XCTAssertEqual(result.status, 77, "A refused scan must refuse the commit through every alias")
            XCTAssertEqual(result.text, "\(name):scan --staged\n")
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        let missing = try run(hook, path: directory.path)
        XCTAssertEqual(missing.status, 0, "Preserve the existing warn-only behavior when no tool is installed")
        XCTAssertTrue(missing.text.contains("not found on PATH; staged env files were not scanned"))
    }

    private func run(_ script: URL, path: String) throws -> (status: Int32, text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.environment = ["PATH": path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
