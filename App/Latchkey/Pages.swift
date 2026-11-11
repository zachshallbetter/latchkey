import AppKit
import LatchkeyCore
import SwiftUI

// Review, Activity, Recently Deleted and Grants: each a list in the middle column with the selected entry's detail on the
// right, like the item list and item detail.

extension Broker.LogEntry {
    /// Stable enough to select an entry by: the log has no ids of its own.
    var key: String { "\(time.timeIntervalSince1970)|\(op)|\(names.joined(separator: ","))" }

    /// What happened, as a short heading: "Deleted PROMPT_CHECK", "Imported 3 items".
    var title: String {
        let subject = names.count == 1 ? (ItemID(names[0])?.name ?? names[0]) : names.isEmpty ? "" : "\(names.count) items"
        return [verb, subject].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var verb: String {
        switch op {
        case "get": return "Read"
        case "set": return "Saved"
        case "rm": return "Deleted"
        case "import": return "Imported"
        case "update": return "Updated"
        case "move": return "Moved"
        case "grant": return "Granted access to"
        case "revoke": return "Revoked access to"
        case "restore": return "Restored"
        case "forget": return "Forgot the history of"
        case "version": return "Showed an earlier value of"
        case "fill": return "Filled"
        case "export": return "Exported"
        case "push": return "Pushed"
        case "link": return "Linked"
        case "unlink": return "Unlinked"
        case "environment-add", "environment-set", "environment-remove": return "Updated the record of"
        case "project-link", "project-unlink": return "Changed the remotes of"
        case "verify-log": return "Checked the log"
        default: return op.prefix(1).uppercased() + op.dropFirst()
        }
    }

    var symbol: String {
        if denied { return "xmark.circle.fill" }
        switch op {
        case "get", "version", "export", "fill": return "eye"
        case "set": return "square.and.pencil"
        case "rm", "forget": return "trash"
        case "import": return "square.and.arrow.down"
        case "update": return "slider.horizontal.3"
        case "move": return "arrow.right.square"
        case "grant": return "checkmark.shield"
        case "revoke": return "nosign"
        case "restore": return "arrow.uturn.backward"
        case "push", "link", "unlink": return "icloud"
        default: return "circle"
        }
    }

    var tint: Color {
        if denied { return .red }
        switch op {
        case "rm", "forget", "revoke": return .red
        case "grant": return .green
        case "import", "restore": return .teal
        case "set", "update", "move": return .blue
        default: return .secondary
        }
    }

    var denied: Bool { decision.hasPrefix("denied") || decision.hasPrefix("refused") }

    /// The program asking, in a word: the nearest one in its chain that isn't a shell.
    var actor: String {
        if let p = program { return p }
        let shells: Set<String> = ["zsh", "bash", "sh", "fish", "login", "sudo", "env", "tmux", "screen", "sshd-session", "latchkey", "lk"]
        let name = chain.first { !shells.contains($0.lowercased()) } ?? chain.first ?? ""
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// The project and environment of a single item or environment, when it has them.
    var place: (project: String, environment: String)? {
        guard names.count == 1 else { return nil }
        let parts = names[0].split(separator: "/").map(String.init)
        return parts.count >= 2 ? (parts[0], parts[1]) : nil
    }
}

/// A project chip and environment badge, or "Shared".
struct PlaceChips: View {
    let project: String?
    let environment: String?
    var body: some View {
        HStack(spacing: 6) {
            if let project, let environment {
                Chip(text: project).font(.caption)
                EnvBadge(environment: environment, compact: true).fixedSize()
            } else {
                Chip(text: "Shared").font(.caption)
            }
        }
    }
}

/// A search field in a page header.
struct PageSearch: View {
    @Binding var text: String
    let prompt: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.8)))
    }
}

/// A dropdown that names its choice, for page filter rows.
struct ChoicePill<Items: View>: View {
    let title: String
    let choice: String?
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu { items() } label: {
            HStack(spacing: 4) {
                Text(choice ?? title).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.callout)
            .foregroundStyle(choice == nil ? Color.primary : Color.accentColor)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(choice == nil ? AnyShapeStyle(.quaternary.opacity(0.3)) : AnyShapeStyle(Color.accentColor.opacity(0.15))))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator.opacity(0.8)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusEffectDisabled()
    }
}

