import AppKit
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
  latchkey import FILE [--rewrite] [--replace] [--dry-run] [--only NAME,...]
                  [--kind KIND | --kind NAME=KIND]... [--agent-safe NAME,...|all]
      Add every KEY=VALUE in a .env file with one approval. Prints names, never values.
      --rewrite replaces each imported value in FILE with latchkey://KEY.
      Existing items are left alone unless --replace is given.
  latchkey grant NAME[,NAME...] [--folder DIR] [--for 2h]
      Let commands run from DIR (default: here) and the folders inside it read these items
      without asking, until the time is up (30m, 2h, 1d; at most 7d). Asks for approval once.
  latchkey grants                 Grants that are in effect.
  latchkey revoke ID|all
  latchkey status

Items not marked agent-safe need your approval (Touch ID, Apple Watch or your Mac password).
Changes always do. Values are kept in iCloud Keychain, so they follow you to your other Macs.
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("latchkey: " + message + "\n").utf8))
    exit(code)
}

func appAnswers(within seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if let fd = try? UnixSocket.connect(Paths.socket) { close(fd); return true }
        usleep(150_000)
    } while Date() < deadline
    return false
}

/// Starts Latchkey hidden and waits for it to answer. False if it isn't installed or doesn't answer.
/// Launching is the last resort: a launch request that lands while the app is already starting ends that
/// launch, so first give a starting copy a moment, and never launch while one is listed as running.
func launchApp() -> Bool {
    if ProcessInfo.processInfo.environment["LATCHKEY_NO_LAUNCH"] == "1" { return false }
    let bundleID = "io.latchkey.Latchkey"
    if appAnswers(within: 1.5) { return true }
    if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
        return appAnswers(within: 10)
    }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
    FileHandle.standardError.write(Data("latchkey: starting the Latchkey app…\n".utf8))
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    config.hides = true
    config.addsToRecentItems = false
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in done.signal() }
    _ = done.wait(timeout: .now() + 10)
    return appAnswers(within: 10)
}

