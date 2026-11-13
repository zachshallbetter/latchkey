import AppKit
import LatchkeyCore
import SwiftUI

/// One prompt at a time. A change (add, change, delete, import, move, restore, link) gets the system Touch ID sheet
/// alone, saying what, who and where; its Details… button opens this panel with everything, to allow or deny.
/// Releasing values, grants, earlier values and pushes show the panel first, where the choice is made (once, this
/// folder, until the agent quits; production), and the sheet confirms after. So does anything from another computer
/// or a program that isn't Latchkey's tool, whose warning has to be read first.
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
        if request.sheetFirst {
            switch system.evaluate(request.touchIDReason, cancelTitle: "Details…") {
            case .passed: return .once
            case .failed: return .deny   // no answer, or Touch ID failed: nothing more to show
            case .cancelled: break       // show what was asked, in full, to allow after all or deny
            }
        }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var choice = ApprovalDecision.deny
        DispatchQueue.main.async {
            ApprovalWindow.shared.show(request, afterCancel: request.sheetFirst) { decision in
                choice = decision
                done.signal()
            }
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            DispatchQueue.main.sync { ApprovalWindow.shared.dismiss() }
            return .deny
        }
        guard choice.allowed else { return .deny }
        return system.confirm(request.touchIDReason) ? choice : .deny
    }
}

@MainActor
final class ApprovalWindow {
    static let shared = ApprovalWindow()
    private var panel: NSPanel?
    private var reply: ((ApprovalDecision) -> Void)?

    /// `reply` gets the choice; the system sheet confirms an allowed one after the panel closes.
    func show(_ request: ApprovalRequest, afterCancel: Bool, reply: @escaping (ApprovalDecision) -> Void) {
        dismiss()
        self.reply = reply
        let view = ApprovalView(request: request, afterCancel: afterCancel) { [weak self] decision in self?.finish(decision) }
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
        if let r = reply { reply = nil; r(.deny) }
    }

    private func finish(_ decision: ApprovalDecision) {
        let r = reply
        reply = nil
        panel?.orderOut(nil)
        panel = nil
        r?(decision)
    }
}

/// What's selected in the panel.
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

struct ApprovalView: View {
    let request: ApprovalRequest
    /// Shown after the Touch ID sheet for a change was cancelled.
    var afterCancel = false
    let decide: (ApprovalDecision) -> Void
    @StateObject private var choice = ApprovalChoice()
    /// Production pushes need this ticked, on top of Touch ID.
    @State private var confirmedProduction = false
    @State private var decided = false

    private func finish(_ decision: ApprovalDecision) {
        guard !decided else { return }
        decided = true
        decide(decision)
    }

    /// "add shop/development/DB", "use 2 items": the action and what it's on, for the title.
    private var what: String {
        let one = request.names.count == 1 ? request.names[0] : nil
        let n = request.names.count
        func items(_ word: String = "item") -> String { one ?? "\(n) \(word)\(n == 1 ? "" : "s")" }
        switch request.action {
        case .read: return "use \(items())"
        case .add: return "add \(items())"
        case .change: return "change \(items())"
        case .delete: return "delete \(items())"
        case .importItems: return "import \(n) item\(n == 1 ? "" : "s")"
        case .grant: return "read \(items()) without asking"
        case .move: return "move \(items())"
        case .readVersion: return "see an earlier value of \(items())"
        case .restore: return "restore \(items())"
        case .link: return "link \(items())"
        case .push: return "push \(items("value"))"
        case .compare: return "compare \(items()) to find duplicates"
        case .scan: return "compare values found in files with \(items())"
        }
    }

    var title: String {
        if let who = request.asker { return "\(who) wants to \(what)" }
        return what.prefix(1).uppercased() + what.dropFirst() + "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(afterCancel ? "Everything about this request. Allow asks for Touch ID again." : "Latchkey")
                        .font(.callout).foregroundStyle(.secondary)
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
                if [.add, .change, .importItems, .restore].contains(request.action), !request.summary.isEmpty {
                    row("Request", request.summary)
                }
                if request.action == .compare {
                    row("Purpose", "Compare their values inside Latchkey to find items holding the same key. Only which items match is shown; no value leaves Latchkey.")
                }
                if request.action == .scan {
                    row("Purpose", "Check whether env files still hold these items' values in plain text. Only which items match is shown; no stored value leaves Latchkey.")
                }
                if request.fromSafari {
                    row("Asked by", "Latchkey's Safari extension")
                    if let page = request.page { row("Page", page + "\n(as Safari reported it)", mono: true) }
                } else {
                    let via = request.chain.prefix(4).joined(separator: " › ")
                    row("Asked by", (request.asker.map { "\($0), via \(via)" } ?? via) + (request.byAgent ? "\nthrough Latchkey's MCP server" : ""))
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
            HStack {
                Text("Touch ID confirms your choice.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Deny", role: .cancel) { finish(.deny) }.keyboardShortcut(.cancelAction)
                Button(allowLabel) { finish(choice.decision) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(request.production && !confirmedProduction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var allowLabel: String {
        switch request.action {
        case .push: return "Push"
        case .compare, .scan: return "Compare"
        case .read where choice.grant: return "Allow from Folder"
        case .read: return "Allow Once"
        default: return "Allow"
        }
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