/// The top of a detail pane: a tile, a title, a subtitle and chips.
struct DetailHeader<Chips: View, Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let chips: () -> Chips
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: symbol, tint: tint, size: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
                HStack(spacing: 6) { chips() }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

// MARK: - Review

/// Something Review asks you to look at.
struct Finding: Identifiable {
    enum Area: String, CaseIterable {
        case access = "Access", duplicates = "Duplicates", changes = "Changes", environment = "Environment", grants = "Grants"
    }
    let id: String
    let area: Area
    let symbol: String
    let tint: Color
    let title: String
    let summary: String
    let why: String
    var items: [SecretInfo] = []
    var variables: [(scope: String, name: String)] = []
    var grants: [Grant] = []
    var advice: Duplicates.Advice?
}

extension AppModel {
    /// What Review shows, most pressing first.
    var findings: [Finding] {
        var out: [Finding] = []
        func places(_ items: [SecretInfo]) -> String {
            let projects = Array(Set(items.map { $0.ref.isShared ? "Shared" : $0.ref.project })).sorted()
            return projects.prefix(3).joined(separator: ", ") + (projects.count > 3 ? ", …" : "")
        }
        func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        let open = items.filter(\.agentSafe)
        if !open.isEmpty {
            out.append(Finding(id: "access", area: .access, symbol: "lock.open", tint: .blue,
                               title: "Credentials available without approval",
                               summary: "\(count(open.count, "item")) · \(places(open))",
                               why: "Any program in your Mac account, agents included, can read these without asking. That's fine for values that aren't really secret, and a risk for anything that is.",
                               items: open))
        }
        let byName = Dictionary(items.map { ($0.name, $0) }) { a, _ in a }
        for group in duplicateGroups ?? [] {
            let members = group.compactMap { byName[$0] }
            guard members.count > 1 else { continue }
            let advice = Duplicates.advice(for: members.map(\.name))
            let production = advice == .separateProduction
            out.append(Finding(id: "dup-\(group[0])", area: .duplicates, symbol: production ? "exclamationmark.triangle" : "doc.on.doc",
                               tint: production ? .red : .teal,
                               title: production ? "Production key used elsewhere" : "Same key in \(count(members.count, "place"))",
                               summary: "\(members.first.map { $0.ref.name } ?? "") · \(places(members))",
                               why: advice.summary, items: members, advice: advice))
        }
        let stale = items.filter { remoteStates[$0.name] == .outOfDate }
        if !stale.isEmpty {
            out.append(Finding(id: "stale", area: .changes, symbol: "arrow.triangle.2.circlepath", tint: .orange,
                               title: "Changed since last push",
                               summary: "\(count(stale.count, "item")) · \(places(stale))",
                               why: "These values changed in Latchkey after they were last pushed, so the linked services still have the old ones.",
                               items: stale))
        }
        let unpushed = items.filter { remoteStates[$0.name] == .notPushed }
        if !unpushed.isEmpty {
            out.append(Finding(id: "unpushed", area: .changes, symbol: "icloud.slash", tint: .blue,
                               title: "Not pushed yet",
                               summary: "\(count(unpushed.count, "item")) · \(places(unpushed))",
                               why: "Their environment is linked to a service that doesn't have them yet.",
                               items: unpushed))
        }
        let unconfirmed = records.flatMap { r in r.inferred.map { (scope: r.scope, name: $0) } }
        if !unconfirmed.isEmpty {
            let scopes = Array(Set(unconfirmed.map(\.scope))).sorted()
            out.append(Finding(id: "unconfirmed", area: .environment, symbol: "questionmark.circle", tint: .purple,
                               title: "Unconfirmed environment variables",
                               summary: "\(count(unconfirmed.count, "variable")) · \(scopes.prefix(2).joined(separator: ", "))",
                               why: "lk env migrate found these through the files items were imported from. They're used, but nobody has confirmed they belong in the environment.",
                               variables: unconfirmed))
        }
        let soon = grants.filter { $0.expires.timeIntervalSinceNow < 86400 }
        if !soon.isEmpty {
            out.append(Finding(id: "grants", area: .grants, symbol: "calendar.badge.clock", tint: .red,
                               title: "Grants ending soon",
                               summary: "\(count(soon.count, "grant")) · within a day",
                               why: "When a grant ends, commands that relied on it start asking for approval again.",
                               grants: soon))
        }
        return out
    }
}

