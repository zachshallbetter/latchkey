import Foundation
import XCTest
import LatchkeyCore
@testable import latchkey

final class RunTests: XCTestCase {
    let spec = RunSpec(cwd: "/tmp")
    func prepare(_ env: [String: String], values: [String: String], proxy: Bool = false) throws -> PreparedRun {
        try prepareRun(spec, env: env, masking: true, proxy: proxy) { _ in Response(ok: true, values: values) }
    }

    func testKeyFilesHaveUniquePathsAndOwnerOnlyPermissions() throws {
        let env = ["DEV": "latchkey-file://shop/development/KEY", "PROD": "latchkey-file://shop/production/KEY",
                   "DEV_AGAIN": "latchkey-file://shop/development/KEY"]
        let run = try prepare(env, values: ["shop/development/KEY": "fixture-dev", "shop/production/KEY": "fixture-prod"])
        let dir = try XCTUnwrap(run.tempDir)
        defer { run.cleanUp() }
        let dev = try XCTUnwrap(run.environment["DEV"]), prod = try XCTUnwrap(run.environment["PROD"])
        XCTAssertNotEqual(dev, prod)
        XCTAssertEqual(run.environment["DEV_AGAIN"], dev)
        XCTAssertEqual(try String(contentsOfFile: dev, encoding: .utf8), "fixture-dev")
        XCTAssertEqual(try String(contentsOfFile: prod, encoding: .utf8), "fixture-prod")
        for (path, permissions) in [(dir.path, 0o700), (dev, 0o600), (prod, 0o600)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, permissions)
        }
        run.cleanUp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testIncompleteBrokerReplyNeverBecomesAnEmptyKeyFile() {
        XCTAssertThrowsError(try prepare(["KEY": "latchkey-file://MISSING"], values: [:]))
    }

    func testProxyHoldsBackSupportedKeysAndRefusesOtherDeliveries() throws {
        let key = "fixture-provider-key", values = ["KEY": "fixture-provider-key"]
        let base = ["OPENAI_API_KEY": "latchkey://KEY"]
        let run = try prepare(base, values: values, proxy: true)
        XCTAssertTrue(run.environment["OPENAI_API_KEY"]?.hasPrefix("lk-proxy-") == true)
        XCTAssertFalse(run.environment.values.contains { $0.contains(key) })
        XCTAssertEqual(run.proxies.count, 1)
        for extra in [["ALIAS": "latchkey://KEY"], ["URL": "prefix-latchkey://KEY"],
                      ["KEY_FILE": "latchkey-file://KEY"], ["ALIAS": key],
                      ["OPENAI_BASE_URL": "https://api.openai.com/v1"]] {
            XCTAssertThrowsError(try prepare(base.merging(extra) { _, b in b }, values: values, proxy: true))
        }
        XCTAssertThrowsError(try prepare(["OPENAI_API_KEY": key], values: values, proxy: true))
        XCTAssertThrowsError(try prepare([:], values: values, proxy: true))
    }

    func testMalformedEnvFileStopsBeforeBrokerAccess() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try "KEY=\"unterminated\nbody".write(to: file, atomically: true, encoding: .utf8)
        var calls = 0
        XCTAssertThrowsError(try plannedEnvironment(RunSpec(envFiles: [file.path], cwd: "/tmp"), base: [:]) { _ in
            calls += 1
            return Response(ok: true)
        })
        XCTAssertEqual(calls, 0)
    }
}

/// The MCP export tool writes without asking the owner, so only inside the folder the agent works in.
final class MCPExportPathTests: XCTestCase {
    func testExportPathStaysInsideTheFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("latchkey-mcp-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("project"), outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: outside)
        defer { try? fm.removeItem(at: root) }

        XCTAssertEqual(try MCPServer.inside(dir.path, ".env.local"), dir.appendingPathComponent(".env.local").path)
        XCTAssertNoThrow(try MCPServer.inside(dir.path, "sub/.env"))
        XCTAssertNoThrow(try MCPServer.inside(dir.path, dir.appendingPathComponent(".env").path))
        for escape in ["../outside/.env", outside.appendingPathComponent(".env").path, "link/.env", "~/.zshrc", "/etc/hosts", ""] {
            XCTAssertThrowsError(try MCPServer.inside(dir.path, escape), escape)
        }
    }
}
