import Darwin
import Foundation

/// Answers CLI requests: decides what may be read, asks for approval, writes the access log.
/// The app hosts one; `latchkey-broker` hosts one without a window during development.
public final class Broker: @unchecked Sendable {
    /// How requests from the Latchkey window identify themselves.
    public static let appCaller = "the Latchkey app"

    public let store: SecretStore
    public let grants: GrantStore
    public let approver: Approver
    /// How long a read approval covers the same names from the same place. 0 asks every time.
    public var readApprovalWindow: TimeInterval
    public let logURL: URL?
    /// Called after every logged decision (reads, changes, denials), off the main thread.
    public var onChange: (@Sendable () -> Void)?
    private let memory = ApprovalMemory()
    /// One request at a time, so approval sheets never stack.
    private let serial = NSLock()

    /// Without a log (tests), grants are kept in memory too unless a store is passed.
    public init(store: SecretStore, approver: Approver, readApprovalWindow: TimeInterval = 120,
                logURL: URL? = Paths.accessLog, grants: GrantStore? = nil) {
        self.store = store
        self.grants = grants ?? GrantStore(url: logURL == nil ? nil : Paths.grants)
        self.approver = approver
        self.readApprovalWindow = readApprovalWindow
        self.logURL = logURL
    }

    // MARK: requests

    public func handle(_ req: Request, peer: PeerInfo) -> Response {
        serial.lock()
        defer { serial.unlock() }
        do {
            switch req.op {
            case "status": return status()
            case "list": return Response(ok: true, secrets: try store.list())
            case "get": return try get(req, peer: peer)
            case "set": return try set(req, peer: peer)
            case "rm": return try remove(req, peer: peer)
            case "import": return try importItems(req, peer: peer)
            case "grants": return Response(ok: true, grants: grants.all())
            case "grant": return try grant(req, peer: peer)
            case "revoke": return revoke(req, peer: peer)
            case "move": return try move(req, peer: peer)
            default: return Response(ok: false, error: "unknown op \(req.op)")
            }
        } catch {
            return Response(ok: false, error: "\(error)")
        }
    }

    func status() -> Response {
        let count = (try? store.list().count).map(String.init) ?? "unknown"
        return Response(ok: true, info: [
            "storage": store.location,
            "approval": approver.method,
            "items": count,
            "grants": String(grants.all().count),
            "socket": Paths.socket,
        ])
    }

    func get(_ req: Request, peer: PeerInfo) throws -> Response {
        let names = Array(Set(req.names ?? [])).sorted()
        guard !names.isEmpty else { return Response(ok: false, error: "no names given") }
        let infos = Dictionary(uniqueKeysWithValues: try store.list().map { ($0.name, $0) })
        let missing = names.filter { infos[$0] == nil }
        let present = names.filter { infos[$0] != nil }
        let cwd = req.cwd ?? peer.cwd
        let needApproval = present.filter { !(infos[$0]!.agentSafe) }
        let granted = needApproval.filter { grants.covering($0, cwd: cwd) != nil }
        if !granted.isEmpty { log("get", granted, "allowed (grant)", peer, req) }
        let toAsk = needApproval.filter { !granted.contains($0) }

        var denied: [String] = []
        if !toAsk.isEmpty {
            let key = ApprovalMemory.key(toAsk, peer)
            if memory.covers(key) {
                log("get", toAsk, "allowed (remembered)", peer, req)
            } else {
                switch ask(.read, toAsk, peer, req, "release \(toAsk.joined(separator: ", ")) to \(Self.describe(peer, req))") {
                case .deny:
                    denied = toAsk
                    log("get", toAsk, "denied", peer, req)
                case .once:
                    memory.remember(key, for: readApprovalWindow)
                    log("get", toAsk, "approved", peer, req)
                case .grant(let duration):
                    memory.remember(key, for: readApprovalWindow)
                    if cwd.isEmpty {
                        log("get", toAsk, "approved", peer, req)
                    } else {
                        let g = grants.add(names: toAsk, folder: cwd, duration: duration, createdBy: Self.who(peer))
                        log("get", toAsk, "approved (grant \(g.id) for \(GrantStore.describe(duration)))", peer, req)
                    }
                }
            }
        }
        let released = present.filter { !denied.contains($0) }
        let autoReleased = released.filter { infos[$0]!.agentSafe }
        if !autoReleased.isEmpty { log("get", autoReleased, "allowed (agent-safe)", peer, req) }

        let values = denied.isEmpty ? try store.values(released) : [:]
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
        try store.save(name: name, value: req.value, kind: req.kind, agentSafe: req.agentSafe, note: req.note, usedIn: nil,
                       service: req.service)
        log("set", [name], "approved", peer, req)
        return Response(ok: true)
    }

