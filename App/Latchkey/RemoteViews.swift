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

            if links.isEmpty {
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

            if !links.isEmpty {
                HStack {
                    Button(checking ? "Checking…" : "Check Status") { check() }.disabled(checking || working)
                    Button("Add a Location…") { adding = true }
                }
            }
            Spacer(minLength: 0)
            SheetFooter(note: "Values go through each service's own tool, signed in as you, or to its API with the token item you chose. Nothing is deployed.") {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                if !links.isEmpty {
                    Button(working ? "Pushing…" : "Push to All") { pushTo(nil) }
                        .keyboardShortcut(.defaultAction).disabled(working || itemCount == 0)
                }
            }
        }
        .padding(24)
        .frame(width: 620, height: 520)
        .sheet(isPresented: $adding) { AddLocationSheet(model: model, scope: scope, itemCount: itemCount) }
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
extension RemoteTarget.Service {
    /// A plain symbol for the service's picker; Latchkey doesn't use the services' own marks.
    var symbol: String {
        switch self {
        case .vercel: return "triangle.fill"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .railway: return "tram.fill"
        case .fly: return "paperplane.fill"
        }
    }

    /// Where to get the service's command-line tool.
    var installPage: URL {
        switch self {
        case .vercel: return URL(string: "https://vercel.com/docs/cli")!
        case .github: return URL(string: "https://cli.github.com")!
        case .railway: return URL(string: "https://docs.railway.com/guides/cli")!
        case .fly: return URL(string: "https://fly.io/docs/flyctl/install/")!
        }
    }
}

/// Links an environment to Vercel, GitHub Actions, Railway or Fly. Nothing here signs in or stores a token. Pushes run
/// each service's own tool, signed in as you (so the sheet checks it's installed), or, with a token item chosen, go to
/// the service's API with the token in that item. The App Store build only does the second.
struct AddLocationSheet: View {
    let model: AppModel
    let scope: String
    let itemCount: Int
    @Environment(\.dismiss) private var dismiss
    @State private var service: RemoteTarget.Service = .vercel

    /// The App Store build leaves out GitHub's sealed box, so it can't push to GitHub Actions.
    static var services: [RemoteTarget.Service] {
        #if LATCHKEY_APP_STORE
        return RemoteTarget.Service.allCases.filter { $0 != .github }
        #else
        return RemoteTarget.Service.allCases
        #endif
    }
    @State private var project = ""
    @State private var environment = "preview"
    @State private var repo = ""
    @State private var serviceName = ""
    @State private var app = ""
    @State private var branch = ""
    @State private var directory = ""
    @State private var tokenItem = ""
    @State private var team = ""
    @State private var error: String?
    @State private var working = false
    /// The service's tool: its version when installed, nil while checking, "" when it isn't installed.
    @State private var toolVersion: String?

    init(model: AppModel, scope: String, itemCount: Int) {
        self.model = model
        self.scope = scope
        self.itemCount = itemCount
        let ids = model.items.filter { $0.name.hasPrefix(scope + "/") }.map(\.name)
        let folder = model.files(for: ids).first.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? ""
        _directory = State(initialValue: folder)
        let env = String(scope.split(separator: "/").last ?? "")
        let instance = env.split(separator: ".").last.map(String.init) ?? env
        _environment = State(initialValue: ["development", "preview", "production"].contains(instance) ? instance : "preview")
    }

    private var projectName: String { String(scope.split(separator: "/").first ?? "") }
    private var envName: String { String(scope.split(separator: "/").last ?? "") }

    var target: RemoteTarget {
        func v(_ s: String) -> String? { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
        return RemoteTarget(service: service, project: v(project), environment: v(environment), repo: v(repo),
                            serviceName: v(serviceName), app: v(app), branch: v(branch), directory: v(directory),
                            tokenItem: v(tokenItem), team: service == .vercel ? v(team) : nil)
    }

    /// What stops Add Location: with a token item the service's API needs more than a folder can give; the App Store
    /// build has no tools to fall back on.
    private var blocker: String? {
        #if LATCHKEY_APP_STORE
        return target.tokenItem == nil ? "Choose the item that holds the access token." : target.nativeProblem
        #else
        return target.tokenItem == nil ? target.problem : target.nativeProblem
        #endif
    }

    /// Items an access token can come from: shared items, which belong to no project.
    private var tokenChoices: [String] { model.items.map(\.name).filter { !$0.contains("/") }.sorted() }

    @ViewBuilder
    private var tokenField: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Access token").frame(width: 110, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $tokenItem) {
                        #if !LATCHKEY_APP_STORE
                        Text("None (use \(service.tool))").tag("")
                        #else
                        Text("Choose an item…").tag("")
                        #endif
                        ForEach(tokenChoices, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    Text(tokenCaption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 10)
        }
    }

