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
        XCTAssertTrue(preferences.lockApp)
        XCTAssertEqual(preferences.lockAfterMinutes, 5)
        defaults.set(120, forKey: AppPreferences.Key.clipboardSeconds)
        defaults.set(10, forKey: AppPreferences.Key.revealSeconds)
        defaults.set(false, forKey: AppPreferences.Key.hideOnDeactivate)
        defaults.set(false, forKey: AppPreferences.Key.keepRunningFromDock)
        defaults.set(false, forKey: AppPreferences.Key.lockApp)
        defaults.set(15, forKey: AppPreferences.Key.lockAfterMinutes)
        let reloaded = AppPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(reloaded.clipboardSeconds, 120)
        XCTAssertEqual(reloaded.revealSeconds, 10)
        XCTAssertFalse(reloaded.hideOnDeactivate)
        XCTAssertFalse(reloaded.keepRunningFromDock)
        XCTAssertFalse(reloaded.lockApp)
        XCTAssertEqual(reloaded.lockAfterMinutes, 15)
    }

    func testUnsupportedDurationsCannotDisableAutomaticClearing() throws {
        let suite = "latchkey-preferences-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for value: Any in [0, -1, Int.max, "never"] {
            defaults.set(value, forKey: AppPreferences.Key.clipboardSeconds)
            defaults.set(value, forKey: AppPreferences.Key.revealSeconds)
            defaults.set(value, forKey: AppPreferences.Key.lockAfterMinutes)
            XCTAssertEqual(AppPreferences(defaults: defaults).clipboardSeconds, 60)
            XCTAssertEqual(AppPreferences(defaults: defaults).revealSeconds, 30)
            XCTAssertEqual(AppPreferences(defaults: defaults).lockAfterMinutes, 5)
        }
    }
}
