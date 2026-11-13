import Darwin
import Foundation

/// Answers CLI requests: decides what may be read, asks for approval, writes the access log.
/// The app hosts one; `latchkey-broker` hosts one without a window during development.
public final class Broker: @unchecked Sendable {
    /// How requests from the Latchkey window identify themselves.
    public static let appCaller = "the Latchkey app"

    /// The primary endpoint this broker advertises, independent of any extension listener.
    public let socketPath: String
    public let store: SecretStore
    public let grants: GrantStore
    /// Earlier values: kept when a value is replaced or an item deleted, pruned to `Versions.keep` per item and
    /// `Versions.deletedFor` after a delete.
    public let versions: VersionStore
    /// Environments linked to Vercel, GitHub Actions, Railway or Fly.
    public let remotes: RemoteStore
    /// Environment and project records: which variables each environment has, and which remotes each project's
    /// checkouts use.
    public let records: EnvironmentStore
    let runner: RemoteRunner
    /// Talks to the services' HTTPS APIs for links that name a token item.
    let native: NativeRemote
    /// Every link goes through the API, never a command-line tool: the sandboxed App Store build can't run them, so a
    /// link without a token item can't push there.
    public let nativeOnly: Bool
    /// Pushes run only in the app, where the approval panel can confirm production. The window-less broker refuses them.
    public let allowsPush: Bool
    public let approver: Approver
    public let logURL: URL?
    /// Signs each log entry into a chain, when the log is kept.
    public let logKeys: LogKeyStore?
    /// Called after every logged decision (reads, changes, denials), off the main thread.
    public var onChange: (@Sendable () -> Void)?
    /// One request at a time, so approval sheets never stack.
    private let serial = NSLock()
    /// Whether this Mac has Latchkey Pro. The app passes its StoreKit resolver in the App Store build; everywhere else
    /// nothing grants it, so a Pro op is refused.
    private let hasPro: @Sendable () -> Bool
    /// Pro ops and the feature each is named by in the refusal. `ProGate.features` outside tests.
    private let proFeatures: [String: String]

    /// Without a log (tests), grants are kept in memory too unless a store is passed.
    public init(store: SecretStore, approver: Approver,
                logURL: URL? = Paths.accessLog, grants: GrantStore? = nil, versions: VersionStore? = nil,
                remotes: RemoteStore? = nil, runner: RemoteRunner = ProcessRunner(), native: NativeRemote = NativeRemote(),
                nativeOnly: Bool = false, allowsPush: Bool = true,
                logKeys: LogKeyStore? = nil, records: EnvironmentStore? = nil, socketPath: String = Paths.socket,
                hasPro: @escaping @Sendable () -> Bool = { false }, proFeatures: [String: String] = ProGate.features) {
        self.socketPath = socketPath
        self.hasPro = hasPro
        self.proFeatures = proFeatures
        self.store = store
        if let records {
            self.records = records
        } else if logURL != nil, let keychain = store as? KeychainStore {
            self.records = KeychainEnvironmentStore(mode: keychain.mode)
        } else {
            self.records = MemoryEnvironmentStore()
        }
        self.runner = runner
        self.native = native
        self.nativeOnly = nativeOnly
        self.allowsPush = allowsPush
        if let remotes {
            self.remotes = remotes
        } else if logURL != nil, let keychain = store as? KeychainStore {
            self.remotes = KeychainRemoteStore(mode: keychain.mode)
        } else {
            self.remotes = MemoryRemoteStore()
        }
        if let versions {
            self.versions = versions
        } else if logURL != nil, let keychain = store as? KeychainStore {
            self.versions = KeychainVersionStore(mode: keychain.mode)
        } else {
            self.versions = MemoryVersionStore()
        }
        if let grants {
            self.grants = grants
        } else if logURL != nil, let keychain = store as? KeychainStore {
            self.grants = GrantStore(backing: KeychainGrantBacking(mode: keychain.mode))
        } else {
            self.grants = GrantStore()
        }
        self.approver = approver
        self.logURL = logURL
        if let logKeys {
            self.logKeys = logKeys
        } else if logURL != nil, let keychain = store as? KeychainStore {
            self.logKeys = KeychainLogKeyStore(mode: keychain.mode)
        } else {
            self.logKeys = nil
        }
    }

    // MARK: requests

    public func handle(_ req: Request, peer: PeerInfo) -> Response {
        serial.lock()
        defer { serial.unlock() }
        if let feature = proFeatures[req.op], !hasPro() { return Response(ok: false, error: ProGate.refusal(feature: feature)) }
        do {
            switch req.op {
            case "status": return status(peer)
            case "list": return Response(ok: true, secrets: try store.list())
            case "check": return try check(req, peer: peer)
            case "verify-log": return verifyLog()
            case "log":
                let limit = req.logLimit ?? 20
                guard (0...1000).contains(limit) else { return Response(ok: false, error: "log limit must be between 0 and 1000") }
                return Response(ok: true, logEntries: logURL.map { Self.readLog(limit: limit, from: $0) } ?? [])
            case "get": return try get(req, peer: peer)
            case "set": return try set(req, peer: peer)
            case "fill": return try fill(req, peer: peer)
            case "rm": return try remove(req, peer: peer)
            case "import": return try importItems(req, peer: peer)
            case "grants": return Response(ok: true, grants: grants.all())
            case "grant": return try grant(req, peer: peer)
            case "revoke": return revoke(req, peer: peer)
            case "move": return try move(req, peer: peer)
            case "update": return try update(req, peer: peer)
            case "history": return try history(req)
            case "deleted": return Response(ok: true, versions: try versions.deleted(existing: Set(store.list().map(\.name))))
            case "version": return try versionValue(req, peer: peer)
            case "restore": return try restore(req, peer: peer)
            case "forget": return try forget(req, peer: peer)
            case "links":
                let scope = req.names?.first
                return Response(ok: true, links: try remotes.all().filter { scope == nil || $0.scope == scope })
            case "link": return try link(req, peer: peer)
            case "unlink": return try unlink(req, peer: peer)
            case "remote-status": return try remoteStatus(req)
            case "push": return try push(req, peer: peer)
            case "environments":
                let scopes = Set(req.names ?? [])
                return Response(ok: true, environments: try records.environments().filter { scopes.isEmpty || scopes.contains($0.scope) })
            case "environment-add": return try addToEnvironments(req, peer: peer)
            case "environment-set": return try setEnvironment(req, peer: peer)
            case "environment-remove": return try removeEnvironment(req, peer: peer)
            case "export": return try export(req, peer: peer)
            case "projects": return Response(ok: true, projects: try records.projects())
            case "project-link": return try linkProject(req, peer: peer)
            case "project-unlink": return try unlinkProject(req, peer: peer)
            case "duplicates": return try duplicates(req, peer: peer)
            case "combine": return try combine(req, peer: peer)
            case "scan": return try scan(req, peer: peer)
            default: return Response(ok: false, error: "unknown op \(req.op)")
            }
        } catch {
            return Response(ok: false, error: "\(error)")
        }
    }

    func status(_ peer: PeerInfo) -> Response {
        let count = (try? store.list().count).map(String.init) ?? "unknown"
        return Response(ok: true, info: [
            "caller": peer.isSSHForward ? "another computer, through your ssh connection (\(peer.redactedCommandLine))"
                : peer.isLatchkeyTool ? "Latchkey's command-line tool (signature checked)"
                : "\(peer.path.isEmpty ? "unknown program" : peer.path) (not Latchkey's signed command-line tool)",
            "storage": store.location,
            "approval": approver.method,
            "items": count,
            "grants": String(grants.all().count),
            "socket": socketPath,
        ])
    }

    /// What `get` would do with these names from this caller and folder, without asking or releasing anything:
    /// which are agent-safe, covered by a grant, need approval, or don't exist.
    func check(_ req: Request, peer: PeerInfo) throws -> Response {
        let names = Array(Set(req.names ?? [])).sorted()
        guard !names.isEmpty else { return Response(ok: false, error: "no names given") }
        let infos = Dictionary(uniqueKeysWithValues: try store.list().map { ($0.name, $0) })
        let missing = names.filter { infos[$0] == nil }
        let present = names.filter { infos[$0] != nil }
        let cwd = peer.cwd
        let safe = present.filter { infos[$0]!.agentSafe }
        var granted: [String] = []
        var covering: [Grant] = []
        for name in present where !infos[name]!.agentSafe && !peer.isSSHForward {
            guard let g = grants.covering(name, cwd: cwd, ancestors: peer.ancestors, command: req.intended ?? peer.runCommand) else { continue }
            granted.append(name)
            if !covering.contains(g) { covering.append(g) }
        }
        let rest = present.filter { !infos[$0]!.agentSafe && !granted.contains($0) }
        func some(_ a: [String]) -> [String]? { a.isEmpty ? nil : a }
        return Response(ok: true, missing: some(missing), grants: covering.isEmpty ? nil : covering,
                        agentSafe: some(safe), granted: some(granted), needsApproval: some(rest))
    }