struct ReviewList: View {
    @Bindable var model: AppModel
    @State private var area: Finding.Area?
    @State private var finding = false

    var body: some View {
        let all = model.findings
        let shown = all.filter { area == nil || $0.area == area }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                PageHeader(title: "Review", subtitle: all.isEmpty ? "Nothing needs your attention" : "\(all.count) thing\(all.count == 1 ? "" : "s") need\(all.count == 1 ? "s" : "") your attention")
                Spacer()
                Button { finding = true; Task { await model.findDuplicates(); finding = false } } label: {
                    Label("Find Duplicates…", systemImage: "doc.on.doc")
                }
                .disabled(finding)
                .help("Compare values inside Latchkey to find items holding the same key. Asks for Touch ID; no value is shown.")
            }
            Picker("", selection: $area) {
                Text("All").tag(Finding.Area?.none)
                ForEach(Finding.Area.allCases, id: \.self) { Text($0.rawValue).tag(Finding.Area?.some($0)) }
            }
            .pickerStyle(.segmented).labelsHidden()
            List(selection: $model.selectedFinding) {
                ForEach(shown) { f in
                    HStack(spacing: 12) {
                        IconTile(symbol: f.symbol, tint: f.tint, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.title).font(.body.weight(.semibold)).lineLimit(1)
                            Text(f.summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.callout.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                    .tag(f.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView("Nothing to Review", systemImage: "checkmark.shield",
                                           description: Text(all.isEmpty ? "Every pushed value is current, and nothing is waiting on you." : "Nothing in \(area?.rawValue ?? "this") needs a look."))
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 12)
        .navigationTitle("Review")
        .toolbar(removing: .title)
        .onAppear { if model.selectedFinding == nil { model.selectedFinding = all.first?.id } }
    }
}

struct FindingDetail: View {
    let model: AppModel
    let finding: Finding
    @State private var working = false
    @State private var combining = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DetailHeader(symbol: finding.symbol, tint: finding.tint, title: finding.title, subtitle: finding.summary) { EmptyView() } trailing: { EmptyView() }
                Text(finding.why).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
                if !finding.items.isEmpty {
                    Text("Items (\(finding.items.count))").font(.headline)
                    Card(padding: 0) {
                        ForEach(Array(finding.items.enumerated()), id: \.element.id) { i, item in
                            Button { model.filter = .all; model.selection = [item.name] } label: {
                                HStack {
                                    ItemRow(item: item)
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if i < finding.items.count - 1 { Divider() }
                        }
                    }
                }
                if !finding.variables.isEmpty {
                    Text("Variables (\(finding.variables.count))").font(.headline)
                    Card {
                        ForEach(Array(finding.variables.enumerated()), id: \.offset) { i, v in
                            CardRow(label: v.name, last: i == finding.variables.count - 1) { Text(v.scope).foregroundStyle(.secondary) }
                        }
                    }
                }
                if !finding.grants.isEmpty {
                    Text("Grants (\(finding.grants.count))").font(.headline)
                    Card {
                        ForEach(Array(finding.grants.enumerated()), id: \.element.id) { i, g in
                            CardRow(label: Broker.tilde(g.folder), last: i == finding.grants.count - 1) {
                                Text("ends \(g.expires.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Divider().padding(.vertical, 4)
                actions
            }
            .padding(16)
        }
        .disabled(working)
        .sheet(isPresented: $combining) { CombineSheet(model: model, items: finding.items, suggested: finding.advice?.into ?? "") }
    }

    @ViewBuilder
    private var actions: some View {
        switch finding.id {
        case _ where finding.advice == .separateProduction:
            let production = finding.items.filter { !$0.ref.isShared && Environments.isProduction($0.ref.environment) }
            recommended("Make a new key at the service for production and save it there, so a leak elsewhere can't reach it. Combining isn't offered.") {
                Button { model.filter = .all; model.selection = Set(production.map(\.name)) } label: {
                    Label("Show Production Item", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.borderedProminent)
            }
        case _ where finding.advice != nil:
            recommended("Combine them into one shared item. Environments and the files they were imported from will point at it, and the originals go to Recently Deleted.") {
                Button { combining = true } label: { Label("Combine into Shared…", systemImage: "arrow.triangle.merge") }
                    .buttonStyle(.borderedProminent)
            }
        case "access":
            recommended("Require approval for these items, so agents need your permission to read their values.") {
                Button { act { await model.updateItems(finding.items.map(\.name), agentSafe: false) } } label: {
                    Label("Require Approval…", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                Button("View Items") { model.filter = .agentSafe }
            }
        case "stale", "unpushed":
            let scope = finding.items.first.map { "\($0.ref.project)/\($0.ref.environment)" } ?? ""
            recommended("Push the environment again so its linked services have the current values.") {
                Button { model.remoteRequest = RemoteRequest(scope: scope) } label: { Label("Push…", systemImage: "icloud.and.arrow.up") }
                    .buttonStyle(.borderedProminent).disabled(scope.isEmpty)
            }
        case "unconfirmed":
            recommended("Confirm them if they belong; remove any that don't with lk env unset.") {
                Button { act { await model.confirmVariables(finding.variables) } } label: { Label("Confirm All…", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent)
            }
        case "grants":
            recommended("Let them end, or make a new grant before you step away from an agent.") {
                Button("View Grants") { model.filter = .grants }.buttonStyle(.borderedProminent)
            }
        default:
            EmptyView()
        }
    }

    private func recommended<Buttons: View>(_ text: String, @ViewBuilder _ buttons: () -> Buttons) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recommended action").font(.headline)
            Label(text, systemImage: "shield").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { buttons() }.controlSize(.large)
        }
    }

    private func act(_ work: @escaping @MainActor () async -> Void) {
        working = true
        Task { await work(); working = false }
    }
}

/// Names the shared item a group of duplicates becomes.
struct CombineSheet: View {
    let model: AppModel
    let items: [SecretInfo]
    @State var suggested: String
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var problem: String? {
        guard let id = ItemID(suggested), Wire.isValidName(suggested), id.isShared else { return "A shared item name: letters, digits, _ - . and no slashes." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(symbol: "arrow.triangle.merge", tint: .teal, title: "Combine into Shared", subtitle: "\(items.count) items hold the same value")
            Card {
                FieldRow(label: "Shared item") { TextField("Name", text: $suggested, prompt: Text("OPENAI_API_KEY")) }
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    CardRow(label: i == 0 ? "Replaces" : "", last: i == items.count - 1) { Text(item.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
            }
            Text("Agents can read it without approval only if they could read every one of these. References in environments and in the files these were imported from point at the new name.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = error ?? (suggested.isEmpty ? nil : problem) { Text(error).font(.callout).foregroundStyle(.red) }
            SheetFooter(note: "Combining asks for Touch ID once.", noteSymbol: "touchid") {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Combine") {
                    saving = true
                    Task {
                        error = await model.combine(items.map(\.name), into: suggested)
                        saving = false
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(saving || problem != nil)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}

// MARK: - Activity

struct ActivityList: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var action: String?
    @State private var project: String?

    private static let actions: [(String, [String])] = [
        ("Reads", ["get", "version", "fill", "export"]), ("Changes", ["set", "update", "import", "move", "restore"]),
        ("Deletions", ["rm", "forget"]), ("Grants", ["grant", "revoke"]), ("Remote", ["push", "link", "unlink"]),
    ]

    var body: some View {
        let q = search.lowercased()
        let entries = model.visibleLog.filter { e in
            (q.isEmpty || e.title.lowercased().contains(q) || e.names.joined().lowercased().contains(q) || e.actor.lowercased().contains(q))
                && (action.map { a in Self.actions.first { $0.0 == a }?.1.contains(e.op) ?? true } ?? true)
                && (project.map { p in e.place?.project == p } ?? true)
        }
        let days = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.time) }
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Activity", subtitle: "Recent reads and changes across your items · values are never logged")
            PageSearch(text: $search, prompt: "Search activity…")
            HStack(spacing: 6) {
                ChoicePill(title: "All Events", choice: action) {
                    Button("All Events") { action = nil }
                    Divider()
                    ForEach(Self.actions, id: \.0) { a in Button(a.0) { action = a.0 } }
                }
                ChoicePill(title: "All Projects", choice: project) {
                    Button("All Projects") { project = nil }
                    Divider()
                    ForEach(model.projects, id: \.self) { p in Button(p) { project = p } }
                }
                Spacer()
            }
            List(selection: $model.selectedLog) {
                ForEach(days.keys.sorted(by: >), id: \.self) { day in
                    Section {
                        ForEach(days[day]!, id: \.key) { e in ActivityRow(entry: e).tag(e.key) }
                    } header: {
                        Text(Calendar.current.isDateInToday(day) ? "Today" : Calendar.current.isDateInYesterday(day) ? "Yesterday"
                             : day.formatted(date: .abbreviated, time: .omitted))
                            .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("No Activity", systemImage: "clock",
                                           description: Text(model.log.isEmpty ? "Every read and change shows up here, never the values." : "Nothing matches."))
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 12)
        .navigationTitle("Activity")
        .toolbar(removing: .title)
    }
}

/// One access-log entry: what happened to what, where, who asked and when.
struct ActivityRow: View {
    let entry: Broker.LogEntry
    var showNames = true

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: entry.symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(entry.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(showNames ? entry.title : entry.verb).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if showNames, entry.names.count == 1 {
                    PlaceChips(project: entry.place?.project, environment: entry.place?.environment)
                } else if !showNames {
                    Text(entry.denied ? "Denied" : entry.decision.prefix(1).uppercased() + entry.decision.dropFirst())
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Label(entry.actor, systemImage: "person").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(entry.time.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize()
        }
        .padding(.vertical, 4)
        .help(entry.names.joined(separator: ", "))
    }
}

struct ActivityDetail: View {
    let entry: Broker.LogEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DetailHeader(symbol: entry.symbol == "circle" ? "waveform.path.ecg" : entry.symbol.replacingOccurrences(of: ".fill", with: ""),
                             tint: entry.tint == .secondary ? .gray : entry.tint, title: entry.title) {
                    if entry.names.count == 1 { PlaceChips(project: entry.place?.project, environment: entry.place?.environment) }
                } trailing: { EmptyView() }
                Card {
                    CardRow(label: "Action") { Text(entry.verb).foregroundStyle(.secondary) }
                    CardRow(label: entry.names.count == 1 ? "Item" : "Items") {
                        Text(entry.names.joined(separator: "\n")).font(.callout.monospaced()).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing).textSelection(.enabled)
                    }
                    CardRow(label: "Decision") { Text(entry.decision).foregroundStyle(entry.denied ? .red : .secondary).multilineTextAlignment(.trailing) }
                    CardRow(label: "Actor") { Label(entry.actor, systemImage: "person").foregroundStyle(.secondary) }
                    CardRow(label: "When", last: entry.chain.isEmpty && entry.cwd.isEmpty && entry.command == nil) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(entry.time.formatted(date: .abbreviated, time: .shortened))
                            Text(entry.time.formatted(.relative(presentation: .named))).font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                if !entry.chain.isEmpty || !entry.cwd.isEmpty || entry.command != nil {
                    Text("Details").font(.headline)
                    Card {
                        if !entry.chain.isEmpty {
                            CardRow(label: "Asked by", last: entry.cwd.isEmpty && entry.command == nil) {
                                Text(entry.chain.joined(separator: " › ")).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                            }
                        }
                        if !entry.cwd.isEmpty {
                            CardRow(label: "Folder", last: entry.command == nil) {
                                Text(Broker.tilde(entry.cwd)).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        if let c = entry.command {
                            CardRow(label: "Command", last: true) {
                                Text(c).font(.callout.monospaced()).textSelection(.enabled).lineLimit(3).multilineTextAlignment(.trailing)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(0.6)))
                            }
                        }
                    }
                }
                Text("The access log records what was asked and decided, never values.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }
}

// MARK: - Recently Deleted

struct DeletedList: View {
    @Bindable var model: AppModel
    @State private var search = ""

    var body: some View {
        let q = search.lowercased()
        let shown = model.deleted.filter { q.isEmpty || $0.item.lowercased().contains(q) }
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Recently Deleted",
                       subtitle: "\(model.deleted.count) item\(model.deleted.count == 1 ? "" : "s") · kept for \(Int(Versions.deletedFor / 86400)) days")
            PageSearch(text: $search, prompt: "Search deleted items…")
            List(selection: $model.selectedVersion) {
                ForEach(shown) { v in
                    let info = v.info
                    HStack(spacing: 12) {
                        Image(systemName: ItemType(info).symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(ItemType(info).tint).frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(info.ref.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            PlaceChips(project: info.ref.isShared ? nil : info.ref.project, environment: info.ref.isShared ? nil : info.ref.environment)
                        }
                        Spacer(minLength: 6)
                        Text("Deleted \(v.savedAt.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary).fixedSize()
                        Button("Restore") { Task { await model.restore(v) } }.buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                    .tag(v.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView("Nothing Deleted", systemImage: "trash",
                                           description: Text("Items you delete stay here for \(Int(Versions.deletedFor / 86400)) days."))
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 12)
        .navigationTitle("Recently Deleted")
        .toolbar(removing: .title)
    }
}

extension Version {
    /// The deleted item as the list shows items.
    var info: SecretInfo { SecretInfo(name: item, kind: kind, agentSafe: agentSafe, note: note, updatedAt: savedAt, usedIn: usedIn, service: service) }
}

struct DeletedDetail: View {
    let model: AppModel
    let version: Version
    @State private var confirmingForget = false

    var body: some View {
        let info = version.info
        let left = max(0, Int((Versions.deletedFor - Date().timeIntervalSince(version.savedAt)) / 86400))
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DetailHeader(symbol: ItemType(info).symbol, tint: ItemType(info).tint, title: info.ref.name) {
                    PlaceChips(project: info.ref.isShared ? nil : info.ref.project, environment: info.ref.isShared ? nil : info.ref.environment)
                    Chip(text: ItemType(info).label).font(.caption)
                } trailing: { EmptyView() }
                Card {
                    CardRow(label: "Deleted") { Text(version.savedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
                    CardRow(label: "Deleted by") { Text(version.by).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
                    CardRow(label: "Item ID") {
                        Text(version.item).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(version.item, forType: .string) } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless).help("Copy the item ID")
                    }
                    CardRow(label: "Service") { Text(version.service ?? "None").foregroundStyle(.secondary) }
                    CardRow(label: "Last value", last: true) {
                        if let v = model.revealedVersions[version.id] {
                            Text(v).font(.callout.monospaced()).textSelection(.enabled).lineLimit(3)
                        } else {
                            Text(String(repeating: "•", count: 14)).foregroundStyle(.secondary)
                        }
                        Button {
                            if model.revealedVersions[version.id] != nil { model.revealedVersions[version.id] = nil }
                            else { Task { await model.revealVersion(version) } }
                        } label: { Image(systemName: model.revealedVersions[version.id] == nil ? "eye" : "eye.slash") }
                        .buttonStyle(.borderless).help("Show the last value (asks for approval)")
                    }
                }
                Card {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "clock").font(.title3).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("This item is deleted").font(.body.weight(.semibold))
                            Text("It can be restored to its project and environment, with its settings and history, for \(left) more day\(left == 1 ? "" : "s"). After that it's removed for good.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 12)
                }
                HStack {
                    Button { Task { await model.restore(version) } } label: { Label("Restore Item", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.borderedProminent)
                    Button(role: .destructive) { confirmingForget = true } label: { Label("Permanently Delete…", systemImage: "trash") }
                }
                .controlSize(.large)
            }
            .padding(16)
        }
        .confirmationDialog("Permanently delete \(info.ref.name)?", isPresented: $confirmingForget) {
            Button("Delete for Good", role: .destructive) { Task { await model.forgetHistory([version.item]) } }
        } message: {
            Text("Its last value and every earlier value are deleted\(model.synced ? " on all your Macs" : "") and can't be brought back.")
        }
    }
}

// MARK: - Grants

struct GrantList: View {
    @Bindable var model: AppModel
    @State private var search = ""

    var body: some View {
        let q = search.lowercased()
        let shown = model.grants.filter { g in q.isEmpty || g.folder.lowercased().contains(q) || g.names.joined().lowercased().contains(q) }
        let ending = model.grants.filter { $0.expires.timeIntervalSinceNow < 3600 }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                PageHeader(title: "Grants", subtitle: "\(model.grants.count) in effect\(ending > 0 ? " · \(ending) ending within the hour" : "")")
                Spacer()
                Button { model.grantRequest = GrantRequest() } label: { Label("New Grant…", systemImage: "plus") }
            }
            PageSearch(text: $search, prompt: "Search grants…")
            Table(shown, selection: $model.selectedGrant) {
                TableColumn("Grant") { g in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(g.names.count == 1 ? (ItemID(g.names[0])?.name ?? g.names[0]) : "\(g.names.count) items").font(.body.weight(.medium)).lineLimit(1)
                        if g.names.count == 1, let ref = ItemID(g.names[0]) {
                            PlaceChips(project: ref.isShared ? nil : ref.project, environment: ref.isShared ? nil : ref.environment)
                        } else {
                            Text(g.names.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 3)
                }
                TableColumn("Folder") { g in Text(Broker.tilde(g.folder)).font(.callout.monospaced()).lineLimit(1).truncationMode(.head) }
                TableColumn("Limits") { g in Text(g.limits.isEmpty ? "Any command" : g.limits.prefix(1).capitalized + g.limits.dropFirst()).lineLimit(1) }
                TableColumn("Status") { g in GrantStatus(grant: g) }.width(min: 90, ideal: 110)
                TableColumn("Ends") { g in Text(g.expires.formatted(date: .abbreviated, time: .shortened)).lineLimit(1) }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView {
                        Label("No Grants", systemImage: "checkmark.shield")
                    } description: {
                        Text("Every read of an item that isn't agent-safe asks first.")
                    } actions: {
                        Button("New Grant…") { model.grantRequest = GrantRequest() }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 12)
        .navigationTitle("Grants")
        .toolbar(removing: .title)
    }
}

/// Active, or ending within the hour.
struct GrantStatus: View {
    let grant: Grant
    var body: some View {
        let soon = grant.expires.timeIntervalSinceNow < 3600
        HStack(spacing: 5) {
            Circle().fill(soon ? Color.orange : Color.green).frame(width: 7, height: 7)
            Text(soon ? "Ending soon" : "Active").font(.callout)
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(Capsule().fill((soon ? Color.orange : Color.green).opacity(0.15)))
    }
}

struct GrantDetail: View {
    let model: AppModel
    let grant: Grant

    var body: some View {
        let single = grant.names.count == 1 ? ItemID(grant.names[0]) : nil
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DetailHeader(symbol: "checkmark.shield", tint: .teal,
                             title: single.map(\.name) ?? "\(grant.names.count) items") {
                    if let ref = single { PlaceChips(project: ref.isShared ? nil : ref.project, environment: ref.isShared ? nil : ref.environment) }
                } trailing: { EmptyView() }
                Card {
                    CardRow(label: "Status") { GrantStatus(grant: grant) }
                    CardRow(label: "Folder") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Broker.tilde(grant.folder)).font(.callout.monospaced()).textSelection(.enabled)
                            if grant.repo != nil { Text("and its repository's worktrees").font(.caption) }
                        }
                        .foregroundStyle(.secondary)
                    }
                    CardRow(label: grant.names.count == 1 ? "Item" : "Items") {
                        Text(grant.names.joined(separator: "\n")).font(.callout.monospaced()).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                    CardRow(label: "Limits", last: true) {
                        Text(grant.limits.isEmpty ? "Any command, any number of reads" : grant.limits).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
                Card {
                    CardRow(label: "Created") {
                        Text(grant.created.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    }
                    CardRow(label: "Ends") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(grant.expires.formatted(date: .abbreviated, time: .shortened))
                            Text(grant.expires.formatted(.relative(presentation: .named))).font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    CardRow(label: "Made by", last: true) { Text(grant.createdBy).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
                }
                HStack {
                    Button(role: .destructive) { Task { await model.revoke(grant.id) } } label: { Label("Revoke Grant", systemImage: "nosign") }
                        .buttonStyle(.borderedProminent).tint(.red)
                    Button("Show Folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: grant.folder)]) }
                }
                .controlSize(.large)
                Text("Revoking stops future reads through this grant. It can't recall values already released.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }
}
