import Foundation

/// The git repository a folder belongs to, found by reading git's own files rather than running git.
/// A worktree (`~/Projects/_worktrees/site/fix-login`) and its main checkout (`~/Projects/site`) share one
/// common directory, so both resolve to the same repository.
public enum Repo {
    /// The repository's common `.git` directory for `path` (a folder or a file), or nil outside a repository.
    public static func commonDir(for path: String) -> String? {
        var dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), !isDir.boolValue { dir.deleteLastPathComponent() }
        while true {
            let git = dir.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) {
                if isDir.boolValue { return git.standardizedFileURL.resolvingSymlinksInPath().path }
                return worktreeCommonDir(gitFile: git)
            }
            if dir.path == "/" { return nil }
            dir.deleteLastPathComponent()
        }
    }

    /// The main checkout's folder for `path`: the folder holding the common `.git` directory.
    public static func mainCheckout(for path: String) -> String? {
        guard let common = commonDir(for: path) else { return nil }
        let url = URL(fileURLWithPath: common)
        return url.lastPathComponent == ".git" ? url.deletingLastPathComponent().path : nil
    }

    /// A worktree's `.git` is a file: `gitdir: <main>/.git/worktrees/<name>`; that folder's `commondir` file
    /// points back at the main `.git` (usually `../..`).
    static func worktreeCommonDir(gitFile: URL) -> String? {
        guard let text = try? String(contentsOf: gitFile, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitdir.hasPrefix("/") { gitdir = gitFile.deletingLastPathComponent().appendingPathComponent(gitdir).path }
        let base = URL(fileURLWithPath: gitdir)
        guard let common = try? String(contentsOf: base.appendingPathComponent("commondir"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty else {
            return base.standardizedFileURL.path
        }
        let resolved = common.hasPrefix("/") ? URL(fileURLWithPath: common) : base.appendingPathComponent(common)
        return resolved.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