    func get(_ req: Request, peer: PeerInfo) throws -> Response {
        let names = Array(Set(req.names ?? [])).sorted()
        guard !names.isEmpty else { return Response(ok: false, error: "no names given") }
        let infos = Dictionary(uniqueKeysWithValues: try store.list().map { ($0.name, $0) })
        let missing = names.filter { infos[$0] == nil }
        let present = names.filter { infos[$0] != nil }
        let cwd = peer.cwd
        let needApproval = present.filter { !(infos[$0]!.agentSafe) }
        var byGrant: [Grant: [String]] = [:]
        // Over SSH this Mac sees only the ssh client, so no grant can stand for the caller.
        for name in needApproval where !peer.isSSHForward {
            if let g = grants.covering(name, cwd: cwd, ancestors: peer.ancestors, command: peer.runCommand) { byGrant[g, default: []].append(name) }
        }
        let granted = byGrant.values.flatMap { $0 }
        for (g, names) in byGrant.sorted(by: { $0.key.id < $1.key.id }) {
            log("get", names.sorted(), "allowed (grant \(g.id))", peer, req)
        }
        let toAsk = needApproval.filter { !granted.contains($0) }

        var denied: [String] = []
        if !toAsk.isEmpty {
            switch ask(.read, toAsk, peer, req, "release \(Self.count(toAsk)), asked by \(Self.describe(peer, req))", offersGrant: true) {
            case .deny:
                denied = toAsk
                log("get", toAsk, "denied", peer, req)
            case .once:
                log("get", toAsk, "approved", peer, req)
            case .grant(let choice):
                if cwd.isEmpty || Grant.normalize(cwd) == "/" || peer.isSSHForward {
                    log("get", toAsk, "approved", peer, req)
                } else {
                    let session = choice.untilAgentQuits ? peer.sessionProcess.map { GrantSession(process: $0.stamp, name: $0.name) } : nil
                    let commands = choice.thisCommandOnly ? peer.runCommand.map { [$0] } : nil
                    let g = grants.add(names: toAsk, folder: cwd, duration: choice.duration, createdBy: Self.who(peer),
                                       session: session, commands: commands)
                    let limits = g.limits.isEmpty ? "" : ", \(g.limits)"
                    log("get", toAsk, "approved (grant \(g.id) for \(GrantStore.describe(choice.duration))\(limits))", peer, req)
                }
            }
        }
        let released = present.filter { !denied.contains($0) }
        let autoReleased = released.filter { infos[$0]!.agentSafe }
        if !autoReleased.isEmpty { log("get", autoReleased, "allowed (agent-safe)", peer, req) }

        let values = denied.isEmpty ? try store.values(released) : [:]
        if denied.isEmpty, !byGrant.isEmpty { grants.used(byGrant.keys.map(\.id)) }
        return Response(ok: true, values: values,
                        masked: released.filter { infos[$0]!.kind.isSecret },
                        denied: denied.isEmpty ? nil : denied,
                        missing: missing.isEmpty ? nil : missing)
    }

    func set(_ req: Request, peer: PeerInfo) throws -> Response {
        guard let name = req.names?.first, req.names?.count == 1 else { return Response(ok: false, error: "set takes one name") }
        guard Wire.isValidName(name) else { throw StoreError.badName(name) }
        let isNew = (try store.info(name)) == nil
        let verb = isNew ? "add" : "change"
        guard ask(isNew ? .add : .change, [name], peer, req, "\(verb) \(name), asked by \(Self.describe(peer, req))").allowed else {
            log("set", [name], "denied", peer, req)
            return Response(ok: false, error: "change to \(name) was not approved")
        }
        if !isNew, let value = req.value { try keepCurrent(name, reason: .changed, by: Self.who(peer), unlessEqualTo: value) }
        try store.save(name: name, value: req.value, kind: req.kind, agentSafe: req.agentSafe, note: req.note, usedIn: nil,
                       service: req.service)
        if isNew { try addToOwnEnvironment([name]) }
        pruneVersions()
        log("set", [name], "approved", peer, req)
        return Response(ok: true)
    }

    /// Latchkey for Safari filling one item into a field on the page you're on. Only that item, only on a site it may
    /// go to (the item's own fill sites, else `Services.mayFill`'s default; decided here, not by the extension), and
    /// only with your approval every time: no
    /// grant, recent approval or agent-safe setting stands in, because the value leaves Latchkey for a web page.
    func fill(_ req: Request, peer: PeerInfo) throws -> Response {
        guard peer.isSafariExtension else { return Response(ok: false, error: "fill is only for Latchkey for Safari") }
        guard let name = req.names?.first, req.names?.count == 1 else { return Response(ok: false, error: "fill takes one name") }
        guard let info = try store.info(name) else { return Response(ok: true, missing: [name]) }
        guard let page = req.page, let host = Services.fillHost(page), Services.mayFill(origin: page, item: info) else {
            log("fill", [name], "refused (not a site it may be filled on: \(req.page ?? "no page"))", peer, req)
            let allowed = info.fillSites.map { "only on \($0.joined(separator: ", "))" } ?? "only on its service's own site and where deployments keep their environment variables"
            return Response(ok: false, error: "\(name) can't be filled on this site. It may be filled \(allowed); change that in Latchkey.")
        }
        guard ask(.read, [name], peer, req, "fill \(name) into a field on \(host)").allowed else {
            log("fill", [name], "denied", peer, req)
            return Response(ok: false, error: "filling \(name) was not approved")
        }
        let values = try store.values([name])
        log("fill", [name], "approved (into a field on \(host))", peer, req)
        return Response(ok: true, values: values)
    }

    /// Deletes one or many items with one approval. If any named item is missing nothing is deleted, so a typo
    /// in a list never leaves half of it gone.
    func remove(_ req: Request, peer: PeerInfo) throws -> Response {
        let names = Array(Set(req.names ?? [])).sorted()
        guard !names.isEmpty else { return Response(ok: false, error: "no names given") }
        let existing = Set(try store.list().map(\.name))
        let missing = names.filter { !existing.contains($0) }
        if missing.count == names.count { return Response(ok: true, missing: missing) }
        guard missing.isEmpty else { return Response(ok: false, error: "no item named \(missing.joined(separator: ", ")); nothing deleted", missing: missing) }
        let what = names.count == 1 ? names[0] : Self.count(names)
        guard ask(.delete, names, peer, req, "delete \(what), asked by \(Self.describe(peer, req))").allowed else {
            log("rm", names, "denied", peer, req)
            return Response(ok: false, error: "removal of \(what) was not approved")
        }
        var done: [String] = []
        for name in names {
            do {
                try keepCurrent(name, reason: .deleted, by: Self.who(peer))
                _ = try store.remove(name)
                done.append(name)
            } catch {
                log("rm", done, "approved (stopped at \(name))", peer, req)
                return Response(ok: false, error: "deleted \(done.count) of \(names.count), then \(name) failed: \(error)")
            }
        }
        log("rm", names, "approved", peer, req)
        pruneVersions()
        return Response(ok: true)
    }

    /// Changes agent-safe, kind, service, note or fill sites on many items with one approval. Values are untouched.
    func update(_ req: Request, peer: PeerInfo) throws -> Response {
        let names = Array(Set(req.names ?? [])).sorted()
        guard !names.isEmpty else { return Response(ok: false, error: "no names given") }
        guard req.agentSafe != nil || req.kind != nil || req.service != nil || req.note != nil || req.fillSites != nil else {
            return Response(ok: false, error: "nothing to change: give agent-safe, kind, service, note or fill sites")
        }
        var sites: [String]?
        if let given = req.fillSites {
            switch Services.fillSites(given) {
            case .success(let s): sites = s
            case .failure(let e): return Response(ok: false, error: e.description)
            }
        }
        let existing = Set(try store.list().map(\.name))
        let missing = names.filter { !existing.contains($0) }
        guard missing.isEmpty else { return Response(ok: false, missing: missing) }
        var changes: [String] = []
        if let a = req.agentSafe { changes.append(a ? "let agents read" : "require approval for") }
        if let k = req.kind { changes.append("set the kind to \(k.label.lowercased()) for") }
        if let s = req.service { changes.append(s.isEmpty ? "clear the service of" : "set the service to \(s) for") }
        if req.note != nil { changes.append("change the note of") }
        if let s = sites { changes.append(s.isEmpty ? "let Safari fill on the default sites" : "let Safari fill only on \(s.joined(separator: ", "))") }
        let reason = "\(changes.joined(separator: " and ")) \(names.count == 1 ? names[0] : Self.count(names)), asked by \(Self.who(peer))"
        guard ask(.change, names, peer, req, reason).allowed else {
            log("update", names, "denied", peer, req)
            return Response(ok: false, error: "the change was not approved")
        }
        for name in names {
            try store.save(name: name, value: nil, kind: req.kind, agentSafe: req.agentSafe, note: req.note, usedIn: nil,
                           service: req.service, fillSites: sites)
        }
        log("update", names, sites.map { "approved (fill sites: \($0.isEmpty ? "default" : $0.joined(separator: ", ")))" } ?? "approved", peer, req)
        return Response(ok: true)
    }

