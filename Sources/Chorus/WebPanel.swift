import SwiftUI
import WebKit

/// Wraps a persistent WKWebView in a container NSView. The WKWebView itself is owned by
/// `WebViewStore`, not by this view — so when SwiftUI re-renders (e.g. after reordering),
/// the same WKWebView is just reparented to the new container instead of being recreated.
/// This preserves navigation state, scroll, in-flight messages, etc.
struct WebPanel: NSViewRepresentable {
    let webView: WKWebView
    /// When true, an opaque cream cover is shown over this panel; when it flips back to false
    /// the cover fades out. Driven by ContentView during a removal reflow so the WKWebView's
    /// white repaint-on-resize is masked. (Animating the resize instead made the white edge
    /// visible for the WHOLE animation, which was worse — hence this cover approach.)
    var reflowing: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        weak var cover: NSView?
        var lastReflowing = false
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = ChorusTheme.windowBackgroundCGColor()
        embed(webView, in: container)

        // Native cream cover ON TOP of the webview. A SwiftUI `.overlay` does NOT render above
        // an embedded WKWebView (AppKit-hosted views punch through SwiftUI layers), so masking
        // the white repaint-on-resize requires a native sibling layered above it.
        let cover = NSView()
        cover.wantsLayer = true
        cover.layer?.backgroundColor = ChorusTheme.windowBackgroundCGColor()
        cover.frame = container.bounds
        cover.autoresizingMask = [.width, .height]
        cover.alphaValue = 0
        cover.isHidden = true
        container.addSubview(cover)               // added last → topmost
        context.coordinator.cover = cover
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Don't steal the webview back while the keeper window holds it (app hidden/minimized —
        // a SwiftUI render during that state would re-embed it into an invisible window and
        // re-freeze the page). It returns via restoreFromKeeper() on unhide.
        if webView.superview !== container && !WebViewStore.shared.isKept(webView) {
            embed(webView, in: container)
        }
        guard let cover = context.coordinator.cover else { return }
        if container.subviews.last !== cover {     // embed() re-adds the webView above it
            cover.removeFromSuperview()
            cover.frame = container.bounds
            cover.autoresizingMask = [.width, .height]
            container.addSubview(cover)
        }
        if context.coordinator.lastReflowing != reflowing {
            context.coordinator.lastReflowing = reflowing
            if reflowing {
                cover.layer?.removeAllAnimations()
                cover.isHidden = false
                cover.alphaValue = 1
            } else {
                NSAnimationContext.runAnimationGroup({ c in
                    c.duration = 0.22
                    cover.animator().alphaValue = 0
                }, completionHandler: { cover.isHidden = true })
            }
        }
    }

    private func embed(_ webView: WKWebView, in container: NSView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }
}

/// Intercepts link clicks in the embedded AI panels and routes external links
/// to Chrome (or the user's default browser if Chrome isn't installed). Keeps
/// same-host navigation in the webview so internal flows like "switch conversation"
/// or "click on a prior message" stay where you'd expect.
@MainActor
final class LinkRoutingDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = LinkRoutingDelegate()
    private override init() { super.init() }

    /// When set, the next file-open panel (triggered by a web page's <input type=file>)
    /// is auto-answered with this URL instead of showing a dialog. This is how we feed
    /// an image into Gemini, which renders no static file input and ignores synthetic
    /// paste/drop. The broadcaster writes the image to a temp file, sets this, then drives
    /// Gemini's "Upload files" menu — WebKit calls runOpenPanel, we supply the file silently.
    /// Single-shot: cleared as soon as it's consumed. Array so a multi-image broadcast can answer
    /// Gemini's file panel with all N files at once.
    var pendingUploads: [URL] = []

    /// Last auto-reload time per webview — guards against reloading in a tight crash loop.
    private var lastReloadAt: [ObjectIdentifier: Date] = [:]

    // Plain link clicks (anchor tags, no target=_blank).
    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let linkHost = url.host ?? ""
        let currentHost = webView.url?.host ?? ""

        // Same-host clicks (e.g. switching ChatGPT conversations, Claude sidebar
        // entries) — keep them inside the panel.
        if isSameSite(linkHost, currentHost) {
            decisionHandler(.allow)
            return
        }

        // External link → punt to Chrome
        Task { @MainActor in Self.openExternally(url) }
        decisionHandler(.cancel)
    }

    // target=_blank and window.open() — never open these inside the panel.
    nonisolated func webView(_ webView: WKWebView,
                             createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction,
                             windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            Task { @MainActor in Self.openExternally(url) }
        }
        return nil
    }

    // Each finished navigation: remember this panel's current URL so we can reopen the
    // last conversation on next launch (gated by the "restore session" setting at read time).
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            WebViewStore.shared.noteNavigationFinished(webView)
            WebViewStore.shared.recoverIfDeadConversation(webView)
            WebViewStore.shared.recordSessionURL(for: webView)
            WebViewStore.shared.fetchFavicon(for: webView)
            if let host = webView.url?.host { WebViewStore.shared.clearLoadFailure(host: host) }
        }
    }

    // A failed page load leaves a blank white panel with no explanation (this bit the user when
    // gemini.google.com's TLS was being reset on their network while Chrome — which falls back to
    // QUIC — still worked). Surface it so the panel can say what happened and offer a retry.
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportLoadFailure(webView, error)
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportLoadFailure(webView, error)
    }

    private nonisolated func reportLoadFailure(_ webView: WKWebView, _ error: Error) {
        let ns = error as NSError
        // -999 is "cancelled": a superseded navigation (SPA redirect, fast reload), not a failure.
        guard ns.code != NSURLErrorCancelled else { return }
        let host = webView.url?.host
            ?? (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
                .flatMap { URL(string: $0)?.host }
            ?? "?"
        let reason = ns.localizedDescription
        Task { @MainActor in
            WebViewStore.shared.noteLoadFailure(host: host, reason: reason)
        }
    }

    // WebContent process crashed (panel goes blank). Auto-reload so it self-heals, but skip
    // if we just reloaded (<10s) to avoid a tight crash loop.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            let id = ObjectIdentifier(webView)
            let now = Date()
            if let last = self.lastReloadAt[id], now.timeIntervalSince(last) < 10 {
                chorusLog.notice("[Chorus.WebKit] content process terminated again <10s — skipping reload (crash-loop guard)")
                return
            }
            self.lastReloadAt[id] = now
            chorusLog.notice("[Chorus.WebKit] content process terminated for \(webView.url?.host ?? "?", privacy: .public) — reloading")
            webView.reload()
        }
    }

    // File upload panel. Web page triggered an <input type=file>. If we have a pending
    // programmatic upload (Gemini image), answer with it silently — no dialog. Otherwise
    // show the real NSOpenPanel so manual uploads inside the panels still work normally.
    nonisolated func webView(_ webView: WKWebView,
                             runOpenPanelWith parameters: WKOpenPanelParameters,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping ([URL]?) -> Void) {
        Task { @MainActor in
            // Only auto-answer for Gemini. Host-scoping prevents a manual file pick in another
            // panel (or a stray panel) from consuming the armed image during its brief window.
            let host = webView.url?.host ?? ""
            let isGemini = host.contains("gemini.google.com") || host.contains("gemini")
            if !self.pendingUploads.isEmpty, isGemini {
                let pending = self.pendingUploads
                self.pendingUploads = []  // single-shot
                chorusLog.notice("[Chorus.OpenPanel] FIRED on \(host, privacy: .public) — auto-supplying \(pending.count) file(s) (no dialog)")
                completionHandler(pending)
            } else {
                // Either no pending upload, or a non-Gemini panel — show the real dialog and
                // leave any armed Gemini upload intact for when Gemini's own panel fires.
                chorusLog.notice("[Chorus.OpenPanel] FIRED on \(host, privacy: .public) — showing NSOpenPanel (pending=\(!self.pendingUploads.isEmpty))")
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = parameters.allowsMultipleSelection
                panel.begin { resp in
                    completionHandler(resp == .OK ? panel.urls : nil)
                }
            }
        }
    }

    /// Hand the URL to the system's default browser (which the user sets in
    /// System Settings → Desktop & Dock → Default web browser). Same fallback
    /// handles mailto:, tel:, etc. — macOS routes to the right app.
    static func openExternally(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Treat related hosts as the same site so internal nav (`accounts.google.com` ↔
    /// `gemini.google.com`) doesn't bounce out. Strict eTLD+1 would need a public-suffix
    /// list; for our three AIs the "same registered domain" heuristic is enough.
    nonisolated private func isSameSite(_ a: String, _ b: String) -> Bool {
        func base(_ h: String) -> String {
            var h = h
            if h.hasPrefix("www.") { h.removeFirst(4) }
            let parts = h.split(separator: ".")
            // last two labels: e.g. "google.com", "openai.com"
            return parts.count >= 2 ? parts.suffix(2).joined(separator: ".") : h
        }
        if a.isEmpty || b.isEmpty { return false }
        return base(a) == base(b)
    }
}

/// Receives diagnostic logs from the broadcast JS and forwards them to macOS
/// unified logging. Lets us debug per-site upload issues without making the
/// user open Web Inspector. Read back with:
///   log show --subsystem com.smiletalker.chorus --info --debug --last 5m
@MainActor
final class JSLogHandler: NSObject, WKScriptMessageHandler {
    static let shared = JSLogHandler()
    private override init() { super.init() }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let s = message.body as? String else { return }
        chorusLog.notice("[Chorus.JS] \(s, privacy: .public)")
    }
}

/// Bridges JS `webkit.messageHandlers.chorusCompletion.postMessage({host})`
/// back to Swift. Singleton — same handler instance is attached to every WKWebView.
@MainActor
final class CompletionScriptHandler: NSObject, WKScriptMessageHandler {
    static let shared = CompletionScriptHandler()

    /// Called on main actor with the page hostname (e.g. "chatgpt.com").
    var onCompletion: ((String) -> Void)?
    /// Called on main actor when a host's streaming state changes (true = started,
    /// false = timed out). Used to drive the per-panel "thinking" status dot.
    var onStreamingState: ((String, Bool) -> Void)?

    private override init() { super.init() }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let host = body["host"] as? String else { return }
        // Diagnostic-only messages: log but don't count as completion.
        if let diag = body["diagnostic"] as? String {
            chorusLog.notice("[Chorus.Poll] \(host, privacy: .public) — \(diag, privacy: .public)")
            if diag == "streaming-started" {
                Task { @MainActor in self.onStreamingState?(host, true) }
            } else if diag == "timeout-no-completion" {
                Task { @MainActor in self.onStreamingState?(host, false) }
            }
            return
        }
        Task { @MainActor in
            self.onCompletion?(host)
        }
    }
}

