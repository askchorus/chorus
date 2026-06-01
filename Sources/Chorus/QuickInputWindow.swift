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

    /// While true, the panel won't auto-hide on losing key focus. Set during voice input so
    /// the mic-permission dialog / audio session stealing focus doesn't dismiss the panel.
    var suppressAutoHide = false

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

    /// After voice input ends, bring the panel back to key so the text field is focused for
    /// editing/sending and the normal click-away-to-dismiss behavior resumes.
    func refocusAfterDictation() {
        guard let panel = panel, panel.isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.focusTextField() }
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
        let delta = abs(old.size.height - newHeight)
        guard delta > 0.5 else { return }
        let centerY = old.midY
        var f = old
        f.size.height = newHeight
        f.origin.y = centerY - newHeight / 2

        // Smoothly animate big jumps (chips / dictionary result appearing or disappearing) for a
        // polished "grows to fit" feel. Keep small jumps (a typed line wrapping) and the initial
        // grow-in right after summon instant, so typing stays snappy and summon isn't a wipe.
        let justShown = Date().timeIntervalSince(lastShowAt) < 0.3
        if delta >= 30 && !justShown {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(f, display: true)
            }
        } else {
            panel.setFrame(f, display: true, animate: false)
        }
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
                guard let self else { return }
                if self.suppressAutoHide { return }   // voice input in progress — keep panel up
                if let pp = self.panel, !pp.isKeyWindow { pp.orderOut(nil) }
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

