import Darwin
import Foundation

/// Answers CLI requests: decides what may be read, asks for approval, writes the access log.
/// The app hosts one; `latchkey-broker` hosts one without a window during development.
public final class Broker: @unchecked Sendable {
    public let store: SecretStore
    public let approver: Approver
    /// How long a read approval covers the same names from the same place. 0 asks every time.
    public var readApprovalWindow: TimeInterval
    public let logURL: URL?
    private let memory = ApprovalMemory()
    /// One request at a time, so approval sheets never stack.
    private let serial = NSLock()

    public init(store: SecretStore, approver: Approver, readApprovalWindow: TimeInterval = 120,
                logURL: URL? = Paths.accessLog) {
        self.store = store
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
            "socket": Paths.socket,
        ])
    }

    func get(_ req: Request, peer: PeerInfo) throws -> Response {
        let names = Array(Set(req.names ?? [])).sorted()
        guard !names.isEmpty else { return Response(ok: false, error: "no names given") }
        let infos = Dictionary(uniqueKeysWithValues: try store.list().map { ($0.name, $0) })
        let missing = names.filter { infos[$0] == nil }
        let present = names.filter { infos[$0] != nil }
        let needApproval = present.filter { !(infos[$0]!.agentSafe) }

        var denied: [String] = []
        if !needApproval.isEmpty {
            let key = ApprovalMemory.key(needApproval, peer)
            if memory.covers(key) {
                log("get", needApproval, "allowed (remembered)", peer, req)
            } else if approver.approve("release \(needApproval.joined(separator: ", ")) to \(Self.describe(peer, req))") {
                memory.remember(key, for: readApprovalWindow)
                log("get", needApproval, "approved", peer, req)
            } else {
                denied = needApproval
                log("get", needApproval, "denied", peer, req)
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
        let verb = (try store.info(name)) == nil ? "add" : "change"
        guard approver.approve("\(verb) \(name), asked by \(Self.describe(peer, req))") else {
            log("set", [name], "denied", peer, req)
            return Response(ok: false, error: "change to \(name) was not approved")
        }
        try store.save(name: name, value: req.value, kind: req.kind, agentSafe: req.agentSafe, note: req.note)
        log("set", [name], "approved", peer, req)
        return Response(ok: true)
    }

    func remove(_ req: Request, peer: PeerInfo) throws -> Response {
        guard let name = req.names?.first, req.names?.count == 1 else { return Response(ok: false, error: "rm takes one name") }
        guard (try store.info(name)) != nil else { return Response(ok: true, missing: [name]) }
        guard approver.approve("delete \(name), asked by \(Self.describe(peer, req))") else {
            log("rm", [name], "denied", peer, req)
            return Response(ok: false, error: "removal of \(name) was not approved")
        }
        _ = try store.remove(name)
        log("rm", [name], "approved", peer, req)
        return Response(ok: true)
    }

    /// "claude › zsh in ~/Projects/site (running npm test)"
    static func describe(_ peer: PeerInfo, _ req: Request) -> String {
        let who = peer.chain.prefix(3).joined(separator: " › ")
        var cwd = req.cwd ?? peer.cwd
        let home = NSHomeDirectory()
        if cwd.hasPrefix(home) { cwd = "~" + cwd.dropFirst(home.count) }
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
