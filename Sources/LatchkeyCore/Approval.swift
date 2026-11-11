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
    /// The asking program's path when it isn't Latchkey's own signed command-line tool.
    public var program: String?
    /// Asked from the Latchkey window itself (the same process), not over the socket.
    public var fromApp = false
    /// The agent a grant made here could last as long as ("claude"), if the caller runs under one.
    public var sessionName: String?
    /// What a signed `latchkey run` is starting, which a grant made here can be limited to.
    public var runCommand: [String]?
    /// From another computer through an SSH forward, and what the tool there says about itself (unverified).
    public var overSSH = false
    public var remote: RemoteClaim?
    /// From Latchkey's Safari extension, and the site the value was found on (as Safari reported it).
    public var fromSafari = false
    public var page: String?
    /// Releasing values to a command, where the approval can also become a grant for its folder. Only `get` sets it.
    public var offersGrant = false

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

    /// Who's asking, in a word: the agent the caller runs under ("Claude"), else the nearest program that isn't a shell.
    /// Nil for the Latchkey window and Safari, and over SSH, where nothing on the other computer can be seen.
    public var asker: String? {
        guard !fromApp, !fromSafari, !overSSH else { return nil }
        let name = sessionName ?? chain.first { !PeerInfo.launchers.contains($0.lowercased()) }
        guard let name, !name.isEmpty else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// The line for the Touch ID sheet, which macOS shows as "Latchkey is trying to …": what's asked, by whom and from
    /// which folder. The full process chain and command are in the panel, for anyone who wants them.
    public var touchIDReason: String {
        let what = reason.range(of: ", asked by ").map { String(reason[..<$0.lowerBound]) } ?? reason
        guard let who = asker else { return what }
        let place = folder.isEmpty || folder == "/" ? "" : " in \(Broker.tilde(folder))"
        if action == .read, what.hasPrefix("release ") { return "give \(what.dropFirst(8)) to \(who)\(place)" }
        return "\(what), asked by \(who)\(place)"
    }

    /// Changes are confirmed by the system's Touch ID sheet alone; the panel with every detail appears only if that's
    /// cancelled. Releasing values, grants, earlier values and pushes have choices to make, and a request from another
    /// computer or from a program that isn't Latchkey's tool has a warning to read, so those show the panel first.
    public var sheetFirst: Bool {
        guard !overSSH, program == nil, !production else { return false }
        switch action {
        case .add, .change, .delete, .importItems, .move, .restore, .link: return true
        case .read, .readVersion, .grant, .push: return false
        }
    }

    /// Reads from a folder can be turned into a grant from the approval itself.
    public var canGrant: Bool { offersGrant && action == .read && !folder.isEmpty && folder != "/" && remote == nil && !overSSH }
}

public enum ApprovalDecision: Sendable, Equatable {
    case deny
    case once
    /// Allow now, and keep allowing these names from this folder, within these limits.
    case grant(GrantChoice)

    public var allowed: Bool { self != .deny }
}

/// A grant made from an approval: for how long, and whether only while the agent runs or only for this command.
public struct GrantChoice: Sendable, Equatable {
    public var duration: TimeInterval
    public var untilAgentQuits: Bool
    public var thisCommandOnly: Bool

    public init(duration: TimeInterval, untilAgentQuits: Bool = false, thisCommandOnly: Bool = false) {
        self.duration = duration
        self.untilAgentQuits = untilAgentQuits
        self.thisCommandOnly = thisCommandOnly
    }
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

    /// How a Touch ID sheet ended.
    public enum Outcome: Sendable, Equatable {
        case passed
        /// The person pressed the sheet's cancel button.
        case cancelled
        /// Nobody answered in time, authentication failed, or it couldn't be shown.
        case failed
    }

    /// Touch ID / Watch / password with this reason. True if the person passed it.
    public func confirm(_ reason: String) -> Bool { evaluate(reason) == .passed }

    /// Touch ID / Watch / password with this reason, telling a deliberate cancel from no answer.
    public func evaluate(_ reason: String, cancelTitle: String = "Deny") -> Outcome {
        let ctx = LAContext()
        ctx.localizedCancelTitle = cancelTitle
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return .failed }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome = Outcome.failed
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            outcome = success ? .passed : (error as? LAError)?.code == .userCancel ? .cancelled : .failed
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            ctx.invalidate()
            done.wait()
            outcome = .failed
        }
        return outcome
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
