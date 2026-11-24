import AppKit
import LatchkeyCore
import LocalAuthentication
import SwiftUI

/// Every approval is one small panel saying what's asked, by whom and where, with Touch ID inside it: touch the sensor
/// to allow, or Use Password… for the system sheet. Questions from the same caller in the same folder that arrive while
/// the panel is up join it as rows, so one touch answers a burst of them; each row can be denied on its own. Questions
/// from anyone else wait their turn. A production push is always asked on its own, and so is anything from a caller
/// whose requests are never grouped (`ApprovalRequest.caller`).
final class PanelApprover: Approver, @unchecked Sendable {
    let system = SystemApprover()
    /// How long a question waits, shown or behind another caller's, before counting as a denial.
    let timeout: TimeInterval = 120

    var method: String { system.method }
    var groupsRequests: Bool { true }

    func approve(_ request: ApprovalRequest) -> ApprovalDecision {
        let ticket = ApprovalTicket(request)
        DispatchQueue.main.async { ApprovalWindow.shared.submit(ticket) }
        if !ticket.wait(timeout) {
            ticket.answer(.deny)
            DispatchQueue.main.sync { ApprovalWindow.shared.withdraw(ticket) }
        }
        return ticket.decision
    }
}

/// One question waiting for its answer. The first answer stands.
final class ApprovalTicket: @unchecked Sendable {
    let request: ApprovalRequest
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var given: ApprovalDecision?

    init(_ request: ApprovalRequest) { self.request = request }

    var decision: ApprovalDecision { lock.withLock { given ?? .deny } }

    func answer(_ decision: ApprovalDecision) {
        let first = lock.withLock { () -> Bool in
            guard given == nil else { return false }
            given = decision
            return true
        }
        if first { done.signal() }
    }

    /// False if no answer came in time.
    func wait(_ timeout: TimeInterval) -> Bool { done.wait(timeout: .now() + timeout) == .success }

    /// Questions with the same key may share a panel: same caller, same folder. Nil for one that's always asked alone.
    var groupKey: String? {
        guard !request.caller.isEmpty, !request.production, request.action != .push else { return nil }
        return [request.caller, request.folder, request.program ?? "", request.fromApp ? "app" : ""].joined(separator: "\n")
    }
}

/// The questions one panel shows.
@MainActor
final class ApprovalGroup: ObservableObject {
    let key: String?
    @Published private(set) var tickets: [ApprovalTicket]
    /// Counts questions joining, so Touch ID starts over and a touch can't allow one that just appeared.
    @Published private(set) var joined = 0

    init(_ first: ApprovalTicket) {
        key = first.groupKey
        tickets = [first]
    }

    var first: ApprovalRequest { tickets[0].request }

    func add(_ ticket: ApprovalTicket) {
        tickets.append(ticket)
        joined += 1
    }

    func remove(_ ticket: ApprovalTicket) { tickets.removeAll { $0 === ticket } }
}

@MainActor
final class ApprovalWindow {
    static let shared = ApprovalWindow()
    /// Rows one panel holds; more from the same caller wait for the next panel.
    static let most = 12
    private var panel: NSPanel?
    private var group: ApprovalGroup?
    private var waiting: [ApprovalTicket] = []

    func submit(_ ticket: ApprovalTicket) {
        if let group, let key = ticket.groupKey, group.key == key, group.tickets.count < Self.most {
            group.add(ticket)
        } else if group == nil {
            show(ticket)
        } else {
            waiting.append(ticket)
        }
    }

    /// A question that stopped waiting (it timed out): off the panel, or out of the queue.
    func withdraw(_ ticket: ApprovalTicket) {
        waiting.removeAll { $0 === ticket }
        guard let group, group.tickets.contains(where: { $0 === ticket }) else { return }
        group.remove(ticket)
        if group.tickets.isEmpty { close() }
    }

