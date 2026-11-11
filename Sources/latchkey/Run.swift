import Foundation
import LatchkeyCore

// Starting a command with values filled in: shared by `latchkey run`, `latchkey check` and the MCP server.
// Nothing here exits; callers turn a RunError into an exit code or a tool error.

/// Why a request or a run couldn't go ahead.
enum RunError: Error {
    case usage(String)          // exit 64
    case unreadable(String)     // exit 66: an env file
    case missing([String])      // exit 66
    case refused([String])      // exit 77
    case unreachable(String)    // exit 69
    case failed(String)         // exit 1
}

/// What to load into a command's environment.
struct RunSpec {
    var envFiles: [String] = []
    /// `project/environment` scopes loaded without a file.
    var scopes: [String] = []
    /// NAME=ID pairs delivered as temporary files.
    var fileArgs: [(name: String, id: String)] = []
    /// The folder relative env file paths are read from.
    var cwd: String
    /// Swap the long-lived AWS key for short-lived credentials from STS: GetSessionToken, or AssumeRole with a role.
    var aws: (role: String?, duration: TimeInterval)?
}

/// The command's environment with values filled in, the values to hide in its output, and the private folder
/// holding key files. Call `cleanUp()` when the command has ended.
struct PreparedRun {
    var environment: [String: String]
    var secretValues: [String]
    var tempDir: URL?
    /// Keys held back for `--proxy`: the command has placeholders instead.
    var proxies: [ProxyRoute] = []

    func cleanUp() { if let tempDir { try? FileManager.default.removeItem(at: tempDir) } }
}

/// `base` with env files, environments and key files applied: references still in place, nothing asked yet.
func plannedEnvironment(_ spec: RunSpec, base: [String: String], call: (Request) throws -> Response) throws -> [String: String] {
    var env = base
    for path in spec.envFiles {
        let full = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: spec.cwd, isDirectory: true)).path
        do { for (k, v) in try EnvFile.load(full) { env[k] = v } }
        catch { throw RunError.unreadable("cannot read \(path): \(error.localizedDescription)") }
    }
    if !spec.scopes.isEmpty {
        let listed = try call(Request(op: "list"))
        guard listed.ok else { throw RunError.failed(listed.error ?? "the app refused the request") }
        let all = listed.secrets ?? []
        for scope in spec.scopes {
            let inScope = all.filter { $0.name.hasPrefix(scope + "/") }
            if inScope.isEmpty { throw RunError.missing(["\(scope)/*"]) }
            for item in inScope { env[item.ref.name] = References.scheme + item.name }
            // Shared items this environment's files use (recorded on import), unless something already set them.
            let folders = Set(inScope.flatMap { $0.usedIn ?? [] }.map { Repo.mainCheckout(for: $0) ?? URL(fileURLWithPath: $0).deletingLastPathComponent().path })
            for item in all where item.ref.isShared && env[item.name] == nil {
                let used = (item.usedIn ?? []).contains { path in folders.contains { path.hasPrefix($0 + "/") } }
                if used { env[item.name] = References.scheme + item.name }
            }
        }
    }
    for f in spec.fileArgs { env[f.name] = References.fileScheme + f.id }
    return env
}

/// The item IDs an environment refers to, as `latchkey://` or `latchkey-file://` references.
func referencedIDs(_ env: [String: String]) -> [String] {
    Array(Set(References.names(in: env) + References.fileReferences(in: env).values)).sorted()
}

