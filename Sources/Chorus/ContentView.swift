import SwiftUI
import WebKit
import AppKit
import CoreGraphics
import ApplicationServices
import UniformTypeIdentifiers

@MainActor
final class WebViewStore: ObservableObject {
    /// Shared singleton so both ContentView and QuickInputWindow can broadcast
    /// to the same set of WKWebViews.
    static let shared = WebViewStore()

    private var cache: [String: WKWebView] = [:]
    /// KVO tokens for each webview's `.url`, so SPA conversation switches get recorded for restore.
    private var urlObservers: [String: NSKeyValueObservation] = [:]
    /// KVO tokens for each webview's `.isLoading`, driving the per-panel reload spinner.
    private var loadingObservers: [String: NSKeyValueObservation] = [:]

    /// Provider keys currently streaming a response — drives the per-panel "thinking" dot.
    @Published private(set) var streamingKeys: Set<String> = []
    /// Provider keys whose webview is loading a page — drives the reload spinner (so a tap on
    /// reload visibly does something and the user doesn't click it repeatedly).
    @Published private(set) var loadingKeys: Set<String> = []
    /// Panels whose page failed to load, with a short reason. A failed load leaves the webview
    /// BLANK WHITE with no explanation — the panel has to say so and offer a retry.
    @Published private(set) var loadErrors: [String: String] = [:]
    /// The most recent broadcast prompt — included as "the question" when summarizing answers.
    @Published private(set) var lastBroadcast: String = ""
    /// Provider keys/ids that have FINISHED answering since the last broadcast — so "summarize"
    /// only compares fresh answers to the same question (a panel still on a stale answer is
    /// excluded, preventing the "mixed questions" mess).
    @Published private(set) var answeredLastBroadcast: Set<String> = []
    /// Unique id per broadcast — groups the panels racing the same prompt for vote stats.
    @Published private(set) var currentBroadcastId: String = ""

    /// Favicons per provider key, fetched from each panel's real site — gives every panel
    /// (built-in AND custom) a real logo with zero bundled assets.
    @Published private(set) var favicons: [String: NSImage] = [:]

