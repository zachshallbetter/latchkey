import Darwin
import Foundation

/// Answers CLI requests: decides what may be read, asks for approval, writes the access log.
/// The app hosts one; `latchkey-broker` hosts one without a window during development.
public final class Broker: @unchecked Sendable {
    /// How requests from the Latchkey window identify themselves.
    public static let appCaller = "the Latchkey app"

    public let store: SecretStore
    public let grants: GrantStore
    /// Earlier values: kept when a value is replaced or an item deleted, pruned to `Versions.keep` per item and
    /// `Versions.deletedFor` after a delete.
    public let versions: VersionStore
    /// Environments linked to Vercel, GitHub Actions, Railway or Fly.
    public let remotes: RemoteStore
    let runner: RemoteRunner
    /// Pushes run only in the app, where the approval panel can confirm production. The window-less broker refuses them.
    public let allowsPush: Bool
    public let approver: Approver
    /// How long a read approval covers the same names from the same place. 0 asks every time.
    public var readApprovalWindow: TimeInterval
    public let logURL: URL?
    /// Signs each log entry into a chain, when the log is kept.
    public let logKeys: LogKeyStore?
    /// Called after every logged decision (reads, changes, denials), off the main thread.
    public var onChange: (@Sendable () -> Void)?
    private let memory = ApprovalMemory()
    /// One request at a time, so approval sheets never stack.
    private let serial = NSLock()

    /// Without a log (tests), grants are kept in memory too unless a store is passed.
    public init(store: SecretStore, approver: Approver, readApprovalWindow: TimeInterval = 120,
                logURL: URL? = Paths.accessLog, grants: GrantStore? = nil, versions: VersionStore? = nil,
                remotes: RemoteStore? = nil, runner: RemoteRunner = ProcessRunner(), allowsPush: Bool = true,
                logKeys: LogKeyStore? = nil) {
        self.store = store
        self.runner = runner
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
        self.readApprovalWindow = readApprovalWindow
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
        do {
            switch req.op {
            case "status": return status(peer)
            case "list": return Response(ok: true, secrets: try store.list())
            case "check": return try check(req, peer: peer)
            case "verify-log": return verifyLog()
            case "get": return try get(req, peer: peer)
            case "set": return try set(req, peer: peer)
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
            default: return Response(ok: false, error: "unknown op \(req.op)")
            }
        } catch {
            return Response(ok: false, error: "\(error)")
        }
    }

    func status(_ peer: PeerInfo) -> Response {
        let count = (try? store.list().count).map(String.init) ?? "unknown"
        return Response(ok: true, info: [
            "caller": peer.isLatchkeyTool ? "Latchkey's command-line tool (signature checked)"
                : "\(peer.path.isEmpty ? "unknown program" : peer.path) (not Latchkey's signed command-line tool)",
            "storage": store.location,
            "approval": approver.method,
            "items": count,
            "grants": String(grants.all().count),
            "socket": Paths.socket,
        ])
    }

    /// What `get` would do with these names from this caller and folder, without asking or releasing anything:
    /// which are agent-safe, covered by a grant, covered by a recent approval, need approval, or don't exist.
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
        for name in present where !infos[name]!.agentSafe {
            guard let g = grants.covering(name, cwd: cwd, ancestors: peer.ancestors, command: req.intended ?? peer.runCommand) else { continue }
            granted.append(name)
            if !covering.contains(g) { covering.append(g) }
        }
        let rest = present.filter { !infos[$0]!.agentSafe && !granted.contains($0) }
        let remembered = !rest.isEmpty && memory.covers(ApprovalMemory.key(rest, peer))
        func some(_ a: [String]) -> [String]? { a.isEmpty ? nil : a }
        return Response(ok: true, missing: some(missing), grants: covering.isEmpty ? nil : covering,
                        agentSafe: some(safe), granted: some(granted), remembered: remembered ? rest : nil,
                        needsApproval: remembered ? nil : some(rest))
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
        for name in needApproval {
            if let g = grants.covering(name, cwd: cwd, ancestors: peer.ancestors, command: peer.runCommand) { byGrant[g, default: []].append(name) }
        }
        let granted = byGrant.values.flatMap { $0 }
        for (g, names) in byGrant.sorted(by: { $0.key.id < $1.key.id }) {
            log("get", names.sorted(), "allowed (grant \(g.id))", peer, req)
        }
        let toAsk = needApproval.filter { !granted.contains($0) }

