import AppKit
import LatchkeyCore
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
        case .privacy: return "Privacy & Approval"
        case .storage: return "Storage & File Access"
        case .developer: return "Developer Tools"
        case .membership: return "Membership"
        case .about: return "About & Updates"
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
    var summary: String {
        switch self {
        case .general: return "Appearance, startup and how Latchkey behaves."
        case .privacy: return "Choose how long values stay visible or on the clipboard."
        case .storage: return "Your Keychain storage and the files Latchkey can access."
        case .developer: return "Command-line setup and activity records."
        case .membership: return "Your plan, purchases and purchase support."
        case .about: return "Version, updates and help."
        }
    }
}

/// Settings stays in the main navigation. Every entry point, including Command-comma, uses the same destination.
struct SettingsCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                model.openSettings()
                openWindow(id: "main")
                NSApp.activate()
            }.keyboardShortcut(",", modifiers: .command)
        }
    }
}

struct SettingsSectionList: View {
    @Bindable var model: AppModel
    var body: some View {
        List(SettingsSection.visible, selection: Binding<SettingsSection?>(get: { model.settingsSection }, set: { if let section = $0 { model.settingsSection = section } })) { section in
            HStack(spacing: 12) {
                IconTile(symbol: section.symbol, tint: section == .membership ? .orange : .blue, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title).font(.headline)
                    Text(section.summary).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 7)
            .tag(section)
        }
        .navigationTitle("Settings")
        .listStyle(.inset)
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage(AppPreferences.Key.appearance) private var appearance = "system"
    @AppStorage(AppPreferences.Key.clipboardSeconds) private var clipboardSeconds = AppPreferences.defaultClipboardSeconds
    @AppStorage(AppPreferences.Key.revealSeconds) private var revealSeconds = AppPreferences.defaultRevealSeconds
    @AppStorage(AppPreferences.Key.hideOnDeactivate) private var hideOnDeactivate = true
    @AppStorage(AppPreferences.Key.keepRunningFromDock) private var keepRunningFromDock = true
    @State private var atLogin = false
    @State private var loginError: String?
    #if !LATCHKEY_APP_STORE
    @State private var checksForUpdates = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                IconTile(symbol: model.settingsSection.symbol, tint: model.settingsSection == .membership ? .orange : .blue, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.settingsSection.title).font(.title2.weight(.semibold))
                    Text(model.settingsSection.summary).foregroundStyle(.secondary).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            Divider()
            Form {
                switch model.settingsSection {
                case .general: general
                case .privacy: privacy
                case .storage: storage
                case .developer: developer
                case .membership: MembershipSettings()
                case .about: about
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            SettingsNote("Preferences are saved on this Mac. They do not change the settings on your other Macs.")
        }
        Section("Startup & Dock") {
            Toggle("Open Latchkey at login", isOn: Binding(get: { atLogin }, set: { on in
                loginError = model.setOpensAtLogin(on)
                atLogin = model.opensAtLogin
            }))
            if let loginError { Text(loginError).font(.callout).foregroundStyle(.red) }
            Toggle("Keep running when I quit from the Dock", isOn: $keepRunningFromDock)
            SettingsNote("When enabled, quitting from the Dock closes the window and leaves the menu bar app running for your commands and agents. Quit from the Latchkey menu always exits the app.")
        }
    }

    @ViewBuilder private var privacy: some View {
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
            SettingsNote("The command-line tool, latchkey (lk for short), is a separate, signed download. It connects to this app through an authenticated App Group endpoint, and every value it asks for is approved here.")
            Link("Get the Command-Line Tool", destination: AppModel.commandLineToolPage)
            #else
            if let tool = model.bundledTool {
                LabeledContent("Bundled CLI", value: tool.lastPathComponent)
                Button("Install Command Line Tool…") { model.installCommandLineTool() }
                SettingsNote("Links ~/.local/bin/latchkey and ~/.local/bin/lk to the copy inside Latchkey, so they update with the app. Existing files are left alone.")
            } else {
                Text("This development copy has no bundled CLI.").foregroundStyle(.secondary)
                Link("Command-line setup help", destination: SettingsLinks.support)
            }
            #endif
            SettingsNote("Commands run in your terminal. The command-line tool starts Latchkey when needed.")
        }
        Section("Activity") {
            Button("View Activity") { model.filter = .activity }
            Button("Show Access Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.accessLog]) }
            SettingsNote("The log records access decisions and caller context. Command arguments use heuristic redaction; avoid putting credentials in arguments.")
        }
    }

    @ViewBuilder private var about: some View {
        Section("Latchkey") {
            LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
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
        Section("Help & Policies") {
            Link("Latchkey Help", destination: SettingsLinks.support)
            Link("Privacy Policy", destination: SettingsLinks.privacy)
            Link("Terms of Use", destination: SettingsLinks.terms)
            Link("Report a Security Issue", destination: URL(string: "mailto:latchkey@snackstud.io?subject=Security")!)
        }
    }
}

private struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

private enum SettingsLinks {
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
