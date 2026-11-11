import Foundation

/// Replaces secret values in a byte stream, including values split across two chunks.
public struct Masker {
    public static let replacement = Array("<concealed by latchkey>".utf8)
    /// Values shorter than this are not masked: they would match ordinary output.
    public static let minimumLength = 6

    private let needles: [[UInt8]]
    private var pending: [UInt8] = []

    public init(secrets: [String]) {
        var set = Set<[UInt8]>()
        for s in secrets {
            for part in s.split(whereSeparator: \.isNewline) {
                let bytes = Array(part.utf8)
                if bytes.count >= Masker.minimumLength { set.insert(bytes) }
            }
        }
        needles = set.sorted { $0.count > $1.count }
    }

    public var isActive: Bool { !needles.isEmpty }

    public mutating func feed(_ chunk: Data) -> Data {
        guard isActive else { return chunk }
        pending.append(contentsOf: chunk)
        let replaced = Masker.replaceAll(pending, needles)
        let keep = Masker.heldBack(replaced, needles)
        pending = Array(replaced[(replaced.count - keep)...])
        return Data(replaced[..<(replaced.count - keep)])
    }

    public mutating func flush() -> Data {
        let out = Masker.replaceAll(pending, needles)
        pending = []
        return Data(out)
    }

    static func replaceAll(_ input: [UInt8], _ needles: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        var i = 0
        outer: while i < input.count {
            for n in needles where input[i] == n[0] && i + n.count <= input.count {
                if input[i..<(i + n.count)].elementsEqual(n) {
                    out.append(contentsOf: replacement)
                    i += n.count
                    continue outer
                }
            }
            out.append(input[i])
            i += 1
        }
        return out
    }

    /// Length of the longest tail of `buf` that is the start of some needle.
    static func heldBack(_ buf: [UInt8], _ needles: [[UInt8]]) -> Int {
        var best = 0
        for n in needles {
            var k = min(n.count - 1, buf.count)
            while k > best {
                if buf[(buf.count - k)...].elementsEqual(n[..<k]) { best = k; break }
                k -= 1
            }
        }
        return best
    }
}
