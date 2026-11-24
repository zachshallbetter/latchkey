import XCTest
@testable import LatchkeyCore

final class BrowserExtensionTests: XCTestCase {
    func input(_ data: Data) throws -> FileHandle {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        try FileManager.default.removeItem(at: url)
        return handle
    }

    func testFramesRejectOversizeAndTruncationBeforePayloadParsing() throws {
        for bytes: [UInt8] in [[0, 0], [0, 0, 0, 0], [1, 0, 1, 0], [255, 255, 255, 255], [2, 0, 0, 0, 123]] {
            let handle = try input(Data(bytes)); defer { try? handle.close() }
            XCTAssertThrowsError(try BrowserNativeFrame.read(from: handle))
        }
        let handle = try input(Data([2, 0, 0, 0, 123, 125])); defer { try? handle.close() }
        XCTAssertEqual(try BrowserNativeFrame.read(from: handle), Data("{}".utf8))
    }

    func testVersionAndMessageShapeAreRequired() throws {
        for text in ["{}", "[]", "{\"version\":true,\"message\":{}}", "{\"version\":2,\"message\":{}}", "{\"version\":1}"] {
            XCTAssertThrowsError(try BrowserNativeFrame.message(from: Data(text.utf8)))
        }
        let data = Data("{\"version\":1,\"message\":{\"op\":\"status\"}}".utf8)
        XCTAssertEqual(try BrowserNativeFrame.message(from: data)["op"] as? String, "status")
    }

    func testExplicitExtensionAllowlistsRejectSpoofedOriginShapes() throws {
        let id = String(repeating: "a", count: 32)
        let list = BrowserHostAllowlist(chrome: [id], firefox: ["pistachio@snackstud.io"])
        XCTAssertEqual(try list.browser(arguments: ["chrome-extension://" + id + "/"]), .chrome)
        XCTAssertEqual(try list.browser(arguments: ["/tmp/host.json", "pistachio@snackstud.io"]), .firefox)
        for args in [[String](), ["chrome-extension://" + id + "/?x=1"], ["https://" + id],
                     ["chrome-extension://" + String(repeating: "b", count: 32)],
                     ["/tmp/host.json", "other@example.invalid"], ["host.json", "pistachio@snackstud.io"]] {
            XCTAssertThrowsError(try list.browser(arguments: args))
        }
    }

    func testBrowserGateHasNoTerminalOrExportPowers() throws {
        XCTAssertNotEqual(Broker.Gate.browserExtension.identifier, Broker.Gate.safariExtension.identifier)
        XCTAssertNotEqual(Broker.Gate.browserExtension.identifier, CodeIdentity.toolIdentifier)
        let store = MemoryStore()
        let broker = Broker(store: store, approver: FixedApprover(false), logURL: nil)
        var peer = PeerInfo(pid: 1, path: "/fixture/helper", cwd: "", chain: ["Google Chrome"])
        peer.nativeBrowser = "Chrome"
        for op in ["get", "export", "grant", "scan", "push", "rm", "import"] {
            XCTAssertFalse(broker.handle(Request(op: op), peer: peer, gate: .browserExtension).ok)
        }
        XCTAssertTrue(broker.handle(Request(op: "status"), peer: peer, gate: .browserExtension).ok)
    }

    func testRefusalDoesNotFillAgentSafeValuesOrWrite() throws {
        let store = MemoryStore()
        try store.save(name: "FIXTURE", value: "fixture-value", kind: .token, agentSafe: true, note: "")
        let broker = Broker(store: store, approver: FixedApprover(false), logURL: nil)
        var peer = PeerInfo(pid: 1, path: "/fixture/helper", cwd: "", chain: ["Firefox"])
        peer.nativeBrowser = "Firefox"
        let fill = broker.handle(Request(op: "fill", names: ["FIXTURE"], page: "https://vercel.com"), peer: peer, gate: .browserExtension)
        XCTAssertFalse(fill.ok)
        XCTAssertNil(fill.values)
        XCTAssertFalse(broker.handle(Request(op: "set", names: ["NEW"], value: "fixture-new"), peer: peer, gate: .browserExtension).ok)
        XCTAssertNil(try store.info("NEW"))
        var approval = ApprovalRequest(action: .read, names: ["FIXTURE"], chain: ["Firefox"], folder: "", reason: "fill fixture")
        approval.browserName = "Firefox"
        XCTAssertTrue(approval.fromBrowser)
        XCTAssertNil(approval.asker)
    }

    func testTranslatorNeverPromotesExtensionOperationsToCLI() {
        var sent = [String]()
        for op in ["get", "export", "grant", "run"] {
            let result = BrowserExtensionMessages.answer(["op": op]) { request in
                sent.append(request.op); return Response(ok: true)
            }
            XCTAssertEqual(result["ok"] as? Bool, false)
        }
        XCTAssertTrue(sent.isEmpty)
        let status = BrowserExtensionMessages.answer(["op": "status"]) { request in
            sent.append(request.op); return Response(ok: true)
        }
        XCTAssertEqual(status["ok"] as? Bool, true)
        XCTAssertEqual(sent, ["status"])
    }
    func testOutputFramesPreserveUnicodeAndEnforceTheirBound() throws {
        let pipe = Pipe()
        try BrowserNativeFrame.write(["ok": true, "label": "Pistachio 🌰"], to: pipe.fileHandleForWriting)
        let body = try BrowserNativeFrame.read(from: pipe.fileHandleForReading)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["label"] as? String, "Pistachio 🌰")
        XCTAssertThrowsError(try BrowserNativeFrame.write(["payload": String(repeating: "x", count: BrowserNativeFrame.outputLimit + 1)], to: pipe.fileHandleForWriting))
        try pipe.fileHandleForWriting.close(); try pipe.fileHandleForReading.close()
    }

    func testBrowserFillAlwaysAsksEvenForAgentSafeItems() throws {
        let recorder = RecordingApprover(), store = MemoryStore()
        try store.save(name: "FIXTURE", value: "fixture-value", kind: .token, agentSafe: true, note: "")
        let broker = Broker(store: store, approver: recorder, logURL: nil)
        var peer = PeerInfo(pid: 1, path: "/fixture/helper", cwd: "", chain: ["Firefox"])
        peer.nativeBrowser = "Firefox"
        for _ in 0..<2 {
            XCTAssertTrue(broker.handle(Request(op: "fill", names: ["FIXTURE"], page: "https://vercel.com"), peer: peer, gate: .browserExtension).ok)
        }
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertTrue(recorder.requests.allSatisfy { $0.browserName == "Firefox" && !$0.canGrant && $0.caller.isEmpty })
        XCTAssertFalse(broker.handle(Request(op: "fill", names: ["FIXTURE"], page: "https://attacker.invalid"), peer: peer, gate: .browserExtension).ok)
        XCTAssertEqual(recorder.requests.count, 2)
    }

    func testSaveNoteNamesTheAuthenticatedBrowser() {
        var note: String?
        let result = BrowserExtensionMessages.answer(["op": "save", "id": "FIXTURE", "value": "fixture", "page": "https://vercel.com"], browserName: "Firefox") { request in
            if request.op == "set" { note = request.note }
            return Response(ok: true)
        }
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(note, "saved from https://vercel.com by Pistachio for Firefox")
    }

}
