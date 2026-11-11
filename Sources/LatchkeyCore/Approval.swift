import Foundation
import LocalAuthentication

/// What the broker is asking the person at the Mac to allow.
public struct ApprovalRequest: Sendable {
    public enum Action: String, Sendable {
        case read, add, change, delete, importItems, grant, move, readVersion, restore, link, push
    }
    public var action: Action
    public var names: [String]
    /// The asking program and its parents, nearest first ("zsh", "claude").
    public var chain: [String]
    /// Absolute folder the request came from; empty for the app itself.
    public var folder: String
    public var command: String?
    /// For a grant made ahead of time: how long it lasts.
    public var duration: TimeInterval?
    /// Completes the system sentence "<App> is trying to …".
    public var reason: String
    /// push, link: where values are going, as labels.
    public var targets: [String] = []
    /// push: at least one target is production, which needs its own confirmation.
    public var production = false
    /// Asked through `latchkey mcp`, by an agent rather than a command.
    public var byAgent = false

    public init(action: Action, names: [String], chain: [String], folder: String, command: String? = nil,
                duration: TimeInterval? = nil, reason: String) {
        self.action = action
        self.names = names
        self.chain = chain
        self.folder = folder
        self.command = command
        self.duration = duration
        self.reason = reason
    }

    /// Reads from a folder can be turned into a grant from the approval itself.
    public var canGrant: Bool { action == .read && !folder.isEmpty }
    /// Requests made in the Latchkey window: the person is already there, so Touch ID alone is enough, except for
    /// pushes, which always show the panel.
    public var fromApp: Bool { chain.first == Broker.appCaller }
}

public enum ApprovalDecision: Sendable, Equatable {
    case deny
    case once
    /// Allow now, and keep allowing these names from this folder for this long.
    case grant(TimeInterval)

    public var allowed: Bool { self != .deny }
}

/// Asks the person at the Mac to allow something.
public protocol Approver: Sendable {
    /// How approval happens, for `latchkey status`.
    var method: String { get }
    func approve(_ request: ApprovalRequest) -> ApprovalDecision
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

    public func approve(_ request: ApprovalRequest) -> ApprovalDecision {
        // The system sheet has no way to ask "are you sure this is production?", so it doesn't approve that.
        if request.production { return .deny }
        return confirm(request.reason) ? .once : .deny
    }

    /// Touch ID / Watch / password with this reason. True if the person passed it.
    public func confirm(_ reason: String) -> Bool {
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

/// Gives the same answer to everything without asking. Tests only.
public struct FixedApprover: Approver {
    public let answer: ApprovalDecision
    public init(_ allow: Bool) { answer = allow ? .once : .deny }
    public init(_ decision: ApprovalDecision) { answer = decision }
    public var method: String { "fixed (test)" }
    public func approve(_ request: ApprovalRequest) -> ApprovalDecision { answer }
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
