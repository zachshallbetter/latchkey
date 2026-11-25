import Foundation

/// Local presentation and handling preferences. These never change broker authorization or Pro ownership.
public struct AppPreferences {
    public enum Key {
        public static let appearance = "appearance"
        public static let icon = "appIconChoice"
        public static let palette = "paletteChoice"
        public static let clipboardSeconds = "clipboardClearSeconds"
        public static let revealSeconds = "revealSeconds"
        public static let hideOnDeactivate = "hideValuesOnDeactivate"
        public static let keepRunningFromDock = "keepRunningFromDock"
        public static let lockApp = "lockApp"
        public static let lockAfterMinutes = "lockAfterMinutes"
        public static let lastSeenVersion = "lastSeenVersion"
        public static let welcomeDone = "welcomeDone"
    }
    public static let clipboardChoices = [15, 30, 60, 120]
    public static let revealChoices = [10, 30, 60]
    public static let defaultClipboardSeconds = 60
    public static let defaultRevealSeconds = 30
    /// How long Latchkey can be in the background before its window locks.
    public static let lockChoices = [1, 5, 15, 60]
    public static let defaultLockMinutes = 5
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public enum Icon: String, CaseIterable, Sendable {
        case pistachio, key

        public var title: String { self == .pistachio ? "Pistachio" : "Key" }
        public init(preference: String?) { self = preference.flatMap(Self.init(rawValue:)) ?? .pistachio }
    }

    public var icon: Icon { Icon(preference: defaults.string(forKey: Key.icon)) }

    /// The app's accent colour, chosen apart from the icon.
    public enum Palette: String, CaseIterable, Sendable {
        case pistachio, blue, plum, graphite

        public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
        public init(preference: String?) { self = preference.flatMap(Self.init(rawValue:)) ?? .pistachio }
    }

    public var palette: Palette { Palette(preference: defaults.string(forKey: Key.palette)) }

    public var clipboardSeconds: Int { Self.clipboardSeconds(defaults.integer(forKey: Key.clipboardSeconds)) }

    /// A clipboard delay as given (a preference, or a request's `clearAfter`), or the default when it isn't a choice.
    public static func clipboardSeconds(_ value: Int?) -> Int {
        guard let value, clipboardChoices.contains(value) else { return defaultClipboardSeconds }
        return value
    }
    public var revealSeconds: Int {
        let value = defaults.integer(forKey: Key.revealSeconds)
        return Self.revealChoices.contains(value) ? value : Self.defaultRevealSeconds
    }
    public var hideOnDeactivate: Bool { defaults.object(forKey: Key.hideOnDeactivate) as? Bool ?? true }
    public var keepRunningFromDock: Bool { defaults.object(forKey: Key.keepRunningFromDock) as? Bool ?? true }
    /// Lock the window and menu bar panel at launch, after `lockAfterMinutes` away, and when the Mac sleeps.
    public var lockApp: Bool { defaults.object(forKey: Key.lockApp) as? Bool ?? true }
    public var lockAfterMinutes: Int {
        let value = defaults.integer(forKey: Key.lockAfterMinutes)
        return Self.lockChoices.contains(value) ? value : Self.defaultLockMinutes
    }

    /// Whether to show What's New for `version`, remembering that it has been: once after each update. A Mac that has
    /// never recorded a version shows it only if Latchkey was already in use there (`existingUser`), so a first install
    /// opens to the app, not to release notes.
    public func takeWhatsNew(for version: String, existingUser: Bool) -> Bool {
        let last = defaults.string(forKey: Key.lastSeenVersion)
        defaults.set(version, forKey: Key.lastSeenVersion)
        return last.map { $0 != version } ?? existingUser
    }

    /// Whether to open the welcome window. A Mac where Pistachio was already in use (it has items, or has recorded a
    /// version) never sees it and is marked done; otherwise it opens until `finishWelcome()`. Call before `takeWhatsNew`.
    public func needsWelcome(existingUser: Bool) -> Bool {
        if defaults.bool(forKey: Key.welcomeDone) { return false }
        if existingUser || defaults.string(forKey: Key.lastSeenVersion) != nil {
            finishWelcome()
            return false
        }
        return true
    }

    /// Closing the welcome early counts too: everything it asks is in Settings.
    public func finishWelcome() { defaults.set(true, forKey: Key.welcomeDone) }
}
