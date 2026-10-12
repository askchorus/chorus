import XCTest
@testable import Chorus

final class AgentBridgeRequestTests: XCTestCase {
    func testNegativeBodyLengthIsRejectedBeforeItCanReachDataPrefix() {
        XCTAssertNil(AgentBridge.contentLength(in: "POST /ask HTTP/1.1\r\nContent-Length: -1"))
    }

    func testMalformedOrOverflowingLengthsAreNotTreatedAsAnEmptyBody() {
        for value in ["", "not-a-number", "1.5", "999999999999999999999999999999"] {
            XCTAssertNil(AgentBridge.contentLength(in: "POST /ask HTTP/1.1\r\nContent-Length: \(value)"), value)
        }
    }

    func testValidRequestsKeepTheirBodyLength() {
        XCTAssertEqual(AgentBridge.contentLength(in: "POST /ask HTTP/1.1\r\nContent-Length: 42"), 42)
        XCTAssertEqual(AgentBridge.contentLength(in: "POST /ask HTTP/1.1\r\ncontent-length:  42 \r\nX-Test: value"), 42)
        XCTAssertEqual(AgentBridge.contentLength(in: "POST /ask HTTP/1.1\r\nContent-Length: 0"), 0)
        XCTAssertEqual(AgentBridge.contentLength(in: "POST /ask HTTP/1.1"), 0)
    }
}
