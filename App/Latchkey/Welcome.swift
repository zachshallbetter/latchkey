import AppKit
import LatchkeyCore
import SwiftUI

/// Pistachio's welcome window, which walks through the choices only the user can make: what quitting does, and whether
/// to connect the command-line tool and Safari. It opens on a new Mac (`AppPreferences.needsWelcome`) and from
/// Settings › About. Closing it early counts as done; everything it asks is in Settings too.
struct WelcomeView: View {
    static let size = CGSize(width: 720, height: 540)

    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var page: Page
    @State private var forward = true

    enum Page: Int, CaseIterable {
        case welcome, quitting, tools, ready
    }

    init(model: AppModel, startPage: Page = .welcome) {
        self.model = model
        _page = State(initialValue: startPage)
    }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [WelcomeTheme.accent.opacity(0.16), WelcomeTheme.accent.opacity(0)],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()

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
        .focusEffectDisabled()
        .onDisappear { AppPreferences().finishWelcome() }
    }

    @ViewBuilder private var pageView: some View {
        switch page {
        case .welcome: WelcomePage(model: model)
        case .quitting: QuittingPage(model: model)
        case .tools: ToolsPage(model: model)
        case .ready: ReadyPage()
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Page.allCases, id: \.self) { p in
                    Capsule()
                        .fill(p == page ? WelcomeTheme.accent : Color.primary.opacity(0.15))
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
        case .quitting, .tools: "Continue"
        case .ready: "Start Using Pistachio"
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

/// Pistachio green, from the icon's kernel: brighter in dark mode, deeper in light mode so text on it stays readable.
enum WelcomeTheme {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.69, green: 0.75, blue: 0.36, alpha: 1)
            : NSColor(srgbRed: 0.36, green: 0.44, blue: 0.15, alpha: 1)
    })
    /// The primary button's fill, dark enough for white text in both appearances.
    static let buttonFill = Color(nsColor: NSColor(srgbRed: 0.33, green: 0.42, blue: 0.13, alpha: 1))
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

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.75))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background {
                    Capsule(style: .continuous)
                        .fill(isEnabled ? WelcomeTheme.buttonFill.opacity(configuration.isPressed ? 0.85 : 1) : Color.secondary.opacity(0.45))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(WelcomeTheme.accent)
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
    let model: AppModel
    @State private var shown = 0

    private var inApplications: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 36) {
            PistachioHero(size: 210)

            VStack(alignment: .leading, spacing: 22) {
                PageTitle(
                    eyebrow: "Welcome to Pistachio",
                    title: Text("Your secrets. ") + Text("In a shell.").foregroundColor(WelcomeTheme.accent),
                    subtitle: "Project files keep references. Pistachio keeps the values in your keychain and fills them in when a command starts."
                )

                VStack(alignment: .leading, spacing: 10) {
                    checkRow(0, done: inApplications,
                             inApplications ? "In your Applications folder" : "Move Pistachio to Applications so Safari and the command-line tool can find it")
                    checkRow(1, done: model.synced,
                             model.synced ? "Values sync through iCloud Keychain to your other Macs" : "iCloud Keychain is off, so values stay on this Mac")
                    checkRow(2, done: true, "Touch ID asks before any program or agent reads a value")
                }
            }
        }
        .frame(maxHeight: .infinity)
        .task {
            // Tick the rows in one after another.
            for i in 1...3 {
                try? await Task.sleep(for: .milliseconds(280))
                withAnimation(.spring(response: 0.4)) { shown = i }
            }
        }
    }

    private func checkRow(_ index: Int, done: Bool, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(done ? Color.green : Color.orange)
                .font(.title3)
                .frame(width: 22)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .opacity(shown > index ? 1 : 0)
        .offset(x: shown > index ? 0 : -8)
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

private struct ToolsPage: View {
    let model: AppModel
    @State private var safariOn: Bool?
    @State private var safariError: String?
    @State private var toolInstalled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageTitle(eyebrow: "Last step", title: Text("Connect your tools"),
                      subtitle: "Both are optional. Every value they ask for is still approved here.")

            OptionRow(symbol: "terminal", title: "Command-line tool", detail: toolDetail) {
                #if LATCHKEY_APP_STORE
                Link("Get the Tool…", destination: AppModel.commandLineToolPage)
                #else
                if toolInstalled {
                    Done(text: "Installed")
                } else if model.bundledTool != nil {
                    Button("Install") {
                        model.installCommandLineTool()
                        refreshTool()
                    }
                } else {
                    Link("Setup Help…", destination: AppModel.commandLineToolPage)
                }
                #endif
            }

            OptionRow(symbol: "safari", title: "Pistachio for Safari",
                      detail: safariError ?? "Saves a new API key from the page that shows it, and fills saved keys into the sites they belong to.") {
                if safariOn == true {
                    Done(text: "On")
                } else {
                    Button("Turn On in Safari…") {
                        safariError = nil
                        SafariExtension.openSettings { safariError = $0 }
                    }
                }
            }
        }
        .onAppear {
            refreshTool()
            refreshSafari()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshSafari() }
    }

    private var toolDetail: String {
        #if LATCHKEY_APP_STORE
        "A free, separate download. `pst run -- npm start` starts a command with its values filled in."
        #else
        toolInstalled
            ? "`pst run -- npm start` starts a command with its values filled in. Make sure ~/.local/bin is on your PATH."
            : "Links `pst` and `pistachio` in ~/.local/bin, so `pst run -- npm start` starts a command with its values filled in."
        #endif
    }

    /// Installed when the short name links to this copy of the tool, the way Install leaves it.
    private func refreshTool() {
        guard let tool = model.bundledTool, let link = AppModel.toolLinks.first else { toolInstalled = model.installedTool != nil; return }
        toolInstalled = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == tool.path
    }

    private func refreshSafari() { SafariExtension.state { safariOn = $0 } }
}

