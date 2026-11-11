import AppKit
import LatchkeyCore
import SwiftUI

/// Where one environment's values go: links, a names-only status check, push, and adding a link.
struct RemoteSheet: View {
    let model: AppModel
    let scope: String
    @Environment(\.dismiss) private var dismiss
    @State private var statuses: [String: RemoteStatus] = [:]
    @State private var results: [PushResult] = []
    @State private var checking = false
    @State private var working = false
    @State private var adding = false
    @State private var unlinking: RemoteLink?

    var links: [RemoteLink] { model.links(for: scope) }
    var itemCount: Int { model.items.filter { $0.name.hasPrefix(scope + "/") }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                IconTile(symbol: "cloud", tint: .blue, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Remote Locations").font(.title2.weight(.semibold))
                    HStack(spacing: 6) {
                        Text(scope.split(separator: "/").first.map(String.init) ?? scope).font(.callout.weight(.medium))
                        EnvBadge(environment: String(scope.split(separator: "/").last ?? ""))
                        Text("· \(itemCount) item\(itemCount == 1 ? "" : "s")").foregroundStyle(.secondary)
                    }
                }
            }

            if links.isEmpty && !adding {
                VStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.quaternary.opacity(0.4))
                        .frame(width: 88, height: 88)
                        .overlay(Image(systemName: "cloud").font(.system(size: 36, weight: .regular)).foregroundStyle(.blue))
                    Text("Not Linked").font(.title3.weight(.semibold))
                    Text("Link this environment to Vercel, GitHub Actions, Railway or Fly to push its values there and see what's out of step.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
                    Button { adding = true } label: { Label("Add a Location…", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    HStack(spacing: 6) {
                        ForEach(["Vercel", "GitHub Actions", "Railway", "Fly"], id: \.self) { Chip(text: $0) }
                    }
                    .font(.caption)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
            } else {
                List {
                    ForEach(links) { link in
                        LinkRow(link: link, status: statuses[link.id], results: results.filter { $0.link == link.id }) {
                            pushTo(link)
                        } unlink: { unlinking = link }
                    }
                }
                .frame(minHeight: 160)
            }

            if adding {
                AddLinkForm(model: model, scope: scope) { adding = false }
            }

            if !links.isEmpty {
                HStack {
                    Button(checking ? "Checking…" : "Check Status") { check() }.disabled(checking || working)
                    Button("Add a Location…") { adding = true }.disabled(adding)
                }
            }
            Spacer(minLength: 0)
            SheetFooter(note: "Values go through each service's own tool, signed in as you. Nothing is deployed.") {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                if !links.isEmpty {
                    Button(working ? "Pushing…" : "Push to All") { pushTo(nil) }
                        .keyboardShortcut(.defaultAction).disabled(working || itemCount == 0)
                }
            }
        }
        .padding(24)
        .frame(width: 620, height: adding ? 680 : 520)
        .confirmationDialog("Unlink \(unlinking?.target.label ?? "")?", isPresented: Binding(get: { unlinking != nil }, set: { if !$0 { unlinking = nil } }),
                            presenting: unlinking) { link in
            Button("Unlink", role: .destructive) { Task { await model.unlink(link) } }
        } message: { _ in
            Text("Values already there stay there. Latchkey just stops tracking and pushing to it.")
        }
    }

    private func check() {
        checking = true
        Task {
            let s = await model.remoteStatus(scope)
            statuses = Dictionary(uniqueKeysWithValues: s.map { ($0.link, $0) })
            checking = false
        }
    }

    private func pushTo(_ link: RemoteLink?) {
        working = true
        Task {
            results = await model.push(scope, link: link?.id)
            working = false
            if !results.isEmpty { check() }
        }
    }
}