/// Builds and caches WKWebViews. Used by `WebViewStore` to keep webview instances
/// alive across SwiftUI view rebuilds.
enum WebViewFactory {
    // Standard Safari macOS UA — used by ChatGPT and Claude.
    private static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    // Chrome macOS UA — used for Google services. Google's serving tier historically
    // ships a heavier / legacy JS bundle to non-Chrome UAs (Polymer/Shadow-DOM-v0
    // incident in 2018, ongoing through Gemini era). UA-Client-Hints sometimes
    // sees through this, but a Chrome UA still has ~30-40% chance of unlocking
    // the optimized code path.
    private static let chromeUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    @MainActor
    static func make(url: URL) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // persistent: cookies/login survive app restart
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Public API (macOS 14+): keep the page scheduler running even when the webview
        // is "inactive". Doesn't address occlusion-based throttling by itself, but it
        // closes the "view detached from hierarchy" suspension path. Defensive setting.
        if #available(macOS 14.0, *) {
            config.preferences.inactiveSchedulingPolicy = .none
        }

        // Install completion-detection bridge: JS will postMessage to "chorusCompletion"
        // when a streamed response finishes (send button transitions disabled → enabled).
        config.userContentController.add(CompletionScriptHandler.shared, name: "chorusCompletion")
        // Install diagnostic log bridge so JS `[Chorus]` logs reach unified logging.
        config.userContentController.add(JSLogHandler.shared, name: "chorusJSLog")

        // Keep-alive shims, installed BEFORE any page code runs. The WKPreferences knobs unfreeze
        // page TIMERS for a minimized window, but rendering-tied APIs stay engine-suspended and
        // sites also self-pause when they see the page hidden. Live logs: Kimi (timer-driven)
        // streamed fine while minimized; Claude (rAF-driven pipeline) sat frozen mid-generation
        // until APP didUnhide, then completed within ~1s. Two shims:
        //  - requestAnimationFrame falls back to a 16ms setTimeout whenever the page is hidden
        //    (timers run thanks to the knobs), so rAF-gated stream rendering keeps flowing.
        //  - document.visibilityState/hidden report "visible" and visibilitychange is swallowed,
        //    so sites' own "pause while hidden" logic never engages.
        config.userContentController.addUserScript(
            WKUserScript(source: Broadcaster.keepAliveScript(),
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true)
        )

        // Persistent streaming watcher (auto-runs on every page load): a lightweight,
        // event-driven MutationObserver that reports streaming start/finish even for messages
        // the user sends manually inside a panel (not just our broadcasts). Drives the menu-bar
        // icon + card pulse; never triggers notifications (manual sends aren't broadcast batches).
        config.userContentController.addUserScript(
            WKUserScript(source: Broadcaster.streamingWatcherScript(),
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true)
        )

        // Optional cosmetic warm tint: re-applied on every load (incl. SPA new-chat) so the
        // official pages lean toward the app's cream tone. Off → no script injected at all.
        if UserDefaults.standard.object(forKey: "warmWebPages") as? Bool ?? true {
            config.userContentController.addUserScript(
                WKUserScript(source: Broadcaster.warmTintAddJS,
                             injectionTime: .atDocumentEnd,
                             forMainFrameOnly: true)
            )
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        // The color WebKit paints in areas not yet covered by page content — i.e. before the
        // first paint of a freshly-added panel, and (the real offender here) the strip exposed
        // when a panel WIDENS after an AI is removed. Default is white, which flashed as an ugly
        // block between cards. This is the documented knob for it (macOS 12+).
        //
        // Use a CONCRETE color, not the dynamic `windowBackground`: WebKit does not reliably
        // resolve a dynamic catalog NSColor here and falls back to white. And keep the webview
        // OPAQUE (drawsBackground stays at its default true) — turning it off made WebKit's
        // compositor paint that strip *black*, which is worse than white.
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = ChorusTheme.windowBackgroundColor()
        }

        // Route link clicks: same-site stays in panel, external links → Chrome.
        webView.navigationDelegate = LinkRoutingDelegate.shared
        webView.uiDelegate = LinkRoutingDelegate.shared

        // CRITICAL FIX for background streaming: disable WebKit's "window is occluded →
        // throttle WebContent process" pipeline. This is the same private SPI that
        // WebKitTestRunner uses (WebKit bug 111116) so layout tests aren't disturbed
        // by window visibility. Without this, the user's "send from another app and
        // get notified" workflow doesn't work — pages freeze when our window is hidden.
        // Private API; raises no warning at compile time; only safe outside Mac App Store.
        disableWindowOcclusionDetection(webView)

        // Occlusion is only ONE suspension path. MINIATURIZING the window (or ⌘H) marks the page
        // "not visible", which suppresses the WebContent process and clamps page timers — live
        // logs showed Claude's stream frozen mid-generation for the whole minimized stretch and
        // completing 1.7s after unhide (while native evaluateJavaScript kept answering fine).
        // These WKPreferences SPIs turn that visibility-based suppression off.
        disableBackgroundThrottling(config)

        // EVERYONE gets the real Safari UA now, including Google. A Chrome UA on the WebKit
        // engine is a fingerprint MISMATCH (claims AppleWebKit/537.36 + Chrome but the engine is
        // WebKit 605): Cloudflare flags it as a bot (ChatGPT "verify you are human" loop) and —
        // the reason for this change — Google's sign-in flags it as "此浏览器或应用可能不安全 /
        // this browser or app may not be secure" and BLOCKS login. An authentic Safari UA matches
        // the engine, so sign-in is far more likely to be allowed. (We lose the ~30–40% chance of
        // Google serving Gemini its Chrome-optimized bundle, but being able to log in wins.)
        webView.customUserAgent = safariUA

        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        webView.load(URLRequest(url: url))
        return webView
    }

    /// Turns off WebKit's page-visibility-based suppression via WKPreferences SPI setters:
    /// process suppression (freezes the WebContent process for hidden pages) and hidden-page DOM
    /// timer throttling (clamps/aligns page timers — what froze the completion poll while
    /// minimized). Each setter is feature-checked and no-ops gracefully if the SPI disappears.
    private static func disableBackgroundThrottling(_ config: WKWebViewConfiguration) {
        let prefs = config.preferences
        let knobs: [(selector: String, label: String)] = [
            ("_setPageVisibilityBasedProcessSuppressionEnabled:", "visibility-based process suppression"),
            ("_setHiddenPageDOMTimerThrottlingEnabled:", "hidden-page DOM timer throttling"),
            ("_setHiddenPageDOMTimerThrottlingAutoIncreases:", "hidden-page timer throttling auto-increase"),
        ]
        for knob in knobs {
            let sel = NSSelectorFromString(knob.selector)
            guard prefs.responds(to: sel) else {
                chorusLog.notice("[Chorus.WebKit] SPI missing: \(knob.label, privacy: .public)")
                continue
            }
            typealias SetterIMP = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
            let setter = unsafeBitCast(prefs.method(for: sel), to: SetterIMP.self)
            setter(prefs, sel, ObjCBool(false))
            chorusLog.notice("[Chorus.WebKit] disabled \(knob.label, privacy: .public)")
        }
    }

    /// Invokes the private SPI `-[WKWebView _setWindowOcclusionDetectionEnabled:]`
    /// via the Objective-C runtime. No-ops gracefully if Apple ever removes the SPI.
    private static func disableWindowOcclusionDetection(_ webView: WKWebView) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: selector) else {
            chorusLog.notice("[Chorus.WebKit] _setWindowOcclusionDetectionEnabled: not available — page will throttle in background")
            return
        }
        typealias SetterIMP = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
        let imp = webView.method(for: selector)
        let setter = unsafeBitCast(imp, to: SetterIMP.self)
        setter(webView, selector, ObjCBool(false))
        chorusLog.notice("[Chorus.WebKit] disabled window occlusion detection for \(webView.url?.host ?? "<unknown>", privacy: .public)")
    }
}

