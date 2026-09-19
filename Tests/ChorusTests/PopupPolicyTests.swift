import XCTest
@testable import Chorus

final class PopupPolicyTests: XCTestCase {
    private func inApp(link: Bool = false, sized: Bool = false, _ url: String?) -> Bool {
        PopupPolicy.opensInApp(linkActivated: link, hasWindowSize: sized, targetURL: url.flatMap(URL.init(string:)))
    }

    func testTheClaudeGoogleSignInPopupStaysInApp() {
        // Exactly what claude.ai does: script-opened, sized, pointed at Google's OAuth endpoint.
        XCTAssertTrue(inApp(sized: true, "https://accounts.google.com/o/oauth2/v2/auth?gsiwebsdk=gis_attributes&client_id=x"))
    }

    func testIdentityProvidersStayInAppEvenWithoutASize() {
        XCTAssertTrue(inApp("https://accounts.google.com/o/oauth2/v2/auth"))
        XCTAssertTrue(inApp("https://appleid.apple.com/auth/authorize"))
        XCTAssertTrue(inApp("https://open.weixin.qq.com/connect/qrconnect"))
    }

    func testABlankPopupStaysInAppBecauseScriptWillNavigateIt() {
        XCTAssertTrue(inApp("about:blank"))
        XCTAssertTrue(inApp(nil))
    }

    func testClickedLinksAlwaysGoToTheBrowser() {
        XCTAssertFalse(inApp(link: true, "https://en.wikipedia.org/wiki/Lean_(proof_assistant)"))
        XCTAssertFalse(inApp(link: true, sized: true, "https://accounts.google.com/"))   // a clicked link is a link
    }

    func testUnsizedScriptOpenedOrdinaryPagesGoToTheBrowser() {
        XCTAssertFalse(inApp("https://arxiv.org/abs/2401.00001"))
        XCTAssertFalse(inApp("mailto:someone@example.com"))
    }

    func testLookalikeHostsAreNotTreatedAsIdentityProviders() {
        XCTAssertFalse(inApp("https://accounts.google.com.evil.example/o/oauth2"))
        XCTAssertFalse(inApp("https://notgithub.com/login"))
    }
}
