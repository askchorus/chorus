import AppKit
import WebKit

/// Which `window.open` / `target=_blank` requests get an in-app popup instead of the default
/// browser. Pure, so the rules are unit-tested.
///
/// Why this exists: "Continue with Google" on claude.ai (and every site using Google's sign-in
/// library) opens a sized popup and waits for it to report back through `window.opener`.
/// Handing that URL to the external browser completes the sign-in over there with no way back,
/// so the panel stays logged out forever. Links a person CLICKS (citations in an answer, "learn
/// more") still belong in the real browser.
enum PopupPolicy {
    /// Identity providers whose pages only make sense as a popup of the page that opened them.
    static let identityHosts = [
        "accounts.google.com", "appleid.apple.com", "github.com",
        "login.microsoftonline.com", "login.live.com", "auth.openai.com",
        "open.weixin.qq.com", "graph.qq.com",
    ]

    static func opensInApp(linkActivated: Bool, hasWindowSize: Bool, targetURL: URL?) -> Bool {
        if linkActivated { return false }            // a clicked link → the browser, as before
        if hasWindowSize { return true }             // script asked for a sized window: a dialog, not a tab
        guard let url = targetURL, let scheme = url.scheme?.lowercased() else { return true }   // blank popup, navigated by script later
        if scheme == "about" { return true }
        guard scheme == "http" || scheme == "https", let host = url.host?.lowercased() else { return false }
        return identityHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// A plain panel for popups. Deliberately NOT `KeyablePanel`: the quick input's key monitors
/// treat any key `KeyablePanel` as theirs and would swallow Return in a password field.
final class AuthPopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the in-app popup windows. Each holds a child WKWebView created from the configuration
/// WebKit supplied — that is what links `window.opener`, so the popup can hand its result back.
@MainActor
final class PopupWindowManager: NSObject, NSWindowDelegate {
    static let shared = PopupWindowManager()

    /// Tests flip this off so exercising the flow doesn't flash windows on screen.
    var presentsWindows = true

    private struct Entry {
        let panel: AuthPopupPanel
        let webView: WKWebView
        let titleObservation: NSKeyValueObservation
    }
    private var entries: [ObjectIdentifier: Entry] = [:]

    var openCount: Int { entries.count }
    var webViews: [WKWebView] { entries.values.map(\.webView) }

    func open(configuration: WKWebViewConfiguration, features: WKWindowFeatures, opener: WKWebView) -> WKWebView {
        let width = min(max(CGFloat(features.width?.doubleValue ?? 520), 380), 900)
        let height = min(max(CGFloat(features.height?.doubleValue ?? 680), 480), 900)

        let child = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
        child.uiDelegate = LinkRoutingDelegate.shared          // window.close() + nested popups
        child.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) { child.isInspectable = true }
        // No navigationDelegate on purpose: the panels' delegate maps hosts to PANELS (a failed
        // Google page would be reported as "Gemini failed to load").

        let panel = AuthPopupPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                   styleMask: [.titled, .closable, .resizable],
                                   backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false        // the user may switch to a password manager mid-login
        panel.isFloatingPanel = false
        panel.title = opener.url?.host ?? "Chorus"
        panel.contentView = child
        panel.delegate = self

        let observation = child.observe(\.title, options: [.new]) { [weak panel] wv, _ in
            guard let t = wv.title, !t.isEmpty else { return }
            Task { @MainActor in panel?.title = t }
        }
        entries[ObjectIdentifier(child)] = Entry(panel: panel, webView: child, titleObservation: observation)

        if presentsWindows {
            if let host = opener.window, host.isVisible {
                let f = host.frame
                panel.setFrameOrigin(NSPoint(x: f.midX - width / 2, y: f.midY - height / 2))
                host.addChildWindow(panel, ordered: .above)     // stays with the main window
            } else {
                panel.center()
            }
            panel.makeKeyAndOrderFront(nil)
        }
        clog("popup opened for \(opener.url?.host ?? "?") (\(Int(width))×\(Int(height)))")
        return child
    }

    /// The page called `window.close()` — the normal end of a sign-in popup.
    func close(_ webView: WKWebView) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(webView)) else { return }
        tearDown(entry)
    }

    /// The user closed the window themselves.
    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? AuthPopupPanel,
              let (key, entry) = entries.first(where: { $0.value.panel === panel }) else { return }
        entries.removeValue(forKey: key)
        tearDown(entry, closingPanel: false)
    }

    private func tearDown(_ entry: Entry, closingPanel: Bool = true) {
        entry.titleObservation.invalidate()
        entry.panel.delegate = nil
        entry.panel.parent?.removeChildWindow(entry.panel)
        entry.webView.uiDelegate = nil
        if closingPanel { entry.panel.close() }
        clog("popup closed")
    }
}