enum Broadcaster {
    /// Shared JS helpers, installed as `window.__chorusLib`. Every generated script embeds this
    /// at its top (assignment is idempotent — latest evaluation wins), so there is exactly ONE
    /// source for the stop-button selector list, the shadow-DOM walker, and the scroll/repaint
    /// helpers that used to be copy-pasted per script and drifted apart (the watcher once called
    /// a helper that only the broadcast poll defined — a silent ReferenceError).
    ///
    /// PERF (Gemini): `isStreaming` caches the stop button it finds — while streaming, each call
    /// is one isConnected + visibility check. The whole-tree shadow walk (querySelectorAll('*'))
    /// only runs when there's no cached hit, throttled to every 2.5s except right after the cache
    /// is lost (state transition) or when `force` is passed (busy re-checks, send-verify).
    /// Injected at documentStart on every panel. Keeps site code running while the window is
    /// minimized/hidden: masks page visibility (sites self-pause when they see "hidden") and
    /// backs requestAnimationFrame with a timer so rAF-gated pipelines (Claude's stream
    /// rendering) keep flowing — the engine suspends native rAF for non-visible pages, but the
    /// WKPreferences knobs keep TIMERS alive. Idempotent; runs before any page script.
    static func keepAliveScript() -> String {
        return """
        (() => {
          if (window.__chorusKeepAlive) return;
          window.__chorusKeepAlive = true;

          // REAL hidden state (prototype getter, captured before masking the instance) — the rAF
          // shim needs the truth even though page code sees "visible".
          const protoHidden = Object.getOwnPropertyDescriptor(Document.prototype, 'hidden');
          const realHidden = () => {
            try { return protoHidden && protoHidden.get ? !!protoHidden.get.call(document) : false; }
            catch (_) { return false; }
          };

          // Mask visibility on the instance (prototype stays intact for realHidden()).
          try {
            Object.defineProperty(document, 'visibilityState', { get: () => 'visible', configurable: true });
            Object.defineProperty(document, 'hidden', { get: () => false, configurable: true });
          } catch (_) {}
          // Swallow visibilitychange before site handlers (we're registered first at documentStart).
          const swallow = (e) => { try { e.stopImmediatePropagation(); } catch (_) {} };
          document.addEventListener('visibilitychange', swallow, true);
          window.addEventListener('visibilitychange', swallow, true);

          // rAF dual-drive: schedule the native callback AND a timer backup; first to fire wins.
          // Visible → native wins at vsync (backup no-ops). Hidden → native is suspended, the
          // 16ms timer drives the chain. Transition frames can't stall: the pending pair's backup
          // fires within 100ms and the next request re-evaluates hiddenness.
          const nativeRAF = window.requestAnimationFrame.bind(window);
          const nativeCAF = window.cancelAnimationFrame.bind(window);
          let seq = 1;
          const pending = new Map();   // shimId → {n: nativeId, t: timerId}
          window.requestAnimationFrame = (cb) => {
            const id = -(seq++);   // negative: never collides with native ids
            let done = false;
            const fire = (ts) => {
              if (done) return;
              done = true;
              const p = pending.get(id);
              pending.delete(id);
              if (p) { try { nativeCAF(p.n); } catch (_) {} clearTimeout(p.t); }
              try { cb(ts); } catch (_) {}
            };
            const n = nativeRAF((ts) => fire(ts));
            const t = setTimeout(() => fire(performance.now()),
              realHidden() ? (window.__chorusStreamingActive ? 16 : 750) : 100);
            pending.set(id, { n, t });
            return id;
          };
          window.cancelAnimationFrame = (id) => {
            if (typeof id === 'number' && id < 0) {
              const p = pending.get(id);
              pending.delete(id);
              if (p) { try { nativeCAF(p.n); } catch (_) {} clearTimeout(p.t); }
              return;
            }
            nativeCAF(id);
          };

          // requestIdleCallback is suspended for hidden pages the same way rAF is — back it with
          // a timer so idle-scheduled work (React scheduler et al.) keeps draining while hidden.
          if (typeof window.requestIdleCallback === 'function') {
            const nativeRIC = window.requestIdleCallback.bind(window);
            const nativeCIC = (window.cancelIdleCallback || (() => {})).bind(window);
            const ricPending = new Map();
            window.requestIdleCallback = (cb, opts) => {
              const id = -(seq++);
              let done = false;
              const fire = (deadline) => {
                if (done) return;
                done = true;
                const p = ricPending.get(id);
                ricPending.delete(id);
                if (p) { try { nativeCIC(p.n); } catch (_) {} clearTimeout(p.t); }
                try { cb(deadline || { didTimeout: true, timeRemaining: () => 50 }); } catch (_) {}
              };
              const n = nativeRIC((d) => fire(d), opts);
              const t = setTimeout(() => fire(null),
              realHidden() ? (window.__chorusStreamingActive ? 50 : 1200) : 400);
              ricPending.set(id, { n, t });
              return id;
            };
            window.cancelIdleCallback = (id) => {
              if (typeof id === 'number' && id < 0) {
                const p = ricPending.get(id);
                ricPending.delete(id);
                if (p) { try { nativeCIC(p.n); } catch (_) {} clearTimeout(p.t); }
                return;
              }
              nativeCIC(id);
            };
          }

          // scheduler.postTask (Prioritized Task Scheduling — React's scheduler uses it where
          // available) is another hidden-page-suspended queue. While really hidden, run tasks on
          // a plain timeout instead; while visible, defer to the native implementation.
          if (window.scheduler && typeof window.scheduler.postTask === 'function') {
            const nativePost = window.scheduler.postTask.bind(window.scheduler);
            window.scheduler.postTask = (cb, opts) => {
              if (!realHidden()) return nativePost(cb, opts);
              return new Promise((resolve, reject) => {
                setTimeout(() => { try { resolve(cb()); } catch (e) { reject(e); } },
                           window.__chorusStreamingActive ? 10 : 150);
              });
            };
          }
        })();
        """
    }

    static func libScript() -> String {
        return """
        window.__chorusLib = (() => {
          const isGemini = location.hostname.includes('gemini');

          const STOP_SELECTORS = [
            // ChatGPT
            'button[data-testid="stop-button"]',
            'button[data-testid="composer-stop-button"]',
            // Claude (current UI)
            'button[aria-label="Stop response"]',
            'button[aria-label="Stop Response"]',
            // Gemini (Material Design / mat-icon)
            'button[aria-label*="Stop generating" i]',
            'button[aria-label*="Stop response" i]',
            'button[mattooltip*="Stop" i]',
            'button.send-button[aria-label*="Stop" i]',
            // Generic catch-alls
            'button[data-testid="send-button"][aria-label*="Stop" i]',
            'button[aria-label*="Stop streaming" i]',
            'button[aria-label*="Stop" i]',
            'button[aria-label*="停止" i]',
            'button[aria-label*="중지" i]',
            'button[aria-label*="停止生成" i]',
          ];

          // Query light DOM + every shadow root (Polymer/Lit sites like Gemini hide the composer
          // file input and stop button inside web components). Returns a deduped array.
          const deepQueryAll = (selectors) => {
            const results = [];
            const stack = [document];
            while (stack.length) {
              const root = stack.pop();
              if (!root) continue;
              for (const sel of selectors) {
                try {
                  const found = root.querySelectorAll?.(sel);
                  if (found) for (const el of found) results.push(el);
                } catch (_) {}
              }
              let all; try { all = root.querySelectorAll('*'); } catch (_) { all = []; }
              for (const el of all) if (el.shadowRoot) stack.push(el.shadowRoot);
            }
            return [...new Set(results)];
          };

          // "Really visible": offsetParent alone is too permissive — Gemini's per-message stop
          // affordances pass it while having zero height until their message is hovered.
          const isReallyVisible = (el) => {
            // No offsetParent test: it is null for position:fixed elements (composer bars, and the
            // stop buttons that live in them). The rect + computed-style checks below already
            // reject anything not actually rendered, including display:none ancestors.
            if (!el) return false;
            const rect = el.getBoundingClientRect();
            if (rect.width === 0 || rect.height === 0) return false;
            const style = window.getComputedStyle(el);
            return style.visibility !== 'hidden' && style.display !== 'none';
          };

          const lightScan = () => {
            for (const sel of STOP_SELECTORS) {
              try { for (const el of document.querySelectorAll(sel)) if (isReallyVisible(el)) return el; }
              catch (_) {}
            }
            return null;
          };
          // Shadow-aware scan, short-circuits on the first visible match.
          const deepScan = () => {
            const stack = [document];
            while (stack.length) {
              const root = stack.pop();
              if (!root) continue;
              for (const sel of STOP_SELECTORS) {
                try { for (const el of root.querySelectorAll(sel)) if (isReallyVisible(el)) return el; }
                catch (_) {}
              }
              let all; try { all = root.querySelectorAll('*'); } catch (_) { all = []; }
              for (const el of all) if (el.shadowRoot) stack.push(el.shadowRoot);
            }
            return null;
          };

          let stopEl = null;       // cached visible stop button
          let lastDeepWalk = 0;    // throttle for Gemini's expensive whole-tree walk
          const isStreaming = (force) => {
            if (stopEl && stopEl.isConnected && isReallyVisible(stopEl)) return true;
            const hadCache = !!stopEl;
            stopEl = null;
            const light = lightScan();
            if (light) { stopEl = light; return true; }
            if (!isGemini) return false;
            // Deep walk: skip if throttled — unless forced, or the cache was JUST lost (a real
            // state transition deserves an immediate confirm so "done" isn't declared late/early).
            const now = Date.now();
            if (!force && !hadCache && now - lastDeepWalk < 2500) return false;
            lastDeepWalk = now;
            stopEl = deepScan();
            return !!stopEl;
          };

          // Keep the view pinned to the streaming response — only when already near the bottom,
          // so reading history isn't disturbed. (Claude doesn't auto-follow its own stream.)
          const followBottom = (thresh) => {
            const limit = thresh || 140;
            document.querySelectorAll('[class*="scroll" i], main, [role="main"]').forEach(el => {
              if (el.scrollHeight > el.clientHeight + 4 &&
                  el.scrollHeight - el.clientHeight - el.scrollTop < limit) {
                el.scrollTop = el.scrollHeight;
              }
            });
          };
          // Robust jump-to-end: class-name matching misses Claude's obfuscated classes, so pin
          // the LARGEST genuinely-scrollable element.
          const scrollToEnd = () => {
            try {
              let best = null, bestArea = 0;
              document.querySelectorAll('div, main, section, [role="main"], [class*="scroll" i]').forEach(el => {
                if (el.scrollHeight <= el.clientHeight + 40) return;
                const oy = getComputedStyle(el).overflowY;
                if (oy !== 'auto' && oy !== 'scroll') return;
                const area = el.clientWidth * el.clientHeight;
                if (area > bestArea) { bestArea = area; best = el; }
              });
              if (best) best.scrollTop = best.scrollHeight;
              const se = document.scrollingElement || document.body;
              if (se) window.scrollTo(0, se.scrollHeight);
            } catch (_) {}
          };
          // On completion, prefer landing at the START of the latest answer (read from the top).
          const scrollLatestAnswerTop = () => {
            try {
              const ums = document.querySelectorAll('[data-message-author-role="user"], [data-testid="user-message"], [data-testid="human-turn"]');
              const last = ums[ums.length - 1];
              if (last) { last.scrollIntoView({ block: 'start', behavior: 'auto' }); return true; }
            } catch (_) {}
            return false;
          };
          const scrollOnComplete = () => {
            const go = () => { if (!scrollLatestAnswerTop()) scrollToEnd(); };
            go(); setTimeout(go, 300); setTimeout(go, 800);   // retries catch post-stream re-render
          };
          // Gentle repaint for Gemini's virtualized renderer during streaming.
          const geminiRepaint = () => {
            try { window.dispatchEvent(new Event('resize')); } catch (_) {}
            document.querySelectorAll('[class*="scroll" i], main, [role="main"]').forEach(el => {
              if (el.scrollHeight > el.clientHeight + 4) {
                const nearBottom = el.scrollHeight - el.clientHeight - el.scrollTop < 140;
                if (nearBottom) { el.scrollTop = el.scrollHeight; }
                else { const t = el.scrollTop; el.scrollTop = t + 1; el.scrollTop = t; }
              }
            });
          };
          // Aggressive repaint for when Gemini FINISHES but leaves the answer unpainted: jiggle
          // the largest scroller by a real amount + force a reflow so the final paint commits.
          const geminiForceRepaint = () => {
            try {
              window.dispatchEvent(new Event('resize'));
              let best = null, bestArea = 0;
              document.querySelectorAll('div, main, section, [role="main"], [class*="scroll" i]').forEach(el => {
                if (el.scrollHeight <= el.clientHeight + 20) return;
                const oy = getComputedStyle(el).overflowY;
                if (oy !== 'auto' && oy !== 'scroll') return;
                const area = el.clientWidth * el.clientHeight;
                if (area > bestArea) { bestArea = area; best = el; }
              });
              if (best) {
                const t = best.scrollTop;
                best.scrollTop = Math.max(0, t - 80); best.scrollTop = t + 80; best.scrollTop = t;
                void best.offsetHeight;   // force reflow → paint
              }
              void document.body.offsetHeight;
            } catch (_) {}
          };
          // Per-tick nudge for occluded windows (IntersectionObserver lazy rendering skips
          // offscreen content until a scroll pokes it). Net-zero scroll, harmless.
          const paintNudge = () => {
            try {
              const sx = window.scrollX, sy = window.scrollY;
              window.scrollTo(sx, sy + 0.1);
              window.scrollTo(sx, sy);
              if (isGemini) geminiRepaint(); else followBottom();
            } catch (_) {}
          };
          // The completion combo both trackers use: Gemini gets the aggressive repaint burst
          // (its stalled final paint), everyone else lands at the start of the finished answer.
          const finishPaint = () => {
            if (isGemini) {
              geminiForceRepaint();
              setTimeout(geminiForceRepaint, 250); setTimeout(geminiForceRepaint, 700); setTimeout(geminiForceRepaint, 1500);
            } else {
              scrollOnComplete();
            }
          };

          // Total text length of the LAST assistant turn — deliberately INCLUDING thinking and
          // tool-call blocks, so a model that pauses mid-answer (Kimi's agentic searches) still
          // reads as active. Feeds the poll's text-settle completion fallback for sites whose stop
          // button doesn't match STOP_SELECTORS. Returns -1 when it can't measure.
          const activityLen = () => {
            try {
              const h = location.hostname;
              let el = null;
              if (h.includes('kimi') || h.includes('moonshot')) {
                const segs = document.querySelectorAll('.segment.segment-assistant, .segment-assistant');
                el = segs[segs.length - 1];
              } else if (h.includes('manus')) {
                // Agent transcript: measure the WHOLE conversation column, so the long tool-running
                // pauses between steps still read as "growing" rather than finished.
                el = document.querySelector('main') || document.body;
              } else {
                const ns = document.querySelectorAll('.ds-markdown, .markdown, [class*="markdown"]');
                el = ns[ns.length - 1];
              }
              if (!el) return -1;
              return (el.innerText || '').length;
            } catch (_) { return -1; }
          };

          return { isGemini, STOP_SELECTORS, deepQueryAll, isReallyVisible, isStreaming, activityLen,
                   followBottom, scrollToEnd, scrollLatestAnswerTop, scrollOnComplete,
                   geminiRepaint, geminiForceRepaint, paintNudge, finishPaint };
        })();
        """
    }