    /// Grab the page's favicon for the panel and cache it. Reads the best <link rel=icon>
    /// (or falls back to /favicon.ico), downloads it, and publishes for the header avatar.
    func fetchFavicon(for webView: WKWebView) {
        guard let key = cache.first(where: { $0.value === webView })?.key else { return }
        let js = """
        (() => {
          const links = [...document.querySelectorAll('link[rel~="icon"],link[rel="apple-touch-icon"],link[rel="shortcut icon"]')];
          const best = links.map(l => ({ href: l.href, size: parseInt((l.getAttribute('sizes')||'0').split('x')[0]) || 0 }))
                            .sort((a,b) => b.size - a.size)[0];
          return (best && best.href) ? best.href : (location.origin + '/favicon.ico');
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let urlStr = result as? String, let url = URL(string: urlStr) else { return }
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let img = NSImage(data: data), img.size.width > 0 else { return }
                await MainActor.run { self?.favicons[key] = img }
            }
        }
    }

    /// Pending completion batches — one per broadcast. Each tracks which provider keys
    /// have not yet posted their completion message. When a batch's set empties → notify.
    private var pendingBatches: [UUID: PendingBatch] = [:]

    /// Last time we auto-recovered a panel from a dead conversation — guards against an
    /// infinite reload loop if the fresh page ever also matches the trigger text.
    private var recoveredAt: [String: Date] = [:]

    private struct PendingBatch {
        var pendingKeys: Set<String>
        let source: BroadcastSource
        let totalCount: Int
        var lastActivityAt: Date
    }

    init() {
        // Wire JS → Swift completion bridge to this store.
        CompletionScriptHandler.shared.onCompletion = { [weak self] host in
            self?.handleHostCompletion(host: host)
        }
        // Track streaming state per host for the status dots.
        CompletionScriptHandler.shared.onStreamingState = { [weak self] host, streaming in
            guard let self, let key = self.providerKey(forHost: host) else { return }
            if streaming {
                self.streamingKeys.insert(key)
            } else {
                self.streamingKeys.remove(key)
            }
        }
    }

    /// Returns an existing WKWebView for `key`, or creates one and caches it.
    /// Calling this multiple times for the same key always returns the same instance.
    /// On first creation, if "restore session" is on, opens the last conversation URL
    /// instead of the provider's base URL.
    func getOrCreate(key: String, url: URL) -> WKWebView {
        if let existing = cache[key] {
            return existing
        }
        let restore = UserDefaults.standard.object(forKey: "restoreSession") as? Bool ?? true
        let initialURL = restore ? (savedSessionURL(for: key) ?? url) : url
        let webView = WebViewFactory.make(url: initialURL)
        cache[key] = webView
        MemoryHeartbeat.shared.note("webview created \(key)")
        // Record the conversation URL whenever it changes. `didFinish` only fires on full
        // navigations, so in-app conversation switches done as SPA history.pushState (Gemini,
        // Claude, ChatGPT) were never captured — the saved session stayed on the initial page
        // and "reopen last chat" landed on a new chat. KVO on `.url` sees pushState too.
        urlObservers[key] = webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            self?.recordSessionURL(for: wv)
        }
        // Drive the reload spinner. `.isLoading` KVO fires on the main thread, so mutating the
        // @Published set here is safe.
        loadingObservers[key] = webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] wv, _ in
            guard let self else { return }
            if wv.isLoading { self.loadingKeys.insert(key) } else { self.loadingKeys.remove(key) }
        }
        return webView
    }

    // MARK: Session restore — remember & reopen each panel's last conversation

    private func sessionURLMap() -> [String: String] {
        guard let s = UserDefaults.standard.string(forKey: "sessionURLs"),
              let data = s.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }
    private func saveSessionMap(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map),
              let s = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(s, forKey: "sessionURLs")
    }
    private func savedSessionURL(for key: String) -> URL? {
        guard let s = sessionURLMap()[key], let url = URL(string: s) else { return nil }
        return url
    }

    /// Persist a panel's current conversation URL. Skips auth/login/blank pages so we never
    /// "restore" to a sign-in screen.
    func recordSessionURL(for webView: WKWebView) {
        guard let key = cache.first(where: { $0.value === webView })?.key,
              let url = webView.url else { return }
        if url.scheme == "about" { return }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        if host.hasPrefix("accounts.") || host.hasPrefix("auth.") || host.hasPrefix("login.")
            || path.contains("login") || path.contains("signin") || path.contains("sign-in") || path.contains("/auth") {
            return
        }
        var map = sessionURLMap()
        map[key] = url.absoluteString
        saveSessionMap(map)
    }

    /// Save every live panel's current URL — call on quit as a backstop.
    func saveAllSessionURLs() {
        for (_, webView) in cache { recordSessionURL(for: webView) }
    }

    /// Reloads the WKWebView for a given provider key (preserves cookies / login).
    func reload(key: String) {
        cache[key]?.reload()
    }

    /// EXPERIMENT — extract a web panel's latest answer text (DOM scrape). Empty string if the
    /// panel has no webview or nothing matched.
    func extractAnswer(key: String, completion: @escaping (String) -> Void) {
        guard let wv = cache[key] else { completion(""); return }
        wv.evaluateJavaScript(Broadcaster.extractAnswerScript()) { result, _ in
            completion((result as? String) ?? "")
        }
    }

    /// Live-checks whether ANY of `keys` still shows a stop button — i.e. is still generating
    /// or thinking right now. Async; `completion` runs on the main actor. Ground truth (queries
    /// the live DOM), used by the completion safety net so it won't declare "done" mid-thought.
    func anyBusy(_ keys: Set<String>, completion: @escaping (Bool) -> Void) {
        // A still-streaming API panel counts as busy (no webview to query for it).
        if !keys.isDisjoint(with: apiStreamingIds) { completion(true); return }
        let webviews = keys.compactMap { cache[$0] }
        guard !webviews.isEmpty else { completion(false); return }
        let group = DispatchGroup()
        var busy = false
        for wv in webviews {
            group.enter()
            wv.evaluateJavaScript(Broadcaster.busyCheckScript()) { result, _ in
                if (result as? Bool) == true { busy = true }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(busy) }
    }

    /// Add/remove the cosmetic cream tint on every live panel — lets the Settings toggle
    /// apply instantly without a reload. New page loads pick it up via the injected
    /// user script (see WebViewFactory.make), which is added/skipped per the same setting;
    /// existing webviews keep their old user-script set until reload, so we drive those
    /// directly here.
    func setWarmTint(_ on: Bool) {
        let js = on ? Broadcaster.warmTintAddJS : Broadcaster.warmTintRemoveJS
        for (_, webView) in cache {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// A "fresh start" URL for a provider — its new-chat page for built-ins, else its base URL.
    private func freshURL(forKey key: String) -> URL? {
        let builtinNew: [String: String] = [
            "chatgpt": "https://chatgpt.com/",
            "claude":  "https://claude.ai/new",
            "gemini":  "https://gemini.google.com/app",
        ]
        if let s = builtinNew[key], let u = URL(string: s) { return u }
        return ProviderRegistry.all().first(where: { $0.key == key })?.url
    }

    /// Navigate a panel to its "new conversation" page (login/cookies preserved).
    func newChat(key: String) {
        guard let webView = cache[key], let url = freshURL(forKey: key) else { return }
        newChatStartedAt[key] = Date()
        clog("[NewChat] \(key) — loading \(url.absoluteString)")
        webView.load(URLRequest(url: url))
    }

    /// TEMP DIAG: when each new-chat navigation actually finished, to find out whether the
    /// "sometimes instant, sometimes ages" the user sees is the full page load or something else.
    var newChatStartedAt: [String: Date] = [:]
    func noteNavigationFinished(_ webView: WKWebView) {
        guard let key = cache.first(where: { $0.value === webView })?.key,
              let started = newChatStartedAt.removeValue(forKey: key) else { return }
        clog("[NewChat] \(key) — finished in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    }

    /// After a restored session loads, some deep links point at a conversation that no longer
    /// exists — these sites return HTTP 200 and render a "Conversation not found" message via
    /// JS (so navigation callbacks don't fire). Detect that text and recover to a fresh chat,
    /// clearing the dead saved URL so it doesn't recur next launch.
    func recoverIfDeadConversation(_ webView: WKWebView) {
        guard let key = cache.first(where: { $0.value === webView })?.key else { return }
        // Don't recover again within 15s — prevents an infinite reload loop if the fresh page
        // itself ever contains the trigger text.
        if let last = recoveredAt[key], Date().timeIntervalSince(last) < 15 { return }
        let js = """
        (() => {
          const t = ((document.body && document.body.innerText) || '').slice(0, 4000).toLowerCase();
          return (t.includes('conversation not found') || t.includes('chat not found')
                  || t.includes('对话未找到') || t.includes('未找到对话')) ? 'dead' : 'ok';
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, (result as? String) == "dead" else { return }
            self.recoveredAt[key] = Date()
            var map = self.sessionURLMap()
            map.removeValue(forKey: key)
            self.saveSessionMap(map)
            chorusLog.notice("[Chorus.Restore] \(key, privacy: .public) hit a dead conversation — recovering to a fresh chat")
            self.newChat(key: key)
        }
    }

    /// Broadcast a prompt to all webviews. `source` is used by the completion notifier
    /// to decide whether to alert (e.g. only for quick-input broadcasts in default config).
    /// `targets` (panel keys) narrows the send to specific panels — used by @-directed asks.
    /// A directed ask is a SIDE question: it does not reset the round, so the other panels'
    /// answers keep counting for summarize/vote exactly as they stood.
    func broadcast(text: String, images: [NSImage] = [], source: BroadcastSource = .mainWindow,
                   targets: Set<String>? = nil) {
        MemoryHeartbeat.shared.note("broadcast chars=\(text.count) images=\(images.count) source=\(source) targets=\(targets.map { String($0.count) } ?? "all")")
        if targets == nil {
            lastBroadcast = text          // remembered so "summarize" can include the question
            answeredLastBroadcast = []    // new question → prior answers no longer count
            currentBroadcastId = UUID().uuidString
            VoteStore.shared.newRound()   // commit the previous round's pick, reset the star state
        }
        var imagesBase64: [String] = []
        var pngDatas: [Data] = []
        for image in images {
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            pngDatas.append(png)
            imagesBase64.append(png.base64EncodedString())
        }

        // Build the "wait for" set for the completion notification:
        // (visible) ∩ (user-marked-required). Hidden providers and "best effort"
        // providers (e.g. Gemini if user unchecked it) still receive the broadcast
        // but their completion doesn't block the notification.
        let hiddenRaw = UserDefaults.standard.string(forKey: "hiddenProviders") ?? ""
        let hiddenKeys = Set(hiddenRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
        let visibleKeys = Set(cache.keys).subtracting(hiddenKeys)
        let visibleAPIKeys = Set(APIProviderRegistry.all().map(\.id)).subtracting(hiddenKeys)

        // Default: wait for whatever the user currently has ON SCREEN — the panels you chose to
        // show ARE the answer set you're waiting for, and it stays right when panels are added or
        // hidden. The old behaviour (a separate hand-kept checklist) silently drifted: hiding a
        // listed panel dropped it, and newly shown panels were never waited for, so the "all
        // done" alert could fire while a visible AI was still writing.
        let everyVisible = UserDefaults.standard.object(forKey: "notifyWaitAllVisible") as? Bool ?? true
        let onScreen = visibleKeys.union(visibleAPIKeys)
        let trackKeys: Set<String>
        if let targets {
            trackKeys = targets.intersection(onScreen)
        } else if everyVisible {
            trackKeys = onScreen
        } else {
            let requiredRaw = UserDefaults.standard.string(forKey: "notifyRequiredProviders") ?? "chatgpt,claude,gemini"
            let requiredKeys = Set(requiredRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
            trackKeys = onScreen.intersection(requiredKeys)
        }

        if !trackKeys.isEmpty {
            let batchID = UUID()
            pendingBatches[batchID] = PendingBatch(
                pendingKeys: trackKeys,
                source: source,
                totalCount: trackKeys.count,
                lastActivityAt: Date()
            )
            SleepGuard.shared.sync(pendingBatches: pendingBatches.count)
            clog("batch \(batchID.uuidString.prefix(8)) created — source=\(source), waiting on \(trackKeys) (onScreen=\(onScreen), mode=\(everyVisible ? "all-visible" : "manual-list"))")
            scheduleBatchFallback(batchID: batchID)
            startCompletionWatchdogIfNeeded()   // native busy→idle detection survives minimize
            // Keep the batch alive through long thinking runs (Claude Extra exceeded the old 300s,
            // so its completion arrived after the batch was already nuked — no notification/star).
            // Mirrors the JS poll's 15-minute maxWait.
            DispatchQueue.main.asyncAfter(deadline: .now() + 900) { [weak self] in
                self?.pendingBatches.removeValue(forKey: batchID)
                SleepGuard.shared.sync(pendingBatches: self?.pendingBatches.count ?? 0)
            }
        } else {
            clog("broadcast skipped completion tracking — no providers to wait for (onScreen=\(onScreen), mode=\(everyVisible ? "all-visible" : "manual-list"))")
        }

        let jsWithImages = Broadcaster.injectionScript(text: text, imagesBase64: imagesBase64)
        // Gemini send script: attaches no image itself, but waits for the panel-uploaded
        // image(s) to finish appearing before typing + sending.
        let jsGeminiSend = Broadcaster.injectionScript(text: text, imagesBase64: [], waitForGeminiUpload: !pngDatas.isEmpty)
        for (key, webView) in cache {
            // Don't broadcast to hidden panels — hiding a panel excludes it from sends.
            if hiddenKeys.contains(key) { continue }
            if let targets, !targets.contains(key) { continue }

            // Gemini blocks synthetic JS image attachment: it renders no static <input type=file>
            // and ignores synthetic paste/drop (isTrusted=false). Instead we intercept its
            // file-open panel: arm runOpenPanel with the temp image file(s), then drive Gemini's
            // "Upload files" menu so WebKit calls the panel — which we answer silently with all N.
            if key == "gemini", !pngDatas.isEmpty {
                geminiUploadViaPanel(into: webView, pngDatas: pngDatas, thenRun: jsGeminiSend)
                continue
            }
            webView.evaluateJavaScript(jsWithImages) { result, error in
                if let error = error {
                    print("[\(key)] error: \(error.localizedDescription)")
                }
            }
        }

        // Fan out to the native API model panels too (with the image, for vision models). Hidden
        // ones are skipped, mirroring the web panels.
        let apiPrompt = text
        let apiImages = imagesBase64
        let skip = hiddenKeys
        let only = targets
        Task { @MainActor in
            for p in APIProviderRegistry.all() where !skip.contains(p.id) {
                if let only, !only.contains(p.id) { continue }
                APIChatStore.shared.send(to: p, prompt: apiPrompt, imagesBase64: apiImages)
            }
        }
    }

    /// Feed an image into Gemini via file-open-panel interception (the native equivalent of
    /// Playwright's fileChooser handling). Steps: write the image to a temp file, arm the
    /// runOpenPanel auto-answer, then drive Gemini's "Upload files" menu. When Gemini fires
    /// its lazy <input type=file>, WebKit calls our delegate, which returns the file silently
    /// (no dialog). Finally set the text and send.
    private func geminiUploadViaPanel(into webView: WKWebView, pngDatas: [Data], thenRun js: String) {
        var tmps: [URL] = []
        for png in pngDatas {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("chorus-upload-\(UUID().uuidString).png")
            do { try png.write(to: tmp); tmps.append(tmp) }
            catch { chorusLog.notice("[Chorus.Gemini] temp file write failed: \(error.localizedDescription, privacy: .public)") }
        }
        guard !tmps.isEmpty else {
            webView.evaluateJavaScript(js) { _, _ in }  // still send the text
            return
        }

        // Arm the open-panel auto-answer (single-shot, consumed by runOpenPanel — returns ALL N).
        LinkRoutingDelegate.shared.armGeminiUploads(tmps)
        chorusLog.notice("[Chorus.Gemini] armed pendingUploads=\(tmps.count)")

        // Honour "don't switch to Chorus after a quick-input send": the upload path no longer
        // needs the app in front (verified with the panels in the hidden keeper window and with
        // the main window key). Activation stays as a last-resort retry below.
        let staysInBackground = !NSApp.isActive
            && !(UserDefaults.standard.object(forKey: "foregroundMainOnSend") as? Bool ?? true)
        if !staysInBackground { NSApp.activate(ignoringOtherApps: true) }
        chorusLog.notice("[Chorus.Gemini] upload starting \(staysInBackground ? "in the background" : "with Chorus active", privacy: .public)")

        // Delay so ChatGPT/Claude finish their synthetic paste before we churn Gemini's UI.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            // The send script polls for the uploaded thumbnail itself (WAIT_UPLOAD, up to 20 s),
            // so it can start as soon as the menu drive is under way.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                webView.evaluateJavaScript(js) { _, _ in }
            }
            self.driveGeminiUpload(in: webView, armed: tmps) { fired in
                guard !fired, staysInBackground else {
                    LinkRoutingDelegate.shared.finishGeminiUploads()
                    return
                }
                chorusLog.notice("[Chorus.Gemini] picker did not fire in the background — activating and retrying")
                NSApp.activate(ignoringOtherApps: true)
                self.driveGeminiUpload(in: webView, armed: tmps) { _ in LinkRoutingDelegate.shared.finishGeminiUploads() }
            }
        }

        // Safety: never leave an armed upload behind to hijack the user's next manual file pick.
        // Longer than the whole drive (hidden selector ≤3 s, native fallback ≤~9 s, one retry).
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if LinkRoutingDelegate.shared.pendingUploads == tmps {
                LinkRoutingDelegate.shared.pendingUploads = []
                chorusLog.notice("[Chorus.Gemini] cleared stale pendingUploads (panel never fired)")
            }
        }

        // Delete the temp PNGs once Gemini has read them (done well within a minute) — otherwise
        // they pile up in the temp dir, N per broadcast, forever.
        let toClean = tmps
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            for url in toClean { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Get Gemini's file picker open so runOpenPanel can hand it the armed files.
    ///
    /// Gemini's "Files" tile doesn't open the file input itself: its handler clicks a hidden
    /// button (`hidden-local-file-image-selector-button`, present only while the upload menu is
    /// open) whose handler calls input.click() — and WebKit opens a file chooser only under a
    /// user gesture, which gets lost on the way. Observed with the main window on screen: a
    /// trusted native click on the tile reached the page (pointerdown…click, all isTrusted),
    /// Gemini clicked the hidden button, and no picker ever came; a synthetic tile click could
    /// open the picker, yet the image never reached the composer. It only worked while the panels
    /// sat in the hidden keeper window — which is why the first native-click fix passed its
    /// probes and still failed from the quick input, where the main window is brought forward.
    ///
    /// So: open the menu, then click the hidden button from its own synchronous
    /// evaluateJavaScript, which carries a user gesture. Verified with the main window key and
    /// the app active: picker in ~20–55 ms, image in the composer, menu closes by itself. If
    /// Gemini renames that button, fall back to a native click on the tile. No synthetic tile
    /// click any more — it consumed the file without attaching it. `done(true)` once the picker
    /// has taken the files.
    private func driveGeminiUpload(in webView: WKWebView, armed: [URL], done: @escaping (Bool) -> Void) {
        let consumed = { LinkRoutingDelegate.shared.lastAutoSupplied == armed }
        webView.callAsyncJavaScript(Broadcaster.geminiUploadMenuReadyBody(), arguments: [:], in: nil, in: .page) { result in
            MainActor.assumeIsolated {
                let info = (try? result.get()) as? [String: Any]
                guard (info?["ready"] as? Bool) == true else {
                    chorusLog.notice("[Chorus.Gemini] hidden file selector not available — \(String(describing: result), privacy: .public); falling back to a native click on the tile")
                    self.nativeTileClick(in: webView, consumed: consumed, done: done)
                    return
                }
                let start = Date()
                webView.evaluateJavaScript(Broadcaster.geminiHiddenSelectorClickScript()) { clicked, _ in
                    self.waitForConsumption(consumed, deadline: start.addingTimeInterval(3)) { ok in
                        if ok {
                            chorusLog.notice("[Chorus.Gemini] picker fired \(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) ms after clicking the hidden file selector")
                            done(true)
                        } else {
                            chorusLog.notice("[Chorus.Gemini] hidden file selector clicked=\((clicked as? Bool) ?? false, privacy: .public) but no picker — falling back to a native click on the tile")
                            self.nativeTileClick(in: webView, consumed: consumed, done: done)
                        }
                    }
                }
            }
        }
    }

    /// Fallback: locate the "Files" tile and give it a real mouse click. Works with the panels in
    /// the keeper window; with the main window on screen it may not (see driveGeminiUpload). On a
    /// miss, logs every pointer/mouse event the page saw so the next change is diagnosable.
    private func nativeTileClick(in webView: WKWebView, consumed: @escaping () -> Bool, done: @escaping (Bool) -> Void) {
        webView.callAsyncJavaScript(Broadcaster.geminiUploadLocateBody(), arguments: [:], in: nil, in: .page) { result in
            MainActor.assumeIsolated {
                guard case .success(let value) = result, let info = value as? [String: Any],
                      (info["found"] as? Bool) == true,
                      let x = info["x"] as? Double, let y = info["y"] as? Double else {
                    chorusLog.notice("[Chorus.Gemini] upload tile not located — \(String(describing: result), privacy: .public)")
                    done(false)
                    return
                }
                chorusLog.notice("[Chorus.Gemini] tile \"\((info["label"] as? String) ?? "?", privacy: .public)\" at \(Int(x)),\(Int(y)) hitOnTile=\((info["hitOnTile"] as? Bool) ?? false, privacy: .public) — native click")
                let clickedAt = Date()
                self.nativeClick(in: webView, cssX: x, cssY: y)
                self.waitForConsumption(consumed, deadline: clickedAt.addingTimeInterval(4.5)) { ok in
                    if ok {
                        chorusLog.notice("[Chorus.Gemini] picker fired \(Int(Date().timeIntervalSince(clickedAt) * 1000), privacy: .public) ms after the native tile click")
                        done(true)
                        return
                    }
                    webView.evaluateJavaScript("(() => { const l = JSON.stringify(window.__chorusEvtLog || null); window.__chorusEvtLog = null; return l; })()") { log, _ in
                        chorusLog.notice("[Chorus.Gemini] native tile click did not open the picker; events the page saw: \((log as? String) ?? "nil", privacy: .public)")
                        done(false)
                    }
                }
            }
        }
    }

    /// Poll `consumed` every 100 ms until it is true or `deadline` passes.
    private func waitForConsumption(_ consumed: @escaping () -> Bool, deadline: Date, done: @escaping (Bool) -> Void) {
        if consumed() { done(true); return }
        guard Date() < deadline else { done(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.waitForConsumption(consumed, deadline: deadline, done: done)
        }
    }

    /// Deliver a real left click to the page at a CSS-pixel point (viewport coordinates).
    private func nativeClick(in webView: WKWebView, cssX: Double, cssY: Double) {
        guard let window = webView.window else { return }
        let local = webView.isFlipped ? NSPoint(x: cssX, y: cssY)
                                      : NSPoint(x: cssX, y: Double(webView.bounds.height) - cssY)
        let inWindow = webView.convert(local, to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        webView.mouseDown(with: down)
        webView.mouseUp(with: up)
    }

    /// DEBUG: mark one panel as "answering" for a few seconds, then as answered — drives the
    /// header character's singing / ^ ^ states and the menu-bar glyph without sending anything.
    /// Distributed notification, `debugHooksEnabled` only (see AppDelegate).
    func debugFakeStreaming(key: String, seconds: Double = 6) {
        streamingKeys.insert(key)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.answeredLastBroadcast.insert(key)
            self.streamingKeys.remove(key)
        }
    }

    /// DEBUG: exercise the Gemini upload path WITHOUT sending anything — arms a tiny image,
    /// drives the menu, reports whether the picker took it. If it works the image ends up
    /// attached (unsent) in Gemini's composer. Triggered by a distributed notification, and only
    /// when the `debugHooksEnabled` default is on (see AppDelegate).
    func debugProbeGeminiUpload() {
        guard let webView = cache["gemini"] else { clog("[probe] no Gemini panel is open"); return }
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus(); NSColor.systemOrange.setFill(); NSRect(x: 0, y: 0, width: 16, height: 16).fill(); image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("chorus-probe-\(UUID().uuidString).png")
        guard (try? png.write(to: tmp)) != nil else { return }
        LinkRoutingDelegate.shared.armGeminiUploads([tmp])
        clog("[probe] Gemini upload probe starting (window visible=\(webView.window?.isVisible ?? false), key=\(webView.window?.isKeyWindow ?? false), app active=\(NSApp.isActive))")
        driveGeminiUpload(in: webView, armed: [tmp]) { fired in
            clog("[probe] Gemini upload probe finished — picker fired=\(fired)")
            LinkRoutingDelegate.shared.finishGeminiUploads()
            if LinkRoutingDelegate.shared.pendingUploads == [tmp] { LinkRoutingDelegate.shared.pendingUploads = [] }
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { try? FileManager.default.removeItem(at: tmp) }
            // Report what landed in the composer, then reload the panel — a reload drops unsent
            // attachments, which is the one cleanup that can't miss (Gemini's remove button is
            // hover-only). The conversation URL is restored as usual.
            guard fired else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.debugRemoveGeminiAttachments(in: webView, remaining: 1)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    clog("[probe] reloading the Gemini panel to drop the probe image")
                    webView.reload()
                }
            }
        }
    }

    /// DEBUG: report / clear whatever is attached in Gemini's composer (no upload, no send).
    func debugClearGeminiAttachments() {
        guard let webView = cache["gemini"] else { clog("[probe] no Gemini panel is open"); return }
        debugRemoveGeminiAttachments(in: webView, remaining: 5)
    }

    private func debugRemoveGeminiAttachments(in webView: WKWebView, remaining: Int) {
        guard remaining > 0 else { return }
        let body = """
        \(Broadcaster.libScript())
        const q = window.__chorusLib.deepQueryAll;
        const btn = q(['button[aria-label*="Remove" i]', 'button[aria-label*="移除" i]', 'button[aria-label*="删除" i]',
                       'button[aria-label*="Cancel" i]', 'button[data-test-id*="cancel" i]', 'button[data-test-id*="remove" i]'])[0];
        if (!btn) {
          // Say what IS there, so a selector miss is diagnosable from the log.
          const thumbs = q(['img[src^="blob:"]', 'img[src^="data:image"]']).length;
          const chips = q(['uploader-file-preview', '[class*="file-preview" i]', '[class*="attachment" i]', '[class*="upload" i] img']).length;
          const labels = q(['button[aria-label]']).map(b => b.getAttribute('aria-label')).filter(l => /remove|cancel|delete|close|clear|移除|删除|取消/i.test(l)).slice(0, 8);
          return { left: 0, thumbs, chips, labels };
        }
        const r = btn.getBoundingClientRect();
        if (r.width > 0 && r.height > 0) return { left: 1, x: r.left + r.width / 2, y: r.top + r.height / 2 };
        btn.click();
        return { left: 1, synthetic: true };
        """
        webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
            MainActor.assumeIsolated {
                guard case .success(let v) = result, let info = v as? [String: Any], (info["left"] as? Int) == 1 else {
                    clog("[probe] no (more) removable attachment — state: \(String(describing: result))")
                    return
                }
                if let x = info["x"] as? Double, let y = info["y"] as? Double { self.nativeClick(in: webView, cssX: x, cssY: y) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.debugRemoveGeminiAttachments(in: webView, remaining: remaining - 1) }
            }
        }
    }

