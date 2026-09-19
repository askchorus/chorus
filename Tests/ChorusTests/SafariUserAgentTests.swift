import XCTest
@testable import Chorus

final class SafariUserAgentTests: XCTestCase {
    func testInstalledVersionIsUsedVerbatim() {
        XCTAssertEqual(SafariUserAgent.applicationName(safariVersion: "27.0", osMajor: 27), "Version/27.0 Safari/605.1.15")
        XCTAssertEqual(SafariUserAgent.applicationName(safariVersion: "17.4.1", osMajor: 14), "Version/17.4.1 Safari/605.1.15")
    }

    func testAnUpdatedSafariOnAnOlderSystemWinsOverTheOSDefault() {
        // Safari 26 installed on macOS 15: the engine is 26, so the UA must say 26.
        XCTAssertEqual(SafariUserAgent.applicationName(safariVersion: "26.2", osMajor: 15), "Version/26.2 Safari/605.1.15")
    }

    func testMissingVersionFallsBackToTheSafariThatShipsWithTheOS() {
        XCTAssertEqual(SafariUserAgent.applicationName(safariVersion: nil, osMajor: 27), "Version/27.0 Safari/605.1.15")
        XCTAssertEqual(SafariUserAgent.applicationName(safariVersion: nil, osMajor: 26), "Version/26.0 Safari/605.1.15")
        XCTAssertEqual(SafariUserAgent.applicationName(safariVersion: nil, osMajor: 15), "Version/18.0 Safari/605.1.15")
        XCTAssertEqual(SafariUserAgent.applicationName(safariVersion: nil, osMajor: 14), "Version/17.0 Safari/605.1.15")
        XCTAssertEqual(SafariUserAgent.applicationName(safariVersion: nil, osMajor: 13), "Version/16.0 Safari/605.1.15")
    }

    func testAnythingThatIsNotAPlainDottedNumberIsRejected() {
        for bad in ["", "27.0 (beta)", "abc", "27..0", "1.2.3.4", "27.0\r\nX-Evil: 1", "２７.０", "1234.0"] {
            XCTAssertEqual(SafariUserAgent.applicationName(safariVersion: bad, osMajor: 27),
                           "Version/27.0 Safari/605.1.15", "should have rejected \(bad.debugDescription)")
        }
    }

    func testTheInstalledSafariOnThisMachineIsReadable() throws {
        let v = try XCTUnwrap(SafariUserAgent.installedSafariVersion(), "Safari's Info.plist should be readable")
        XCTAssertTrue(SafariUserAgent.isPlainVersion(v), "unexpected Safari version format: \(v)")
    }
}
