import AppKit
import Darwin
import Foundation
import LatchkeyCore

// stdout is exclusively bounded native-messaging frames. Never emit request bodies, values or raw errors.
func answer() -> [String: Any] {
    do {
        guard let team = CodeIdentity.ownTeam,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: team + "." + CodeIdentity.appIdentifier),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CodeIdentity.appIdentifier),
              CodeIdentity.application(at: app, team: team) else {
            return ["ok": false, "error": "Install the signed Pistachio app and set up its browser connection."]
        }
        let config = container.appendingPathComponent("browser-host-allowlist.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: config.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0,
              let size = attributes[.size] as? NSNumber, size.intValue <= 16 * 1024 else {
            return ["ok": false, "error": "Browser connection setup is unavailable."]
        }
        let allowlist = try JSONDecoder().decode(BrowserHostAllowlist.self, from: Data(contentsOf: config))
        let browser = try allowlist.browser(arguments: Array(CommandLine.arguments.dropFirst()))
        let prefix = browser == .chrome ? "com.google.Chrome" : "org.mozilla.firefox"
        let vendor = browser == .chrome ? "EQHXZ8M8AV" : "43AQ936H96"
        guard CodeIdentity.browserParent(getppid(), identifierPrefix: prefix, team: vendor) else {
            return ["ok": false, "error": "This connection must be started by Chrome or Firefox."]
        }
        let message = try BrowserNativeFrame.message(from: BrowserNativeFrame.read(from: .standardInput))
        let path = container.appendingPathComponent("browser.sock").path
        if NSRunningApplication.runningApplications(withBundleIdentifier: CodeIdentity.appIdentifier).isEmpty {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            let done = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in done.signal() }
            _ = done.wait(timeout: .now() + 10)
        }
        // A newly launched app needs a moment to create the listener; never send a secret on a status retry.
        for _ in 0..<30 {
            if let status = try? BrokerClient.send(Request(op: "status"), socketPath: path), status.ok {
                return BrowserExtensionMessages.answer(message, browserName: browser == .chrome ? "Chrome" : "Firefox") { try? BrokerClient.send($0, socketPath: path) }
            }
            usleep(100_000)
        }
        return ["ok": false, "error": "Open Pistachio and try again."]
    } catch {
        return ["ok": false, "error": "Browser connection refused: invalid setup, request or protocol version."]
    }
}

let response = answer()
do { try BrowserNativeFrame.write(response, to: .standardOutput) }
catch { try? BrowserNativeFrame.write(["ok": false, "error": "Browser response exceeds the supported size."], to: .standardOutput) }