    /// Builds the JS payload that injects text and (optionally) an image into the AI site,
    /// then clicks send once the send button becomes enabled.
    /// - Parameters:
    ///   - text: prompt text (may be empty if image-only)
    ///   - imageBase64: base64-encoded PNG bytes, or nil
    ///   - imageMime: MIME type of the image, defaults to "image/png"
    ///   - waitForGeminiUpload: when true, the script attaches NO image itself but first waits
    ///     for an externally-supplied image (Gemini's runOpenPanel upload) to finish appearing
    ///     in the composer before typing + sending. Avoids firing send on a half-uploaded image.
    static func injectionScript(text: String, imagesBase64: [String] = [], imageMime: String = "image/png", waitForGeminiUpload: Bool = false) -> String {
        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")

        let imagesJS = "[" + imagesBase64.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let mimeJS = "\"\(imageMime)\""
        let waitUploadJS = waitForGeminiUpload ? "true" : "false"

        return """
        \(libScript())
        (async () => {
          const TEXT = "\(escapedText)";
          const IMAGES_B64 = \(imagesJS);   // array of base64 PNGs (may be empty)
          const IMAGE_MIME = \(mimeJS);
          const WAIT_UPLOAD = \(waitUploadJS);

          // Diagnostic log → Swift (visible in `log show --subsystem com.smiletalker.chorus`).
          const clog = (msg) => {
            try {
              window.webkit?.messageHandlers?.chorusJSLog?.postMessage(
                location.hostname + ': ' + msg
              );
            } catch (_) {}
            try { console.log('[Chorus]', msg); } catch (_) {}
          };

          const HOSTS = [
            {
              host: 'chatgpt.com',
              inputSelectors: ['#prompt-textarea', 'main div[contenteditable="true"]'],
              sendSelectors: [
                'button[data-testid="send-button"]',
                'button[data-testid="composer-send-button"]',
                'button[aria-label*="Send" i]'
              ],
              uploadMethod: 'fileInput',   // multiple-capable <input>; paste only carries ONE image
              fileInputSelectors: [
                'input[type="file"][multiple][accept]',
                'input[type="file"][accept*="image"]',
                'input[type="file"]'
              ],
            },
            {
              host: 'claude.ai',
              inputSelectors: [
                'div[contenteditable="true"].ProseMirror',
                'fieldset div[contenteditable="true"]',
                'div[contenteditable="true"]'
              ],
              sendSelectors: [
                'button[aria-label="Send Message"]',
                'button[aria-label="Send message"]',
                'button[aria-label*="Send" i]'
              ],
              uploadMethod: 'fileInput',   // ProseMirror paste reads files[0] only → use the input
              fileInputSelectors: [
                'input[type="file"][accept*="image"]',
                'input[data-testid*="file"]',
                'input[type="file"]'
              ],
            },
            {
              host: 'gemini.google.com',
              inputSelectors: [
                'rich-textarea div.ql-editor[contenteditable="true"]',
                'div.ql-editor[contenteditable="true"]',
                'div[contenteditable="true"]'
              ],
              // Ordered most-specific first. The 2026 redesign moved the class onto the
              // <gem-icon-button> wrapper (so the old 'button.send-button' matches nothing) and,
              // critically, the loose 'aria-label*="Send"' catch-all can match a SIDEBAR entry —
              // "More options for <chat title>" — whenever a conversation title contains "send".
              // The sidebar comes first in DOM order, so that stray menu button won the lookup and
              // broadcasts opened a menu instead of sending. :not() keeps the catch-all safe.
              sendSelectors: [
                'gem-icon-button.send-button button',
                'button[aria-label="Send message"]',
                'button[aria-label="发送消息"]',
                'gem-icon-button.send-button',
                'button.send-button',
                'button[data-test-id="send-button"]',
                'button[mattooltip*="Send" i]',
                'button[aria-label^="发送"]',
                'button[aria-label*="Send" i]:not([aria-label*="More options" i]):not([aria-label*="更多" i])'
              ],
              // Gemini's image upload goes through the native runOpenPanel path
              // (geminiUploadViaPanel), not this script — so no upload selectors here.
            },
            {
              // Verified against the live DOM 2026-07-23. Kimi's send control is a DIV (never
              // matched the button-only generic selectors → every send burned the full deadline
              // before the Enter fallback), its disabled state is a CSS class, there is no
              // <input type=file> at rest (created lazily), synthetic paste is ignored but a
              // synthetic DROP on the editor attaches properly, and attachment previews are
              // .image-thumbnail chips (no blob:/data: <img>, so the generic attachment gate
              // never saw them and always waited its full 8s).
              // Verified against the live DOM 2026-08-10. Manus's composer is TipTap/ProseMirror
              // (our execCommand+InputEvent typing drives it correctly — confirmed by watching the
              // send button flip from disabled to enabled). Its send control carries NO aria-label,
              // data-testid, type=submit or form — only Tailwind classes — so it is resolved
              // structurally instead: the last button in the composer's control row.
              host: 'manus.im',
              inputSelectors: [
                'div[contenteditable="true"].tiptap',
                'div[contenteditable="true"].ProseMirror',
                'div[contenteditable="true"]'
              ],
              sendResolve: () => {
                const ed = document.querySelector('div[contenteditable="true"].tiptap')
                  || document.querySelector('div[contenteditable="true"]');
                if (!ed) return null;
                let box = ed, hops = 0;
                while (box && hops < 6 && box.querySelectorAll('button').length < 2) {
                  box = box.parentElement; hops++;
                }
                if (!box) return null;
                const btns = [...box.querySelectorAll('button')].filter(b => {
                  const r = b.getBoundingClientRect();   // rect, not offsetParent (fixed bars)
                  return r.width > 0 && r.height > 0;
                });
                return btns.length ? btns[btns.length - 1] : null;   // disabled until text lands
              },
              sendSelectors: [],
              uploadMethod: 'fileInput',
              fileInputSelectors: ['input[type="file"][accept*="image"]', 'input[type="file"]'],
            },
            {
              // Verified against the live DOM 2026-08-30. DeepSeek web's controls are all DIVs
              // with hashed classes and no aria-labels, so the generic selectors never matched
              // and every text send burned the full deadline before the Enter fallback. The send
              // control is the one circular primary role=button; its disabled state is the BEM
              // modifier class ds-button--disabled (caught by the --disabled check in the loop).
              host: 'deepseek.com',
              inputSelectors: ['textarea'],
              sendSelectors: ['div[role="button"].ds-button--primary.ds-button--circle'],
              uploadMethod: 'fileInput',
              fileInputSelectors: ['input[type="file"][accept*="image"]', 'input[type="file"]'],
            },
            {
              host: 'kimi.com',
              inputSelectors: [
                'div[contenteditable="true"].chat-input-editor',
                'div[contenteditable="true"]'
              ],
              // Click the inner SVG (deepest child) so the events bubble up THROUGH the container —
              // dispatching on the container would never reach a listener on the icon.
              sendSelectors: ['.send-button-container svg', '.send-button-container'],
              uploadMethod: 'drop',
              dropTargetSelectors: ['div[contenteditable="true"].chat-input-editor'],
              attachmentSelectors: ['.chat-editor-attachment-area .image-thumbnail'],
            },
          ];

          let cfg = HOSTS.find(c =>
            location.hostname === c.host || location.hostname.endsWith('.' + c.host)
          );
          if (!cfg) {
            // User-added provider — no tuned selectors. Most chat AIs use a contenteditable
            // or textarea plus a Send button (or Enter), so a broad set usually works for text.
            // Image upload isn't guaranteed for these (best-effort paste only).
            cfg = {
              host: location.hostname,
              // contenteditable / textarea only — NOT input[type=text], which would match a
              // logged-out page's email/search field and hide the "not logged in" signal.
              inputSelectors: ['div[contenteditable="true"]', 'textarea'],
              sendSelectors: [
                'button[aria-label*="Send" i]',
                'button[data-testid*="send" i]',
                'button[class*="send" i]',
                'button[type="submit"]',
              ],
              uploadMethod: 'paste',
              fileInputSelectors: ['input[type="file"][accept*="image"]', 'input[type="file"]'],
            };
            clog('using generic config for ' + location.hostname);
          }

          // offsetParent is null for position:fixed elements — and floating composer bars are
          // usually fixed. Testing visibility that way made us skip Gemini's real send button and
          // fall through to a stray sidebar match; measure the box instead.
          const onScreen = (el) => {
            try {
              const r = el.getBoundingClientRect();
              return r.width > 0 && r.height > 0;
            } catch (_) { return false; }
          };

          const pickFirst = (selectors) => {
            for (const sel of selectors) {
              const el = document.querySelector(sel);
              if (el && onScreen(el)) return el;
            }
            for (const sel of selectors) {
              const el = document.querySelector(sel);
              if (el) return el;
            }
            return null;
          };

          const pickAll = (selectors) => {
            const results = [];
            for (const sel of selectors) {
              document.querySelectorAll(sel).forEach(el => results.push(el));
            }
            return [...new Set(results)];
          };

          // Shadow-root-aware query (Gemini's composer file input hides in a web component) —
          // shared implementation from the lib.
          const deepQueryAll = window.__chorusLib.deepQueryAll;

          // Wait for the composer input to exist before giving up. A broadcast can fire while the
          // page is still settling (fresh chat, post-reload hydration, a React re-render of the
          // composer), and a single-shot lookup would bail and leave the panel blank while the
          // others answer. Poll up to 8s.
          let input = pickFirst(cfg.inputSelectors);
          if (!input && (TEXT || IMAGES_B64.length)) {
            const inputDeadline = Date.now() + 8000;
            while (Date.now() < inputDeadline) {
              await new Promise(r => setTimeout(r, 200));
              input = pickFirst(cfg.inputSelectors);
              if (input) break;
            }
          }
          if (!input && (TEXT || IMAGES_B64.length)) return 'input not found';

          // 1) Attach image FIRST (if any)
          // Reason: some composers (Claude) clear the input on paste-with-file.
          // Doing image first means the file attaches to a separate attachment slot,
          // and text inserted afterwards lands cleanly in the empty editor.
          let imageAttached = false;
          if (IMAGES_B64.length) {
            // Decode each base64 → File.
            const ext = IMAGE_MIME.split('/')[1] || 'png';
            const files = IMAGES_B64.map((b64, i) => {
              const byteString = atob(b64);
              const bytes = new Uint8Array(byteString.length);
              for (let j = 0; j < byteString.length; j++) bytes[j] = byteString.charCodeAt(j);
              return new File([new Blob([bytes], { type: IMAGE_MIME })], `pasted-${i}.${ext}`, { type: IMAGE_MIME });
            });

            const method = cfg.uploadMethod || 'paste';

            // Each strategy builds ONE DataTransfer carrying ALL files and fires its event ONCE —
            // never one event per file (sequential single-file attaches race React's state-commit
            // and usually leave only the LAST image, the classic "only the last one attached" bug).
            const tryPaste = () => {
              if (!input) return false;
              try {
                const dt = new DataTransfer();
                for (const f of files) dt.items.add(f);
                input.focus();
                input.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
                return true;
              } catch (e) { return false; }
            };

            const tryDrop = () => {
              const targets = (cfg.dropTargetSelectors || cfg.inputSelectors)
                .flatMap(sel => Array.from(document.querySelectorAll(sel))).filter(Boolean);
              if (targets.length === 0) return false;
              for (const target of targets) {
                try {
                  const dt = new DataTransfer();
                  for (const f of files) dt.items.add(f);
                  ['dragenter', 'dragover', 'drop'].forEach(type =>
                    target.dispatchEvent(new DragEvent(type, { dataTransfer: dt, bubbles: true, cancelable: true })));
                  return true;
                } catch (e) { /* try next target */ }
              }
              return false;
            };

            const tryFileInput = () => {
              const fileInputs = deepQueryAll(cfg.fileInputSelectors || ['input[type="file"]']);
              clog('tryFileInput: deep-found ' + fileInputs.length + ' inputs, attaching ' + files.length + ' file(s)');
              if (fileInputs.length === 0) return false;
              for (const fi of fileInputs) {
                try {
                  const dt = new DataTransfer();
                  for (const f of files) dt.items.add(f);
                  fi.files = dt.files;   // .files has a real native setter; inputs are uncontrolled
                  fi.dispatchEvent(new Event('change', { bubbles: true }));
                  clog('tryFileInput: set ' + dt.files.length + ' file(s) on ' + (fi.outerHTML || '?').slice(0, 100));
                  return true;
                } catch (e) { clog('tryFileInput: threw — ' + e); }
              }
              return false;
            };

            const order = method === 'drop'
              ? [['drop', tryDrop], ['fileInput', tryFileInput], ['paste', tryPaste]]
              : method === 'fileInput'
                ? [['fileInput', tryFileInput], ['paste', tryPaste], ['drop', tryDrop]]
                : [['paste', tryPaste], ['fileInput', tryFileInput], ['drop', tryDrop]];

            // Count attachment previews / remove-buttons BEFORE attaching, so images already in
            // the conversation don't inflate the gate and make it pass before the NEW ones commit.
            const attachmentCount = () => {
              try {
                // Site-tuned preview selector wins (Kimi's chips are divs with no blob <img> and
                // no aria-labeled remove button, invisible to the heuristics below).
                if (cfg.attachmentSelectors) {
                  const tuned = deepQueryAll(cfg.attachmentSelectors).length;
                  if (tuned > 0) return tuned;
                }
                const imgs = deepQueryAll(['img[src^="blob:"]', 'img[src^="data:image"]']).length;
                const rms = deepQueryAll(['button[aria-label*="remove" i]', 'button[aria-label*="delete" i]',
                                          'button[aria-label*="移除" i]', 'button[aria-label*="删除" i]']).length;
                return Math.max(imgs, rms);
              } catch (_) { return 0; }
            };
            const baseline = attachmentCount();

            for (const [name, fn] of order) {
              let ok = false;
              try { ok = await fn(); } catch (e) { clog(name + ' threw: ' + e); }
              clog('strategy ' + name + ' returned ' + ok);
              if (ok) { imageAttached = true; break; }
            }

            // Only wait if something actually attached (else we'd burn the timeout for nothing).
            // Wait for the NEW attachments (delta over baseline) so a multi-image set isn't sent
            // half-attached; cap 8s so a selector miss can't stall the send too long.
            if (imageAttached) {
              const need = files.length;
              const waitStart = Date.now();
              while (Date.now() - waitStart < 8000) {
                if (attachmentCount() >= baseline + need) break;
                await new Promise(r => setTimeout(r, 300));
              }
              await new Promise(r => setTimeout(r, 500));   // settle
              clog('multi-image: ' + (attachmentCount() - baseline) + '/' + need + ' new after ' + (Date.now() - waitStart) + 'ms');
            }
          }

          // 1b) Gemini panel-upload path: the image is uploaded out-of-band (native
          //     runOpenPanel), so this script attaches nothing — but it MUST wait for the
          //     image to finish appearing in the composer before typing/sending, or Gemini
          //     sends a text-only message ("you forgot the image"). Poll for the uploaded
          //     thumbnail (blob:/data: img) or a remove-attachment affordance.
          if (WAIT_UPLOAD) {
            // Phase 1 — wait for the local preview thumbnail to appear (upload accepted).
            // NOTE: this shows INSTANTLY (a blob: preview) and does NOT mean the server-side
            // upload is done. It's only "the file was accepted into the composer".
            const thumb = () => deepQueryAll(['img[src^="blob:"]', 'img[src^="data:image"]'])
              .concat(deepQueryAll(['button[aria-label*="remove" i]', 'button[aria-label*="delete" i]',
                                    'button[aria-label*="移除" i]', 'button[aria-label*="删除" i]']));
            const t0 = Date.now();
            while (Date.now() - t0 < 20000) {
              if (thumb().length) break;
              await new Promise(r => setTimeout(r, 250));
            }
            clog('WAIT_UPLOAD: preview appeared=' + (thumb().length > 0) + ' after ' + (Date.now() - t0) + 'ms');

            // Visible upload spinner/progress indicator. Gemini is Angular Material, so the
            // in-progress affordance is likely a mat spinner / progressbar. Diagnostic dump too.
            const spinners = () => deepQueryAll([
              'mat-progress-spinner', 'mat-spinner', '.mat-mdc-progress-spinner', '.mdc-circular-progress',
              '[role="progressbar"]', 'circular-progress',
              '[class*="spinner" i]', '[class*="uploading" i]', '[class*="progress" i]',
            ]).filter(el => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; });
            const s0 = spinners();
            clog('WAIT_UPLOAD: visible spinners=' + s0.length);
            s0.slice(0, 5).forEach((s, i) =>
              clog('  spinner[' + i + ']: <' + s.tagName.toLowerCase() + '> cls="' + (s.className || '').toString().slice(0, 60) + '"'));

            // Phase 2 — wait for the server upload to FINISH. Heuristic: at least a 4s floor
            // (covers normal uploads even if our spinner selectors miss), then break early once
            // no spinner is visible; hard cap 22s for big images / slow networks.
            const minWait = 4000, maxWait = 22000;
            const t1 = Date.now();
            while (Date.now() - t1 < maxWait) {
              const elapsed = Date.now() - t1;
              if (elapsed >= minWait && spinners().length === 0) break;
              await new Promise(r => setTimeout(r, 300));
            }
            clog('WAIT_UPLOAD: finished waiting (spinners=' + spinners().length + ', waited=' + (Date.now() - t1) + 'ms)');
          }

          // 2) Set text AFTER image is attached.
          //    Use collapse(false) so the cursor lands at the END of any existing
          //    content (including any inline image node), instead of replacing it.
          if (TEXT && input) {
            input.focus();
            if (input.isContentEditable) {
              const sel = window.getSelection();
              sel.removeAllRanges();
              const r = document.createRange();
              r.selectNodeContents(input);
              // No image: keep the FULL selection so insertText REPLACES any stale, unsent text —
              // otherwise a Gemini send that failed leaves its prompt in the composer and the next
              // broadcast piles a second question on top of it. With an image, collapse to the end
              // so we append after the attachment node instead of wiping it.
              if (IMAGES_B64.length || WAIT_UPLOAD) { r.collapse(false); }
              sel.addRange(r);
              document.execCommand('insertText', false, TEXT);
              // Arm rich editors (Gemini's Quill / Angular) whose send button only ENABLES on a
              // real input event — execCommand alone may not fire one in WKWebView, so the button
              // stays aria-disabled and the prompt strands in the composer.
              try {
                input.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: TEXT }));
              } catch (_) {
                input.dispatchEvent(new Event('input', { bubbles: true }));
              }
            } else {
              const proto = input instanceof HTMLTextAreaElement
                ? HTMLTextAreaElement.prototype
                : HTMLInputElement.prototype;
              const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
              const currentValue = input.value || '';
              setter.call(input, currentValue + TEXT);
              input.dispatchEvent(new Event('input', { bubbles: true }));
            }
            // Small settle delay so the editor's reactive state catches up before send
            await new Promise(r => setTimeout(r, 150));
          }

          // 3) Wait for send button to become enabled (image uploads can take 10–20s),
          //    then trigger send. Try a real click first; if button stays disabled past the
          //    deadline, click it anyway as a last-ditch attempt; finally fall back to a
          //    synthesized Enter on the input (some sites send via key event not button).
          const sendDeadline = Date.now() + ((IMAGES_B64.length || WAIT_UPLOAD) ? 25000 : 8000);
          let lastBtn = null;
          let clicked = false;

          // Re-resolve the composer on EVERY use: Angular/React re-render it (Gemini especially),
          // detaching the node captured at the start — a detached node reads as empty and swallows
          // dispatched events.
          const liveInput = () => pickFirst(cfg.inputSelectors) || input;
          const composerText = () => {
            try {
              const el = liveInput();
              return ((el.isContentEditable ? el.innerText : el.value) || '').trim();
            } catch (_) { return ''; }
          };

          // Shadow-DOM-aware send-button lookup, used when the light-DOM query comes up empty
          // (web-component composers hide their controls inside a shadow root).
          const deepPickSend = () => {
            try {
              const els = deepQueryAll(cfg.sendSelectors || []);
              return els.find(e => onScreen(e)) || els[0] || null;
            } catch (_) { return null; }
          };

          // Make a framework re-read the composer's DOM. Gemini renders its send button only once
          // Angular registers non-empty input; when our typing doesn't reach that model no button
          // ever appears AND synthetic Enter is ignored (it consults the same model) — the exact
          // "text sits in the box, nothing sends" failure. Re-firing input events (plus a
          // space-then-delete edit, which is a real model change) wakes it up.
          const nudgeEditor = () => {
            const el = liveInput();
            if (!el) return;
            try { el.focus(); } catch (_) {}
            try {
              el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: ' ' }));
            } catch (_) {
              el.dispatchEvent(new Event('input', { bubbles: true }));
            }
            try {
              document.execCommand('insertText', false, ' ');
              document.execCommand('delete', false);
            } catch (_) {}
            el.dispatchEvent(new Event('change', { bubbles: true }));
            el.dispatchEvent(new KeyboardEvent('keyup', { key: 'a', bubbles: true }));
          };
          let nudges = 0;

          // Dispatch the full pointer/mouse event sequence (for sites that listen to them),
          // then trigger the click EXACTLY ONCE via el.click(). Calling both
          // dispatchEvent('click') AND el.click() fires the click handler twice — that
          // was causing ChatGPT to send the message twice.
          const fullClick = (el) => {
            const rect = el.getBoundingClientRect();
            const opts = {
              bubbles: true, cancelable: true,
              clientX: rect.left + rect.width / 2,
              clientY: rect.top + rect.height / 2,
              button: 0, view: window,
            };
            try { el.dispatchEvent(new PointerEvent('pointerdown', opts)); } catch (_) {}
            el.dispatchEvent(new MouseEvent('mousedown', opts));
            try { el.dispatchEvent(new PointerEvent('pointerup', opts)); } catch (_) {}
            el.dispatchEvent(new MouseEvent('mouseup', opts));
            // SVG elements have no .click() — fall back to ONE synthetic click event (never both,
            // which would double-send on sites whose handler listens for 'click').
            try { el.click(); } catch (_) { el.dispatchEvent(new MouseEvent('click', opts)); }
          };

          const sendLoopStart = Date.now();
          while (Date.now() < sendDeadline) {
            // cfg.sendResolve: structural lookup for composers whose send control carries no
            // identifying attributes at all (Manus). Tried first, then selectors, then a
            // shadow-DOM-aware deep query.
            let btn = null;
            if (cfg.sendResolve) { try { btn = cfg.sendResolve(); } catch (_) {} }
            btn = btn || pickFirst(cfg.sendSelectors) || deepPickSend();
            // Backstop against label collisions like Gemini's "More options for <chat titled …
            // SEND>": clicking a menu opens it instead of sending, and the prompt strands.
            if (btn) {
              const lbl = (btn.getAttribute && btn.getAttribute('aria-label') || '');
              if (/more options|更多选项|options for/i.test(lbl)) {
                clog('send: ignoring label collision — "' + lbl.slice(0, 40) + '"');
                btn = null;
              }
            }
            if (btn) {
              lastBtn = btn;
              // Disabled = attribute (real <button>s) OR a 'disabled' CSS class on the element or
              // an ancestor — Kimi's send control is <div class="send-button-container disabled">
              // with neither attribute, and we click its inner svg (class lives on the parent) —
              // OR a BEM-style modifier like DeepSeek's ds-button--disabled.
              const cls = (btn.getAttribute && btn.getAttribute('class')) || '';
              const isDisabled = btn.disabled || btn.getAttribute('aria-disabled') === 'true'
                || !!(btn.closest && btn.closest('.disabled'))
                || cls.split(/\\s+/).some(c => c === 'disabled' || c.endsWith('--disabled'));
              if (!isDisabled) {
                fullClick(btn);
                clicked = true;
                break;
              }
            } else if (composerText() !== '' && nudges < 6) {
              // Button not rendered yet but text IS in the composer → the framework probably
              // hasn't registered our input. Wake it, then keep polling (see nudgeEditor).
              nudges++;
              if (nudges === 1) clog('send: no button yet, text present — nudging the editor');
              nudgeEditor();
            } else if (!lastBtn && Date.now() - sendLoopStart > ((IMAGES_B64.length || WAIT_UPLOAD) ? 5000 : 2500)) {
              // No element has EVER matched the send selectors — more waiting can't help (the
              // long deadlines exist to wait for a FOUND button to enable, e.g. during upload).
              // Bail to the Enter fallback instead of burning the full deadline. Gating this to
              // the image path made every text send on an unmatched site (DeepSeek before it had
              // tuned selectors) sit out the whole 8s — the "takes forever to send" complaint.
              break;
            }
            await new Promise(r => setTimeout(r, 200));
          }

          if (!clicked && lastBtn) {
            // Last-ditch: click anyway even if it still reports disabled.
            fullClick(lastBtn);
            clicked = true;
          }

          if (!clicked && input) {
            // Final fallback: simulate Enter on the input (some composers send on Enter).
            // Count it as a send attempt so Enter-based sites don't report a false failure.
            input.focus();
            input.dispatchEvent(new KeyboardEvent('keydown', {
              key: 'Enter', code: 'Enter', keyCode: 13, which: 13,
              bubbles: true, cancelable: true,
            }));
            clicked = true;
          }
          clog('send: clicked=' + clicked + ', btnFound=' + !!lastBtn +
               (lastBtn ? ', btn="' + (lastBtn.getAttribute('aria-label') || (lastBtn.outerHTML || '').slice(0, 80)) + '"' : ' (fell back to Enter)'));

          // 3b) Verify the send actually TOOK. Gemini's Angular composer sometimes swallows
          //     the synthetic click (the button looks enabled before the framework has armed
          //     its handler), leaving the text stranded in the input — the panel then looks
          //     like it ignored the broadcast. On every host a successful send clears the
          //     composer immediately, so "text still in the composer" = the send didn't land.
          //     Retry: wake the framework with a fresh input event, re-click, then fall back
          //     to a synthesized Enter (Gemini sends on Enter).
          if (TEXT && input) {
            // liveInput / composerText are defined above the send loop — they re-resolve the
            // composer on every use because Angular/React re-render it (Gemini especially), and a
            // detached node both reads as empty and swallows dispatched events.
            //
            // A successful send EITHER clears the composer OR makes a stop button appear (streaming
            // started). Checking both prevents a re-send — and a double-posted message — when an AI
            // begins generating without clearing its editor. force=true bypasses the Gemini deep-walk
            // throttle: these ≤3 checks decide whether to re-send, so accuracy beats the walk cost.
            const sent = () => {
              const empty = composerText() === '';
              const stop = window.__chorusLib.isStreaming(true);
              if (empty || stop) {
                clog('send-verify: accepted (composerEmpty=' + empty + ', stopVisible=' + stop + ')');
                return true;
              }
              return false;
            };
            for (let attempt = 1; attempt <= 3; attempt++) {
              await new Promise(r => setTimeout(r, 1500));
              if (sent()) break;   // composer cleared or streaming started → send accepted
              clog('send-verify: still stranded (len=' + composerText().length + ') after wait ' + attempt + ' — retrying');
              const el = liveInput();   // the CURRENT composer, not the possibly-detached original
              try {
                el.focus();
                // Nudge the framework's change detection so the send handler is really armed.
                el.dispatchEvent(new InputEvent('input', { bubbles: true }));
              } catch (_) {}
              await new Promise(r => setTimeout(r, 250));
              // The click keeps getting swallowed by Gemini's Angular handler, so ESCALATE through a
              // different send path on each retry (one per attempt, so a method that DID work can't
              // double-post): re-click → full synthetic Enter sequence → submit the enclosing form.
              const kOpts = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
              el.focus();
              if (attempt === 1) {
                const btn = pickFirst(cfg.sendSelectors);
                if (btn) fullClick(btn);
              } else if (attempt === 2) {
                el.dispatchEvent(new KeyboardEvent('keydown', kOpts));
                el.dispatchEvent(new KeyboardEvent('keypress', kOpts));
                el.dispatchEvent(new KeyboardEvent('keyup', kOpts));
              } else {
                try { el.closest('form')?.requestSubmit?.(); } catch (_) {}
                el.dispatchEvent(new KeyboardEvent('keydown', kOpts));
                el.dispatchEvent(new KeyboardEvent('keyup', kOpts));
              }
            }
            if (composerText() !== '' && !window.__chorusLib.isStreaming(true)) {
              clog('send-verify: GAVE UP — text still stranded after 3 escalation retries');
            }
          }

          // 4) Async completion poll. We detect "currently streaming" via EITHER:
          //    (a) a stop/cancel button is present in the composer area, OR
          //    (b) the send button is present but disabled.
          //    ChatGPT/Claude/Gemini all REPLACE send with stop during streaming, so (a)
          //    is the primary signal. We also keep (b) as a backup for sites that just
          //    disable the send button. Transition "streaming → not streaming" = done.
          (() => {
            // Streaming detection + repaint helpers come from the shared lib (single source of
            // truth; the Gemini deep-walk is cached + throttled there).
            const { isStreaming, paintNudge, finishPaint, activityLen } = window.__chorusLib;

            // Only ONE completion poll per page at a time. A new broadcast cancels the prior
            // poll — otherwise every send spun up its own 5-minute interval and they stacked,
            // each doing DOM work every tick (a big reason ChatGPT got sluggish after a few sends).
            if (window.__chorusPoll) { clearInterval(window.__chorusPoll); window.__chorusPoll = null; }

            let wasStreaming = false;
            let idleTicks = 0;
            // Text-settle fallback state (only used when the stop button never matches).
            let lastLen = -1, grewOnce = false, settleTicks = 0;
            const SETTLE_TICKS = 15;   // 15 * 800ms = 12s quiet — long enough to ride out tool-call pauses
            const start = Date.now();
            const maxWait = 15 * 60 * 1000;   // thinking models (Claude Extra) can run past 5 min
            const pollMs = 800;  // was 500 — halving the tick rate roughly halves poll overhead
            const interval = setInterval(() => {
              paintNudge();

              if (Date.now() - start > maxWait) {
                clearInterval(interval); window.__chorusPoll = null;
                try {
                  window.webkit?.messageHandlers?.chorusCompletion?.postMessage({
                    host: location.hostname,
                    diagnostic: 'timeout-no-completion'
                  });
                } catch (_) {}
                return;
              }
              const streaming = isStreaming();
              window.__chorusStreamingActive = streaming;   // keep the shims' activity flag fresh
              if (streaming) {
                idleTicks = 0;
                if (!wasStreaming) {
                  try {
                    window.webkit?.messageHandlers?.chorusCompletion?.postMessage({
                      host: location.hostname,
                      diagnostic: 'streaming-started'
                    });
                  } catch (_) {}
                }
                wasStreaming = true;
              } else if (wasStreaming) {
                // Require the stop button to be gone for 2 consecutive ticks before declaring
                // done — ChatGPT briefly flickers its stop button, which used to cause a false
                // "completed" within ~0.5s of starting.
                idleTicks++;
                if (idleTicks >= 2) {
                  clearInterval(interval); window.__chorusPoll = null;
                  // Response finished — repaint/land per host (Gemini force-repaint burst, others
                  // scroll to the start of the finished answer).
                  finishPaint();
                  try {
                    window.webkit?.messageHandlers?.chorusCompletion?.postMessage({
                      host: location.hostname
                    });
                  } catch (_) {}
                }
              } else {
                // Stop button never matched STOP_SELECTORS (Kimi / Grok / 豆包 / 千问 / customs) —
                // infer completion from the answer text going quiet. Only reachable while
                // wasStreaming is false, so the reliable stop-button path above is untouched.
                const len = activityLen();
                if (len >= 0) {
                  if (lastLen < 0) {
                    lastLen = len;
                  } else if (len > lastLen) {
                    if (!grewOnce) {
                      grewOnce = true;
                      // One-shot: dump the visible buttons while it IS generating, so a precise
                      // stop selector can be added for this site later.
                      try {
                        const btns = [...document.querySelectorAll('button')]
                          .filter(b => b.offsetParent !== null)
                          .map(b => (b.getAttribute('aria-label') || b.getAttribute('title') || b.className || '').toString().slice(0, 40))
                          .filter(Boolean).slice(-14);
                        clog('no stop button matched — generating; candidate buttons: ' + JSON.stringify(btns));
                      } catch (_) {}
                    }
                    lastLen = len; settleTicks = 0;
                  } else if (grewOnce) {
                    settleTicks++;
                    if (settleTicks >= SETTLE_TICKS) {
                      clearInterval(interval); window.__chorusPoll = null;
                      finishPaint();
                      clog('completion inferred by text-settle (' + Math.round(SETTLE_TICKS * pollMs / 1000) + 's quiet, len=' + len + ')');
                      try {
                        window.webkit?.messageHandlers?.chorusCompletion?.postMessage({
                          host: location.hostname
                        });
                      } catch (_) {}
                    }
                  }
                }
              }
            }, pollMs);
            window.__chorusPoll = interval;
          })();

          return clicked
            ? (imageAttached ? 'sent (with image)' : 'sent')
            : 'send button not found';
        })();
        """
    }