    /// Many items, one approval. Existing items are skipped unless `replace` is set.
    func importItems(_ req: Request, peer: PeerInfo) throws -> Response {
        var byName: [String: ImportItem] = [:]
        for item in req.items ?? [] {
            guard Wire.isValidName(item.name) else { throw StoreError.badName(item.name) }
            guard !item.value.isEmpty else { return Response(ok: false, error: "\(item.name) has an empty value") }
            byName[item.name] = item   // last one wins, as in a .env file
        }
        let given = req.environments ?? []
        if let problem = Self.invalid(given) { return Response(ok: false, error: problem) }
        guard !byName.isEmpty || !given.isEmpty else { return Response(ok: false, error: "nothing to import") }
        let existing = Set(try store.list().map(\.name))
        let names = byName.keys.sorted()
        let toAdd = names.filter { !existing.contains($0) }
        let toReplace = req.replace == true ? names.filter { existing.contains($0) } : []
        let skipped = req.replace == true ? [] : names.filter { existing.contains($0) }
        let writing = toAdd + toReplace
        guard !writing.isEmpty else {
            // Nothing new to save, but the files still say which variables their environments have.
            if !given.isEmpty {
                guard ask(.change, given.map(\.scope), peer, req, "record which variables \(Self.describeScopes(given)) has, asked by \(Self.describe(peer, req))").allowed else {
                    log("import", [], "denied (environment records)", peer, req)
                    return Response(ok: false, error: "recording the environment was not approved")
                }
                try applyImported(given)
                log("import", given.map(\.scope), "approved (environment records only)", peer, req)
            }
            return Response(ok: true, added: [], replaced: [], skipped: skipped)
        }

        var what: [String] = []
        if !toAdd.isEmpty { what.append("add \(Self.count(toAdd))") }
        if !toReplace.isEmpty { what.append("overwrite \(Self.count(toReplace))") }
        var from = ""
        if let src = req.source, !src.isEmpty { from = " from \(Self.tilde(src))" }
        if !given.isEmpty { from += " and record which variables \(Self.describeScopes(given)) has" }
        guard ask(.importItems, writing, peer, req, "\(what.joined(separator: " and "))\(from), asked by \(Self.describe(peer, req))").allowed else {
            log("import", writing, "denied", peer, req)
            return Response(ok: false, error: "import was not approved")
        }
        var done: [String] = []
        for name in writing {
            let i = byName[name]!
            do {
                if toReplace.contains(name) { try keepCurrent(name, reason: .changed, by: Self.who(peer), unlessEqualTo: i.value) }
                try store.save(name: name, value: i.value, kind: i.kind, agentSafe: i.agentSafe, note: i.note, usedIn: i.usedIn,
                               service: i.service)
                done.append(name)
            } catch {
                log("import", done, "approved (stopped at \(name))", peer, req)
                return Response(ok: false, error: "saved \(done.count) of \(writing.count), then \(name) failed: \(error)",
                                added: toAdd.filter(done.contains), replaced: toReplace.filter(done.contains), skipped: skipped)
            }
        }
        try applyImported(given)
        log("import", writing, given.isEmpty ? "approved" : "approved (and recorded \(Self.describeScopes(given)))", peer, req)
        pruneVersions()
        return Response(ok: true, added: toAdd, replaced: toReplace, skipped: skipped)
    }

    /// A grant made ahead of time, e.g. before leaving an agent to work.
    func grant(_ req: Request, peer: PeerInfo) throws -> Response {
        let names = Array(Set(req.names ?? [])).sorted()
        guard !names.isEmpty else { return Response(ok: false, error: "no names given") }
        let existing = try store.list().map(\.name)
        let missing = names.filter { entry in
            if Grant.isPattern(entry) { return !existing.contains { Grant.entry(entry, matches: $0) } }
            return !Wire.isValidName(entry) || !existing.contains(entry)
        }
        guard missing.isEmpty else { return Response(ok: false, missing: missing) }
        guard !peer.isSSHForward else { return Response(ok: false, error: "grants can't be made over SSH: make them on the Mac running Latchkey") }
        let folder = Grant.normalize(req.folder ?? peer.cwd)
        guard !folder.isEmpty, folder != "/" else { return Response(ok: false, error: "a grant needs a folder other than /") }
        var duration = min(req.duration ?? 3600, GrantStore.longest)
        guard duration > 0 else { return Response(ok: false, error: "the duration must be positive") }
        if req.origin == "mcp" {
            // An agent asking for itself: only its own folder, nothing in production or a whole project, a day at most.
            if let entry = names.first(where: Self.reachesProduction) {
                return Response(ok: false, error: "an agent can't ask for \(entry): grants it asks for can't include production or a whole project. The owner can grant it with latchkey grant.")
            }
            guard folder == Grant.normalize(peer.cwd) else {
                return Response(ok: false, error: "an agent can only ask for a grant on the folder it runs in")
            }
            duration = min(duration, Self.longestAgentGrant)
            guard req.session == true else {
                return Response(ok: false, error: "a grant an agent asks for lasts only for its session; ask with session")
            }
        }
        var session: GrantSession?
        if req.session == true {
            guard let p = peer.sessionProcess else {
                return Response(ok: false, error: "no agent process to tie the grant to: run it from the agent's session, or leave out --session")
            }
            session = GrantSession(process: p.stamp, name: p.name)
        }
        if let uses = req.uses, uses < 1 { return Response(ok: false, error: "uses must be 1 or more") }
        if let commands = req.commands, commands.isEmpty || commands.contains(where: \.isEmpty) {
            return Response(ok: false, error: "each command needs at least one word")
        }
        let worktrees = Repo.commonDir(for: folder) != nil ? " (and its worktrees)" : ""
        let preview = Grant(names: names, folder: folder, expires: Date(), createdBy: "", session: session, commands: req.commands, usesLeft: req.uses)
        let limits = preview.limits.isEmpty ? "" : " (\(preview.limits))"
        let reason = "let programs in \(Self.tilde(folder))\(worktrees) read \(Self.count(names)) without asking for \(GrantStore.describe(duration))\(limits), asked by \(Self.who(peer))"
        guard ask(.grant, names, peer, req, reason, duration: duration, folder: folder).allowed else {
            log("grant", names, "denied", peer, req)
            return Response(ok: false, error: "the grant was not approved")
        }
        let g = grants.add(names: names, folder: folder, duration: duration, createdBy: Self.who(peer),
                           session: session, commands: req.commands, uses: req.uses)
        log("grant", names, "approved (grant \(g.id) for \(GrantStore.describe(duration))\(limits))", peer, req)
        return Response(ok: true, grants: [g])
    }

    /// Moves items into a project and environment (or back to shared), keeping value and metadata. All or
    /// nothing up front: every target id must be free before anything moves. Files that reference the old ids
    /// are the caller's to update, from `moved` and each item's `usedIn`.
    func move(_ req: Request, peer: PeerInfo) throws -> Response {
        let ids = Array(Set(req.names ?? [])).sorted()
        guard !ids.isEmpty else { return Response(ok: false, error: "no names given") }
        let project = req.project ?? "", environment = project.isEmpty ? "" : (req.environment ?? "")
        let infos = Dictionary(uniqueKeysWithValues: try store.list().map { ($0.name, $0) })
        let missing = ids.filter { infos[$0] == nil }
        guard missing.isEmpty else { return Response(ok: false, missing: missing) }
        var targets: [String: String] = [:]
        for id in ids {
            let target = ItemID(project: project, environment: environment, name: infos[id]!.ref.name)
            guard target.isValid else {
                return Response(ok: false, error: "\(project)/\(environment) is not a valid project and environment")
            }
            if target.string != id { targets[id] = target.string }
        }
        guard !targets.isEmpty else { return Response(ok: true, moved: [:]) }
        let taken = targets.values.filter { infos[$0] != nil }.sorted()
        guard taken.isEmpty else { return Response(ok: false, error: "already exists: \(taken.joined(separator: ", "))") }
        guard Set(targets.values).count == targets.count else { return Response(ok: false, error: "two items would get the same id") }

        let moving = targets.keys.sorted()
        let place = project.isEmpty ? "shared items" : "\(project)/\(environment)"
        guard ask(.move, moving, peer, req, "move \(Self.count(moving)) to \(place), asked by \(Self.who(peer))").allowed else {
            log("move", moving, "denied", peer, req)
            return Response(ok: false, error: "the move was not approved")
        }
        let values = try store.values(moving)
        var done: [String: String] = [:]
        for id in moving {
            let info = infos[id]!, to = targets[id]!
            do {
                guard let value = values[id] else { throw StoreError.notFound(id) }
                try store.save(name: to, value: value, kind: info.kind, agentSafe: info.agentSafe, note: info.note,
                               usedIn: info.usedIn, service: info.service ?? "", fillSites: info.fillSites ?? [])
                _ = try store.remove(id)
                try versions.rename(from: id, to: to)
                done[id] = to
            } catch {
                try? recordMoves(done)
                log("move", done.keys.sorted(), "approved (stopped at \(id))", peer, req)
                return Response(ok: false, error: "moved \(done.count) of \(moving.count), then \(id) failed: \(error)", moved: done)
            }
        }
        try recordMoves(done)
        log("move", moving, "approved (to \(place))", peer, req)
        return Response(ok: true, moved: done)
    }

    // MARK: environment records

    static func describeScopes(_ records: [EnvironmentRecord]) -> String {
        let scopes = Array(Set(records.map(\.scope))).sorted()
        return scopes.count == 1 ? scopes[0] : "\(scopes.count) environments"
    }

    /// Nil when every record is well formed: a valid scope, variable names and item IDs, and plain values that are
    /// plain (no references, at most 4 KB).
    static func invalid(_ records: [EnvironmentRecord]) -> String? {
        for r in records {
            guard RemoteLink.isValidScope(r.scope) else { return "\(r.scope) is not a valid project and environment" }
            for (name, entry) in r.variables {
                guard EnvironmentRecord.isValidVariable(name) else { return "\(name) is not a valid variable name" }
                switch entry {
                case .credential(let id):
                    guard Wire.isValidName(id) else { return "\(id) is not a valid item id" }
                case .literal(let v):
                    if v.contains(References.scheme) || v.contains(References.fileScheme) {
                        return "\(name): a plain value can't hold a latchkey reference; point it at the item instead"
                    }
                    if v.utf8.count > 4096 { return "\(name): plain values are limited to 4 KB" }
                    if !EnvironmentMigration.isPlainSetting(v) && EnvironmentRecord.mayBeSecret(name: name, value: v) {
                        return "\(name) looks like a secret; save it as an item (lk set) and point the variable at it"
                    }
                }
            }
        }
        return nil
    }

