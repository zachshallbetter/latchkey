import AppKit
import LatchkeyCore
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI

/// Shows who is asking, from where and for what. With Touch ID, the panel has its own fingerprint area: touching the
/// sensor approves what's selected, so one step approves a request. Without Touch ID (or for pushes, which have their
/// own production check), its buttons choose and the system sheet confirms.
/// Things you started yourself, in the Latchkey window or in Latchkey for Safari, skip the panel: the system sheet
/// alone confirms them, except pushes, which always show it.
final class PanelApprover: Approver, @unchecked Sendable {
    let system = SystemApprover()
    /// How long the panel waits before counting as a denial.
    let timeout: TimeInterval = 90

    var method: String { system.method }

    func approve(_ request: ApprovalRequest) -> ApprovalDecision {
        // Pushes always show the panel, even from the window: it's where production is confirmed.
        if (request.fromApp || request.fromSafari) && request.action != .push { return system.approve(request) }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var choice = ApprovalDecision.deny
        nonisolated(unsafe) var touched = false
        DispatchQueue.main.async {
            ApprovalWindow.shared.show(request) { decision, authenticated in
                choice = decision
                touched = authenticated
                done.signal()
            }
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            DispatchQueue.main.sync { ApprovalWindow.shared.dismiss() }
            return .deny
        }
        guard choice.allowed else { return .deny }
        if touched { return choice }
        return system.confirm(request.touchIDReason) ? choice : .deny
    }
}

@MainActor
final class ApprovalWindow {
    static let shared = ApprovalWindow()
    private var panel: NSPanel?
    private var reply: ((ApprovalDecision, Bool) -> Void)?

    /// `reply` gets the decision, and whether Touch ID in the panel already confirmed it.
    func show(_ request: ApprovalRequest, reply: @escaping (ApprovalDecision, Bool) -> Void) {
        dismiss()
        self.reply = reply
        let view = ApprovalView(request: request) { [weak self] decision, authenticated in self?.finish(decision, authenticated) }
        let host = NSHostingController(rootView: view)
        let panel = NSPanel(contentViewController: host)
        panel.styleMask = [.titled, .fullSizeContentView]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.center()
        self.panel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        if let r = reply { reply = nil; r(.deny, false) }
    }

    private func finish(_ decision: ApprovalDecision, _ authenticated: Bool) {
        let r = reply
        reply = nil
        panel?.orderOut(nil)
        panel = nil
        r?(decision, authenticated)
    }
}

/// What's selected in the panel, read when Touch ID succeeds.
@MainActor
final class ApprovalChoice: ObservableObject {
    @Published var grant = false
    /// Seconds, or `untilQuit` for "until the agent quits".
    @Published var grantFor: Double = 3600
    @Published var thisCommandOnly = false
    static let untilQuit = -1.0

    var decision: ApprovalDecision {
        guard grant else { return .once }
        let untilQuit = grantFor == Self.untilQuit
        return .grant(GrantChoice(duration: untilQuit ? 86400 : grantFor, untilAgentQuits: untilQuit, thisCommandOnly: thisCommandOnly))
    }
}

/// Touch ID drawn inside the panel instead of in a system sheet.
struct TouchIDArea: NSViewRepresentable {
    let context: LAContext
    func makeNSView(context: Context) -> LAAuthenticationView { LAAuthenticationView(context: self.context, controlSize: .regular) }
    func updateNSView(_ view: LAAuthenticationView, context: Context) {}
}

struct ApprovalView: View {
    let request: ApprovalRequest
    /// The decision, and whether Touch ID in the panel already confirmed it.
    let decide: (ApprovalDecision, Bool) -> Void
    @StateObject private var choice = ApprovalChoice()
    /// Production pushes need this ticked, on top of Touch ID.
    @State private var confirmedProduction = false
    /// Set when this Mac can use Touch ID here; nil means buttons, then the system sheet.
    @State private var touch: LAContext?
    @State private var decided = false

    /// Touch ID in the panel, where it can do the whole job: not for pushes (production has its own check first).
    private static func embeddedTouchID(for request: ApprovalRequest) -> LAContext? {
        guard request.action != .push else { return nil }
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        return ctx
    }

    private func finish(_ decision: ApprovalDecision, authenticated: Bool) {
        guard !decided else { return }
        decided = true
        touch?.invalidate()
        decide(decision, authenticated)
    }