    /// A persistent, event-driven streaming watcher injected on every page load. Unlike the
    /// broadcast poll (which only runs after WE send), this catches messages the user types
    /// directly into a panel too. It's deliberately light:
    ///   • a MutationObserver (zero cost when the page is idle) instead of a timer
    ///   • throttled to coalesce bursts during streaming
    ///   • a 700ms confirm before declaring "done" (avoids ChatGPT's stop-button flicker)
    ///   • yields while a broadcast poll owns the page (window.__chorusPoll)
    ///   • ChatGPT/Claude/custom: light DOM query + observer (event-driven, ~free at idle)
    ///   • Gemini: its stop button hides in shadow DOM the observer can't see into, so it gets
    ///     a shadow-aware query + a gentle 1.5s fallback poll (one panel, short-circuited)
    /// It posts the same messages as the broadcast poll, so it feeds the menu-bar icon / card
    /// pulse; manual sends never notify because they aren't part of a broadcast batch.
    static func streamingWatcherScript() -> String {
        return """
        \(libScript())
        (() => {
          if (window.__chorusWatcher) return;
          window.__chorusWatcher = true;

          // Streaming detection + scroll/repaint helpers come from the shared lib. (A previous
          // copy-paste drift here referenced a helper only the broadcast poll defined — the
          // resulting ReferenceError silently swallowed Gemini completion signals.)
          const L = window.__chorusLib;
          const isGemini = L.isGemini;
          const streaming = () => L.isStreaming();
          let paintUntil = 0;

          // ChatGPT frequently shows "Something went wrong while generating the response" in
          // WKWebView under a proxy (WebKit's QUIC/h2 handling is weaker than Chromium's, and
          // Apple exposes no app-level QUIC switch). We can't prevent it, but we can auto-click
          // its Retry button so it self-heals. Rate-limited to avoid loops / wasted quota.
          const isChatGPT = location.hostname.includes('chatgpt') || location.hostname.includes('openai');
          const ERR_RE = /something went wrong|生成回答时出错|出错了|网络错误|an error occurred/i;
          const RETRY_RE = /retry|regenerate|重试|重新生成|try again/i;
          let retries = 0, retryWindow = 0;
          const maybeAutoRetry = () => {
            if (!isChatGPT) return;
            const txt = (document.body && document.body.innerText) || '';
            if (!ERR_RE.test(txt)) return;
            const now = Date.now();
            if (now - retryWindow > 90000) { retryWindow = now; retries = 0; }  // reset window
            if (retries >= 2) return;                                            // cap: 2 / 90s
            for (const b of document.querySelectorAll('button')) {
              const label = ((b.textContent || '') + ' ' + (b.getAttribute('aria-label') || '')).trim();
              if (RETRY_RE.test(label)) {
                retries++;
                try { b.click(); } catch (_) {}
                try { window.webkit?.messageHandlers?.chorusJSLog?.postMessage(location.hostname + ': auto-retried error (' + retries + '/2)'); } catch (_) {}
                return;
              }
            }
          };

          let was = false, scheduled = false, confirm = null;
          const post = (body) => {
            try { window.webkit?.messageHandlers?.chorusCompletion?.postMessage(body); } catch (_) {}
          };
          const check = () => {
            scheduled = false;
            // While a broadcast is actively tracking this page, let it own the signal.
            if (window.__chorusPoll) { was = false; if (confirm) { clearTimeout(confirm); confirm = null; } return; }
            const now = streaming();
            // Live activity flag for the keep-alive shims: full-rate timer backups only while a
            // response is actually generating; hidden idle pages drop to a slow tick (energy).
            window.__chorusStreamingActive = now;
            if (now) {
              if (isGemini) paintUntil = Date.now() + 6000;  // keep repainting through the stream
              else L.followBottom();                          // other panels: just follow the stream
              if (confirm) { clearTimeout(confirm); confirm = null; }
              if (!was) { was = true; post({ host: location.hostname, diagnostic: 'streaming-started' }); }
            } else {
              if (was && !confirm) {
                // Stop button gone — wait 700ms and re-check before declaring done (flicker guard).
                confirm = setTimeout(() => {
                  confirm = null;
                  if (!window.__chorusPoll && !streaming()) {
                    was = false;
                    L.finishPaint();   // Gemini force-repaint burst / others land at the answer start
                    post({ host: location.hostname });
                  }
                }, 700);
              }
              maybeAutoRetry();  // errors appear after streaming stops — only scan when idle
            }
            // Repaint Gemini during the stream and for ~6s after (catches the stalled tail render).
            if (isGemini && Date.now() < paintUntil) L.geminiRepaint();
          };
          const schedule = () => { if (!scheduled) { scheduled = true; setTimeout(check, 350); } };

          try {
            new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
          } catch (_) {}

          // Gemini's shadow-hosted stop button is invisible to the observer — gentle fallback poll.
          if (isGemini) setInterval(schedule, 1500);
        })();
        """
    }

