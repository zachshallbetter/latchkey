import Darwin
import Foundation

/// Who is on the other end of a broker connection.
public struct PeerInfo: Codable, Sendable, Hashable {
    public var pid: Int32
    public var path: String
    public var cwd: String
    /// Names of the caller's ancestors, nearest first, without the caller itself.
    public var chain: [String]
    /// The caller's command line, as the kernel has it.
    public var arguments: [String]
    /// True when the caller is the `latchkey` tool signed by the same team as this process. Anything else talking
    /// to the socket is shown by its path.
    public var isLatchkeyTool: Bool

    public init(pid: Int32, path: String, cwd: String, chain: [String], arguments: [String] = [], isLatchkeyTool: Bool = false) {
        self.pid = pid
        self.path = path
        self.cwd = cwd
        self.chain = chain
        self.arguments = arguments
        self.isLatchkeyTool = isLatchkeyTool
    }

    /// The command line to show: the program's name, then its arguments, quoted where needed.
    public var commandLine: String {
        guard let first = arguments.first else { return "" }
        let quoted = arguments.dropFirst().map { a in
            a.isEmpty || a.contains(where: { " \"'$`\\".contains($0) }) ? "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'" : a
        }
        return ([(first as NSString).lastPathComponent] + quoted).joined(separator: " ")
    }

    /// The process ID on the other end of a Unix socket, or 0.
    public static func pid(of fd: Int32) -> pid_t {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        let SOL_LOCAL_: Int32 = 0
        let LOCAL_PEERPID_: Int32 = 0x002
        return getsockopt(fd, SOL_LOCAL_, LOCAL_PEERPID_, &pid, &len) == 0 ? pid : 0
    }

    public static func of(socket fd: Int32) -> PeerInfo {
        let pid = pid(of: fd)
        guard pid > 0 else { return PeerInfo(pid: 0, path: "", cwd: "", chain: []) }
        var chain: [String] = []
        var cur = parent(of: pid)
        var hops = 0
        while cur > 1, hops < 10 {
            let p = path(of: cur)
            chain.append(p.isEmpty ? "pid \(cur)" : (p as NSString).lastPathComponent)
            cur = parent(of: cur)
            hops += 1
        }
        let isTool = CodeIdentity.ownTeam.map { CodeIdentity.peer(fd, is: CodeIdentity.toolIdentifier, team: $0) } ?? false
        return PeerInfo(pid: pid, path: path(of: pid), cwd: cwd(of: pid), chain: chain, arguments: arguments(of: pid),
                        isLatchkeyTool: isTool)
    }

    /// A process's arguments from the kernel (KERN_PROCARGS2: argc, the executable path, padding, then argv).
    public static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }
        while i < size, buf[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    public static func path(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    public static func parent(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        return n == size ? pid_t(info.pbi_ppid) : 0
    }

    public static func cwd(of pid: pid_t) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard n == size else { return "" }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}