    func remove(_ req: Request, peer: PeerInfo) throws -> Response {
        guard let name = req.names?.first, req.names?.count == 1 else { return Response(ok: false, error: "rm takes one name") }
        guard (try store.info(name)) != nil else { return Response(ok: true, missing: [name]) }
        guard ask(.delete, [name], peer, req, "delete \(name), asked by \(Self.describe(peer, req))").allowed else {
            log("rm", [name], "denied", peer, req)
            return Response(ok: false, error: "removal of \(name) was not approved")
        }
        _ = try store.remove(name)
        log("rm", [name], "approved", peer, req)
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
        let folder = Grant.normalize(req.folder ?? req.cwd ?? peer.cwd)
        guard !folder.isEmpty, folder != "/" else { return Response(ok: false, error: "a grant needs a folder other than /") }
        let duration = min(req.duration ?? 3600, GrantStore.longest)
        guard duration > 0 else { return Response(ok: false, error: "the duration must be positive") }
        var r = req
        r.cwd = folder
        let reason = "let programs in \(Self.tilde(folder)) read \(Self.count(names)) without asking for \(GrantStore.describe(duration)), asked by \(Self.who(peer))"
        guard ask(.grant, names, peer, r, reason, duration: duration).allowed else {
            log("grant", names, "denied", peer, r)
            return Response(ok: false, error: "the grant was not approved")
        }
        let g = grants.add(names: names, folder: folder, duration: duration, createdBy: Self.who(peer))
        log("grant", names, "approved (grant \(g.id) for \(GrantStore.describe(duration)))", peer, r)
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
                done[id] = to
            } catch {
                log("move", done.keys.sorted(), "approved (stopped at \(id))", peer, req)
                return Response(ok: false, error: "moved \(done.count) of \(moving.count), then \(id) failed: \(error)", moved: done)
            }
        }
        log("move", moving, "approved (to \(place))", peer, req)
        return Response(ok: true, moved: done)
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
                     _ reason: String, duration: TimeInterval? = nil) -> ApprovalDecision {
        let folder = req.cwd ?? peer.cwd
        return approver.approve(ApprovalRequest(action: action, names: names, chain: peer.chain,
                                                folder: folder.isEmpty ? "" : Grant.normalize(folder),
                                                command: req.command, duration: duration, reason: reason))
    }

    /// "zsh › claude" or "the Latchkey app".
    static func who(_ peer: PeerInfo) -> String {
        let w = peer.chain.prefix(3).joined(separator: " › ")
        return w.isEmpty ? "a process" : w
    }

    /// "3 items (A, B, C)", shortened past a handful so the system sheet stays readable.
    static func count(_ names: [String]) -> String {
        let shown = names.count > 6 ? names.prefix(5).joined(separator: ", ") + ", …" : names.joined(separator: ", ")
        return "\(names.count) item\(names.count == 1 ? "" : "s") (\(shown))"
    }

    public static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// "zsh › claude in ~/Projects/site (running npm test)"
    static func describe(_ peer: PeerInfo, _ req: Request) -> String {
        let who = peer.chain.prefix(3).joined(separator: " › ")
        let cwd = tilde(req.cwd ?? peer.cwd)
        var s = (who.isEmpty ? "a process" : who) + (cwd.isEmpty ? "" : " in \(cwd)")
        if let c = req.command, !c.isEmpty { s += " (running \(c.count > 60 ? String(c.prefix(57)) + "…" : c))" }
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
    }

    private func log(_ op: String, _ names: [String], _ decision: String, _ peer: PeerInfo, _ req: Request) {
        guard let url = logURL else { return }
        let entry = LogEntry(time: Date(), op: op, names: names, decision: decision,
                             chain: peer.chain, cwd: req.cwd ?? peer.cwd, command: req.command)
        guard var line = try? Wire.encoder().encode(entry) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            FileManager.default.createFile(atPath: url.path, contents: line, attributes: [.posixPermissions: 0o600])
        }
        onChange?()
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
