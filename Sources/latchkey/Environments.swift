import Darwin
import Foundation
import LatchkeyCore

// `latchkey env`, `latchkey export` and `latchkey project`: environment records, writing env files from them, and
// matching checkouts to projects.

func absolutePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: currentDirectory(), isDirectory: true)).standardizedFileURL.path
}

func environmentRecord(_ scope: String) -> EnvironmentRecord? {
    send(Request(op: "environments", names: [scope])).environments?.first { $0.scope == scope }
}

/// The project a file's checkout is linked to, if its own origin points at exactly one.
func linkedProject(for url: URL, _ projects: [ProjectRecord]) -> String? {
    ProjectMatching.project(remotes: GitRemotes.remotes(for: url.path), projects: projects)?.name
}

/// The environment an env file belongs to, from its checkout's linked project (or folder) and its name.
func fileScope(_ url: URL, _ projects: [ProjectRecord]) -> String {
    "\(linkedProject(for: url, projects) ?? EnvImport.project(forFile: url))/\(EnvImport.environment(forFile: url.lastPathComponent))"
}

// MARK: - env

func envCommand(_ input: [String]) -> Never {
    var args = input
    let sub = args.isEmpty ? "list" : args.removeFirst()
    func scopeArg() -> String {
        guard let s = args.first, RemoteLink.isValidScope(s) else { fail("give an environment, such as shop/development", code: 64) }
        args.removeFirst()
        return s
    }
    switch sub {
    case "list":
        let records = send(Request(op: "environments")).environments ?? []
        if records.isEmpty { print("No environment records yet. `lk env migrate` makes them from your items."); exit(0) }
        for r in records {
            let literals = r.variables.values.filter { $0.item == nil }.count
            var notes: [String] = []
            if literals > 0 { notes.append("\(literals) plain") }
            if !r.inferred.isEmpty { notes.append("\(r.inferred.count) unconfirmed") }
            if !r.legacyChecked { notes.append("not migrated") }
            print("\(r.scope)  \(r.variables.count) variable\(r.variables.count == 1 ? "" : "s")\(notes.isEmpty ? "" : "  (\(notes.joined(separator: ", ")))")")
        }
        exit(0)

    case "show":
        let scope = scopeArg()
        guard let r = environmentRecord(scope) else { fail("\(scope) has no environment record; `lk env migrate` makes one", code: 66) }
        if args.contains("--json") {
            let enc = Wire.encoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try! enc.encode(r), as: UTF8.self))
            exit(0)
        }
        let ids = Set((send(Request(op: "list")).secrets ?? []).map(\.name))
        let width = max(4, r.variables.keys.map(\.count).max() ?? 4)
        for name in r.variables.keys.sorted() {
            let entry = r.variables[name]!
            var line = "  \(name.padding(toLength: width, withPad: " ", startingAt: 0))  "
            switch entry {
            case .credential(let id): line += "\(References.scheme)\(id)\(ids.contains(id) ? "" : "  (missing)")"
            case .literal(let v): line += "\(EnvFile.quoted(v))  (plain)"
            }
            if r.inferred.contains(name) { line += "  (unconfirmed: found through old file locations)" }
            print(line)
        }
        if !r.inferred.isEmpty { print("`lk env confirm \(scope)` confirms them; `lk env unset \(scope) NAME` removes one.") }
        exit(0)

    case "set":
        let scope = scopeArg()
        guard !args.isEmpty else { fail("usage: latchkey env set PROJECT/ENV NAME=latchkey://ID|NAME=VALUE...", code: 64) }
        var vars: [String: EnvironmentEntry] = [:]
        for a in args {
            guard let eq = a.firstIndex(of: "=") else { fail("\(a): give NAME=latchkey://ID or NAME=VALUE", code: 64) }
            let name = String(a[..<eq]), value = String(a[a.index(after: eq)...])
            guard EnvironmentRecord.isValidVariable(name) else { fail("\(name) is not a valid variable name", code: 64) }
            if value.hasPrefix(References.scheme) {
                let id = String(value.dropFirst(References.scheme.count))
                guard Wire.isValidName(id) else { fail("\(id) is not a valid item id", code: 64) }
                vars[name] = .credential(id)
            } else {
                if !EnvironmentMigration.isPlainSetting(value) && EnvironmentRecord.mayBeSecret(name: name, value: value) {
                    fail("\(name) looks like a secret. Save it as an item (lk set \(scope)/\(name)), then: lk env set \(scope) \(name)=latchkey://\(scope)/\(name)", code: 64)
                }
                vars[name] = .literal(value)
            }
        }
        let r = try? call(Request(op: "environment-set", names: [scope], environments: [EnvironmentRecord(scope: scope, variables: vars)]))
        finishEnvChange(r, scope)

    case "unset", "confirm":
        let scope = scopeArg()
        var names = args
        if sub == "unset" && names.isEmpty { fail("usage: latchkey env unset PROJECT/ENV NAME...", code: 64) }
        if sub == "confirm" && names.isEmpty {
            guard let r = environmentRecord(scope) else { fail("\(scope) has no environment record", code: 66) }
            names = r.inferred
            if names.isEmpty { print("Nothing in \(scope) is waiting to be confirmed."); exit(0) }
        }
        let r = try? call(sub == "unset" ? Request(op: "environment-set", names: [scope], unset: names)
                                          : Request(op: "environment-set", names: [scope], confirm: names))
        finishEnvChange(r, scope)

    case "migrate":
        migrateCommand(dryRun: args.contains("--dry-run"))

    default:
        fail("unknown: latchkey env \(sub). Try list, show, set, unset, confirm or migrate.", code: 64)
    }
}

