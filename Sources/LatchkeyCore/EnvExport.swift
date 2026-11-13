import Foundation

/// Writing an environment's env file: shared by `lk export` and the app's Export sheet, so both make the same checks.
public enum EnvExport {
    public enum Mode: Sendable, Equatable {
        /// A new file; an existing one is refused.
        case create
        /// Update the variables the record has, append missing ones, leave the rest of an existing file as it is.
        case merge
        /// Replace the whole file.
        case replace
    }

    public struct Plan: Sendable {
        public var mode: Mode
        public var path: String
        /// The text of the file a merge started from, to notice it changing before the write.
        public var existing: String?
        /// The permissions of the file being overwritten.
        public var permissions: mode_t?
        /// Names a merge would add, and names whose value it would change. Without an existing file, every name is
        /// added. With values, a name already in the file is listed as updated although its value may be the same.
        public var added: [String]
        public var updated: [String]
        public var changes: Bool { !added.isEmpty || !updated.isEmpty }
    }

    /// Checks the destination and works out what writing would change, before anything is asked or written. Throws for a
    /// symbolic link, a folder, an existing file in `.create` mode, or a merge into a file that isn't UTF-8 `KEY=VALUE`
    /// lines.
    public static func plan(path: String, record: EnvironmentRecord, values: Bool, mode: Mode) throws -> Plan {
        let current = try EnvFile.existingFile(path)
        if current != nil && mode == .create { throw EnvFile.ExportError.exists(path) }
        let variables = record.resolved()
        var plan = Plan(mode: mode, path: path, existing: nil, permissions: current.map { $0.st_mode & 0o777 },
                        added: variables.keys.sorted(), updated: [])
        guard mode == .merge, current != nil else { return plan }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { throw EnvFile.ExportError.notText(path) }
        let pending = values ? Set(record.variables.filter { $0.value.item != nil }.keys) : []
        let merge = try EnvFile.merge(text, with: variables, pending: pending)
        plan.existing = text
        plan.added = merge.added
        plan.updated = merge.updated
        return plan
    }

    /// Writes the file the plan describes, with `released` the values of the record's items (empty for references).
    /// Returns what a merge changed. A merge refuses a file that changed since the plan, which an approval may have
    /// waited on.
    @discardableResult
    public static func write(_ plan: Plan, record: EnvironmentRecord, released: [String: String] = [:]) throws -> EnvFile.Merge {
        let variables = record.resolved(values: released)
        // Plain text is readable only by its owner.
        let permissions: mode_t = released.isEmpty ? plan.permissions ?? 0o644 : 0o600
        if let existing = plan.existing {
            guard try EnvFile.existingFile(plan.path) != nil,
                  (try? String(contentsOfFile: plan.path, encoding: .utf8)) == existing else { throw EnvFile.ExportError.changed(plan.path) }
            let merge = try EnvFile.merge(existing, with: variables)
            if merge.text != existing || permissions != plan.permissions {
                try EnvFile.writeAtomically(merge.text, to: plan.path, mode: permissions, replace: true)
            }
            return merge
        }
        let text = record.envFile(values: released)
        try EnvFile.writeAtomically(text, to: plan.path, mode: permissions, replace: plan.mode == .replace)
        return EnvFile.Merge(text: text, added: variables.keys.sorted(), updated: [])
    }

    /// Runs git quietly; its exit status, or 127 if it couldn't start.
    static func gitStatus(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return 127 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Why plain text at `path` could end up in Git: the file is tracked, or not ignored, in the checkout it's in. Nil
    /// outside a checkout, or when Git ignores it and doesn't track it.
    public static func gitProblem(_ path: String) -> String? {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard Repo.commonDir(for: folder) != nil else { return nil }
        let shown = Broker.tilde(path)
        if gitStatus(["-C", folder, "ls-files", "--error-unmatch", "--", path]) == 0 {
            return "\(shown) is tracked by Git, so the values would be committed. Write them somewhere Git ignores."
        }
        switch gitStatus(["-C", folder, "check-ignore", "-q", "--", path]) {
        case 0: return nil
        case 1: return "\(shown) isn't ignored by Git, so `git add` would commit the values. Add it to .gitignore first, or write somewhere else."
        default: return "couldn't ask Git whether \(shown) is ignored, so nothing was written."
        }
    }

    /// The cloud service a folder syncs to, if it's in iCloud Drive (including Desktop and Documents) or a File Provider
    /// folder such as Dropbox, Google Drive or OneDrive.
    public static func cloudSync(_ path: String) -> String? {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        if folder.path.contains("/Library/Mobile Documents/") || (try? folder.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
            return "iCloud Drive"
        }
        if let r = folder.path.range(of: "/Library/CloudStorage/") {
            let service = folder.path[r.upperBound...].split(separator: "/").first.map(String.init) ?? "a cloud service"
            return service.split(separator: "-").first.map(String.init) ?? service
        }
        if folder.path.hasPrefix(NSHomeDirectory() + "/Dropbox") { return "Dropbox" }
        return nil
    }
}
