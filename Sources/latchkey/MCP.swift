import Foundation
import LatchkeyCore

/// `latchkey mcp`: Latchkey's tools for agents over the Model Context Protocol, as newline-delimited JSON-RPC 2.0
/// on standard input and output (logs go to standard error).
///
/// There is no direct secret-read tool. Child output masks exact values, but transformed values can leak.
/// Agents get item metadata, a check of what a run would get without asking, commands
/// run with values filled in and their output masked, and a way to ask the owner for a limited grant. Every
/// request reaches the app like any other `latchkey` call, marked as coming from an agent.
final class MCPServer: @unchecked Sendable {
    /// Keep in step with MARKETING_VERSION in App/project.yml.
    static let version = "0.3.0"
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let defaultTimeout: TimeInterval = 600
    static let longestTimeout: TimeInterval = 3600
    /// The most output kept per stream; the end is kept, where failures show.
    static let outputCap = 64 * 1024

    private let writeLock = NSLock()
    private let runLock = NSLock()
    /// Running commands by request id, so a cancelled request stops its command.
    private var running: [String: Process] = [:]
    /// Requests the client cancelled: they get no response.
    private var cancelled: Set<String> = []
    private let home = FileManager.default.currentDirectoryPath

    enum Outcome {
        case result([String: Any])
        case error(Int, String)
    }

    // MARK: transport

