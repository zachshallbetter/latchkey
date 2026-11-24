import AppKit
import LatchkeyCore
import SafariServices
import ServiceManagement
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    /// The sections shown: Membership only where there's a plan to show (the direct build links to the App Store
    /// version; the store build once Pro is on sale).
    static var visible: [SettingsSection] {
        #if LATCHKEY_APP_STORE
        return allCases.filter { $0 != .membership || ProEntitlement.onSale }
        #else
        return allCases
        #endif
    }

    case general, privacy, storage, developer, membership, about
    var id: Self { self }
    var title: String {
        switch self {
        case .general: return "General"
        case .privacy: return "Privacy"
        case .storage: return "Storage"
        case .developer: return "Developer"
        case .membership: return "Membership"
        case .about: return "About"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .privacy: return "hand.raised"
        case .storage: return "externaldrive"
        case .developer: return "terminal"
        case .membership: return "star"
        case .about: return "info.circle"
        }
    }
}

/// The Settings window: one tab per section, each a short form.
struct SettingsWindow: View {
    @Bindable var model: AppModel
    var body: some View {
        TabView(selection: $model.settingsSection) {
            ForEach(SettingsSection.visible) { section in
                SettingsView(model: model, section: section)
                    .tabItem { Label(section.title, systemImage: section.symbol) }
                    .tag(section)
            }
        }
        .frame(width: 620, height: 560)
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    var section: SettingsSection
    @AppStorage(AppPreferences.Key.appearance) private var appearance = "system"
    @AppStorage(AppPreferences.Key.icon) private var icon = AppPreferences.Icon.pistachio.rawValue
    @AppStorage(AppPreferences.Key.clipboardSeconds) private var clipboardSeconds = AppPreferences.defaultClipboardSeconds
    @AppStorage(AppPreferences.Key.revealSeconds) private var revealSeconds = AppPreferences.defaultRevealSeconds
    @AppStorage(AppPreferences.Key.hideOnDeactivate) private var hideOnDeactivate = true
    @AppStorage(AppPreferences.Key.lockApp) private var lockApp = true
    @AppStorage(AppPreferences.Key.lockAfterMinutes) private var lockAfterMinutes = AppPreferences.defaultLockMinutes
    @AppStorage(AppPreferences.Key.keepRunningFromDock) private var keepRunningFromDock = true
    @State private var atLogin = false
    @State private var loginError: String?
    #if !LATCHKEY_APP_STORE
    @State private var checksForUpdates = false
    #endif

    var body: some View {
        Form {
            switch section {
            case .general: general
            case .privacy: privacy
            case .storage: storage
            case .developer: developer
            case .membership: MembershipSettings()
            case .about: about
            }
        }
        .formStyle(.grouped)
        .onAppear {
            atLogin = model.opensAtLogin
            #if !LATCHKEY_APP_STORE
            checksForUpdates = AppUpdater.shared.controller?.updater.automaticallyChecksForUpdates ?? false
            #endif
            model.checkLegacy()
        }
    }

    @ViewBuilder private var general: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appearance) {
                Text("Follow macOS").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            Picker("Icon", selection: Binding(get: { AppPreferences.Icon(preference: icon).rawValue }, set: { icon = $0 })) {
                ForEach(AppPreferences.Icon.allCases, id: \.rawValue) { choice in
                    Label {
                        Text(choice.title)
                    } icon: {
                        Image(nsImage: AppBranding.image(for: choice)).resizable().scaledToFit().frame(width: 28, height: 28)
                    }
                    .tag(choice.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            SettingsNote("Changes the Dock icon, menu bar symbol and marks inside the app. Finder and Safari keep the bundled Pistachio icon.")
            SettingsNote("Preferences are saved on this Mac. They do not change the settings on your other Macs.")
        }
        Section("Startup & Dock") {
            Toggle("Open Latchkey at login", isOn: Binding(get: { atLogin }, set: { on in
                loginError = model.setOpensAtLogin(on)
                atLogin = model.opensAtLogin
            }))
            if let loginError { Text(loginError).font(.callout).foregroundStyle(.red) }
            Toggle("Keep running in the menu bar when I quit", isOn: $keepRunningFromDock)
            SettingsNote("When enabled, quitting from the Dock or with ⌘Q closes the window and leaves Latchkey in the menu bar for your commands and agents. Quit in the menu bar panel always exits the app.")
        }
    }

    @ViewBuilder private var privacy: some View {
        Section("Lock") {
            Toggle("Lock Latchkey automatically", isOn: $lockApp)
            Picker("Lock after", selection: $lockAfterMinutes) {
                ForEach(AppPreferences.lockChoices, id: \.self) { Text($0 == 60 ? "1 hour away" : $0 == 1 ? "1 minute away" : "\($0) minutes away").tag($0) }
            }
            .disabled(!lockApp)
            Button("Lock Now") { model.lock(byHand: true) }
            SettingsNote("Latchkey locks when it opens, when your Mac sleeps or the screen locks, and after the time you choose here away from Latchkey. Touch ID or your Mac password unlocks it. The lock covers the window and the menu bar; requests from commands, agents and Safari keep asking for approval as before.")
        }
        Section("Values & Clipboard") {
            Picker("Clear copied values after", selection: $clipboardSeconds) {
                ForEach(AppPreferences.clipboardChoices, id: \.self) { Text("\($0) seconds").tag($0) }
            }
            SettingsNote("Copied values stay on this Mac and are marked for compatible clipboard managers to skip. Clearing leaves anything you copied afterward alone.")
            Picker("Hide revealed values after", selection: $revealSeconds) {
                ForEach(AppPreferences.revealChoices, id: \.self) { Text("\($0) seconds").tag($0) }
            }
            Toggle("Hide values when Latchkey loses focus", isOn: $hideOnDeactivate)
                .onChange(of: hideOnDeactivate) { _, on in if on { model.concealRevealedValues() } }
            Button("Hide Revealed Values Now") { model.concealRevealedValues() }
                .disabled(model.revealed.isEmpty && model.revealedVersions.isEmpty)
            SettingsNote("Timer changes apply the next time you copy or reveal a value. Revealing a value still asks for approval when required.")
        }
        Section("Approval & Grants") {
            LabeledContent("Approval method", value: model.broker.approver.method)
            SettingsNote("Allow Once authorizes one read request. Repeated reads need an explicit grant or an item set to No Approval. These preferences never bypass approval.")
            LabeledContent("Active grants", value: "\(model.grants.count)")
            Button("Review Grants…") { model.filter = .grants }
            SettingsNote("Revoking a grant stops future reads through it. It cannot recall a value already released to a process.")
        }
    }

    @ViewBuilder private var storage: some View {
        Section("Keychain") {
            LabeledContent("Where values live", value: model.store.location)
            SettingsNote(model.synced ? "Values use iCloud Keychain. Latchkey cannot verify delivery to another Mac; that Mac needs iCloud Keychain enabled and the same Apple Account." : "This copy uses the local login keychain. iCloud Keychain requires a properly signed copy of Latchkey and iCloud Keychain enabled on your Mac.")
            if model.synced && !model.legacyItems.isEmpty {
                LabeledContent("Items in this Mac’s login keychain", value: "\(model.legacyItems.count)")
                Button("Move to iCloud Keychain") { Task { await model.moveLegacyItems() } }
                SettingsNote("macOS may ask for your login password as older items move.")
            }
        }
        Section("Project Files") {
            #if LATCHKEY_APP_STORE
            SettingsNote("File access permits reading or rewriting selected project files. It does not authorize releasing secrets. macOS may retain access to a previously opened file until Latchkey quits.")
            if model.authorizedResources.isEmpty { Text("No files or folders remembered.").foregroundStyle(.secondary) }
            ForEach(model.authorizedResources) { resource in
                LabeledContent {
                    Button("Remove") { model.forgetFileAccess(resource.id) }
                        .accessibilityLabel("Remove access to \(resource.path)")
                } label: {
                    Text(resource.path).font(.callout.monospaced()).textSelection(.enabled)
                    if model.fileAccess?.isActive(resource.id) != true { Text("Unavailable; choose it again when connected.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Button("Allow Project Folder…") { model.chooseProjectFolder() }
            #else
            SettingsNote("The direct download uses your Mac user’s file permissions. You choose which project files to import or rewrite. Access to a file does not approve releasing a secret.")
            #endif
        }
    }

    @ViewBuilder private var developer: some View {
        Section("Command Line") {
            #if LATCHKEY_APP_STORE
            SettingsNote("The command-line tool, pistachio (pst for short), is a separate, signed download. It connects to this app through an authenticated App Group endpoint, and every value it asks for is approved here.")
            Link("Get the Command-Line Tool", destination: AppModel.commandLineToolPage)
            #else
            if let tool = model.bundledTool {
                LabeledContent("Bundled CLI", value: tool.lastPathComponent)
                Button("Install Command Line Tool…") { model.installCommandLineTool() }
                SettingsNote("Links pst and pistachio in ~/.local/bin to the copy inside the app, so they update with it. Existing files are left alone.")
            } else if let tool = model.installedTool {
                LabeledContent("Installed", value: (tool.path as NSString).abbreviatingWithTildeInPath)
                SettingsNote("Installed separately from this copy of Latchkey (by scripts/install.sh, Homebrew or the download), so update it the same way.")
            } else {
                Text("This copy of Latchkey has no command-line tool inside, and none is installed.").foregroundStyle(.secondary)
                Link("Command-line setup help", destination: SettingsLinks.support)
            }
            #endif
            SettingsNote("Commands run in your terminal. The command-line tool starts Latchkey when needed.")
        }
        SafariExtensionSettings()
        Section("Activity") {
            Button("View Activity") { model.filter = .activity }
            Button("Show Access Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.accessLog]) }
            SettingsNote("The log records access decisions and caller context. Command arguments use heuristic redaction; avoid putting credentials in arguments.")
        }
    }

    @ViewBuilder private var about: some View {
        Section("Latchkey") {
            LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
            Button("What's New in This Version…") { model.openWhatsNew() }
            #if LATCHKEY_APP_STORE
            LabeledContent("Distribution", value: "Mac App Store")
            SettingsNote("Updates are delivered through the Mac App Store.")
            #else
            LabeledContent("Distribution", value: "Direct download")
            if let updater = AppUpdater.shared.controller?.updater {
                Toggle("Check for updates automatically", isOn: Binding(get: { checksForUpdates }, set: { on in
                    updater.automaticallyChecksForUpdates = on
                    checksForUpdates = updater.automaticallyChecksForUpdates
                }))
                CheckForUpdatesButton(updater: AppUpdater.shared)
            } else { SettingsNote("Automatic updates are unavailable in this build.") }
            #endif
        }
        Section("Snack Studio") {
            if let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String, !copyright.isEmpty {
                LabeledContent("Copyright", value: copyright.replacingOccurrences(of: "Copyright ", with: ""))
            }
            LabeledContent("License", value: "Functional Source License 1.1")
            Link("latchkey.snackstud.io", destination: SettingsLinks.website)
        }
        Section("Help & Policies") {
            Link("Latchkey Help", destination: SettingsLinks.support)
            Link("Privacy Policy", destination: SettingsLinks.privacy)
            Link("Terms of Use", destination: SettingsLinks.terms)
            Link("Report a Security Issue", destination: URL(string: "mailto:latchkey@snackstud.io?subject=Security")!)
        }
    }
}

/// Latchkey for Safari ships inside the app; Safari lists it once the app has run, and the user turns it on in Safari's
/// own settings. Apple offers no way for an app to turn its extension on, only to open that page with it selected.
private struct SafariExtensionSettings: View {
    /// nil while checking, or when Safari couldn't say (it hasn't seen this copy's extension yet).
    @State private var enabled: Bool?
    @State private var error: String?
    private static let identifier = (Bundle.main.bundleIdentifier ?? "io.snackstud.latchkey") + ".safari"

    var body: some View {
        Section("Safari Extension") {
            LabeledContent("Latchkey for Safari", value: enabled.map { $0 ? "On" : "Off" } ?? "Not found in Safari")
            Button(enabled == true ? "Open Safari Extension Settings…" : "Turn On in Safari…") { open() }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            SettingsNote("Saves a new key from the page where you made it, and fills saved keys into the sites they belong to. Safari opens its Extensions settings with Latchkey selected: tick it, then allow it on the sites you use. Every save and fill still asks here.")
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: Self.identifier) { state, _ in
            DispatchQueue.main.async { enabled = state?.isEnabled }
        }
    }

    private func open() {
        error = nil
        SFSafariApplication.showPreferencesForExtension(withIdentifier: Self.identifier) { failure in
            guard let failure else { return }
            DispatchQueue.main.async { error = "Couldn't open Safari's settings: \(failure.localizedDescription)" }
        }
    }
}

private struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

private enum SettingsLinks {
    static let website = URL(string: "https://latchkey.snackstud.io/")!
    static let support = URL(string: "https://latchkey.snackstud.io/support.html")!
    static let privacy = URL(string: "https://latchkey.snackstud.io/privacy.html")!
    static let terms = URL(string: "https://latchkey.snackstud.io/terms.html")!
}

private struct MembershipSettings: View {
    #if LATCHKEY_APP_STORE
    @ObservedObject private var pro = ProEntitlement.shared
    #endif
    var body: some View {
        Section("Your Plan") {
            #if LATCHKEY_APP_STORE
            LabeledContent("Plan", value: !pro.hasResolved ? "Checking purchases…" : pro.isPro ? "Latchkey Pro" : "Latchkey Free")
            LabeledContent("Billing", value: !pro.hasResolved ? "Checking…" : pro.isPro ? "One-time purchase · No renewal" : "No charges on Free")
            if let date = pro.purchaseDate { LabeledContent("Purchased", value: date.formatted(date: .long, time: .omitted)) }
            #else
            LabeledContent("Plan", value: "Latchkey Free")
            LabeledContent("Distribution", value: "Direct download")
            SettingsNote("Pro ownership is verified in the Mac App Store version. This copy does not read your App Store purchases.")
            #endif
            SettingsNote("Everything in Latchkey today is free, including storage, approvals, grants, running commands, import, export and restoring your secrets.")
        }
        Section("Latchkey Pro") {
            SettingsNote("Pro is a one-time purchase for future additions. There are no recurring charges or renewals. Planned features are described on the pricing page.")
            #if LATCHKEY_APP_STORE
            if pro.hasResolved && !pro.isPro {
                if let product = pro.product {
                    LabeledContent("One-time price", value: product.displayPrice)
                    Button("Buy Latchkey Pro for \(product.displayPrice)") { Task { await pro.buy() } }
                        .disabled(pro.busy)
                } else {
                    Text(pro.busy ? "Checking App Store availability…" : "Pro is not available to purchase right now.").foregroundStyle(.secondary)
                    Button("Check Availability") { Task { await pro.reload() } }.disabled(pro.busy)
                }
            } else if pro.isPro {
                Label("Your Pro purchase is verified by the App Store.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            }
            Button("Restore Purchases") { Task { await pro.restore() } }.disabled(pro.busy)
            if pro.busy { ProgressView().controlSize(.small).accessibilityLabel("Updating purchases") }
            if let message = pro.message { SettingsNote(message) }
            SettingsNote("Restore uses the Apple Account signed in to the App Store. Latchkey does not have a separate billing account.")
            #else
            Link("View Plans & App Store Availability", destination: ProLinks.pricing)
            #endif
        }
        Section("Purchase Support") {
            Link("Plans & Pricing", destination: ProLinks.pricing)
            Link("Get Help with a Purchase", destination: SettingsLinks.support)
            Link("Terms of Use", destination: SettingsLinks.terms)
            Link("Privacy Policy", destination: SettingsLinks.privacy)
        }
    }
}
