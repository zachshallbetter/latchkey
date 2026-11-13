#if DEBUG && LATCHKEY_APP_STORE
import Darwin
import Foundation
import LatchkeyCore
import Security

/// Headless development-only probes. Runs before AppModel exists, so it never opens the real vault, broker,
/// Safari socket, settings or approval UI. All writes use uniquely named fixture paths.
@MainActor
enum SandboxSelfTest {
    static func runAndExit() -> Never {
        var results: [[String: Any]] = []
        func check(_ name: String, _ body: () throws -> Bool) {
            do { results.append(["name": name, "passed": try body()]) }
            catch {
                let diagnostic = (error as? SocketError)?.description ?? "\((error as NSError).domain):\((error as NSError).code)"
                results.append(["name": name, "passed": false, "error": diagnostic])
            }
        }
        guard sandboxEntitlement() else {
            emit(["passed": false, "reason": "a signed sandbox build is required", "submissionReady": false])
            exit(1)
        }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("latchkey-sandbox-probe-" + UUID().uuidString)
        check("container env rewrite") {
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: fixture) }
            let file = fixture.appendingPathComponent(".env")
            let text = "KEY=fixture-value\n"
            try Data(text.utf8).write(to: file)
            try EnvFile.rewriteFile(at: file, original: text, toReferences: ["KEY": "fixture/development/KEY"])
            return try String(contentsOf: file, encoding: .utf8) == "KEY=latchkey://fixture/development/KEY\n"
        }
        check("unselected home file denied") {
            guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { return false }
            let outside = URL(fileURLWithPath: String(cString: home)).appendingPathComponent(".latchkey-sandbox-probe-" + UUID().uuidString)
            do {
                try Data("fixture".utf8).write(to: outside, options: .withoutOverwriting)
                try? FileManager.default.removeItem(at: outside)
                return false
            } catch let error as NSError {
                // An unrelated I/O failure isn't proof of sandbox enforcement.
                return error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError
            }
        }
        check("app-group local IPC and kernel identity") {
            guard let group = Bundle.main.object(forInfoDictionaryKey: "LatchkeyAppGroup") as? String,
                  let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
                  let team = CodeIdentity.ownTeam else { return false }
            // sockaddr_un has a short pathname limit; a full UUID plus a macOS Group Containers path exceeds it.
            let path = container.appendingPathComponent(".p" + UUID().uuidString.prefix(8)).path
            guard !FileManager.default.fileExists(atPath: path) else { return false }
            let listener = try UnixSocket.listen(path)
            defer { close(listener); unlink(path) }
            let client = try UnixSocket.connect(path)
            defer { close(client) }
            let server = accept(listener, nil, nil)
            guard server >= 0 else { return false }
            defer { close(server) }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(server, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let identity = CodeIdentity.peer(server, is: CodeIdentity.appIdentifier, team: team)
            try UnixSocket.writeLine(client, Data("fixture-ipc".utf8))
            let reply = try UnixSocket.readLine(server)
            return identity && PeerInfo.pid(of: server) == getpid() && reply == Data("fixture-ipc".utf8)
        }
        check("system child execution") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        let passed = results.allSatisfy { $0["passed"] as? Bool == true }
        emit(["passed": passed, "submissionReady": false, "checks": results,
              "observations": ["parentArgumentsVisible": !PeerInfo.arguments(of: getppid()).isEmpty,
                               "parentWorkingDirectoryVisible": !PeerInfo.cwd(of: getppid()).isEmpty],
              "notCovered": ["real selected-folder grants", "terminal CLI/MCP", "caller-context forgery",
                             "Node/npm and user commands", "remote pushes", "real keychain and migration", "cross-Mac sync", "Safari", "TestFlight"]])
        exit(passed ? 0 : 1)
    }

    /// Keychain round trip in the app's access group, under fixture services that never synchronize. The real
    /// "latchkey" and "latchkey.history" items are never queried.
    static func runVaultAndExit() -> Never {
        var results: [[String: Any]] = []
        func check(_ name: String, _ body: () throws -> Bool) {
            do { results.append(["name": name, "passed": try body()]) }
            catch {
                var diagnostic = "\((error as NSError).domain):\((error as NSError).code)"
                if case StoreError.keychain(_, let status) = error { diagnostic = "OSStatus \(status)" }
                results.append(["name": name, "passed": false, "error": diagnostic])
            }
        }
        guard sandboxEntitlement(), let group = Bundle.main.object(forInfoDictionaryKey: "LatchkeyAccessGroup") as? String,
              !group.contains("$"), let dot = group.firstIndex(of: ".") else {
            emit(["passed": false, "reason": "a signed sandbox build with a resolved access group is required", "submissionReady": false])
            exit(1)
        }
        let service = "latchkey.probe." + UUID().uuidString.prefix(8).lowercased()
        let store = KeychainStore(mode: .iCloud(accessGroup: group), service: service, synchronizable: false)
        let versions = KeychainVersionStore(mode: .iCloud(accessGroup: group), service: service + ".history", synchronizable: false)
        let name = "FIXTURE_VAULT"
        func cleanup() {
            _ = try? store.remove(name)
            for version in (try? versions.list(item: nil)) ?? [] { try? versions.remove(version.id) }
        }
        defer { cleanup() }
        check("save and read in the app access group") {
            try store.save(name: name, value: "fixture-vault-one", kind: .token, agentSafe: false, note: "probe")
            return try store.values([name]) == [name: "fixture-vault-one"] && store.list().map(\.name) == [name]
        }
        check("fixture item is not synchronizable") {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: true]
            return SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound
        }
        check("change records a readable version") {
            guard let info = try store.info(name) else { return false }
            let old = try store.values([name])[name] ?? ""
            let version = try versions.record(info, value: old, reason: .changed, by: "vault probe")
            try store.save(name: name, value: "fixture-vault-two", kind: nil, agentSafe: nil, note: nil)
            return try store.values([name])[name] == "fixture-vault-two" && versions.list(item: name).map(\.id) == [version.id] &&
                versions.value(version.id) == "fixture-vault-one"
        }
        var deleted: Version?
        check("delete keeps history and removes the item") {
            guard let info = try store.info(name), let value = try store.values([name])[name] else { return false }
            Thread.sleep(forTimeInterval: 1.1)   // stored dates have one-second resolution, so "latest" needs distinct seconds
            deleted = try versions.record(info, value: value, reason: .deleted, by: "vault probe")
            guard try store.remove(name) else { return false }
            return try store.list().isEmpty && store.values([name]).isEmpty &&
                versions.deleted(existing: []).first?.id == deleted?.id && versions.list(item: name).count == 2
        }
        check("restore recreates the deleted item from history") {
            guard let deleted, let value = try versions.value(deleted.id) else { return false }
            try store.save(name: name, value: value, kind: deleted.kind, agentSafe: deleted.agentSafe, note: deleted.note)
            return try store.values([name])[name] == "fixture-vault-two" && store.info(name)?.note == "probe"
        }
        check("an access group outside the entitlements is refused") {
            let wrong = String(group[..<dot]) + ".io.latchkey.probe.not-entitled"
            let outside = KeychainStore(mode: .iCloud(accessGroup: wrong), service: service, synchronizable: false)
            do { try outside.save(name: name, value: "x", kind: .token, agentSafe: false, note: ""); return false }
            catch StoreError.keychain(_, let status) { return status == errSecMissingEntitlement }
        }
        cleanup()
        check("cleanup leaves no fixture items") {
            try store.list().isEmpty && versions.list(item: nil).isEmpty
        }
        let passed = results.allSatisfy { $0["passed"] as? Bool == true }
        emit(["passed": passed, "submissionReady": false, "checks": results,
              "notCovered": ["real vault items and history", "iCloud Keychain synchronization", "direct-to-store migration",
                             "approval UI", "Apple Distribution/TestFlight signing"]])
        exit(passed ? 0 : 1)
    }

    /// One launch of a multi-launch file access probe. The harness stands in for the Open panel by passing
    /// App Sandbox extension tokens for fixture paths; SecurityScopedAccess then runs exactly as after a selection.
    /// Phases: "grant" (consume tokens, remember, rewrite), "relaunch" (restore from saved records only, forget),
    /// "revoked" (restore after forgetting). Records travel as base64 on stdin/stdout; they hold paths, never contents.
    static func runFileAccessAndExit(phase: String) -> Never {
        var results: [[String: Any]] = []
        var observations: [String: Any] = [:]
        var saved: Data?
        func check(_ name: String, _ body: () throws -> Bool) {
            do { results.append(["name": name, "passed": try body()]) }
            catch { results.append(["name": name, "passed": false, "error": "\((error as NSError).domain):\((error as NSError).code)"]) }
        }
        func denied(_ body: () throws -> Void) -> Bool {
            do { try body(); return false }
            catch let error as NSError { return error.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) }
        }
        guard sandboxEntitlement(), ["grant", "relaunch", "revoked"].contains(phase),
              let input = try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: String],
              let root = input["root"], root.hasPrefix("/") else {
            emit(["passed": false, "reason": "a signed sandbox build and a valid phase are required", "submissionReady": false])
            exit(1)
        }
        let project = URL(fileURLWithPath: root).appendingPathComponent("project")
        let file = project.appendingPathComponent(".env")
        let sibling = URL(fileURLWithPath: root).appendingPathComponent("other")
        let siblingFile = sibling.appendingPathComponent(".env")
        let original = "KEY=fixture-value\n"
        let access = try? SecurityScopedAccess(saved: input["saved"].flatMap { Data(base64Encoded: $0) }) { saved = $0 }
        guard let access else { emit(["passed": false, "reason": "saved records could not be read", "submissionReady": false]); exit(1) }
        func read() throws -> String { try String(contentsOf: file, encoding: .utf8) }
        func siblingDenied() -> Bool {
            denied { _ = try Data(contentsOf: siblingFile) } && denied { _ = try FileManager.default.contentsOfDirectory(atPath: sibling.path) } &&
                denied { try Data("x".utf8).write(to: sibling.appendingPathComponent(".latchkey-probe"), options: .withoutOverwriting) }
        }
        func rewriteWorks(from text: String, to value: String) throws -> Bool {
            let before = try FileManager.default.attributesOfItem(atPath: file.path)
            try EnvFile.rewriteFile(at: file, original: text, toReferences: ["KEY": value])
            let after = try FileManager.default.attributesOfItem(atPath: file.path)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: project.path).filter { $0.hasPrefix(".latchkey-") }
            return try read() == "KEY=latchkey://\(value)\n" && after[.posixPermissions] as? Int == before[.posixPermissions] as? Int &&
                after[.systemFileNumber] as? Int != before[.systemFileNumber] as? Int && leftovers.isEmpty
        }
        switch phase {
        case "grant":
            check("file unreadable before it is selected") { denied { _ = try read() } }
            check("selected file is readable and remembered") {
                guard let token = input["fileToken"], sandbox_extension_consume(token) > 0 else { return false }
                try access.remember(file, isDirectory: false)
                return try read() == original && access.records.count == 1
            }
            check("atomic rewrite waits for the parent folder") {
                // The rewrite fails for want of a temporary file beside the target, so confirm that cause directly.
                let probe = project.appendingPathComponent(".latchkey-probe-" + UUID().uuidString).path
                let descriptor = open(probe, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                let blocked = descriptor < 0 && errno == EPERM
                if descriptor >= 0 { close(descriptor); unlink(probe) }
                var refused = false
                do { try EnvFile.rewriteFile(at: file, original: original, toReferences: ["KEY": "fixture/one"]) } catch { refused = true }
                return try blocked && refused && read() == original
            }
            check("parent grant allows atomic rewrite that keeps permissions") {
                guard let token = input["folderToken"], sandbox_extension_consume(token) > 0 else { return false }
                try access.remember(project, isDirectory: true)
                return try rewriteWorks(from: original, to: "fixture/one") && access.records.count == 2
            }
        case "relaunch":
            check("nothing is readable before records are restored") { denied { _ = try read() } }
            check("saved records restore access after relaunch") {
                let failed = access.restore()
                return try failed.isEmpty && access.records.count == 2 && read() == "KEY=latchkey://fixture/one\n"
            }
            check("rewrite works again after relaunch") { try rewriteWorks(from: "KEY=latchkey://fixture/one\n", to: "fixture/two") }
            check("removing both permissions forgets them") {
                for record in access.records { try access.forget(record.id) }
                return access.records.isEmpty
            }
            // The initial Open panel extension may last for the process, so same-process denial is reported, not required.
            observations["fileReadableInSameProcessAfterForget"] = (try? read()) != nil
        default:
            check("no records remain after removal") { access.restore().isEmpty && access.records.isEmpty }
            check("removed file is inaccessible after relaunch") { denied { _ = try read() } }
            check("removed parent no longer allows replacement") {
                denied { try EnvFile.rewriteFile(at: file, original: "KEY=latchkey://fixture/two\n", toReferences: ["KEY": "fixture/three"]) }
            }
        }
        check("unselected sibling folder stays inaccessible") { siblingDenied() }
        let passed = results.allSatisfy { $0["passed"] as? Bool == true }
        var report: [String: Any] = ["phase": phase, "passed": passed, "submissionReady": false, "checks": results, "observations": observations]
        if let saved { report["savedAccess"] = saved.base64EncodedString() }
        emit(report)
        exit(passed ? 0 : 1)
    }

    /// A separate-process fixture for the real terminal CLI. Never initialize AppModel or a Keychain store.
    /// A random, short App Group path prevents collision with the production broker or Safari listener.
    static func serveFixtureAndExit() -> Never {
        guard sandboxEntitlement(), let id = ProcessInfo.processInfo.environment["LATCHKEY_PROBE_ID"],
              id.count == 8, id.allSatisfy({ $0.isHexDigit }),
              let folder = ProcessInfo.processInfo.environment["LATCHKEY_PROBE_FOLDER"], folder.hasPrefix("/"),
              let group = Bundle.main.object(forInfoDictionaryKey: "LatchkeyAppGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { exit(64) }
        let path = container.appendingPathComponent(".c" + id).path
        guard !FileManager.default.fileExists(atPath: path) else { exit(73) }
        do {
            let store = MemoryStore()
            try store.save(name: "FIXTURE_KEY", value: "fixture-secret-transport-12345", kind: .token, agentSafe: true, note: "")
            try store.save(name: "FIXTURE_FILE", value: "fixture-private-key-67890", kind: .key, agentSafe: true, note: "")
            try store.save(name: "GRANTED_KEY", value: "fixture-granted-24680", kind: .token, agentSafe: false, note: "")
            try store.save(name: "ONCE_KEY", value: "fixture-once-13579", kind: .token, agentSafe: false, note: "")
            let broker = Broker(store: store, approver: FixedApprover(false), logURL: nil, allowsPush: false, socketPath: path)
            broker.grants.add(names: ["GRANTED_KEY"], folder: folder, duration: 300, createdBy: "transport fixture",
                              commands: [["/usr/bin/true"]])
            broker.grants.add(names: ["ONCE_KEY"], folder: folder, duration: 300, createdBy: "transport fixture",
                              commands: [["/usr/bin/true"]], uses: 1)
            try broker.serve(gate: .commandLineTool)
        } catch { exit(1) }
    }

    @_silgen_name("sandbox_extension_consume")
    private static func sandbox_extension_consume(_ token: UnsafePointer<CChar>) -> Int64

    private static func sandboxEntitlement() -> Bool {
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return entitlements["com.apple.security.app-sandbox"] as? Bool == true
    }

    private static func emit(_ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
    }
}
#endif