    /// Called when a single host finishes streaming (via WKScriptMessageHandler bridge).
    /// Removes the host from every pending batch; when a batch's set becomes empty,
    /// triggers the completion notification.
    private func handleHostCompletion(host: String) {
        clog("host completion arrived from JS — host=\(host)")
        guard let key = providerKey(forHost: host) else {
            clog("no provider key matched host \(host)")
            return
        }
        streamingKeys.remove(key)  // clear the "thinking" dot
        notePanelCompletion(key: key)
    }

    /// Native API panels track their streaming state precisely here, so the batch fallback's
    /// "is anyone still busy?" check can see a long API reply (no webview to query).
    private var apiStreamingIds: Set<String> = []
    func setAPIStreaming(_ id: String, _ on: Bool) {
        if on { apiStreamingIds.insert(id) } else { apiStreamingIds.remove(id) }
    }

    /// Called when a native API panel's reply finishes — feeds the SAME batch tracking as web
    /// hosts, so the "all done" notification waits for API models too.
    func handleAPICompletion(id: String) {
        apiStreamingIds.remove(id)
        notePanelCompletion(key: id)
    }

    /// Remove a finished provider (web host key OR API id) from every pending batch; notify when
    /// a batch empties.
    private func notePanelCompletion(key: String) {
        answeredLastBroadcast.insert(key)   // this panel has a fresh answer to the latest question
        var completedBatches: [PendingBatch] = []
        for (id, var batch) in pendingBatches {
            if batch.pendingKeys.contains(key) {
                batch.pendingKeys.remove(key)
                clog("batch \(id.uuidString.prefix(8)) — removed \(key), remaining: \(batch.pendingKeys)")
                if batch.pendingKeys.isEmpty {
                    completedBatches.append(batch)
                    pendingBatches.removeValue(forKey: id)
                } else {
                    batch.lastActivityAt = Date()
                    pendingBatches[id] = batch
                    scheduleBatchFallback(batchID: id)
                }
            }
        }
        SleepGuard.shared.sync(pendingBatches: pendingBatches.count)
        for batch in completedBatches {
            CompletionNotifier.shared.handleBatchComplete(source: batch.source)
        }
    }

