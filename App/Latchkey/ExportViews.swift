import AppKit
import LatchkeyCore
import SwiftUI

/// Writes an environment's env file, as `lk export` does and with the same checks: references or values, a new file, or a
/// merge into an existing one that names what it adds and updates and keeps every other byte.
struct ExportSheet: View {
    let model: AppModel
    let scope: String
    @Environment(\.dismiss) private var dismiss
    @State private var values = false
    @State private var path = ""
    @State private var replace = false
    @State private var error: String?
    @State private var working = false

    private var record: EnvironmentRecord? { model.records.first { $0.scope == scope } }
    private var destination: String { path.isEmpty ? "" : (path as NSString).expandingTildeInPath }
    private var exists: Bool { !destination.isEmpty && ((try? EnvFile.existingFile(destination)) ?? nil) != nil }
    private var mode: EnvExport.Mode { exists ? (replace ? .replace : .merge) : .create }

    /// What writing would do, or why it can't. Nothing is written or asked for until Export.
    private var plan: Result<EnvExport.Plan, Error>? {
        guard let record, destination.hasPrefix("/") else { return nil }
        return Result { try EnvExport.plan(path: destination, record: record, values: values, mode: mode) }
    }

    private var gitProblem: String? { values && destination.hasPrefix("/") ? EnvExport.gitProblem(destination) : nil }
    private var sync: String? { values && destination.hasPrefix("/") ? EnvExport.cloudSync(destination) : nil }

    private var blocked: Bool {
        if working || gitProblem != nil { return true }
        guard let plan, case .success = plan else { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(symbol: "square.and.arrow.up", tint: .blue, title: "Export \(scope)",
                        subtitle: "Write this environment's env file from its record.")
            if record == nil {
                Text("\(scope) has no environment record yet. `lk env migrate` makes one from your items.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Card {
                FieldRow(label: "Contents") {
                    Picker("", selection: $values) {
                        Text("References").tag(false)
                        Text("Values").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                }
                FieldRow(label: "File", last: !exists) {
                    TextField("File", text: $path, prompt: Text("/path/to/.env.local"))
                        .font(.callout.monospaced()).autocorrectionDisabled()
                    Button("Choose…") { choose() }
                }
                if exists {
                    FieldRow(label: "File exists", last: true) {
                        Picker("", selection: $replace) {
                            Text("Merge").tag(false)
                            Text("Replace the file").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        Spacer()
                    }
                }
            }

            preview

            if values {
                Label("Values are written in plain text, readable only by you. Latchkey asks first, naming the file.",
                      systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            }
            if let gitProblem { Text(gitProblem).font(.caption).foregroundStyle(.red) }
            if let sync {
                Text("\(Broker.tilde(destination)) is in a folder that syncs to \(sync): the values will leave this Mac.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }

            SheetFooter(note: values ? "Writing values asks for Touch ID." : "References only; no values are read.",
                        noteSymbol: values ? "touchid" : "lock") {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(mode == .merge ? "Merge" : "Export") { export() }
                    .keyboardShortcut(.defaultAction).disabled(blocked)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onChange(of: path) { _, _ in error = nil }
        .onChange(of: values) { _, _ in error = nil }
    }

    @ViewBuilder private var preview: some View {
        switch plan {
        case nil:
            if record != nil { Text("Choose a file to see what would change.").font(.caption).foregroundStyle(.secondary) }
        case .failure(let e):
            Text(e.localizedDescription).font(.caption).foregroundStyle(.red)
        case .success(let plan):
            VStack(alignment: .leading, spacing: 4) {
                if plan.mode == .replace {
                    Text("Replaces the whole file with \(record?.variables.count ?? 0) variable\(record?.variables.count == 1 ? "" : "s"). Comments and other variables in it are lost.")
                        .font(.callout)
                } else if plan.existing == nil {
                    Text("Creates \(Broker.tilde(destination)) with \(plan.added.count) variable\(plan.added.count == 1 ? "" : "s").").font(.callout)
                } else if !plan.changes {
                    Text("The file already has every variable as it would be written. Nothing changes.").font(.callout)
                } else {
                    Text("Everything else in the file stays as it is.").font(.callout).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(plan.added, id: \.self) { Text("add     \($0)").font(.caption.monospaced()).foregroundStyle(.green) }
                            ForEach(plan.updated, id: \.self) {
                                Text("update  \($0)\(values ? "  (value written; may be unchanged)" : "")").font(.caption.monospaced())
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 130)
                }
            }
        }
    }

    private func choose() {
        let panel = NSSavePanel()
        panel.showsHiddenFiles = true
        panel.nameFieldStringValue = ".env.local"
        panel.message = "Choose the env file to write or update."
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }

    private func export() {
        guard let plan, case .success(let p) = plan else { return }
        working = true
        Task {
            error = await model.exportEnvironment(p, scope: scope, values: values)
            working = false
            if error == nil { dismiss() }
        }
    }
}