    /// After an import: each file's variables join its environment's record, for the items that now exist. Several
    /// files for one environment apply in order, later ones winning, as when they're loaded.
    private func applyImported(_ given: [EnvironmentRecord]) throws {
        guard !given.isEmpty else { return }
        let items = try store.list()
        let ids = Set(items.map(\.name))
        var byScope: [String: [String: EnvironmentEntry]] = [:]
        var order: [String] = []
        for r in given {
            if byScope[r.scope] == nil { order.append(r.scope) }
            for (name, entry) in r.variables where entry.item.map(ids.contains) ?? true { byScope[r.scope, default: [:]][name] = entry }
        }
        let stored = Dictionary(uniqueKeysWithValues: try records.environments().map { ($0.scope, $0) })
        for scope in order {
            guard let vars = byScope[scope], !vars.isEmpty else { continue }
            try records.save(EnvironmentRecords.applying(vars, to: stored[scope], scope: scope, items: items))
        }
    }

    /// New project items join their environment's record when it has one and the name is free. With no record yet,
    /// the environment keeps working as before until one is made.
    private func addToOwnEnvironment(_ ids: [String]) throws {
        let stored = Dictionary(uniqueKeysWithValues: try records.environments().map { ($0.scope, $0) })
        var changed: [String: EnvironmentRecord] = [:]
        for id in ids {
            guard let ref = ItemID(id), !ref.isShared else { continue }
            let scope = "\(ref.project)/\(ref.environment)"
            guard var r = changed[scope] ?? stored[scope], r.variables[ref.name] == nil else { continue }
            r.set(ref.name, .credential(id))
            r.updatedAt = Date()
            changed[scope] = r
        }
        for r in changed.values { try records.save(r) }
    }

    /// Records follow moved items to their new IDs, as files do.
    private func recordMoves(_ moved: [String: String]) throws {
        guard !moved.isEmpty else { return }
        for r in EnvironmentRecords.renaming(try records.environments(), moved) { try records.save(r) }
        try addToOwnEnvironment(Array(moved.values))
    }

    /// `env migrate`: adds variables to records where they're missing, with one approval. Never changes a stored
    /// variable, so it's safe to run again.
    func addToEnvironments(_ req: Request, peer: PeerInfo) throws -> Response {
        let given = req.environments ?? []
        guard !given.isEmpty else { return Response(ok: false, error: "no environments given") }
        if let problem = Self.invalid(given) { return Response(ok: false, error: problem) }
        guard Set(given.map(\.scope)).count == given.count else { return Response(ok: false, error: "an environment is given twice") }
        let stored = Dictionary(uniqueKeysWithValues: try records.environments().map { ($0.scope, $0) })
        let planned = given.map { EnvironmentRecords.adding($0, to: stored[$0.scope]) }
        let changed = planned.filter { $0.record != stored[$0.record.scope] }
        guard !changed.isEmpty else { return Response(ok: true, environments: []) }
        let count = changed.reduce(0) { $0 + $1.added.count }
        let scopes = changed.map(\.record.scope)
        let what = count == 0 ? "mark \(Self.describeScopes(changed.map(\.record))) as checked"
            : "record \(count) variable\(count == 1 ? "" : "s") in \(Self.describeScopes(changed.map(\.record)))"
        guard ask(.change, scopes, peer, req, "\(what), from your items and the files they came from, asked by \(Self.describe(peer, req))").allowed else {
            log("environment-add", scopes, "denied", peer, req)
            return Response(ok: false, error: "recording the environments was not approved")
        }
        for c in changed { try records.save(c.record) }
        log("environment-add", scopes, "approved (\(count) variable\(count == 1 ? "" : "s"))", peer, req)
        return Response(ok: true, environments: changed.map(\.record))
    }

    /// `env set`, `env unset`, `env confirm`: one environment, one approval.
    func setEnvironment(_ req: Request, peer: PeerInfo) throws -> Response {
        guard let scope = req.names?.first, req.names?.count == 1, RemoteLink.isValidScope(scope) else {
            return Response(ok: false, error: "give one environment, such as shop/development")
        }
        if let r = req.environments?.first, r.scope != scope || req.environments!.count > 1 {
            return Response(ok: false, error: "the variables given are for another environment")
        }
        let set = req.environments?.first?.variables ?? [:]
        if let problem = Self.invalid([EnvironmentRecord(scope: scope, variables: set)]) { return Response(ok: false, error: problem) }
        let unset = Array(Set(req.unset ?? [])).sorted(), confirm = Array(Set(req.confirm ?? [])).sorted()
        guard !set.isEmpty || !unset.isEmpty || !confirm.isEmpty else { return Response(ok: false, error: "nothing to change") }
        let items = try store.list()
        let ids = Set(items.map(\.name))
        let missing = set.values.compactMap(\.item).filter { !ids.contains($0) }
        guard missing.isEmpty else { return Response(ok: false, missing: Array(Set(missing)).sorted()) }
        var record = try records.environments().first { $0.scope == scope } ?? EnvironmentRecords.seeded(scope: scope, items: items, now: Date())
        let unknown = (unset + confirm).filter { record.variables[$0] == nil && set[$0] == nil }
        guard unknown.isEmpty else { return Response(ok: false, error: "\(scope) has no variable \(unknown.joined(separator: ", "))") }
        var parts: [String] = []
        if !set.isEmpty { parts.append("set \(set.keys.sorted().joined(separator: ", "))") }
        if !unset.isEmpty { parts.append("remove \(unset.joined(separator: ", "))") }
        if !confirm.isEmpty { parts.append("confirm \(confirm.joined(separator: ", "))") }
        let reason = "\(parts.joined(separator: " and ")) in \(scope), asked by \(Self.describe(peer, req))"
        guard ask(.change, [scope], peer, req, reason).allowed else {
            log("environment-set", [scope], "denied", peer, req)
            return Response(ok: false, error: "the change to \(scope) was not approved")
        }
        for (name, entry) in set { record.set(name, entry) }
        for name in unset { record.unset(name) }
        record.inferred.removeAll { confirm.contains($0) }
        record.updatedAt = Date()
        try records.save(record)
        log("environment-set", [scope], "approved (\(parts.joined(separator: "; ")))", peer, req)
        return Response(ok: true, environments: [record])
    }

    /// `env rm`: forgets an environment's record. Its items stay; `run --env` goes back to finding them by ID.
    func removeEnvironment(_ req: Request, peer: PeerInfo) throws -> Response {
        guard let scope = req.names?.first, req.names?.count == 1, RemoteLink.isValidScope(scope) else {
            return Response(ok: false, error: "give one environment, such as shop/development")
        }
        guard try records.environments().contains(where: { $0.scope == scope }) else { return Response(ok: true, missing: [scope]) }
        guard ask(.delete, [scope], peer, req, "forget the record of \(scope) (its items stay), asked by \(Self.describe(peer, req))").allowed else {
            log("environment-remove", [scope], "denied", peer, req)
            return Response(ok: false, error: "removing the record of \(scope) was not approved")
        }
        try records.removeEnvironment(scope)
        log("environment-remove", [scope], "approved", peer, req)
        return Response(ok: true)
    }

    /// Values for `lk export --values`, which writes them to a file in plain text, or with `clipboard` puts them on the
    /// clipboard. Always asks, naming the file or the environment: no grant, agent-safe setting or earlier approval
    /// stands in, because the values leave Latchkey for good (a file can at least be found again; a copy can't). The
    /// file is the caller's claim, shown as such; an agent through `latchkey mcp` can't ask at all.
    func export(_ req: Request, peer: PeerInfo) throws -> Response {
        guard req.origin != "mcp" else {
            return Response(ok: false, error: "an agent can't export values in plain text; it can export references (lk export without --values)")
        }
        guard !peer.isSafariExtension else { return Response(ok: false, error: "export isn't available to Safari") }
        let clipboard = req.clipboard == true
        let names = Array(Set(req.names ?? [])).sorted()
        guard !names.isEmpty else { return Response(ok: false, error: "no names given") }
        if clipboard {
            guard req.project != nil else { return Response(ok: false, error: "copying to the clipboard needs the environment") }
            guard !peer.isSSHForward else { return Response(ok: false, error: "the clipboard is on the other computer; copy there, or write a file with lk export --values --out") }
        } else {
            guard let dest = req.destination, dest.hasPrefix("/") else { return Response(ok: false, error: "export needs the full path of the file it writes") }
        }
        let existing = Set(try store.list().map(\.name))
        let missing = names.filter { !existing.contains($0) }
        guard missing.isEmpty else { return Response(ok: false, missing: missing) }
        let scope = req.project.map { " from \($0)" } ?? ""
        let dest = req.destination ?? ""
        let reason: String
        if clipboard {
            reason = "copy \(Self.count(names))\(scope) to the clipboard in plain text, for this Mac only and cleared after \(Int(Clipboard.clearAfter)) seconds, asked by \(Self.describe(peer, req))"
        } else {
            let place = peer.isSSHForward ? "\(dest) on another computer" : Self.tilde(dest)
            reason = "write \(Self.count(names))\(scope) in plain text to \(place), asked by \(Self.describe(peer, req))"
        }
        guard ask(.read, names, peer, req, reason).allowed else {
            log("export", names, clipboard ? "denied (copy to the clipboard)" : "denied (plain text to \(dest))", peer, req)
            return Response(ok: false, error: "the export was not approved")
        }
        let values = try store.values(names)
        log("export", names, clipboard ? "approved (copied to the clipboard)" : "approved (plain text to \(dest))", peer, req)
        return Response(ok: true, values: values)
    }

