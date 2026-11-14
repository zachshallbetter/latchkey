import Foundation
import XCTest
@testable import LatchkeyCore

final class AppPreferencesTests: XCTestCase {
    func testDefaultsAndPersistedDurations() throws {
        let suite = "latchkey-preferences-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.clipboardSeconds, 60)
        XCTAssertEqual(preferences.revealSeconds, 30)
        XCTAssertTrue(preferences.hideOnDeactivate)
        XCTAssertTrue(preferences.keepRunningFromDock)
        defaults.set(120, forKey: AppPreferences.Key.clipboardSeconds)
        defaults.set(10, forKey: AppPreferences.Key.revealSeconds)
        defaults.set(false, forKey: AppPreferences.Key.hideOnDeactivate)
        defaults.set(false, forKey: AppPreferences.Key.keepRunningFromDock)
        let reloaded = AppPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(reloaded.clipboardSeconds, 120)
        XCTAssertEqual(reloaded.revealSeconds, 10)
        XCTAssertFalse(reloaded.hideOnDeactivate)
        XCTAssertFalse(reloaded.keepRunningFromDock)
    }

    func testUnsupportedDurationsCannotDisableAutomaticClearing() throws {
        let suite = "latchkey-preferences-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for value: Any in [0, -1, Int.max, "never"] {
            defaults.set(value, forKey: AppPreferences.Key.clipboardSeconds)
            defaults.set(value, forKey: AppPreferences.Key.revealSeconds)
            XCTAssertEqual(AppPreferences(defaults: defaults).clipboardSeconds, 60)
            XCTAssertEqual(AppPreferences(defaults: defaults).revealSeconds, 30)
        }
    }
}
