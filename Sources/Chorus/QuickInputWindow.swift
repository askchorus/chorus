import SwiftUI
import AppKit
import Carbon.HIToolbox

/// NSPanel subclass that can become key window even with `.nonactivatingPanel`.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickInputWindowController {
    static let shared = QuickInputWindowController()

    private var panel: KeyablePanel?
    private var resignKeyObserver: NSObjectProtocol?

    // Frame width is fixed; height tracks SwiftUI content.
    private let panelWidth: CGFloat = 640

    /// Timestamp of the last explicit `show()` call. Used by the SwiftUI view to
    /// distinguish "panel just got summoned" (load clipboard) from "panel got
    /// focus back after the user clicked an internal button" (do NOT reload — it
    /// would clobber the prompt with stale clipboard content).
    var lastShowAt: Date = .distantPast

    private init() {}

    func toggle() {
        if let p = panel, p.isVisible { hide() } else { show() }
    }

    func show() {
        if panel == nil { createPanel() }
        recenter()
        lastShowAt = Date()    // mark a fresh summon so the SwiftUI view knows it's OK to reload clipboard
        // Do NOT NSApp.activate(...) — would surface the main Chorus window.
        panel?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.focusTextField() }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func handlePostSubmit() {
        hide()
        let foregroundMain = UserDefaults.standard.object(forKey: "foregroundMainOnSend") as? Bool ?? true
        clog("[QuickInput] handlePostSubmit — foregroundMain=\(foregroundMain)")
        guard foregroundMain else { return }

        // Defer to next runloop so panel.orderOut + resignKey side-effects settle first.
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)

            // Pick exactly ONE target window — the SwiftUI WindowGroup main window.
            // SwiftUI's AppKitWindow reports canBecomeMain=false even though it IS the
            // main window, so we can't rely on that. Instead, prefer a non-panel window
            // titled "Chorus"; fall back to the first non-panel non-Settings window.
            let candidates = NSApp.windows.filter { w in
                w !== self?.panel && !(w is NSPanel)
            }
            let target = candidates.first(where: { $0.title == "Chorus" })
                      ?? candidates.first(where: { $0.title != "Chorus Settings" && !$0.title.isEmpty })
                      ?? candidates.first

            guard let target = target else {
                clog("[QuickInput] no candidate non-panel window to surface")
                return
            }

            if target.isMiniaturized {
                target.deminiaturize(nil)
            }
            target.makeKeyAndOrderFront(nil)
            clog("[QuickInput] surfaced '\(target.title)' \(type(of: target)) isMin-was=\(target.isMiniaturized)")
        }
    }

    /// Called from SwiftUI whenever the content's preferred size changes.
    /// We grow the panel keeping its visual CENTER stable — both top and
    /// bottom expand symmetrically, so the input stays visually anchored.
    fileprivate func contentSizeChanged(_ size: CGSize) {
        guard let panel = panel else { return }
        let newHeight = max(size.height, 50)
        let old = panel.frame
        clog("[Resize] content reported=\(Int(size.width))x\(Int(size.height)) panel current=\(Int(old.size.width))x\(Int(old.size.height))")
        guard abs(old.size.height - newHeight) > 0.5 else { return }
        let centerY = old.midY
        var f = old
        f.size.height = newHeight
        f.origin.y = centerY - newHeight / 2
        panel.setFrame(f, display: true, animate: false)
        clog("[Resize] panel grew to \(Int(f.size.width))x\(Int(f.size.height))")
    }

    private func createPanel() {
        let view = QuickInputView(
            onSubmitCompleted: { [weak self] in self?.handlePostSubmit() },
            onDismiss: { [weak self] in self?.hide() },
            onSizeChange: { [weak self] size in self?.contentSizeChanged(size) }
        )
        let hostingView = NSHostingView(rootView: view)

        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 70),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isFloatingPanel = true
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isReleasedWhenClosed = false
        // Drag anywhere on the panel's non-interactive surface (blur background, padding).
        // Clicks on the TextField still place the cursor — AppKit lets the interactive
        // child handle mouseDown first, only initiating window drag if no view consumed it.
        p.isMovableByWindowBackground = true
        p.contentView = hostingView

        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: p,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let pp = self?.panel, !pp.isKeyWindow { pp.orderOut(nil) }
            }
        }

        self.panel = p
    }

    /// Center the panel horizontally and vertically on the screen with the active app.
    private func recenter() {
        guard let screen = NSScreen.main, let panel = panel else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.midY - size.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func focusTextField() {
        guard let panel = panel, let content = panel.contentView else { return }
        if let tf = firstTextField(in: content) { panel.makeFirstResponder(tf) }
    }

    private func firstTextField(in view: NSView) -> NSTextField? {
        if let tf = view as? NSTextField { return tf }
        for sub in view.subviews {
            if let tf = firstTextField(in: sub) { return tf }
        }
        return nil
    }
}