    /// Remembers remotes as a project's, so its checkouts elsewhere are recognized. A remote belongs to one project.
    func linkProject(_ req: Request, peer: PeerInfo) throws -> Response {
        guard let name = req.project, ItemID.isValidPart(name) else { return Response(ok: false, error: "give a project name") }
        let origins = Array(Set(req.origins ?? [])).sorted()
        guard !origins.isEmpty else { return Response(ok: false, error: "no remotes given") }
        if let bad = origins.first(where: { GitRemotes.normalize($0) != $0 }) { return Response(ok: false, error: "\(bad) is not a normalized remote") }
        let all = try records.projects()
        if let other = all.first(where: { $0.name != name && !Set($0.origins).isDisjoint(with: origins) }) {
            let shared = origins.filter(other.origins.contains)
            return Response(ok: false, error: "\(shared.joined(separator: ", ")) belongs to project \(other.name); unlink it there first (lk project unlink \(other.name) \(shared[0]))")
        }
        var project = all.first { $0.name == name } ?? ProjectRecord(name: name, origins: [])
        let new = origins.filter { !project.origins.contains($0) }
        guard !new.isEmpty else { return Response(ok: true, projects: [project]) }
        guard ask(.change, [name], peer, req, "remember \(new.joined(separator: ", ")) as project \(name), so its checkouts on your Macs are recognized, asked by \(Self.describe(peer, req))").allowed else {
            log("project-link", [name], "denied", peer, req)
            return Response(ok: false, error: "linking \(name) was not approved")
        }
        project.origins = Array(Set(project.origins + new)).sorted()
        try records.save(project)
        log("project-link", [name], "approved (\(new.joined(separator: ", ")))", peer, req)
        return Response(ok: true, projects: [project])
    }

    func unlinkProject(_ req: Request, peer: PeerInfo) throws -> Response {
        guard let name = req.project, var project = try records.projects().first(where: { $0.name == name }) else {
            return Response(ok: false, error: "no project \(req.project ?? "") is linked")
        }
        let origins = Set(req.origins ?? [])
        let removing = project.origins.filter(origins.contains)
        guard !removing.isEmpty else { return Response(ok: false, error: "\(name) isn't linked to \(origins.sorted().joined(separator: ", "))") }
        guard ask(.change, [name], peer, req, "forget \(removing.joined(separator: ", ")) as project \(name), asked by \(Self.describe(peer, req))").allowed else {
            log("project-unlink", [name], "denied", peer, req)
            return Response(ok: false, error: "unlinking \(name) was not approved")
        }
        project.origins.removeAll { origins.contains($0) }
        // With no remotes left there's nothing to recognize it by.
        if project.origins.isEmpty { try records.removeProject(project.id) } else { try records.save(project) }
        log("project-unlink", [name], "approved (\(removing.joined(separator: ", ")))", peer, req)
        return Response(ok: true, projects: [project])
    }

    // MARK: duplicates

    /// Which items hold the same value. The values are compared here and never returned, but reading them all is still
    /// reading them, so this asks every time (no grant or agent-safe setting stands in), and agents can't ask at all:
    /// which keys are shared is itself worth knowing.
    func duplicates(_ req: Request, peer: PeerInfo) throws -> Response {
        guard req.origin != "mcp" else { return Response(ok: false, error: "an agent can't compare values; ask the owner to run lk duplicates") }
        guard !peer.isSafariExtension else { return Response(ok: false, error: "finding duplicates isn't available to Safari") }
        let items = try store.list().filter { $0.kind.isSecret }
        guard !items.isEmpty else { return Response(ok: true, groups: []) }
        let names = items.map(\.name)
        guard ask(.compare, names, peer, req, "compare the values of \(Self.count(names)) to find duplicates (no value leaves Latchkey), asked by \(Self.describe(peer, req))").allowed else {
            log("duplicates", [], "denied", peer, req)
            return Response(ok: false, error: "finding duplicates was not approved")
        }
        let values = try store.values(names)
        let groups = Duplicates.groups(values: values, items: items)
        let identifiers = groups.joined().filter { id in
            values[id].map { Duplicates.looksLikeIdentifier(name: ItemID(id)?.name ?? id, value: $0) } ?? false
        }
        log("duplicates", groups.flatMap { $0 }, "approved (\(groups.count) group\(groups.count == 1 ? "" : "s"))", peer, req)
        return Response(ok: true, groups: groups, identifiers: identifiers)
    }

    /// Which values found in files equal a stored item. Like `duplicates`, the comparison happens here: the caller sends
    /// the values it found (`items`, each named by its position) and gets back only the IDs of the items they equal,
    /// never a stored value. It asks every time, and agents can't ask.
    func scan(_ req: Request, peer: PeerInfo) throws -> Response {
        guard req.origin != "mcp" else { return Response(ok: false, error: "an agent can't compare values; ask the owner to run lk scan") }
        guard !peer.isSafariExtension else { return Response(ok: false, error: "scanning files isn't available to Safari") }
        let found = (req.items ?? []).filter { $0.value.count >= Duplicates.shortest && !$0.value.contains(References.scheme) }
        let items = try store.list().filter { $0.kind.isSecret }
        guard !found.isEmpty, !items.isEmpty else { return Response(ok: true, matches: [:]) }
        let names = items.map(\.name)
        guard ask(.scan, names, peer, req, "compare \(found.count) value\(found.count == 1 ? "" : "s") found in files with the values of \(Self.count(names)) (no stored value leaves Latchkey), asked by \(Self.describe(peer, req))").allowed else {
            log("scan", [], "denied", peer, req)
            return Response(ok: false, error: "scanning was not approved")
        }
        var byValue: [String: [String]] = [:]
        for (id, value) in try store.values(names) where value.count >= Duplicates.shortest { byValue[value, default: []].append(id) }
        var matches: [String: [String]] = [:]
        for item in found { if let ids = byValue[item.value] { matches[item.name] = ids.sorted() } }
        log("scan", Set(matches.values.joined()).sorted(), "approved (\(matches.count) of \(found.count) match)", peer, req)
        return Response(ok: true, matches: matches)
    }

    /// Makes items holding one value into one shared item, `into`: it's created from them (or must already hold the same
    /// value), the others are deleted (kept in Recently Deleted), and environment records follow. Files are the caller's
    /// to update, from `moved` and each item's `usedIn`, as after a move.
    func combine(_ req: Request, peer: PeerInfo) throws -> Response {
        guard req.origin != "mcp" else { return Response(ok: false, error: "an agent can't combine items; ask the owner to run lk combine") }
        let ids = Array(Set(req.names ?? [])).sorted()
        guard ids.count >= 2 || (ids.count == 1 && req.into != ids.first) else { return Response(ok: false, error: "give the items to combine") }
        // Into a shared item, or into one item of the environment they're all in (two names for one value there).
        guard let into = req.into, let target = ItemID(into), Wire.isValidName(into),
              target.isShared || ids.allSatisfy({ ItemID($0).map { $0.project == target.project && $0.environment == target.environment } ?? false }) else {
            return Response(ok: false, error: "combine needs a shared item name, such as OPENAI_API_KEY, or an item in the environment they're all in")
        }
        let infos = Dictionary(uniqueKeysWithValues: try store.list().map { ($0.name, $0) })
        let missing = ids.filter { infos[$0] == nil }
        guard missing.isEmpty else { return Response(ok: false, missing: missing) }
        let values = try store.values(ids + (infos[into] != nil ? [into] : []))
        guard Set(ids.compactMap { values[$0] }).count == 1, let value = values[ids[0]] else {
            return Response(ok: false, error: "these items don't all hold the same value; nothing was combined")
        }
        if infos[into] != nil, values[into] != value {
            return Response(ok: false, error: "\(into) already exists with a different value; choose another name")
        }
        let sources = ids.filter { $0 != into }
        let what = "combine \(Self.count(ids)) into \(target.isShared ? "the shared item " : "")\(into)\(infos[into] != nil ? "" : " (new)")"
        guard ask(.move, ids, peer, req, "\(what); the others are deleted and references follow, asked by \(Self.who(peer))").allowed else {
            log("combine", ids, "denied", peer, req)
            return Response(ok: false, error: "combining was not approved")
        }
        if infos[into] == nil {
            let parts = ids.compactMap { infos[$0] }
            // The strictest settings among them: agents may read it only if they could read every one.
            let kind = parts.first?.kind ?? .token
            let services = Set(parts.compactMap(\.service))
            try store.save(name: into, value: value, kind: kind, agentSafe: parts.allSatisfy(\.agentSafe),
                           note: "combined from \(ids.joined(separator: ", "))", usedIn: parts.flatMap { $0.usedIn ?? [] },
                           service: services.count == 1 ? services.first! : "")
        } else {
            try store.save(name: into, value: nil, kind: nil, agentSafe: nil, note: nil, usedIn: sources.compactMap { infos[$0]?.usedIn }.flatMap { $0 })
        }
        var moved: [String: String] = [:]
        for id in sources {
            try keepCurrent(id, reason: .deleted, by: Self.who(peer))
            _ = try store.remove(id)
            moved[id] = into
        }
        for r in EnvironmentRecords.renaming(try records.environments(), moved) { try records.save(r) }
        pruneVersions()
        log("combine", ids, "approved (into \(into))", peer, req)
        return Response(ok: true, moved: moved)
    }

    // MARK: versions