        var denied: [String] = []
        if !toAsk.isEmpty {
            let key = ApprovalMemory.key(toAsk, peer)
            if memory.covers(key) {
                log("get", toAsk, "allowed (remembered)", peer, req)
            } else {
                switch ask(.read, toAsk, peer, req, "release \(Self.count(toAsk)) to \(Self.describe(peer, req))") {
                case .deny:
                    denied = toAsk
                    log("get", toAsk, "denied", peer, req)
                case .once:
                    memory.remember(key, for: readApprovalWindow)
                    log("get", toAsk, "approved", peer, req)
                case .grant(let choice):
                    memory.remember(key, for: readApprovalWindow)
                    if cwd.isEmpty {
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
        pruneVersions()
        log("set", [name], "approved", peer, req)
        return Response(ok: true)
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

    /// Changes agent-safe, kind, service or note on many items with one approval. Values are untouched.
    func update(_ req: Request, peer: PeerInfo) throws -> Response {
        let names = Array(Set(req.names ?? [])).sorted()
        guard !names.isEmpty else { return Response(ok: false, error: "no names given") }
        guard req.agentSafe != nil || req.kind != nil || req.service != nil || req.note != nil else {
            return Response(ok: false, error: "nothing to change: give agent-safe, kind, service or note")
        }
        let existing = Set(try store.list().map(\.name))
        let missing = names.filter { !existing.contains($0) }
        guard missing.isEmpty else { return Response(ok: false, missing: missing) }
        var changes: [String] = []
        if let a = req.agentSafe { changes.append(a ? "let agents read" : "require approval for") }
        if let k = req.kind { changes.append("set the kind to \(k.label.lowercased()) for") }
        if let s = req.service { changes.append(s.isEmpty ? "clear the service of" : "set the service to \(s) for") }
        if req.note != nil { changes.append("change the note of") }
        let reason = "\(changes.joined(separator: " and ")) \(names.count == 1 ? names[0] : Self.count(names)), asked by \(Self.who(peer))"
        guard ask(.change, names, peer, req, reason).allowed else {
            log("update", names, "denied", peer, req)
            return Response(ok: false, error: "the change was not approved")
        }
        for name in names {
            try store.save(name: name, value: nil, kind: req.kind, agentSafe: req.agentSafe, note: req.note, usedIn: nil,
                           service: req.service)
        }
        log("update", names, "approved", peer, req)
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
        guard !byName.isEmpty else { return Response(ok: false, error: "nothing to import") }
        let existing = Set(try store.list().map(\.name))
        let names = byName.keys.sorted()
        let toAdd = names.filter { !existing.contains($0) }
        let toReplace = req.replace == true ? names.filter { existing.contains($0) } : []
        let skipped = req.replace == true ? [] : names.filter { existing.contains($0) }
        let writing = toAdd + toReplace
        guard !writing.isEmpty else { return Response(ok: true, added: [], replaced: [], skipped: skipped) }

        var what: [String] = []
        if !toAdd.isEmpty { what.append("add \(Self.count(toAdd))") }
        if !toReplace.isEmpty { what.append("overwrite \(Self.count(toReplace))") }
        var from = ""
        if let src = req.source, !src.isEmpty { from = " from \(Self.tilde(src))" }
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
        log("import", writing, "approved", peer, req)
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
                               usedIn: info.usedIn, service: info.service ?? "")
                _ = try store.remove(id)
                try versions.rename(from: id, to: to)
                done[id] = to
            } catch {
                log("move", done.keys.sorted(), "approved (stopped at \(id))", peer, req)
                return Response(ok: false, error: "moved \(done.count) of \(moving.count), then \(id) failed: \(error)", moved: done)
            }
        }
        log("move", moving, "approved (to \(place))", peer, req)
        return Response(ok: true, moved: done)
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
                       service: v.service ?? "")
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
        if try remotes.all().contains(where: { $0.scope == scope && $0.target == target }) {
            return Response(ok: false, error: "\(scope) is already linked to \(target.label)")
        }
        guard ask(.link, [scope], peer, req, "link \(scope) to \(target.label), asked by \(Self.who(peer))", targets: [target.label]).allowed else {
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

    /// Compares names with each link's target. Reads names only; never sends or keeps a value.
    func remoteStatus(_ req: Request) throws -> Response {
        guard let scope = req.names?.first, RemoteLink.isValidScope(scope) else { return Response(ok: false, error: "status takes a project/environment") }
        let items = try store.list().filter { $0.name.hasPrefix(scope + "/") }
        let expected = Set(items.map(\.ref.name))
        var out: [RemoteStatus] = []
        for link in try remotes.all() where link.scope == scope {
            let r = runner.run(link.target.listCommand, timeout: 60)
            let stale = items.filter { link.state(of: $0.name, valueChangedAt: valueChangedAt($0.name)) == .outOfDate }.map(\.ref.name).sorted()
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
    /// grant or remembered approval covers a push, production needs its own confirmation, and only the app does it.
    func push(_ req: Request, peer: PeerInfo) throws -> Response {
        guard allowsPush else { return Response(ok: false, error: "pushes run in the Latchkey app, where production can be confirmed; open it and try again") }
        guard let scope = req.names?.first, RemoteLink.isValidScope(scope) else { return Response(ok: false, error: "push takes a project/environment") }
        let links = try remotes.all().filter { $0.scope == scope && (req.link == nil || $0.id == req.link) }
        guard !links.isEmpty else { return Response(ok: false, error: req.link == nil ? "\(scope) isn't linked anywhere" : "no such link for \(scope)") }
        var items = try store.list().filter { $0.name.hasPrefix(scope + "/") }
        if let only = req.only { items = items.filter { only.contains($0.name) } }
        guard !items.isEmpty else { return Response(ok: false, error: "no items to push in \(scope)") }

        let labels = links.map(\.target.label)
        let names = items.map(\.name)
        var request = approvalRequest(.push, names, peer, req,
                                      "push \(Self.count(names.map { ItemID($0)?.name ?? $0 })) to \(labels.joined(separator: ", ")), asked by \(Self.who(peer))")
        request.targets = labels
        request.production = links.contains { $0.target.isProduction }
        guard approver.approve(request).allowed else {
            log("push", names, "denied", peer, req)
            return Response(ok: false, error: "the push was not approved")
        }

        let values = try store.values(names)
        var results: [PushResult] = []
        for var link in links {
            var batch: [(name: String, value: String, secret: Bool)] = []
            var ids: [String] = []
            for item in items {
                guard let value = values[item.name] else { results.append(PushResult(link: link.id, item: item.name, ok: false, error: "no value")); continue }
                if link.target.service == .fly && value.contains("\n") {
                    results.append(PushResult(link: link.id, item: item.name, ok: false, error: "Fly secrets import takes one line per value"))
                    continue
                }
                batch.append((item.ref.name, value, item.kind.isSecret))
                ids.append(item.name)
            }
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
            try remotes.save(link)
            let ok = results.filter { $0.link == link.id && $0.ok }.count, failed = results.filter { $0.link == link.id && !$0.ok }.count
            log("push", ids, "approved (\(link.target.label): \(ok) pushed\(failed > 0 ? ", \(failed) failed" : ""))", peer, req)
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
                     _ reason: String, duration: TimeInterval? = nil, folder: String? = nil, targets: [String] = []) -> ApprovalDecision {
        var request = approvalRequest(action, names, peer, req, reason, duration: duration, folder: folder)
        request.targets = targets
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
                             program: peer.isLatchkeyTool || peer.pid == getpid() || peer.path.isEmpty ? nil : peer.path)
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
    public func serve(socketPath: String = Paths.socket) throws -> Never {
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
            let peer = PeerInfo.of(socket: fd)
            DispatchQueue.global().async { [self] in
                defer { close(fd) }
                var nosig: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
                let response: Response
                do {
                    let line = try UnixSocket.readLine(fd)
                    let req = try Wire.decoder().decode(Request.self, from: line)
                    response = handle(req, peer: peer)
                } catch {
                    response = Response(ok: false, error: "bad request: \(error)")
                }
                if let data = try? Wire.encoder().encode(response) { try? UnixSocket.writeLine(fd, data) }
            }
        }
    }
}
