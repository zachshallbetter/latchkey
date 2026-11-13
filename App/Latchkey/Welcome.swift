#if !LATCHKEY_APP_STORE
import AppKit
import LatchkeyCore
import SafariServices
import SwiftUI

/// Latchkey's welcome window: what's installed, checked live, then the choices only the person can make (the Safari
/// extension, a coding agent, a first .env file). It never turns a switch on itself. It opens:
/// - on the first launch of a copy with no items yet;
/// - after the installer package: the setup helper opens Latchkey with `-LatchkeyWelcome YES`, an argument-domain
///   default that lasts one launch (docs/installer.md);
/// - from Settings › About & Updates › Show Welcome… and Help › Welcome to Latchkey.
enum Welcome {
    static let windowID = "welcome"
    static let launchArgument = "LatchkeyWelcome"
    static let doneKey = "welcomeDone"
    static let safariExtensionID = "io.snackstud.latchkey.safari"
    static let agentCommand = "claude mcp add latchkey -- ~/.local/bin/latchkey mcp"

    @MainActor private static var checkedLaunch = false

    /// Once per launch, when the main window first appears: whether to open the welcome. Someone updating from a
    /// version without it, who already has items, isn't shown it; it stays in Settings.
    @MainActor static func shouldOpenAtLaunch(hasItems: Bool) -> Bool {
        guard !checkedLaunch else { return false }
        checkedLaunch = true
        #if DEBUG
        if Snapshot.requested { return false }
        #endif
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: launchArgument) { return true }
        guard !defaults.bool(forKey: doneKey) else { return false }
        if hasItems { defaults.set(true, forKey: doneKey); return false }
        return true
    }
}

/// The install, checked live: the app's location, the command-line links and PATH, and the Safari extension's switch.
@MainActor @Observable
final class WelcomeChecks {
    enum Tool: Equatable { case linked, missing, inTheWay, development }
    var tool: Tool = .missing
    /// Whether a login shell's PATH has ~/.local/bin; nil while checking or when the shell didn't answer.
    var onPath: Bool?
    /// Safari's switch for the extension; nil until Safari has answered, or when it can't say.
    var safariOn: Bool?

