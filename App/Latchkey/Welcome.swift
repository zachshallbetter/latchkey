import AppKit
import LatchkeyCore
import SwiftUI

/// Pistachio's welcome window, which walks through the choices only the user can make: its icon and theme (applied as
/// they're chosen, to the Dock, the menu bar and this window), what quitting does, the browser extension, and connecting
/// coding agents. It opens on a new Mac (`AppPreferences.needsWelcome`) and from Settings › About. Closing it early
/// counts as done; everything it asks is in Settings too.
struct WelcomeView: View {
    static let size = CGSize(width: 720, height: 540)

    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppPreferences.Key.icon) private var icon = AppPreferences.Icon.pistachio.rawValue
    @State private var page: Page
    @State private var forward = true

    enum Page: Int, CaseIterable {
        case welcome, look, quitting, browsers, agents, ready
    }

    init(model: AppModel, startPage: Page = .welcome) {
        self.model = model
        _page = State(initialValue: startPage)
    }

    private var theme: WelcomeTheme { WelcomeTheme(icon: AppPreferences.Icon(preference: icon)) }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [theme.accent.opacity(0.16), theme.accent.opacity(0)], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.3), value: icon)

            VStack(spacing: 0) {
                ZStack {
                    pageView
                        .id(page)
                        .transition(.asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
                        ))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()

                footer
            }
            .padding(.horizontal, 44)
            .padding(.top, 44)
            .padding(.bottom, 26)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.welcomeTheme, theme)
        .focusEffectDisabled()
        .onDisappear { AppPreferences().finishWelcome() }
    }

    @ViewBuilder private var pageView: some View {
        switch page {
        case .welcome: WelcomePage()
        case .look: LookPage()
        case .quitting: QuittingPage(model: model)
        case .browsers: BrowsersPage()
        case .agents: AgentsPage(model: model)
        case .ready: ReadyPage()
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Page.allCases, id: \.self) { p in
                    Capsule()
                        .fill(p == page ? theme.accent : Color.primary.opacity(0.15))
                        .frame(width: p == page ? 20 : 7, height: 7)
                }
            }
            .animation(.spring(response: 0.35), value: page)
            .accessibilityElement()
            .accessibilityLabel("Page \(page.rawValue + 1) of \(Page.allCases.count)")

            Spacer()

            if page != .welcome, page != .ready {
                Button("Back") { go(-1) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
            }
            Button(primaryTitle) { primary() }
                .buttonStyle(WelcomePrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 18)
    }

    private var primaryTitle: String {
        switch page {
        case .welcome: "Get Started"
        case .ready: "Start Using Pistachio"
        default: "Continue"
        }
    }

    private func primary() {
        if page == .ready {
            AppPreferences().finishWelcome()
            dismiss()
        } else {
            go(1)
        }
    }

    private func go(_ delta: Int) {
        let next = min(max(page.rawValue + delta, 0), Page.allCases.count - 1)
        forward = delta > 0
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { page = Page(rawValue: next) ?? page }
    }
}

/// The welcome's colours follow the chosen icon: pistachio green from the kernel, or the key's blue. Brighter in dark
/// mode, deeper in light mode so text in them stays readable; the button fill is dark enough for white text in both.
struct WelcomeTheme: Equatable {
    let accent: Color
    let buttonFill: Color

    init(icon: AppPreferences.Icon) {
        switch icon {
        case .pistachio:
            accent = Self.dynamic(dark: (0.69, 0.75, 0.36), light: (0.36, 0.44, 0.15))
            buttonFill = Color(nsColor: NSColor(srgbRed: 0.33, green: 0.42, blue: 0.13, alpha: 1))
        case .key:
            accent = Self.dynamic(dark: (0.42, 0.64, 1.0), light: (0.10, 0.40, 0.85))
            buttonFill = Color(nsColor: NSColor(srgbRed: 0.10, green: 0.38, blue: 0.80, alpha: 1))
        }
    }

