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
        if host.contains("chatgpt") || host.contains("openai") { return "chatgpt" }
        if host.contains("claude") { return "claude" }
        if host.contains("gemini") || host.contains("google") { return "gemini" }
        return nil
    }
}

struct Provider: Identifiable {
    let key: String
    let name: String
    let url: URL
    var id: String { key }
}

let allProviders: [Provider] = [
    Provider(key: "chatgpt", name: "ChatGPT", url: URL(string: "https://chatgpt.com/")!),
    Provider(key: "claude",  name: "Claude",  url: URL(string: "https://claude.ai/")!),
    Provider(key: "gemini",  name: "Gemini",  url: URL(string: "https://gemini.google.com/")!),
]

struct ContentView: View {
    @EnvironmentObject private var store: WebViewStore
    @State private var prompt: String = ""
    @State private var attachedImage: NSImage? = nil
    @FocusState private var promptFocused: Bool

    @AppStorage("providerOrder") private var providerOrderRaw: String = "chatgpt,claude,gemini"
    @AppStorage("hiddenProviders") private var hiddenProvidersRaw: String = ""

    @State private var dropTargetKey: String? = nil
    @State private var hoveredHeaderKey: String? = nil
    @State private var pasteMonitor: Any? = nil
    @State private var showPanelMenu: Bool = false

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
            // HStack with equal-flex children: panels always evenly distributed across width.
            // Reordering just shuffles the ForEach output; WKWebViews stay alive in the store
            // and get reparented into the new positions. No divider state to drift.
            HStack(spacing: 1) {
                ForEach(visibleProviders) { p in
                    panel(for: p)
                        .frame(minWidth: 320, maxWidth: .infinity)
                }
            }
            .background(Color.secondary.opacity(0.25))  // 1px gap shows as a thin separator

            Divider()
            inputBar
        }
        .onAppear {
            // Pre-create all webviews up-front so their lifecycle is independent of view rebuilds.
            for p in allProviders {
                _ = store.getOrCreate(key: p.key, url: p.url)
            }
        }
    }

    private func panel(for p: Provider) -> some View {
        VStack(spacing: 0) {
            header(for: p)
            WebPanel(webView: store.getOrCreate(key: p.key, url: p.url))
        }
    }

    private func header(for p: Provider) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(p.name).font(.headline)
            Spacer()
            if hoveredHeaderKey == p.key {
                Text("拖动重排")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .transition(.opacity)

                // Reload button: always available on hover (works even on the last visible panel)
                Button {
                    store.reload(key: p.key)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reload \(p.name)")
                .transition(.opacity)

                // Close button: only on hover, only if there'd still be panels left after closing
                if visibleProviders.count > 1 {
                    Button {
                        toggleHidden(p.key)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Hide \(p.name)")
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                if dropTargetKey == p.key {
                    Rectangle().fill(Color.accentColor.opacity(0.30))
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
            if hovering {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .draggable(p.key) {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal").font(.caption)
                Text(p.name).font(.headline)
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

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Image preview row: shown only when an image is attached
            if let image = attachedImage {
                HStack(spacing: 8) {
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 56, height: 56)
                            .clipped()
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.secondary.opacity(0.3))
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
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 2)
            }

            HStack(alignment: .bottom, spacing: 8) {
                panelVisibilityButton

                TextField("Ask all three AIs...   ⌘+Enter to send · ⌘+V to paste image",
                          text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($promptFocused)
                    .lineLimit(1...8)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.secondary.opacity(0.3))
                    )

                Button("Send to all") { send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
            }
            .padding(8)
        }
        .background(.bar)
        .onAppear {
            promptFocused = true
            installPasteMonitor()
        }
        .onDisappear {
            removePasteMonitor()
        }
    }

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedImage != nil
    }

    /// Small button in the input bar that opens a popover for toggling panel visibility.
    private var panelVisibilityButton: some View {
        Button {
            showPanelMenu.toggle()
        } label: {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 16))
                .foregroundColor(.secondary)
                .padding(6)
        }
        .buttonStyle(.plain)
        .help("Show/hide AI panels")
        .popover(isPresented: $showPanelMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text("AI Panels")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                ForEach(allProviders) { p in
                    let isVisible = !hiddenKeys.contains(p.key)
                    let isLastVisible = isVisible && visibleProviders.count == 1
                    Button {
                        toggleHidden(p.key)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isVisible ? "checkmark.square.fill" : "square")
                                .foregroundColor(isVisible ? .accentColor : .secondary)
                                .font(.system(size: 14))
                            Text(p.name)
                                .foregroundColor(.primary)
                            Spacer()
                            if isLastVisible {
                                Text("(必须保留 1 个)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLastVisible)
                }
            }
            .frame(width: 220)
            .padding(.vertical, 4)
        }
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