    /// Drives Gemini's "Upload & tools" → "Upload files" menu so it triggers its lazy
    /// <input type=file>. WebKit then calls our runOpenPanel delegate, which feeds the
    /// image silently. This script does NOT touch the file input itself — it just navigates
    /// the menu. It also dumps the menu contents (so we can see the real item labels) and
    /// logs each element's rect (so we can fall back to real CGEvent coordinate clicks if
    /// synthetic clicks don't carry enough user-activation to open the picker).
    static func geminiUploadTriggerScript() -> String {
        return """
        \(libScript())
        (async () => {
          const clog = (msg) => {
            try { window.webkit?.messageHandlers?.chorusJSLog?.postMessage(location.hostname + ': ' + msg); } catch (_) {}
          };
          const deepQueryAll = window.__chorusLib.deepQueryAll;
          const fullClick = (el) => {
            const r = el.getBoundingClientRect();
            const o = { bubbles: true, cancelable: true, clientX: r.left + r.width/2, clientY: r.top + r.height/2, button: 0, view: window };
            try { el.dispatchEvent(new PointerEvent('pointerdown', o)); } catch (_) {}
            el.dispatchEvent(new MouseEvent('mousedown', o));
            try { el.dispatchEvent(new PointerEvent('pointerup', o)); } catch (_) {}
            el.dispatchEvent(new MouseEvent('mouseup', o));
            try { el.click(); } catch (_) {}
          };
          const rectOf = (el) => { const r = el.getBoundingClientRect(); return Math.round(r.x)+','+Math.round(r.y)+' '+Math.round(r.width)+'x'+Math.round(r.height); };

          const sleep = (ms) => new Promise(r => setTimeout(r, ms));

          const findButton = () => {
            const b = deepQueryAll([
              'button[aria-label="Upload & tools"]',
              'button[aria-label*="Upload" i]',
              'button[aria-label*="Add files" i]',
              'button[aria-label*="上传" i]',
            ]);
            return b.length ? b[0] : null;
          };
          const findMenuItems = () => deepQueryAll([
            '[role="menuitem"]', 'button[mat-menu-item]', '[mat-menu-item]',
            '.mat-mdc-menu-panel button', '[role="menu"] button', '.cdk-overlay-pane button',
            '.cdk-overlay-pane [role="menuitem"]',
          ]);
          // Files = upload-from-computer. EXCLUDE cloud/other sources — Gemini's menu is a
          // grid (Files | Avatar | Drive | Photos | Notebooks); matching 'photo' once grabbed
          // "Google Photos" (an in-page picker) instead of the local-file upload.
          const isUploadItem = (raw) => {
            const t = raw.toLowerCase();
            if (t.includes('drive') || t.includes('photos') || t.includes('notebook') ||
                t.includes('avatar') || t.includes('personal intelligence')) return false;
            return /\\bfiles?\\b/.test(t) || t.includes('upload') ||
                   t.includes('from computer') || t.includes('上传') ||
                   t.includes('本地') || t.includes('文件');
          };
          const findUploadTile = () => {
            for (const it of findMenuItems()) {
              const t = ((it.textContent || '') + ' ' + (it.getAttribute('aria-label') || '')).trim();
              if (t && isUploadItem(t)) return it;
            }
            return null;
          };

          // 1. Poll for the "Upload & tools" button — the composer may still be rendering
          //    (cold start / slow machine), so don't assume it's there immediately.
          let btn = null;
          for (let i = 0; i < 20 && !btn; i++) { btn = findButton(); if (!btn) await sleep(150); }
          if (!btn) { clog('geminiUpload: NO upload button after ~3s'); return 'no-btn'; }

          // 2. Up to 2 attempts: click the button, then POLL (not a fixed sleep) for the
          //    upload tile to appear, then click it. Polling absorbs menu-open latency;
          //    the retry absorbs a missed first click / menu that opened then closed.
          for (let attempt = 1; attempt <= 2; attempt++) {
            clog('geminiUpload: attempt ' + attempt + ' — clicking upload btn (rect=' + rectOf(btn) + ')');
            fullClick(btn);

            let tile = null;
            for (let i = 0; i < 27 && !tile; i++) { tile = findUploadTile(); if (!tile) await sleep(150); }

            if (tile) {
              clog('geminiUpload: clicking "' + (tile.textContent || '').trim().slice(0, 40) + '" (rect=' + rectOf(tile) + ')');
              fullClick(tile);
              return 'clicked-item';
            }

            // Miss — dump what's actually in the menu so a future UI change is debuggable.
            const items = findMenuItems();
            clog('geminiUpload: attempt ' + attempt + ' found no upload tile among ' + items.length + ' items');
            items.slice(0, 12).forEach((it, i) => {
              const t = ((it.textContent || '') + ' | ' + (it.getAttribute('aria-label') || '')).trim();
              clog('  item[' + i + ']: "' + t.slice(0, 50) + '"');
            });
            await sleep(400);  // let any half-open menu settle before retrying
          }
          clog('geminiUpload: NO matching upload tile after 2 attempts');
          return 'no-item';
        })();
        """
    }

