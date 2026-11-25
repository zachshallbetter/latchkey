import Foundation

/// Connects coding agents to Pistachio: registers `pst mcp` as an MCP server in each agent's own user configuration and,
/// where the agent reads Agent Skills, copies Pistachio's skill beside its others. Nothing here reads or passes a value;
/// the agents still ask the app, which still asks the person.
///
/// Files are merged, never replaced: other servers and settings stay, the first change keeps a copy of the original
/// (`<file>.before-pistachio`), and a file that can't be read as the format it should be is left alone and reported.
/// Claude Code keeps its MCP servers in a state file it rewrites itself, so it is changed through its own `claude mcp`
/// command (`claudeCodeArguments`) by the caller rather than edited here.
public enum AgentSetup {
    public static let serverName = "pistachio"
    public static let skillName = "pistachio"

    public enum Agent: String, CaseIterable, Sendable {
        case claudeCode, claudeDesktop, codex, cursor, gemini

        public var title: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .claudeDesktop: "Claude Desktop"
            case .codex: "Codex"
            case .cursor: "Cursor"
            case .gemini: "Gemini CLI"
            }
        }

        /// The folder whose presence means the agent has been used on this Mac.
        func folder(_ home: URL) -> URL {
            switch self {
            case .claudeCode: home.appendingPathComponent(".claude")
            case .claudeDesktop: home.appendingPathComponent("Library/Application Support/Claude")
            case .codex: home.appendingPathComponent(".codex")
            case .cursor: home.appendingPathComponent(".cursor")
            case .gemini: home.appendingPathComponent(".gemini")
            }
        }

        /// Where its MCP servers are listed. Claude Code's is read only, to tell whether Pistachio is there.
        public func mcpFile(_ home: URL) -> URL {
            switch self {
            case .claudeCode: home.appendingPathComponent(".claude.json")
            case .claudeDesktop: folder(home).appendingPathComponent("claude_desktop_config.json")
            case .codex: folder(home).appendingPathComponent("config.toml")
            case .cursor: folder(home).appendingPathComponent("mcp.json")
            case .gemini: folder(home).appendingPathComponent("settings.json")
            }
        }

        /// Where the skill goes, for agents that read user skills.
        public func skillFile(_ home: URL) -> URL? {
            switch self {
            case .claudeCode: folder(home).appendingPathComponent("skills/\(AgentSetup.skillName)/SKILL.md")
            case .codex: folder(home).appendingPathComponent("skills/\(AgentSetup.skillName)/SKILL.md")
            case .claudeDesktop, .cursor, .gemini: nil
            }
        }
    }

    public enum Status: Equatable, Sendable { case notFound, available, connected }

    public enum SetupError: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        public var description: String {
            switch self { case .unreadable(let path): "\(path) isn't in the format expected, so it was left as is." }
        }
    }

    public static func status(_ agent: Agent, home: URL) -> Status {
        let fm = FileManager.default
        guard fm.fileExists(atPath: agent.folder(home).path) else { return .notFound }
        let skillDone = agent.skillFile(home).map { fm.fileExists(atPath: $0.path) } ?? true
        return hasServer(agent, home: home) && skillDone ? .connected : .available
    }

    static func hasServer(_ agent: Agent, home: URL) -> Bool {
        let file = agent.mcpFile(home)
        guard let data = try? Data(contentsOf: file) else { return false }
        if agent == .codex {
            return String(decoding: data, as: UTF8.self).split(separator: "\n")
                .contains { $0.trimmingCharacters(in: .whitespaces) == "[mcp_servers.\(serverName)]" }
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (object?["mcpServers"] as? [String: Any])?[serverName] != nil
    }

    /// `claude` arguments that register the server for every project of this user.
    public static func claudeCodeArguments(tool: URL) -> [String] {
        ["mcp", "add", "--scope", "user", serverName, "--", tool.path, "mcp"]
    }

    /// Registers the server in the agent's file (all but Claude Code) and copies the skill where it reads one.
    public static func connect(_ agent: Agent, home: URL, tool: URL, skill: String) throws {
        if agent != .claudeCode, !hasServer(agent, home: home) {
            agent == .codex ? try addTOML(agent.mcpFile(home), tool: tool) : try addJSON(agent.mcpFile(home), tool: tool)
        }
        if let file = agent.skillFile(home) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(skill.utf8).write(to: file, options: .atomic)
        }
    }

    static func addJSON(_ file: URL, tool: URL) throws {
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            guard let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw SetupError.unreadable(file.path)
            }
            object = existing
            try keepOriginal(file)
        }
        guard object["mcpServers"] == nil || object["mcpServers"] is [String: Any] else { throw SetupError.unreadable(file.path) }
        var servers = object["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": tool.path, "args": ["mcp"]]
        object["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    static func addTOML(_ file: URL, tool: URL) throws {
        var text = ""
        if let data = try? Data(contentsOf: file) {
            guard let existing = String(data: data, encoding: .utf8) else { throw SetupError.unreadable(file.path) }
            text = existing
            try keepOriginal(file)
        }
        let path = tool.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += (text.isEmpty ? "" : "\n") + "[mcp_servers.\(serverName)]\ncommand = \"\(path)\"\nargs = [\"mcp\"]\n"
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file, options: .atomic)
    }

    /// The file as it was before Pistachio first changed it.
    static func keepOriginal(_ file: URL) throws {
        let copy = file.appendingPathExtension("before-pistachio")
        guard !FileManager.default.fileExists(atPath: copy.path) else { return }
        try FileManager.default.copyItem(at: file, to: copy)
    }
}