/// Asks for every value `env` refers to and fills them in. Missing or refused items throw; nothing is filled in
/// unless everything was released.
func prepareRun(_ spec: RunSpec, env planned: [String: String], masking: Bool, proxy: Bool = false,
                call: (Request) throws -> Response) throws -> PreparedRun {
    var env = planned
    // Variables that are exactly one reference, for --proxy to hold back.
    var wholeReferences: [String: String] = [:]
    for (k, v) in env where v.hasPrefix(References.scheme) {
        let id = String(v.dropFirst(References.scheme.count))
        if Wire.isValidName(id) { wholeReferences[k] = id }
    }
    let fileRefs = References.fileReferences(in: env)
    let names = referencedIDs(env)
    if proxy && names.isEmpty { throw RunError.usage("--proxy needs an OPENAI_API_KEY or ANTHROPIC_API_KEY reference") }
    guard !names.isEmpty else { return PreparedRun(environment: env, secretValues: [], tempDir: nil) }
    let r = try call(Request(op: "get", names: names))
    guard r.ok else { throw RunError.failed(r.error ?? "the app refused the request") }
    if let m = r.missing, !m.isEmpty { throw RunError.missing(m) }
    if let d = r.denied, !d.isEmpty { throw RunError.refused(d) }
    let values = r.values ?? [:]
    guard names.allSatisfy({ values[$0] != nil }) else { throw RunError.failed("the app did not return every requested value") }
    env = References.resolve(env: env, with: values)
    let proxies: [ProxyRoute]
    do { proxies = proxy ? try holdBackProxiedKeys(&env, values: values, references: wholeReferences) : [] }
    catch { throw RunError.usage(String(describing: error)) }
    var tempDir: URL?
    if !fileRefs.isEmpty {
        // A private folder of owner-only files, removed when the command ends.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("latchkey-run-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var filesByID: [String: URL] = [:]
            for (key, id) in fileRefs.sorted(by: { $0.key < $1.key }) {
                if let file = filesByID[id] { env[key] = file.path; continue }
                let file = dir.appendingPathComponent(UUID().uuidString)
                guard FileManager.default.createFile(atPath: file.path, contents: Data(values[id]!.utf8),
                                                     attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                filesByID[id] = file
                env[key] = file.path
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw RunError.failed("couldn't write a temporary file for \(fileRefs.keys.sorted().joined(separator: ", ")): \(error.localizedDescription)")
        }
        tempDir = dir
    }
    let masked = Set(r.masked ?? names)
    let secrets = masking ? values.filter { masked.contains($0.key) }.map(\.value) : []
    var masks = secrets
    if let aws = spec.aws {
        // The long-lived key must come from Latchkey, so it never reaches the command.
        guard let idRef = wholeReferences["AWS_ACCESS_KEY_ID"], let secretRef = wholeReferences["AWS_SECRET_ACCESS_KEY"],
              let id = values[idRef], let secret = values[secretRef] else {
            tempDir.map { try? FileManager.default.removeItem(at: $0) }
            throw RunError.usage("short-lived AWS credentials need AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY as latchkey:// references")
        }
        switch AWSSTS.mint(accessKeyID: id, secret: secret, role: aws.role, duration: aws.duration) {
        case .success(let c):
            env["AWS_ACCESS_KEY_ID"] = c.accessKeyID
            env["AWS_SECRET_ACCESS_KEY"] = c.secretAccessKey
            env["AWS_SESSION_TOKEN"] = c.sessionToken
            env["AWS_CREDENTIAL_EXPIRATION"] = c.expiration
            masks += [secret, c.secretAccessKey, c.sessionToken]
        case .failure(let f):
            tempDir.map { try? FileManager.default.removeItem(at: $0) }
            throw RunError.failed(f.description)
        }
    }
    return PreparedRun(environment: env, secretValues: masking ? masks : [], tempDir: tempDir, proxies: proxies)
}

/// Reads `pipe` to its end on a background queue, hiding `secrets`, and hands each masked chunk to `sink`.
func pumpMasked(_ pipe: Pipe, secrets: [String], group: DispatchGroup, sink: @escaping @Sendable (Data) -> Void) {
    group.enter()
    DispatchQueue.global().async {
        var masker = Masker(secrets: secrets)
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            let out = masker.feed(chunk)
            if !out.isEmpty { sink(out) }
        }
        let tail = masker.flush()
        if !tail.isEmpty { sink(tail) }
        group.leave()
    }
}
