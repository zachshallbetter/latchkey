import Foundation
import XCTest
@testable import LatchkeyCore

final class AgentSetupTests: XCTestCase {
    private var home: URL!
    private let tool = URL(fileURLWithPath: "/Users/me/.local/bin/pst")

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("agent-setup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func make(_ agent: AgentSetup.Agent) throws {
        try FileManager.default.createDirectory(at: agent.folder(home), withIntermediateDirectories: true)
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testAnAgentNeverUsedHereIsNotOffered() {
        for agent in AgentSetup.Agent.allCases { XCTAssertEqual(AgentSetup.status(agent, home: home), .notFound) }
    }

    func testJSONAgentsKeepTheirOtherServersAndSettings() throws {
        for agent in [AgentSetup.Agent.claudeDesktop, .cursor, .gemini] {
            try make(agent)
            let file = agent.mcpFile(home)
            let before = #"{"theme":"dark","mcpServers":{"other":{"command":"other-server"}}}"#
            try Data(before.utf8).write(to: file)
            XCTAssertEqual(AgentSetup.status(agent, home: home), .available)

            try AgentSetup.connect(agent, home: home, tool: tool, skill: "skill")
            let object = try json(file)
            XCTAssertEqual(object["theme"] as? String, "dark")
            let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
            XCTAssertNotNil(servers["other"], agent.title)
            let ours = try XCTUnwrap(servers["pistachio"] as? [String: Any])
            XCTAssertEqual(ours["command"] as? String, tool.path)
            XCTAssertEqual(ours["args"] as? [String], ["mcp"])
            XCTAssertEqual(try String(contentsOf: file.appendingPathExtension("before-pistachio"), encoding: .utf8), before)
            XCTAssertEqual(AgentSetup.status(agent, home: home), .connected)
        }
    }

    func testAMissingConfigFileIsCreated() throws {
        try make(.cursor)
        try AgentSetup.connect(.cursor, home: home, tool: tool, skill: "skill")
        XCTAssertNotNil((try json(AgentSetup.Agent.cursor.mcpFile(home))["mcpServers"] as? [String: Any])?["pistachio"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: AgentSetup.Agent.cursor.mcpFile(home).appendingPathExtension("before-pistachio").path))
    }

    func testAFileThatIsntJSONIsLeftAlone() throws {
        try make(.gemini)
        let file = AgentSetup.Agent.gemini.mcpFile(home)
        let text = "{ // a comment the parser can't read\n \"mcpServers\": {} }"
        try Data(text.utf8).write(to: file)
        XCTAssertThrowsError(try AgentSetup.connect(.gemini, home: home, tool: tool, skill: "skill")) { error in
            XCTAssertEqual(error as? AgentSetup.SetupError, .unreadable(file.path))
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
    }

    func testCodexGetsATableAndTheSkillOnce() throws {
        try make(.codex)
        let file = AgentSetup.Agent.codex.mcpFile(home)
        try Data("model = \"o3\"\n\n[mcp_servers.other]\ncommand = \"other\"".utf8).write(to: file)
        try AgentSetup.connect(.codex, home: home, tool: tool, skill: "---\nname: pistachio\n---\n")
        try AgentSetup.connect(.codex, home: home, tool: tool, skill: "---\nname: pistachio\n---\n")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("model = \"o3\"\n\n[mcp_servers.other]\ncommand = \"other\"\n"))
        XCTAssertEqual(text.components(separatedBy: "[mcp_servers.pistachio]").count, 2, "added once")
        XCTAssertTrue(text.hasSuffix("[mcp_servers.pistachio]\ncommand = \"\(tool.path)\"\nargs = [\"mcp\"]\n"))
        let skill = try XCTUnwrap(AgentSetup.Agent.codex.skillFile(home))
        XCTAssertEqual(try String(contentsOf: skill, encoding: .utf8), "---\nname: pistachio\n---\n")
        XCTAssertEqual(AgentSetup.status(.codex, home: home), .connected)
    }

    func testClaudeCodeIsConnectedOnlyWithItsServerAndSkill() throws {
        try make(.claudeCode)
        let state = AgentSetup.Agent.claudeCode.mcpFile(home)
        try Data(#"{"projects":{}}"#.utf8).write(to: state)
        try AgentSetup.connect(.claudeCode, home: home, tool: tool, skill: "skill")
        XCTAssertEqual(try String(contentsOf: state, encoding: .utf8), #"{"projects":{}}"#, "its state file is never edited")
        XCTAssertEqual(AgentSetup.status(.claudeCode, home: home), .available, "skill alone isn't enough")
        try Data(#"{"mcpServers":{"pistachio":{"command":"pst"}}}"#.utf8).write(to: state)
        XCTAssertEqual(AgentSetup.status(.claudeCode, home: home), .connected)
        XCTAssertEqual(AgentSetup.claudeCodeArguments(tool: tool), ["mcp", "add", "--scope", "user", "pistachio", "--", tool.path, "mcp"])
    }
}
