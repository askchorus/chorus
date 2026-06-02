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

    /// Provider keys currently streaming a response — drives the per-panel "thinking" dot.
    @Published private(set) var streamingKeys: Set<String> = []

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
        // Record the conversation URL whenever it changes. `didFinish` only fires on full
        // navigations, so in-app conversation switches done as SPA history.pushState (Gemini,
        // Claude, ChatGPT) were never captured — the saved session stayed on the initial page
        // and "reopen last chat" landed on a new chat. KVO on `.url` sees pushState too.
        urlObservers[key] = webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            self?.recordSessionURL(for: wv)
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

    /// Live-checks whether ANY of `keys` still shows a stop button — i.e. is still generating
    /// or thinking right now. Async; `completion` runs on the main actor. Ground truth (queries
    /// the live DOM), used by the completion safety net so it won't declare "done" mid-thought.
    func anyBusy(_ keys: Set<String>, completion: @escaping (Bool) -> Void) {
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
        webView.load(URLRequest(url: url))
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
    func broadcast(text: String, image: NSImage? = nil, source: BroadcastSource = .mainWindow) {
        var imageBase64: String? = nil
        var pngData: Data? = nil
        if let image = image,
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            pngData = png
            imageBase64 = png.base64EncodedString()
        }

        // Build the "wait for" set for the completion notification:
        // (visible) ∩ (user-marked-required). Hidden providers and "best effort"
        // providers (e.g. Gemini if user unchecked it) still receive the broadcast
        // but their completion doesn't block the notification.
        let hiddenRaw = UserDefaults.standard.string(forKey: "hiddenProviders") ?? ""
        let hiddenKeys = Set(hiddenRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
        let visibleKeys = Set(cache.keys).subtracting(hiddenKeys)

        let requiredRaw = UserDefaults.standard.string(forKey: "notifyRequiredProviders") ?? "chatgpt,claude,gemini"
        let requiredKeys = Set(requiredRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
        let trackKeys = visibleKeys.intersection(requiredKeys)

        if !trackKeys.isEmpty {
            let batchID = UUID()
            pendingBatches[batchID] = PendingBatch(
                pendingKeys: trackKeys,
                source: source,
                totalCount: trackKeys.count,
                lastActivityAt: Date()
            )
            clog("batch \(batchID.uuidString.prefix(8)) created — source=\(source), waiting on \(trackKeys) (visible=\(visibleKeys), required=\(requiredKeys))")
            scheduleBatchFallback(batchID: batchID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
                self?.pendingBatches.removeValue(forKey: batchID)
            }
        } else {
            clog("broadcast skipped completion tracking — no providers to wait for (visible=\(visibleKeys), required=\(requiredKeys))")
        }

        let jsWithImage = Broadcaster.injectionScript(text: text, imageBase64: imageBase64)
        // Gemini send script: attaches no image itself, but waits for the panel-uploaded
        // image to finish appearing before typing + sending.
        let jsGeminiSend = Broadcaster.injectionScript(text: text, imageBase64: nil, waitForGeminiUpload: true)
        for (key, webView) in cache {
            // Don't broadcast to hidden panels — hiding a panel excludes it from sends.
            if hiddenKeys.contains(key) { continue }

            // Gemini blocks synthetic JS image attachment: it renders no static <input type=file>
            // and ignores synthetic paste/drop (isTrusted=false). Instead we intercept its
            // file-open panel: arm runOpenPanel with a temp image file, then drive Gemini's
            // "Upload files" menu so WebKit calls the panel — which we answer silently.
            if key == "gemini", let png = pngData {
                geminiUploadViaPanel(into: webView, pngData: png, thenRun: jsGeminiSend)
                continue
            }
            webView.evaluateJavaScript(jsWithImage) { result, error in
                if let error = error {
                    print("[\(key)] error: \(error.localizedDescription)")
                }
            }
        }

        // Fan out to the native API model panels too (with the image, for vision models). Hidden
        // ones are skipped, mirroring the web panels.
        let apiPrompt = text
        let apiImage = imageBase64
        let skip = hiddenKeys
        Task { @MainActor in
            for p in APIProviderRegistry.all() where !skip.contains(p.id) {
                APIChatStore.shared.send(to: p, prompt: apiPrompt, imageBase64: apiImage)
            }
        }
    }

    /// Feed an image into Gemini via file-open-panel interception (the native equivalent of
    /// Playwright's fileChooser handling). Steps: write the image to a temp file, arm the
    /// runOpenPanel auto-answer, then drive Gemini's "Upload files" menu. When Gemini fires
    /// its lazy <input type=file>, WebKit calls our delegate, which returns the file silently
    /// (no dialog). Finally set the text and send.
    private func geminiUploadViaPanel(into webView: WKWebView, pngData: Data, thenRun js: String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-upload-\(UUID().uuidString).png")
        do {
            try pngData.write(to: tmp)
        } catch {
            chorusLog.notice("[Chorus.Gemini] temp file write failed: \(error.localizedDescription, privacy: .public)")
            webView.evaluateJavaScript(js) { _, _ in }  // still send the text
            return
        }

        // Arm the open-panel auto-answer (single-shot, consumed by runOpenPanel).
        LinkRoutingDelegate.shared.pendingUpload = tmp
        chorusLog.notice("[Chorus.Gemini] armed pendingUpload=\(tmp.lastPathComponent, privacy: .public)")

        // Bring Chorus forward — some user-activation-gated paths only fire for the active app.
        NSApp.activate(ignoringOtherApps: true)

        // Delay so ChatGPT/Claude finish their synthetic paste before we churn Gemini's UI.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            webView.evaluateJavaScript(Broadcaster.geminiUploadTriggerScript()) { result, _ in
                chorusLog.notice("[Chorus.Gemini] upload trigger result=\(String(describing: result), privacy: .public)")
                // The send script polls for the uploaded thumbnail itself (WAIT_UPLOAD), so we
                // only need a short gap before kicking it off — it does the waiting internally.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    webView.evaluateJavaScript(js) { _, _ in }
                }
            }
        }

        // Safety: if the menu nav never triggers the panel, don't leave a stale armed upload
        // that would hijack the user's next manual file pick. Clear it after 10s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if LinkRoutingDelegate.shared.pendingUpload == tmp {
                LinkRoutingDelegate.shared.pendingUpload = nil
                chorusLog.notice("[Chorus.Gemini] cleared stale pendingUpload (panel never fired)")
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
                clog("batch \(batchID.uuidString.prefix(8)) fallback-fired — undetected completion for \(batch.pendingKeys)")
                CompletionNotifier.shared.handleBatchComplete(source: batch.source)
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

    /// Drop a webview (used when a custom provider is removed) so it stops consuming memory.
    func removeWebView(key: String) {
        cache[key]?.removeFromSuperview()
        cache[key] = nil
        streamingKeys.remove(key)
        favicons.removeValue(forKey: key)
    }
}

