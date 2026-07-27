import SwiftUI
import AppKit
import CoreGraphics

/// Shared visual tokens for the Arc-style main window: floating webview "cards" on a soft
/// neutral canvas, generous rounding, consistent spacing.
enum ChorusTheme {
    static let cardRadius: CGFloat = 12
    static let gap: CGFloat = 12
    static let margin: CGFloat = 14

    /// Brand accents shared by the share card, welcome card, and future branded surfaces.
    /// (scripts/dmg-background.swift mirrors these as CGColor — it can't import the app module,
    /// so keep them in sync by hand.)
    static let brandOrange = Color(red: 0.86, green: 0.5, blue: 0.26)
    /// Light cream gradient backing branded cards (share card, welcome card).
    static let cardCream: [Color] = [Color(red: 0.988, green: 0.972, blue: 0.937),
                                     Color(red: 0.956, green: 0.925, blue: 0.862)]

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

/// Keeps the title bar transparent for the immersive, hidden-title-bar look.
/// isMovableByWindowBackground must stay FALSE: the main composer is a SwiftUI multiline
/// TextField, which is not an AppKit text control — with background-dragging on, AppKit treated
/// click-drags inside it as "move the window" and text selection was impossible. Window dragging
/// is provided explicitly by WindowDragHandle on the top strip instead.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.isMovableByWindowBackground = false
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.backgroundColor = ChorusTheme.windowBackground
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// An explicit window-drag area (the top strip): press-and-drag moves the window, double-click
/// performs the standard titlebar zoom/minimize action. Replaces whole-window background dragging,
/// which broke text selection in the SwiftUI composer.
struct WindowDragHandle: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