    private func startTouchID() {
        guard let ctx = Self.embeddedTouchID(for: request) else { return }
        #if DEBUG
        if Snapshot.requested { touch = ctx; return }   // draw the fingerprint area without asking for a finger
        #endif
        touch = ctx
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: request.touchIDReason) { success, error in
            DispatchQueue.main.async {
                if success { finish(choice.decision, authenticated: true); return }
                // Locked out, or no finger: fall back to the buttons and the system sheet (which offers the password).
                if let e = error as? LAError, e.code != .appCancel, e.code != .systemCancel, !decided { touch = nil }
            }
        }
    }

    private var touchPrompt: String {
        if request.action != .read { return "Touch ID to allow" }
        guard choice.grant else { return "Touch ID to allow once" }
        if choice.grantFor == ApprovalChoice.untilQuit, let agent = request.sessionName { return "Touch ID to allow until \(agent) quits" }
        return "Touch ID to allow from this folder"
    }

    var title: String {
        switch request.action {
        case .read: return "Release \(request.names.count == 1 ? request.names[0] : "\(request.names.count) items")?"
        case .add: return "Add \(request.names.first ?? "item")?"
        case .change: return request.names.count == 1 ? "Change \(request.names[0])?" : "Change \(request.names.count) items?"
        case .delete: return request.names.count == 1 ? "Delete \(request.names[0])?" : "Delete \(request.names.count) items?"
        case .importItems: return "Import \(request.names.count) item\(request.names.count == 1 ? "" : "s")?"
        case .grant: return "Allow reads without asking?"
        case .move: return "Move \(request.names.count) item\(request.names.count == 1 ? "" : "s")?"
        case .readVersion: return "Show an earlier value of \(request.names.first ?? "item")?"
        case .restore: return "Restore \(request.names.first ?? "item")?"
        case .link: return "Link \(request.names.first ?? "environment")?"
        case .push: return "Push \(request.names.count) value\(request.names.count == 1 ? "" : "s")?"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    Text("Latchkey").font(.callout).foregroundStyle(.secondary)
                }
            }
            if request.overSSH {
                VStack(alignment: .leading, spacing: 4) {
                    Label("From another computer, through your SSH connection", systemImage: "network")
                        .foregroundStyle(.orange).font(.callout.weight(.semibold))
                    if let r = request.remote {
                        Text("It says it's \(r.host), running \(r.command) in \(r.cwd). Latchkey can't check that.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Latchkey can't see what's asking on the other computer.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let program = request.program {
                Label("Asked by a program that isn't Latchkey's command-line tool: \(program)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
                row("Items", request.names.joined(separator: ", "), mono: true)
                if request.fromSafari {
                    row("Asked by", "Latchkey's Safari extension")
                    if let page = request.page { row("Page", page + "\n(as Safari reported it)", mono: true) }
                } else {
                    row("Asked by", request.chain.prefix(4).joined(separator: " › ") + (request.byAgent ? "\nan agent, through Latchkey's MCP server" : ""))
                }
                if !request.folder.isEmpty { row("Folder", Broker.tilde(request.folder), mono: true) }
                if let c = request.command, !c.isEmpty { row("Command", c, mono: true) }
                if let d = request.duration { row("For", GrantStore.describe(d)) }
                if !request.targets.isEmpty { row(request.action == .push ? "To" : "Target", request.targets.joined(separator: "\n")) }
            }
            if request.production {
                VStack(alignment: .leading, spacing: 6) {
                    Label("This sends values to production.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout.weight(.semibold))
                    Toggle("I mean to change production", isOn: $confirmedProduction)
                    Text("Nothing is deployed; the new values apply on the next deploy.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.12)))
            }
            if request.canGrant {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("Allow from this folder", isOn: $choice.grant).toggleStyle(.checkbox)
                        Picker("", selection: $choice.grantFor) {
                            if let agent = request.sessionName { Text("until \(agent) quits").tag(ApprovalChoice.untilQuit) }
                            Text("for 1 hour").tag(3600.0)
                            Text("for 8 hours").tag(8 * 3600.0)
                            Text("for 1 day").tag(86400.0)
                            Text("for 7 days").tag(7 * 86400.0)
                        }
                        .labelsHidden().fixedSize().disabled(!choice.grant)
                        if touch == nil {
                            Button("Allow") { choice.grant = true; finish(choice.decision, authenticated: false) }
                        }
                    }
                    if let command = request.runCommand {
                        Toggle("Only for \(command.joined(separator: " "))", isOn: $choice.thisCommandOnly)
                            .toggleStyle(.checkbox).lineLimit(1).truncationMode(.middle).disabled(!choice.grant)
                    }
                }
                // Narrowest first: a grant that ends with the agent's session.
                .onAppear { if request.sessionName != nil { choice.grantFor = ApprovalChoice.untilQuit } }
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            }
            if let touch {
                HStack(spacing: 12) {
                    TouchIDArea(context: touch).frame(width: 34, height: 34)
                    Text(touchPrompt).font(.callout.weight(.semibold))
                    Spacer()
                    Button("Deny", role: .cancel) { finish(.deny, authenticated: false) }.keyboardShortcut(.cancelAction)
                }
            } else {
                HStack {
                    Text("Touch ID confirms your choice.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Deny", role: .cancel) { finish(.deny, authenticated: false) }.keyboardShortcut(.cancelAction)
                    Button(request.action == .read ? "Allow Once" : request.action == .push ? "Push" : "Allow") { finish(.once, authenticated: false) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(request.production && !confirmedProduction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: startTouchID)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).font(mono ? .callout.monospaced() : .callout).textSelection(.enabled)
                .lineLimit(3).truncationMode(.middle)
        }
    }
}
