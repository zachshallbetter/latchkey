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

    func testPaletteFollowsTheIconUntilChosenAndIgnoresUnknownChoices() throws {
        let suite = "latchkey-preferences-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppPreferences(defaults: defaults).palette, .pistachio)
        defaults.set("key", forKey: AppPreferences.Key.icon)
        XCTAssertEqual(AppPreferences(defaults: defaults).palette, .blue)
        defaults.set("plum", forKey: AppPreferences.Key.palette)
        XCTAssertEqual(AppPreferences(defaults: defaults).palette, .plum, "a chosen palette stays when the icon changes")
        defaults.set("pistachio", forKey: AppPreferences.Key.icon)
        XCTAssertEqual(AppPreferences(defaults: defaults).palette, .plum)
        defaults.set("neon", forKey: AppPreferences.Key.palette)
        XCTAssertEqual(AppPreferences(defaults: defaults).palette, .pistachio)
        XCTAssertEqual(AppPreferences.Palette(preference: "", iconPreference: "key"), .blue)
        XCTAssertEqual(AppPreferences.Palette.graphite.title, "Graphite")
    }

    func testWelcomeOpensOnAFreshMacUntilFinished() throws {
        let suite = "latchkey-preferences-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.needsWelcome(existingUser: false))
        XCTAssertTrue(preferences.needsWelcome(existingUser: false), "only finishing it, or closing it, counts")
        preferences.finishWelcome()
        XCTAssertFalse(preferences.needsWelcome(existingUser: false))
    }

    func testWelcomeNeverOpensWherePistachioWasAlreadyInUse() throws {
        for setUp in [{ (_: UserDefaults) in }, { $0.set("0.5.0", forKey: AppPreferences.Key.lastSeenVersion) }] {
            let suite = "latchkey-preferences-test-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            setUp(defaults)
            let hasItems = defaults.string(forKey: AppPreferences.Key.lastSeenVersion) == nil
            XCTAssertFalse(AppPreferences(defaults: defaults).needsWelcome(existingUser: hasItems))
            XCTAssertTrue(defaults.bool(forKey: AppPreferences.Key.welcomeDone), "marked done, so it stays closed")
        }
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

    func testIconChoicePersistsAndInvalidValuesUsePistachio() throws {
        let suite = "pistachio-icon-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppPreferences(defaults: defaults).icon, .pistachio)
        defaults.set("key", forKey: AppPreferences.Key.icon)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(AppPreferences(defaults: reloaded).icon, .key)
        defaults.set("pistachio", forKey: AppPreferences.Key.icon)
        XCTAssertEqual(AppPreferences(defaults: reloaded).icon, .pistachio)
        for invalid: Any in ["unknown", "", 42, false] {
            defaults.set(invalid, forKey: AppPreferences.Key.icon)
            XCTAssertEqual(AppPreferences(defaults: defaults).icon, .pistachio)
        }
    }

    func testWhatsNewShowsOnceAfterEachUpdate() throws {
        let suite = "latchkey-preferences-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let p = AppPreferences(defaults: defaults)
        XCTAssertFalse(p.takeWhatsNew(for: "0.4.0", existingUser: false), "a first install opens to the app")
        XCTAssertFalse(p.takeWhatsNew(for: "0.4.0", existingUser: true), "already seen")
        XCTAssertTrue(p.takeWhatsNew(for: "0.5.0", existingUser: true), "an update")
        XCTAssertFalse(p.takeWhatsNew(for: "0.5.0", existingUser: true))
        defaults.removeObject(forKey: AppPreferences.Key.lastSeenVersion)
        XCTAssertTrue(p.takeWhatsNew(for: "0.5.0", existingUser: true), "an update from a version that didn't record one")
    }
}