func finishEnvChange(_ r: Response?, _ scope: String) -> Never {
    guard let r else { fail("cannot reach the Latchkey app", code: 69) }
    if let m = r.missing, !m.isEmpty { failMissing(m) }
    guard r.ok else { fail(r.error ?? "the app refused the request", code: 77) }
    print("updated \(scope)")
    exit(0)
}

/// Makes or completes records from what Latchkey already knows, reading the files recorded on items where they're on
/// this Mac. Adds only; reports what it can't settle.
func migrateCommand(dryRun: Bool) -> Never {
    let items = send(Request(op: "list")).secrets ?? []
    let existing = send(Request(op: "environments")).environments ?? []
    var files: [String: String] = [:]
    for path in Set(items.filter { !$0.ref.isShared }.flatMap { $0.usedIn ?? [] }) {
        if let text = try? String(contentsOfFile: path, encoding: .utf8) { files[path] = text }
    }
    let plan = EnvironmentMigration.plan(items: items, existing: existing, files: files)
    if plan.records.isEmpty { print("No project items, so no environments to record."); exit(0) }
    let stored = Dictionary(uniqueKeysWithValues: existing.map { ($0.scope, $0) })
    var total = 0
    for proposed in plan.records {
        let result = EnvironmentRecords.adding(proposed, to: stored[proposed.scope])
        total += result.added.count
        let inferred = result.added.filter(proposed.inferred.contains)
        var line = "\(proposed.scope): "
        line += result.added.isEmpty ? "nothing new" : "\(result.added.count) to add"
        if !inferred.isEmpty { line += " (\(inferred.count) unconfirmed: \(inferred.joined(separator: ", ")))" }
        print(line)
        for c in plan.conflicts[proposed.scope] ?? [] { print("  conflict  \(c)") }
        for n in plan.notRecorded[proposed.scope] ?? [] { print("  not recorded  \(n)") }
    }
    for path in plan.unreadable { print("not on this Mac: \(Broker.tilde(path)) (shared items or settings only it used aren't found)") }
    if dryRun { print("Nothing sent."); exit(0) }
    let r = send(Request(op: "environment-add", environments: plan.records))
    let changed = r.environments ?? []
    if changed.isEmpty { print("Records already up to date.") }
    else { print("recorded \(total) variable\(total == 1 ? "" : "s") in \(changed.count) environment\(changed.count == 1 ? "" : "s")") }
    if changed.contains(where: { !$0.inferred.isEmpty }) { print("next: check with lk env show PROJECT/ENV, then lk env confirm PROJECT/ENV") }
    exit(0)
}

// MARK: - export

