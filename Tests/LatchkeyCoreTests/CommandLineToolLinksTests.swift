import Foundation
import XCTest
@testable import LatchkeyCore

final class CommandLineToolLinksTests: XCTestCase {
    private var home: URL!
    private var tool: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("latchkey-links-test-" + UUID().uuidString)
        tool = home.appendingPathComponent("Latchkey.app/Contents/Helpers/latchkey")
        try fm.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: tool)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: home) }

    private func link(_ name: String) -> URL { CommandLineToolLinks.directory(home: home.path).appendingPathComponent(name) }

    func testInstallsBothLinksIntoAFolderThatDoesNotExistYet() throws {
        let result = try CommandLineToolLinks.install(tool: tool, home: home.path)
        XCTAssertEqual(result.installed, ["~/.local/bin/latchkey", "~/.local/bin/lk"])
        XCTAssertEqual(result.inTheWay, [])
        for name in CommandLineToolLinks.names {
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link(name).path), tool.path)
            XCTAssertEqual(CommandLineToolLinks.state(of: link(name), tool: tool), .linked)
        }
        XCTAssertEqual(result.message, "Installed ~/.local/bin/latchkey and ~/.local/bin/lk. Make sure ~/.local/bin is on your PATH.")
    }

    func testRunningAgainChangesNothing() throws {
        _ = try CommandLineToolLinks.install(tool: tool, home: home.path)
        let again = try CommandLineToolLinks.install(tool: tool, home: home.path)
        XCTAssertEqual(again.installed.count, 2)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link("lk").path), tool.path)
    }

    func testReplacesALinkToAnotherCopyButLeavesFilesAlone() throws {
        try fm.createDirectory(at: CommandLineToolLinks.directory(home: home.path), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link("latchkey").path, withDestinationPath: "/Volumes/Latchkey/Latchkey.app/Contents/Helpers/latchkey")
        try Data("my own lk\n".utf8).write(to: link("lk"))
        XCTAssertEqual(CommandLineToolLinks.state(of: link("latchkey"), tool: tool),
                       .otherLink("/Volumes/Latchkey/Latchkey.app/Contents/Helpers/latchkey"))
        XCTAssertEqual(CommandLineToolLinks.state(of: link("lk"), tool: tool), .file)

        let result = try CommandLineToolLinks.install(tool: tool, home: home.path)
        XCTAssertEqual(result.installed, ["~/.local/bin/latchkey"])
        XCTAssertEqual(result.inTheWay, ["~/.local/bin/lk"])
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link("latchkey").path), tool.path)
        XCTAssertEqual(try String(contentsOf: link("lk"), encoding: .utf8), "my own lk\n")
        XCTAssertEqual(result.message, "Installed ~/.local/bin/latchkey. Make sure ~/.local/bin is on your PATH. "
                       + "~/.local/bin/lk already exists and isn't a link to Latchkey; left as is.")
    }

    func testMissingLinks() {
        XCTAssertEqual(CommandLineToolLinks.state(of: link("latchkey"), tool: tool), .missing)
    }

    func testFindsTheFolderOnAPath() {
        let h = "/Users/pat"
        XCTAssertTrue(CommandLineToolLinks.directoryIsOnPath("/opt/homebrew/bin:/Users/pat/.local/bin:/usr/bin", home: h))
        XCTAssertTrue(CommandLineToolLinks.directoryIsOnPath("/Users/pat/.local/bin/", home: h))
        XCTAssertTrue(CommandLineToolLinks.directoryIsOnPath("~/.local/bin:/usr/bin", home: h))
        XCTAssertFalse(CommandLineToolLinks.directoryIsOnPath("/usr/bin:/bin", home: h))
        XCTAssertFalse(CommandLineToolLinks.directoryIsOnPath("/Users/pat/.local/bin2:/Users/sam/.local/bin", home: h))
        XCTAssertFalse(CommandLineToolLinks.directoryIsOnPath("", home: h))
    }
}