    private var tokenCaption: String {
        #if LATCHKEY_APP_STORE
        return "A shared item that holds your \(service.label) access token. Latchkey sends it only to \(service.label), and the push approval names it."
        #else
        return "Optional: a shared item that holds your \(service.label) access token. Pushes then go straight to \(service.label) instead of through \(service.tool); the approval names the item."
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                IconTile(symbol: "cloud", tint: .blue, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add Remote Location").font(.title2.weight(.semibold))
                    HStack(spacing: 6) {
                        Text(projectName).font(.callout.weight(.medium))
                        EnvBadge(environment: envName, compact: true).fixedSize()
                        Text("· \(itemCount) item\(itemCount == 1 ? "" : "s")").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Link this environment to a deployment platform to push its values there and see what's out of step.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Text("Service").frame(width: 110, alignment: .leading)
                Picker("", selection: $service) {
                    ForEach(Self.services, id: \.self) { s in Label(s.label, systemImage: s.symbol).tag(s) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            .padding(.horizontal, 14)

            Card {
                switch service {
                case .vercel:
                    field("Project", $project, "Name or ID", "Leave blank to use the project the folder is linked to with vercel link (not with an access token).")
                    choice("Environment", ["development", "preview", "production"], "The Vercel environment to set variables in.")
                    if environment == "preview" { field("Git branch", $branch, "Optional", "Only for preview deployments of this branch.") }
                    field("Team", $team, "Optional", "The team's slug or ID, when the project belongs to a team. Used with an access token.")
                    #if !LATCHKEY_APP_STORE
                    folder(last: false)
                    #endif
                    tokenField
                case .github:
                    field("Repository", $repo, "owner/repo", "The repository whose Actions secrets are set.")
                    field("Environment", $environment, "Optional", "A GitHub Actions environment. Leave blank for repository secrets.")
                    tokenField
                case .railway:
                    field("Service", $serviceName, "api, web…", "The Railway service to set variables on.")
                    field("Environment", $environment, "production, staging…", "The Railway environment.")
                    field("Project ID", $project, "Optional", "Leave blank to use the project the folder is linked to with railway link (not with an access token).")
                    #if !LATCHKEY_APP_STORE
                    folder(last: false)
                    #endif
                    tokenField
                case .fly:
                    field("App", $app, "your-app", "The Fly app whose secrets are set. Changes are staged until your next deploy.")
                    tokenField
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                #if LATCHKEY_APP_STORE
                if tokenChoices.isEmpty {
                    Label("Add an item for the access token first (for example \(service.rawValue.uppercased())_TOKEN).", systemImage: "info.circle")
                        .foregroundStyle(.secondary).font(.callout)
                }
                #else
                if target.tokenItem == nil { toolStatus }
                #endif
                if let p = blocker {
                    Label(p, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red).font(.callout)
                }
                if target.isProduction {
                    Label("Pushes here count as production and ask for an extra confirmation every time.", systemImage: "info.circle")
                        .foregroundStyle(.secondary).font(.callout)
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout) }
            }

            SheetFooter(note: target.tokenItem == nil ? "Values go through \(service.label)'s own tool, signed in as you. Nothing is deployed."
                                                       : "Values go to \(service.label)'s API with the token in \(target.tokenItem ?? ""). Nothing is deployed.") {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Location") {
                    working = true
                    Task {
                        error = await model.addLink(scope, target)
                        working = false
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(blocker != nil || working || (target.tokenItem == nil && toolVersion == ""))
            }
        }
        .padding(24)
        .frame(width: 620)
        .task(id: service) {
            #if !LATCHKEY_APP_STORE
            await checkTool()
            #endif
        }
        .onChange(of: service) { _, s in
            if s == .github || s == .railway { environment = environment == "preview" ? "" : environment }
            if s == .vercel && environment.isEmpty { environment = "preview" }
        }
    }

    @ViewBuilder
    private var toolStatus: some View {
        switch toolVersion {
        case nil:
            Label("Looking for \(service.tool)…", systemImage: "hourglass").foregroundStyle(.secondary).font(.callout)
        case ""?:
            HStack {
                Label("\(service.tool) isn't installed on this Mac. Latchkey uses it to push.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
                Spacer()
                Link("Install…", destination: service.installPage).font(.callout)
                Button("Check Again") { Task { await checkTool() } }.controlSize(.small)
            }
        case let v?:
            Label("\(service.tool) is installed\(v.isEmpty ? "" : " (\(v))")", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        }
    }

    /// Finds the tool and asks it for its version; "" when it isn't installed.
    private func checkTool() async {
        toolVersion = nil
        let tool = service.tool
        let version: String = await Task.detached {
            guard let path = ProcessRunner.locate(tool) else { return "" }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["--version"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return "" }
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            if p.isRunning { p.terminate(); return "installed" }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            // The first version-like word: "Vercel CLI 39.1.0", "gh version 2.63.0 (...)", "flyctl v0.3.82 ...".
            let word = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first { $0.first?.isNumber == true || ($0.first == "v" && $0.dropFirst().first?.isNumber == true) }
            return word.map { $0.hasPrefix("v") ? String($0) : "v" + $0 } ?? "installed"
        }.value
        toolVersion = version == "installed" ? "installed" : version
    }

    @ViewBuilder
    private func field(_ label: String, _ text: Binding<String>, _ prompt: String, _ caption: String, last: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).frame(width: 110, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    TextField(label, text: text, prompt: Text(prompt)).textFieldStyle(.roundedBorder)
                    Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 10)
            if !last { Divider() }
        }
    }

    @ViewBuilder
    private func choice(_ label: String, _ options: [String], _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).frame(width: 110, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $environment) { ForEach(options, id: \.self) { Text($0).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 10)
            Divider()
        }
    }

    @ViewBuilder
    private func folder(last: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Folder").frame(width: 110, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(directory.isEmpty ? "None chosen" : Broker.tilde(directory)).font(.callout.monospaced())
                            .foregroundStyle(directory.isEmpty ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url { directory = url.path }
                        }
                    }
                    Text("The project's folder, where its link to \(service.label) lives. The tool runs from here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 10)
            if !last { Divider() }
        }
    }
}