struct Provider: Identifiable {
    let key: String
    let name: String
    let url: URL
    var isBuiltIn: Bool = false
    var id: String { key }
}

/// Codable form for persisting user-added providers in UserDefaults.
private struct ProviderDTO: Codable {
    let key: String
    let name: String
    let url: String
}

/// Single source of truth for the AI panels: three tuned built-ins plus any the user adds.
/// Built-ins have hand-tuned input/send/upload selectors; custom ones broadcast text via a
/// generic strategy (contenteditable/textarea + Send button or Enter).
enum ProviderRegistry {
    static let customKey = "customProviders"

    static let builtIn: [Provider] = [
        Provider(key: "chatgpt", name: "ChatGPT", url: URL(string: "https://chatgpt.com/")!,        isBuiltIn: true),
        Provider(key: "claude",  name: "Claude",  url: URL(string: "https://claude.ai/")!,          isBuiltIn: true),
        Provider(key: "gemini",  name: "Gemini",  url: URL(string: "https://gemini.google.com/")!,  isBuiltIn: true),
    ]

    /// Real, ready-to-add AIs surfaced as one-click "Quick add" chips in Settings, so the
    /// user doesn't have to look up URLs. (They still log in once inside the new panel.)
    static let presets: [(name: String, url: String)] = [
        ("DeepSeek",    "https://chat.deepseek.com/"),
        ("Kimi",        "https://www.kimi.com/"),
        ("Grok",        "https://grok.com/"),
        ("Perplexity",  "https://www.perplexity.ai/"),
        ("千问",         "https://www.tongyi.com/"),
        ("豆包",         "https://www.doubao.com/chat/"),
        ("腾讯元宝",     "https://yuanbao.tencent.com/"),
        ("Le Chat",     "https://chat.mistral.ai/"),
        ("Manus",       "https://manus.im/"),
        ("Genspark",    "https://www.genspark.ai/"),
        ("MiniMax",     "https://chat.minimaxi.com/"),
        ("GLM",         "https://chat.z.ai/"),
    ]