    var inApplications: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    func refresh(bundledTool: URL?) {
        let link = CommandLineToolLinks.links(home: NSHomeDirectory())[0]
        if let bundledTool {
            switch CommandLineToolLinks.state(of: link, tool: bundledTool) {
            case .linked: tool = .linked
            case .file: tool = .inTheWay
            case .missing, .otherLink: tool = .missing
            }
        } else {
            // Development builds: scripts/install.sh copies the tool instead of linking it.
            tool = FileManager.default.isExecutableFile(atPath: link.path) ? .development : .missing
        }
        Task.detached {
            let path = Self.loginShellPath()
            let on = path.map { CommandLineToolLinks.directoryIsOnPath($0, home: NSHomeDirectory()) }
            await MainActor.run { self.onPath = on }
        }
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: Welcome.safariExtensionID) { state, _ in
            let on = state?.isEnabled
            Task { @MainActor in self.safariOn = on }
        }
    }

    /// The PATH a new Terminal window gets: the login shell's, read interactively so ~/.zshrc counts. Nil if the shell
    /// doesn't answer within five seconds.
    nonisolated static func loginShellPath() -> String? {
        let shell = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        let marker = "__LATCHKEY_PATH__"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-i", "-c", "printf '\\n\(marker)%s' \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let range = text.range(of: marker, options: .backwards) else { return nil }
        return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct WelcomeView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var checks = WelcomeChecks()
    @State private var page: Page
    @State private var forward = true

    init(model: AppModel, page: Page = .installed) {
        self.model = model
        _page = State(initialValue: page)
    }

    enum Page: Int, CaseIterable { case installed, safari, agent, firstImport }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                pageView
                    .id(page)
                    .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            footer
        }
        .padding(.horizontal, 44).padding(.top, 40).padding(.bottom, 24)
        .frame(width: 700, height: 500)
        .background(alignment: .top) {
            LinearGradient(colors: [Color.accentColor.opacity(0.14), .clear], startPoint: .top, endPoint: .center).ignoresSafeArea()
        }
        .onAppear { checks.refresh(bundledTool: model.bundledTool) }
        // Back from Safari's settings or Terminal: check again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checks.refresh(bundledTool: model.bundledTool)
        }
        .onDisappear { UserDefaults.standard.set(true, forKey: Welcome.doneKey) }
    }

    @ViewBuilder private var pageView: some View {
        switch page {
        case .installed: installed
        case .safari: safari
        case .agent: agent
        case .firstImport: firstImport
        }
    }

    // MARK: pages

    private var installed: some View {
        HStack(alignment: .center, spacing: 36) {
            Image("Logo").resizable().renderingMode(.template).scaledToFit().frame(width: 170, height: 170)
                .foregroundStyle(Color.accentColor)
                .shadow(color: .accentColor.opacity(0.25), radius: 18, y: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 20) {
                PageTitle(eyebrow: UserDefaults.standard.bool(forKey: Welcome.launchArgument) ? "Latchkey \(version) is installed" : "Welcome to Latchkey",
                          title: "Secrets out of .env files.",
                          subtitle: "Your projects keep latchkey:// references. Latchkey keeps the values in your Keychain and fills them in when a command starts.")
                VStack(alignment: .leading, spacing: 10) {
                    CheckRow(state: checks.inApplications ? .done : .attention,
                             text: checks.inApplications ? "In your Applications folder" : "Move Latchkey to Applications, so Safari and updates find it")
                    CheckRow(state: toolState, text: toolText)
                    if checks.tool == .missing, model.bundledTool != nil {
                        Button("Install Command Line Tool") {
                            model.installCommandLineTool()
                            checks.refresh(bundledTool: model.bundledTool)
                        }
                        .controlSize(.small).padding(.leading, 32)
                    }
                    if checks.onPath == false, checks.tool != .missing {
                        CopyLine(text: "echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> \(profileFile)",
                                 note: "~/.local/bin isn't on your PATH. Add it, then open a new Terminal window:")
                            .padding(.leading, 32)
                    }
                    CheckRow(state: model.problem != nil ? .attention : (model.synced ? .done : .info),
                             text: model.problem != nil ? "The keychain needs attention: see the sidebar"
                                 : (model.synced ? "iCloud Keychain is on: items sync to your Macs"
                                    : "Items stay on this Mac (iCloud Keychain isn't available to this copy)"))
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var safari: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageTitle(eyebrow: "Optional", title: "Save keys where you make them.",
                      subtitle: "Latchkey for Safari spots a new API key on the page where you made it and saves it when you say so, so it never sits in a note or a file. It can also fill a key into a deployment's settings, after you approve.")
            VStack(alignment: .leading, spacing: 10) {
                CheckRow(state: checks.safariOn == true ? .done : .info,
                         text: checks.safariOn == true ? "Latchkey for Safari is on" : "Turn it on in Safari › Settings › Extensions: tick Latchkey")
                Text("Safari asks which websites it may run on. Latchkey never turns it on for you.")
                    .font(.callout).foregroundStyle(.secondary).padding(.leading, 32)
            }
            Button("Open Safari Settings") {
                SFSafariApplication.showPreferencesForExtension(withIdentifier: Welcome.safariExtensionID) { _ in }
            }
            .disabled(checks.safariOn == true)
            Spacer()
        }
    }

    private var agent: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageTitle(eyebrow: "Optional", title: "Connect your coding agent.",
                      subtitle: "Agents get Latchkey's tools over MCP: they can run commands with your secrets filled in, and read only what you've marked safe or approved.")
            CopyLine(text: Welcome.agentCommand, note: "For Claude Code, run this once in Terminal:")
            Text("Other agents: point their MCP settings at ~/.local/bin/latchkey with the argument mcp.")
                .font(.callout).foregroundStyle(.secondary)
            Link("Coding agents guide", destination: URL(string: "https://latchkey.snackstud.io/developers/agents.html")!)
                .font(.callout)
            Spacer()
        }
    }

    private var firstImport: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageTitle(eyebrow: "Last step", title: "Bring in your first .env file.",
                      subtitle: "Choose a file and review every line before anything is saved. Latchkey places each value in its project and environment, and can replace the values in the file with references.")
            Button("Choose a .env File…") {
                close()
                openWindow(id: "main")
                model.chooseImportFile()
            }
            .buttonStyle(.borderedProminent)
            Text("Or later: drop a .env file on the Latchkey window, or run latchkey import .env.local --dry-run.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Page.allCases, id: \.self) { p in
                    Capsule().fill(p == page ? Color.accentColor : Color.primary.opacity(0.15))
                        .frame(width: p == page ? 20 : 7, height: 7)
                }
            }
            .animation(.spring(response: 0.35), value: page)
            .accessibilityElement().accessibilityLabel("Step \(page.rawValue + 1) of \(Page.allCases.count)")
            Spacer()
            if page != .installed {
                Button("Back") { go(-1) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if page == .firstImport {
                Button("Start Using Latchkey") { close() }.keyboardShortcut(.defaultAction)
            } else {
                if page != .installed { Button("Not Now") { go(1) }.buttonStyle(.plain).foregroundStyle(.secondary) }
                Button(page == .installed ? "Get Started" : "Continue") { go(1) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.top, 16)
    }

    // MARK: helpers

    /// The login file of the person's shell, for the PATH line.
    private var profileFile: String {
        let shell = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        return shell.hasSuffix("/bash") ? "~/.bash_profile" : "~/.zprofile"
    }

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    private var toolState: CheckRow.State {
        switch checks.tool {
        case .linked, .development: return checks.onPath == nil ? .pending : (checks.onPath == true ? .done : .attention)
        case .missing, .inTheWay: return .attention
        }
    }

    private var toolText: String {
        switch checks.tool {
        case .linked, .development:
            if checks.onPath == nil { return "latchkey and lk are in ~/.local/bin; checking your PATH…" }
            return checks.onPath == true ? "latchkey and lk are ready in Terminal" : "latchkey and lk are in ~/.local/bin, which isn't on your PATH"
        case .missing: return "The latchkey command isn't installed yet"
        case .inTheWay: return "~/.local/bin/latchkey is another file; Latchkey left it alone"
        }
    }

    private func go(_ delta: Int) {
        let next = min(max(page.rawValue + delta, 0), Page.allCases.count - 1)
        forward = delta > 0
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { page = Page(rawValue: next)! }
    }

    private func close() {
        UserDefaults.standard.set(true, forKey: Welcome.doneKey)
        dismissWindow(id: Welcome.windowID)
    }
}

/// Help › Welcome to Latchkey.
struct WelcomeCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Welcome to Latchkey") {
            openWindow(id: Welcome.windowID)
            NSApp.activate()
        }
    }
}

private struct PageTitle: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased()).font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(Color.accentColor)
            Text(title).font(.system(size: 28, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CheckRow: View {
    enum State { case done, attention, info, pending }
    let state: State
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch state {
                case .pending: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .attention: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                case .info: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                }
            }
            .font(.title3).frame(width: 22)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A command to run, with a Copy button.
private struct CopyLine: View {
    let text: String
    let note: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(text).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5)))
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                .accessibilityLabel("Copy command")
            }
        }
    }
}
#endif
