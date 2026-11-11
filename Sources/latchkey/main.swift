import Darwin
import Foundation
import LatchkeyCore

let usage = """
latchkey: read secrets from the Latchkey app without keeping them in files.

  latchkey run [--env-file FILE]... [--no-masking] -- COMMAND [ARGS...]
      Start COMMAND with every latchkey://NAME in its environment replaced by the real value.
      Secret values printed by COMMAND are concealed unless --no-masking is given.
  latchkey list [--json]          Names, kinds and whether agents may read them. Never values.
  latchkey get NAME               Print one value.
  latchkey set NAME [--kind token|password|key|value] [--agent-safe] [--note TEXT]
      Value is read from standard input, or prompted for when run in a terminal.
  latchkey rm NAME
  latchkey status

Items not marked agent-safe need your approval in the app (Touch ID). Changes always do.
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("latchkey: " + message + "\n").utf8))
    exit(code)
}

func send(_ request: Request) -> Response {
    do {
        let r = try BrokerClient.send(request)
        if !r.ok { fail(r.error ?? "the app refused the request") }
        return r
    } catch let e as SocketError {
        fail("cannot reach the Latchkey app (\(e)). Open Latchkey and try again.", code: 69)
    } catch {
        fail("\(error)")
    }
}

func currentDirectory() -> String { FileManager.default.currentDirectoryPath }

func readValue(prompt: String) -> String {
    if isatty(STDIN_FILENO) == 1 {
        guard let p = getpass(prompt) else { fail("no value given") }
        return String(cString: p)
    }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    var text = String(decoding: data, as: UTF8.self)
    if text.hasSuffix("\n") { text.removeLast() }
    return text
}

// MARK: - run

nonisolated(unsafe) var childPID: pid_t = 0

func runCommand(_ input: [String]) -> Never {
    var envFiles: [String] = []
    var masking = true
    var rest = input
    var cmd: [String] = []
    while !rest.isEmpty {
        let a = rest.removeFirst()
        if a == "--" { cmd = rest; break }
        switch a {
        case "--env-file":
            guard !rest.isEmpty else { fail("--env-file takes a path", code: 64) }
            envFiles.append(rest.removeFirst())
        case "--no-masking": masking = false
        default:
            if a.hasPrefix("--env-file=") { envFiles.append(String(a.dropFirst(11))) }
            else if a.hasPrefix("-") { fail("unknown option \(a)", code: 64) }
            else { cmd = [a] + rest; rest = [] }
        }
    }
    guard !cmd.isEmpty else { fail("usage: latchkey run [--env-file FILE] -- COMMAND [ARGS...]", code: 64) }

    var env = ProcessInfo.processInfo.environment
    for path in envFiles {
        do { for (k, v) in try EnvFile.load(path) { env[k] = v } }
        catch { fail("cannot read \(path): \(error.localizedDescription)", code: 66) }
    }

    let names = References.names(in: env)
    var secretValues: [String] = []
    if !names.isEmpty {
        let r = send(Request(op: "get", names: names, cwd: currentDirectory(), command: cmd.joined(separator: " ")))
        if let m = r.missing, !m.isEmpty { fail("no item named: \(m.joined(separator: ", "))", code: 66) }
        if let d = r.denied, !d.isEmpty {
            fail("refused: \(d.joined(separator: ", ")) (not marked agent-safe, and not approved in the app)", code: 77)
        }
        let values = r.values ?? [:]
        env = References.resolve(env: env, with: values)
        let masked = Set(r.masked ?? names)
        secretValues = values.filter { masked.contains($0.key) }.map(\.value)
    }

    if !masking || secretValues.isEmpty {
        for (k, v) in env { setenv(k, v, 1) }
        var argv: [UnsafeMutablePointer<CChar>?] = cmd.map { strdup($0) }
        argv.append(nil)
        execvp(cmd[0], &argv)
        fail("cannot start \(cmd[0]): \(String(cString: strerror(errno)))", code: 127)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = cmd
    process.environment = env
    let outPipe = Pipe(), errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    process.standardInput = FileHandle.standardInput

    let lock = NSLock()
    let group = DispatchGroup()
    func pump(_ pipe: Pipe, to target: FileHandle) {
        group.enter()
        DispatchQueue.global().async {
            var masker = Masker(secrets: secretValues)
            let handle = pipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                let out = masker.feed(chunk)
                if !out.isEmpty { lock.lock(); target.write(out); lock.unlock() }
            }
            let tail = masker.flush()
            if !tail.isEmpty { lock.lock(); target.write(tail); lock.unlock() }
            group.leave()
        }
    }

    signal(SIGTERM) { _ in if childPID > 0 { kill(childPID, SIGTERM) } }
    signal(SIGHUP) { _ in if childPID > 0 { kill(childPID, SIGHUP) } }
    signal(SIGINT) { _ in }   // the terminal already sent it to the child; wait for the child to finish

    do { try process.run() } catch { fail("cannot start \(cmd[0]): \(error.localizedDescription)", code: 127) }
    childPID = process.processIdentifier
    pump(outPipe, to: FileHandle.standardOutput)
    pump(errPipe, to: FileHandle.standardError)
    process.waitUntilExit()
    group.wait()
    if process.terminationReason == .uncaughtSignal { exit(128 + process.terminationStatus) }
    exit(process.terminationStatus)
}

// MARK: - commands

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(0)
}
args.removeFirst()

switch command {
case "help", "--help", "-h":
    print(usage)

case "status":
    let r = send(Request(op: "status"))
    for (k, v) in (r.info ?? [:]).sorted(by: { $0.key < $1.key }) { print("\(k): \(v)") }

case "list":
    let r = send(Request(op: "list"))
    let items = r.secrets ?? []
    if args.contains("--json") {
        let enc = Wire.encoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try! enc.encode(items), as: UTF8.self))
    } else if items.isEmpty {
        print("No items yet. Add one in the app or with `latchkey set NAME`.")
    } else {
        let width = max(4, items.map(\.name.count).max() ?? 4)
        for i in items.sorted(by: { $0.name < $1.name }) {
            let name = i.name.padding(toLength: width, withPad: " ", startingAt: 0)
            let kind = i.kind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
            print("\(name)  \(kind)  \(i.agentSafe ? "agents: yes" : "agents: no ")  \(i.note)")
        }
    }

case "get":
    guard let name = args.first, Wire.isValidName(name) else { fail("usage: latchkey get NAME", code: 64) }
    let r = send(Request(op: "get", names: [name], cwd: currentDirectory()))
    if let m = r.missing, !m.isEmpty { fail("no item named \(name)", code: 66) }
    if let d = r.denied, !d.isEmpty { fail("refused: \(name) is not marked agent-safe and was not approved", code: 77) }
    guard let v = r.values?[name] else { fail("no value returned") }
    print(v)

case "set":
    guard let name = args.first, Wire.isValidName(name) else {
        fail("usage: latchkey set NAME [--kind KIND] [--agent-safe] [--note TEXT]   (letters, digits, _ - . only)", code: 64)
    }
    var kind: ItemKind? = nil
    var agentSafe: Bool? = nil
    var note: String? = nil
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--agent-safe": agentSafe = true
        case "--kind":
            i += 1
            guard i < args.count, let k = ItemKind(rawValue: args[i]) else { fail("--kind takes token, password, key or value", code: 64) }
            kind = k
        case "--note":
            i += 1
            guard i < args.count else { fail("--note takes text", code: 64) }
            note = args[i]
        default: fail("unknown option \(args[i])", code: 64)
        }
        i += 1
    }
    let value = readValue(prompt: "Value for \(name): ")
    guard !value.isEmpty else { fail("empty value; nothing saved") }
    _ = send(Request(op: "set", names: [name], value: value, kind: kind, agentSafe: agentSafe, note: note, cwd: currentDirectory()))
    print("saved \(name)")

case "rm":
    guard let name = args.first, Wire.isValidName(name) else { fail("usage: latchkey rm NAME", code: 64) }
    _ = send(Request(op: "rm", names: [name], cwd: currentDirectory()))
    print("removed \(name)")

case "run":
    runCommand(args)

default:
    fail("unknown command \(command). Try `latchkey help`.", code: 64)
}
