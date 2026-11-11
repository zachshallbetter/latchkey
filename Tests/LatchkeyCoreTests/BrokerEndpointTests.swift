import XCTest
@testable import LatchkeyCore

final class BrokerEndpointTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/fixture")
    func select(_ env: [String: String] = [:], team: String? = "TEAM123456", store: Bool = false) throws -> BrokerEndpoint {
        try BrokerEndpoint.select(environment: env, team: team, installedAppIsStore: store, home: home, directPath: "/direct/broker.sock")
    }

    func testChannelSelectionNeverFallsBackOrSilentlyChangesTrust() throws {
        XCTAssertEqual(try select().path, "/direct/broker.sock")
        let endpoint = try select(store: true)
        XCTAssertEqual(endpoint.path, "/Users/fixture/Library/Group Containers/TEAM123456.io.snackstud.latchkey/cli.sock")
        XCTAssertEqual(endpoint.authentication, .sameTeamApplication("TEAM123456"))
        XCTAssertEqual(try select(["LATCHKEY_BROKER": "direct"], store: true).path, "/direct/broker.sock")
        XCTAssertThrowsError(try select(["LATCHKEY_BROKER": "app-store"], team: nil))
        XCTAssertThrowsError(try select(["LATCHKEY_BROKER": "app-store"], team: "../other"))
        XCTAssertThrowsError(try select(["LATCHKEY_BROKER": "typo"]))
    }

    func testForwardingIsExplicitAndCannotDisableLocalAuthentication() throws {
        let ssh = ["LATCHKEY_SOCKET": "/ssh/forward.sock"]
        XCTAssertEqual(try select(ssh).authentication, .sshForward)
        XCTAssertThrowsError(try select(ssh, store: true))
        XCTAssertEqual(try select(ssh.merging(["LATCHKEY_BROKER": "direct"]) { _, b in b }, store: true).authentication, .sshForward)
        XCTAssertEqual(BrokerEndpoint.local(path: "/local", team: "TEAM").authentication, .sameTeamApplication("TEAM"))
        XCTAssertEqual(try select(["LATCHKEY_BROKER": "app-store", "LATCHKEY_LOCAL_SOCKET": "/fixture"]).authentication,
                       .sameTeamApplication("TEAM123456"))
        XCTAssertThrowsError(try select(["LATCHKEY_LOCAL_SOCKET": "relative"]))
        XCTAssertThrowsError(try select(["LATCHKEY_LOCAL_SOCKET": "/local", "LATCHKEY_SOCKET": "/forward"]))
    }

    func testCommandContextParsesAllRunOptionsAndRejectsUnknownOnes() {
        func command(_ args: [String]) -> [String]? {
            PeerInfo(pid: 1, path: "/fixture/latchkey", cwd: "/project", chain: [],
                     arguments: ["latchkey", "run"] + args, isLatchkeyTool: true).runCommand
        }
        XCTAssertEqual(command(["--aws-role", "arn:fixture", "--aws-for", "15m", "--env-file=.env", "--proxy", "--", "node", "server.js"]), ["node", "server.js"])
        XCTAssertNil(command(["--new-unknown-option", "node"]))
        XCTAssertNil(command(["--aws-role"]))
        XCTAssertNil(command(["--"]))
    }

    func testCommandLineGateDoesNotExposeSafariFill() {
        XCTAssertEqual(Broker.Gate.commandLineTool.identifier, CodeIdentity.toolIdentifier)
        XCTAssertFalse(Broker.Gate.commandLineTool.ops.contains("fill"))
        XCTAssertTrue(Broker.Gate.commandLineTool.ops.contains("get"))
        XCTAssertFalse(Broker.Gate.safariExtension.ops.contains("get"))
    }
}