    private static func dynamic(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

private struct WelcomeThemeKey: EnvironmentKey {
    static let defaultValue = WelcomeTheme(icon: .pistachio)
}

extension EnvironmentValues {
    var welcomeTheme: WelcomeTheme {
        get { self[WelcomeThemeKey.self] }
        set { self[WelcomeThemeKey.self] = newValue }
    }
}

/// A filled capsule, as on Pistachio's website.
struct WelcomePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration)
    }

    /// A view, so it can read whether the button is enabled.
    private struct Label: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.welcomeTheme) private var theme

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.75))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background {
                    Capsule(style: .continuous)
                        .fill(isEnabled ? theme.buttonFill.opacity(configuration.isPressed ? 0.85 : 1) : Color.secondary.opacity(0.45))
                }
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

// MARK: - Pages

private struct PageTitle: View {
    var eyebrow: String?
    var title: Text
    var subtitle: String?
    @Environment(\.welcomeTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(theme.accent)
            }
            title
                .font(.system(size: 30, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct WelcomePage: View {
    @Environment(\.welcomeTheme) private var theme

    private var inApplications: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 32) {
            PistachioHero(size: 250, open: false)

            VStack(alignment: .leading, spacing: 22) {
                PageTitle(eyebrow: "Welcome to Pistachio",
                          title: Text("Let’s crack it ") + Text("open.").foregroundColor(theme.accent))
                if !inApplications {
                    Label("Move Pistachio to Applications so Safari and the command-line tool can find it.",
                          systemImage: "exclamationmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct LookPage: View {
    @AppStorage(AppPreferences.Key.icon) private var icon = AppPreferences.Icon.pistachio.rawValue
    @AppStorage(AppPreferences.Key.appearance) private var appearance = "system"

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageTitle(title: Text("Make it yours"),
                      subtitle: "The Dock, the menu bar and this window change as you choose.")

            HStack(spacing: 14) {
                ForEach(AppPreferences.Icon.allCases, id: \.rawValue) { choice in
                    ChoiceCard(image: AppBranding.image(for: choice), title: choice.title,
                               detail: choice == .pistachio ? "Pistachio green, with the nut in its shell." : "The original key, in blue.",
                               badge: nil, selected: AppPreferences.Icon(preference: icon) == choice) {
                        withAnimation(.easeInOut(duration: 0.25)) { icon = choice.rawValue }
                    }
                }
            }

            OptionRow(symbol: "circle.lefthalf.filled", title: "Theme", detail: "Light, dark, or the same as macOS.") {
                Picker("Theme", selection: $appearance) {
                    Text("Follow macOS").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

private struct QuittingPage: View {
    let model: AppModel
    @AppStorage(AppPreferences.Key.keepRunningFromDock) private var keepRunning = true
    @State private var atLogin = false
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageTitle(title: Text("When you quit Pistachio…"), subtitle: "You can change this any time in Settings.")

            HStack(spacing: 14) {
                ChoiceCard(symbol: "menubar.rectangle", title: "Stay in the menu bar",
                           detail: "Closes the window and keeps answering your commands and agents, so they never wait for it to open.",
                           badge: "Recommended", selected: keepRunning) { keepRunning = true }
                ChoiceCard(symbol: "power", title: "Quit completely",
                           detail: "Stops Pistachio. The command-line tool opens it again when a command needs a value.",
                           badge: nil, selected: !keepRunning) { keepRunning = false }
            }

            OptionRow(symbol: "person.crop.circle.badge.clock", title: "Open Pistachio at login",
                      detail: loginError ?? "So your commands and agents can reach it as soon as you sign in.") {
                Toggle("Open Pistachio at login", isOn: Binding(get: { atLogin }, set: { on in
                    loginError = model.setOpensAtLogin(on)
                    atLogin = model.opensAtLogin
                }))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
        .onAppear { atLogin = model.opensAtLogin }
    }
}

/// The browsers on this Mac, each with what Pistachio can do in it today and, where it can't yet, why.
private struct BrowsersPage: View {
    @State private var safariOn: Bool?
    @State private var safariError: String?

    private struct Browser: Identifiable {
        let id: String
        let name: String
        let app: URL
    }

    private static let known: [(id: String, name: String)] = [
        ("com.apple.Safari", "Safari"), ("com.google.Chrome", "Google Chrome"),
        ("com.brave.Browser", "Brave"), ("org.mozilla.firefox", "Firefox"),
    ]

    private let browsers: [Browser] = known.compactMap { b in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: b.id).map { Browser(id: b.id, name: b.name, app: $0) }
    }

    private let defaultBrowser: String? = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        .flatMap { Bundle(url: $0)?.bundleIdentifier }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(title: Text("Save keys from your browser"),
                      subtitle: "Pistachio offers to keep a new API key when a page shows you one. Each save and fill asks first.")

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(browsers) { browser in
                        OptionRow(image: NSWorkspace.shared.icon(forFile: browser.app.path),
                                  title: browser.name + (browser.id == defaultBrowser ? "  ·  your default browser" : ""),
                                  detail: detail(browser.id)) { control(browser.id) }
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func detail(_ id: String) -> String {
        switch id {
        case "com.apple.Safari":
            safariError ?? "Pistachio for Safari comes with the app. Safari asks you to turn it on in its own settings."
        case "com.google.Chrome":
            "Pistachio for Chrome is in testing and isn’t in the Chrome Web Store yet. It will appear here when it is."
        case "org.mozilla.firefox":
            "Pistachio for Firefox is in testing. Firefox installs only add-ons Mozilla has signed, so it waits for that."
        default:
            "Not yet. Before it answers, Pistachio checks which browser is asking, and that check hasn’t been reviewed for Brave."
        }
    }

    @ViewBuilder private func control(_ id: String) -> some View {
        if id == "com.apple.Safari" {
            if safariOn == true {
                Done(text: "On")
            } else {
                Button("Turn On in Safari…") {
                    safariError = nil
                    SafariExtension.openSettings { safariError = $0 }
                }
            }
        } else {
            Text(id == "com.brave.Browser" ? "Not supported" : "Coming soon")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func refresh() { SafariExtension.state { safariOn = $0 } }
}

/// The command-line tool, then each coding agent found on this Mac, connected with one click: Pistachio's MCP server
/// and, where the agent reads skills, its skill (AgentSetup).
private struct AgentsPage: View {
    let model: AppModel
    @State private var toolInstalled = false
    @State private var statuses: [AgentSetup.Agent: AgentSetup.Status] = [:]
    @State private var errors: [AgentSetup.Agent: String] = [:]
    @State private var working: Set<AgentSetup.Agent> = []

    private static let guide = URL(string: "https://latchkey.snackstud.io/developers/agents.html")!
    private var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }
    private var found: [AgentSetup.Agent] { AgentSetup.Agent.allCases.filter { (statuses[$0] ?? .notFound) != .notFound } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                PageTitle(eyebrow: "Last step", title: Text("Connect your agents"),
                          subtitle: "Agents run commands through Pistachio and never hold a value. You still approve what they use.")
                #if !LATCHKEY_APP_STORE
                if found.filter({ statuses[$0] == .available }).count > 1, mcpTool != nil {
                    Button("Add to All") { found.filter { statuses[$0] == .available }.forEach(connect) }
                }
                #endif
            }

            ScrollView {
                VStack(spacing: 10) {
                    OptionRow(symbol: "terminal", title: "Command-line tool", detail: toolDetail) { toolControl }
                    #if LATCHKEY_APP_STORE
                    OptionRow(symbol: "sparkles", title: "Coding agents",
                              detail: "The guide shows how to add Pistachio’s skill and MCP server to Claude Code, Codex, Cursor and others.") {
                        Link("Setup Guide…", destination: Self.guide)
                    }
                    #else
                    if found.isEmpty {
                        OptionRow(symbol: "sparkles", title: "No coding agents found",
                                  detail: "Pistachio looked for Claude Code, Claude Desktop, Codex, Cursor and Gemini CLI.") {
                            Link("Setup Guide…", destination: Self.guide)
                        }
                    }
                    ForEach(found, id: \.self) { agent in
                        OptionRow(symbol: symbol(agent), title: agent.title, detail: errors[agent] ?? detail(agent)) { control(agent) }
                    }
                    #endif
                }
            }
            .scrollIndicators(.automatic)
        }
        .onAppear(perform: refresh)
    }

    // MARK: command-line tool

    private var toolDetail: String {
        #if LATCHKEY_APP_STORE
        "A free, separate download. `pst run -- npm start` starts a command with its values filled in."
        #else
        toolInstalled
            ? "`pst run -- npm start` starts a command with its values filled in. Make sure ~/.local/bin is on your PATH."
            : "Links `pst` and `pistachio` in ~/.local/bin, so `pst run -- npm start` starts a command with its values filled in."
        #endif
    }

    @ViewBuilder private var toolControl: some View {
        #if LATCHKEY_APP_STORE
        Link("Get the Tool…", destination: AppModel.commandLineToolPage)
        #else
        if toolInstalled {
            Done(text: "Installed")
        } else if model.bundledTool != nil {
            Button("Install") {
                model.installCommandLineTool()
                refresh()
            }
        } else {
            Link("Setup Help…", destination: AppModel.commandLineToolPage)
        }
        #endif
    }

    // MARK: agents

    /// The command agents start for the MCP server: the `pst` link when there is one (it survives moving the app),
    /// else the copy inside the app or one installed separately.
    private var mcpTool: URL? {
        if let link = AppModel.toolLinks.first, FileManager.default.isExecutableFile(atPath: link.path) { return link }
        return model.bundledTool ?? model.installedTool
    }

    private func symbol(_ agent: AgentSetup.Agent) -> String {
        switch agent {
        case .claudeCode, .codex, .gemini: "chevron.left.forwardslash.chevron.right"
        case .claudeDesktop: "bubble.left.and.text.bubble.right"
        case .cursor: "cursorarrow.rays"
        }
    }

    private func detail(_ agent: AgentSetup.Agent) -> String {
        switch agent {
        case .claudeCode: "Adds the Pistachio skill and MCP server for all your projects."
        case .claudeDesktop: "Adds Pistachio’s MCP server. Quit and reopen Claude to load it."
        case .codex: "Adds the Pistachio skill and MCP server to ~/.codex."
        case .cursor: "Adds Pistachio’s MCP server to ~/.cursor/mcp.json."
        case .gemini: "Adds Pistachio’s MCP server to ~/.gemini/settings.json."
        }
    }

    @ViewBuilder private func control(_ agent: AgentSetup.Agent) -> some View {
        if statuses[agent] == .connected {
            Done(text: "Added")
        } else if working.contains(agent) {
            ProgressView().controlSize(.small)
        } else {
            Button("Add") { connect(agent) }
                .disabled(mcpTool == nil)
                .help(mcpTool == nil ? "Install the command-line tool first." : "")
        }
    }

    private func connect(_ agent: AgentSetup.Agent) {
        guard let tool = mcpTool else { return }
        let skill = Bundle.main.url(forResource: "SKILL", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        guard let skill else { errors[agent] = "This copy of Pistachio doesn’t include the agent skill."; return }
        errors[agent] = nil
        working.insert(agent)
        let home = home
        Task.detached {
            var failure: String?
            do {
                try AgentSetup.connect(agent, home: home, tool: tool, skill: skill)
                if agent == .claudeCode { failure = Self.runClaude(AgentSetup.claudeCodeArguments(tool: tool), home: home) }
            } catch {
                failure = "\(error)"
            }
            await MainActor.run {
                working.remove(agent)
                errors[agent] = failure
                refresh()
            }
        }
    }

    /// Runs Claude Code's own command, which owns its state file. nil when it worked, else what to tell the person.
    nonisolated private static func runClaude(_ arguments: [String], home: URL) -> String? {
        let places = [".local/bin/claude", ".claude/local/claude"].map { home.appendingPathComponent($0).path }
            + ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let manual = "Run `claude " + arguments.joined(separator: " ") + "` in Terminal to finish."
        guard let claude = places.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return "Couldn’t find the claude command. " + manual
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "Couldn’t start claude. " + manual }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? nil : "claude didn’t accept the change. " + manual
    }

    private func refresh() {
        if let tool = model.bundledTool, let link = AppModel.toolLinks.first {
            toolInstalled = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == tool.path
        } else {
            toolInstalled = model.installedTool != nil
        }
        #if !LATCHKEY_APP_STORE
        let home = home
        statuses = Dictionary(uniqueKeysWithValues: AgentSetup.Agent.allCases.map { ($0, AgentSetup.status($0, home: home)) })
        #endif
    }
}

private struct ReadyPage: View {
    #if !LATCHKEY_APP_STORE
    @State private var checksForUpdates = AppUpdater.shared.controller?.updater.automaticallyChecksForUpdates ?? false
    #endif
    @Environment(\.welcomeTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 32) {
            PistachioHero(size: 230, open: true)
            VStack(alignment: .leading, spacing: 20) {
                PageTitle(title: Text("Pistachio is ready."))
                VStack(alignment: .leading, spacing: 14) {
                    tip("plus.circle.fill", "Press ⌘N to add a token, or drop a .env file on the window to import it.")
                    tip("terminal.fill", "Start commands with `pst run --` and their values are filled in.")
                    tip("touchid", "Pistachio asks before anything reads a value. Allow once, or a folder for a while.")
                    tip("gearshape.fill", "Change anything later in Pistachio ▸ Settings (⌘,).")
                }
                #if !LATCHKEY_APP_STORE
                if let updater = AppUpdater.shared.controller?.updater {
                    Toggle("Check for updates automatically", isOn: Binding(get: { checksForUpdates }, set: { on in
                        updater.automaticallyChecksForUpdates = on
                        checksForUpdates = updater.automaticallyChecksForUpdates
                    }))
                    .padding(.top, 4)
                }
                #endif
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(theme.accent)
                .frame(width: 26)
            Text(LocalizedStringKey(text)).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Parts

private struct ChoiceCard: View {
    var symbol: String? = nil
    var image: NSImage? = nil
    let title: String
    let detail: String
    let badge: String?
    let selected: Bool
    var action: () -> Void
    @Environment(\.welcomeTheme) private var theme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 48, height: 48)
                    } else if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 26))
                            .foregroundStyle(selected ? theme.accent : .secondary)
                    }
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? theme.accent : Color.secondary.opacity(0.5))
                }
                HStack(spacing: 8) {
                    Text(title).font(.title3.weight(.semibold))
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.accent.opacity(0.15)))
                            .foregroundStyle(theme.accent)
                    }
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 170, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? theme.accent.opacity(0.08) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? theme.accent : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A tinted row: a symbol or an app's icon, a title and a line of detail, with its control on the right.
private struct OptionRow<Control: View>: View {
    var symbol: String? = nil
    var image: NSImage? = nil
    let title: String
    let detail: String
    @ViewBuilder var control: () -> Control
    @Environment(\.welcomeTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 30, height: 30)
                } else if let symbol {
                    Image(systemName: symbol).font(.title2).foregroundStyle(theme.accent)
                }
            }
            .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(LocalizedStringKey(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

private struct Done: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .font(.callout.weight(.medium))
    }
}

/// The pistachio, cracked on the welcome and open on the last page; the key icon instead when that's the choice. It
/// settles into place as the page opens.
private struct PistachioHero: View {
    let size: CGFloat
    let open: Bool
    @AppStorage(AppPreferences.Key.icon) private var icon = AppPreferences.Icon.pistachio.rawValue
    @Environment(\.welcomeTheme) private var theme
    @State private var shown = false

    var body: some View {
        Group {
            if AppPreferences.Icon(preference: icon) == .key {
                BrandAppIcon(size: size * 0.8)
            } else {
                Image(open ? "WelcomePistachioOpen" : "WelcomePistachio")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(shown ? 1 : 0.9)
        .rotationEffect(.degrees(shown ? 0 : (open ? 6 : -6)))
        .shadow(color: theme.accent.opacity(0.35), radius: 30, y: 14)
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.62).delay(0.25)) { shown = true }
        }
    }
}
