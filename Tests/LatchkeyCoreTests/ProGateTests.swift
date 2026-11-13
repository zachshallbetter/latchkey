import XCTest
@testable import LatchkeyCore

final class ProGateTests: XCTestCase {
    let peer = PeerInfo(pid: 1, path: "/fixture/Latchkey", cwd: "/", chain: [Broker.appCaller])

    func broker(pro: Bool, features: [String: String] = ["list": "the fixture feature"]) -> Broker {
        Broker(store: MemoryStore(), approver: FixedApprover(true), logURL: nil, hasPro: { pro }, proFeatures: features)
    }

    func testGatedOpIsRefusedWithoutProNamingProAndTheFeature() {
        let r = broker(pro: false).handle(Request(op: "list"), peer: peer)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.error?.contains("Latchkey Pro") == true)
        XCTAssertTrue(r.error?.contains("the fixture feature") == true)
        XCTAssertTrue(ProGate.isRefusal(r.error))
        XCTAssertNil(r.secrets)
    }

    func testGatedOpIsAllowedWithPro() {
        let r = broker(pro: true).handle(Request(op: "list"), peer: peer)
        XCTAssertTrue(r.ok)
        XCTAssertFalse(ProGate.isRefusal(r.error))
    }

    func testOpsOutsideTheSetAreNeverRefused() {
        let b = broker(pro: false)
        XCTAssertTrue(b.handle(Request(op: "status"), peer: peer).ok)
        XCTAssertFalse(ProGate.isRefusal(b.handle(Request(op: "unknown-op"), peer: peer).error))
    }

    func testDefaultBrokerHasNoProAndNoGatedOps() {
        let b = Broker(store: MemoryStore(), approver: FixedApprover(true), logURL: nil)
        XCTAssertTrue(b.handle(Request(op: "list"), peer: peer).ok)
    }

    func testCoreOpsAreNeverInTheProSet() {
        XCTAssertTrue(ProGate.ops.isDisjoint(with: Broker.Gate.commandLineTool.ops),
                      "Pro-gated ops that are core today: \(ProGate.ops.intersection(Broker.Gate.commandLineTool.ops).sorted())")
        XCTAssertTrue(ProGate.ops.isDisjoint(with: Broker.Gate.safariExtension.ops))
    }
}