func exportCommand(_ input: [String]) -> Never {
    var scope: String?
    var out: String?
    var values = false
    var replace = false
    var rest = input
    while !rest.isEmpty {
        let a = rest.removeFirst()
        switch a {
        case "--out":
            guard !rest.isEmpty else { fail("--out takes a file", code: 64) }
            out = absolutePath(rest.removeFirst())
        case "--values": values = true
        case "--replace": replace = true
        default:
            if a.hasPrefix("-") || scope != nil || !RemoteLink.isValidScope(a) {
                fail("usage: latchkey export PROJECT/ENV [--out FILE] [--values] [--replace]", code: 64)
            }
            scope = a
        }
    }
    guard let scope else { fail("usage: latchkey export PROJECT/ENV [--out FILE] [--values] [--replace]", code: 64) }
    guard let record = environmentRecord(scope) else {
        fail("\(scope) has no environment record. `lk env migrate` makes one from your items (lk run --env \(scope) still works).", code: 66)
    }
    if values && out == nil { fail("--values needs --out FILE: values are only written to a file you name", code: 64) }

    let ids = Set((send(Request(op: "list")).secrets ?? []).map(\.name))
    let credentials = Array(Set(record.variables.values.compactMap(\.item))).sorted()
    let missing = credentials.filter { !ids.contains($0) }
    func note(_ s: String) { FileHandle.standardError.write(Data(("latchkey: " + s + "\n").utf8)) }
    if !record.inferred.isEmpty { note("unconfirmed in \(scope): \(record.inferred.joined(separator: ", ")) (lk env show \(scope))") }

    guard let path = out else {
        if !missing.isEmpty { note("not in Latchkey: \(missing.joined(separator: ", "))") }
        print(record.envFile(), terminator: "")
        exit(0)
    }
    if values && !missing.isEmpty { failMissing(missing) }
    if !missing.isEmpty { note("not in Latchkey, written as references anyway: \(missing.joined(separator: ", "))") }

    // Checked before anything is asked or written: a link or a folder is refused, an existing file needs --replace.
    let current: stat?
    do { current = try EnvFile.existingFile(path) } catch { fail(error.localizedDescription, code: 73) }
    if current != nil && !replace {
        let theirs = Dictionary(((try? EnvFile.load(path)) ?? []).map { ($0.key, $0.value) }) { _, b in b }
        let ours = record.variables.mapValues(\.envValue)
        let added = ours.keys.filter { theirs[$0] == nil }.sorted()
        let gone = theirs.keys.filter { ours[$0] == nil }.sorted()
        let changed = ours.keys.filter { theirs[$0] != nil && theirs[$0] != ours[$0] }.sorted()
        var diff: [String] = []
        if !added.isEmpty { diff.append("adds \(added.joined(separator: ", "))") }
        if !gone.isEmpty { diff.append("drops \(gone.joined(separator: ", "))") }
        if !changed.isEmpty { diff.append("changes \(changed.joined(separator: ", "))") }
        fail("\(Broker.tilde(path)) already exists\(diff.isEmpty ? " (same variables)" : "; exporting \(diff.joined(separator: "; "))"). Nothing written; --replace replaces it.", code: 73)
    }

    var released: [String: String] = [:]
    if values && !credentials.isEmpty {
        let r: Response
        do { r = try call(Request(op: "export", names: credentials, project: scope, destination: path)) } catch { failRun(error) }
        if let m = r.missing, !m.isEmpty { failMissing(m) }
        guard r.ok else { fail(r.error ?? "the export was not approved", code: 77) }
        released = r.values ?? [:]
        guard credentials.allSatisfy({ released[$0] != nil }) else { fail("the app did not return every value") }
    }
    let mode: mode_t = values ? 0o600 : current.map { $0.st_mode & 0o777 } ?? 0o644
    do { try EnvFile.writeAtomically(record.envFile(values: released), to: path, mode: mode, replace: replace) }
    catch { fail(error.localizedDescription, code: 73) }
    let literals = record.variables.count - record.variables.values.compactMap(\.item).count
    if values {
        print("wrote \(Broker.tilde(path)): \(credentials.count) value\(credentials.count == 1 ? "" : "s") in plain text (readable only by you)\(literals > 0 ? ", \(literals) plain setting\(literals == 1 ? "" : "s")" : "")")
    } else {
        print("wrote \(Broker.tilde(path)): \(record.variables.count - literals) reference\(record.variables.count - literals == 1 ? "" : "s")\(literals > 0 ? ", \(literals) plain setting\(literals == 1 ? "" : "s")" : "")")
        print("next: lk run --env-file \(Broker.tilde(path)) -- <your command>")
    }
    exit(0)
}