    /// Safety net for undetected completions. Some AIs (Gemini's shadow-DOM stop button is the
    /// usual culprit) occasionally never report "done", which would leave a batch waiting
    /// forever and silently eat the notification. Once a batch has made *some* progress and
    /// then gone quiet for `grace`, notify anyway. Re-armed on every partial completion, so a
    /// genuinely slow AI that keeps reporting won't trip it early.
    private func scheduleBatchFallback(batchID: UUID, grace: TimeInterval = 75) {
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak self] in
            guard let self, let batch = self.pendingBatches[batchID] else { return }
            let quiet = Date().timeIntervalSince(batch.lastActivityAt) >= grace - 1
            let madeProgress = batch.pendingKeys.count < batch.totalCount
            guard quiet, madeProgress else { return }
            // Before declaring "all done", live-check the still-pending AIs. If any still shows a
            // stop button it's still generating OR THINKING (Claude's extended reasoning keeps the
            // stop button up and can outlast the 75s grace, while lastActivityAt only advances on
            // completions — so the batch looked "quiet" though Claude was still working). Don't
            // notify; re-arm a shorter recheck so we fire promptly once it truly stops. This is
            // the fix for "notified complete while an AI was still Thinking".
            self.anyBusy(batch.pendingKeys) { busy in
                guard self.pendingBatches[batchID] != nil else { return }  // completed meanwhile
                if busy {
                    self.pendingBatches[batchID]?.lastActivityAt = Date()
                    clog("batch \(batchID.uuidString.prefix(8)) fallback deferred — still thinking: \(batch.pendingKeys)")
                    self.scheduleBatchFallback(batchID: batchID, grace: 15)
                    return
                }
                self.pendingBatches.removeValue(forKey: batchID)
                SleepGuard.shared.sync(pendingBatches: self.pendingBatches.count)
                clog("batch \(batchID.uuidString.prefix(8)) fallback-fired — undetected completion for \(batch.pendingKeys)")
                CompletionNotifier.shared.handleBatchComplete(source: batch.source)
            }
        }
    }

    // MARK: - Keep-alive keeper window
    // The endgame fix for the minimized/hidden freeze. All JS shims (rAF/rIC/postTask backup
    // timers, visibility masking, WKPreferences knobs) unfroze ChatGPT and Kimi, but Claude's
    // stream stayed byte-frozen for 15+ minutes while hidden (watchdog len Δ0) — some engine-
    // level suspension we can't reach from JS. So don't let the pages become hidden at all:
    // while the main window is hidden/minimized/closed, reparent every webview into a tiny
    // (2×2 px, alpha 0.01, corner, mouse-transparent) always-on-screen window. WebKit then
    // treats the pages as visible and everything — streams, rendering, timers — keeps running.
    private var keeperWindow: NSWindow?
    private var keeperHomes: [String: WeakViewBox] = [:]
    private(set) var keeperActive = false
    final class WeakViewBox { weak var view: NSView?; init(_ v: NSView?) { view = v } }

    /// True while the keeper holds this webview — WebPanel.updateNSView must not re-embed it.
    func isKept(_ webView: WKWebView) -> Bool {
        keeperActive && webView.window === keeperWindow
    }

    /// Does this window host any of our panels? (Used by the miniaturize/close observers.)
    func windowHostsPanels(_ window: NSWindow) -> Bool {
        cache.values.contains { $0.window === window }
    }

    /// Create the keeper window up-front (called once at launch). It must ALREADY be on screen
    /// when ⌘H hides the app: ordering a window front FROM didHide un-hides the app (live logs
    /// showed a 17ms didHide→didUnhide bounce — "⌘H stopped working"), whereas a pre-existing
    /// canHide=false window simply survives the hide with no ordering calls at all.
    func prepareKeeper() {
        guard keeperWindow == nil else { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.alphaValue = 0.01                    // 0.0 could count as not-visible; 0.01 doesn't
        w.ignoresMouseEvents = true
        w.level = .normal
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isExcludedFromWindowsMenu = true
        w.isReleasedWhenClosed = false
        w.canHide = false                      // survives NSApp.hide — the whole point
        if let screen = NSScreen.main {
            w.setFrameOrigin(NSPoint(x: screen.frame.minX, y: screen.frame.minY))
        }
        keeperWindow = w
        w.orderFrontRegardless()               // at launch the app is visible — safe to order in
    }

    func adoptIntoKeeper() {
        prepareKeeper()
        guard let win = keeperWindow, let content = win.contentView else { return }
        var moved = 0
        for (key, wv) in cache where wv.window !== win {
            keeperHomes[key] = WeakViewBox(wv.superview)
            // Keep the current size so the page doesn't reflow (subviews may exceed the tiny
            // window's bounds — AppKit just clips them).
            let sz = wv.bounds.width > 50 ? wv.bounds.size : NSSize(width: 1100, height: 750)
            wv.removeFromSuperview()               // releases the old container's constraints
            wv.translatesAutoresizingMaskIntoConstraints = true
            wv.frame = NSRect(origin: .zero, size: sz)
            content.addSubview(wv)
            moved += 1
        }
        keeperActive = true
        // NO ordering calls here: ordering the keeper front from didHide un-hides the app.
        // The window is on screen from launch (canHide=false carries it through ⌘H); re-order
        // defensively only when the app is NOT hidden.
        if !win.isVisible && !NSApp.isHidden { win.orderFrontRegardless() }
        clog("keeper: adopted \(moved) webviews (main window hidden/minimized)")
        MemoryHeartbeat.shared.note("keeper adopted \(moved)")
    }

    func restoreFromKeeper() {
        guard keeperActive else { return }
        var restored = 0, stillKept = 0, released = 0
        for (key, wv) in cache where wv.window === keeperWindow {
            let home = keeperHomes[key]?.view
            if let home, let hw = home.window, hw.isVisible, !hw.isMiniaturized {
                // Home container is usable — put the webview straight back.
                wv.removeFromSuperview()
                wv.translatesAutoresizingMaskIntoConstraints = true
                wv.frame = home.bounds
                wv.autoresizingMask = [.width, .height]
                // Below the cream cover (containers keep the cover as their topmost subview).
                home.addSubview(wv, positioned: .below, relativeTo: nil)
                keeperHomes.removeValue(forKey: key)
                restored += 1
            } else if home?.window != nil {
                // Home exists but its window is still hidden/miniaturized — restoring now would
                // re-freeze the page; keep it until the window is actually usable.
                stillKept += 1
            } else {
                // Home container is GONE (panel or window rebuilt while hidden). Release the view
                // from the keeper's claim — leaving it "kept" would deadlock: updateNSView refuses
                // to touch kept views, so it could never be re-adopted. Unparented + not-kept, the
                // objectWillChange render below re-embeds it into the new container.
                wv.removeFromSuperview()
                keeperHomes.removeValue(forKey: key)
                released += 1
            }
        }
        keeperActive = stillKept > 0
        if !keeperActive {
            keeperHomes = [:]
            keeperWindow?.orderOut(nil)
        }
        objectWillChange.send()
        clog("keeper: restored \(restored), released \(released), still kept \(stillKept)")
        MemoryHeartbeat.shared.note("keeper restored \(restored)")
    }

    // MARK: - Native completion watchdog
    // The page-side completion poll runs on the page's OWN timers, which WebKit freezes when the
    // window is miniaturized/hidden — live logs showed Claude's stream frozen mid-generation for
    // the whole minimized stretch (completion arrived 1.7s after unhide), while native
    // evaluateJavaScript kept answering throughout. disableBackgroundThrottling() attacks the
    // freeze itself; this watchdog is the belt-and-braces: while any batch is pending, poll each
    // pending web panel's busy state natively every 2s and synthesize the completion on a
    // confirmed busy→idle transition. Whichever side (page poll / watchdog) fires first wins;
    // notePanelCompletion is idempotent so the loser is a no-op.
    private var completionWatchdog: Timer?
    private var watchdogWasBusy: [String: Bool] = [:]
    private var watchdogIdleTicks: [String: Int] = [:]
    private var watchdogLastLen: [String: Int] = [:]
    private var watchdogTickCount = 0
    private func startCompletionWatchdogIfNeeded() {
        guard completionWatchdog == nil else { return }
        watchdogWasBusy = [:]; watchdogIdleTicks = [:]; watchdogTickCount = 0
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdogTick() }
        }
        RunLoop.main.add(t, forMode: .common)   // .common so it fires during window drags too
        completionWatchdog = t
        clog("watchdog armed")
    }
    private func watchdogTick() {
        guard !pendingBatches.isEmpty else {
            completionWatchdog?.invalidate(); completionWatchdog = nil
            watchdogWasBusy = [:]; watchdogIdleTicks = [:]
            SleepGuard.shared.sync(pendingBatches: 0)
            clog("watchdog disarmed — no pending batches")
            return
        }
        watchdogTickCount += 1
        SleepGuard.shared.sync(pendingBatches: pendingBatches.count)   // also enforces the ceiling
        let keys = Set(pendingBatches.values.flatMap { $0.pendingKeys })
        let heartbeat = watchdogTickCount % 15 == 1   // every ~30s
        if heartbeat {
            clog("watchdog alive tick=\(watchdogTickCount) pending=\(keys.sorted())")
        }
        for key in keys {
            guard let wv = cache[key] else { continue }   // API panels already complete natively
            wv.evaluateJavaScript(Broadcaster.watchdogProbeScript()) { [weak self] result, err in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let err { clog("watchdog: \(key) evaluate error — \(err.localizedDescription)") }
                    // Probe returns JSON "[busy, len]" — len tracks the answer text so the logs can
                    // distinguish frozen-mid-stream / still-growing / done-but-button-stuck.
                    var busy = false
                    var len = -1
                    if let s = result as? String, let data = s.data(using: .utf8),
                       let arr = try? JSONSerialization.jsonObject(with: data) as? [Any], arr.count == 2 {
                        busy = (arr[0] as? Bool) ?? ((arr[0] as? Int) == 1)
                        len = (arr[1] as? Int) ?? -1
                    }
                    if busy {
                        let prev = self.watchdogLastLen[key]
                        if self.watchdogWasBusy[key] != true {
                            clog("watchdog: \(key) → busy (len=\(len))")
                        } else if heartbeat {
                            let delta = prev.map { len - $0 } ?? 0
                            clog("watchdog: \(key) still busy len=\(len) (Δ\(delta) over 30s)\(delta == 0 ? " — FROZEN?" : "")")
                        }
                        if heartbeat || prev == nil { self.watchdogLastLen[key] = len }
                        self.watchdogWasBusy[key] = true
                        self.watchdogIdleTicks[key] = 0
                    } else if self.watchdogWasBusy[key] == true {
                        let n = (self.watchdogIdleTicks[key] ?? 0) + 1
                        self.watchdogIdleTicks[key] = n
                        if n >= 2 {   // two consecutive idle reads ≈ 4s, rides out button flicker
                            self.watchdogWasBusy[key] = false
                            self.watchdogIdleTicks[key] = 0
                            clog("watchdog: \(key) busy→idle confirmed — synthesizing completion")
                            self.streamingKeys.remove(key)
                            self.notePanelCompletion(key: key)
                        }
                    }
                }
            }
        }
    }

    private func providerKey(forHost host: String) -> String? {
        // Built-ins: substring rules (robust to auth subdomains / redirects).
        if host.contains("chatgpt") || host.contains("openai") { return "chatgpt" }
        if host.contains("claude") { return "claude" }
        if host.contains("gemini") || host.contains("google") { return "gemini" }
        // Custom providers: match against the registered host.
        for p in ProviderRegistry.custom() {
            if let h = p.url.host, !h.isEmpty, host.contains(h) || h.contains(host) {
                return p.key
            }
        }
        return nil
    }

    // MARK: - Agent bridge support

    /// Panels an agent question goes to: exactly what the user has on screen. Deliberately not
    /// agent-selectable — the panels you chose to show are the ones you've consented to have
    /// asked, and letting a caller name arbitrary providers would quietly wake hidden ones.
    func agentTargetKeys() -> [String] {
        let hidden = Set((UserDefaults.standard.string(forKey: "hiddenProviders") ?? "")
            .split(separator: ",").map(String.init))
        return cache.keys.filter { !hidden.contains($0) }
    }

    /// Wait for the current agent round to finish, then hand back each panel's answer. Resolves
    /// early once every target has reported; otherwise returns whatever exists at the timeout, so
    /// one stuck panel can't swallow the other answers.
    func awaitAgentAnswers(timeout: TimeInterval,
                           completion: @escaping ([(key: String, name: String, text: String)]) -> Void) {
        let targets = Set(agentTargetKeys())
        let deadline = Date().addingTimeInterval(timeout)
        var done = false

        func harvest() {
            guard !done else { return }
            done = true
            let providers = ProviderRegistry.all()
            var out: [(key: String, name: String, text: String)] = []
            let group = DispatchGroup()
            for key in targets.sorted() {
                let name = providers.first { $0.key == key }?.name ?? key
                group.enter()
                self.extractAnswer(key: key) { text in
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { out.append((key: key, name: name, text: t)) }
                    group.leave()
                }
            }
            group.notify(queue: .main) { completion(out.sorted { $0.key < $1.key }) }
        }

        func poll() {
            guard !done else { return }
            if targets.isSubset(of: self.answeredLastBroadcast) { return harvest() }
            if Date() >= deadline { return harvest() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { poll() }
        }
        poll()
    }

    /// The ON-SCREEN panels as @-mention candidates: web panels in the user's display order,
    /// then API panels. Hidden panels are excluded so a mention can never wake one.
    func directedCandidates() -> [DirectedPrompt.Candidate] {
        let hidden = Set((UserDefaults.standard.string(forKey: "hiddenProviders") ?? "")
            .split(separator: ",").map(String.init))
        let order = (UserDefaults.standard.string(forKey: "providerOrder") ?? "")
            .split(separator: ",").map(String.init)
        let all = ProviderRegistry.all()
        let web = order.compactMap { k in all.first { $0.key == k } } + all.filter { !order.contains($0.key) }
        return web.filter { !hidden.contains($0.key) }
                .map { DirectedPrompt.Candidate(id: $0.key, name: $0.name, host: $0.url.host ?? "") }
            + APIProviderRegistry.all().filter { !hidden.contains($0.id) }
                .map { DirectedPrompt.Candidate(id: $0.id, name: $0.name) }
    }

    /// Parse a leading "@name " prefix into a directed target — "@gemini 展开说说第二点" →
    /// (["gemini"], "展开说说第二点"). The matching rules live in `DirectedPrompt` (pure, tested).
    func resolveDirectedPrompt(_ raw: String) -> (targets: Set<String>?, text: String) {
        DirectedPrompt.resolve(raw, candidates: directedCandidates())
    }

    /// Record/clear a panel's load failure (called from the navigation delegate).
    func noteLoadFailure(host: String, reason: String) {
        guard let key = providerKey(forHost: host) else { return }
        loadErrors[key] = reason
        clog("load failed — \(key): \(reason)")
    }
    func clearLoadFailure(host: String) {
        guard let key = providerKey(forHost: host), loadErrors[key] != nil else { return }
        loadErrors.removeValue(forKey: key)
    }
    func retryLoad(key: String) {
        loadErrors.removeValue(forKey: key)
        cache[key]?.reload()
    }

    /// Cookie names that carry REGION / consent / preference state rather than a login session.
    /// Google caches its "which country are you in" verdict in these, which is why Gemini keeps
    /// showing "not supported in your country" after you switch to a working proxy node — the
    /// verdict is cached per cookie store, and Chorus has its own, separate from Chrome's.
    /// Deleting only these re-runs the geo check WITHOUT signing the user out.
    private static let regionCookieNames: Set<String> = [
        "NID", "AEC", "SOCS", "OTZ", "CONSENT", "DV", "1P_JAR",
        "__Secure-ENID", "__Secure-OSID", "ENID",
        "cf_clearance",          // Cloudflare's region/challenge verdict (ChatGPT, Claude)
    ]

    /// Soft reset: drop region/consent cookies for this panel's host and reload. Keeps the login.
    func refreshSiteState(key: String) {
        guard let wv = cache[key], let host = wv.url?.host ?? providerHost(for: key) else { return }
        let store = wv.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { cookies in
            let base = Self.registrableSuffix(host)
            let doomed = cookies.filter { c in
                Self.regionCookieNames.contains(c.name) && c.domain.hasSuffix(base)
            }
            let group = DispatchGroup()
            for c in doomed { group.enter(); store.delete(c) { group.leave() } }
            group.notify(queue: .main) {
                clog("site state refreshed — \(key): dropped \(doomed.count) region cookie(s) for \(base)")
                wv.reload()
            }
        }
    }

    /// Hard reset: wipe EVERYTHING this host stored (cookies, caches, local/session storage,
    /// service workers) and reload — this signs the user out of that AI.
    func clearSiteData(key: String) {
        guard let wv = cache[key], let host = wv.url?.host ?? providerHost(for: key) else { return }
        let base = Self.registrableSuffix(host)
        let ds = wv.configuration.websiteDataStore
        ds.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let hit = records.filter { $0.displayName.hasSuffix(base) || base.hasSuffix($0.displayName) }
            ds.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: hit) {
                clog("site data cleared — \(key): \(hit.count) record(s) for \(base)")
                if let u = self.freshURL(forKey: key) { wv.load(URLRequest(url: u)) } else { wv.reload() }
            }
        }
    }

    /// "google.com" for "gemini.google.com" — cookies are usually set on the parent domain.
    private static func registrableSuffix(_ host: String) -> String {
        let parts = host.split(separator: ".")
        guard parts.count > 2 else { return host }
        return parts.suffix(2).joined(separator: ".")
    }

    private func providerHost(for key: String) -> String? {
        (ProviderRegistry.builtIn + ProviderRegistry.custom()).first { $0.key == key }?.url.host
    }

    /// Drop a webview (used when a custom provider is removed) so it stops consuming memory.
    func removeWebView(key: String) {
        MemoryHeartbeat.shared.note("webview removed \(key)")
        urlObservers.removeValue(forKey: key)?.invalidate()
        loadingObservers.removeValue(forKey: key)?.invalidate()
        cache[key]?.removeFromSuperview()
        cache[key] = nil
        streamingKeys.remove(key)
        favicons.removeValue(forKey: key)
        loadingKeys.remove(key)
    }

    /// Tear down a HIDDEN panel's webview to stop it consuming CPU/energy (all WebKit power
    /// saving is disabled for the notification fix, so an invisible page runs full tilt).
    /// The conversation URL is continuously recorded via KVO, so re-showing the panel recreates
    /// the webview right back on the same conversation. Skips (and retries once) if the panel is
    /// mid-generation, so a completion isn't lost.
    func destroyHiddenPanel(key: String, retried: Bool = false) {
        guard cache[key] != nil else { return }
        if streamingKeys.contains(key), !retried {
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                self?.destroyHiddenPanel(key: key, retried: true)
            }
            return
        }
        removeWebView(key: key)
        clog("hidden panel torn down — \(key) (recreated on re-show)")
    }

    /// Schedule a hidden panel's teardown after a grace period, skipping it if the panel has
    /// been shown again by then. EVERY path that hides a web panel must go through here: the
    /// layout picker once bypassed it and left up to five invisible pages running full tilt
    /// (all WebKit power saving is off for the notification fix, so hidden ≠ idle).
    func scheduleTeardownIfStillHidden(key: String, grace: TimeInterval = 60) {
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak self] in
            let stillHidden = (UserDefaults.standard.string(forKey: "hiddenProviders") ?? "")
                .split(separator: ",").map(String.init).contains(key)
            if stillHidden { self?.destroyHiddenPanel(key: key) }
        }
    }
}

