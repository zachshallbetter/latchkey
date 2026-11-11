import Darwin
import Foundation

/// Who is on the other end of a broker connection.
public struct PeerInfo: Codable, Sendable, Hashable {
    public var pid: Int32
    public var path: String
    public var cwd: String
    /// Names of the caller's ancestors, nearest first, without the CLI itself.
    public var chain: [String]

    public init(pid: Int32, path: String, cwd: String, chain: [String]) {
        self.pid = pid
        self.path = path
        self.cwd = cwd
        self.chain = chain
    }

    public static func of(socket fd: Int32) -> PeerInfo {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        let SOL_LOCAL_: Int32 = 0
        let LOCAL_PEERPID_: Int32 = 0x002
        guard getsockopt(fd, SOL_LOCAL_, LOCAL_PEERPID_, &pid, &len) == 0, pid > 0 else {
            return PeerInfo(pid: 0, path: "", cwd: "", chain: [])
        }
        var chain: [String] = []
        var cur = parent(of: pid)
        var hops = 0
        while cur > 1, hops < 10 {
            let p = path(of: cur)
            chain.append(p.isEmpty ? "pid \(cur)" : (p as NSString).lastPathComponent)
            cur = parent(of: cur)
            hops += 1
        }
        return PeerInfo(pid: pid, path: path(of: pid), cwd: cwd(of: pid), chain: chain)
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