// MARK: - project

func projectCommand(_ input: [String]) -> Never {
    var args = input
    let sub = args.first.map { ["list", "link", "unlink", "show"].contains($0) ? args.removeFirst() : "show" } ?? "show"
    switch sub {
    case "list":
        let projects = send(Request(op: "projects")).projects ?? []
        if projects.isEmpty { print("No linked projects. In a checkout: lk project link [NAME]"); exit(0) }
        for p in projects { print("\(p.name)  \(p.origins.isEmpty ? "(no remotes)" : p.origins.joined(separator: ", "))") }
        exit(0)

    case "show":
        let dir = absolutePath(args.first ?? ".")
        let remotes = GitRemotes.remotes(for: dir)
        guard !remotes.isEmpty else { fail("\(Broker.tilde(dir)) isn't in a Git checkout with a remote", code: 66) }
        let projects = send(Request(op: "projects")).projects ?? []
        let matches = ProjectMatching.matches(remotes: remotes, projects: projects)
        for (name, url) in remotes.sorted(by: { $0.key < $1.key }) { print("remote \(name): \(url)") }
        guard !matches.isEmpty else {
            let suggested = EnvImport.project(forFile: URL(fileURLWithPath: dir + "/.env"))
            print("Not linked to a project. If this is \(suggested): lk project link \(suggested)")
            exit(0)
        }
        let records = send(Request(op: "environments")).environments ?? []
        let items = send(Request(op: "list")).secrets ?? []
        for m in matches {
            var line = "project \(m.project.name) (through \(m.remotes.joined(separator: ", ")))"
            if !m.throughOrigin { line += ": not through this checkout's origin; a fork looks like this, so check before using it" }
            print(line)
            let scopes = Set(records.map(\.scope).filter { $0.hasPrefix(m.project.name + "/") })
                .union(items.filter { $0.ref.project == m.project.name }.map { "\($0.ref.project)/\($0.ref.environment)" })
            for s in scopes.sorted() {
                let has = records.contains { $0.scope == s }
                print("  \(s)\(has ? "" : "  (no record yet: lk env migrate)")")
            }
            if let first = scopes.sorted().first { print("next: lk export \(first) --out .env.local") }
        }
        if matches.filter(\.throughOrigin).count > 1 { print("More than one project claims this checkout's origin; unlink the wrong one.") }
        exit(0)

    case "link", "unlink":
        var remoteName: String?
        if let i = args.firstIndex(of: "--remote") {
            guard i + 1 < args.count else { fail("--remote takes a remote's name, such as origin", code: 64) }
            remoteName = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }
        let dir = absolutePath(args.count > 1 ? args[1] : ".")
        let remotes = GitRemotes.remotes(for: dir)
        let pick = remoteName ?? (remotes["origin"] != nil ? "origin" : (remotes.count == 1 ? remotes.keys.first : nil))
        guard let pick, let origin = remotes[pick] else {
            fail(remotes.isEmpty ? "\(Broker.tilde(dir)) isn't in a Git checkout with a remote"
                 : "this checkout has no origin; choose a remote with --remote (\(remotes.keys.sorted().joined(separator: ", ")))", code: 64)
        }
        let name = args.first ?? EnvImport.project(forFile: URL(fileURLWithPath: dir + "/.env"))
        guard ItemID.isValidPart(name) else { fail("\(name) is not a valid project name", code: 64) }
        let r = send(Request(op: sub == "link" ? "project-link" : "project-unlink", project: name, origins: [origin]))
        print(sub == "link" ? "\(origin) is project \(r.projects?.first?.name ?? name)" : "\(origin) is no longer project \(name)")
        exit(0)

    default:
        fail("unknown: latchkey project \(sub)", code: 64)
    }
}