    static func decode(_ raw: String) -> [Provider] {
        guard let data = raw.data(using: .utf8),
              let dtos = try? JSONDecoder().decode([ProviderDTO].self, from: data) else { return [] }
        return dtos.compactMap { dto in
            guard let url = URL(string: dto.url) else { return nil }
            return Provider(key: dto.key, name: dto.name, url: url, isBuiltIn: false)
        }
    }

    static func custom() -> [Provider] {
        decode(UserDefaults.standard.string(forKey: customKey) ?? "")
    }

    static func all() -> [Provider] { builtIn + custom() }

    private static func saveCustom(_ providers: [Provider]) {
        let dtos = providers.map { ProviderDTO(key: $0.key, name: $0.name, url: $0.url.absoluteString) }
        guard let data = try? JSONEncoder().encode(dtos),
              let s = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(s, forKey: customKey)
    }

    /// Add a custom provider from a name + URL string. Returns false if the URL is unusable.
    @discardableResult
    static func addCustom(name: String, urlString: String) -> Bool {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return false }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? host : trimmedName
        // Stable unique key from the host.
        let base = host.replacingOccurrences(of: ".", with: "_")
        let existing = Set(all().map(\.key))
        var key = "x_" + base
        var n = 2
        while existing.contains(key) { key = "x_\(base)_\(n)"; n += 1 }
        var list = custom()
        list.append(Provider(key: key, name: displayName, url: url, isBuiltIn: false))
        saveCustom(list)
        return true
    }

    static func removeCustom(key: String) {
        saveCustom(custom().filter { $0.key != key })
    }
}

/// Shared visual tokens for the Arc-style main window: floating webview "cards" on a soft
/// neutral canvas, generous rounding, consistent spacing.
enum ChorusTheme {
    static let cardRadius: CGFloat = 12
    static let gap: CGFloat = 12
    static let margin: CGFloat = 14

    static func cardBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.10)
    }

    static func canvas(_ scheme: ColorScheme) -> LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [Color(red: 0.13, green: 0.13, blue: 0.145),
                         Color(red: 0.08, green: 0.08, blue: 0.09)],
                startPoint: .top, endPoint: .bottom)
        } else {
            // Warm cream "paper" — matches the icon's vibe, not a cold gray.
            return LinearGradient(
                colors: [Color(red: 0.965, green: 0.945, blue: 0.905),
                         Color(red: 0.925, green: 0.895, blue: 0.840)],
                startPoint: .top, endPoint: .bottom)
        }
    }

    /// NSColor that adapts to the effective appearance — used for the window background so
    /// it matches the canvas during resize / behind the content.
    static var windowBackground: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
                        : NSColor(red: 0.95, green: 0.93, blue: 0.89, alpha: 1)   // warm cream
        }
    }

    /// A CONCRETE color for the window background, resolved against the *app's* current
    /// (possibly forced) appearance — NOT the dynamic color's `.cgColor`, which resolves
    /// against the *system* appearance and would pick the dark branch when the system is in
    /// dark mode even though Chorus is forced light. Used for webview backdrops where a
    /// dynamic NSColor isn't reliably resolved (WebKit's `underPageBackgroundColor`, CALayer
    /// backgroundColor).
    static func windowBackgroundColor() -> NSColor {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
                    : NSColor(red: 0.95, green: 0.93, blue: 0.89, alpha: 1)
    }
    static func windowBackgroundCGColor() -> CGColor { windowBackgroundColor().cgColor }

    /// Card / composer drop shadow — soft & warm-light in light mode (paper lift), deeper in dark.
    static func cardShadow(_ scheme: ColorScheme) -> (color: Color, radius: CGFloat, y: CGFloat) {
        scheme == .dark ? (Color.black.opacity(0.30), 9, 3)
                        : (Color(red: 0.4, green: 0.34, blue: 0.24).opacity(0.16), 10, 4)
    }
}

/// Applies the user's appearance choice (System / Light / Dark) to the whole app. Setting
/// NSApp.appearance also changes what `prefers-color-scheme` WKWebViews report, so sites that
/// follow the system theme switch along with our chrome.
enum AppearanceManager {
    static func apply(_ raw: String) {
        switch raw {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil   // follow system
        }
    }
}