    /// Saves the item's current value as a version before it's replaced or deleted. Skipped when the new value
    /// is the same as the old, so re-importing an unchanged file adds no history.
    private func keepCurrent(_ name: String, reason: Version.Reason, by: String, unlessEqualTo new: String? = nil) throws {
        guard let info = try store.info(name), let current = try store.values([name])[name], current != new else { return }
        try versions.record(info, value: current, reason: reason, by: by)
    }

    /// Prunes old versions. Never fails a request: history is a safety net, not the record.
    func pruneVersions() {
        guard let existing = try? Set(store.list().map(\.name)) else { return }
        try? versions.prune(existing: existing)
    }

    func history(_ req: Request) throws -> Response {
        guard let name = req.names?.first, req.names?.count == 1 else { return Response(ok: false, error: "history takes one item") }
        return Response(ok: true, versions: try versions.list(item: name))
    }

    private func version(_ req: Request) throws -> Version? {
        guard let id = req.version, let item = id.split(separator: "#").first.map(String.init) else { return nil }
        return try versions.list(item: item).first { $0.id == id }
    }

    /// An earlier value, for showing in the app. Always asks: grants and agent-safe don't cover history.
    func versionValue(_ req: Request, peer: PeerInfo) throws -> Response {
        guard let v = try version(req) else { return Response(ok: false, error: "no such version") }
        let when = v.savedAt.formatted(date: .abbreviated, time: .shortened)
        guard ask(.readVersion, [v.item], peer, req, "show the value \(v.item) had until \(when), asked by \(Self.who(peer))").allowed else {
            log("version", [v.item], "denied", peer, req)
            return Response(ok: false, denied: [v.item])
        }
        log("version", [v.item], "approved (value from \(when))", peer, req)
        return Response(ok: true, values: [v.id: try versions.value(v.id) ?? ""])
    }

    /// Puts a version back. If the item exists, its current value becomes a version first; if it was deleted,
    /// it comes back with the settings it had.
    func restore(_ req: Request, peer: PeerInfo) throws -> Response {
        guard let v = try version(req), let value = try versions.value(v.id) else { return Response(ok: false, error: "no such version") }
        let exists = try store.info(v.item) != nil
        let when = v.savedAt.formatted(date: .abbreviated, time: .shortened)
        let reason = exists ? "restore \(v.item) to its value from \(when), asked by \(Self.who(peer))"
                            : "bring back \(v.item), deleted \(when), asked by \(Self.who(peer))"
        guard ask(.restore, [v.item], peer, req, reason).allowed else {
            log("restore", [v.item], "denied", peer, req)
            return Response(ok: false, error: "the restore was not approved")
        }
        if exists { try keepCurrent(v.item, reason: .restored, by: Self.who(peer), unlessEqualTo: value) }
        try store.save(name: v.item, value: value, kind: v.kind, agentSafe: v.agentSafe, note: v.note, usedIn: v.usedIn,
                       service: v.service ?? "", fillSites: v.fillSites ?? [])
        log("restore", [v.item], "approved (value from \(when))", peer, req)
        pruneVersions()
        return Response(ok: true)
    }

    /// Deletes every version of the named items.
    func forget(_ req: Request, peer: PeerInfo) throws -> Response {
        let names = Array(Set(req.names ?? [])).sorted()
        guard !names.isEmpty else { return Response(ok: false, error: "no names given") }
        let found = try names.flatMap { try versions.list(item: $0) }
        guard !found.isEmpty else { return Response(ok: true, missing: names) }
        let what = names.count == 1 ? names[0] : Self.count(names)
        guard ask(.delete, names, peer, req, "forget the earlier values of \(what) for good, asked by \(Self.who(peer))").allowed else {
            log("forget", names, "denied", peer, req)
            return Response(ok: false, error: "forgetting the history was not approved")
        }
        for v in found { try versions.remove(v.id) }
        log("forget", names, "approved (\(found.count) version\(found.count == 1 ? "" : "s"))", peer, req)
        return Response(ok: true)
    }

    // MARK: remote locations

    func link(_ req: Request, peer: PeerInfo) throws -> Response {
        guard let scope = req.names?.first, RemoteLink.isValidScope(scope) else {
            return Response(ok: false, error: "link takes a project/environment, such as acp/production")
        }
        guard let target = req.target else { return Response(ok: false, error: "no target given") }
        if let problem = target.problem { return Response(ok: false, error: problem) }
        if let item = target.tokenItem {
            // The token item is read for pushes only. It must exist, and must not be one of the values the link pushes.
            guard ItemID(item) != nil else { return Response(ok: false, error: "\(item) is not a valid item ID for a token") }
            guard !item.hasPrefix(scope + "/") else { return Response(ok: false, error: "the token item can't be inside \(scope), or it would be pushed with the rest") }
            guard try store.list().contains(where: { $0.name == item }) else { return Response(ok: false, error: "no item \(item) to use as the token; create it first") }
            if let problem = target.nativeProblem { return Response(ok: false, error: problem) }
        } else if nativeOnly {
            return Response(ok: false, error: "this build pushes through each service's API: name an item that holds the access token (token=ITEM)")
        }
        if try remotes.all().contains(where: { $0.scope == scope && $0.target == target }) {
            return Response(ok: false, error: "\(scope) is already linked to \(target.label)")
        }
        guard ask(.link, [scope], peer, req, "link \(scope) to \(target.label)\(target.tokenItem.map { " using the token in \($0)" } ?? ""), asked by \(Self.who(peer))", targets: [target.label + (target.tokenItem.map { " (token: \($0))" } ?? "")]).allowed else {
            log("link", [scope], "denied", peer, req)
            return Response(ok: false, error: "the link was not approved")
        }
        let link = RemoteLink(scope: scope, target: target)
        try remotes.save(link)
        log("link", [scope], "approved (\(target.label))", peer, req)
        return Response(ok: true, links: [link])
    }

    /// Removing a link takes nothing away from you, so it doesn't ask.
    func unlink(_ req: Request, peer: PeerInfo) throws -> Response {
        guard let id = req.names?.first else { return Response(ok: false, error: "unlink takes a link id") }
        guard let link = try remotes.all().first(where: { $0.id == id }) else { return Response(ok: true, missing: [id]) }
        try remotes.remove(id)
        log("unlink", [link.scope], "unlinked \(link.target.label)", peer, req)
        return Response(ok: true)
    }

    /// When an item's current value was set: its newest version is the value it replaced.
    func valueChangedAt(_ item: String) -> Date? { try? versions.list(item: item).first?.savedAt }

    /// How a link reaches its service: nil for the service's command-line tool, or the token item whose value
    /// authorizes requests to its API (with what stops it from working, if anything).
    struct NativeRoute {
        var item: String
        var problem: String?
    }

    func nativeRoute(_ link: RemoteLink) -> NativeRoute? {
        if let item = link.target.tokenItem { return NativeRoute(item: item, problem: link.target.nativeProblem) }
        if nativeOnly { return NativeRoute(item: "", problem: "this build pushes through the service's API: link it again with a token item (token=ITEM)") }
        return nil
    }

    /// Compares names with each link's target. Reads names only; never sends or keeps a value.
    /// One variable an environment sends to its links: an item (wherever it lives) under the variable's name, or a plain
    /// setting. `key` is what a link records the push under: the item's ID, or `project/environment/NAME` for a setting.
    struct PushEntry {
        var name: String
        var item: String?
        var literal: String?
        var secret: Bool
        var unconfirmed: Bool
        var key: String
    }

    /// What `scope` sends to its links. With a record: each of its variables, shared items and plain settings included,
    /// plus, until `env migrate` has checked it, the environment's own items the record doesn't name yet. Without one:
    /// the environment's own items, as before records.
    func pushEntries(_ scope: String) throws -> [PushEntry] {
        let all = try store.list()
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        let own = all.filter { $0.name.hasPrefix(scope + "/") }
        func item(_ i: SecretInfo, as name: String, unconfirmed: Bool = false) -> PushEntry {
            PushEntry(name: name, item: i.name, literal: nil, secret: i.kind.isSecret, unconfirmed: unconfirmed, key: i.name)
        }
        guard let record = try records.environments().first(where: { $0.scope == scope }) else {
            return own.map { item($0, as: $0.ref.name) }
        }
        var out: [PushEntry] = record.variables.keys.sorted().map { name in
            let unconfirmed = record.inferred.contains(name)
            switch record.variables[name]! {
            case .credential(let id):
                return byID[id].map { item($0, as: name, unconfirmed: unconfirmed) }
                    ?? PushEntry(name: name, item: id, literal: nil, secret: true, unconfirmed: unconfirmed, key: id)
            case .literal(let v):
                return PushEntry(name: name, item: nil, literal: v, secret: false, unconfirmed: unconfirmed, key: "\(scope)/\(name)")
            }
        }
        if !record.legacyChecked {
            out += own.filter { record.variables[$0.ref.name] == nil }.map { item($0, as: $0.ref.name) }
        }
        return out
    }