/// A composer-attached image with a stable id, so the preview ForEach can key on identity and a
/// remove-by-tap can't hit the macOS-13 ForEach(indices) out-of-range crash.
private struct AttachedImage: Identifiable {
    let id = UUID()
    let image: NSImage
}

struct ContentView: View {
    @EnvironmentObject private var store: WebViewStore
    @ObservedObject private var apiStore = APIChatStore.shared   // native API model panels
    @ObservedObject private var voteStore = VoteStore.shared     // per-round "best answer" votes
    @State private var showStats = false
    @State private var prompt: String = ""
    @State private var attachedImages: [AttachedImage] = []
    @FocusState private var promptFocused: Bool

    // Voice input (on-device dictation) for the main composer.
    @StateObject private var dictator = SpeechDictator()
    @State private var dictationBase = ""
    @State private var micPulse = false

    // Drives the per-panel native cream cover during a removal reflow (masks WKWebView's white
    // repaint-on-resize). Raised proactively in toggleHidden, before the reflow.
    @State private var reflowing = false
    // Set to an API provider id when its "new chat" is tapped → shows a clear-confirmation alert.
    @State private var clearConfirmAPIId: String? = nil
    /// Panel key awaiting confirmation for the destructive "clear all site data" action.
    @State private var clearDataConfirmKey: String? = nil
    // "Summarize answers": the synthesis sheet state.
    @State private var showSummary = false
    @State private var summaryText = ""
    @State private var summaryStreaming = false
    @State private var summaryTask: Task<Void, Never>? = nil

