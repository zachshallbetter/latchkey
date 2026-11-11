import XCTest
@testable import LatchkeyCore

private final class BookmarkFixture: ScopedBookmarkDriver {
    var starts: [URL] = [], stops: [URL] = []
    var offline = false, stale = false, denied = false, creates = 0
    func create(_ url: URL) throws -> Data { creates += 1; return Data(url.absoluteString.utf8) }
    func resolve(_ data: Data) throws -> (url: URL, stale: Bool) {
        if offline { throw CocoaError(.fileReadNoSuchFile) }
        return (URL(string: String(decoding: data, as: UTF8.self))!, stale)
    }
    func start(_ url: URL) -> Bool { if denied { return false }; starts.append(url); return true }
    func stop(_ url: URL) { stops.append(url) }
}

final class SecurityScopedAccessTests: XCTestCase {
    func testRememberDuplicateAndForgetBalanceTheExactScopedURLs() throws {
        let driver = BookmarkFixture()
        var saved: Data?
        let access = try SecurityScopedAccess(saved: nil, driver: driver) { saved = $0 }
        let url = URL(fileURLWithPath: "/tmp/selected/../selected/project", isDirectory: true)
        try access.remember(url, isDirectory: true)
        let id = try XCTUnwrap(access.records.first?.id)
        try access.remember(url, isDirectory: true)
        XCTAssertEqual(access.records.count, 1)
        XCTAssertEqual(driver.starts.count, 2)
        XCTAssertEqual(driver.stops, [driver.starts[0]])
        try access.forget(id)
        XCTAssertEqual(driver.stops, driver.starts)
        XCTAssertFalse(access.isActive(id))
        XCTAssertEqual(try JSONDecoder().decode([SecurityScopedAccess.Record].self, from: XCTUnwrap(saved)), [])
    }

    func testOfflineBookmarksSurviveAndStaleBookmarksRenewWithoutDuplicateStarts() throws {
        let driver = BookmarkFixture()
        var saved: Data?
        var original: SecurityScopedAccess? = try SecurityScopedAccess(saved: nil, driver: driver) { saved = $0 }
        try original?.remember(URL(fileURLWithPath: "/Volumes/Fixture/project"), isDirectory: true)
        original = nil
        let reloaded = try SecurityScopedAccess(saved: saved, driver: driver) { saved = $0 }
        driver.offline = true
        XCTAssertEqual(reloaded.restore().count, 1)
        XCTAssertEqual(reloaded.records.count, 1)
        driver.offline = false; driver.stale = true
        let before = driver.creates
        XCTAssertEqual(reloaded.restore(), [])
        XCTAssertEqual(driver.creates, before + 1)
        let starts = driver.starts.count
        XCTAssertEqual(reloaded.restore(), [])
        XCTAssertEqual(driver.starts.count, starts)
    }

    func testPersistenceFailureDoesNotLeakNewScopeOrRevokeTheExistingOne() throws {
        let driver = BookmarkFixture()
        var fail = false
        let access = try SecurityScopedAccess(saved: nil, driver: driver) { _ in
            if fail { throw CocoaError(.fileWriteNoPermission) }
        }
        let url = URL(fileURLWithPath: "/tmp/project")
        try access.remember(url, isDirectory: true)
        let id = try XCTUnwrap(access.records.first?.id)
        fail = true
        XCTAssertThrowsError(try access.remember(url, isDirectory: true))
        XCTAssertEqual(driver.stops.count, 1)
        XCTAssertTrue(access.isActive(id))
        XCTAssertThrowsError(try access.forget(id))
        XCTAssertTrue(access.isActive(id))
        XCTAssertEqual(driver.stops.count, 1)
    }

    func testDeniedAccessAndCorruptStorageAreNotReportedAsAuthorized() throws {
        let driver = BookmarkFixture(); driver.denied = true
        let access = try SecurityScopedAccess(saved: nil, driver: driver) { _ in }
        XCTAssertThrowsError(try access.remember(URL(fileURLWithPath: "/tmp/project"), isDirectory: true))
        XCTAssertTrue(access.records.isEmpty)
        XCTAssertThrowsError(try SecurityScopedAccess(saved: Data("corrupt".utf8), driver: driver) { _ in })
    }
}
