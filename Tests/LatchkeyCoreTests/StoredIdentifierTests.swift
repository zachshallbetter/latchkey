import XCTest
@testable import LatchkeyCore

/// The names that find what Latchkey has already stored. Renaming the product changes none of them: a build with a
/// new name has to read the items, grants, history and logs an earlier build wrote. See "Stored identifiers" in
/// docs/development.md.
final class StoredIdentifierTests: XCTestCase {
    func testKeychainServicesKeepTheirNames() {
        XCTAssertEqual(KeychainStore.service, "latchkey")
        XCTAssertEqual(KeychainVersionStore.service, "latchkey.history")
        XCTAssertEqual(KeychainGrantBacking.service, "latchkey.grants")
        XCTAssertEqual(KeychainRemoteStore.service, "latchkey.remote")
        XCTAssertEqual(KeychainEnvironmentStore.environmentService, "latchkey.environment")
        XCTAssertEqual(KeychainEnvironmentStore.projectService, "latchkey.project")
        XCTAssertEqual(KeychainLogKeyStore.keyService, "latchkey.logkey")
        XCTAssertEqual(KeychainLogKeyStore.headService, "latchkey.loghead")
    }

    func testCodeSigningIdentifiersKeepTheirNames() {
        XCTAssertEqual(CodeIdentity.appIdentifier, "io.snackstud.latchkey")
        XCTAssertEqual(CodeIdentity.toolIdentifier, "io.snackstud.latchkey.cli")
        XCTAssertEqual(CodeIdentity.safariExtensionIdentifier, "io.snackstud.latchkey.safari")
    }

    func testSupportFolderAndSocketsKeepTheirNames() {
        XCTAssertEqual(Paths.supportDir.lastPathComponent, "Latchkey")
        XCTAssertEqual(URL(fileURLWithPath: Paths.socket).lastPathComponent, "broker.sock")
        XCTAssertEqual(Paths.accessLog.lastPathComponent, "access.jsonl")
        XCTAssertEqual(BrokerEndpoint.appStorePath(container: URL(fileURLWithPath: "/c")), "/c/cli.sock")
    }
}
