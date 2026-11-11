import Darwin
import Foundation

public enum SocketError: Error, CustomStringConvertible {
    case pathTooLong
    case sys(String, Int32)
    case closed
    case tooLarge
    /// Something other than the Latchkey app is answering on the socket (its path, if known).
    case notLatchkey(String)

    public var description: String {
        switch self {
        case .pathTooLong: return "socket path is too long"
        case .sys(let what, let code): return "\(what): \(String(cString: strerror(code)))"
        case .closed: return "connection closed"
        case .tooLarge: return "message too large"
        case .notLatchkey(let path):
            return "the program answering on Latchkey's socket isn't the Latchkey app (\(path.isEmpty ? "unknown program" : path)); nothing was sent"
        }
    }
}

public enum UnixSocket {
    static let maxLine = 4 * 1024 * 1024

    public static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw SocketError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            bytes.withUnsafeBytes { src in raw.copyMemory(from: src) }
        }
        return addr
    }

    public static func connect(_ path: String) throws -> Int32 {
        var addr = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.sys("socket", errno) }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        guard r == 0 else {
            let code = errno
            close(fd)
            throw SocketError.sys("connect", code)
        }
        return fd
    }

    /// Binds and listens. The socket file is owner-only.
    public static func listen(_ path: String) throws -> Int32 {
        var addr = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.sys("socket", errno) }
        unlink(path)
        let old = umask(0o177)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
        }
        umask(old)
        guard r == 0 else {
            let code = errno
            close(fd)
            throw SocketError.sys("bind", code)
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 32) == 0 else {
            let code = errno
            close(fd)
            throw SocketError.sys("listen", code)
        }
        return fd
    }

    public static func writeLine(_ fd: Int32, _ data: Data) throws {
        var out = data
        out.append(0x0A)
        try out.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.sys("write", errno)
                }
                off += n
            }
        }
    }

    public static func readLine(_ fd: Int32) throws -> Data {
        var acc = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketError.sys("read", errno)
            }
            if n == 0 {
                if acc.isEmpty { throw SocketError.closed }
                return acc
            }
            if let nl = buf[0..<n].firstIndex(of: 0x0A) {
                guard acc.count + nl <= maxLine else { throw SocketError.tooLarge }
                acc.append(contentsOf: buf[0..<nl])
                return acc
            }
            acc.append(contentsOf: buf[0..<n])
            if acc.count > maxLine { throw SocketError.tooLarge }
        }
    }
}

/// The CLI side: one request, one response. Authenticate before sending even the operation or item names.
public enum BrokerClient {
    public static func send(_ request: Request) throws -> Response {
        let endpoint = try BrokerEndpoint.select(environment: ProcessInfo.processInfo.environment,
            team: CodeIdentity.ownTeam, installedAppIsStore: false,
            home: FileManager.default.homeDirectoryForCurrentUser, directPath: Paths.socket)
        return try send(request, endpoint: endpoint)
    }

    /// Explicit local paths always retain local authentication, regardless of LATCHKEY_SOCKET in the environment.
    public static func send(_ request: Request, socketPath: String) throws -> Response {
        try send(request, endpoint: .local(path: socketPath, team: CodeIdentity.ownTeam))
    }

    public static func send(_ request: Request, endpoint: BrokerEndpoint) throws -> Response {
        let fd = try UnixSocket.connect(endpoint.path)
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        if case .sameTeamApplication(let team) = endpoint.authentication,
           !CodeIdentity.peer(fd, is: CodeIdentity.appIdentifier, team: team) {
            throw SocketError.notLatchkey(PeerInfo.path(of: PeerInfo.pid(of: fd)))
        }
        let data = try Wire.encoder().encode(request)
        guard data.count <= UnixSocket.maxLine else { throw SocketError.tooLarge }
        try UnixSocket.writeLine(fd, data)
        return try Wire.decoder().decode(Response.self, from: UnixSocket.readLine(fd))
    }
}
