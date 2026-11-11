import Foundation
import XCTest
@testable import LatchkeyCore

final class BrokerLogTransportTests: XCTestCase {
    func testLogComesFromServingBrokerAndHasBoundedLimit() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let first = #"{"time":"2026-11-11T00:00:00Z","op":"get","names":["FIRST"],"decision":"allowed","chain":[],"cwd":"/fixture"}"#
        let second = first.replacingOccurrences(of: "FIRST", with: "SECOND")
        try (first + "\n" + second + "\n").write(to: file, atomically: true, encoding: .utf8)
        let broker = Broker(store: MemoryStore(), approver: FixedApprover(false), logURL: file)
        let peer = PeerInfo(pid: 1, path: "", cwd: "", chain: [])
        let response = broker.handle(Request(op: "log", logLimit: 1), peer: peer)
        XCTAssertEqual(response.logEntries?.map(\.names), [["SECOND"]])
        XCTAssertEqual(broker.handle(Request(op: "log", logLimit: 0), peer: peer).logEntries?.count, 0)
        XCTAssertFalse(broker.handle(Request(op: "log", logLimit: -1), peer: peer).ok)
        XCTAssertFalse(broker.handle(Request(op: "log", logLimit: 1001), peer: peer).ok)
        XCTAssertFalse(broker.handle(Request(op: "log"), peer: peer, gate: .safariExtension).ok)
        let decoded = try Wire.decoder().decode(Response.self, from: Wire.encoder().encode(response))
        XCTAssertEqual(decoded.logEntries?.first?.names, ["SECOND"])
    }
}
