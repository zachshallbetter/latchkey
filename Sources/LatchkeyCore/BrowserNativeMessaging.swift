import Foundation

public enum BrowserNativeError: Error { case truncated, tooLarge, malformed, unsupportedVersion, unapprovedExtension }

/// Chrome/Firefox native framing; all allocation sizes are checked before reading a body.
public enum BrowserNativeFrame {
    public static let inputLimit = 64 * 1024
    public static let outputLimit = 1024 * 1024

    static func exact(_ count: Int, from input: FileHandle) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let next = try input.read(upToCount: count - data.count), !next.isEmpty else { throw BrowserNativeError.truncated }
            data.append(next)
        }
        return data
    }

    public static func read(from input: FileHandle) throws -> Data {
        let header = [UInt8](try exact(4, from: input))
        let length = UInt32(header[0]) | UInt32(header[1]) << 8 | UInt32(header[2]) << 16 | UInt32(header[3]) << 24
        guard length > 0, length <= inputLimit else { throw BrowserNativeError.tooLarge }
        return try exact(Int(length), from: input)
    }

    public static func write(_ message: [String: Any], to output: FileHandle) throws {
        let body = try JSONSerialization.data(withJSONObject: message)
        guard body.count <= outputLimit else { throw BrowserNativeError.tooLarge }
        let n = UInt32(body.count)
        try output.write(contentsOf: Data([UInt8(n & 255), UInt8((n >> 8) & 255), UInt8((n >> 16) & 255), UInt8((n >> 24) & 255)]))
        try output.write(contentsOf: body)
    }

    public static func message(from data: Data) throws -> [String: Any] {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = envelope["version"] as? NSNumber,
              String(cString: version.objCType) != "c", version.intValue == 1, version.doubleValue == 1 else {
            throw BrowserNativeError.unsupportedVersion
        }
        guard let message = envelope["message"] as? [String: Any] else { throw BrowserNativeError.malformed }
        return message
    }
}

public struct BrowserHostAllowlist: Codable {
    public var chrome: [String]
    public var firefox: [String]
    public init(chrome: [String], firefox: [String]) { self.chrome = chrome; self.firefox = firefox }

    public enum Browser: String { case chrome, firefox }
    public static func chromeID(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { (97...112).contains($0) }
    }

    /// Native launch arguments differ: Chrome origin; Firefox manifest path + add-on ID.
    public func browser(arguments: [String]) throws -> Browser {
        if arguments.count == 1, let url = URL(string: arguments[0]), url.scheme == "chrome-extension",
           url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
           let id = url.host, Self.chromeID(id), url.path.isEmpty || url.path == "/", chrome.contains(id) {
            return .chrome
        }
        if arguments.count == 2, arguments[0].hasPrefix("/"), arguments[0].hasSuffix(".json"),
           firefox.contains(arguments[1]), arguments[1] == "pistachio@snackstud.io" { return .firefox }
        throw BrowserNativeError.unapprovedExtension
    }
}
