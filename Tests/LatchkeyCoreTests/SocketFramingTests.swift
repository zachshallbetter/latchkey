import Darwin
import XCTest
@testable import LatchkeyCore

final class SocketFramingTests: XCTestCase {
    func testOversizeLineCannotBypassLimitWithFinalNewline() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let reader = pair[0], writer = pair[1]
        defer { close(reader) }
        let finished = expectation(description: "writer ends")
        DispatchQueue.global().async {
            defer { close(writer); finished.fulfill() }
            var noSignal: Int32 = 1
            setsockopt(writer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            try? UnixSocket.writeLine(writer, Data(repeating: 65, count: UnixSocket.maxLine + 1))
        }
        XCTAssertThrowsError(try UnixSocket.readLine(reader)) { error in
            guard case SocketError.tooLarge = error else { return XCTFail("unexpected error: \(error)") }
        }
        shutdown(reader, SHUT_RDWR)
        wait(for: [finished], timeout: 5)
    }
}
