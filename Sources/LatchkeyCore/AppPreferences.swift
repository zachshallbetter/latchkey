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
}
