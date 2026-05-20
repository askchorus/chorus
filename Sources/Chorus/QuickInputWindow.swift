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

    private init() {}

    /// Toggle visibility — hide if showing, show if not.
    func toggle() {
        if let p = panel, p.isVisible { hide() } else { show() }
    }

    func show() {
        if panel == nil { createPanel() }
        positionAtScreenTopCenter()
        // Do NOT call NSApp.activate(...) here — that would surface the main Chorus window
        // alongside the panel. `.nonactivatingPanel` + KeyablePanel.canBecomeKey lets the
        // panel grab keyboard focus without changing the app's activation state.
        panel?.makeKeyAndOrderFront(nil)

        // Force the TextField to be first responder. SwiftUI's @FocusState alone is
        // unreliable for non-activating panels — the underlying NSTextField needs an
        // explicit makeFirstResponder() after the panel becomes key.
        // Dispatch async so it runs after AppKit finishes propagating the key change.
        DispatchQueue.main.async { [weak self] in
            self?.focusTextField()
        }
    }

    private func focusTextField() {
        guard let panel = panel, let content = panel.contentView else { return }
        if let tf = firstTextField(in: content) {
            panel.makeFirstResponder(tf)
        }
    }

    /// Recursively search for the first NSTextField in a view hierarchy.
    /// SwiftUI's TextField bridges to NSTextField on macOS.
    private func firstTextField(in view: NSView) -> NSTextField? {
        if let tf = view as? NSTextField { return tf }
        for sub in view.subviews {
            if let tf = firstTextField(in: sub) { return tf }
        }
        return nil
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Called after the user submits a prompt from the quick input.
    func handlePostSubmit() {
        hide()
        let foregroundMain = UserDefaults.standard.object(forKey: "foregroundMainOnSend") as? Bool ?? true
        if foregroundMain {
            // Only NOW do we activate the app and surface the main window.
            NSApp.activate(ignoringOtherApps: true)
            for w in NSApp.windows where w !== panel && w.canBecomeMain {
                w.makeKeyAndOrderFront(nil)
                break
            }
        }
        // If !foregroundMain: just hide the panel — Chorus was never activated,
        // so the user is automatically back in whatever app they came from.
    }

    private func createPanel() {
        let view = QuickInputView(
            onSubmitCompleted: { [weak self] in self?.handlePostSubmit() },
            onDismiss: { [weak self] in self?.hide() }
        )
        let hostingView = NSHostingView(rootView: view)

        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 70),
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
        p.contentView = hostingView

        // Auto-dismiss when the panel loses key (user clicked elsewhere / Cmd+Tab)
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: p,
            queue: .main
        ) { [weak self] _ in
            // Small delay so submit's own hide+activate doesn't race
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let pp = self?.panel, !pp.isKeyWindow { pp.orderOut(nil) }
            }
        }

        self.panel = p
    }

    private func positionAtScreenTopCenter() {
        guard let screen = NSScreen.main, let panel = panel else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.maxY - size.height - 180   // ~180pt from the top of the visible area
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// The SwiftUI content of the quick input panel. Single-line input, optional image preview,
/// Enter submits, Esc dismisses, Cmd+V pastes an image.
struct QuickInputView: View {
    let onSubmitCompleted: () -> Void
    let onDismiss: () -> Void

    @State private var prompt: String = ""
    @State private var attachedImage: NSImage? = nil
    @State private var pasteMonitor: Any? = nil
    @State private var escMonitor: Any? = nil
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

            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)

                TextField("Ask all AIs at once...   ↩ send · ⌘V image · esc cancel",
                          text: $prompt)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .font(.system(size: 18))
                    .onSubmit { submit() }
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

        // Cmd+V → check clipboard for image; let text paste continue normally
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

        // Esc → dismiss (works regardless of TextField focus)
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                onDismiss()
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let m = pasteMonitor { NSEvent.removeMonitor(m); pasteMonitor = nil }
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }
}

/// SwiftUI wrapper for NSVisualEffectView (frosted Spotlight-style background).
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