    private func show(_ first: ApprovalTicket) {
        let group = ApprovalGroup(first)
        if let key = group.key {
            for t in waiting where t.groupKey == key && group.tickets.count < Self.most { group.add(t) }
            waiting.removeAll { t in group.tickets.contains { $0 === t } }
        }
        self.group = group
        let view = ApprovalView(group: group,
                                deny: { [weak self] ticket in self?.deny(ticket) },
                                decide: { [weak self] decision in self?.finish(decision) })
        // The default sizing (the window follows the view's size through constraints). `.preferredContentSize` fed the
        // window's size back into the view and looped until AppKit raised, when a production push's panel changed size.
        let host = NSHostingController(rootView: view)
        let panel = NSPanel(contentViewController: host)
        // A panel that takes the keyboard without activating Latchkey: Touch ID inside it only listens while it's the
        // key window, and macOS won't let a background app activate itself over the app you're in. Not activating also
        // leaves Latchkey's main window where it was.
        panel.styleMask = [.titled, .fullSizeContentView, .nonactivatingPanel]
        panel.becomesKeyOnlyIfNeeded = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.center()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    /// One row denied; the panel stays for the rest.
    private func deny(_ ticket: ApprovalTicket) {
        ticket.answer(.deny)
        group?.remove(ticket)
        if group?.tickets.isEmpty == true { close() }
    }

    /// The panel's answer for every row. A grant applies to the releases that offered one; everything else is allowed
    /// once.
    private func finish(_ decision: ApprovalDecision) {
        for t in group?.tickets ?? [] {
            t.answer(decision.allowed && !t.request.canGrant ? .once : decision)
        }
        close()
    }

    private func close() {
        for t in group?.tickets ?? [] { t.answer(.deny) }
        group = nil
        panel?.orderOut(nil)
        panel = nil
        if !waiting.isEmpty { show(waiting.removeFirst()) }
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
        // Until the agent quits has no time limit of its own: the grant ends with the agent's session.
        return .grant(GrantChoice(duration: untilQuit ? GrantStore.untilRevoked : grantFor, untilAgentQuits: untilQuit,
                                  thisCommandOnly: thisCommandOnly))
    }
}

struct ApprovalView: View {
    @ObservedObject var group: ApprovalGroup
    /// Denies one row; the rest stay.
    var deny: (ApprovalTicket) -> Void = { _ in }
    let decide: (ApprovalDecision) -> Void
    @StateObject private var choice = ApprovalChoice()
    /// Production pushes need this ticked, on top of Touch ID.
    @State private var confirmedProduction = false
    @State private var decided = false
    /// The Touch ID request shown in the panel; nil when this Mac has no Touch ID, or after it gave up.
    @State private var touchID: LAContext?
    /// The system sheet is up (Use Password…, or Allow… without Touch ID).
    @State private var sheetUp = false
    /// Who's asking in full (the process chain, the folder, the command), folded until asked for.
    @State private var showDetails = false

    /// The caller and folder every row shares.
    private var request: ApprovalRequest { group.first }
    private var many: Bool { group.tickets.count > 1 }

    private func finish(_ decision: ApprovalDecision) {
        guard !decided else { return }
        decided = true
        touchID?.invalidate()
        decide(decision)
    }

    /// "add shop/development/DB", "use 2 items": the action and what it's on.
    static func what(_ request: ApprovalRequest) -> String {
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
        let who = request.asker
        if many { return "\(who ?? "A program") is asking for \(group.tickets.count) things" }
        let what = Self.what(request)
        if let who { return "\(who) wants to \(what)" }
        return what.prefix(1).uppercased() + what.dropFirst() + "?"
    }

