import AppKit
import Darwin
import Foundation
import LatchkeyCore

let usage = """
latchkey: read secrets from the Latchkey app without keeping them in files.

Items are shared (ID = NAME) or belong to a project's environment (ID = project/environment/NAME).
Files refer to them as latchkey://ID.

  latchkey run [--env-file FILE]... [--no-masking] -- COMMAND [ARGS...]
      Start COMMAND with every latchkey://ID in its environment replaced by the real value.
      Secret values printed by COMMAND are concealed unless --no-masking is given.
  latchkey list [--project P] [--json]   IDs, kinds and whether agents may read them. Never values.
  latchkey get ID                 Print one value.
  latchkey set ID [--kind token|password|key|value] [--agent-safe] [--note TEXT] [--service NAME]
      Value is read from standard input, or prompted for when run in a terminal.
  latchkey rm ID[,ID...]|PATTERN...
      Delete items with one approval. PATTERN is PROJECT/* or PROJECT/ENV/*.
  latchkey update ID[,ID...]|PATTERN... [--agent-safe yes|no] [--kind KIND] [--service NAME] [--note TEXT]
      Change settings on many items with one approval. Values are untouched.
  latchkey import FILE [--project P] [--env E | --shared] [--rewrite] [--replace] [--dry-run]
                  [--only KEY,...] [--kind KIND | --kind KEY=KIND]... [--agent-safe KEY,...|all]
      Add every KEY=VALUE in a .env file with one approval. Prints IDs, never values.
      The project defaults to the repository's folder name and the environment to what the file
      name says (.env and .env.local: development; .env.production: production). --shared
      imports them as shared items named after their keys.
      --rewrite replaces each imported value in FILE with its latchkey://ID.
      Existing items are left alone unless --replace is given.
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
        latchkey remote link acp/vercel.preview vercel project=acp environment=preview
        latchkey remote link acp/production github repo=me/acp environment=production
        latchkey remote link acp/railway.production railway environment=production service=api dir=~/Projects/acp
        latchkey remote link acp/production fly app=acp-api
  latchkey remote unlink LINK
  latchkey remote status PROJECT/ENV   Names missing on each side and values changed since the last push.
  latchkey push PROJECT/ENV [--to LINK] [--only ID,...] [--dry-run]
      Send the environment's values to its links with each service's own tool, signed in as you. Asks every
      time; production needs its own confirmation in the app. Nothing is deployed: Railway and Fly changes are
      staged until your next deploy.
  latchkey grant ID[,ID...] [--folder DIR] [--for 2h]
      Let commands run from DIR (default: here) and the folders inside it read these items
      without asking, until the time is up (30m, 2h, 1d; at most 7d). Asks for approval once.
      PROJECT/* or PROJECT/ENV/* covers a whole project or environment, including items added later.
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

    if shared && (project != nil || environment != nil) { fail("--shared can't be combined with --project or --env", code: 64) }
    let placeProject = shared ? "" : (project ?? EnvImport.project(forFile: url))
    let placeEnv = shared ? "" : (environment ?? EnvImport.environment(forFile: url.lastPathComponent))
    let plan = EnvImport.plan(text, source: url.lastPathComponent, location: url.path, project: placeProject,
                              environment: placeEnv, only: only, defaultKind: defaultKind,
                              kinds: kinds, agentSafe: agentSafe, allAgentSafe: allAgentSafe)
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
            try EnvFile.rewriteFile(at: url, original: text, toReferences: plan.references.filter { saved.contains($0.value) })
            print("rewrote \(file): \(saved.count) value\(saved.count == 1 ? "" : "s") now latchkey://ID")
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
    guard !names.isEmpty, names.allSatisfy({ Wire.isValidName($0) || Grant.isPattern($0) }) else {
        fail("usage: latchkey grant ID[,ID...] [--folder DIR] [--for 2h]   (or PROJECT/* or PROJECT/ENV/*)", code: 64)
    }
    if duration > GrantStore.longest { fail("the longest grant is 7 days", code: 64) }
    let r = send(Request(op: "grant", names: names, cwd: currentDirectory(), folder: folder ?? currentDirectory(), duration: duration))
    if let m = r.missing, !m.isEmpty { fail("no item named: \(m.joined(separator: ", "))", code: 66) }
    for g in r.grants ?? [] {
        print("granted \(g.id): \(g.names.joined(separator: ", ")) readable from \(Broker.tilde(g.folder)) for \(GrantStore.describe(duration))")
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
        let r = send(Request(op: "link", names: [rest[0]], cwd: currentDirectory(), target: t))
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
    do { r = try BrokerClient.send(Request(op: "push", names: [scope], cwd: currentDirectory(), command: "latchkey push \(scope)", link: link, only: only)) }
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
    guard !words.isEmpty else { fail("give one or more item IDs, or a pattern such as acp/* or acp/production/*", code: 64) }
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

    let r = send(Request(op: "move", names: ids, cwd: currentDirectory(), command: "latchkey mv",
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
    for (k, v) in (r.info ?? [:]).sorted(by: { $0.key < $1.key }) { print("\(k): \(v)") }

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
    _ = send(Request(op: "set", names: [name], value: value, kind: kind, agentSafe: agentSafe, note: note, cwd: currentDirectory(),
                     service: service))
    print("saved \(name)")

case "rm":
    let ids = expandIDs(args)
    let r = send(Request(op: "rm", names: ids, cwd: currentDirectory()))
    if let m = r.missing, !m.isEmpty { fail("no item named \(m.joined(separator: ", "))", code: 66) }
    for id in ids { print("removed \(id)") }

case "update":
    var targets: [String] = []
    var agentSafe: Bool?, kind: ItemKind?, service: String?, note: String?
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
        default:
            if a.hasPrefix("-") { fail("unknown option \(a)", code: 64) }
            targets.append(a)
        }
    }
    let ids = expandIDs(targets)
    let r = send(Request(op: "update", names: ids, kind: kind, agentSafe: agentSafe, note: note, cwd: currentDirectory(),
                         service: service))
    if let m = r.missing, !m.isEmpty { fail("no item named \(m.joined(separator: ", "))", code: 66) }
    print("updated \(ids.count) item\(ids.count == 1 ? "" : "s")")

case "run":
    runCommand(args)

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
    _ = send(Request(op: "restore", cwd: currentDirectory(), version: v.id))
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
    let r = send(Request(op: "forget", names: ids, cwd: currentDirectory()))
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
