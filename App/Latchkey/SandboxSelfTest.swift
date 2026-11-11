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
            let broker = Broker(store: store, approver: FixedApprover(false), logURL: nil, allowsPush: false, socketPath: path)
            broker.grants.add(names: ["GRANTED_KEY"], folder: folder, duration: 300, createdBy: "transport fixture",
                              commands: [["/usr/bin/true"]])
            try broker.serve(gate: .commandLineTool)
        } catch { exit(1) }
    }

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