private struct ReadyPage: View {
    #if !LATCHKEY_APP_STORE
    @State private var checksForUpdates = AppUpdater.shared.controller?.updater.automaticallyChecksForUpdates ?? false
    #endif

    var body: some View {
        HStack(alignment: .center, spacing: 36) {
            PistachioHero(size: 170, settled: true)
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
                .foregroundStyle(WelcomeTheme.accent)
                .frame(width: 26)
            Text(LocalizedStringKey(text)).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Parts

private struct ChoiceCard: View {
    let symbol: String
    let title: String
    let detail: String
    let badge: String?
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 26))
                        .foregroundStyle(selected ? WelcomeTheme.accent : .secondary)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? WelcomeTheme.accent : Color.secondary.opacity(0.5))
                }
                HStack(spacing: 8) {
                    Text(title).font(.title3.weight(.semibold))
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(WelcomeTheme.accent.opacity(0.15)))
                            .foregroundStyle(WelcomeTheme.accent)
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
                .fill(selected ? WelcomeTheme.accent.opacity(0.08) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? WelcomeTheme.accent : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A tinted row: a symbol, a title and a line of detail, with its control on the right.
private struct OptionRow<Control: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(WelcomeTheme.accent)
                .frame(width: 28)
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

/// The app icon, settling into place as the welcome opens.
private struct PistachioHero: View {
    let size: CGFloat
    var settled = false
    @State private var shown = false

    var body: some View {
        BrandAppIcon(size: size)
            .scaleEffect(shown ? 1 : 0.9)
            .rotationEffect(.degrees(shown ? 0 : -6))
            .shadow(color: WelcomeTheme.accent.opacity(0.3), radius: 26, y: 12)
            .onAppear {
                if settled { shown = true; return }
                withAnimation(.spring(response: 0.8, dampingFraction: 0.62).delay(0.3)) { shown = true }
            }
    }
}
