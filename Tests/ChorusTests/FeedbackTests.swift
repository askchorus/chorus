import XCTest
@testable import Chorus

/// The feedback email: subject and body arrive in the mail app exactly as written, whatever
/// they contain, and the version line a reply starts from reads right.
final class FeedbackTests: XCTestCase {
    func testMailURLCarriesSubjectAndBodyIntact() {
        let body = "（遇到了什么问题？附上截图更好）\r\n\r\nA & B = C + D? #1 100%\r\n—\r\nChorus 0.2.6 · macOS 27.0 · Apple silicon"
        let url = Feedback.mailURL(subject: "Chorus 反馈 & more", body: body)
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:smileduck@duck.com?subject="), url.absoluteString)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.map(\.name), ["subject", "body"])
        XCTAssertEqual(items.first { $0.name == "subject" }?.value, "Chorus 反馈 & more")
        XCTAssertEqual(items.first { $0.name == "body" }?.value, body)
    }

    func testFooterNamesTheVersionsAndTheChip() {
        XCTAssertEqual(Feedback.footer(appVersion: "0.2.6", os: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1),
                                       appleSilicon: true), "Chorus 0.2.6 · macOS 27.0.1 · Apple silicon")
        XCTAssertEqual(Feedback.footer(appVersion: "0.2.6", os: OperatingSystemVersion(majorVersion: 13, minorVersion: 5, patchVersion: 0),
                                       appleSilicon: false), "Chorus 0.2.6 · macOS 13.5 · Intel")
    }
}
