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

    /// Provider keys currently streaming a response — drives the per-panel "thinking" dot.
    @Published private(set) var streamingKeys: Set<String> = []

    /// Pending completion batches — one per broadcast. Each tracks which provider keys
    /// have not yet posted their completion message. When a batch's set empties → notify.
    private var pendingBatches: [UUID: PendingBatch] = [:]

    private struct PendingBatch {
        var pendingKeys: Set<String>
        let source: BroadcastSource
        let startedAt: Date
    }

    init() {
        // Wire JS → Swift completion bridge to this store.
        CompletionScriptHandler.shared.onCompletion = { [weak self] host in
            self?.handleHostCompletion(host: host)
        }
        // Track streaming state per host for the status dots.
        CompletionScriptHandler.shared.onStreamingState = { [weak self] host, streaming in
            guard let self, let key = self.providerKey(forHost: host) else { return }
            if streaming { self.streamingKeys.insert(key) } else { self.streamingKeys.remove(key) }
        }
    }

    /// Returns an existing WKWebView for `key`, or creates one and caches it.
    /// Calling this multiple times for the same key always returns the same instance.
    func getOrCreate(key: String, url: URL) -> WKWebView {
        if let existing = cache[key] {
            return existing
        }
        let webView = WebViewFactory.make(url: url)
        cache[key] = webView
        return webView
    }

    /// Reloads the WKWebView for a given provider key (preserves cookies / login).
    func reload(key: String) {
        cache[key]?.reload()
    }

    /// Navigate a panel to its "new conversation" page (login/cookies preserved).
    func newChat(key: String) {
        let newChatURLs: [String: String] = [
            "chatgpt": "https://chatgpt.com/",
            "claude":  "https://claude.ai/new",
            "gemini":  "https://gemini.google.com/app",
        ]
        guard let webView = cache[key],
              let str = newChatURLs[key],
              let url = URL(string: str) else { return }
        webView.load(URLRequest(url: url))
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
                startedAt: Date()
            )
            clog("batch \(batchID.uuidString.prefix(8)) created — source=\(source), waiting on \(trackKeys) (visible=\(visibleKeys), required=\(requiredKeys))")
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
                } else if let result = result {
                    print("[\(key)] \(result)")
                }
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
                    pendingBatches[id] = batch
                }
            }
        }

        for batch in completedBatches {
            CompletionNotifier.shared.handleBatchComplete(source: batch.source)
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
        ("通义千问",     "https://www.tongyi.com/"),
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
    static let cardBorder = Color.white.opacity(0.09)

    static var canvas: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.13, green: 0.13, blue: 0.145),
                     Color(red: 0.08, green: 0.08, blue: 0.09)],
            startPoint: .top, endPoint: .bottom
        )
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
            w.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject private var store: WebViewStore
    @State private var prompt: String = ""
    @State private var attachedImage: NSImage? = nil
    @FocusState private var promptFocused: Bool

    @AppStorage("providerOrder") private var providerOrderRaw: String = "chatgpt,claude,gemini"
    @AppStorage("hiddenProviders") private var hiddenProvidersRaw: String = ""
    @AppStorage("customProviders") private var customProvidersRaw: String = ""

    /// Built-ins + user-added providers. Recomputes when customProvidersRaw changes.
    private var allProviders: [Provider] {
        ProviderRegistry.builtIn + ProviderRegistry.decode(customProvidersRaw)
    }

    @State private var dropTargetKey: String? = nil
    @State private var hoveredHeaderKey: String? = nil
    @State private var pasteMonitor: Any? = nil

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

    /// Toggle a provider's visibility. Refuses to hide the last-remaining visible panel.
    private func toggleHidden(_ key: String) {
        var keys = hiddenKeys
        if keys.contains(key) {
            keys.remove(key)
        } else {
            // Don't allow hiding if it would leave 0 visible panels
            let remainingVisible = orderedProviders.count - keys.count - 1
            guard remainingVisible >= 1 else { return }
            keys.insert(key)
        }
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
        .background(ChorusTheme.canvas.ignoresSafeArea())
        .background(WindowConfigurator())
        .onAppear {
            // Pre-create all webviews up-front so their lifecycle is independent of view rebuilds.
            for p in allProviders {
                _ = store.getOrCreate(key: p.key, url: p.url)
            }
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
            slimHeader(for: p)
            WebPanel(webView: store.getOrCreate(key: p.key, url: p.url))
        }
        .clipShape(RoundedRectangle(cornerRadius: ChorusTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ChorusTheme.cardRadius, style: .continuous)
                .strokeBorder(
                    dropTargetKey == p.key ? Color.accentColor.opacity(0.8) : ChorusTheme.cardBorder,
                    lineWidth: dropTargetKey == p.key ? 2 : 1
                )
        )
        .shadow(color: .black.opacity(0.30), radius: 9, x: 0, y: 3)
    }

    /// Thin neutral status strip: a "thinking" dot, the provider name, and hover actions.
    /// Kept minimal so it doesn't compete with each site's own header below it.
    private func slimHeader(for p: Provider) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(store.streamingKeys.contains(p.key) ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
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
                .help("Reload \(p.name)")
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
                    .help("Hide \(p.name)")
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

                TextField("Ask all AIs…    ⌘↩ to send · ⌘V to paste image",
                          text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($promptFocused)
                    .lineLimit(1...8)

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
                .help("Send to all (⌘↩)")
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
                .strokeBorder(ChorusTheme.cardBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 2)
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
            } label: { Label("New chat", systemImage: "square.and.pencil") }

            Button {
                for p in visibleProviders { store.reload(key: p.key) }
            } label: { Label("Reload all", systemImage: "arrow.clockwise") }

            Divider()

            Section("Panels") {
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

            Divider()

            if #available(macOS 14.0, *) {
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }
            } else {
                Button {
                    openSettings()
                } label: { Label("Settings…", systemImage: "gearshape") }
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
        .help("Actions")
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
                .help("Remove attached image")
            }
            Text("Image attached")
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
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        store.broadcast(text: text, image: attachedImage, source: .mainWindow)
        prompt = ""
        attachedImage = nil
    }
}
