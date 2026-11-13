import Darwin
import Foundation

/// Who holds the client end of a loopback TCP connection. The kernel's socket table is the only record of it: the
/// proxy's own end only shows a port.
public enum LoopbackPeer {
    /// Every process holding a socket that is `clientPort` talking to `serverPort` on 127.0.0.1, with the start time
    /// each had before and after its descriptors were read. A process whose start time changed in between (its ID
    /// was reused mid-scan) is returned with a start time of 0, which never matches a real process. Empty when
    /// nothing was found, including when the table couldn't be read: callers must treat that as a refusal.
    public static func holders(clientPort: UInt16, serverPort: UInt16) -> [ProcessStamp] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let listed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard listed > 0 else { return [] }
        var found: [ProcessStamp] = []
        for pid in pids.prefix(Int(listed)) where pid > 0 {
            guard let before = PeerInfo.started(pid), holds(pid, clientPort: clientPort, serverPort: serverPort) else { continue }
            let after = PeerInfo.started(pid)
            found.append(ProcessStamp(pid: pid, started: after == before ? before : 0))
        }
        return found
    }

    private static func holds(_ pid: pid_t, clientPort: UInt16, serverPort: UInt16) -> Bool {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.size + 8)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
        guard got > 0 else { return false }
        let loopback = UInt32(0x7F00_0001)
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp.tcpsi_ini
            guard tcp.insi_vflag & UInt8(INI_IPV4) != 0,
                  UInt32(bigEndian: tcp.insi_laddr.ina_46.i46a_addr4.s_addr) == loopback,
                  UInt32(bigEndian: tcp.insi_faddr.ina_46.i46a_addr4.s_addr) == loopback,
                  UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.insi_lport)) == clientPort,
                  UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.insi_fport)) == serverPort else { continue }
            return true
        }
        return false
    }

    /// True when `pid` is `root` or descends from it, and `root` is still the process that started at `root.started`:
    /// a reused process ID can't stand in for either. A process whose parent exited has been adopted by launchd and
    /// no longer descends from anything.
    public static func isDescendant(_ pid: pid_t, of root: ProcessStamp) -> Bool {
        guard root.started > 0, root.isRunning else { return false }
        var current = pid
        for _ in 0..<64 {
            guard current > 1, PeerInfo.started(current) != nil else { return false }
            if current == root.pid { return true }
            current = PeerInfo.parent(of: current)
        }
        return false
    }

    /// True when every process holding this connection's client end belongs to `root`'s process tree. A socket also
    /// held by an outsider (a descriptor passed or inherited out of the tree) is refused, as is one nobody can be
    /// found holding.
    public static func connection(clientPort: UInt16, serverPort: UInt16, belongsTo root: ProcessStamp) -> Bool {
        let holders = holders(clientPort: clientPort, serverPort: serverPort)
        guard !holders.isEmpty else { return false }
        return holders.allSatisfy { $0.started > 0 && isDescendant($0.pid, of: root) && $0.isRunning }
    }
}
