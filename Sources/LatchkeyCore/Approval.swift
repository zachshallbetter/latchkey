import Foundation
import LocalAuthentication

/// Asks the person at the Mac to allow something.
public protocol Approver: Sendable {
    /// How approval happens, for `latchkey status`.
    var method: String { get }
    /// `reason` completes the system sentence "<App> is trying to …".
    func approve(_ reason: String) -> Bool
}

/// The system authentication sheet: Touch ID, a paired Apple Watch, or the account password, in that
/// order of preference, whichever this Mac has. This is the same check that unlocks a passkey or a saved
/// password in the Passwords app. A desktop Mac without a Touch ID keyboard still gets the Watch or the
/// password.
public final class SystemApprover: Approver, @unchecked Sendable {
    /// An unanswered sheet is withdrawn and counts as a denial, so one forgotten prompt
    /// cannot hold up every other request.
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 90) {
        self.timeout = timeout
    }

    public var method: String {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            return "unavailable (\(err?.localizedDescription ?? "no authentication method"))"
        }
        var parts: [String] = []
        if ctx.biometryType == .touchID { parts.append("Touch ID") }
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithWatch, error: nil) { parts.append("Apple Watch") }
        parts.append("password")
        return parts.joined(separator: ", ")
    }

    public func approve(_ reason: String) -> Bool {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Deny"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            ok = success
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            ctx.invalidate()
            done.wait()
        }
        return ok
    }
}

/// Approves or denies everything without asking. Tests only.
public struct FixedApprover: Approver {
    public let answer: Bool
    public init(_ answer: Bool) { self.answer = answer }
    public var method: String { answer ? "always allow (test)" : "always deny (test)" }
    public func approve(_ reason: String) -> Bool { answer }
}

/// Remembers recent read approvals so a test loop does not prompt on every run. Changes are never remembered.
final class ApprovalMemory: @unchecked Sendable {
    private var until: [String: Date] = [:]
    private let lock = NSLock()

    static func key(_ names: [String], _ peer: PeerInfo) -> String {
        ([peer.cwd] + peer.chain + ["|"] + names.sorted()).joined(separator: "\u{1F}")
    }

    func covers(_ key: String, now: Date = Date()) -> Bool {
        lock.withLock { (until[key] ?? .distantPast) > now }
    }

    func remember(_ key: String, for seconds: TimeInterval, now: Date = Date()) {
        guard seconds > 0 else { return }
        lock.withLock {
            until = until.filter { $0.value > now }
            until[key] = now.addingTimeInterval(seconds)
        }
    }
}