/// Natural height of the definition text, measured by an off-screen twin (see the dictionary
/// hit view) so we can size the scroll area to the content, capped — neither cramped nor giant.
private struct DefHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The scrollable, height-capped dictionary definition. Pulled into its OWN View on purpose:
/// SwiftUI then re-renders it only when the definition `text` changes — not on every keystroke
/// in the prompt above it. Inlined in the parent body, the off-screen measuring twin re-laid-out
/// the whole (long) definition on every key, which is what stuttered typing/deleting.
private struct DictDefinitionView: View {
    let text: String
    @State private var defHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.system(size: 14))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Height = natural content height, capped at 340 (off-screen twin measures it).
        .frame(height: min(max(defHeight, 56), 340))
        .background(
            Text(text)
                .font(.system(size: 14))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { g in
                    Color.clear.preference(key: DefHeightKey.self, value: g.size.height)
                })
                .hidden()
                .allowsHitTesting(false)
        )
        .onPreferenceChange(DefHeightKey.self) { defHeight = $0 }
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
    @State private var aiFallbackWord: String? = nil     // non-nil → show the "not in dictionaries" clickable actions
    @State private var hoveredFallback: String? = nil    // which fallback action row is hovered
    @State private var lookupTask: Task<Void, Never>? = nil   // cancels stale online lookups when prompt changes
    @State private var commandUpdateTask: Task<Void, Never>? = nil  // debounces lookups so fast typing/deleting stays smooth
    @FocusState private var focused: Bool

    // User-customizable quick-prompt chips (edited in Settings → Quick Prompts).
    @AppStorage("customTextChips") private var textChipsRaw: String = kDefaultChipPrompts.joined(separator: "\n")
    @AppStorage("customImageChips") private var imageChipsRaw: String = kImageChipPrompts.joined(separator: "\n")
    @AppStorage("appLanguage") private var appLanguage: String = "system"  // re-render on language switch
    @AppStorage("minimalMode") private var minimalMode: Bool = false

    // Prompt history (↑/↓ recall) browsing state.
    @State private var historyIndex: Int? = nil
    @State private var historyDraft: String = ""

    // Voice input (on-device dictation).
    @StateObject private var dictator = SpeechDictator()
    @State private var dictationBase = ""
    @State private var micPulse = false
    @State private var hoveredChip: String? = nil
    @Environment(\.colorScheme) private var colorScheme

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

            HStack(alignment: .top, spacing: 13) {
                leadingIcon
                    .foregroundColor(.secondary)
                    .padding(.top, 3)

                TextField(
                    minimalMode ? "" : L("quick.placeholder"),
                    text: $prompt,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .focused($focused)
                .font(.system(size: 20))
                .lineLimit(1...5)

                Button {
                    if dictator.isRecording {
                        dictator.stop()
                    } else {
                        // Set BEFORE starting so the mic-permission dialog stealing focus
                        // doesn't auto-dismiss the panel.
                        QuickInputWindowController.shared.suppressAutoHide = true
                        dictationBase = prompt.isEmpty ? "" : prompt + " "
                        dictator.start { text in prompt = dictationBase + text }
                    }
                } label: {
                    Image(systemName: dictator.isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 16))
                        // Calm accent-color breathing pulse while listening (consistent with the
                        // card "thinking" pulse) — not an alarming red.
                        .foregroundColor(dictator.isRecording ? .accentColor : .secondary)
                        .opacity(dictator.isRecording ? (micPulse ? 0.45 : 1.0) : 1.0)
                        .animation(dictator.isRecording
                                   ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                                   : .default, value: micPulse)
                        .padding(.top, 3)
                }
                .buttonStyle(.plain)
                .help(dictator.permissionDenied ? L("quick.micDenied")
                      : (dictator.isRecording ? L("quick.micStop") : L("quick.mic")))
                .onChange(of: dictator.isRecording) { recording in
                    micPulse = recording
                    if !recording {
                        QuickInputWindowController.shared.suppressAutoHide = false
                        QuickInputWindowController.shared.refocusAfterDictation()
                    }
                }
                .onChange(of: dictator.permissionDenied) { denied in
                    if denied {
                        QuickInputWindowController.shared.suppressAutoHide = false
                        QuickInputWindowController.shared.refocusAfterDictation()
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            // Chip row — quick-prefix buttons. Shown when the user has either typed
            // something OR attached an image, and we're not in dictionary-lookup mode.
            // The chip set switches when an image is attached so the suggestions match
            // what makes sense for vision input.
            // Chips show whenever there's text or an image — INCLUDING during a dictionary
            // hit. Looking a word up and wanting the AIs to expand on it ("解释一下 …") is a
            // natural combo, so the two shouldn't be mutually exclusive.
            if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedImage != nil {
                let chips = attachedImage != nil
                    ? parseChipList(imageChipsRaw, fallback: kImageChipPrompts)
                    : parseChipList(textChipsRaw, fallback: kDefaultChipPrompts)
                HStack(spacing: 8) {
                    ForEach(chips, id: \.self) { chip in
                        Button {
                            // Tapping a chip is an explicit "broadcast" intent — leave any
                            // dictionary-lookup mode so submit() broadcasts instead of just
                            // dismissing the definition.
                            isAutoDictionary = false
                            prompt = applyChipPrefix(chip, to: prompt)
                            submit()
                        } label: {
                            Text(chip)
                                .font(.system(size: 12))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule().fill(Color.primary.opacity(hoveredChip == chip ? 0.15 : 0.07))
                                )
                                .overlay(
                                    Capsule().strokeBorder(Color.primary.opacity(hoveredChip == chip ? 0.12 : 0.05))
                                )
                        }
                        .buttonStyle(.plain)
                        .help(Lf("quick.chipHelp", chip))
                        .onHover { hovering in
                            hoveredChip = hovering ? chip : (hoveredChip == chip ? nil : hoveredChip)
                        }
                        .animation(.easeOut(duration: 0.12), value: hoveredChip)
                    }
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }

            // Result area — only shown when a command produced output.
            if isAutoDictionary, let result = commandResult, !result.isEmpty {
                // Dictionary / Wikipedia HIT. Long entries (e.g. "take") used to grow the panel
                // to full-screen height — cap it and make it scroll. The action footer is still
                // offered so you can ask all AIs / Google the word even when a definition shows.
                Divider()
                ZStack(alignment: .topTrailing) {
                    DictDefinitionView(text: result)   // own View → not re-laid-out on every keystroke
                    speakerButton
                }
                actionFooter
            } else if let word = aiFallbackWord {
                // Dictionary MISS: short message + the same action footer.
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    Text("“\(word)” isn't in your dictionaries.")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                    actionFooter
                }
            } else if let result = commandResult, !result.isEmpty {
                // Other inline output (e.g. help text): plain, no footer.
                Divider()
                Text(result)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(
            ZStack {
                // Dark: the classic translucent HUD. Light: a soft popover material warmed with
                // a cream tint so it matches the paper canvas / icon instead of a cold panel.
                VisualEffectView(material: colorScheme == .dark ? .hudWindow : .popover,
                                 blendingMode: .behindWindow)
                if colorScheme != .dark {
                    Color(red: 0.965, green: 0.945, blue: 0.905).opacity(0.78)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            // Dark: a top-lit gradient "glass edge". Light: a soft warm hairline (the white
            // gradient would be invisible on cream).
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    colorScheme == .dark
                        ? AnyShapeStyle(LinearGradient(
                            colors: [Color.white.opacity(0.28), Color.white.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(Color(red: 0.45, green: 0.38, blue: 0.26).opacity(0.18)),
                    lineWidth: 1
                )
        )
        .padding(8)
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
            // Debounce: don't run the dictionary lookup on every keystroke (it stutters fast
            // typing / deleting and the IME commit). Wait ~150ms after the last change.
            commandUpdateTask?.cancel()
            commandUpdateTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { return }
                updateCommandResult()
            }
        }
        .onAppear {
            focused = true
            installMonitors()
            loadClipboardIfEnabled()
            updateCommandResult()
        }
        .onDisappear { removeMonitors(); dictator.stop() }
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

    /// Auto-populate the input from the clipboard — but ONLY when the box is empty, so it never
    /// clobbers a draft you typed (or re-pastes over your edit every time focus shifts, which
    /// made it look like you "couldn't delete" pasted text). Image takes priority over text.
    private func loadClipboardIfEnabled() {
        // Never overwrite existing content — preserve the user's draft across hide/re-summon.
        guard prompt.isEmpty, attachedImage == nil else { return }
        let enabled = UserDefaults.standard.object(forKey: "autoPasteOnSummon") as? Bool ?? true
        guard enabled else { return }
        let pb = NSPasteboard.general
        if let img = NSImage(pasteboard: pb), img.size.width > 0, img.size.height > 0 {
            attachedImage = img
        } else if let str = pb.string(forType: .string), !str.isEmpty {
            prompt = str
        }
    }

    private func submit() {
        dictator.stop()  // end any in-progress dictation before acting on the prompt
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
            PromptHistory.add(text)
            historyIndex = nil
            prompt = ""
            attachedImage = nil
            commandResult = nil
            aiFallbackWord = nil
            onSubmitCompleted()
        }
    }

    /// Broadcast the current prompt to all AIs regardless of whether a dictionary entry is
    /// showing (plain Enter dismisses on a dict hit; the footer's "Ask all AIs" / ⌘↩ uses this
    /// so you can always send the word to the AIs).
    private func broadcastCurrent() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || attachedImage != nil else { return }
        store.broadcast(text: text, image: attachedImage, source: .quickInput)
        PromptHistory.add(text)
        historyIndex = nil
        prompt = ""
        attachedImage = nil
        commandResult = nil
        aiFallbackWord = nil
        isAutoDictionary = false
        onSubmitCompleted()
    }

    /// Update the inline result preview based on what's currently in the prompt.
    /// 1. macOS Dictionary (DCS) — instant, local, covers user's installed dicts (Chinese/English/etc.)
    /// 2. Free Dictionary API — async fallback for English misses (covers slang, technical words)
    /// 3. Nothing — let Enter broadcast to AIs
    private func updateCommandResult() {
        // Always cancel any pending online lookup when prompt changes
        lookupTask?.cancel()
        lookupTask = nil
        aiFallbackWord = nil   // cleared here; re-set only on a confirmed dictionary miss below

        switch CommandRouter.route(prompt) {
        case .help:
            commandResult = helpText()
            isAutoDictionary = false

        case .broadcast:
            let candidate = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isLikelyDictionaryQuery(candidate) else {
                commandResult = nil
                isAutoDictionary = false
                return
            }

            // All lookups run OFF the main thread. DCSCopyTextDefinition is synchronous and
            // blocks; running it inline on every keystroke is what stuttered typing/deleting and
            // the IME commit. Local DCS first (detached), then English misses → online (API + Wiki).
            let target = candidate
            lookupTask = Task {
                let localDef = await Task.detached(priority: .userInitiated) {
                    dictionaryDefinition(of: target)
                }.value
                if Task.isCancelled { return }
                guard stillCurrent(target) else { return }

                if let def = localDef {
                    commandResult = def
                    isAutoDictionary = true
                    aiFallbackWord = nil
                    Task { await WordSpeaker.shared.prefetchAudio(for: target) }
                    return
                }

                guard isLikelyEnglishWord(target) else {
                    // Non-English (Chinese / Japanese / …) miss → AI / Google fallback.
                    commandResult = nil
                    aiFallbackWord = target
                    isAutoDictionary = false
                    return
                }

                // English word + local miss → Free Dictionary API and Wikipedia in parallel.
                async let api = OnlineDictionary.shared.lookup(target)
                async let wiki = WikipediaSummary.shared.lookup(target)
                let (apiResult, wikiResult) = await (api, wiki)
                if Task.isCancelled { return }
                guard stillCurrent(target) else { return }

                if let apiResult = apiResult {
                    commandResult = apiResult.formatted
                    isAutoDictionary = true
                    aiFallbackWord = nil
                } else if let wikiResult = wikiResult {
                    commandResult = wikiResult
                    isAutoDictionary = true   // Enter dismisses; Wikipedia is "content to read"
                    aiFallbackWord = nil
                } else {
                    commandResult = nil
                    aiFallbackWord = target
                    isAutoDictionary = false
                }
            }
        }
    }

    /// True if the prompt still equals `target` (case-insensitively) — guards against a stale
    /// async lookup overwriting the result after the user has typed something else.
    private func stillCurrent(_ target: String) -> Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(target) == .orderedSame
    }

    /// Speaker button for dictionary hits — plays the looked-up word via TTS.
    private var speakerButton: some View {
        Button { speakCurrentWord() } label: {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(8)
                .background(Circle().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(L("quick.pronounce"))
        .padding(.trailing, 12)
        .padding(.top, 10)
    }

    /// Shared action footer shown under the dictionary preview in BOTH the hit and miss cases:
    /// "Ask all AIs" and "Google search" as clickable hover-highlight rows (mouse-friendly).
    /// ⌘↩ / ⌘B trigger them from the keyboard too — ⌘↩ rather than plain Enter because on a
    /// dictionary HIT plain Enter means "done reading, dismiss".
    private var actionFooter: some View {
        VStack(spacing: 2) {
            Divider().padding(.horizontal, 10).padding(.bottom, 4)
            fallbackRow(id: "ask", cap: "⌘↩", label: "Ask all AIs") {
                broadcastCurrent()
            }
            fallbackRow(id: "google", cap: "⌘B", label: "Open Google search in your browser") {
                openGoogleSearch(prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                onDismiss()
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }

    /// One clickable action row in the dictionary-miss view: a key-cap chip + label, with a
    /// soft hover highlight. `contentShape` makes the whole row hit-testable.
    private func fallbackRow(id: String, cap: String, label: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(cap)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
                .frame(minWidth: 26)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hoveredFallback == id ? Color.primary.opacity(0.07) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredFallback = id }
            else if hoveredFallback == id { hoveredFallback = nil }
        }
        .onTapGesture(perform: action)
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

    /// Leading glyph. In the normal broadcast state we echo the app logo — the
    /// circle / square / triangle trio — instead of a generic SF Symbol, so the
    /// quick input feels like the same product. Contextual modes (help, dictionary)
    /// keep their meaningful SF Symbol.
    // NOTE (future): replace ✨ with a purpose-made monochrome brand mark (circle/square/
    // triangle) that also doubles as the menu-bar icon. The hand-drawn cluster + the shrunk
    // app icon both looked off; this needs a real designed glyph (vector/PNG) before swapping in.
    @ViewBuilder private var leadingIcon: some View {
        Image(systemName: iconForCurrentInput())
            .font(.system(size: 19))
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

            // IME GUARD (must be first): while an input method is composing — e.g. typing
            // English/pinyin through a Chinese IME, with marked (underlined) text and a candidate
            // window open — the input method owns the keys: arrows navigate candidates, Enter
            // commits. If ANY handler below intercepts them, the composition freezes mid-word
            // (the reported "卡住" when hitting Enter to commit English via a Chinese IME). So
            // pass every key straight through until the text is actually committed.
            //
            // Detection: the firstResponder is usually the field editor (an NSTextView), but in
            // some SwiftUI/NSPanel setups it's reported as the NSTextField — so also consult the
            // window's shared field editor directly. Either reporting marked text == composing.
            let kw = NSApp.keyWindow
            let composing = ((kw?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true)
                || ((kw?.fieldEditor(false, for: nil) as? NSTextView)?.hasMarkedText() == true)
            if composing { return event }

            // Prompt history recall: ↑ at text start, ↓ at text end (otherwise move the caret).
            if event.keyCode == 126 {  // up arrow → older
                guard caretAtTextStart(),
                      let r = promptHistoryStep(direction: -1, current: prompt, index: historyIndex, draft: historyDraft)
                else { return event }
                Task { @MainActor in
                    prompt = r.prompt; historyIndex = r.index; historyDraft = r.draft
                    moveCaretToTextEnd()
                }
                return nil
            }
            if event.keyCode == 125 {  // down arrow → newer
                guard historyIndex != nil, caretAtTextEnd(),
                      let r = promptHistoryStep(direction: 1, current: prompt, index: historyIndex, draft: historyDraft)
                else { return event }
                Task { @MainActor in
                    prompt = r.prompt; historyIndex = r.index; historyDraft = r.draft
                    moveCaretToTextEnd()
                }
                return nil
            }
            // Any other key exits history browsing.
            if historyIndex != nil { Task { @MainActor in historyIndex = nil } }

            // Cmd+L → speak the current word (only when a dictionary hit is showing)
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "l",
               isAutoDictionary {
                Task { @MainActor in speakCurrentWord() }
                return nil
            }

            // Cmd+Return → broadcast to all AIs even when a dictionary entry is showing (plain
            // Enter dismisses on a dict hit). Mirrors the footer's "Ask all AIs" row.
            if event.modifierFlags.contains(.command),
               event.keyCode == UInt16(kVK_Return) {
                Task { @MainActor in broadcastCurrent() }
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
