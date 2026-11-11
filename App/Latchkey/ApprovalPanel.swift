import AppKit
import LatchkeyCore
import SwiftUI

/// Shows who is asking, from where and for what, then confirms the choice with Touch ID.
/// Requests made in the Latchkey window skip the panel: the person is already looking at what they clicked.
final class PanelApprover: Approver, @unchecked Sendable {
    let system = SystemApprover()
    /// How long the panel waits before counting as a denial.
    let timeout: TimeInterval = 90

    var method: String { system.method }

    func approve(_ request: ApprovalRequest) -> ApprovalDecision {
        if request.fromApp { return system.approve(request) }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var choice = ApprovalDecision.deny
        DispatchQueue.main.async {
            ApprovalWindow.shared.show(request) { decision in
                choice = decision
                done.signal()
            }
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            DispatchQueue.main.sync { ApprovalWindow.shared.dismiss() }
            return .deny
        }
        guard choice.allowed else { return .deny }
        return system.confirm(request.reason) ? choice : .deny
    }
}

@MainActor
final class ApprovalWindow {
    static let shared = ApprovalWindow()
    private var panel: NSPanel?
    private var reply: ((ApprovalDecision) -> Void)?

    func show(_ request: ApprovalRequest, reply: @escaping (ApprovalDecision) -> Void) {
        dismiss()
        self.reply = reply
        let view = ApprovalView(request: request) { [weak self] decision in self?.finish(decision) }
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

struct ApprovalView: View {
    let request: ApprovalRequest
    let decide: (ApprovalDecision) -> Void
    @State private var grantFor: TimeInterval = 3600

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
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
                row("Items", request.names.joined(separator: ", "), mono: true)
                row("Asked by", request.chain.prefix(4).joined(separator: " › "))
                if !request.folder.isEmpty { row("Folder", Broker.tilde(request.folder), mono: true) }
                if let c = request.command, !c.isEmpty { row("Command", c, mono: true) }
                if let d = request.duration { row("For", GrantStore.describe(d)) }
            }
            if request.canGrant {
                HStack {
                    Text("Allow from this folder for")
                    Picker("", selection: $grantFor) {
                        Text("1 hour").tag(3600.0)
                        Text("8 hours").tag(8 * 3600.0)
                        Text("1 day").tag(86400.0)
                        Text("7 days").tag(7 * 86400.0)
                    }
                    .labelsHidden().fixedSize()
                    Button("Allow") { decide(.grant(grantFor)) }
                }
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            }
            HStack {
                Text("Touch ID confirms your choice.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Deny", role: .cancel) { decide(.deny) }.keyboardShortcut(.cancelAction)
                Button(request.action == .read ? "Allow Once" : "Allow") { decide(.once) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
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