    /// What the system sheet says, for Use Password….
    private var sheetReason: String {
        guard many else { return request.touchIDReason }
        let place = request.folder.isEmpty || request.folder == "/" ? "" : " in \(Broker.tilde(request.folder))"
        return "allow \(group.tickets.count) requests from \(request.asker ?? "one program")\(place)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                BrandAppIcon(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            if request.overSSH {
                VStack(alignment: .leading, spacing: 4) {
                    Label("From another computer, through your SSH connection", systemImage: "network")
                        .foregroundStyle(.orange).font(.callout.weight(.semibold))
                    if let r = request.remote {
                        Text("It says it's \(r.host), running \(r.command) in \(r.cwd). Pistachio can't check that.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Pistachio can't see what's asking on the other computer.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let program = request.program {
                Label("Asked by a program that isn't Pistachio's command-line tool: \(program)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if many { rows }
            // What the answer covers stays in view: every item (one is named in the title), the change's own words,
            // and where values go. Who's asking in detail is folded below.
            if !many {
                if request.names.count > 1 { covered(request.names.joined(separator: ", "), mono: true) }
                if [.add, .change, .importItems, .restore].contains(request.action), !request.summary.isEmpty, request.summary != Self.what(request) {
                    covered(request.summary.prefix(1).uppercased() + request.summary.dropFirst())
                }
                if !request.targets.isEmpty { covered((request.action == .push ? "To " : "Target: ") + request.targets.joined(separator: ", ")) }
            }
            DisclosureGroup(isExpanded: $showDetails) {
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
                    if request.fromBrowser {
                        row("Asked by", "Pistachio for " + (request.browserName ?? "Safari"))
                        if let page = request.page { row("Page", page + "\n(as " + (request.browserName ?? "Safari") + " reported it)", mono: true) }
                    } else {
                        let via = request.chain.prefix(4).joined(separator: " › ")
                        row("Asked by", (request.asker.map { "\($0), via \(via)" } ?? via) + (request.byAgent ? "\nthrough Pistachio's MCP server" : ""))
                    }
                    if !request.folder.isEmpty { row("Folder", Broker.tilde(request.folder), mono: true) }
                    if !many {
                        // The command that will receive the values, in full: a signed `latchkey run` shows what it
                        // starts, unredacted (the log keeps the redacted form), so a filter or truncation can't hide it.
                        if let command = Self.command(request) { row("Command", command, mono: true, full: true) }
                        if let d = request.duration { row("For", GrantStore.describe(d)) }
                        if request.action == .compare {
                            row("Purpose", "Compare their values inside Pistachio to find items holding the same key. Only which items match is shown; no value leaves Pistachio.")
                        }
                        if request.action == .scan {
                            row("Purpose", "Check whether env files still hold these items' values in plain text. Only which items match is shown; no stored value leaves Pistachio.")
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Details").font(.callout)
            }
            // Not the panel's first focus: the ring drew around Details as if it were the thing to press.
            .focusEffectDisabled()
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
            if group.tickets.contains(where: { $0.request.canGrant }) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle(many ? "Allow these from this folder" : "Allow from this folder", isOn: $choice.grant).toggleStyle(.checkbox)
                        Picker("", selection: $choice.grantFor) {
                            if let agent = request.sessionName { Text("until \(agent) quits").tag(ApprovalChoice.untilQuit) }
                            Text("for 1 hour").tag(3600.0)
                            Text("for 8 hours").tag(8 * 3600.0)
                            Text("for 1 day").tag(86400.0)
                            Text("for 7 days").tag(7 * 86400.0)
                            Text("until revoked").tag(GrantStore.untilRevoked)
                        }
                        .labelsHidden().fixedSize().disabled(!choice.grant)
                    }
                    if !many, let command = request.runCommand {
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
            footer
        }
        .padding(18)
        .frame(width: 420)
        // No keyboard focus rings: with keyboard navigation on, one landed on Details or Use Password… as if that were
        // the thing to press. Tab still moves between controls.
        .focusEffectDisabled()
        .onAppear { startTouchID() }
        // A question that just joined starts Touch ID over, after a moment to read it.
        .onChange(of: group.joined) { _, _ in
            touchID?.invalidate()
            touchID = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { startTouchID() }
        }
    }

    /// Each question from the caller, with what it covers in full and its own Deny.
    private var rows: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(group.tickets.enumerated()), id: \.offset) { i, ticket in
                    if i > 0 { Divider() }
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            let what = Self.what(ticket.request)
                            Text(what.prefix(1).uppercased() + what.dropFirst())
                                .font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                            // One item is named in full above; more are listed here, every one of them.
                            if ticket.request.names.count > 1 {
                                Text(ticket.request.names.joined(separator: ", ")).font(.caption.monospaced())
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                            if !ticket.request.targets.isEmpty {
                                Text("To " + ticket.request.targets.joined(separator: ", ")).font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if showDetails, let command = Self.command(ticket.request) {
                                Text(command).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                        Button { deny(ticket) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Deny this one")
                    }
                    .padding(.vertical, 7)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if let touchID {
                // The system's glyph, which shows the print being read, in the same space as the grey stand-in shown
                // until production is ticked.
                VStack(spacing: 6) {
                    Group {
                        if ready {
                            InlineTouchID(context: touchID, start: { evaluate(touchID) }, needsKeyWindow: false)
                                .id(ObjectIdentifier(touchID))
                        } else {
                            // Matched to the system glyph's size and thin stroke, so ticking the box only changes its colour.
                            Image(systemName: "touchid").resizable().scaledToFit().fontWeight(.thin).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: InlineTouchID.side, height: InlineTouchID.side)
                    Text(ready ? "Touch ID to \(allowLabel.lowercased())" : "Tick the box above, then Touch ID to \(allowLabel.lowercased())")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            HStack {
                Spacer()
                Button("Deny", role: .cancel) { finish(.deny) }.keyboardShortcut(.cancelAction)
                if touchID == nil {
                    Button(allowLabel + "…") { useSheet() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!ready || sheetUp)
                } else {
                    Button("Use Password…") { useSheet() }.disabled(!ready || sheetUp)
                }
            }
        }
    }

    /// Who and where, in a line: "Claude in ~/Projects/site".
    private var subtitle: String {
        if request.fromBrowser { return "Pistachio for " + (request.browserName ?? "Safari") + (request.page.map { " on \($0)" } ?? "") }
        if request.overSSH { return "From another computer" }
        let place = request.folder.isEmpty || request.folder == "/" ? "" : " in " + Broker.tilde(request.folder)
        return (request.asker ?? (request.fromApp ? "Pistachio" : "A program")) + place
    }

    /// A line of what the answer covers, in full.
    private func covered(_ text: String, mono: Bool = false) -> some View {
        Text(text).font(mono ? .callout.monospaced() : .callout).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Production waits for its box to be ticked before anything can allow it.
    private var ready: Bool { !request.production || confirmedProduction }

    private func startTouchID() {
        guard !decided, !sheetUp, touchID == nil else { return }
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return }
        touchID = context
    }

    private func evaluate(_ context: LAContext) {
        touchIDLog.notice("approval: Touch ID started; app active \(NSApp.isActive, privacy: .public)")
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: sheetReason) { passed, error in
            touchIDLog.notice("approval: Touch ID ended; passed \(passed, privacy: .public), error \((error as? LAError)?.code.rawValue ?? 0, privacy: .public)")
            DispatchQueue.main.async {
                guard touchID === context else { return }   // started over, or the sheet took over
                if passed { finish(choice.decision) } else { touchID = nil }
            }
        }
    }

    /// The system sheet: the Mac password, an Apple Watch, or Touch ID on a Mac where it can't be shown here.
    private func useSheet() {
        touchID?.invalidate()
        touchID = nil
        sheetUp = true
        let reason = sheetReason
        DispatchQueue.global().async {
            let passed = SystemApprover().confirm(reason)
            DispatchQueue.main.async {
                sheetUp = false
                if passed { finish(choice.decision) }
            }
        }
    }

    /// The command that receives what's allowed, in full.
    static func command(_ request: ApprovalRequest) -> String? {
        if let run = request.runCommand { return "latchkey run -- " + run.joined(separator: " ") }
        if let c = request.command, !c.isEmpty { return c }
        return nil
    }

    private var allowLabel: String {
        if group.tickets.contains(where: { $0.request.action != request.action }) { return "Allow" }
        switch request.action {
        case .push: return "Push"
        case .compare, .scan: return "Compare"
        case .read where choice.grant: return "Allow from Folder"
        case .read: return "Allow Once"
        default: return "Allow"
        }
    }

    /// `full` rows hold what the decision covers (every item, the whole command): never truncated, scrolling when long.
    @ViewBuilder
    private func row(_ label: String, _ value: String, mono: Bool = false, full: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            if full {
                ScrollView(.vertical) {
                    Text(value).font(mono ? .callout.monospaced() : .callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(value).font(mono ? .callout.monospaced() : .callout).textSelection(.enabled)
                    .lineLimit(3).truncationMode(.middle)
            }
        }
    }
}