    func remoteStatus(_ req: Request) throws -> Response {
        guard let scope = req.names?.first, RemoteLink.isValidScope(scope) else { return Response(ok: false, error: "status takes a project/environment") }
        let entries = try pushEntries(scope)
        let expected = Set(entries.map(\.name))
        var out: [RemoteStatus] = []
        for link in try remotes.all() where link.scope == scope {
            let stale = entries.filter { e in e.item.map { link.state(of: $0, valueChangedAt: valueChangedAt($0)) == .outOfDate } ?? false }
                .map(\.name).sorted()
            if let route = nativeRoute(link) {
                // Names only: the token is read for the request and nothing it returns is kept except names.
                let listed: Result<[String], NativeRemoteError>
                if let problem = route.problem { listed = .failure(.invalidTarget(problem)) }
                else if let token = try store.values([route.item])[route.item] {
                    do { listed = .success(try native.names(link.target, token: token)) } catch { listed = .failure(error as? NativeRemoteError ?? .network) }
                } else { listed = .failure(.badToken) }
                switch listed {
                case .failure(let e): out.append(RemoteStatus(link: link.id, label: link.target.label, error: Self.redact(e.message, [route.item]), outOfDate: stale))
                case .success(let names):
                    let there = Set(names)
                    out.append(RemoteStatus(link: link.id, label: link.target.label, missing: expected.subtracting(there).sorted(),
                                            extra: there.subtracting(expected).sorted(), outOfDate: stale))
                }
                continue
            }
            let r = runner.run(link.target.listCommand, timeout: 60)
            guard r.status == 0, let names = link.target.names(fromListOutput: r.stdout) else {
                out.append(RemoteStatus(link: link.id, label: link.target.label, error: Self.toolError(r, link.target), outOfDate: stale))
                continue
            }
            let there = Set(names)
            out.append(RemoteStatus(link: link.id, label: link.target.label, missing: expected.subtracting(there).sorted(),
                                    extra: there.subtracting(expected).sorted(), outOfDate: stale))
        }
        return Response(ok: true, remoteStatus: out)
    }

    /// Sends an environment's values to its links with the services' own tools. Always asks, every time: no
    /// grant covers a push, production needs its own confirmation, and only the app does it.
    func push(_ req: Request, peer: PeerInfo) throws -> Response {
        guard allowsPush else { return Response(ok: false, error: "pushes run in the Latchkey app, where production can be confirmed; open it and try again") }
        guard let scope = req.names?.first, RemoteLink.isValidScope(scope) else { return Response(ok: false, error: "push takes a project/environment") }
        let links = try remotes.all().filter { $0.scope == scope && (req.link == nil || $0.id == req.link) }
        guard !links.isEmpty else { return Response(ok: false, error: req.link == nil ? "\(scope) isn't linked anywhere" : "no such link for \(scope)") }
        var entries = try pushEntries(scope)
        if let only = req.only { entries = entries.filter { e in only.contains(e.key) || only.contains(e.name) || e.item.map(only.contains) == true } }
        // Unconfirmed variables (found through old file locations) aren't sent until someone confirms them.
        let held = entries.filter(\.unconfirmed)
        entries = entries.filter { !$0.unconfirmed }
        guard !entries.isEmpty else {
            return Response(ok: false, error: held.isEmpty ? "nothing to push in \(scope)"
                            : "\(scope) has only unconfirmed variables: \(held.map(\.name).joined(separator: ", ")) (lk env confirm \(scope))")
        }

        // Links that push through an API say which item holds their token, and it has to exist before anyone is asked.
        for link in links { if let problem = nativeRoute(link)?.problem { return Response(ok: false, error: "\(link.target.label): \(problem)") } }
        let tokenItems = Array(Set(links.compactMap { nativeRoute($0)?.item })).sorted()
        let known = Set(try store.list().map(\.name))
        if let missing = tokenItems.first(where: { !known.contains($0) }) {
            return Response(ok: false, error: "the token item \(missing) doesn't exist; create it, or link again with another item")
        }
        let labels = links.map { link in link.target.label + (nativeRoute(link).map { " (token: \($0.item))" } ?? "") }
        let names = entries.map(\.key)
        var request = approvalRequest(.push, names, peer, req,
                                      "push \(Self.count(names.map { ItemID($0)?.name ?? $0 })) to \(labels.joined(separator: ", ")), asked by \(Self.who(peer))")
        request.targets = labels
        request.production = links.contains { $0.target.isProduction }
        guard approver.approve(request).allowed else {
            log("push", names, "denied", peer, req)
            return Response(ok: false, error: "the push was not approved")
        }

        let stored = try store.values(entries.compactMap(\.item))
        let tokens = try store.values(tokenItems)
        var values: [String: String] = [:]
        for e in entries { values[e.key] = e.item.flatMap { stored[$0] } ?? e.literal }
        var results: [PushResult] = []
        for var link in links {
            var batch: [(name: String, value: String, secret: Bool)] = []
            var ids: [String] = []
            for e in held {
                results.append(PushResult(link: link.id, item: e.key, ok: false, error: "not sent: unconfirmed in the environment's record (lk env confirm \(scope) \(e.name))"))
            }
            for e in entries {
                guard let value = values[e.key] else { results.append(PushResult(link: link.id, item: e.key, ok: false, error: "no value")); continue }
                if link.target.service == .fly && nativeRoute(link) == nil && value.contains("\n") {
                    results.append(PushResult(link: link.id, item: e.key, ok: false, error: "Fly secrets import takes one line per value"))
                    continue
                }
                batch.append((e.name, value, e.secret))
                ids.append(e.key)
            }
            if let route = nativeRoute(link) {
                let secrets = ids.compactMap { values[$0] }
                let outcomes: [Result<Void, NativeRemoteError>]
                if let token = tokens[route.item] { outcomes = native.push(link.target, token: token, values: batch) }
                else { outcomes = ids.map { _ in .failure(.badToken) } }
                for (id, outcome) in zip(ids, outcomes) {
                    switch outcome {
                    case .success:
                        link.pushed[id] = Date()
                        results.append(PushResult(link: link.id, item: id, ok: true))
                    case .failure(let e):
                        results.append(PushResult(link: link.id, item: id, ok: false, error: Self.redact(e.message, secrets + [tokens[route.item] ?? ""])))
                    }
                }
            } else {
                let commands = link.target.pushCommands(batch)
                // One command per item, except Fly, where one command carries them all.
                let groups: [[String]] = commands.count == ids.count ? ids.map { [$0] } : [ids]
                for (command, group) in zip(commands, groups) {
                    let r = runner.run(command, timeout: 120)
                    let secrets = group.compactMap { values[$0] }
                    for id in group {
                        if r.status == 0 {
                            link.pushed[id] = Date()
                            results.append(PushResult(link: link.id, item: id, ok: true))
                        } else {
                            results.append(PushResult(link: link.id, item: id, ok: false, error: Self.redact(Self.toolError(r, link.target), secrets)))
                        }
                    }
                }
            }
            try remotes.save(link)
            let ok = results.filter { $0.link == link.id && $0.ok }.count, failed = results.filter { $0.link == link.id && !$0.ok }.count
            log("push", ids, "approved (\(link.target.label)\(nativeRoute(link).map { ", token \($0.item)" } ?? ""): \(ok) pushed\(failed > 0 ? ", \(failed) failed" : ""))", peer, req)
        }
        let anyFailed = results.contains { !$0.ok }
        return Response(ok: !anyFailed, error: anyFailed ? "some values didn't reach their target" : nil, pushResults: results)
    }

    /// A tool's complaint, shortened, or why it couldn't run.
    static func toolError(_ r: (status: Int32, stdout: String, stderr: String), _ target: RemoteTarget) -> String {
        if r.status == 127 { return r.stderr }
        let text = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        let line = text.split(separator: "\n").last.map(String.init) ?? "exit status \(r.status)"
        return "\(target.service.tool): \(line.prefix(300))"
    }

    /// Belt and braces: no value appears in an error message, even if a tool echoed it.
    static func redact(_ text: String, _ secrets: [String]) -> String {
        secrets.filter { $0.count >= 4 }.reduce(text) { $0.replacingOccurrences(of: $1, with: "<value>") }
    }

    /// Taking access away never needs approval.
    func revoke(_ req: Request, peer: PeerInfo) -> Response {
        guard let id = req.names?.first else { return Response(ok: false, error: "revoke takes a grant id or all") }
        let gone = grants.all().filter { id == "all" || $0.id == id }
        let n = grants.revoke(id)
        guard n > 0 else { return Response(ok: true, missing: [id]) }
        log("revoke", Array(Set(gone.flatMap(\.names))).sorted(), "revoked \(n) grant\(n == 1 ? "" : "s")", peer, req)
        return Response(ok: true, info: ["revoked": String(n)])
    }

    private func ask(_ action: ApprovalRequest.Action, _ names: [String], _ peer: PeerInfo, _ req: Request,
                     _ reason: String, duration: TimeInterval? = nil, folder: String? = nil, targets: [String] = [],
                     offersGrant: Bool = false) -> ApprovalDecision {
        var request = approvalRequest(action, names, peer, req, reason, duration: duration, folder: folder)
        request.targets = targets
        request.offersGrant = offersGrant
        return approver.approve(request)
    }

    /// What the approval panel shows. Everything about the caller comes from the kernel: its folder, its command
    /// line, its parents, and whether it's Latchkey's own signed tool. Nothing the request says about itself is
    /// shown, except `folder` for a grant, which is what's being granted.
    private func approvalRequest(_ action: ApprovalRequest.Action, _ names: [String], _ peer: PeerInfo, _ req: Request,
                                 _ reason: String, duration: TimeInterval? = nil, folder: String? = nil) -> ApprovalRequest {
        let place = folder ?? peer.cwd
        var request = ApprovalRequest(action: action, names: names, chain: peer.chain,
                                      folder: place.isEmpty ? "" : Grant.normalize(place),
                                      command: peer.redactedCommandLine.isEmpty ? nil : peer.redactedCommandLine, duration: duration, reason: reason)
        request.fromApp = peer.pid == getpid()
        request.sessionName = peer.sessionProcess?.name
        request.runCommand = peer.runCommand
        request.program = request.fromApp || peer.isLatchkeyTool || peer.path.isEmpty ? nil : peer.path
        if peer.isSafariExtension {
            request.fromSafari = true
            request.page = req.page
            request.program = nil
            request.folder = ""
            request.command = nil
        }
        if peer.isSSHForward {
            request.overSSH = true
            request.remote = req.remote
            request.program = nil
            request.sessionName = nil
        }
        request.byAgent = req.origin == "mcp"
        return request
    }

