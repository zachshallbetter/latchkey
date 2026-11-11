import AppKit
import Darwin
import Foundation
import LatchkeyCore

let usage = """
latchkey: read secrets from the Latchkey app without keeping them in files.

Items are shared (ID = NAME) or belong to a project's environment (ID = project/environment/NAME).
Files refer to them as latchkey://ID.

  latchkey run [--env-file FILE]... [--env PROJECT/ENV]... [--file NAME=ID]... [--no-masking] [--proxy] -- COMMAND [ARGS...]
      Start COMMAND with every latchkey://ID in its environment replaced by the real value.
      --env loads an environment's items without any file (each as its NAME), plus the shared items that
      environment's files use. --file NAME=ID (or NAME=latchkey-file://ID in an env file) gives COMMAND the
      path of a temporary file holding the value, readable only by you and deleted when COMMAND exits.
      Secret values printed by COMMAND are concealed unless --no-masking is given.
      --proxy keeps OPENAI_API_KEY and ANTHROPIC_API_KEY out of COMMAND: it gets a placeholder and a local
      OPENAI_BASE_URL / ANTHROPIC_BASE_URL, and latchkey puts the real key on requests to the provider only.
      --aws-session (or --aws-role ARN) gives COMMAND short-lived AWS credentials from STS instead of the long-lived
      key; --aws-for sets how long they last (default 15m, at most 12h).
  latchkey check [--env-file FILE]... [--env PROJECT/ENV]... [--file NAME=ID]... [ID,...] [--json] [-- COMMAND...]
      What `latchkey run` with the same options would get without asking (agent-safe or granted), what would ask, and what's missing. Asks nothing and releases nothing. Give the COMMAND to
      count grants limited to it.
  latchkey mcp                    Serve Latchkey's tools to an agent over MCP (standard input and output).
  latchkey list [--project P] [--json]   IDs, kinds and whether agents may read them. Never values.
  latchkey get ID                 Print one value.
  latchkey set ID [--kind token|password|key|value] [--agent-safe] [--note TEXT] [--service NAME]
      Value is read from standard input, or prompted for when run in a terminal.
  latchkey rm ID[,ID...]|PATTERN...
      Delete items with one approval. PATTERN is PROJECT/* or PROJECT/ENV/*.
  latchkey update ID[,ID...]|PATTERN... [--agent-safe yes|no] [--kind KIND] [--service NAME] [--note TEXT]
                                          [--fill-sites HOST,HOST... | --fill-sites ""]
      Change settings on many items with one approval. Values are untouched.
  latchkey import FILE... [--batch LIST] [--scan DIR] [--project P] [--env E | --shared] [--share-identical]
                  [--rewrite] [--replace] [--dry-run] [--only KEY,...] [--kind KIND | --kind KEY=KIND]...
                  [--agent-safe KEY,...|all] [--agent-safe-pattern PATTERN,...] [--skip PATTERN,...]
                  [--no-default-skip]
      Add every KEY=VALUE in a .env file with one approval. Prints IDs, never values.
      The project defaults to the repository's folder name and the environment to what the file
      name says (.env and .env.local: development; .env.production: production). --shared
      imports them as shared items named after their keys.
      --rewrite replaces each imported value in FILE with its latchkey://ID.
      Existing items are left alone unless --replace is given.
      --scan DIR finds every .env and .env.* under DIR (not examples or templates, not in node_modules, build or
      .git folders) so all your projects come in at once; try it with --dry-run first.
      Several files (or --batch LIST, one path per line) are reviewed and approved together, each in its own
      project and environment. --share-identical makes a name that holds the same value in every file that
      has it one shared item, so rotating it is one change. Two files giving one ID different values is a
      conflict: neither is imported and both lines stay as they are.
      Skipped by default: VERCEL_OIDC_TOKEN, VERCEL_* and TURBO_* (vercel env pull writes them; they expire);
      --no-default-skip turns that off, --skip adds patterns. --agent-safe-pattern 'NEXT_PUBLIC_*,VITE_*'
      imports matching names as plain values agents may read (they ship to browsers anyway).
  latchkey env [list] | env show PROJECT/ENV [--json] | env migrate [--dry-run]
  latchkey env set PROJECT/ENV NAME=latchkey://ID|NAME=VALUE... | env unset PROJECT/ENV NAME... | env confirm PROJECT/ENV [NAME...]
      An environment's record: which variables it has, each an item (shared items too) or a plain setting such as
      PORT=3000. Records sync with your items, so `run --env` and `export` work the same on every Mac, wherever the
      checkout is. import, set and mv keep them up to date. `env migrate` makes or completes them from your items and
      the files they were imported from (when those are on this Mac); it only adds, and marks what it found through
      old file locations as unconfirmed until `env confirm`. Plain settings that may be secret are refused.
  latchkey export PROJECT/ENV [--out FILE] [--replace] [--values]
      Write the environment's env file from its record: latchkey:// references and plain settings, to standard
      output or FILE. An existing FILE is left alone (and the differences shown) unless --replace; a symbolic link
      is refused. --values writes the values themselves, in plain text, readable only by you: it asks every time,
      naming the file, and the access log records it (without the values). Agents can't use --values.
  latchkey project [DIR] | project link [NAME] [DIR] [--remote R] | project unlink NAME [DIR] | project list
      Which project a checkout is, from its Git remotes: so a fresh clone on another Mac finds its environments.
      link remembers the checkout's origin (or --remote R) as project NAME (default: the folder's name); a remote
      belongs to one project. A match only names the project: it never releases values or widens a grant, and a
      match through a remote other than origin (as a fork has) is flagged.
  latchkey mv ID[,ID...] | --from-file FILE   --to PROJECT/ENV | --shared   [--file FILE]...
      Move items into a project's environment (or back to shared) with one approval, then point
      references at the new IDs in the files each item was imported from, in --file files, and
      in the --from-file file. --from-file moves the shared items that FILE refers to.
  latchkey history ID             Earlier values of an item: when and by whom they were replaced. Never values.
  latchkey restore ID [--version N]
      Put back version N (1 = most recent) of ID, or bring back a deleted item. The current value
      is kept as a version first. Asks for approval.
  latchkey deleted                Items deleted in the last 30 days, which restore can bring back.
  latchkey forget ID[,ID...]      Delete the earlier values of items for good. Asks for approval.
  latchkey remote list [PROJECT/ENV]
  latchkey remote link PROJECT/ENV vercel|github|railway|fly KEY=VALUE...
      Link an environment to a place that holds its values. Keys: project, environment, repo, service, app,
      branch, dir (a folder linked with `vercel link` or `railway link`). For example:
        latchkey remote link shop/vercel.preview vercel project=shop environment=preview
        latchkey remote link shop/production github repo=me/shop environment=production
        latchkey remote link shop/railway.production railway environment=production service=api dir=~/Projects/shop
        latchkey remote link shop/production fly app=shop-api
  latchkey remote unlink LINK
  latchkey remote status PROJECT/ENV   Names missing on each side and values changed since the last push.
  latchkey push PROJECT/ENV [--to LINK] [--only ID,...] [--dry-run]
      Send the environment's values to its links with each service's own tool, signed in as you. Asks every
      time; production needs its own confirmation in the app. Nothing is deployed: Railway and Fly changes are
      staged until your next deploy.
  latchkey grant ID[,ID...] [--folder DIR] [--for 2h] [--session] [--command CMD]... [--once]
      Let commands run from DIR (default: here) and the folders inside it read these items
      without asking, until the time is up (30m, 2h, 1d; at most 7d). Asks for approval once.
      --session ends it when the agent you run this under quits, and covers only programs it starts.
      --command limits it to `latchkey run` of that command ("npm test" covers "npm test -- --ci").
      --once ends it after one use.
      PROJECT/* or PROJECT/ENV/* covers a whole project or environment, including items added later.
  latchkey log [--limit 20] | latchkey log --verify
      Recent entries of the access log (never values), or a check that no entry was changed, removed or
      added since Latchkey wrote it.
  latchkey touched [--since 24h] [--by NAME] [--grant ID] [--json]
      Items Latchkey released in that time (to anything, to programs under NAME such as claude, or under a grant),
      with how often and to whom, from the access log.
  latchkey rotate IDS|PATTERN... | --touched [--since 24h] [--by NAME] [--grant ID]  [--open] [--push]
      Replace items: ends grants that cover them, shows where to make each new key (--open opens it), asks for the
      new value (the old one stays in history), then pushes to linked environments with --push.
  latchkey grants                 Grants that are in effect.
  latchkey revoke ID|all
  latchkey status

Items not marked agent-safe need your approval (Touch ID, Apple Watch or your Mac password).
Changes always do. Values are kept in iCloud Keychain, so they follow you to your other Macs.

Exit codes: 0 done; 64 wrong usage; 66 no item with that ID (ask the owner to add it); 69 the Latchkey app
can't be reached; 73 a file couldn't be rewritten; 77 refused: not agent-safe, not approved, no grant (ask
the owner to approve or grant, don't retry); 127 the command couldn't start.
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("latchkey: " + message + "\n").utf8))
    exit(code)
}

func appAnswers(within seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if let fd = try? UnixSocket.connect(Paths.clientSocket) { close(fd); return true }
        usleep(150_000)
    } while Date() < deadline
    return false
}

/// Starts Latchkey hidden and waits for it to answer. False if it isn't installed or doesn't answer.
/// Launching is the last resort: a launch request that lands while the app is already starting ends that
/// launch, so first give a starting copy a moment, and never launch while one is listed as running.
func launchApp() -> Bool {
    if ProcessInfo.processInfo.environment["LATCHKEY_NO_LAUNCH"] == "1" || Paths.forwardedSocket != nil { return false }
    let bundleID = "io.snackstud.latchkey"
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

/// Sends one request to the app, starting it if it isn't running. Returns the response as is, `ok` or not.
/// Commands `latchkey mcp` starts for an agent carry LATCHKEY_ORIGIN=mcp, so their requests say so.
func call(_ request: Request) throws -> Response {
    var request = request
    if ProcessInfo.processInfo.environment["LATCHKEY_ORIGIN"] == "mcp" { request.origin = "mcp" }
    if Paths.forwardedSocket != nil {
        request.remote = RemoteClaim(host: ProcessInfo.processInfo.hostName, cwd: currentDirectory(),
                                     command: Redact.arguments(Array(CommandLine.arguments.dropFirst())).joined(separator: " "))
    }
    var launched = false
    var retries = 0
    while true {
        do {
            return try BrokerClient.send(request)
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
            throw RunError.unreachable(Paths.forwardedSocket.map { "cannot reach Latchkey through \($0) (\(e)). Is the SSH connection forwarding it?" }
                                       ?? "cannot reach the Latchkey app (\(e)). Open Latchkey and try again.")
        } catch {
            throw RunError.failed("\(error)")
        }
    }
}

/// `call`, exiting on any failure.
func send(_ request: Request) -> Response {
    do {
        let r = try call(request)
        if !r.ok { fail(r.error ?? "the app refused the request") }
        return r
    } catch {
        failRun(error)
    }
}

/// Exits with the code and message for a RunError.
func failRun(_ error: Error) -> Never {
    switch error as? RunError {
    case .usage(let m): fail(m, code: 64)
    case .unreadable(let m): fail(m, code: 66)
    case .missing(let ids): failMissing(ids)
    case .refused(let ids): failRefused(ids)
    case .unreachable(let m): fail(m, code: 69)
    case .failed(let m): fail(m)
    case nil: fail("\(error)")
    }
}

func currentDirectory() -> String { FileManager.default.currentDirectoryPath }

/// Exit 66 with the missing IDs and what to do, worded for agents as much as people.
func failMissing(_ ids: [String]) -> Never {
    fail("no item named: \(ids.joined(separator: ", "))\n  Ask the owner to add it in Latchkey (latchkey set ID) or check the name. Don't retry.", code: 66)
}

/// Exit 77 with the refused IDs and what to do.
func failRefused(_ ids: [String]) -> Never {
    let folder = Broker.tilde(currentDirectory())
    fail("refused: \(ids.joined(separator: ", ")) (not agent-safe, not approved, no grant)\n  Ask the owner to approve it in Latchkey, or to grant it: latchkey grant \(ids.joined(separator: ",")) --folder \(folder) --for 2h. Don't retry.", code: 77)
}

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
    var scopes: [String] = []
    var fileArgs: [(name: String, id: String)] = []
    var masking = true
    var proxy = false
    var aws: (role: String?, duration: TimeInterval)?
    var rest = input
    var cmd: [String] = []
    while !rest.isEmpty {
        let a = rest.removeFirst()
        if a == "--" { cmd = rest; break }
        switch a {
        case "--env-file":
            guard !rest.isEmpty else { fail("--env-file takes a path", code: 64) }
            envFiles.append(rest.removeFirst())
        case "--env":
            guard !rest.isEmpty, RemoteLink.isValidScope(rest[0]) else { fail("--env takes PROJECT/ENV, such as shop/development", code: 64) }
            scopes.append(rest.removeFirst())
        case "--file":
            guard !rest.isEmpty, let eq = rest[0].firstIndex(of: "="), Wire.isValidName(String(rest[0][rest[0].index(after: eq)...])) else {
                fail("--file takes NAME=ID, such as GOOGLE_APPLICATION_CREDENTIALS=gcp/production/SERVICE_ACCOUNT", code: 64)
            }
            let a = rest.removeFirst(), i = a.firstIndex(of: "=")!
            fileArgs.append((String(a[..<i]), String(a[a.index(after: i)...])))
        case "--no-masking": masking = false
        case "--proxy": proxy = true
        case "--aws-session": aws = (aws?.role, aws?.duration ?? AWSSTS.shortest)
        case "--aws-role":
            guard !rest.isEmpty, rest[0].hasPrefix("arn:") else { fail("--aws-role takes a role ARN, such as arn:aws:iam::123456789012:role/dev", code: 64) }
            aws = (rest.removeFirst(), aws?.duration ?? AWSSTS.shortest)
        case "--aws-for":
            guard !rest.isEmpty, let d = GrantStore.parseDuration(rest.removeFirst()) else { fail("--aws-for takes a time such as 15m or 1h", code: 64) }
            aws = (aws?.role, d)
        default:
            if a.hasPrefix("--env-file=") { envFiles.append(String(a.dropFirst(11))) }
            else if a.hasPrefix("-") { fail("unknown option \(a)", code: 64) }
            else { cmd = [a] + rest; rest = [] }
        }
    }
    guard !cmd.isEmpty else { fail("usage: latchkey run [--env-file FILE] [--env PROJECT/ENV] [--file NAME=ID] -- COMMAND [ARGS...]", code: 64) }

    let spec = RunSpec(envFiles: envFiles, scopes: scopes, fileArgs: fileArgs, cwd: currentDirectory(), aws: aws)
    let prepared: PreparedRun
    do {
        let planned = try plannedEnvironment(spec, base: ProcessInfo.processInfo.environment, call: call)
        prepared = try prepareRun(spec, env: planned, masking: masking, proxy: proxy, call: call)
    } catch { failRun(error) }
    var env = prepared.environment
    let secretValues = prepared.secretValues, tempDir = prepared.tempDir
    var proxies: [KeyProxy] = []
    for route in prepared.proxies {
        do {
            let p = try KeyProxy(route: route)
            let port = try p.start()
            env[route.provider.baseVariable] = "http://127.0.0.1:\(port)\(route.provider.basePath)"
            proxies.append(p)
        } catch {
            prepared.cleanUp()
            fail("couldn't start the key proxy for \(route.provider.name): \(error)")
        }
    }

    // Exec in place when there's nothing to mask and nothing to clean up afterwards.
    if secretValues.isEmpty && tempDir == nil && proxies.isEmpty {
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
        pumpMasked(pipe, secrets: secretValues, group: group) { out in lock.lock(); target.write(out); lock.unlock() }
    }

    signal(SIGTERM) { _ in if childPID > 0 { kill(childPID, SIGTERM) } }
    signal(SIGHUP) { _ in if childPID > 0 { kill(childPID, SIGHUP) } }
    signal(SIGINT) { _ in }   // the terminal already sent it to the child; wait for the child to finish

    do { try process.run() } catch { prepared.cleanUp(); fail("cannot start \(cmd[0]): \(error.localizedDescription)", code: 127) }
    childPID = process.processIdentifier
    pump(outPipe, to: FileHandle.standardOutput)
    pump(errPipe, to: FileHandle.standardError)
    process.waitUntilExit()
    group.wait()
    prepared.cleanUp()
    proxies.forEach { $0.stop() }
    if process.terminationReason == .uncaughtSignal { exit(128 + process.terminationStatus) }
    exit(process.terminationStatus)
}

// MARK: - check

func checkCommand(_ input: [String]) -> Never {
    var spec = RunSpec(cwd: currentDirectory())
    var ids: [String] = []
    var json = false
    var intended: [String]?
    var rest = input
    while !rest.isEmpty {
        let a = rest.removeFirst()
        if a == "--" { intended = rest; break }
        switch a {
        case "--env-file":
            guard !rest.isEmpty else { fail("--env-file takes a path", code: 64) }
            spec.envFiles.append(rest.removeFirst())
        case "--env":
            guard !rest.isEmpty, RemoteLink.isValidScope(rest[0]) else { fail("--env takes PROJECT/ENV, such as shop/development", code: 64) }
            spec.scopes.append(rest.removeFirst())
        case "--file":
            guard !rest.isEmpty, let eq = rest[0].firstIndex(of: "="), Wire.isValidName(String(rest[0][rest[0].index(after: eq)...])) else {
                fail("--file takes NAME=ID", code: 64)
            }
            let f = rest.removeFirst(), i = f.firstIndex(of: "=")!
            spec.fileArgs.append((String(f[..<i]), String(f[f.index(after: i)...])))
        case "--json": json = true
        default:
            if a.hasPrefix("-") { fail("unknown option \(a)", code: 64) }
            ids += a.split(separator: ",").map(String.init)
        }
    }
    let names: [String]
    do {
        let planned = try plannedEnvironment(spec, base: ProcessInfo.processInfo.environment, call: call)
        names = Array(Set(referencedIDs(planned) + ids)).sorted()
    } catch { failRun(error) }
    guard !names.isEmpty else { fail("nothing to check: give IDs, --env-file, --env or --file", code: 64) }
    let r = send(Request(op: "check", names: names, intended: intended))
    if json {
        let report = CheckReport(r)
        let enc = Wire.encoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try! enc.encode(report), as: UTF8.self))
    } else {
        let byID = Dictionary((r.grants ?? []).flatMap { g in (r.granted ?? []).filter { g.covers($0, cwd: spec.cwd) }.map { ($0, g) } },
                              uniquingKeysWith: { a, _ in a })
        func show(_ label: String, _ list: [String]?, _ detail: (String) -> String = { _ in "" }) {
            for id in list ?? [] { print("\(label.padding(toLength: 18, withPad: " ", startingAt: 0))\(id)\(detail(id))") }
        }
        show("agent-safe", r.agentSafe)
        show("granted", r.granted) { id in byID[id].map { "  (grant \($0.id), \(relative($0.expires)) left)" } ?? "" }
        show("asks", r.needsApproval)
        show("missing", r.missing)
    }
    exit((r.missing ?? []).isEmpty ? 0 : 66)
}

/// What `latchkey check --json` prints and the MCP check tool returns.
struct CheckReport: Encodable {
    var agentSafe: [String]
    var granted: [String]
    var remembered: [String]
    var needsApproval: [String]
    var missing: [String]
    var grants: [Grant]

    init(_ r: Response) {
        agentSafe = r.agentSafe ?? []
        granted = r.granted ?? []
        remembered = r.remembered ?? []
        needsApproval = r.needsApproval ?? []
        missing = r.missing ?? []
        grants = r.grants ?? []
    }

    /// True when `latchkey run` would start without asking.
    var runsWithoutAsking: Bool { needsApproval.isEmpty && missing.isEmpty }
}

// MARK: - import

func importCommand(_ input: [String]) -> Never {
    var files: [String] = []
    var shareIdentical = false
    var skip = EnvImport.defaultSkip
    var agentSafePatterns: [String] = []
    var rewrite = false, replace = false, dryRun = false
    var only: Set<String>?
    var defaultKind = ItemKind.token
    var kinds: [String: ItemKind] = [:]
    var agentSafe: Set<String> = []
    var allAgentSafe = false
    var project: String?, environment: String?, shared = false
    var rest = input
    func names(_ s: String) -> Set<String> { Set(s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
    while !rest.isEmpty {
        let a = rest.removeFirst()
        switch a {
        case "--project":
            guard !rest.isEmpty, ItemID.isValidPart(rest[0]) else { fail("--project takes a name (letters, digits, _ - .)", code: 64) }
            project = rest.removeFirst()
        case "--env":
            guard !rest.isEmpty, ItemID.isValidPart(rest[0]) else { fail("--env takes a name such as development or production", code: 64) }
            environment = rest.removeFirst()
        case "--shared": shared = true
        case "--share-identical": shareIdentical = true
        case "--no-default-skip": skip.removeAll { EnvImport.defaultSkip.contains($0) }
        case "--skip":
            guard !rest.isEmpty else { fail("--skip takes patterns such as SENTRY_AUTH_TOKEN,TEMP_*", code: 64) }
            skip += names(rest.removeFirst()).sorted()
        case "--agent-safe-pattern":
            guard !rest.isEmpty else { fail("--agent-safe-pattern takes patterns such as NEXT_PUBLIC_*,VITE_*", code: 64) }
            agentSafePatterns += names(rest.removeFirst()).sorted()
        case "--batch":
            guard !rest.isEmpty else { fail("--batch takes a file listing one path per line", code: 64) }
            let list = rest.removeFirst()
            guard let text = try? String(contentsOfFile: (list as NSString).expandingTildeInPath, encoding: .utf8) else {
                fail("cannot read \(list)", code: 66)
            }
            files += text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        case "--scan":
            guard !rest.isEmpty else { fail("--scan takes a folder, such as ~/Projects", code: 64) }
            let root = URL(fileURLWithPath: (rest.removeFirst() as NSString).expandingTildeInPath)
            let found = EnvScan.files(under: root)
            if found.isEmpty { fail("no env files under \(Broker.tilde(root.path))", code: 66) }
            FileHandle.standardError.write(Data("latchkey: found \(found.count) env file\(found.count == 1 ? "" : "s") under \(Broker.tilde(root.path))\n".utf8))
            files += found
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
            if a.hasPrefix("-") { fail("unknown option \(a)   (see latchkey help)", code: 64) }
            files.append(a)
        }
    }
    guard !files.isEmpty else { fail("usage: latchkey import FILE... [options]   (see latchkey help)", code: 64) }
    if shared && (project != nil || environment != nil) { fail("--shared can't be combined with --project or --env", code: 64) }
    if files.count > 1 {
        batchImport(files, project: project, environment: environment, shared: shared, shareIdentical: shareIdentical,
                    defaultKind: defaultKind, kinds: kinds, agentSafe: agentSafe, allAgentSafe: allAgentSafe, skip: skip,
                    agentSafePatterns: agentSafePatterns, only: only, rewrite: rewrite, replace: replace, dryRun: dryRun)
    }
    let file = files[0]
    let url = URL(fileURLWithPath: file).standardizedFileURL
    let text: String
    do { text = try String(contentsOf: url, encoding: .utf8) }
    catch { fail("cannot read \(file): \(error.localizedDescription)", code: 66) }

    let linked = send(Request(op: "projects")).projects ?? []
    let placeProject = shared ? "" : (project ?? linkedProject(for: url, linked) ?? EnvImport.project(forFile: url))
    let placeEnv = shared ? "" : (environment ?? EnvImport.environment(forFile: url.lastPathComponent))
    let plan: EnvImport.Plan
    do { plan = try EnvImport.plan(text, source: url.lastPathComponent, location: url.path, project: placeProject,
                              environment: placeEnv, only: only, defaultKind: defaultKind,
                              kinds: kinds, agentSafe: agentSafe, allAgentSafe: allAgentSafe,
                              skip: skip, agentSafePatterns: agentSafePatterns) }
    catch { fail("cannot import \(url.lastPathComponent): \(error.localizedDescription)", code: 66) }
    let items = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.name, $0) })
    let ignored = plan.ignored
    if let only {
        let unknown = only.subtracting(plan.references.keys).subtracting(ignored.keys)
        if !unknown.isEmpty { fail("not in \(file): \(unknown.sorted().joined(separator: ", "))", code: 66) }
    }
    for key in Set(kinds.keys).union(agentSafe) where plan.references[key] == nil && ignored[key] == nil {
        fail("\(key) is named in an option but is not in \(file)", code: 64)
    }
    print(placeProject.isEmpty ? "into shared items" : "into project \(placeProject), environment \(placeEnv)")
    for (key, why) in ignored.sorted(by: { $0.key < $1.key }) { print("ignore   \(key)  (\(why))") }
    let record = EnvironmentRecords.fromFile(text, references: plan.references,
                                             scope: placeProject.isEmpty ? fileScope(url, linked) : "\(placeProject)/\(placeEnv)")
    guard !items.isEmpty || (record != nil && !dryRun) else { print("Nothing to import."); exit(0) }

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

    let r = send(Request(op: "import",
                         items: items.values.sorted { $0.name < $1.name }, replace: replace, source: url.path,
                         environments: record.map { [$0] }))
    if let record { print("recorded \(record.scope): \(record.variables.keys.sorted().joined(separator: ", "))") }
    for n in r.added ?? [] { print("added    \(describe(items[n]!))") }
    for n in r.replaced ?? [] { print("replaced \(describe(items[n]!))") }
    for n in r.skipped ?? [] { print("skipped  \(n)  (exists; --replace to overwrite)") }

    let saved = Set((r.added ?? []) + (r.replaced ?? []))
    if rewrite && !saved.isEmpty {
        do {
            try EnvFile.rewriteFile(at: url, original: text, toReferences: plan.references.filter { saved.contains($0.value) })
            print("rewrote \(file): \(saved.count) value\(saved.count == 1 ? "" : "s") now latchkey://ID")
            print("next: lk run --env-file \(file) -- <your command>")
        } catch {
            fail("items were saved, but \(file) could not be rewritten: \(error.localizedDescription)", code: 73)
        }
    } else if !saved.isEmpty {
        print("next: replace the values in \(file) with latchkey:// references (lk import \(file) --rewrite does it), then:")
        print("  lk run --env-file \(file) -- <your command>")
    }
    exit(0)
}

// MARK: - several files

func batchImport(_ paths: [String], project: String?, environment: String?, shared: Bool, shareIdentical: Bool,
                 defaultKind: ItemKind, kinds: [String: ItemKind], agentSafe: Set<String>, allAgentSafe: Bool,
                 skip: [String], agentSafePatterns: [String], only: Set<String>?, rewrite: Bool, replace: Bool,
                 dryRun: Bool) -> Never {
    if only != nil { fail("--only works with one file", code: 64) }
    var files: [(url: URL, text: String)] = []
    var seen = Set<String>()
    for p in paths {
        let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL
        guard seen.insert(url.path).inserted else { continue }
        do { files.append((url, try String(contentsOf: url, encoding: .utf8))) }
        catch { fail("cannot read \(p): \(error.localizedDescription)", code: 66) }
    }
    let linked = send(Request(op: "projects")).projects ?? []
    let plan: EnvImport.BatchPlan
    do { plan = try EnvImport.batch(files, project: project, environment: environment, shared: shared, shareIdentical: shareIdentical,
                               defaultKind: defaultKind, kinds: kinds, agentSafe: agentSafe, allAgentSafe: allAgentSafe,
                               skip: skip, agentSafePatterns: agentSafePatterns, projectFor: { linkedProject(for: $0, linked) }) }
    catch { fail("cannot import: \(error.localizedDescription)", code: 66) }
    let existing = Set((send(Request(op: "list")).secrets ?? []).map(\.name))

    // The review: per file, then what's shared, skipped and in conflict. Names and counts only.
    for f in plan.files {
        let place = f.project.isEmpty ? "shared" : "\(f.project)/\(f.environment)"
        let sharedHere = f.references.values.filter { !$0.contains("/") }.count
        let skipped = f.ignored.values.filter { $0.hasPrefix("skipped") }.count
        let conflicts = f.ignored.values.filter { $0.hasPrefix("conflict") }.count
        var parts = ["\(f.references.count) to import"]
        if sharedHere > 0 && !f.project.isEmpty { parts.append("\(sharedHere) shared") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if conflicts > 0 { parts.append("\(conflicts) in conflict") }
        print("\(Broker.tilde(f.url.path))  →  \(place): \(parts.joined(separator: ", "))")
    }
    print("")
    let newItems = plan.items.filter { !existing.contains($0.name) }
    let existingItems = plan.items.filter { existing.contains($0.name) }
    print("\(plan.items.count) items from \(plan.files.count) files: \(newItems.count) new, \(existingItems.count) already exist\(existingItems.isEmpty ? "" : (replace ? " (will be overwritten)" : " (left alone; --replace overwrites)"))")
    if !plan.shared.isEmpty {
        print("shared (same value everywhere): " + plan.shared.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
    }
    let skippedNames = Set(plan.files.flatMap { f in f.ignored.filter { $0.value.hasPrefix("skipped") }.keys })
    if !skippedNames.isEmpty { print("skipped: \(skippedNames.sorted().joined(separator: ", "))") }
    for (id, where_) in plan.conflicts.sorted(by: { $0.key < $1.key }) {
        print("conflict: \(id) differs between \(where_.map { Broker.tilde($0) }.joined(separator: " and ")); not imported")
    }
    let publicCount = plan.items.filter { EnvImport.matches(ItemID($0.name)?.name ?? $0.name, agentSafePatterns) }.count
    if publicCount > 0 { print("\(publicCount) agent-safe plain values from --agent-safe-pattern") }

    let toSend = replace ? plan.items : newItems
    let records = plan.files.compactMap { f in
        EnvironmentRecords.fromFile(f.text, references: f.references,
                                    scope: f.project.isEmpty ? fileScope(f.url, linked) : "\(f.project)/\(f.environment)")
    }
    if dryRun {
        print(rewrite ? "Nothing sent. Without --dry-run: one approval, then each file's imported values become latchkey:// references." : "Nothing sent.")
        exit(0)
    }
    guard !toSend.isEmpty || !records.isEmpty else { print("Nothing new to import."); exit(0) }

    let r = send(Request(op: "import",
                         items: toSend, replace: replace, source: "\(plan.files.count) files", environments: records))
    if !records.isEmpty { print("recorded \(Set(records.map(\.scope)).sorted().joined(separator: ", "))") }
    let saved = Set((r.added ?? []) + (r.replaced ?? []))
    print("imported \(r.added?.count ?? 0) new\((r.replaced?.count ?? 0) > 0 ? ", replaced \(r.replaced!.count)" : "")\((r.skipped?.count ?? 0) > 0 ? ", left \(r.skipped!.count) that already existed" : "")")
    guard rewrite else { exit(0) }
    var failed = 0
    for f in plan.files {
        let refs = f.references.filter { saved.contains($0.value) }
        guard !refs.isEmpty else { continue }
        do {
            try EnvFile.rewriteFile(at: f.url, original: f.text, toReferences: refs)
            let left = f.references.count - refs.count
            print("rewrote \(Broker.tilde(f.url.path)): \(refs.count) now latchkey://ID\(left > 0 ? ", \(left) left as they were" : "")")
        } catch {
            failed += 1
            print("couldn't rewrite \(Broker.tilde(f.url.path)): \(error.localizedDescription)")
        }
    }
    if failed == 0, !saved.isEmpty {
        print("next: run each project through Latchkey, from its folder:")
        print("  lk run --env-file <its env file> -- <your command>")
    }
    exit(failed == 0 ? 0 : 73)
}

// MARK: - grants

func relative(_ d: Date) -> String {
    let left = d.timeIntervalSinceNow
    return left < 90 ? "under 2 minutes" : GrantStore.describe(left)
}

func printGrants(_ grants: [Grant]) {
    guard !grants.isEmpty else { print("No grants in effect."); return }
    for g in grants {
        let limits = g.limits.isEmpty ? "" : ", \(g.limits)"
        print("\(g.id)  \(Broker.tilde(g.folder))  \(g.names.joined(separator: ", "))  (\(relative(g.expires)) left\(limits))")
    }
}

func grantCommand(_ input: [String]) -> Never {
    var names: [String] = []
    var folder: String?
    var duration: TimeInterval = 3600
    var json = false
    var session = false
    var commands: [[String]] = []
    var uses: Int?
    var rest = input
    while !rest.isEmpty {
        let a = rest.removeFirst()
        switch a {
        case "--json": json = true
        case "--session": session = true
        case "--once": uses = 1
        case "--command":
            guard !rest.isEmpty else { fail("--command takes a command, such as \"npm test\"", code: 64) }
            let words = rest.removeFirst().split(separator: " ").map(String.init)
            guard !words.isEmpty else { fail("--command takes a command, such as \"npm test\"", code: 64) }
            commands.append(words)
        case "--folder":
            guard !rest.isEmpty else { fail("--folder takes a path", code: 64) }
            // The broker sees where commands really run (symbolic links resolved), so grant that folder.
            folder = URL(fileURLWithPath: rest.removeFirst()).resolvingSymlinksInPath().standardizedFileURL.path
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
    guard !names.isEmpty, names.allSatisfy({ Wire.isValidName($0) || Grant.isPattern($0) }) else {
        fail("usage: latchkey grant ID[,ID...] [--folder DIR] [--for 2h] [--session] [--command CMD]... [--once]   (or PROJECT/* or PROJECT/ENV/*)", code: 64)
    }
    if duration > GrantStore.longest { fail("the longest grant is 7 days", code: 64) }
    let r: Response
    do {
        r = try call(Request(op: "grant", names: names, folder: folder ?? currentDirectory(), duration: duration,
                             session: session ? true : nil, commands: commands.isEmpty ? nil : commands, uses: uses))
    } catch { failRun(error) }
    if let m = r.missing, !m.isEmpty { failMissing(m) }
    guard r.ok else { fail(r.error ?? "the app refused the request") }
    if json, let g = r.grants?.first {
        let enc = Wire.encoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try! enc.encode(g), as: UTF8.self))
        exit(0)
    }
    for g in r.grants ?? [] {
        print("granted \(g.id): \(g.names.joined(separator: ", ")) readable from \(Broker.tilde(g.folder)) for \(GrantStore.describe(duration))\(g.limits.isEmpty ? "" : ", \(g.limits)")")
    }
    exit(0)
}

// MARK: - remote locations

func printLinks(_ links: [RemoteLink]) {
    guard !links.isEmpty else { print("No links. Add one with `latchkey remote link PROJECT/ENV SERVICE KEY=VALUE...`."); return }
    var scope: String?
    for l in links.sorted(by: { ($0.scope, $0.target.label) < ($1.scope, $1.target.label) }) {
        if l.scope != scope { if scope != nil { print("") }; print(l.scope); scope = l.scope }
        let last = l.pushed.values.max().map { "last pushed \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "never pushed"
        print("  \(l.id)  \(l.target.label)\(l.target.isProduction ? "  [production]" : "")  (\(last))")
    }
}

func remoteCommand(_ args: [String]) -> Never {
    guard let sub = args.first else { fail("usage: latchkey remote list|link|unlink|status ... (see latchkey help)", code: 64) }
    let rest = Array(args.dropFirst())
    switch sub {
    case "list":
        printLinks(send(Request(op: "links", names: rest.first.map { [$0] })).links ?? [])
    case "link":
        guard rest.count >= 2, RemoteLink.isValidScope(rest[0]), let service = RemoteTarget.Service(rawValue: rest[1]) else {
            fail("usage: latchkey remote link PROJECT/ENV vercel|github|railway|fly KEY=VALUE...", code: 64)
        }
        var t = RemoteTarget(service: service)
        for pair in rest.dropFirst(2) {
            guard let eq = pair.firstIndex(of: "=") else { fail("\(pair) isn't KEY=VALUE", code: 64) }
            let key = String(pair[..<eq]), value = String(pair[pair.index(after: eq)...])
            switch key {
            case "project": t.project = value
            case "environment", "env": t.environment = value
            case "repo": t.repo = value
            case "service": t.serviceName = value
            case "app": t.app = value
            case "branch": t.branch = value
            case "dir": t.directory = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path
            default: fail("unknown key \(key) (project, environment, repo, service, app, branch, dir)", code: 64)
            }
        }
        if let problem = t.problem { fail(problem, code: 64) }
        let r = send(Request(op: "link", names: [rest[0]], target: t))
        if let l = r.links?.first { print("linked \(l.scope) → \(l.target.label) (\(l.id))") }
        if ItemID(rest[0] + "/X")?.environment.contains(".") == false, rest[0].split(separator: "/").last.map(String.init) != t.suggestedEnvironment {
            print("tip: values that differ by service can live in their own environment, e.g. \(rest[0].split(separator: "/")[0])/\(t.suggestedEnvironment)")
        }
    case "unlink":
        guard let id = rest.first else { fail("usage: latchkey remote unlink LINK", code: 64) }
        let r = send(Request(op: "unlink", names: [id]))
        if let m = r.missing, !m.isEmpty { fail("no link \(id)", code: 66) }
        print("unlinked \(id)")
    case "status":
        guard let scope = rest.first, RemoteLink.isValidScope(scope) else { fail("usage: latchkey remote status PROJECT/ENV", code: 64) }
        let statuses = send(Request(op: "remote-status", names: [scope])).remoteStatus ?? []
        if statuses.isEmpty { print("\(scope) isn't linked anywhere.") }
        for s in statuses {
            print(s.label)
            if let e = s.error { print("  couldn't check: \(e)") }
            if !s.missing.isEmpty { print("  not there:  \(s.missing.joined(separator: ", "))") }
            if !s.outOfDate.isEmpty { print("  changed since last push: \(s.outOfDate.joined(separator: ", "))") }
            if !s.extra.isEmpty { print("  only there: \(s.extra.joined(separator: ", "))") }
            if s.error == nil && s.missing.isEmpty && s.outOfDate.isEmpty && s.extra.isEmpty { print("  in step") }
        }
    default:
        fail("unknown: remote \(sub)", code: 64)
    }
    exit(0)
}

func pushCommand(_ args: [String]) -> Never {
    guard let scope = args.first, RemoteLink.isValidScope(scope) else { fail("usage: latchkey push PROJECT/ENV [--to LINK] [--only ID,...] [--dry-run]", code: 64) }
    var link: String?, only: [String]?, dryRun = false
    var rest = Array(args.dropFirst())
    while !rest.isEmpty {
        let a = rest.removeFirst()
        switch a {
        case "--to": guard !rest.isEmpty else { fail("--to takes a link id", code: 64) }; link = rest.removeFirst()
        case "--only": guard !rest.isEmpty else { fail("--only takes item IDs", code: 64) }; only = expandIDs([rest.removeFirst()])
        case "--dry-run": dryRun = true
        default: fail("unknown option \(a)", code: 64)
        }
    }
    if dryRun {
        let links = (send(Request(op: "links", names: [scope])).links ?? []).filter { link == nil || $0.id == link }
        let items = (send(Request(op: "list")).secrets ?? []).filter { $0.name.hasPrefix(scope + "/") && (only == nil || only!.contains($0.name)) }
        if links.isEmpty { fail("\(scope) isn't linked anywhere", code: 66) }
        for l in links {
            print("\(l.target.label)\(l.target.isProduction ? "  [production: confirm in the app]" : "")")
            for i in items { print("  \(i.ref.name)") }
        }
        print("Nothing sent. Run without --dry-run to push; the app asks first.")
        exit(0)
    }
    let r: Response
    do { r = try BrokerClient.send(Request(op: "push", names: [scope], link: link, only: only)) }
    catch { fail("cannot reach the Latchkey app (\(error))", code: 69) }
    for p in (r.pushResults ?? []).sorted(by: { ($0.link, $0.item) < ($1.link, $1.item) }) {
        print("\(p.ok ? "pushed " : "FAILED ") \(ItemID(p.item)?.name ?? p.item)  → \(p.link)\(p.error.map { "  \($0)" } ?? "")")
    }
    if !r.ok { fail(r.error ?? "push failed") }
    exit(0)
}

// MARK: - several items

/// IDs from arguments: comma-separated IDs, or PROJECT/* and PROJECT/ENV/* patterns matched against the items
/// that exist now. Fails on anything else, or on a pattern that matches nothing.
func expandIDs(_ args: [String]) -> [String] {
    let words = args.flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }.filter { !$0.isEmpty }
    guard !words.isEmpty else { fail("give one or more item IDs, or a pattern such as shop/* or shop/production/*", code: 64) }
    var all: [String]?
    var out: [String] = []
    for w in words {
        if Grant.isPattern(w) {
            if all == nil { all = (send(Request(op: "list")).secrets ?? []).map(\.name) }
            let matched = all!.filter { Grant.entry(w, matches: $0) }
            if matched.isEmpty { fail("no items match \(w)", code: 66) }
            out += matched
        } else if Wire.isValidName(w) {
            out.append(w)
        } else {
            fail("not an item ID or pattern: \(w)", code: 64)
        }
    }
    var seen = Set<String>()
    return out.filter { seen.insert($0).inserted }
}

// MARK: - move

func moveCommand(_ input: [String]) -> Never {
    var ids: [String] = []
    var fromFile: URL?
    var files: [URL] = []
    var target: (project: String, environment: String)?
    var rest = input
    while !rest.isEmpty {
        let a = rest.removeFirst()
        switch a {
        case "--to":
            guard !rest.isEmpty else { fail("--to takes PROJECT/ENV", code: 64) }
            let parts = rest.removeFirst().split(separator: "/").map(String.init)
            guard parts.count == 2, parts.allSatisfy(ItemID.isValidPart) else { fail("--to takes PROJECT/ENV, such as site/production", code: 64) }
            target = (parts[0], parts[1])
        case "--shared": target = ("", "")
        case "--file":
            guard !rest.isEmpty else { fail("--file takes a path", code: 64) }
            files.append(URL(fileURLWithPath: rest.removeFirst()).standardizedFileURL)
        case "--from-file":
            guard !rest.isEmpty else { fail("--from-file takes a path", code: 64) }
            fromFile = URL(fileURLWithPath: rest.removeFirst()).standardizedFileURL
        default:
            if a.hasPrefix("-") { fail("unknown option \(a)", code: 64) }
            ids += a.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }
    guard let target else { fail("usage: latchkey mv ID[,ID...] | --from-file FILE  --to PROJECT/ENV | --shared  [--file FILE]...", code: 64) }
    let existing = send(Request(op: "list")).secrets ?? []
    if let fromFile {
        let refs: [String]
        do { refs = References.names(in: Dictionary(try EnvFile.load(fromFile.path).map { ($0.key, $0.value) }) { $1 }) }
        catch { fail("cannot read \(fromFile.path): \(error.localizedDescription)", code: 66) }
        let sharedIDs = Set(existing.filter { $0.ref.isShared }.map(\.name))
        ids += refs.filter { sharedIDs.contains($0) }
        files.append(fromFile)
        if ids.isEmpty { print("\(fromFile.lastPathComponent) refers to no shared items; nothing to move."); exit(0) }
    }
    guard !ids.isEmpty, ids.allSatisfy(Wire.isValidName) else { fail("no valid item IDs given", code: 64) }
    let usedIn = existing.filter { ids.contains($0.name) }.flatMap { $0.usedIn ?? [] }

    let r = send(Request(op: "move", names: ids,
                         project: target.project, environment: target.environment))
    if let m = r.missing, !m.isEmpty { fail("no item named: \(m.joined(separator: ", "))", code: 66) }
    let moved = r.moved ?? [:]
    for (old, new) in moved.sorted(by: { $0.key < $1.key }) { print("moved    \(old) → \(new)") }
    if moved.isEmpty { print("Nothing to move: already there."); exit(0) }
    var seen = Set<String>()
    for url in files + usedIn.map({ URL(fileURLWithPath: $0) }) where seen.insert(url.path).inserted {
        guard FileManager.default.fileExists(atPath: url.path) else { print("missing  \(Broker.tilde(url.path)) (not updated)"); continue }
        do {
            if try EnvFile.renameReferences(in: url, moved) { print("updated  \(Broker.tilde(url.path))") }
        } catch {
            print("failed   \(Broker.tilde(url.path)): \(error.localizedDescription)")
        }
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
    var info = r.info ?? [:]
    info["app"] = Paths.forwardedSocket != nil ? "not checked (forwarded over SSH from \(Paths.forwardedSocket!))"
        : CodeIdentity.ownTeam == nil ? "not checked (this tool is unsigned)" : "the Latchkey app (signature checked)"
    for (k, v) in info.sorted(by: { $0.key < $1.key }) { print("\(k): \(v)") }

case "list":
    var only: String?
    if let i = args.firstIndex(of: "--project") {
        guard i + 1 < args.count else { fail("--project takes a name", code: 64) }
        only = args[i + 1]
    }
    let r = send(Request(op: "list"))
    let items = (r.secrets ?? []).filter { only == nil || $0.ref.project == only }.sorted { $0.ref < $1.ref }
    if args.contains("--json") {
        let enc = Wire.encoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try! enc.encode(items), as: UTF8.self))
    } else if items.isEmpty {
        print(only.map { "No items in project \($0)." } ?? "No items yet. Add one in the app or with `latchkey set NAME`.")
    } else {
        // One heading per project and environment, then the items' names under it.
        let width = max(4, items.map(\.ref.name.count).max() ?? 4)
        var heading: String?
        for i in items {
            let h = i.ref.isShared ? "shared" : "\(i.ref.project)/\(i.ref.environment)"
            if h != heading {
                if heading != nil { print("") }
                print(h)
                heading = h
            }
            let name = i.ref.name.padding(toLength: width, withPad: " ", startingAt: 0)
            let kind = i.kind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
            let svc = (i.service ?? "").padding(toLength: 12, withPad: " ", startingAt: 0)
            print("  \(name)  \(kind)  \(svc)  \(i.agentSafe ? "agents: yes" : "agents: no ")  \(i.note)")
        }
    }

case "get":
    guard let name = args.first, Wire.isValidName(name) else { fail("usage: latchkey get ID", code: 64) }
    let r = send(Request(op: "get", names: [name]))
    if let m = r.missing, !m.isEmpty { failMissing(m) }
    if let d = r.denied, !d.isEmpty { failRefused(d) }
    guard let v = r.values?[name] else { fail("no value returned") }
    print(v)

case "set":
    guard let name = args.first, Wire.isValidName(name) else {
        fail("usage: latchkey set NAME [--kind KIND] [--agent-safe] [--note TEXT]   (letters, digits, _ - . only)", code: 64)
    }
    var kind: ItemKind? = nil
    var agentSafe: Bool? = nil
    var note: String? = nil
    var service: String? = nil
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
        case "--service":
            i += 1
            guard i < args.count else { fail("--service takes a name, such as Stripe", code: 64) }
            service = args[i]
        default: fail("unknown option \(args[i])", code: 64)
        }
        i += 1
    }
    let value = readValue(prompt: "Value for \(name): ")
    guard !value.isEmpty else { fail("empty value; nothing saved") }
    _ = send(Request(op: "set", names: [name], value: value, kind: kind, agentSafe: agentSafe, note: note,
                     service: service))
    print("saved \(name)")
    print("next: put \(ItemID(name)?.name ?? name)=latchkey://\(name) in your env file, then run your command through Latchkey:")
    print("  lk run --env-file .env -- <your command>")

case "rm":
    let ids = expandIDs(args)
    let r = send(Request(op: "rm", names: ids))
    if let m = r.missing, !m.isEmpty { fail("no item named \(m.joined(separator: ", "))", code: 66) }
    for id in ids { print("removed \(id)") }

case "update":
    var targets: [String] = []
    var agentSafe: Bool?, kind: ItemKind?, service: String?, note: String?, fillSites: [String]?
    var rest = args
    while !rest.isEmpty {
        let a = rest.removeFirst()
        switch a {
        case "--agent-safe":
            guard let v = rest.first, ["yes", "no"].contains(v) else { fail("--agent-safe takes yes or no", code: 64) }
            agentSafe = rest.removeFirst() == "yes"
        case "--kind":
            guard let v = rest.first, let k = ItemKind(rawValue: v) else { fail("--kind takes token, password, key or value", code: 64) }
            _ = rest.removeFirst(); kind = k
        case "--service":
            guard !rest.isEmpty else { fail("--service takes a name (\"\" clears it)", code: 64) }
            service = rest.removeFirst()
        case "--note":
            guard !rest.isEmpty else { fail("--note takes text", code: 64) }
            note = rest.removeFirst()
        case "--fill-sites":
            guard !rest.isEmpty else { fail("--fill-sites takes host names separated by commas (\"\" goes back to the default)", code: 64) }
            fillSites = rest.removeFirst().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default:
            if a.hasPrefix("-") { fail("unknown option \(a)", code: 64) }
            targets.append(a)
        }
    }
    let ids = expandIDs(targets)
    let r = send(Request(op: "update", names: ids, kind: kind, agentSafe: agentSafe, note: note,
                         service: service, fillSites: fillSites))
    if let m = r.missing, !m.isEmpty { fail("no item named \(m.joined(separator: ", "))", code: 66) }
    print("updated \(ids.count) item\(ids.count == 1 ? "" : "s")")

case "run":
    runCommand(args)

case "check":
    checkCommand(args)

case "log":
    if args.contains("--verify") {
        let info = send(Request(op: "verify-log")).info ?? [:]
        if info["result"] == "intact" {
            print("intact: \(info["signed"] ?? "0") signed entries\(info["unsigned"].flatMap { $0 == "0" ? nil : ", \($0) older unsigned ones" } ?? "")")
            exit(0)
        }
        fail("the access log was changed: line \(info["line"] ?? "?"), \(info["reason"] ?? "unknown")", code: 1)
    }
    var limit = 20
    if let i = args.firstIndex(of: "--limit"), i + 1 < args.count, let n = Int(args[i + 1]) { limit = n }
    for e in Broker.readLog(limit: limit) {
        let who = e.program ?? e.chain.prefix(3).joined(separator: " › ")
        print("\(e.time.formatted(date: .abbreviated, time: .standard))  \(e.op)  \(e.decision)  \(e.names.joined(separator: ", "))  \(who)  \(Broker.tilde(e.cwd))\(e.command.map { "  $ \($0)" } ?? "")")
    }

case "touched":
    touchedCommand(args)

case "rotate":
    rotateCommand(args)

case "mcp":
    MCPServer().serve()

case "import":
    importCommand(args)

case "grant":
    grantCommand(args)

case "remote":
    remoteCommand(args)


case "push":
    pushCommand(args)

case "mv":
    moveCommand(args)

case "env":
    envCommand(args)

case "export":
    exportCommand(args)

case "project":
    projectCommand(args)

case "history":
    guard let name = args.first, Wire.isValidName(name) else { fail("usage: latchkey history ID", code: 64) }
    let versions = send(Request(op: "history", names: [name])).versions ?? []
    if versions.isEmpty { print("No earlier values of \(name).") }
    for (n, v) in versions.enumerated() {
        let when = v.savedAt.formatted(date: .abbreviated, time: .shortened)
        print("\(String(n + 1).padding(toLength: 3, withPad: " ", startingAt: 0)) \(when)  \(v.reason.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))  by \(v.by)")
    }
    if !versions.isEmpty { print("Kept: the last \(Versions.keep) per item. `latchkey restore \(name) --version N` puts one back.") }

case "restore":
    guard let name = args.first, Wire.isValidName(name) else { fail("usage: latchkey restore ID [--version N]", code: 64) }
    var n = 1
    if let i = args.firstIndex(of: "--version") {
        guard i + 1 < args.count, let v = Int(args[i + 1]), v >= 1 else { fail("--version takes a number from `latchkey history`", code: 64) }
        n = v
    }
    let versions = send(Request(op: "history", names: [name])).versions ?? []
    guard n <= versions.count else { fail(versions.isEmpty ? "no earlier values of \(name)" : "\(name) has \(versions.count) version(s)", code: 66) }
    let v = versions[n - 1]
    _ = send(Request(op: "restore", version: v.id))
    print("restored \(name) to its value from \(v.savedAt.formatted(date: .abbreviated, time: .shortened))")

case "deleted":
    let gone = send(Request(op: "deleted")).versions ?? []
    if gone.isEmpty { print("Nothing deleted in the last 30 days.") }
    for v in gone {
        let left = max(0, Int((Versions.deletedFor - Date().timeIntervalSince(v.savedAt)) / 86400))
        print("\(v.item)  deleted \(v.savedAt.formatted(date: .abbreviated, time: .shortened)) by \(v.by)  (\(left) day\(left == 1 ? "" : "s") left)")
    }

case "forget":
    let ids = expandIDs(args)
    let r = send(Request(op: "forget", names: ids))
    if let m = r.missing, !m.isEmpty { print("No earlier values of \(m.joined(separator: ", ")).") } else { print("forgot the earlier values of \(ids.count) item\(ids.count == 1 ? "" : "s")") }

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
