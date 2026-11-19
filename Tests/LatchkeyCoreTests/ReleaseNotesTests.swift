import XCTest
@testable import LatchkeyCore

final class ReleaseNotesTests: XCTestCase {
    let sample = """
    # Changelog

    ## Unreleased

    ### App
    - Not out yet.

    ## 0.4.0 (2026-11-18)

    ### App
    - Latchkey locks, as Passwords does: when it opens, after 5 minutes
      in the background, and when the Mac sleeps.
    - Approvals are one small panel.

    ### Security
    - The broker no longer holds its lock while a request waits.

    ## 0.3.1 (2026-11-13)

    Prose that isn't a list item is skipped.

    ### Mac App Store
    - The App Store version is free.
    """

    func testReleasesSectionsAndItems() throws {
        let notes = ReleaseNotes(markdown: sample)
        XCTAssertEqual(notes.releases.map(\.version), ["Unreleased", "0.4.0", "0.3.1"])
        let r = try XCTUnwrap(notes.release("0.4.0"))
        XCTAssertEqual(r.date, "2026-11-18")
        XCTAssertEqual(r.sections.map(\.title), ["App", "Security"])
        XCTAssertEqual(r.sections[0].items, ["Latchkey locks, as Passwords does: when it opens, after 5 minutes in the background, and when the Mac sleeps.",
                                             "Approvals are one small panel."])
        XCTAssertEqual(notes.release("Unreleased")?.date, nil)
        XCTAssertEqual(notes.release("0.3.1")?.sections.first?.items, ["The App Store version is free."])
        XCTAssertNil(notes.release("9.9.9"))
    }

    /// The repository's own changelog parses, and the version being built has notes.
    func testTheRepositoryChangelogHasTheCurrentVersion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let changelog = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let project = try String(contentsOf: root.appendingPathComponent("App/project.yml"), encoding: .utf8)
        let version = try XCTUnwrap(project.range(of: #"MARKETING_VERSION: "([^"]+)""#, options: .regularExpression)
            .map { String(project[$0]).components(separatedBy: "\"")[1] })
        let release = try XCTUnwrap(ReleaseNotes(markdown: changelog).release(version), "CHANGELOG.md has no ## \(version) heading")
        XCTAssertFalse(release.sections.flatMap(\.items).isEmpty)
        XCTAssertFalse(changelog.contains("|||||||") || changelog.contains("<<<<<<<"), "a merge marker was left in the changelog")
    }
}