    // MARK: - Warm web-page tint (optional, cosmetic)

    /// The cream we multiply over each page. Multiply blend means: white → this cream,
    /// dark text/UI stays dark, mid colors warm slightly. Chosen to sit between the app's
    /// canvas-gradient endpoints so framed pages read as part of the same warm surface.
    private static let warmTintColor = "#f1e9d9"

    /// Overlay a translucent cream layer on the page so the official sites lean toward the
    /// app's warm tone. Implemented as a single fixed, `pointer-events:none` div with
    /// `mix-blend-mode:multiply` — purely cosmetic (no network, no automation, zero ban
    /// risk; the same thing DarkReader-style extensions do), and it touches no site
    /// selectors so a redesign can't break it. A shallow observer on <body>'s direct
    /// children re-adds the layer if an SPA route swap removes it (cheap: body's direct
    /// children rarely churn, unlike the deep DOM during streaming).
    static var warmTintAddJS: String {
        return """
        (function(){
          var ID='chorus-warm-tint';
          function add(){
            if(document.getElementById(ID)) return;
            var d=document.createElement('div');
            d.id=ID;
            d.style.cssText='position:fixed;top:0;left:0;right:0;bottom:0;background:\(warmTintColor);'
              +'mix-blend-mode:multiply;pointer-events:none;z-index:2147483647';
            (document.body||document.documentElement).appendChild(d);
          }
          add();
          if(!window.__chorusTintObs && document.body){
            window.__chorusTintObs=new MutationObserver(function(){
              if(!document.getElementById(ID)) add();
            });
            window.__chorusTintObs.observe(document.body,{childList:true});
          }
        })();
        """
    }