// MARK: - SwiftUI content

private struct ContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct QuickInputView: View {
    let onSubmitCompleted: () -> Void
    let onDismiss: () -> Void
    let onSizeChange: (CGSize) -> Void

    @State private var prompt: String = ""
    @State private var attachedImage: NSImage? = nil
    @State private var pasteMonitor: Any? = nil
    @State private var keyMonitor: Any? = nil
    @State private var commandResult: String? = nil      // inline preview (definition / help)
    @State private var isAutoDictionary: Bool = false    // true when current prompt produced a dict hit
    @State private var lookupTask: Task<Void, Never>? = nil   // cancels stale online lookups when prompt changes
    @FocusState private var focused: Bool

    // User-customizable quick-prompt chips (edited in Settings → Quick Prompts).
    @AppStorage("customTextChips") private var textChipsRaw: String = kDefaultChipPrompts.joined(separator: "\n")
    @AppStorage("customImageChips") private var imageChipsRaw: String = kImageChipPrompts.joined(separator: "\n")

    private let store = WebViewStore.shared

    var body: some View {
        VStack(spacing: 0) {
            if let img = attachedImage {
                HStack(spacing: 6) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipped()
                        .cornerRadius(4)
                    Button {
                        attachedImage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    Text("Image attached")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconForCurrentInput())
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)

                TextField(
                    "Ask all AIs at once...   (single word auto-looks up · /? for help)",
                    text: $prompt,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .focused($focused)
                .font(.system(size: 18))
                .lineLimit(1...5)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            // Chip row — quick-prefix buttons. Shown when the user has either typed
            // something OR attached an image, and we're not in dictionary-lookup mode.
            // The chip set switches when an image is attached so the suggestions match
            // what makes sense for vision input.
            if (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedImage != nil),
               !isAutoDictionary {
                let chips = attachedImage != nil
                    ? parseChipList(imageChipsRaw, fallback: kImageChipPrompts)
                    : parseChipList(textChipsRaw, fallback: kDefaultChipPrompts)
                HStack(spacing: 8) {
                    ForEach(chips, id: \.self) { chip in
                        Button {
                            // Prepend chip prefix and broadcast immediately — one-tap action.
                            prompt = applyChipPrefix(chip, to: prompt)
                            submit()
                        } label: {
                            Text(chip)
                                .font(.system(size: 12))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule().fill(Color.primary.opacity(0.08))
                                )
                                .overlay(
                                    Capsule().strokeBorder(Color.primary.opacity(0.05))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Send to all AIs with “\(chip)：” prepended")
                    }
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }

            // Result area — only shown when a command produced output.
            if let result = commandResult, !result.isEmpty {
                Divider()
                ZStack(alignment: .topTrailing) {
                    Text(result)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .fixedSize(horizontal: false, vertical: true)

                    // Speaker button — only for dictionary hits, plays the looked-up word via TTS
                    if isAutoDictionary {
                        Button {
                            speakCurrentWord()
                        } label: {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .padding(8)
                                .background(
                                    Circle().fill(Color.primary.opacity(0.06))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Pronounce  (⌘L)")
                        .padding(.trailing, 12)
                        .padding(.top, 10)
                    }
                }
            }
        }
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .padding(6)
        .frame(width: 640)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ContentSizeKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(ContentSizeKey.self) { size in
            onSizeChange(size)
        }
        .onChange(of: prompt) { _ in
            updateCommandResult()
        }
        .onAppear {
            focused = true
            installMonitors()
            loadClipboardIfEnabled()
            updateCommandResult()
        }
        .onDisappear { removeMonitors() }
        // Re-load clipboard only when this notification follows a fresh show() call —
        // otherwise internal focus shuffles (clicking a chip / speaker button) would
        // clobber the prompt with stale clipboard content.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notif in
            if let w = notif.object as? NSWindow, w is KeyablePanel {
                let elapsed = Date().timeIntervalSince(QuickInputWindowController.shared.lastShowAt)
                if elapsed < 0.5 {
                    loadClipboardIfEnabled()
                    updateCommandResult()
                }
            }
        }
    }

    /// Auto-populate the input from the clipboard. Image takes priority over text.
    /// If user disabled the toggle, we just clear instead.
    private func loadClipboardIfEnabled() {
        let enabled = UserDefaults.standard.object(forKey: "autoPasteOnSummon") as? Bool ?? true
        guard enabled else {
            prompt = ""
            attachedImage = nil
            return
        }
        let pb = NSPasteboard.general
        if let img = NSImage(pasteboard: pb), img.size.width > 0, img.size.height > 0 {
            attachedImage = img
            prompt = ""
        } else if let str = pb.string(forType: .string), !str.isEmpty {
            prompt = str
            attachedImage = nil
        } else {
            prompt = ""
            attachedImage = nil
        }
    }

    private func submit() {
        switch CommandRouter.route(prompt) {
        case .help:
            commandResult = nil
            onDismiss()

        case .broadcast:
            // If the prompt is currently showing an auto-dictionary hit, treat Enter
            // as "I'm done reading the definition" — close without broadcasting.
            // For misses or non-word input, broadcast as usual.
            if isAutoDictionary {
                commandResult = nil
                isAutoDictionary = false
                onDismiss()
                return
            }
            let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || attachedImage != nil else { return }
            store.broadcast(text: text, image: attachedImage, source: .quickInput)
            prompt = ""
            attachedImage = nil
            commandResult = nil
            onSubmitCompleted()
        }
    }

    /// Update the inline result preview based on what's currently in the prompt.
    /// 1. macOS Dictionary (DCS) — instant, local, covers user's installed dicts (Chinese/English/etc.)
    /// 2. Free Dictionary API — async fallback for English misses (covers slang, technical words)
    /// 3. Nothing — let Enter broadcast to AIs
    private func updateCommandResult() {
        // Always cancel any pending online lookup when prompt changes
        lookupTask?.cancel()
        lookupTask = nil

        switch CommandRouter.route(prompt) {
        case .help:
            commandResult = kHelpText
            isAutoDictionary = false

        case .broadcast:
            let candidate = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isLikelyDictionaryQuery(candidate) else {
                commandResult = nil
                isAutoDictionary = false
                return
            }

            // 1. Local macOS Dictionary first — instant
            if let def = dictionaryDefinition(of: candidate) {
                commandResult = def
                isAutoDictionary = true
                Task { await WordSpeaker.shared.prefetchAudio(for: candidate) }
                return
            }

            // 2. English word + local miss → try Free Dictionary API and Wikipedia
            //    in PARALLEL. Whichever returns first wins. If both miss, show hint.
            if isLikelyEnglishWord(candidate) {
                commandResult = nil
                isAutoDictionary = false
                let target = candidate
                lookupTask = Task {
                    async let api = OnlineDictionary.shared.lookup(target)
                    async let wiki = WikipediaSummary.shared.lookup(target)
                    let (apiResult, wikiResult) = await (api, wiki)
                    if Task.isCancelled { return }
                    let current = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard current.caseInsensitiveCompare(target) == .orderedSame else { return }

                    if let apiResult = apiResult {
                        commandResult = apiResult.formatted
                        isAutoDictionary = true
                    } else if let wikiResult = wikiResult {
                        commandResult = wikiResult
                        isAutoDictionary = true   // Enter dismisses; Wikipedia is "content to read"
                    } else {
                        commandResult = aiFallbackHint(for: target)
                        isAutoDictionary = false
                    }
                }
                return
            }

            // 3. Non-English (Chinese / Japanese / etc.) miss: hint immediately.
            commandResult = aiFallbackHint(for: candidate)
            isAutoDictionary = false
        }
    }

    /// One-line hint shown when neither local nor online dictionary has the word.
    private func aiFallbackHint(for word: String) -> String {
        """
        “\(word)” isn't in your dictionaries.

        ↩    Enter to ask all AIs
        ⌘B  Open Google search in your browser
        """
    }

    /// Speak the currently looked-up word via macOS TTS.
    private func speakCurrentWord() {
        let word = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        WordSpeaker.shared.speak(word)
    }

    /// Open a Google search for `term` in the user's default browser.
    private func openGoogleSearch(_ term: String) {
        let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        guard let url = URL(string: "https://www.google.com/search?q=\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Pick an icon hint based on what kind of command the user is typing.
    private func iconForCurrentInput() -> String {
        switch CommandRouter.route(prompt) {
        case .help:       return "questionmark.circle"
        case .broadcast:  return isAutoDictionary ? "book.closed" : "sparkles"
        }
    }

    private func installMonitors() {
        guard pasteMonitor == nil else { return }

        // CRITICAL gate for both monitors: only act when our quick-input panel is the
        // current key window. `@FocusState focused` is unreliable here because panel
        // orderOut doesn't always trigger SwiftUI's lifecycle updates — `focused` can
        // stay true even after the panel is hidden, causing us to hijack Enter/Cmd+V
        // inside the WKWebView pages (e.g. swallowing Enter when committing a Chinese
        // IME candidate on chatgpt.com).
        func panelIsKey() -> Bool { NSApp.keyWindow is KeyablePanel }

        // Cmd+V → capture clipboard image (text paste continues normally).
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard panelIsKey(),
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v"
            else { return event }
            let pb = NSPasteboard.general
            if let img = NSImage(pasteboard: pb), img.size.width > 0, img.size.height > 0 {
                Task { @MainActor in attachedImage = img }
                let hasText = pb.canReadObject(forClasses: [NSString.self], options: nil)
                return hasText ? event : nil
            }
            return event
        }

        // Combined Enter / Esc / Cmd+L handler with IME awareness.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard panelIsKey() else { return event }

            // Cmd+L → speak the current word (only when a dictionary hit is showing)
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "l",
               isAutoDictionary {
                Task { @MainActor in speakCurrentWord() }
                return nil
            }

            // Cmd+B → Google search the current input in the default browser
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "b" {
                let term = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !term.isEmpty {
                    Task { @MainActor in
                        openGoogleSearch(term)
                        onDismiss()
                    }
                    return nil
                }
            }

            // Backspace with an image attached and no text → remove the image.
            // Matches chat-app UX: once there's nothing left to delete in the text box,
            // the next backspace clears the attachment. If there IS text, fall through so
            // backspace edits text normally.
            if event.keyCode == UInt16(kVK_Delete),
               attachedImage != nil,
               prompt.isEmpty {
                Task { @MainActor in attachedImage = nil }
                return nil
            }

            if event.keyCode == UInt16(kVK_Escape) {
                onDismiss()
                return nil
            }
            if event.keyCode == UInt16(kVK_Return) {
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if let ic = NSApp.keyWindow?.firstResponder as? NSTextInputClient,
                   ic.hasMarkedText() {
                    return event   // let IME commit candidate
                }
                if mods.contains(.shift) {
                    return event   // shift+Enter = newline
                }
                Task { @MainActor in submit() }
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let m = pasteMonitor { NSEvent.removeMonitor(m); pasteMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blendingMode
    }
}
