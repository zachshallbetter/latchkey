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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Item").font(.title3.weight(.semibold)).padding([.top, .horizontal], 20)
            Form {
                TextField("Name", text: $name, prompt: Text("GEMINI_API_KEY"))
                if let p = nameProblem { Text(p).font(.caption).foregroundStyle(.red) }
                Picker("Kind", selection: $kind) {
                    ForEach(ItemKind.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                if kind == .key || kind == .value {
                    TextField("Value", text: $value, axis: .vertical).lineLimit(3...10).font(.body.monospaced())
                } else {
                    SecureField("Value", text: $value)
                }
                TextField("Note", text: $note, prompt: Text("Optional"))
                Toggle("Allow reads without approval", isOn: $agentSafe)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            HStack {
                Text("Saving asks for Touch ID.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    saving = true
                    Task {
                        error = await model.save(name: name, value: value, kind: kind, agentSafe: agentSafe, note: note)
                        saving = false
                        if error == nil {
                            model.filter = .all
                            model.selection = [name]
                            model.reveal([name])
                            dismiss()
                            let added = name
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                model.nextSteps = NextSteps(
                                    title: "Added \(added)",
                                    body: "Put this reference in an env file in place of the value, then run your project through lk run. Replace npm run dev with your own command.",
                                    commands: ["\(ItemID(added)?.name ?? added)=latchkey://\(added)", "lk run --env-file .env -- npm run dev"],
                                    agents: true)
                            }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || nameProblem != nil || value.isEmpty || saving)
            }
            .padding(20)
        }
        .frame(width: 460)
    }
}

struct ChangeValueSheet: View {
    let model: AppModel
    let item: SecretInfo
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New value for \(item.name)").font(.title3.weight(.semibold))
            if item.kind == .key || item.kind == .value {
                TextField("Value", text: $value, axis: .vertical).lineLimit(3...10).font(.body.monospaced())
            } else {
                SecureField("Value", text: $value)
            }
            Text("Commands pick up the new value the next time they start.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
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
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 420)
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
        _draft = State(initialValue: draft)
    }

    func exists(_ row: ImportDraft.Row) -> Bool { model.item(draft.itemID(row.key)) != nil }

    var chosen: Int { draft.rows.filter { $0.include && (!exists($0) || replace) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import \(draft.url.lastPathComponent)").font(.title3.weight(.semibold))
                Text(Broker.tilde(draft.url.path)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
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
            Text(draft.shared ? "Items are named after their keys, e.g. latchkey://\(draft.rows.first?.key ?? "KEY")."
                 : "Items become latchkey://\(draft.itemID(draft.rows.first?.key ?? "KEY")). The project is the repository's folder; the environment comes from the file name.")
                .font(.caption).foregroundStyle(.secondary)
            Table($draft.rows) {
                TableColumn("") { $row in
                    Toggle("", isOn: $row.include).labelsHidden()
                }
                .width(24)
                TableColumn("Key") { $row in
                    HStack(spacing: 6) {
                        Text(row.key).font(.body.monospaced())
                        if let s = row.item.service { Text(s).font(.caption).foregroundStyle(.secondary) }
                        if exists(row) {
                            Text("exists").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(.yellow.opacity(0.3)))
                        }
                    }
                }
                TableColumn("Kind") { $row in
                    Picker("", selection: Binding(get: { row.item.kind ?? .token }, set: { row.item.kind = $0 })) {
                        ForEach(ItemKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
                .width(120)
                TableColumn("Agents") { $row in
                    Toggle("", isOn: Binding(get: { row.item.agentSafe ?? false }, set: { row.item.agentSafe = $0 }))
                        .labelsHidden()
                }
                .width(56)
            }
            .frame(minHeight: 220)

            if !draft.ignored.isEmpty {
                Text("Left alone: " + draft.ignored.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Overwrite items that already exist", isOn: $replace)
            Toggle("Replace values in the file with latchkey:// references", isOn: $rewrite)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("One Touch ID approval covers the whole import.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import \(chosen) Item\(chosen == 1 ? "" : "s")") {
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
        .frame(width: 620, height: 480)
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
}

struct NextStepsSheet: View {
    let steps: NextSteps
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(steps.title, systemImage: "checkmark.circle.fill").font(.title3.weight(.semibold)).foregroundStyle(.primary)
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
                Text("Coding agents run commands the same way. They'll ask you here before reading a key, or you can allow a folder for a while when the panel appears. To teach an agent, install the Latchkey skill or tell it to use lk run.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
