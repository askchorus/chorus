import AppKit
import SwiftUI

/// The comparison's own window rather than a sheet over the main one: it doesn't lock the panels,
/// so the answers can be read next to it, and closing it doesn't stop the comparison — when the
/// result is in, the window comes back by itself, without taking the keyboard from whatever the
/// user is typing. A floating utility panel: above the main window while Chorus is frontmost,
/// hidden with the app when it isn't.
@MainActor
final class SummaryWindowController: NSObject, NSWindowDelegate {
    static let shared = SummaryWindowController()
    let model = SummaryModel()
    private var panel: NSPanel?
    /// Finished while Chorus wasn't frontmost: come up when the user comes back.
    private var showOnReturn = false

    private override init() {
        super.init()
        // Coming back to Chorus brings up a result that finished meanwhile; it's seen then.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.showOnReturn { self.showOnReturn = false; self.panel?.orderFront(nil) }
                if self.panel?.isVisible == true { self.model.unseen = false }
            }
        }
    }

    /// The user asked for it (Compare, or the composer's "ready" chip): bring it up, key.
    func show() {
        let p = panel ?? makePanel()
        model.unseen = false
        p.makeKeyAndOrderFront(nil)
    }

    /// The comparison finished. Put the window back up — ordered in, not made key, so typing
    /// elsewhere carries on. If Chorus isn't frontmost, a floating panel mustn't appear over
    /// another app: it waits for the user to come back, marked unseen, and a notification says
    /// the result is ready.
    func finished() {
        guard let p = panel else { return }
        if NSApp.isActive {
            p.orderFront(nil)
            model.unseen = false
        } else {
            showOnReturn = true
            model.unseen = true
            CompletionNotifier.shared.postComparisonReady()
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = true
        p.isReleasedWhenClosed = false
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        // The view has its own Stop / Close; the title bar's buttons would sit on its header.
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            p.standardWindowButton(b)?.isHidden = true
        }
        p.minSize = NSSize(width: 460, height: 360)
        p.contentView = NSHostingView(rootView: SummarySheet(
            model: model,
            onClose: { [weak self] in self?.panel?.orderOut(nil) },
            onStop: { [weak self] in self?.model.stop() }))
        p.delegate = self
        p.center()
        p.setFrameAutosaveName("ChorusComparison")   // after center(): a saved frame wins
        panel = p
        return p
    }
}
