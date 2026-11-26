import LatchkeyCore
import SwiftUI

struct AddItemSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var value = ""
    @State private var kind = ItemKind.token
    @State private var agentSafe = false
    @State private var note = ""
    @State private var error: String?
    @State private var saving = false

    var nameProblem: String? {
        if name.isEmpty { return nil }
        if !Wire.isValidName(name) { return "Letters, digits, _ - . only." }
        if model.item(name) != nil { return "An item with this name exists. Use Change Value on it instead." }
        return nil
    }

    private var place: String {
        guard let id = ItemID(name), Wire.isValidName(name) else { return "Name it NAME for a shared item, or project/environment/NAME" }
        return id.isShared ? "A shared item" : "In \(id.project) / \(id.environment)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(symbol: kind.symbol, tint: kind.tint, title: "New Item", subtitle: place)
            Card {
                FieldRow(label: "Name") {
                    TextField("Name", text: $name, prompt: Text("GEMINI_API_KEY")).font(.body.monospaced())
                }
                FieldRow(label: "Kind") {
                    Picker("", selection: $kind) {
                        ForEach(ItemKind.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Spacer()
                }
                FieldRow(label: "Value") {
                    if kind == .key || kind == .value {
                        TextField("Value", text: $value, prompt: Text("Paste the value"), axis: .vertical).lineLimit(3...10).font(.body.monospaced())
                    } else {
                        SecureField("Value", text: $value, prompt: Text("Paste the value"))
                    }
                }
                FieldRow(label: "Note") {
                    TextField("Note", text: $note, prompt: Text("Optional"))
                }
                FieldRow(label: "Access", last: true) {
                    Picker("Access", selection: $agentSafe) {
                        Text("Ask first").tag(false)
                        Text("No approval").tag(true)
                    }
                    .labelsHidden().fixedSize()
                    Spacer()
                }
            }
            if let p = nameProblem ?? error { Text(p).font(.callout).foregroundStyle(.red) }
            SheetFooter(note: "Saving asks for Touch ID.", noteSymbol: "touchid") {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    saving = true
                    Task {
                        error = await model.save(name: name, value: value, kind: kind, agentSafe: agentSafe, note: note)
                        saving = false
                        if error == nil {
                            model.filter = .all
                            model.selection = [name]
                            dismiss()
                            let added = name
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                model.nextSteps = NextSteps(
                                    title: "Added \(added)",
                                    body: "Put this reference in an env file in place of the value, then run your project through pst run. Replace npm run dev with your own command.",
                                    commands: ["\(ItemID(added)?.name ?? added)=pistachio://\(added)", "pst run --env-file .env -- npm run dev"],
                                    agents: true)
                            }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || nameProblem != nil || value.isEmpty || saving)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct ChangeValueSheet: View {
    let model: AppModel
    let item: SecretInfo
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(symbol: ItemType(item).symbol, tint: ItemType(item).tint, title: "New Value", subtitle: "for \(item.name)")
            Card {
                FieldRow(label: "Value", last: true) {
                    if item.kind == .key || item.kind == .value {
                        TextField("Value", text: $value, prompt: Text("Paste the new value"), axis: .vertical).lineLimit(3...10).font(.body.monospaced())
                    } else {
                        SecureField("Value", text: $value, prompt: Text("Paste the new value"))
                    }
                }
            }
            Text("Commands pick up the new value the next time they start. The current one is kept in History.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            SheetFooter(note: "Saving asks for Touch ID.", noteSymbol: "touchid") {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        error = await model.save(name: item.name, value: value, kind: nil, agentSafe: nil, note: nil)
                        if error == nil {
                            model.revealed[item.name] = nil
                            model.notice = "Changed \(item.name)."
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(value.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

/// An item's settings, changed together with one approval.
struct EditItemSheet: View {
    let model: AppModel
    let item: SecretInfo
    @Environment(\.dismiss) private var dismiss
    @State private var kind = ItemKind.token
    @State private var agentSafe = false
    @State private var service = ""
    @State private var note = ""
    @State private var fillSites = ""
    @State private var error: String?
    @State private var saving = false

    private var sites: [String] {
        fillSites.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var changed: Bool {
        kind != item.kind || agentSafe != item.agentSafe || service != (item.service ?? "") || note != item.note
            || sites != (item.fillSites ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(symbol: ItemType(item).symbol, tint: ItemType(item).tint, title: "Edit Details", subtitle: item.name)
            Card {
                FieldRow(label: "Kind") {
                    Picker("", selection: $kind) {
                        ForEach(ItemKind.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Spacer()
                }
                FieldRow(label: "Access") {
                    Picker("Access", selection: $agentSafe) {
                        Text("Ask first").tag(false)
                        Text("No approval").tag(true)
                    }
                    .labelsHidden().fixedSize()
                    Spacer()
                }
                FieldRow(label: "Service") { TextField("Service", text: $service, prompt: Text("Stripe, Neon, GitHub…")) }
                FieldRow(label: "Note") { TextField("Note", text: $note, prompt: Text("What it's for, where it came from")) }
                FieldRow(label: "Fill in Safari on", last: true) {
                    TextField("Sites", text: $fillSites, prompt: Text("Its service's site and deployment platforms"))
                }
            }
            Text("Sites are separated by commas, such as vercel.com, and each covers its subdomains. Leave them empty for the item's service and the deployment platforms.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            SheetFooter(note: "Saving asks for Touch ID once.", noteSymbol: "touchid") {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    saving = true
                    Task {
                        error = await model.updateDetails(item.name,
                                                          kind: kind == item.kind ? nil : kind,
                                                          agentSafe: agentSafe == item.agentSafe ? nil : agentSafe,
                                                          service: service == (item.service ?? "") ? nil : service,
                                                          note: note == item.note ? nil : note,
                                                          fillSites: sites == (item.fillSites ?? []) ? nil : sites)
                        saving = false
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(saving || !changed)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear {
            kind = item.kind; agentSafe = item.agentSafe; service = item.service ?? ""; note = item.note
            fillSites = (item.fillSites ?? []).joined(separator: ", ")
        }
    }
}

struct ImportSheet: View {
    let model: AppModel
    @State var draft: ImportDraft
    @Environment(\.dismiss) private var dismiss
    @State private var replace = false
    @State private var rewrite = true
    @State private var error: String?
    @State private var working = false

    init(model: AppModel, draft: ImportDraft) {
        self.model = model
        var draft = draft
        // Only secrets are saved to the keychain by default; settings and public values stay in the file.
        for i in draft.rows.indices { draft.rows[i].include = draft.rows[i].include && draft.rows[i].cls == .secret }
        _draft = State(initialValue: draft)
    }

    func exists(_ row: ImportDraft.Row) -> Bool { model.item(draft.itemID(row.key)) != nil }

    var chosen: Int { draft.rows.filter { $0.include && (!exists($0) || replace) }.count }

    /// What the file will hold after import, built with the importer's own rewrite. Values of secrets, and of
    /// anything the classifier didn't mark a setting or public value, are masked; the text is never shown as read.
    var preview: [String]? {
        let saved = draft.rows.filter { $0.include && (!exists($0) || replace) }
        let refs = rewrite ? Dictionary(uniqueKeysWithValues: saved.map { ($0.key, draft.itemID($0.key)) }) : [:]
        let shown = Set(draft.rows.filter { $0.cls == .setting || $0.cls == .publicValue }.map(\.key))
        guard let text = try? EnvFile.rewrite(draft.text, toReferences: refs),
              let entries = try? EnvFile.located(text) else { return nil }
        var masks: [String: String] = [:]
        for e in entries where !shown.contains(e.key) && !References.containsReference(e.value) { masks[e.key] = "\u{2022}\u{2022}\u{2022}\u{2022}" }
        guard let masked = try? EnvFile.merge(text, with: masks, pending: Set(masks.keys)).text else { return nil }
        var lines = masked.replacingOccurrences(of: "\"\u{2022}\u{2022}\u{2022}\u{2022}\"", with: "\u{2022}\u{2022}\u{2022}\u{2022}")
            .components(separatedBy: .newlines)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    var destination: String { draft.shared ? "Shared" : "\(draft.project) / \(draft.environment)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(symbol: "square.and.arrow.down", tint: .blue, title: "Import \(draft.url.lastPathComponent)",
                        subtitle: destination)
            HStack(spacing: 10) {
                Picker("", selection: $draft.shared) {
                    Text("Project").tag(false)
                    Text("Shared").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if !draft.shared {
                    TextField("Project", text: $draft.project).frame(width: 160)
                    TextField("Environment", text: $draft.environment).frame(width: 140)
                    Menu {
                        ForEach(Environments.known, id: \.self) { e in Button(e) { draft.environment = e } }
                    } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Spacer()
            }
            .textFieldStyle(.roundedBorder)
            Text(draft.shared ? "Items are named after their keys, e.g. pistachio://\(draft.rows.first?.key ?? "KEY")."
                 : "Items become pistachio://\(draft.itemID(draft.rows.first?.key ?? "KEY")). The project is the repository's folder; the environment comes from the file name.")
                .font(.caption).foregroundStyle(.secondary)
            Table($draft.rows) {
                TableColumn("Variable") { $row in
                    HStack(spacing: 6) {
                        Text(row.key).font(.body.monospaced())
                        if let s = row.item.service { Text(s).font(.caption).foregroundStyle(.secondary) }
                        if exists(row) {
                            Text("exists").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(.yellow.opacity(0.3)))
                        }
                    }
                }
                TableColumn("Action") { $row in
                    Picker("", selection: $row.include) {
                        Text("Save to Keychain").tag(true)
                        Text("Keep in file").tag(false)
                    }
                    .labelsHidden()
                    .help("Save to Keychain imports the line as an item. Keep in file leaves it as it is.")
                }
                .width(150)
            }
            .frame(minHeight: 180)

            VStack(alignment: .leading, spacing: 4) {
                Text(".env after import").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    if let lines = preview {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .trailing, spacing: 0) {
                                ForEach(lines.indices, id: \.self) { Text("\($0 + 1)").foregroundStyle(.tertiary) }
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(lines.indices, id: \.self) { Text(lines[$0].isEmpty ? " " : lines[$0]).textSelection(.enabled) }
                            }
                            Spacer(minLength: 0)
                        }
                        .font(.caption.monospaced())
                        .padding(8)
                    } else {
                        Text("Preview unavailable: the file has invalid syntax.").font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                }
                .frame(height: 110)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
            }

            if !draft.ignored.isEmpty {
                Text("Left alone: " + draft.ignored.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Overwrite items that already exist", isOn: $replace)
            Toggle("Replace values in the file with credential references", isOn: $rewrite)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            SheetFooter(note: "One Touch ID approval covers the whole import.", noteSymbol: "touchid") {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import \(chosen) Secret\(chosen == 1 ? "" : "s")") {
                    working = true
                    Task {
                        error = await model.runImport(draft, replace: replace, rewrite: rewrite)
                        working = false
                        if error == nil { model.filter = .all; dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen == 0 || working || !draft.placeIsValid)
            }
        }
        .padding(20)
        .frame(width: 620, height: 660)
    }
}


/// What to do once keys are in Latchkey: the command to run, ready to copy, and where agents come in.
struct NextSteps: Identifiable {
    let id = UUID()
    var title: String
    var body: String
    var commands: [String]
    /// Mention how coding agents use the keys.
    var agents: Bool

    /// The env file the commands run with, for the agent prompt.
    var envFile: String? {
        commands.lazy.compactMap { c -> String? in
            guard let r = c.range(of: "--env-file ") else { return nil }
            return c[r.upperBound...].split(separator: " ").first.map(String.init)
        }.first
    }

    /// What to tell a coding agent: run through lk, keep values out of files and output, stop when refused.
    static func agentPrompt(envFile: String?) -> String {
        let file = envFile ?? ".env.local"
        return """
        Secrets are in Pistachio. \(file) holds credential references, not values. Run anything that needs them with `pst run --env-file \(file) -- <command>`. In a fresh checkout or worktree, write the file first with `pst project` and `pst export <project>/<environment> --out \(file)`. Never run `pst get`, print the environment, or put real values in env files. If pst exits 77 (refused) or 66 (missing), stop and ask me; don't retry.
        """
    }
}

struct NextStepsSheet: View {
    let steps: NextSteps
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(symbol: "checkmark", tint: .green, title: steps.title)
            Text(steps.body).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(steps.commands, id: \.self) { command in
                    HStack {
                        Text(command).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(copied == command ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            copied = command
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
                }
            }
            if steps.agents {
                let prompt = NextSteps.agentPrompt(envFile: steps.envFile)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("For your coding agent").font(.callout.weight(.semibold))
                        Spacer()
                        Button(copied == prompt ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(prompt, forType: .string)
                            copied = prompt
                        }
                    }
                    Text(prompt).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Paste it into CLAUDE.md or AGENTS.md, or install the Pistachio skill. Agents ask you here before reading a key.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
            }
            SheetFooter {
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

enum ProLinks {
    static let pricing = URL(string: "https://latchkey.snackstud.io/pricing.html#pro")!
}

/// Shown when the broker refuses an op that needs Latchkey Pro. Buying happens in Settings (App Store build only).
struct UpgradeSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    private static let groups: [(title: String, detail: String)] = [
        ("Agent controls", "Secret requests, and a hook that stops commands like cat .env."),
        ("Recovery and migration", "Importers for 1Password, Bitwarden and Passwords, and an encrypted backup."),
        ("Rotation and lifecycle", "Last-used and expiry dates, reminders and leak alerts."),
        ("Provider integrations", "Each key's origin: its service, console and last rotation."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(symbol: "star.fill", tint: .orange, title: "Pistachio Pro",
                        subtitle: "This feature is part of Pistachio Pro.")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title).font(.callout.weight(.semibold))
                        Text(group.detail).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Everything Pistachio does today is free. Storing, reading, approving, running, importing, exporting and restoring your secrets never depend on Pro.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SheetFooter {
                Button("Not Now") { dismiss() }
                Button("Membership") { dismiss(); model.openSettings(.membership) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
