import Foundation

/// Local presentation and handling preferences. These never change broker authorization or Pro ownership.
public struct AppPreferences {
    public enum Key {
        public static let appearance = "appearance"
        public static let clipboardSeconds = "clipboardClearSeconds"
        public static let revealSeconds = "revealSeconds"
        public static let hideOnDeactivate = "hideValuesOnDeactivate"
        public static let keepRunningFromDock = "keepRunningFromDock"
    }
    public static let clipboardChoices = [15, 30, 60, 120]
    public static let revealChoices = [10, 30, 60]
    public static let defaultClipboardSeconds = 60
    public static let defaultRevealSeconds = 30
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var clipboardSeconds: Int {
        let value = defaults.integer(forKey: Key.clipboardSeconds)
        return Self.clipboardChoices.contains(value) ? value : Self.defaultClipboardSeconds
    }
    public var revealSeconds: Int {
        let value = defaults.integer(forKey: Key.revealSeconds)
        return Self.revealChoices.contains(value) ? value : Self.defaultRevealSeconds
    }
    public var hideOnDeactivate: Bool { defaults.object(forKey: Key.hideOnDeactivate) as? Bool ?? true }
    public var keepRunningFromDock: Bool { defaults.object(forKey: Key.keepRunningFromDock) as? Bool ?? true }
}