func send(_ request: Request) -> Response {
    var launched = false
    var retries = 0
    while true {
        do {
            let r = try BrokerClient.send(request)
            if !r.ok { fail(r.error ?? "the app refused the request") }
            return r
        } catch let e as SocketError {
            if case .sys(let what, _) = e, what == "connect", !launched, launchApp() {
                launched = true
                continue
            }
            // A copy that is just starting or just quitting can drop the connection; give it a moment.
            if case .closed = e, retries < 3 {
                retries += 1
                usleep(500_000)
                continue
            }
            fail("cannot reach the Latchkey app (\(e)). Open Latchkey and try again.", code: 69)
        } catch {
            fail("\(error)")
        }
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

// MARK: - import

func importCommand(_ input: [String]) -> Never {
    var file: String?
    var rewrite = false, replace = false, dryRun = false
    var only: Set<String>?
    var defaultKind = ItemKind.token
    var kinds: [String: ItemKind] = [:]
    var agentSafe: Set<String> = []
    var allAgentSafe = false
    var rest = input
    func names(_ s: String) -> Set<String> { Set(s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
    while !rest.isEmpty {
        let a = rest.removeFirst()
        switch a {
        case "--rewrite": rewrite = true
        case "--replace": replace = true
        case "--dry-run": dryRun = true
        case "--only":
            guard !rest.isEmpty else { fail("--only takes NAME,NAME", code: 64) }
            only = names(rest.removeFirst())
        case "--agent-safe":
            guard !rest.isEmpty else { fail("--agent-safe takes NAME,NAME or all", code: 64) }
            let v = rest.removeFirst()
            if v == "all" { allAgentSafe = true } else { agentSafe.formUnion(names(v)) }
        case "--kind":
            guard !rest.isEmpty else { fail("--kind takes KIND or NAME=KIND", code: 64) }
            let v = rest.removeFirst()
            if let eq = v.firstIndex(of: "=") {
                guard let k = ItemKind(rawValue: String(v[v.index(after: eq)...])) else {
                    fail("--kind takes token, password, key or value", code: 64)
                }
                kinds[String(v[..<eq])] = k
            } else {
                guard let k = ItemKind(rawValue: v) else { fail("--kind takes token, password, key or value", code: 64) }
                defaultKind = k
            }
        default:
            if a.hasPrefix("-") || file != nil { fail("usage: latchkey import FILE [options]   (see latchkey help)", code: 64) }
            file = a
        }
    }
    guard let file else { fail("usage: latchkey import FILE [options]   (see latchkey help)", code: 64) }
    let url = URL(fileURLWithPath: file).standardizedFileURL
    let text: String
    do { text = try String(contentsOf: url, encoding: .utf8) }
    catch { fail("cannot read \(file): \(error.localizedDescription)", code: 66) }

    let plan = EnvImport.plan(text, source: url.lastPathComponent, only: only, defaultKind: defaultKind,
                              kinds: kinds, agentSafe: agentSafe, allAgentSafe: allAgentSafe)
    let items = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.name, $0) })
    let ignored = plan.ignored
    if let only {
        let unknown = only.subtracting(items.keys).subtracting(ignored.keys)
        if !unknown.isEmpty { fail("not in \(file): \(unknown.sorted().joined(separator: ", "))", code: 66) }
    }
    for name in Set(kinds.keys).union(agentSafe) where items[name] == nil && ignored[name] == nil {
        fail("\(name) is named in an option but is not in \(file)", code: 64)
    }
    for (name, why) in ignored.sorted(by: { $0.key < $1.key }) { print("ignore   \(name)  (\(why))") }
    guard !items.isEmpty else { print("Nothing to import."); exit(0) }

    func describe(_ i: ImportItem) -> String {
        "\(i.name)  \(i.kind!.rawValue)\(i.agentSafe == true ? ", agent-safe" : "")"
    }

    if dryRun {
        let existing = Set((send(Request(op: "list")).secrets ?? []).map(\.name))
        for i in items.values.sorted(by: { $0.name < $1.name }) {
            let action = !existing.contains(i.name) ? "add     " : (replace ? "replace " : "skip    ")
            print("\(action) \(describe(i))\(action == "skip    " ? "  (exists; --replace to overwrite)" : "")")
        }
        if rewrite { print("(would rewrite \(file) for the items added or replaced)") }
        exit(0)
    }

    let r = send(Request(op: "import", cwd: currentDirectory(), command: "latchkey import \(file)",
                         items: items.values.sorted { $0.name < $1.name }, replace: replace, source: url.path))
    for n in r.added ?? [] { print("added    \(describe(items[n]!))") }
    for n in r.replaced ?? [] { print("replaced \(describe(items[n]!))") }
    for n in r.skipped ?? [] { print("skipped  \(n)  (exists; --replace to overwrite)") }

    let saved = Set((r.added ?? []) + (r.replaced ?? []))
    if rewrite && !saved.isEmpty {
        do {
            try EnvFile.rewriteFile(at: url, original: text, toReferences: saved)
            print("rewrote \(file): \(saved.count) value\(saved.count == 1 ? "" : "s") now latchkey://NAME")
        } catch {
            fail("items were saved, but \(file) could not be rewritten: \(error.localizedDescription)", code: 73)
        }
    }
    exit(0)
}

// MARK: - grants

func relative(_ d: Date) -> String {
    let left = d.timeIntervalSinceNow
    return left < 90 ? "under 2 minutes" : GrantStore.describe(left)
}

func printGrants(_ grants: [Grant]) {
    guard !grants.isEmpty else { print("No grants in effect."); return }
    for g in grants {
        print("\(g.id)  \(Broker.tilde(g.folder))  \(g.names.joined(separator: ", "))  (\(relative(g.expires)) left)")
    }
}

func grantCommand(_ input: [String]) -> Never {
    var names: [String] = []
    var folder: String?
    var duration: TimeInterval = 3600
    var rest = input
    while !rest.isEmpty {
        let a = rest.removeFirst()
        switch a {
        case "--folder":
            guard !rest.isEmpty else { fail("--folder takes a path", code: 64) }
            folder = URL(fileURLWithPath: rest.removeFirst()).standardizedFileURL.path
        case "--for":
            guard !rest.isEmpty, let d = GrantStore.parseDuration(rest.removeFirst()) else {
                fail("--for takes a time such as 30m, 2h or 1d", code: 64)
            }
            duration = d
        default:
            if a.hasPrefix("-") { fail("unknown option \(a)", code: 64) }
            names += a.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }
    guard !names.isEmpty, names.allSatisfy(Wire.isValidName) else {
        fail("usage: latchkey grant NAME[,NAME...] [--folder DIR] [--for 2h]", code: 64)
    }
    if duration > GrantStore.longest { fail("the longest grant is 7 days", code: 64) }
    let r = send(Request(op: "grant", names: names, cwd: currentDirectory(), folder: folder ?? currentDirectory(), duration: duration))
    if let m = r.missing, !m.isEmpty { fail("no item named: \(m.joined(separator: ", "))", code: 66) }
    for g in r.grants ?? [] {
        print("granted \(g.id): \(g.names.joined(separator: ", ")) readable from \(Broker.tilde(g.folder)) for \(GrantStore.describe(duration))")
    }
    exit(0)
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
    let r = send(Request(op: "rm", names: [name], cwd: currentDirectory()))
    if let m = r.missing, !m.isEmpty { fail("no item named \(name)", code: 66) }
    print("removed \(name)")

case "run":
    runCommand(args)

case "import":
    importCommand(args)

case "grant":
    grantCommand(args)

case "grants":
    printGrants(send(Request(op: "grants")).grants ?? [])

case "revoke":
    guard let id = args.first else { fail("usage: latchkey revoke ID|all", code: 64) }
    let r = send(Request(op: "revoke", names: [id]))
    if let m = r.missing, !m.isEmpty { fail("no grant \(id)", code: 66) }
    print("revoked \(r.info?["revoked"] ?? "0") grant(s)")

default:
    fail("unknown command \(command). Try `latchkey help`.", code: 64)
}