    /// Remove the cream layer + stop its observer — used for the live toggle.
    static var warmTintRemoveJS: String {
        return """
        (function(){
          var e=document.getElementById('chorus-warm-tint'); if(e) e.remove();
          if(window.__chorusTintObs){ window.__chorusTintObs.disconnect(); window.__chorusTintObs=null; }
        })();
        """
    }

    // MARK: - Live "is this AI still busy?" check

    /// Returns a boolean: is a stop button visible on the page RIGHT NOW? The stop button is
    /// present for the whole generation — INCLUDING a thinking/reasoning phase (Claude's
    /// extended "Thinking" keeps it up) — so this is the ground-truth "still working" signal.
    /// Used by the batch-completion safety net to avoid declaring "all done" while an AI is
    /// still thinking (its reasoning can outlast the 75s grace, and the batch only looks
    /// "quiet" because nothing has *completed*). A live query (not the cached streamingKeys),
    /// so a genuinely-undetected completion still lets the net fire.
    ///
    /// Selectors mirror the generic catch-alls in the poll/watcher STOP_SELECTORS; keep roughly
    /// in sync if those change. Gemini hides its stop button in shadow DOM → deep walk.
    static func busyCheckScript() -> String {
        // force=true: this is the batch-fallback's "still busy?" double-check — it runs rarely
        // and its answer decides whether to notify, so accuracy beats the deep-walk cost.
        return """
        \(libScript())
        window.__chorusLib.isStreaming(true);
        """
    }

    /// Watchdog probe: busy state + answer-text length in one evaluate, as a JSON string.
    /// The length delta across ticks distinguishes "genuinely frozen mid-stream" from "text
    /// still growing" and from "finished but the stop button is stuck" while the app is hidden.
    static func watchdogProbeScript() -> String {
        return """
        \(libScript())
        JSON.stringify([window.__chorusLib.isStreaming(true), window.__chorusLib.activityLen()]);
        """
    }

    /// EXPERIMENT — extract the latest assistant answer's plain text from a web AI's DOM, so we
    /// can compare/summarize answers natively. Per-site selectors (best-effort, will need upkeep);
    /// returns "" if nothing matched so the caller can show "couldn't extract".
    static func extractAnswerScript() -> String {
        return """
        (() => {
          const host = location.hostname;
          // Drop consecutive duplicate lines (Claude's thinking block renders a collapsed preview
          // AND the full text, so innerText repeats lines).
          const dedupe = (s) => {
            const out = [];
            for (const ln of s.split('\\n')) {
              const k = ln.trim();
              if (out.length && k && out[out.length - 1].trim() === k) continue;
              out.push(ln);
            }
            return out.join('\\n').trim();
          };
          let sels = [];
          if (host.includes('chatgpt') || host.includes('openai')) {
            sels = ['[data-message-author-role="assistant"]'];
          } else if (host.includes('claude')) {
            // The data-is-streaming wrapper also holds an sr-only "Claude responded:" <h2> and the
            // extended-thinking status button, which the container-level innerText swallows. The
            // clean prose is the LAST .standard-markdown inside the answer body. (The body class
            // was renamed .font-claude-message -> .font-claude-response; keep both as fallback.)
            const cs = document.querySelectorAll('div[data-is-streaming]');
            const c = cs[cs.length - 1];
            if (c) {
              const resp = c.querySelector('.font-claude-response') || c.querySelector('.font-claude-message') || c;
              const mds = resp.querySelectorAll('.standard-markdown');
              if (mds.length) {
                const t = (mds[mds.length - 1].innerText || '').trim();
                if (t) return dedupe(t);
              }
              // No .standard-markdown → strip known noise nodes from a clone, then read.
              const clone = resp.cloneNode(true);
              clone.querySelectorAll('.sr-only, [class*="group/status"]').forEach(n => n.remove());
              const t = (clone.innerText || '').trim();
              if (t) return dedupe(t);
            }
            sels = ['.standard-markdown', 'div.font-claude-response', 'div.font-claude-message'];
          } else if (host.includes('gemini') || host.includes('google')) {
            sels = ['message-content', '.model-response-text', 'model-response', '.markdown'];
          } else if (host.includes('kimi') || host.includes('moonshot')) {
            // Kimi renders reasoning + tool calls inline (.thinking-container / .toolcall-container)
            // inside the same assistant segment as the answer. Strip them from a clone, then join
            // the remaining .markdown blocks (an answer can span several).
            const segs = document.querySelectorAll('.segment.segment-assistant, .segment-assistant');
            const seg = segs[segs.length - 1];
            if (seg) {
              const clone = seg.cloneNode(true);
              clone.querySelectorAll('.thinking-container, .toolcall-container, [class*="thinking-container"], [class*="toolcall"]').forEach(n => n.remove());
              const mds = clone.querySelectorAll('.markdown');
              const t = (mds.length ? [...mds].map(m => (m.innerText || '').trim()).filter(Boolean).join('\\n\\n') : (clone.innerText || '')).trim();
              if (t) return dedupe(t);
            }
            sels = ['.segment-assistant .markdown', '.markdown'];
          } else if (host.includes('manus')) {
            // Best-effort until a real task can be inspected (Manus runs cost credits, so no
            // sample was generated): take the last prose block in the transcript.
            sels = ['.prose', '[class*="markdown" i]', '[class*="prose" i]'];
          } else {
            // Best-effort for other web AIs (Grok / 豆包 / DeepSeek web / 千问 / customs): the last
            // markdown-ish block. Not verified per-site — may miss or over-capture; precise
            // selectors get added when a specific site is reported wrong.
            sels = ['.ds-markdown', '.markdown', '[class*="markdown"]'];
          }
          for (const s of sels) {
            try {
              const ns = document.querySelectorAll(s);
              const last = ns[ns.length - 1];
              const t = last && (last.innerText || '').trim();
              if (t) return dedupe(t);
            } catch (_) {}
          }
          return '';
        })();
        """
    }
}
