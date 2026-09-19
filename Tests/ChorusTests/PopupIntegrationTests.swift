import XCTest
import WebKit
@testable import Chorus

/// Drives a real WKWebView through the delegate: a script-opened sized popup must come back as
/// an in-app child whose `window.opener` is live, and `window.close()` must tear it down.
@MainActor
final class PopupIntegrationTests: XCTestCase {
    private func wait(_ what: String, timeout: TimeInterval = 10, until cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testScriptOpenedPopupGetsAnInAppChildWiredToItsOpenerAndClosesCleanly() async throws {
        let manager = PopupWindowManager.shared
        manager.presentsWindows = false
        defer { manager.presentsWindows = true }

        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true   // no user gesture in a test
        let opener = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        opener.uiDelegate = LinkRoutingDelegate.shared
        opener.loadHTMLString("<html><body>opener</body></html>", baseURL: URL(string: "https://claude.ai/login"))
        try await wait("opener load") { !opener.isLoading }

        let before = manager.openCount
        _ = try await opener.evaluateJavaScript("window.__p = window.open('about:blank', 'g_auth', 'width=420,height=520'); !!window.__p")
        try await wait("popup to be created") { manager.openCount == before + 1 }

        let child = try XCTUnwrap(manager.webViews.last)
        try await wait("child to settle") { !child.isLoading }
        let hasOpener = try await child.evaluateJavaScript("!!window.opener") as? Bool
        XCTAssertEqual(hasOpener, true, "the popup must be able to report back to the page that opened it")

        _ = try await opener.evaluateJavaScript("window.__p.close(); true")
        try await wait("popup to close") { manager.openCount == before }
    }
}
