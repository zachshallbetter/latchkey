import Foundation

/// `latchkey`, and `lk` for short, in ~/.local/bin: links to the tool inside Latchkey.app, so they update with the app.
/// Latchkey › Install Command Line Tool…, Settings, the welcome and the installer package's setup helper (which runs
/// the app with `--install-command-line-tool`) all install them through `install`.
public enum CommandLineToolLinks {
    public static let names = ["latchkey", "lk"]

    public static func directory(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".local/bin")
    }

    public static func links(home: String) -> [URL] {
        names.map { directory(home: home).appendingPathComponent($0) }
    }

    /// What is at one link's path.
    public enum State: Equatable {
        /// A link to this tool.
        case linked
        /// Nothing there.
        case missing
        /// A link to something else (another copy of Latchkey, an old build); `install` replaces it.
        case otherLink(String)
        /// A file or folder that isn't a link; `install` leaves it alone.
        case file
    }

    public static func state(of link: URL, tool: URL, fileManager fm: FileManager = .default) -> State {
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            return dest == tool.path ? .linked : .otherLink(dest)
        }
        return fm.fileExists(atPath: link.path) ? .file : .missing
    }

    public struct Result: Equatable {
        /// Display names (`~/.local/bin/latchkey`) of the links that now point at the tool.
        public var installed: [String] = []
        /// Display names of files in the way, left as they are.
        public var inTheWay: [String] = []

        public var message: String {
            var text = installed.isEmpty ? "" : "Installed \(installed.joined(separator: " and ")). Make sure ~/.local/bin is on your PATH."
            if !inTheWay.isEmpty {
                text += (text.isEmpty ? "" : " ") + "\(inTheWay.joined(separator: " and ")) already exists and isn't a link to Latchkey; left as is."
            }
            return text
        }
    }

    /// Links each name to `tool`. Replaces only links; a file of either name is left alone and reported.
    public static func install(tool: URL, home: String, fileManager fm: FileManager = .default) throws -> Result {
        var result = Result()
        try fm.createDirectory(at: directory(home: home), withIntermediateDirectories: true)
        for link in links(home: home) {
            let name = "~/.local/bin/" + link.lastPathComponent
            switch state(of: link, tool: tool, fileManager: fm) {
            case .linked:
                result.installed.append(name)
                continue
            case .file:
                result.inTheWay.append(name)
                continue
            case .otherLink:
                try fm.removeItem(at: link)
            case .missing:
                break
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: tool)
            result.installed.append(name)
        }
        return result
    }

    /// Whether ~/.local/bin is one of the folders in a PATH value (as a login shell prints it).
    public static func directoryIsOnPath(_ path: String, home: String) -> Bool {
        let wanted = directory(home: home).standardizedFileURL.path
        return path.split(separator: ":").contains { entry in
            let expanded = entry.hasPrefix("~/") ? home + entry.dropFirst(1) : String(entry)
            return URL(fileURLWithPath: expanded).standardizedFileURL.path == wanted
        }
    }
}