    /// The longest grant an agent can ask for through `latchkey mcp`.
    public static let longestAgentGrant: TimeInterval = 24 * 3600

    /// A grant entry that reaches a production environment: `project/*` (every environment) or an item or
    /// environment pattern whose environment is production. Shared items don't say, so they don't count.
    static func reachesProduction(_ entry: String) -> Bool {
        let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
        switch parts.count {
        case 2: return true
        case 3: return Environments.isProduction(String(parts[1]))
        default: return false
        }
    }

    /// "zsh › claude" or "the Latchkey app".
    static func who(_ peer: PeerInfo) -> String {
        let w = peer.chain.prefix(3).joined(separator: " › ")
        return w.isEmpty ? "a process" : w
    }

    /// "3 items (A, B, C)", shortened past a handful so the system sheet stays readable.
    /// Items as the system authentication sheet can show them, which cuts long text off: a few names from one
    /// place ("DATABASE_URL and STRIPE_KEY from shop/development"), or a count by place ("17 items from
    /// acp-gateway/development", "5 items from shop/development and shop/preview"). The approval panel lists them all.
    static func count(_ names: [String]) -> String {
        var places: [String] = []
        var byPlace: [String: [String]] = [:]
        for n in names {
            let id = ItemID(n)
            let place = id.map { $0.isShared ? "shared" : "\($0.project)/\($0.environment)" } ?? "shared"
            if byPlace[place] == nil { places.append(place) }
            byPlace[place, default: []].append(id?.name ?? n)
        }
        func items(_ k: Int) -> String { "\(k) item\(k == 1 ? "" : "s")" }
        func from(_ place: String) -> String { place == "shared" ? "shared" : "from \(place)" }
        if places.count == 1, let place = places.first, let short = byPlace[place], short.count <= 3 {
            let list = short.count < 3 ? short.joined(separator: " and ") : "\(short[0]), \(short[1]) and \(short[2])"
            return place == "shared" ? list : "\(list) \(from(place))"
        }
        switch places.count {
        case 1: return places[0] == "shared" ? "\(items(names.count)), shared" : "\(items(names.count)) \(from(places[0]))"
        case 2: return "\(items(names.count)) from \(places[0]) and \(places[1])"
        default: return "\(items(names.count)) from \(places[0]) and \(places.count - 1) other places"
        }
    }

    /// A folder short enough for the system sheet: the last two parts of a long path ("…/latchkey/grants").
    static func shortFolder(_ path: String) -> String {
        let t = tilde(path)
        let parts = t.split(separator: "/")
        return t.count > 32 && parts.count > 2 ? "…/" + parts.suffix(2).joined(separator: "/") : t
    }

    public static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// "zsh › claude in ~/Projects/site (running npm test)"
    static func describe(_ peer: PeerInfo, _ req: Request) -> String {
        if peer.isSafariExtension { return "Latchkey's Safari extension" + (req.page.map { " on " + $0 } ?? "") }
        let who = peer.chain.prefix(3).joined(separator: " › ")
        let cwd = shortFolder(peer.cwd)
        var s = (who.isEmpty ? "a process" : who) + (cwd.isEmpty ? "" : " in \(cwd)")
        let c = peer.redactedCommandLine
        if !c.isEmpty { s += " (running \(c.count > 48 ? String(c.prefix(45)) + "…" : c))" }
        return s
    }

    // MARK: log

    public struct LogEntry: Codable, Sendable {
        public var time: Date
        public var op: String
        public var names: [String]
        public var decision: String
        public var chain: [String]
        public var cwd: String
        public var command: String?
        /// The asking program, when it isn't Latchkey's own command-line tool or the app.
        public var program: String?
        /// The MAC of the entry before this one, and this entry's own (see LogChain).
        public var prev: String?
        public var mac: String?
    }

    private func log(_ op: String, _ names: [String], _ decision: String, _ peer: PeerInfo, _ req: Request) {
        guard let url = logURL else { return }
        var entry = LogEntry(time: Date(), op: op, names: names, decision: decision,
                             chain: peer.chain, cwd: peer.cwd, command: peer.redactedCommandLine.isEmpty ? nil : peer.redactedCommandLine,
                             program: peer.isSafariExtension ? "Latchkey's Safari extension" + (req.page.map { " on " + $0 } ?? "")
                                 : peer.isLatchkeyTool || peer.pid == getpid() || peer.path.isEmpty ? nil : peer.path)
        var head: LogHead?
        if let keys = logKeys, let key = keys.key() {
            let last = keys.head()
            entry.prev = last?.mac
            let mac = LogChain.mac(entry, key: key)
            entry.mac = mac
            head = LogHead(mac: mac, count: (last?.count ?? 0) + 1)
        }
        guard var line = try? Wire.encoder().encode(entry) else { return }
        line.append(0x0A)
        defer { if let head { logKeys?.setHead(head) } }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            FileManager.default.createFile(atPath: url.path, contents: line, attributes: [.posixPermissions: 0o600])
        }
        onChange?()
    }

    /// Whether the access log is as Latchkey wrote it.
    func verifyLog() -> Response {
        guard let url = logURL, let keys = logKeys else { return Response(ok: false, error: "this broker keeps no signed log") }
        switch LogChain.verify(url, keys: keys) {
        case .intact(let signed, let unsigned):
            return Response(ok: true, info: ["result": "intact", "signed": String(signed), "unsigned": String(unsigned)])
        case .broken(let line, let reason):
            return Response(ok: true, info: ["result": "broken", "line": String(line), "reason": reason])
        }
    }

    public static func readLog(limit: Int = 50, from url: URL = Paths.accessLog) -> [LogEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = Wire.decoder()
        return text.split(separator: "\n").suffix(limit).compactMap { try? dec.decode(LogEntry.self, from: Data($0.utf8)) }
    }

    // MARK: socket

    public enum ServeError: Error, CustomStringConvertible {
        case alreadyRunning(String)
        public var description: String {
            switch self { case .alreadyRunning(let p): return "another broker is already answering on \(p)" }
        }
    }

    /// Listens until the process exits. Accepts only connections from this user.
    /// Who may use a socket, and for what: the Safari extension's socket admits only Latchkey's signed extension, and
    /// only to see item names, save a value (which asks, like any change) and fill one item into the page you're on
    /// (which asks every time, and only on sites the broker allows).
    public struct Gate: Sendable {
        public var identifier: String
        public var ops: Set<String>
        /// This endpoint has the complete CLI API, but admits only our signed terminal client. It does not
        /// accept a client's claimed cwd, argv or ancestry in place of the kernel-derived PeerInfo.
        public static let commandLineTool = Gate(identifier: CodeIdentity.toolIdentifier, ops: [
            "status", "list", "check", "verify-log", "log", "get", "set", "rm", "import", "grants", "grant", "revoke",
            "move", "update", "history", "deleted", "version", "restore", "forget", "links", "link", "unlink", "remote-status", "push",
            "environments", "environment-add", "environment-set", "environment-remove", "export", "projects", "project-link", "project-unlink",
            "duplicates", "combine", "scan"
        ])
        public static let safariExtension = Gate(identifier: CodeIdentity.safariExtensionIdentifier, ops: ["status", "list", "set", "fill"])
    }

    /// `handle`, limited to what a gate allows.
    public func handle(_ req: Request, peer: PeerInfo, gate: Gate?) -> Response {
        if let gate, !gate.ops.contains(req.op) { return Response(ok: false, error: "\(req.op) isn't available here") }
        return handle(req, peer: peer)
    }

    public func serve(socketPath requestedPath: String? = nil, gate: Gate? = nil) throws -> Never {
        let socketPath = requestedPath ?? self.socketPath
        // A client that hangs up before reading its reply (a "is it up yet?" probe, a Ctrl-C) must cost one
        // failed write, not the whole process: by default writing to a closed socket raises SIGPIPE, which kills it.
        signal(SIGPIPE, SIG_IGN)
        try Paths.ensureSupportDir()
        pruneVersions()
        if let fd = try? UnixSocket.connect(socketPath) {
            close(fd)
            throw ServeError.alreadyRunning(socketPath)
        }
        let listener = try UnixSocket.listen(socketPath)
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 { continue }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); continue }
            if let gate {
                guard let team = CodeIdentity.ownTeam, CodeIdentity.peer(fd, is: gate.identifier, team: team) else { close(fd); continue }
            }
            var peer = PeerInfo.of(socket: fd)
            // The second audit-token validation brackets PID-based context collection. If it failed or
            // the process disappeared/reused its PID, the CLI-only listener must not handle the request.
            if gate?.identifier == CodeIdentity.toolIdentifier, !peer.isLatchkeyTool { close(fd); continue }
            peer.isSafariExtension = gate?.identifier == CodeIdentity.safariExtensionIdentifier
            let caller = peer
            DispatchQueue.global().async { [self] in
                defer { close(fd) }
                var nosig: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
                let response: Response
                do {
                    let line = try UnixSocket.readLine(fd)
                    let req = try Wire.decoder().decode(Request.self, from: line)
                    response = handle(req, peer: caller, gate: gate)
                } catch {
                    response = Response(ok: false, error: "bad request: \(error)")
                }
                if let data = try? Wire.encoder().encode(response) { try? UnixSocket.writeLine(fd, data) }
            }
        }
    }
}