private struct LinkRow: View {
    let link: RemoteLink
    let status: RemoteStatus?
    let results: [PushResult]
    let push: () -> Void
    let unlink: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
                Text(link.target.label).font(.callout.weight(.medium)).lineLimit(1)
                if link.target.isProduction {
                    Text("production").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(.red.opacity(0.15)))
                }
                Spacer()
                Button("Push", action: push).buttonStyle(.borderless)
                Menu {
                    Button("Unlink…", role: .destructive, action: unlink)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Text(link.pushed.values.max().map { "Last pushed \($0.formatted(.relative(presentation: .named)))" } ?? "Never pushed")
                .font(.caption).foregroundStyle(.secondary)
            if let s = status {
                if let e = s.error {
                    Text("Couldn't check: \(e)").font(.caption).foregroundStyle(.red).lineLimit(3)
                } else if s.missing.isEmpty && s.extra.isEmpty && s.outOfDate.isEmpty {
                    Label("In step", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                } else {
                    if !s.missing.isEmpty { line("Not there", s.missing, .orange) }
                    if !s.outOfDate.isEmpty { line("Changed since last push", s.outOfDate, .orange) }
                    if !s.extra.isEmpty { line("Only there", s.extra, .secondary) }
                }
            }
            let failed = results.filter { !$0.ok }
            if !results.isEmpty {
                Text("Pushed \(results.count - failed.count) of \(results.count)").font(.caption).foregroundStyle(failed.isEmpty ? .green : .orange)
                ForEach(failed, id: \.item) { f in
                    Text("\(ItemID(f.item)?.name ?? f.item): \(f.error ?? "failed")").font(.caption.monospaced()).foregroundStyle(.red).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
    }

    var icon: String {
        switch link.target.service {
        case .vercel: return "triangle.fill"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .railway: return "tram.fill"
        case .fly: return "paperplane.fill"
        }
    }

    private func line(_ title: String, _ names: [String], _ color: Color) -> some View {
        Text("\(title): \(names.prefix(8).joined(separator: ", "))\(names.count > 8 ? " +\(names.count - 8)" : "")")
            .font(.caption).foregroundStyle(color).lineLimit(2)
    }
}

/// The fields each service needs, with the folder defaulting to where the environment's items were imported from.
private struct AddLinkForm: View {
    let model: AppModel
    let scope: String
    let done: () -> Void
    @State private var service: RemoteTarget.Service = .vercel
    @State private var project = ""
    @State private var environment = "preview"
    @State private var repo = ""
    @State private var serviceName = ""
    @State private var app = ""
    @State private var branch = ""
    @State private var directory = ""
    @State private var error: String?
    @State private var working = false

    init(model: AppModel, scope: String, done: @escaping () -> Void) {
        self.model = model
        self.scope = scope
        self.done = done
        let ids = model.items.filter { $0.name.hasPrefix(scope + "/") }.map(\.name)
        let folder = model.files(for: ids).first.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? ""
        _directory = State(initialValue: folder)
        let env = String(scope.split(separator: "/").last ?? "")
        let instance = env.split(separator: ".").last.map(String.init) ?? env
        _environment = State(initialValue: ["development", "preview", "production"].contains(instance) ? instance : "preview")
    }

    var target: RemoteTarget {
        func v(_ s: String) -> String? { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
        return RemoteTarget(service: service, project: v(project), environment: v(environment), repo: v(repo),
                            serviceName: v(serviceName), app: v(app), branch: v(branch), directory: v(directory))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Picker("Service", selection: $service) {
                ForEach(RemoteTarget.Service.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                switch service {
                case .vercel:
                    field("Project", $project, "name or ID; blank uses the folder's linked project")
                    GridRow {
                        Text("Environment").foregroundStyle(.secondary)
                        Picker("", selection: $environment) {
                            ForEach(["development", "preview", "production"], id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented)
                    }
                    if environment == "preview" { field("Git branch", $branch, "optional") }
                    folderRow
                case .github:
                    field("Repository", $repo, "owner/repo")
                    field("Environment", $environment, "optional; blank means repository secrets")
                case .railway:
                    field("Environment", $environment, "production, staging…")
                    field("Service", $serviceName, "the service to set variables on")
                    field("Project ID", $project, "blank uses the folder's linked project")
                    folderRow
                case .fly:
                    field("App", $app, "the Fly app")
                }
            }
            .textFieldStyle(.roundedBorder)
            if let p = target.problem { Text(p).font(.caption).foregroundStyle(.secondary) }
            if target.isProduction { Text("Pushes here count as production and need an extra confirmation every time.").font(.caption).foregroundStyle(.orange) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if ProcessRunner.locate(service.tool) == nil {
                    Text("\(service.tool) isn't installed on this Mac.").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel", action: done)
                Button("Link") {
                    working = true
                    Task {
                        error = await model.addLink(scope, target)
                        working = false
                        if error == nil { done() }
                    }
                }
                .disabled(target.problem != nil || working)
            }
        }
        .onChange(of: service) { _, s in if s == .github || s == .railway { environment = environment == "preview" ? "" : environment } }
    }

    @ViewBuilder
    private func field(_ label: String, _ text: Binding<String>, _ prompt: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            TextField("", text: text, prompt: Text(prompt))
        }
    }

    private var folderRow: some View {
        GridRow {
            Text("Folder").foregroundStyle(.secondary)
            HStack {
                Text(directory.isEmpty ? "none" : Broker.tilde(directory)).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { directory = url.path }
                }
            }
        }
    }
}