    /// Gather every visible AI's latest answer (web panels via DOM scrape, API panels natively),
    /// then have `provider` synthesize a comparison. Streams the result into the summary sheet.
    /// Gather every visible AI's latest answer (web via DOM scrape, API natively).
    /// `freshOnly` = restrict to the panels that answered the LAST broadcast (used by summarize so
    /// stale topics don't mix); when false, take whatever each panel currently shows (used by the
    /// share card, so you can share a previous answer too). Shared by "summarize" and "share card".
    private func gatherAnswers(freshOnly: Bool, _ done: @escaping ([(name: String, color: Color, text: String)]) -> Void) {
        let answered = store.answeredLastBroadcast
        let gate: (String) -> Bool = { key in !freshOnly || answered.isEmpty || answered.contains(key) }
        let webProviders = visibleProviders.filter { gate($0.key) }
        var web = [String?](repeating: nil, count: webProviders.count)
        let group = DispatchGroup()
        for (i, p) in webProviders.enumerated() {
            group.enter()
            store.extractAnswer(key: p.key) { web[i] = $0; group.leave() }
        }
        group.notify(queue: .main) {
            var blocks: [(name: String, color: Color, text: String)] = []
            for (i, p) in webProviders.enumerated() {
                let t = (web[i] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { blocks.append((p.name, ProviderStyle.accent(key: p.key, host: p.url.host ?? ""), t)) }
            }
            for p in visibleAPIProviders where gate(p.id) {
                if let last = apiStore.messages(for: p.id).last(where: { $0.role == .assistant && !$0.text.isEmpty }) {
                    blocks.append((p.name, ProviderStyle.accent(key: p.id, host: ""), last.text))
                }
            }
            done(blocks)
        }
    }

    private func summarizeAnswers(using provider: APIProvider) {
        summaryTask?.cancel()
        // Open the sheet IMMEDIATELY in its working state. Extraction queues on each panel's JS
        // thread and can take seconds when a page is busy — opening the sheet only afterwards
        // left a dead, no-feedback gap between the click and anything appearing.
        summaryText = ""
        summaryStreaming = true
        // Present on the NEXT runloop, not in the same transaction as the state reset: macOS
        // builds a first-presented sheet's content from the PRE-transaction snapshot (streaming=
        // false, empty text → the blank branch) and nothing re-triggers evaluation until the first
        // streamed token seconds later. Deferring one turn makes the sheet see the committed
        // working state, so the spinner shows from the first frame on the FIRST click too.
        DispatchQueue.main.async { showSummary = true }
        gatherAnswers(freshOnly: true) { blocks in
            guard blocks.count >= 2 else {
                summaryText = Lf("summary.needTwo", blocks.count)
                summaryStreaming = false
                return
            }
            runSummary(provider: provider, blocks: blocks.map { (name: $0.name, text: $0.text) })
        }
    }

    // Share card.
    @State private var showShareCard = false
    @State private var shareCardData: ShareCardData? = nil

    /// Collect the currently-displayed answers (history included) and open the share-card preview,
    /// where the user picks a desktop or mobile size and copies/saves the rendered image.
    private func generateShareCard() {
        MemoryHeartbeat.shared.note("share card")
        gatherAnswers(freshOnly: false) { blocks in
            shareCardData = blocks.isEmpty ? nil
                : ShareCardData(question: store.lastBroadcast,
                                answers: blocks.map { ShareAnswer(name: $0.name, color: $0.color, text: $0.text) })
            // Present on the NEXT runloop: presenting in the same transaction as the data write
            // makes the FIRST-ever presentation build from the pre-transaction snapshot (nil →
            // "no answers"), with nothing arriving later to trigger a rebuild. Same bug and same
            // fix as the summary sheet.
            DispatchQueue.main.async { showShareCard = true }
        }
    }

    private func runSummary(provider: APIProvider, blocks: [(name: String, text: String)]) {
        MemoryHeartbeat.shared.note("summary blocks=\(blocks.count) chars=\(blocks.reduce(0) { $0 + $1.text.count })")
        let q = store.lastBroadcast.trimmingCharacters(in: .whitespacesAndNewlines)
        let joined = blocks.map { "【\($0.name)】\n\($0.text)" }.joined(separator: "\n\n———\n\n")
        // The summary is a reply to the QUESTION, so its language follows the question — not the
        // UI. An English-UI user who asked in Chinese and got Chinese answers wants a Chinese
        // summary (the quick-prompt chips follow the same rule). With no question to judge by
        // (rare), the answers decide; with nothing at all, the UI language does.
        let sample = q.isEmpty ? String(blocks.map(\.text).joined(separator: " ").prefix(2000)) : q
        let prompt = !chipsAreChinese(for: sample)
            ? """
        Below are \(blocks.count) AI answers to \(q.isEmpty ? "the same question" : "the question “\(q)”"). Compare them in English and give me:
        1. Consensus — what they all agree on
        2. Main disagreements / contradictions
        3. What each one uniquely contributes
        4. A one-sentence bottom line

        Format: short headings plus bullet lists (lines starting with -). **Do not use markdown tables** (the pipe | kind) — the viewer can't render them and they come out garbled. For disagreements, give each dimension its own short section with each AI's position as a bullet, not a table.

        \(joined)
        """
            : """
        下面是 \(blocks.count) 个 AI 对\(q.isEmpty ? "同一个问题" : "问题「\(q)」")的回答。请用中文综合对比,给我:
        1. 共识 —— 它们都同意的点
        2. 主要分歧 / 矛盾
        3. 各自独特或最有价值的点
        4. 一句话综合结论

        格式要求:用小标题和要点列表(- 开头)。**不要用 markdown 表格**(竖线 | 那种),展示窗口不支持表格,会显示成乱码。分歧对比也请用"每个维度一段、各家观点用要点列出"的方式,不要排成表格。

        \(joined)
        """
        summaryText = ""
        summaryStreaming = true
        showSummary = true
        summaryTask = Task {
            do {
                try await APIClient.stream(provider: provider, messages: [ChatMessage(role: .user, text: prompt)]) { delta in
                    Task { @MainActor in summaryText += delta }
                }
            } catch {
                await MainActor.run { summaryText += "\n\n[" + L("common.error") + "] " + APIClient.friendly(error) }
            }
            await MainActor.run { summaryStreaming = false }
        }
    }

    @AppStorage("providerOrder") private var providerOrderRaw: String = "chatgpt,claude,gemini"
    @AppStorage("hiddenProviders") private var hiddenProvidersRaw: String = ""
    @AppStorage("customProviders") private var customProvidersRaw: String = ""
    @AppStorage("appLanguage") private var appLanguage: String = "system"  // re-render on language switch
    @AppStorage("appearance") private var appearance: String = "light"
    @AppStorage("minimalMode") private var minimalMode: Bool = false
    /// Panels per row. Default 3 keeps the historical single row for anyone running the usual
    /// three panels, while more panels now wrap instead of shrinking into unreadable slivers.
    @AppStorage("panelColumns") private var panelColumns: Int = 3
    @State private var showLayoutPicker = false
    @AppStorage("welcomeSeen") private var welcomeSeen: Bool = false   // first-run welcome card
    @State private var showWelcome = false
    // Observed so the main window re-renders (and shows/removes API cards) the moment an API
    // model is added or removed in Settings — no app restart needed. Read via APIProviderRegistry.
    @AppStorage("apiProviders") private var apiProvidersRaw: String = ""
    @Environment(\.colorScheme) private var colorScheme

    /// Built-ins + user-added providers. Recomputes when customProvidersRaw changes.
    private var allProviders: [Provider] {
        ProviderRegistry.builtIn + ProviderRegistry.decode(customProvidersRaw)
    }

    @State private var dropTargetKey: String? = nil
    @State private var hoveredHeaderKey: String? = nil
    @State private var pasteMonitor: Any? = nil

    // Prompt history (↑/↓ recall) browsing state.
    @State private var historyIndex: Int? = nil
    @State private var historyDraft: String = ""

    // @-mention: the picked "only this AI" chip, the picker's rows while "@…" is being typed,
    // and the previous text (macOS 13's onChange has no old-value form) for the space-to-chip
    // conversion. See DirectedPrompt.
    @State private var directedTarget: DirectedPrompt.Target? = nil
    @State private var pickerOptions: [DirectedPrompt.Target] = []
    @State private var pickerIndex: Int = 0
    @State private var lastPrompt: String = ""

    private var orderedProviders: [Provider] {
        let storedKeys = providerOrderRaw.split(separator: ",").map(String.init)
        var result: [Provider] = []
        for key in storedKeys {
            if let p = allProviders.first(where: { $0.key == key }) {
                result.append(p)
            }
        }
        for p in allProviders where !result.contains(where: { $0.key == p.key }) {
            result.append(p)
        }
        return result
    }

    private var hiddenKeys: Set<String> {
        Set(hiddenProvidersRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    /// One entry per on-screen panel, web and API alike, so the grid can lay them out together.
    private enum PanelItem: Identifiable {
        case web(Provider)
        case api(APIProvider)
        var id: String {
            switch self {
            case .web(let p): return "w_" + p.key
            case .api(let p): return "a_" + p.id
            }
        }
    }

    private var visiblePanels: [PanelItem] {
        visibleProviders.map { .web($0) } + visibleAPIProviders.map { .api($0) }
    }

    /// Panels split into rows of `panelColumns`. Columns are capped by the panel count, so with
    /// three panels and "3 columns" this is exactly the old single row; a partial last row lets
    /// its panels stretch rather than leaving a hole.
    private var panelRows: [[PanelItem]] {
        let items = visiblePanels
        guard !items.isEmpty else { return [] }
        let cols = max(1, min(panelColumns, items.count))
        return stride(from: 0, to: items.count, by: cols).map {
            Array(items[$0 ..< min($0 + cols, items.count)])
        }
    }

    @ViewBuilder private func panelView(_ item: PanelItem) -> some View {
        switch item {
        case .web(let p): card(for: p)
        case .api(let p): apiCard(for: p)
        }
    }

    private var visibleProviders: [Provider] {
        orderedProviders.filter { !hiddenKeys.contains($0.key) }
    }

    /// All configured API providers, decoded from the observed @AppStorage so the main window
    /// updates the instant one is added/removed in Settings (no restart).
    private var apiProviders: [APIProvider] {
        APIProviderRegistry.decode(apiProvidersRaw)
    }

    /// Configured API model providers shown after the web cards (removed via Settings).
    private var visibleAPIProviders: [APIProvider] {
        apiProviders.filter { !hiddenKeys.contains($0.id) }
    }

    /// Toggle a provider's visibility. Refuses to hide the last-remaining visible panel.
    private func toggleHidden(_ key: String) {
        var keys = hiddenKeys
        if keys.contains(key) {
            // Un-hiding adds a panel → survivors only shrink, which never flashes. Apply directly.
            keys.remove(key)
            hiddenProvidersRaw = keys.sorted().joined(separator: ",")
        } else {
            // Don't allow hiding the last visible web panel. Count VISIBLE panels directly —
            // hiddenKeys also carries hidden API-panel ids, so the old arithmetic
            // (orderedProviders.count - keys.count - 1) went negative once several customs/API
            // panels were hidden, silently blocking ALL web-panel hiding.
            guard visibleProviders.count > 1 else { return }
            keys.insert(key)
            let newRaw = keys.sorted().joined(separator: ",")
            // Hiding makes survivors WIDEN → WKWebView paints that strip white for a beat. Raise
            // the native cream cover THIS frame, then do the actual removal next runloop so the
            // widen happens under the cover; fade the cover out after WebKit has redrawn.
            reflowing = true
            DispatchQueue.main.async {
                hiddenProvidersRaw = newRaw
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { reflowing = false }
            }
            // Energy: tear down the hidden panel's webview after a grace period (a quick
            // hide→show toggle inside the window costs nothing; past it, re-show reloads and
            // restores the recorded conversation).
            store.scheduleTeardownIfStillHidden(key: key)
        }
    }

    /// Show/hide a native API panel. No "last panel" guard (an API panel is an optional extra —
    /// the web panels remain), and no reflow cover (native cards don't flash white on resize).
    private func toggleHiddenAPI(_ id: String) {
        var keys = hiddenKeys
        if keys.contains(id) { keys.remove(id) } else { keys.insert(id) }
        hiddenProvidersRaw = keys.sorted().joined(separator: ",")
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            // Floating webview "cards" on the canvas. Reordering just shuffles the ForEach;
            // WKWebViews stay alive in the store and get reparented into the new positions.
            // Rows of panels. The grid always FILLS the window and each panel scrolls its own
            // page — an outer scroll would fight the webviews for the scroll wheel.
            VStack(spacing: ChorusTheme.gap) {
                ForEach(Array(panelRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: ChorusTheme.gap) {
                        ForEach(row) { item in
                            panelView(item)
                                .frame(minWidth: 300, maxWidth: .infinity)
                        }
                    }
                    .frame(minHeight: 240, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, ChorusTheme.margin)
            .padding(.top, 6)
            .frame(maxHeight: .infinity)

            composer
                .padding(.horizontal, ChorusTheme.margin)
                .padding(.top, ChorusTheme.gap)
                .padding(.bottom, ChorusTheme.margin)
        }
        .ignoresSafeArea(.container, edges: .top)   // pull content up under the hidden titlebar
        .background(ChorusTheme.canvas(colorScheme).ignoresSafeArea())
        .background(WindowConfigurator())
        .onAppear {
            AppearanceManager.apply(appearance)
            // Pre-create webviews for VISIBLE panels only, so their lifecycle is independent of
            // view rebuilds. Hidden panels used to be created too — with all power-saving disabled
            // for the notification fix, that meant 5+ invisible full-tilt web pages burning energy
            // around the clock. A hidden panel now costs nothing; re-showing it recreates the
            // webview and restores its recorded conversation URL.
            let hidden = Set(hiddenProvidersRaw.split(separator: ",").map(String.init))
            for p in allProviders where !hidden.contains(p.key) {
                _ = store.getOrCreate(key: p.key, url: p.url)
            }
            if !welcomeSeen { showWelcome = true }   // first launch only
        }
        .onChange(of: appearance) { newValue in
            AppearanceManager.apply(newValue)
        }
        .alert(L("panel.clearData.title"), isPresented: Binding(
            get: { clearDataConfirmKey != nil },
            set: { if !$0 { clearDataConfirmKey = nil } }
        )) {
            Button(L("panel.clearData.confirm"), role: .destructive) {
                if let k = clearDataConfirmKey { store.clearSiteData(key: k) }
                clearDataConfirmKey = nil
            }
            Button(L("common.cancel"), role: .cancel) { clearDataConfirmKey = nil }
        } message: {
            Text(L("panel.clearData.message"))
        }
        .alert(L("api.clearConfirm.title"), isPresented: Binding(
            get: { clearConfirmAPIId != nil },
            set: { if !$0 { clearConfirmAPIId = nil } }
        )) {
            Button(L("api.clearConfirm.clear"), role: .destructive) {
                if let id = clearConfirmAPIId { apiStore.newChat(id) }
                clearConfirmAPIId = nil
            }
            Button(L("common.cancel"), role: .cancel) { clearConfirmAPIId = nil }
        } message: {
            Text(L("api.clearConfirm.message"))
        }
        .sheet(isPresented: $showSummary, onDismiss: { summaryTask?.cancel() }) {
            SummarySheet(text: summaryText, streaming: summaryStreaming) {
                summaryTask?.cancel()
                showSummary = false
            }
        }
        .sheet(isPresented: $showShareCard) {
            ShareCardSheet(data: shareCardData) { showShareCard = false }
        }
        .sheet(isPresented: $showStats) {
            StatsSheet { showStats = false }
        }
        .sheet(isPresented: $showWelcome) {
            WelcomeSheet {
                welcomeSeen = true
                showWelcome = false
                // Ask for notification permission HERE, not at launch: the guide's last step just
                // explained what notifications are for, so the system dialog lands with context
                // (launch-time asks stacked on top of this sheet with zero explanation).
                CompletionNotifier.shared.requestAuthorizationIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chorusShowGuide)) { _ in
            showWelcome = true   // 菜单 → 使用指引
        }
    }

    /// Minimal immersive top strip — just reserves the traffic-light row so the cards don't
    /// slide under the window controls. All global actions now live in the composer's menu.
    private var topBar: some View {
        // The explicit window-drag strip (background dragging is off so the composer can select
        // text — see WindowConfigurator).
        WindowDragHandle().frame(height: 28)
    }

    private func openSettings() {
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    /// Shown over a panel whose page failed to load — the webview itself would just be white.
    private func loadErrorCard(name: String, reason: String, kind: InkCast, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            InkCharacter(kind: kind, pose: InkPose(lookX: -0.35, lookY: 0.9))
                .frame(height: 58)
            Text(Lf("panel.loadFailed", name))
                .font(.chorus(13, .semibold))
            Text(reason)
                .font(.chorus(11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 18)
            Text(L("panel.loadFailed.hint"))
                .font(.chorus(10.5))
                .foregroundColor(.secondary.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
            Button(action: retry) {
                Text(L("panel.retry"))
                    .font(.chorus(12, .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChorusTheme.canvas(colorScheme))
    }

    private func card(for p: Provider) -> some View {
        VStack(spacing: 0) {
            AccentBar(color: ProviderStyle.accent(key: p.key, host: p.url.host ?? ""))
            slimHeader(for: p, cast: .forPanel(panelIndex("w_" + p.key)))
            WebPanel(webView: store.getOrCreate(key: p.key, url: p.url), reflowing: reflowing)
                .overlay(alignment: .center) {
                    // A failed load renders as a blank white webview; say so instead.
                    if let reason = store.loadErrors[p.key] {
                        loadErrorCard(name: p.name, reason: reason, kind: .forPanel(panelIndex("w_" + p.key))) {
                            store.retryLoad(key: p.key)
                        }
                    }
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: ChorusTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ChorusTheme.cardRadius, style: .continuous)
                .strokeBorder(
                    dropTargetKey == p.key ? ChorusTheme.brandOrange.opacity(0.9) : ChorusTheme.cardBorder(colorScheme),
                    lineWidth: dropTargetKey == p.key ? 3 : 1
                )
        )
        // While a panel is dragged over this one, wash the whole card in the accent tint. The
        // system draws a COPY (+) cursor for the drag — the wrong verb for a reorder — so the
        // layout, not the cursor, has to say "release here and they swap".
        .overlay {
            if dropTargetKey == p.key {
                RoundedRectangle(cornerRadius: ChorusTheme.cardRadius, style: .continuous)
                    .fill(ChorusTheme.brandOrange.opacity(0.10))
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: ChorusTheme.cardShadow(colorScheme).color,
                radius: ChorusTheme.cardShadow(colorScheme).radius,
                x: 0, y: ChorusTheme.cardShadow(colorScheme).y)
    }

    /// A native API model card — same chrome as a web card, but a native chat transcript instead
    /// of a WKWebView.
    private func apiCard(for p: APIProvider) -> some View {
        VStack(spacing: 0) {
            AccentBar(color: ProviderStyle.accent(key: p.id, host: ""))
            apiSlimHeader(for: p, cast: .forPanel(panelIndex("a_" + p.id)))
            APIPanelView(provider: p)
        }
        .clipShape(RoundedRectangle(cornerRadius: ChorusTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ChorusTheme.cardRadius, style: .continuous)
                .strokeBorder(ChorusTheme.cardBorder(colorScheme), lineWidth: 1)
        )
        .shadow(color: ChorusTheme.cardShadow(colorScheme).color,
                radius: ChorusTheme.cardShadow(colorScheme).radius,
                x: 0, y: ChorusTheme.cardShadow(colorScheme).y)
    }

    /// Slim header for an API card: brand dot, name + model, a stop button while streaming, and
    /// a "new chat" on hover. (No hide button — API panels are added/removed in Settings.)
    private func apiSlimHeader(for p: APIProvider, cast: InkCast) -> some View {
        HStack(spacing: 7) {
            statusCharacter(cast, key: p.id, singing: apiStore.isStreaming(p.id))
            Text(p.name)
                .font(.chorus(12, .semibold))
                .foregroundColor(.primary.opacity(0.9))
            // Marks this as a native API panel — disambiguates from a web panel of the same name.
            Text("API")
                .font(.chorus(8.5, .bold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            if !p.model.isEmpty {
                Text(p.model)
                    .font(.chorus(10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)   // shrink the long model name first, keep the buttons clear
            }
            Spacer(minLength: 8)
            winnerTrophy(key: p.id, accentHost: "", name: p.name)
            if apiStore.isStreaming(p.id) {
                Button { apiStore.stop(p.id) } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("api.stop"))
            }
            // Always visible (not hover-only) so clearing an API conversation is discoverable.
            // Confirms first — clearing an API conversation is permanent (no server-side history).
            Button { clearConfirmAPIId = p.id } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("menu.newChat"))
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                if hoveredHeaderKey == p.id { Rectangle().fill(Color.primary.opacity(0.05)) }
            }
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                hoveredHeaderKey = hovering ? p.id : (hoveredHeaderKey == p.id ? nil : hoveredHeaderKey)
            }
        }
    }

    /// Thin neutral status strip: a "thinking" dot, the provider name, and hover actions.
    /// Kept minimal so it doesn't compete with each site's own header below it.
    /// "This answer won the round" trophy. A star was the obvious first choice but the wrong
    /// word: everywhere else ☆ means FAVOURITE — a persistent bookmark — while this is a
    /// single-choice verdict on one round, and what it feeds is literally called 胜率 / win rate.
    /// A trophy says that without a legend. Shown only once the round is votable
    /// (this panel answered AND ≥2 panels answered — a 1-panel vote is meaningless). Single-select:
    /// clicking a different panel moves the crown; clicking the current winner clears it.
    @ViewBuilder private func winnerTrophy(key: String, accentHost: String, name: String) -> some View {
        if store.answeredLastBroadcast.contains(key) && store.answeredLastBroadcast.count >= 2 {
            let isWinner = voteStore.currentWinner == key
            Button {
                pickWinner(key)
            } label: {
                // The film's trophy. One gold for the award everywhere, NOT each panel's brand
                // color: the trophy is a verdict, not part of that AI's identity, and per-panel
                // colors made the winner blend into its own card instead of standing out across
                // the row. Unselected stays an outline so exactly one gold mark shows per round.
                TrophyGlyph(won: isWinner)
                    .frame(width: 16, height: 15)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isWinner ? Lf("vote.chosen", name) : Lf("vote.choose", name))
        }
    }

    /// Snapshot the round context and record the pick (held in memory, written on the next round).
    private func pickWinner(_ key: String) {
        let contenders = Array(store.answeredLastBroadcast)
        var names: [String: String] = [:]
        for k in contenders {
            if let p = allProviders.first(where: { $0.key == k }) { names[k] = p.name }
            else if let p = apiProviders.first(where: { $0.id == k }) { names[k] = p.name }
            else { names[k] = k }
        }
        voteStore.pick(winner: key, broadcastId: store.currentBroadcastId,
                       question: store.lastBroadcast, contenders: contenders, names: names)
    }

    /// Where a panel sits among the visible ones — it picks the panel's character (circle,
    /// square, triangle, then round again), the same order as the film and the app icon.
    private func panelIndex(_ id: String) -> Int {
        visiblePanels.firstIndex { $0.id == id } ?? 0
    }

    /// The panel's character: sings while its AI answers, ^ ^ when it's done.
    private func statusCharacter(_ cast: InkCast, key: String, singing: Bool) -> some View {
        PanelStatusCharacter(kind: cast, singing: singing, answered: store.answeredLastBroadcast.contains(key))
            .frame(width: 19, height: 22)
            .padding(.top, 1)
    }

    private func slimHeader(for p: Provider, cast: InkCast) -> some View {
        HStack(spacing: 7) {
            // The panel's character stands where the site's favicon used to: in the film each
            // character IS one AI, singing its answer. The name beside it and the accent bar
            // above still say which AI this is.
            statusCharacter(cast, key: p.key, singing: store.streamingKeys.contains(p.key))
            Text(p.name)
                .font(.chorus(12, .semibold))
                .foregroundColor(.primary.opacity(0.9))
            Spacer()
            winnerTrophy(key: p.key, accentHost: p.url.host ?? "", name: p.name)
            // Loading spinner — always visible (not hover-gated) while the page reloads, so a
            // reload tap visibly registers and the user waits instead of clicking again.
            if store.loadingKeys.contains(p.key) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
                    .frame(width: 14, height: 14)
            }
            if hoveredHeaderKey == p.key {
                // Occasional actions live behind "…" rather than a header .contextMenu: a
                // context menu's recognizer swallows the header's .draggable gesture, which
                // silently broke drag-to-reorder (cursor flashed to a hand, then nothing).
                Menu {
                    // Explicit reordering. Dragging a header works, but macOS shows the COPY (+)
                    // cursor for it — the wrong verb for "move this panel" — and nothing hints
                    // that panels are draggable at all. These say it outright.
                    Button(L("panel.moveLeft")) { movePanel(key: p.key, by: -1) }
                        .disabled(!canMovePanel(key: p.key, by: -1))
                    Button(L("panel.moveRight")) { movePanel(key: p.key, by: 1) }
                        .disabled(!canMovePanel(key: p.key, by: 1))
                    Divider()
                    Button(L("panel.refreshSite")) { store.refreshSiteState(key: p.key) }
                    Button(L("panel.clearData"), role: .destructive) { clearDataConfirmKey = p.key }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 14)
                .help(L("panel.moreActions"))
                .transition(.opacity)

                // Per-panel new chat — asking ONE AI a fresh question is a common flow (the
                // global New chat resets every panel, which is a different intent).
                Button {
                    store.newChat(key: p.key)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(Lf("panel.newChat", p.name))
                .transition(.opacity)

                // Reload hidden while loading (the spinner is there instead → can't double-tap).
                if !store.loadingKeys.contains(p.key) {
                    Button {
                        store.reload(key: p.key)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(Lf("panel.reload", p.name))
                    .transition(.opacity)
                }

                if visibleProviders.count > 1 {
                    Button {
                        toggleHidden(p.key)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(Lf("panel.hide", p.name))
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                if dropTargetKey == p.key {
                    Rectangle().fill(ChorusTheme.brandOrange.opacity(0.25))
                } else if hoveredHeaderKey == p.key {
                    Rectangle().fill(Color.primary.opacity(0.05))
                }
            }
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                hoveredHeaderKey = hovering ? p.key : (hoveredHeaderKey == p.key ? nil : hoveredHeaderKey)
            }
            if hovering { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
        }
        .draggable(p.key) {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal").font(.caption)
                Text(p.name).font(.subheadline)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ChorusTheme.brandOrange)
            .foregroundColor(.white)
            .cornerRadius(6)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let droppedKey = items.first else { return false }
            reorder(droppedKey: droppedKey, targetKey: p.key)
            return true
        } isTargeted: { isTargeted in
            withAnimation(.easeOut(duration: 0.1)) {
                dropTargetKey = isTargeted ? p.key : (dropTargetKey == p.key ? nil : dropTargetKey)
            }
        }
    }

    /// Can this panel move one slot in `direction` (-1 left, +1 right) among VISIBLE panels?
    private func canMovePanel(key: String, by direction: Int) -> Bool {
        guard let i = visibleProviders.firstIndex(where: { $0.key == key }) else { return false }
        let target = i + direction
        return target >= 0 && target < visibleProviders.count
    }

    /// Swap this panel with its visible neighbour. Works on the full order list so hidden panels
    /// keep their relative places.
    private func movePanel(key: String, by direction: Int) {
        guard canMovePanel(key: key, by: direction),
              let vi = visibleProviders.firstIndex(where: { $0.key == key }) else { return }
        let neighbourKey = visibleProviders[vi + direction].key
        withAnimation(.easeInOut(duration: 0.18)) {
            reorder(droppedKey: key, targetKey: neighbourKey)
        }
    }

    private func reorder(droppedKey: String, targetKey: String) {
        guard droppedKey != targetKey else { return }
        var keys = orderedProviders.map(\.key)
        guard let fromIdx = keys.firstIndex(of: droppedKey),
              let toIdx = keys.firstIndex(of: targetKey),
              fromIdx != toIdx else { return }

        let item = keys.remove(at: fromIdx)
        keys.insert(item, at: toIdx)
        providerOrderRaw = keys.joined(separator: ",")
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !attachedImages.isEmpty {
                imagePreviewRow()
            }
            // The @-mention list sits ABOVE the field — the composer lives at the bottom of the
            // window, so the list opens upward like a menu that has room to grow.
            if pickerVisible {
                MentionPicker(options: pickerOptions, selected: $pickerIndex,
                              favicons: store.favicons) { acceptMention($0) }
            }

            HStack(alignment: .center, spacing: 10) {
                composerMenu
                summarizeButton
                layoutButton

                if let t = directedTarget {
                    DirectedChip(target: t) { directedTarget = nil }
                }

                // Vertical-axis TextField re-measures the WHOLE text on every keystroke — fine for
                // normal prompts, but typing after pasting a long article lagged badly. Above a
                // threshold, swap in an NSTextView-backed TextEditor (fast on large text); the
                // Enter/⌘V/history key monitor works unchanged (NSTextView is an NSText).
                if prompt.count > 1500 {
                    TextEditor(text: $prompt)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 44, maxHeight: 150)
                        .focused($promptFocused)
                        .onAppear { if !promptFocused { promptFocused = true } }
                } else {
                    TextField(composerPlaceholder, text: $prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($promptFocused)
                        .lineLimit(1...8)
                }

                Button {
                    if dictator.isRecording {
                        dictator.stop()
                        DictationCoordinator.shared.ended(dictator)
                    } else {
                        DictationCoordinator.shared.begin(dictator)   // stops any other active mic
                        dictationBase = prompt.isEmpty ? "" : prompt + " "
                        dictator.start { text in prompt = dictationBase + text }
                    }
                } label: {
                    InkMicGlyph(recording: dictator.isRecording)
                        .frame(width: 17, height: 17)
                        .opacity(dictator.isRecording ? (micPulse ? 0.45 : 1.0) : 1.0)
                        .animation(dictator.isRecording
                                   ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                                   : .default, value: micPulse)
                        .frame(width: 32, height: 26)
                        .inkChip(orange: dictator.isRecording)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(dictator.permissionDenied ? L("quick.micDenied")
                      : (dictator.isRecording ? L("quick.micStop") : L("quick.mic")))
                .onChange(of: dictator.isRecording) { micPulse = $0 }

                Button {
                    send()
                } label: {
                    InkSendButtonLabel(enabled: canSend, size: 30)   // the film's orange send disc
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .help(L("composer.sendHelp"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: ChorusTheme.cardRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChorusTheme.cardRadius, style: .continuous)
                .strokeBorder(ChorusTheme.cardBorder(colorScheme), lineWidth: 1)
        )
        .shadow(color: ChorusTheme.cardShadow(colorScheme).color,
                radius: ChorusTheme.cardShadow(colorScheme).radius,
                x: 0, y: ChorusTheme.cardShadow(colorScheme).y)
        .onChange(of: prompt) { handlePromptChange($0) }
        .onAppear {
            promptFocused = true
            installPasteMonitor()
        }
        .onDisappear {
            removePasteMonitor()
        }
    }

    // MARK: @-mention picker + chip

    private var pickerVisible: Bool { DirectedPrompt.pendingMention(in: prompt) != nil }

    private var composerPlaceholder: String {
        if minimalMode { return "" }
        if let t = directedTarget { return Lf("composer.placeholderDirected", t.name) }
        return L("composer.placeholder")
    }

    /// Keep the picker in step with the text, and turn "@name " typed straight through into the
    /// chip the moment the space lands (the picker is for discovery; fast typists never open it).
    private func handlePromptChange(_ new: String) {
        if let token = DirectedPrompt.completedMention(previous: lastPrompt, current: new),
           let t = DirectedPrompt.target(for: token, in: store.directedCandidates()) {
            acceptMention(t)
            return
        }
        lastPrompt = new
        if let q = DirectedPrompt.pendingMention(in: new) {
            let opts = DirectedPrompt.options(store.directedCandidates(), query: q)
            if opts != pickerOptions { pickerIndex = 0 }
            pickerOptions = opts
        } else {
            pickerOptions = []
        }
    }

    private func acceptMention(_ t: DirectedPrompt.Target) {
        directedTarget = t
        prompt = ""
        lastPrompt = ""
        pickerOptions = []
        pickerIndex = 0
    }

    private func acceptHighlightedMention() {
        guard !pickerOptions.isEmpty else { return }
        acceptMention(pickerOptions[min(pickerIndex, pickerOptions.count - 1)])
    }

    /// How many AIs to show at once, ChatHub-style: one click goes from three panels to six,
    /// and the arrangement follows the count (4 → 2x2, 6 → 3x2). This is a COUNT picker, not a
    /// rearrangement — re-flowing the same three panels into different rows changes nothing
    /// useful; what the user wants is "put more AIs on screen, now".
    /// Panels are taken from the top of their existing order, so the choice is predictable.
    private static let layoutPresets: [(count: Int, columns: Int, rows: Int)] = [
        (1, 1, 1),
        (2, 2, 1),
        (3, 3, 1),
        (4, 2, 2),
        (6, 3, 2),
    ]

    private var layoutButton: some View {
        let available = orderedProviders.count + apiProviders.count
        let current = Self.layoutPresets.last { min($0.count, available) == visiblePanels.count
            && $0.columns == panelColumns }
        return Button {
            showLayoutPicker.toggle()
        } label: {
            LayoutGlyph(cols: current?.columns ?? panelColumns, rows: current?.rows ?? 1, lineWidth: 1.5)
                .foregroundColor(Ink.line(colorScheme))
                .frame(width: 32, height: 26)
                .inkChip()
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L("layout.help"))
        // One glyph in the composer strip; the five-way progression appears only when asked for.
        // Five icons inline read as clutter next to the other controls — ChatHub can afford the
        // full row because it lives in a roomy sidebar card, this bar can't.
        .popover(isPresented: $showLayoutPicker, arrowEdge: .top) {
            // No caption, no numbers: the glyphs already ARE the answer (one pane, two, three,
            // 2x2, 3x2). Labelling a self-evident picture is just noise; hover tooltips cover
            // the rare "wait, how many is that?".
            HStack(spacing: 6) {
                ForEach(Self.layoutPresets, id: \.count) { preset in
                    let reachable = min(preset.count, available)
                    let isCurrent = visiblePanels.count == reachable && panelColumns == preset.columns
                    Button {
                        applyLayoutPreset(count: preset.count, columns: preset.columns)
                        showLayoutPicker = false
                    } label: {
                        LayoutGlyph(cols: preset.columns, rows: preset.rows, side: 17)
                            .frame(width: 34, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(isCurrent ? Color.primary.opacity(0.10) : .clear)
                            )
                            .foregroundColor(isCurrent ? .primary : .secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(preset.count > available)
                    .help(Lf("layout.showN", preset.count))
                }
            }
            .padding(10)
        }
    }

    /// Show the first `count` panels in order, hide the rest, and set the row width to match.
    private func applyLayoutPreset(count: Int, columns: Int) {
        let webKeys = orderedProviders.map(\.key)
        let apiKeys = apiProviders.map(\.id)
        let all = webKeys + apiKeys
        let keep = Set(all.prefix(count))
        let hidden = all.filter { !keep.contains($0) }
        // Web panels this preset hides that were showing until now. They need the same deferred
        // teardown the ✕ button schedules — this path used to skip it, leaving every panel the
        // picker hid running invisibly at full tilt.
        let newlyHiddenWeb = hidden.filter { webKeys.contains($0) && !hiddenKeys.contains($0) }

        // Widening/adding panels makes WebKit repaint the newly exposed area white; raise the
        // cream cover across the change like the hide/show reflow does.
        reflowing = true
        panelColumns = columns
        MemoryHeartbeat.shared.note("layout count=\(count) columns=\(columns)")
        DispatchQueue.main.async {
            hiddenProvidersRaw = hidden.sorted().joined(separator: ",")
            for key in newlyHiddenWeb { store.scheduleTeardownIfStillHidden(key: key) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { reflowing = false }
        }
    }

    /// "Summarize all answers" — a one-click composer button (was buried in the … menu). Click
    /// the sparkles → pick which API model synthesizes the comparison.
    private var summarizeButton: some View {
        Menu {
            if apiProviders.isEmpty {
                Text(L("summary.needAPI"))
                Button(L("summary.openSettings")) { openSettings() }
            } else {
                Section(L("summary.pickModel")) {
                    ForEach(apiProviders) { p in
                        Button(Lf("summary.useModel", p.name)) { summarizeAnswers(using: p) }
                    }
                }
            }
        } label: {
            // An AppKit-rendered menu label keeps only an image and a string, so the sparkle is a
            // pre-drawn image and the chip's capsule is drawn around the menu, not inside it.
            HStack(spacing: 5) {
                Image(nsImage: InkImages.sparkle)
                if !minimalMode {
                    Text(L("summary.button")).font(.chorus(12, .semibold))
                }
            }
            .foregroundColor(ChorusTheme.brandOrange)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(ChorusTheme.brandOrange)   // an AppKit menu label takes its colour from the tint
        .fixedSize()
        .padding(.horizontal, minimalMode ? 9 : 10)
        .frame(minWidth: 32)
        .frame(height: 26)
        .inkChip(orange: true)
        .contentShape(Capsule())
        .help(L("summary.help"))
    }

    /// Global actions tucked into the composer's left edge (ChatGPT-style). Keeps the title
    /// bar clean: new chat / reload all, per-panel show-hide, settings — all one click away.
    private var composerMenu: some View {
        Menu {
            Button {
                for p in visibleProviders { store.newChat(key: p.key) }
                for p in visibleAPIProviders { apiStore.newChat(p.id) }
            } label: { Label(L("menu.newChat"), systemImage: "square.and.pencil") }

            Button {
                for p in visibleProviders { store.reload(key: p.key) }
            } label: { Label(L("menu.reloadAll"), systemImage: "arrow.clockwise") }

            Button {
                generateShareCard()
            } label: { Label(L("menu.shareCard"), systemImage: "photo") }

            Button {
                showStats = true
            } label: { Label(L("stats.title"), systemImage: "chart.bar") }

            Divider()

            Section(L("menu.panels")) {
                ForEach(allProviders) { p in
                    let isVisible = !hiddenKeys.contains(p.key)
                    let isLastVisible = isVisible && visibleProviders.count == 1
                    // A Toggle, not a Button with a checkmark Label: AppKit then draws the tick in
                    // the menu's own state column, which EVERY row reserves — so the names line
                    // up. (An icon-label only exists on the checked rows and shoved them right.)
                    Toggle(p.name, isOn: Binding(get: { isVisible }, set: { _ in toggleHidden(p.key) }))
                        .disabled(isLastVisible)
                }
            }

            // Native API panels live under their own header, so they read as a distinct group
            // (and a web panel with a similar name isn't confusing) — no per-item suffix needed.
            if !apiProviders.isEmpty {
                Section(L("settings.section.apiModels")) {
                    ForEach(apiProviders) { p in
                        let isVisible = !hiddenKeys.contains(p.id)
                        Toggle(p.name, isOn: Binding(get: { isVisible }, set: { _ in toggleHiddenAPI(p.id) }))
                    }
                }
            }

            Divider()

            if #available(macOS 14.0, *) {
                SettingsLink {
                    Label(L("menu.settings"), systemImage: "gearshape")
                }
            } else {
                Button {
                    openSettings()
                } label: { Label(L("menu.settings"), systemImage: "gearshape") }
            }
        } label: {
            Image(nsImage: InkImages.dots)   // AppKit draws menu labels: an image, not a view
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 32, height: 26)
        .inkChip()
        .contentShape(Capsule())
        .help(L("menu.actions"))
    }

    private func imagePreviewRow() -> some View {
        HStack(spacing: 8) {
            ForEach(attachedImages) { item in
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: item.image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 52, height: 52)
                        .clipped()
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.white.opacity(0.12))
                        )
                    Button {
                        attachedImages.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                            .background(Circle().fill(.background))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .help(L("composer.removeImage"))
                }
            }
            Spacer()
        }
    }

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedImages.isEmpty
    }

    /// Local NSEvent monitor that handles two things when our prompt field has focus:
    ///   • ⌘+V with an image on the clipboard → capture into `attachedImage`
    ///   • Plain Enter (no modifiers) → force-insert a newline at the cursor (TextField
    ///     with axis: .vertical *should* do this natively but is unreliable in some
    ///     macOS / Xcode versions, so we explicitly handle it.)
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only act when our prompt field has focus — and never while a panel-type window
            // (a sign-in popup, the quick input) is key: a stale focus flag there would make
            // this monitor swallow Return inside a password field.
            guard promptFocused, !(NSApp.keyWindow is NSPanel) else { return event }

            // The @-mention picker owns ↑↓ / ↩ / ⇥ / ⎋ while it is showing — unless an input
            // method is mid-composition, which must keep its keys (arrows move candidates,
            // Enter commits).
            let composing = (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
            if !composing, DirectedPrompt.pendingMention(in: prompt) != nil {
                switch event.keyCode {
                case 126: Task { @MainActor in self.pickerIndex = max(0, self.pickerIndex - 1) }; return nil
                case 125: Task { @MainActor in self.pickerIndex = min(max(0, self.pickerOptions.count - 1), self.pickerIndex + 1) }; return nil
                case 36, 48: Task { @MainActor in self.acceptHighlightedMention() }; return nil   // ↩ / ⇥
                case 53: Task { @MainActor in self.prompt = "" }; return nil                      // ⎋ drops the half-typed mention
                default: break
                }
            }
            // Backspace with a mention chip and nothing typed → remove the chip (same rule the
            // quick input applies to an attached image).
            if event.keyCode == 51, prompt.isEmpty, directedTarget != nil {
                Task { @MainActor in self.directedTarget = nil }
                return nil
            }

            // Prompt history recall: ↑ at text start, ↓ at text end (otherwise move the caret).
            if event.keyCode == 126 {  // up arrow → older
                guard caretAtTextStart(),
                      let r = promptHistoryStep(direction: -1, current: prompt, index: historyIndex, draft: historyDraft)
                else { return event }
                Task { @MainActor in
                    self.prompt = r.prompt; self.historyIndex = r.index; self.historyDraft = r.draft
                    moveCaretToTextEnd()
                }
                return nil
            }
            if event.keyCode == 125 {  // down arrow → newer
                guard historyIndex != nil, caretAtTextEnd(),
                      let r = promptHistoryStep(direction: 1, current: prompt, index: historyIndex, draft: historyDraft)
                else { return event }
                Task { @MainActor in
                    self.prompt = r.prompt; self.historyIndex = r.index; self.historyDraft = r.draft
                    moveCaretToTextEnd()
                }
                return nil
            }
            // Any other key exits history browsing.
            if historyIndex != nil { Task { @MainActor in self.historyIndex = nil } }

            let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])

            // Plain Enter (keyCode 36 = Return). No modifiers → insert newline.
            // ⇧+Enter (Shift only) likewise inserts newline (common chat-app behavior).
            // ⌘+Enter is left for the Send button's keyboardShortcut to handle.
            if event.keyCode == 36 && (mods.isEmpty || mods == .shift) {
                // CRITICAL: if an IME composition is active (Chinese/Japanese/Korean input
                // showing a candidate window), pass Enter through so the IME can commit the
                // candidate. Only treat Enter as "newline" when there's no marked text.
                if let inputClient = NSApp.keyWindow?.firstResponder as? NSTextInputClient,
                   inputClient.hasMarkedText() {
                    return event
                }

                // Insert via the field editor so the cursor position is respected
                if let textView = NSApp.keyWindow?.firstResponder as? NSText {
                    textView.insertText("\n")
                } else {
                    Task { @MainActor in self.prompt += "\n" }
                }
                return nil // consume — TextField won't see this
            }

            // ⌘+V → image paste detection
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "v" {
                let pb = NSPasteboard.general
                if let img = NSImage(pasteboard: pb), img.size.width > 0, img.size.height > 0 {
                    Task { @MainActor in self.attachedImages.append(AttachedImage(image: img)) }
                    let hasText = pb.canReadObject(forClasses: [NSString.self], options: nil)
                    return hasText ? event : nil
                }
            }
            return event
        }
    }

    private func removePasteMonitor() {
        if let token = pasteMonitor {
            NSEvent.removeMonitor(token)
            pasteMonitor = nil
        }
    }

    private func send() {
        dictator.stop()  // end any in-progress dictation
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // ⌘↩ while the mention picker is up means "pick this one", not "send '@ge' to everyone".
        if DirectedPrompt.pendingMention(in: text) != nil, !pickerOptions.isEmpty {
            acceptHighlightedMention()
            return
        }
        guard canSend else { return }
        let directed: (targets: Set<String>?, text: String)
        if let t = directedTarget { directed = (t.ids, text) } else { directed = store.resolveDirectedPrompt(text) }
        store.broadcast(text: directed.text, images: attachedImages.map(\.image), source: .mainWindow,
                        targets: directed.targets)
        PromptHistory.add(text)
        historyIndex = nil
        prompt = ""
        attachedImages = []
        directedTarget = nil
    }
}