/// Per-provider brand accent color. Known AIs get their real brand color; custom providers
/// get a stable color derived from their host so each still reads as distinct.
enum ProviderStyle {
    static func accent(key: String, host: String) -> Color {
        switch key {
        case "chatgpt": return Color(red: 0.125, green: 0.129, blue: 0.137)  // #202123 OpenAI near-black (matches the current monochrome logo; the old #10A37F green is retired)
        case "claude":  return Color(red: 0.800, green: 0.471, blue: 0.361)  // #CC785C Anthropic clay
        case "gemini":  return Color(red: 0.259, green: 0.522, blue: 0.957)  // #4285F4 Google blue
        default:
            // Stable hash → hue (String.hashValue is randomized per launch, so roll our own).
            var h = 5381
            for u in host.unicodeScalars { h = (h &* 33) &+ Int(u.value) }
            let hue = Double(abs(h) % 360) / 360.0
            return Color(hue: hue, saturation: 0.55, brightness: 0.85)
        }
    }
}

/// Thin brand-color bar across the top of a card. Pulses while that AI is streaming.
struct AccentBar: View {
    let color: Color
    let active: Bool
    @State private var pulse = false

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 2)
            .opacity(active ? (pulse ? 0.3 : 1.0) : 0.85)
            .animation(active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                       value: pulse)
            .onAppear { pulse = active }
            .onChange(of: active) { newValue in pulse = newValue }
    }
}

