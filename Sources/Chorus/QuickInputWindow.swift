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

    private init() {}

    func toggle() {
        if let p = panel, p.isVisible { hide() } else { show() }
    }

    func show() {
        if panel == nil { createPanel() }
        recenter()
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
        if foregroundMain {
            NSApp.activate(ignoringOtherApps: true)
            for w in NSApp.windows where w !== panel && w.canBecomeMain {
                w.makeKeyAndOrderFront(nil)
                break
            }
        }
    }

    /// Called from SwiftUI whenever the content's preferred size changes.
    /// We grow the panel keeping its visual CENTER stable — both top and
    /// bottom expand symmetrically, so the input stays visually anchored.
    fileprivate func contentSizeChanged(_ size: CGSize) {
        guard let panel = panel else { return }
        let newHeight = max(size.height, 50)
        let old = panel.frame
        guard abs(old.size.height - newHeight) > 0.5 else { return }
        let centerY = old.midY
        var f = old
        f.size.height = newHeight
        f.origin.y = centerY - newHeight / 2
        panel.setFrame(f, display: true, animate: false)
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
    @FocusState private var focused: Bool

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
                Image(systemName: "sparkles")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)

                TextField(
                    "Ask all AIs at once...   ↩ send · ⇧↩ newline · ⌘V image · esc cancel",
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
        .onAppear {
            prompt = ""
            attachedImage = nil
            focused = true
            installMonitors()
        }
        .onDisappear { removeMonitors() }
    }

    private func submit() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || attachedImage != nil else { return }
        store.broadcast(text: text, image: attachedImage, source: .quickInput)
        prompt = ""
        attachedImage = nil
        onSubmitCompleted()
    }

    private func installMonitors() {
        guard pasteMonitor == nil else { return }

        // Cmd+V → capture clipboard image (text paste continues normally).
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard focused,
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

        // Combined Enter / Esc handler with IME awareness.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc → dismiss
            if event.keyCode == UInt16(kVK_Escape) {
                onDismiss()
                return nil
            }
            // Enter → submit (or newline with Shift)
            if event.keyCode == UInt16(kVK_Return) {
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                // Let IME commit candidate when composing
                if let ic = NSApp.keyWindow?.firstResponder as? NSTextInputClient,
                   ic.hasMarkedText() {
                    return event
                }
                if mods.contains(.shift) {
                    return event   // shift+Enter = newline (TextField handles it)
                }
                // Plain Enter or Cmd+Enter → submit
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