    func serve() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let calls = DispatchGroup()
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                write(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
                continue
            }
            let method = message["method"] as? String ?? ""
            let params = message["params"] as? [String: Any] ?? [:]
            guard message.keys.contains("id") else { notify(method, params); continue }
            let id = message["id"] ?? NSNull()
            if method == "tools/call" {
                // Commands can take minutes; keep answering pings and cancellations meanwhile.
                calls.enter()
                DispatchQueue.global().async {
                    let key = Self.key(id)
                    let outcome = self.callTool(params, id: key)
                    self.runLock.lock()
                    let dropped = self.cancelled.remove(key) != nil
                    self.runLock.unlock()
                    if !dropped { self.reply(id, outcome) }
                    calls.leave()
                }
            } else {
                reply(id, handle(method, params))
            }
        }
        calls.wait()
        exit(0)
    }

    private func handle(_ method: String, _ params: [String: Any]) -> Outcome {
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return .result([
                "protocolVersion": Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "latchkey", "title": "Latchkey", "version": Self.version],
                "instructions": Self.instructions,
            ])
        case "ping":
            return .result([:])
        case "tools/list":
            return .result(["tools": Self.tools])
        default:
            return .error(-32601, "method not found: \(method)")
        }
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        guard method == "notifications/cancelled", let id = params["requestId"] else { return }
        let key = Self.key(id)
        runLock.lock()
        let process = running[key]
        if process != nil { cancelled.insert(key) }
        runLock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    private func reply(_ id: Any, _ outcome: Outcome) {
        switch outcome {
        case .result(let r): write(["jsonrpc": "2.0", "id": id, "result": r])
        case .error(let code, let message): write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
        }
    }

    private func write(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes, .sortedKeys]) else { return }
        data.append(0x0A)
        writeLock.lock()
        FileHandle.standardOutput.write(data)
        writeLock.unlock()
    }

    static func key(_ id: Any) -> String {
        if let s = id as? String { return "s:" + s }
        return "n:\(id)"
    }

    // MARK: tools

    private func callTool(_ params: [String: Any], id: String) -> Outcome {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            switch name {
            case "latchkey_status": return try status()
            case "latchkey_list": return try list(args)
            case "latchkey_check": return try check(args)
            case "latchkey_run": return try run(args, id: id)
            case "latchkey_request_grant": return try requestGrant(args)
            case "latchkey_project": return try project(args)
            case "latchkey_export_references": return try exportReferences(args)
            default: return .error(-32602, "unknown tool: \(name)")
            }
        } catch {
            let (text, detail) = Self.describe(error, folder: (try? folder(args)) ?? home)
            return Self.toolResult(text, detail, isError: true)
        }
    }

    private func status() throws -> Outcome {
        let r = try ask(Request(op: "status"))
        let info = r.info ?? [:]
        return Self.toolResult(info.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"), info)
    }

    private func list(_ args: [String: Any]) throws -> Outcome {
        let project = args["project"] as? String
        let environment = args["environment"] as? String
        let items = (try ask(Request(op: "list")).secrets ?? []).filter { i in
            (project == nil || i.ref.project == project) && (environment == nil || i.ref.environment == environment)
        }
        let lines = items.map { i in
            "\(i.name)  \(i.kind.rawValue)\(i.agentSafe ? ", agent-safe" : "")\(i.service.map { "  \($0)" } ?? "")"
        }
        return Self.toolResult(lines.isEmpty ? "No items." : lines.joined(separator: "\n"), ["items": Self.json(items)])
    }

    private func check(_ args: [String: Any]) throws -> Outcome {
        var cli = ["check", "--json"] + (try sourceArguments(args))
        let ids = Self.strings(args["ids"])
        if !ids.isEmpty { cli.append(ids.joined(separator: ",")) }
        let command = Self.strings(args["command"])
        if !command.isEmpty { cli += ["--"] + command }
        let result = try latchkey(cli, in: try folder(args), timeout: 60, id: nil)
        guard result.code == 0 || result.code == 66, let data = result.stdout.text.data(using: .utf8),
              var detail = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Self.failure(result)
        }
        func list(_ key: String) -> [String] { detail[key] as? [String] ?? [] }
        let runsWithoutAsking = list("needsApproval").isEmpty && list("missing").isEmpty
        detail["runsWithoutAsking"] = runsWithoutAsking
        var lines: [String] = []
        for (label, key) in [("agent-safe", "agentSafe"), ("granted", "granted"),        ("will ask the owner", "needsApproval"), ("missing", "missing")] where !list(key).isEmpty {
            lines.append("\(label): \(list(key).joined(separator: ", "))")
        }
        lines.append(runsWithoutAsking ? "latchkey_run would start without asking." :
                        list("missing").isEmpty ? "latchkey_run would ask the owner first." : "latchkey_run would fail: items are missing.")
        return Self.toolResult(lines.joined(separator: "\n"), detail)
    }

    private func run(_ args: [String: Any], id: String) throws -> Outcome {
        let command = Self.strings(args["command"])
        guard !command.isEmpty else { throw RunError.usage("command is required: an array such as [\"npm\", \"test\"]") }
        let timeout = min(max(args["timeout_seconds"] as? Double ?? Self.defaultTimeout, 1), Self.longestTimeout)
        var options: [String] = args["proxy"] as? Bool == true ? ["--proxy"] : []
        let models = Self.strings(args["proxy_models"])
        if !models.isEmpty { options += ["--proxy-models", models.joined(separator: ",")] }
        if let requests = args["proxy_requests"] as? Int { options += ["--proxy-requests", String(requests)] }
        if let role = args["aws_role"] as? String, !role.isEmpty { options += ["--aws-role", role] }
        else if args["aws_session"] as? Bool == true { options.append("--aws-session") }
        let cli = ["run"] + options + (try sourceArguments(args)) + ["--"] + command
        let result = try latchkey(cli, in: try folder(args), timeout: timeout, id: id)
        // latchkey's own refusals end the run before the command starts, with a latchkey: line on standard error.
        if [64, 66, 69, 77].contains(result.code), result.stderr.text.hasPrefix("latchkey: ") { throw Self.failure(result) }
        let out = result.stdout, err = result.stderr
        var text = "exit code \(result.code)"
        if result.timedOut { text += " (stopped after \(Int(timeout)) seconds)" }
        if !out.text.isEmpty { text += "\n--- stdout\(out.truncated ? " (last \(Self.outputCap / 1024) KB)" : "") ---\n" + out.text }
        if !err.text.isEmpty { text += "\n--- stderr\(err.truncated ? " (last \(Self.outputCap / 1024) KB)" : "") ---\n" + err.text }
        return Self.toolResult(text, [
            "exitCode": Int(result.code), "timedOut": result.timedOut,
            "stdout": out.text, "stdoutTruncated": out.truncated,
            "stderr": err.text, "stderrTruncated": err.truncated,
        ])
    }

    private func requestGrant(_ args: [String: Any]) throws -> Outcome {
        let ids = Self.strings(args["ids"])
        guard !ids.isEmpty else { throw RunError.usage("ids is required: item IDs or project/environment/* patterns") }
        let duration = args["duration"] as? String ?? "1h"
        guard GrantStore.parseDuration(duration) != nil else { throw RunError.usage("duration is like 30m, 2h or 1d") }
        let result = try latchkey(["grant", ids.joined(separator: ","), "--for", duration, "--session", "--json"], in: try folder(args),
                                  timeout: Self.longestTimeout, id: nil)
        guard result.code == 0, let data = result.stdout.text.data(using: .utf8),
              let g = try? Wire.decoder().decode(Grant.self, from: data) else { throw Self.failure(result) }
        let left = GrantStore.describe(g.expires.timeIntervalSince(g.created))
        let summary = "Granted \(g.names.joined(separator: ", ")) to programs in \(Broker.tilde(g.folder))\(g.repo == nil ? "" : " and its worktrees") for \(left) (grant \(g.id))."
        return Self.toolResult(summary, ["grant": Self.json(g)])
    }

    /// Which project this folder's checkout is, from its Git remotes, and its environments.
    private func project(_ args: [String: Any]) throws -> Outcome {
        let result = try latchkey(["project"], in: try folder(args), timeout: 60, id: nil)
        guard result.code == 0 else { throw Self.failure(result) }
        return Self.toolResult(result.stdout.text, ["output": result.stdout.text])
    }

    /// Writes an environment's env file with latchkey:// references and plain settings only: never values.
    private func exportReferences(_ args: [String: Any]) throws -> Outcome {
        guard let scope = args["environment"] as? String, RemoteLink.isValidScope(scope) else {
            throw RunError.usage("environment is required: PROJECT/ENV, such as shop/development")
        }
        let file = args["file"] as? String ?? ".env.local"
        let cli = ["export", scope, "--out", file] + (args["replace"] as? Bool == true ? ["--replace"] : [])
        let result = try latchkey(cli, in: try folder(args), timeout: 60, id: nil)
        guard result.code == 0 else { throw Self.failure(result) }
        let text = [result.stdout.text, result.stderr.text].filter { !$0.isEmpty }.joined(separator: "\n")
        return Self.toolResult(text, ["output": text])
    }

    // MARK: running the latchkey tool for an agent

    struct ToolRun {
        var code: Int32
        var stdout: (text: String, truncated: Bool)
        var stderr: (text: String, truncated: Bool)
        var timedOut: Bool
    }

    /// Runs this `latchkey` binary with `arguments` in `folder`, marked as an agent's (LATCHKEY_ORIGIN=mcp). The app
    /// then judges a real process in the real folder: its own signed tool, its own command line. `latchkey run`
    /// masks the command's output itself.
    private func latchkey(_ arguments: [String], in folder: String, timeout: TimeInterval, id: String?) throws -> ToolRun {
        guard let me = Bundle.main.executablePath else { throw RunError.failed("can't find the latchkey tool") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: me)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["LATCHKEY_ORIGIN"] = "mcp"
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let stdout = Tail(cap: Self.outputCap), stderr = Tail(cap: Self.outputCap)
        let pumps = DispatchGroup()
        do { try process.run() } catch { throw RunError.failed("cannot start latchkey: \(error.localizedDescription)") }
        if let id { runLock.lock(); running[id] = process; runLock.unlock() }
        defer { if let id { runLock.lock(); running[id] = nil; runLock.unlock() } }
        pumpMasked(outPipe, secrets: [], group: pumps) { stdout.add($0) }
        pumpMasked(errPipe, secrets: [], group: pumps) { stderr.add($0) }

        let timedOut = Flag()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
        process.waitUntilExit()
        // A program that left a child holding its output open shouldn't keep the tool waiting.
        if pumps.wait(timeout: .now() + 5) == .timedOut {
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
        }
        let code = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
        return ToolRun(code: code, stdout: stdout.text, stderr: stderr.text, timedOut: timedOut.isSet)
    }

    /// The error for a latchkey run that stopped on its own account, from its exit code and its `latchkey:` message
    /// (the wording of failMissing and failRefused in main.swift).
    static func failure(_ run: ToolRun) -> RunError {
        let message = run.stderr.text.split(separator: "\n").first.map(String.init) ?? ""
        let text = message.hasPrefix("latchkey: ") ? String(message.dropFirst(10)) : message
        func ids(after prefix: String, until end: String?) -> [String] {
            guard text.hasPrefix(prefix) else { return [] }
            var rest = text.dropFirst(prefix.count)
            if let end, let r = rest.range(of: end) { rest = rest[..<r.lowerBound] }
            return rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        switch run.code {
        case 77: return .refused(ids(after: "refused: ", until: " ("))
        case 66:
            let missing = ids(after: "no item named: ", until: nil)
            return missing.isEmpty ? .unreadable(text) : .missing(missing)
        case 69: return .unreachable(text)
        case 64: return .usage(text)
        default: return .failed(text.isEmpty ? "latchkey exited with \(run.code)" : text)
        }
    }

    // MARK: helpers

    /// The folder a tool works in: `cwd` if given (absolute, or starting with ~), else where the server started.
    private func folder(_ args: [String: Any]) throws -> String {
        guard let given = args["cwd"] as? String, !given.isEmpty else { return home }
        let path = (given as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw RunError.usage("cwd must be an absolute path to a folder: \(given)")
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// env_files, environments and files as `latchkey run` / `latchkey check` options.
    private func sourceArguments(_ args: [String: Any]) throws -> [String] {
        var out: [String] = []
        for f in Self.strings(args["env_files"]) { out += ["--env-file", f] }
        for e in Self.strings(args["environments"]) {
            guard RemoteLink.isValidScope(e) else { throw RunError.usage("environments are project/environment, such as shop/development: \(e)") }
            out += ["--env", e]
        }
        for (name, id) in (args["files"] as? [String: String] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard Wire.isValidName(id), !name.isEmpty, !name.contains("=") else {
                throw RunError.usage("files maps a variable name to an item ID: \(name)=\(id)")
            }
            out += ["--file", "\(name)=\(id)"]
        }
        return out
    }

    private func ask(_ request: Request) throws -> Response {
        let r = try call(request)
        guard r.ok else { throw RunError.failed(r.error ?? "the app refused the request") }
        return r
    }

    static func strings(_ v: Any?) -> [String] {
        if let a = v as? [String] { return a }
        if let s = v as? String, !s.isEmpty { return [s] }
        return []
    }

    static func json<T: Encodable>(_ value: T) -> Any {
        guard let data = try? Wire.encoder().encode(value) else { return NSNull() }
        return (try? JSONSerialization.jsonObject(with: data)) ?? NSNull()
    }

    static func toolResult(_ text: String, _ detail: [String: Any], isError: Bool = false) -> Outcome {
        .result(["content": [["type": "text", "text": text]], "structuredContent": detail, "isError": isError])
    }

    /// The message an agent sees when a tool can't go ahead, with what to do next.
    static func describe(_ error: Error, folder: String) -> (String, [String: Any]) {
        switch error as? RunError {
        case .refused(let ids):
            let grant = "latchkey grant \(ids.joined(separator: ",")) --folder \(Broker.tilde(folder)) --for 2h"
            return ("Refused: \(ids.joined(separator: ", ")) (not agent-safe, not approved, no grant). Ask the owner to approve it when Latchkey asks, or to run `\(grant)`. You can ask once with latchkey_request_grant. Don't retry the same command.",
                    ["error": "refused", "ids": ids, "grantCommand": grant])
        case .missing(let ids):
            return ("No item named: \(ids.joined(separator: ", ")). Ask the owner to add it in Latchkey or check the name. Don't retry.",
                    ["error": "missing", "ids": ids])
        case .unreachable(let m):
            return (m + " Ask the owner to open Latchkey.", ["error": "unreachable"])
        case .usage(let m): return (m, ["error": "usage"])
        case .unreadable(let m): return (m, ["error": "unreadable"])
        case .failed(let m): return (m, ["error": "failed"])
        case nil: return ("\(error)", ["error": "failed"])
        }
    }

    static let instructions = """
    Latchkey keeps this person's secrets (API keys, database URLs) in iCloud Keychain. There is no direct secret-read tool. Child output masks exact secret values, but transformed values can still leak; never print or encode secrets. \
    Env files hold latchkey:// references instead of values. To run a command that needs secrets, call \
    latchkey_run; the values reach the command, and its output is masked. Call latchkey_check first to see whether \
    it would start without asking. If the owner refuses or an item is missing, stop and tell them; you may ask once \
    with latchkey_request_grant. Never try to read values another way.
    """

    // MARK: tool definitions

    private static let cwdProperty: [String: Any] = [
        "type": "string",
        "description": "Absolute path of the folder the command runs in (grants are matched against it). Defaults to the folder the server started in.",
    ]
    private static let sourceProperties: [String: Any] = [
        "cwd": cwdProperty,
        "env_files": ["type": "array", "items": ["type": "string"],
                      "description": "Env files to load first, relative to cwd, such as [\".env.local\"]. Their latchkey:// references are filled in."],
        "environments": ["type": "array", "items": ["type": "string"],
                         "description": "Latchkey environments to load without a file, as project/environment, such as [\"shop/development\"]."],
        "files": ["type": "object", "additionalProperties": ["type": "string"],
                  "description": "Variables to set to the path of a temporary file holding an item's value, as {\"NAME\": \"project/environment/ITEM\"}."],
    ]

    static let tools: [[String: Any]] = [
        [
            "name": "latchkey_status",
            "title": "Latchkey status",
            "description": "Where Latchkey keeps values, how the owner approves, and how many items and grants there are.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "latchkey_list",
            "title": "List items",
            "description": "Item IDs with their kind, service and whether agents may read them without asking. Never values.",
            "inputSchema": ["type": "object", "properties": [
                "project": ["type": "string", "description": "Only this project."],
                "environment": ["type": "string", "description": "Only this environment, such as development."],
            ]],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "latchkey_check",
            "title": "Check before running",
            "description": "What latchkey_run with the same options would get without asking (agent-safe or granted), what would ask the owner, and what's missing. Asks nothing and releases nothing.",
            "inputSchema": ["type": "object", "properties": sourceProperties.merging([
                "ids": ["type": "array", "items": ["type": "string"], "description": "More item IDs to check."],
                "command": ["type": "array", "items": ["type": "string"],
                            "description": "The command you mean to run, to count grants limited to it."],
            ]) { a, _ in a }],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "latchkey_run",
            "title": "Run with secrets",
            "description": "Run a command with latchkey:// references in its environment filled in. Returns the exit code and the command's output, with secret values replaced by <concealed by latchkey> and only the last 64 KB of each stream kept. Items that aren't agent-safe or granted ask the owner first. For tests, builds and scripts that finish; not for dev servers. Standard input is empty.",
            "inputSchema": ["type": "object", "required": ["command"], "properties": sourceProperties.merging([
                "command": ["type": "array", "items": ["type": "string"], "minItems": 1,
                            "description": "The program and its arguments, such as [\"npm\", \"test\"]. Use [\"sh\", \"-c\", \"...\"] for pipes."],
                "proxy": ["type": "boolean",
                          "description": "Keep OPENAI_API_KEY and ANTHROPIC_API_KEY out of the command: it gets a placeholder and a local base URL, and Latchkey adds the real key on requests to the provider. For programs using the OpenAI or Anthropic SDKs."],
                "proxy_models": ["type": "array", "items": ["type": "string"], "minItems": 1,
                                 "description": "With proxy: only let the command use these models. A request that doesn't name one in its JSON body is refused."],
                "proxy_requests": ["type": "integer", "minimum": 1,
                                   "description": "With proxy: stop forwarding after this many requests."],
                "aws_session": ["type": "boolean",
                                "description": "Give the command short-lived AWS credentials (15 minutes) from STS instead of the long-lived key."],
                "aws_role": ["type": "string", "description": "Like aws_session, but assume this role ARN."],
                "timeout_seconds": ["type": "number", "minimum": 1, "maximum": longestTimeout,
                                    "description": "Stop the command after this long. Default 600, at most 3600."],
            ]) { a, _ in a }],
            "annotations": ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": true],
        ],
        [
            "name": "latchkey_project",
            "title": "Which project is this",
            "description": "Which Latchkey project this folder's Git checkout is, from its remotes, and that project's environments. A match only names the project; it releases nothing. A match through a remote other than origin (as a fork has) is flagged.",
            "inputSchema": ["type": "object", "properties": ["cwd": cwdProperty]],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "latchkey_export_references",
            "title": "Write an env file of references",
            "description": "Write an environment's env file from its Latchkey record, for a fresh checkout or worktree: latchkey:// references and plain settings such as PORT, never secret values. Run commands with it through latchkey_run (env_files). An existing file is left alone unless replace is true.",
            "inputSchema": ["type": "object", "required": ["environment"], "properties": [
                "environment": ["type": "string", "description": "PROJECT/ENV, such as shop/development (see latchkey_project)."],
                "file": ["type": "string", "description": "Where to write it, relative to cwd. Default .env.local."],
                "replace": ["type": "boolean", "description": "Replace an existing file."],
                "cwd": cwdProperty,
            ]],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false],
        ],
        [
            "name": "latchkey_request_grant",
            "title": "Ask for a grant",
            "description": "Ask the owner to let commands in this folder (and its repository's worktrees) read these items without asking, until your session ends or the time is up. The owner sees the request marked as coming from an agent and decides. Production items and whole projects can't be requested; at most 1 day. Ask once; don't repeat a refused request.",
            "inputSchema": ["type": "object", "required": ["ids"], "properties": [
                "ids": ["type": "array", "items": ["type": "string"], "minItems": 1,
                        "description": "Item IDs or project/environment/* patterns, such as [\"shop/development/*\"]."],
                "duration": ["type": "string", "description": "How long, such as 30m, 2h or 1d. Default 1h."],
                "cwd": cwdProperty,
            ]],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false],
        ],
    ]
}

/// The last `cap` bytes of a stream, and whether anything before them was dropped.
final class Tail: @unchecked Sendable {
    private let cap: Int
    private let lock = NSLock()
    private var data = Data()
    private var total = 0

    init(cap: Int) { self.cap = cap }

    func add(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        total += chunk.count
        data.append(chunk)
        if data.count > cap * 2 { data = data.suffix(cap) }
    }

    var text: (text: String, truncated: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: data.suffix(cap), as: UTF8.self), total > cap)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