/// Makes the host NSWindow draggable from any background area and keeps the title bar
/// transparent — needed for the immersive, hidden-title-bar look.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.isMovableByWindowBackground = true
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.backgroundColor = ChorusTheme.windowBackground
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject private var store: WebViewStore
    @ObservedObject private var apiStore = APIChatStore.shared   // native API model panels
    @State private var prompt: String = ""
    @State private var attachedImage: NSImage? = nil
    @FocusState private var promptFocused: Bool

    // Voice input (on-device dictation) for the main composer.
    @StateObject private var dictator = SpeechDictator()
    @State private var dictationBase = ""
    @State private var micPulse = false

    // Drives the per-panel native cream cover during a removal reflow (masks WKWebView's white
    // repaint-on-resize). Raised proactively in toggleHidden, before the reflow.
    @State private var reflowing = false

    @AppStorage("providerOrder") private var providerOrderRaw: String = "chatgpt,claude,gemini"
    @AppStorage("hiddenProviders") private var hiddenProvidersRaw: String = ""
    @AppStorage("customProviders") private var customProvidersRaw: String = ""
    @AppStorage("appLanguage") private var appLanguage: String = "system"  // re-render on language switch
    @AppStorage("appearance") private var appearance: String = "light"
    @AppStorage("minimalMode") private var minimalMode: Bool = false
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
            // Don't allow hiding if it would leave 0 visible panels
            let remainingVisible = orderedProviders.count - keys.count - 1
            guard remainingVisible >= 1 else { return }
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
            HStack(spacing: ChorusTheme.gap) {
                ForEach(visibleProviders) { p in
                    card(for: p)
                        .frame(minWidth: 300, maxWidth: .infinity)
                }
                // Native API model panels, after the web cards.
                ForEach(visibleAPIProviders) { p in
                    apiCard(for: p)
                        .frame(minWidth: 300, maxWidth: .infinity)
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
            // Pre-create all webviews up-front so their lifecycle is independent of view rebuilds.
            for p in allProviders {
                _ = store.getOrCreate(key: p.key, url: p.url)
            }
        }
        .onChange(of: appearance) { newValue in
            AppearanceManager.apply(newValue)
        }
    }

    /// Minimal immersive top strip — just reserves the traffic-light row so the cards don't
    /// slide under the window controls. All global actions now live in the composer's menu.
    private var topBar: some View {
        Color.clear.frame(height: 28)
    }

    private func openSettings() {
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    private func card(for p: Provider) -> some View {
        VStack(spacing: 0) {
            AccentBar(color: ProviderStyle.accent(key: p.key, host: p.url.host ?? ""),
                      active: store.streamingKeys.contains(p.key))
            slimHeader(for: p)
            WebPanel(webView: store.getOrCreate(key: p.key, url: p.url), reflowing: reflowing)
        }
        .clipShape(RoundedRectangle(cornerRadius: ChorusTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ChorusTheme.cardRadius, style: .continuous)
                .strokeBorder(
                    dropTargetKey == p.key ? Color.accentColor.opacity(0.8) : ChorusTheme.cardBorder(colorScheme),
                    lineWidth: dropTargetKey == p.key ? 2 : 1
                )
        )
        .shadow(color: ChorusTheme.cardShadow(colorScheme).color,
                radius: ChorusTheme.cardShadow(colorScheme).radius,
                x: 0, y: ChorusTheme.cardShadow(colorScheme).y)
    }

    /// A native API model card — same chrome as a web card, but a native chat transcript instead
    /// of a WKWebView.
    private func apiCard(for p: APIProvider) -> some View {
        VStack(spacing: 0) {
            AccentBar(color: ProviderStyle.accent(key: p.id, host: ""),
                      active: apiStore.isStreaming(p.id))
            apiSlimHeader(for: p)
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
    private func apiSlimHeader(for p: APIProvider) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(ProviderStyle.accent(key: p.id, host: ""))
                .frame(width: 8, height: 8)
            Text(p.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary.opacity(0.9))
            // Marks this as a native API panel — disambiguates from a web panel of the same name.
            Text("API")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            if !p.model.isEmpty {
                Text(p.model)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if apiStore.isStreaming(p.id) {
                Button { apiStore.stop(p.id) } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("api.stop"))
            }
            if hoveredHeaderKey == p.id {
                Button { apiStore.newChat(p.id) } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("menu.newChat"))
                .transition(.opacity)
            }
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
    private func slimHeader(for p: Provider) -> some View {
        HStack(spacing: 7) {
            if let icon = store.favicons[p.key] {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 15, height: 15)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                // No favicon yet — fall back to a brand-color dot.
                Circle()
                    .fill(ProviderStyle.accent(key: p.key, host: p.url.host ?? ""))
                    .frame(width: 8, height: 8)
            }
            Text(p.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary.opacity(0.9))
            Spacer()
            if hoveredHeaderKey == p.key {
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
                    Rectangle().fill(Color.accentColor.opacity(0.25))
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
            .background(Color.accentColor)
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
            if let image = attachedImage {
                imagePreviewRow(image)
            }

            HStack(alignment: .center, spacing: 10) {
                composerMenu

                TextField(minimalMode ? "" : L("composer.placeholder"),
                          text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($promptFocused)
                    .lineLimit(1...8)

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
                    Image(systemName: dictator.isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 15))
                        .foregroundColor(dictator.isRecording ? .accentColor : .secondary)
                        .opacity(dictator.isRecording ? (micPulse ? 0.45 : 1.0) : 1.0)
                        .animation(dictator.isRecording
                                   ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                                   : .default, value: micPulse)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(dictator.permissionDenied ? L("quick.micDenied")
                      : (dictator.isRecording ? L("quick.micStop") : L("quick.mic")))
                .onChange(of: dictator.isRecording) { micPulse = $0 }

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle().fill(canSend ? Color.accentColor : Color.secondary.opacity(0.3))
                        )
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
        .onAppear {
            promptFocused = true
            installPasteMonitor()
        }
        .onDisappear {
            removePasteMonitor()
        }
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

            Divider()

            Section(L("menu.panels")) {
                ForEach(allProviders) { p in
                    let isVisible = !hiddenKeys.contains(p.key)
                    let isLastVisible = isVisible && visibleProviders.count == 1
                    Button {
                        toggleHidden(p.key)
                    } label: {
                        if isVisible {
                            Label(p.name, systemImage: "checkmark")
                        } else {
                            Text(p.name)
                        }
                    }
                    .disabled(isLastVisible)
                }
            }

            // Native API panels live under their own header, so they read as a distinct group
            // (and a web panel with a similar name isn't confusing) — no per-item suffix needed.
            if !apiProviders.isEmpty {
                Section(L("settings.section.apiModels")) {
                    ForEach(apiProviders) { p in
                        let isVisible = !hiddenKeys.contains(p.id)
                        Button {
                            toggleHiddenAPI(p.id)
                        } label: {
                            if isVisible {
                                Label(p.name, systemImage: "checkmark")
                            } else {
                                Text(p.name)
                            }
                        }
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
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("menu.actions"))
    }

    private func imagePreviewRow(_ image: NSImage) -> some View {
        HStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: image)
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
                    attachedImage = nil
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
            Text(L("composer.imageAttached"))
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedImage != nil
    }

    /// Local NSEvent monitor that handles two things when our prompt field has focus:
    ///   • ⌘+V with an image on the clipboard → capture into `attachedImage`
    ///   • Plain Enter (no modifiers) → force-insert a newline at the cursor (TextField
    ///     with axis: .vertical *should* do this natively but is unreliable in some
    ///     macOS / Xcode versions, so we explicitly handle it.)
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only act when our prompt field has focus
            guard promptFocused else { return event }

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
                    Task { @MainActor in self.attachedImage = img }
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
        guard canSend else { return }
        store.broadcast(text: text, image: attachedImage, source: .mainWindow)
        PromptHistory.add(text)
        historyIndex = nil
        prompt = ""
        attachedImage = nil
    }
}
