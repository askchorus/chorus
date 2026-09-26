import SwiftUI
import AppKit
import CoreGraphics

/// Shared visual tokens. The main window is a native split view: panes edge to edge on one
/// surface in the pages' own colour, split by hairlines.
enum ChorusTheme {
    /// Brand accents shared by the share card, welcome card, and future branded surfaces.
    /// (scripts/dmg-background.swift mirrors these as CGColor — it can't import the app module,
    /// so keep them in sync by hand.)
    static let brandOrange = Color(red: 0.86, green: 0.5, blue: 0.26)
    /// The single color of the "won this round" trophy — a warm gold that sits with the cream
    /// palette while still reading as an award at 13pt.
    static let trophyGold = Color(red: 0.83, green: 0.63, blue: 0.16)
    /// Light cream gradient backing branded cards (share card, welcome card).
    static let cardCream: [Color] = [Color(red: 0.988, green: 0.972, blue: 0.937),
                                     Color(red: 0.956, green: 0.925, blue: 0.862)]

    /// Whether the pages get the warm cream tint (Settings, default on).
    static var warmPages: Bool { UserDefaults.standard.object(forKey: "warmWebPages") as? Bool ?? true }

    /// The one surface the window is made of — title strip, pane headers, dividers' ground, the
    /// composer bar — in the colour the pages themselves show, so chrome and content read as a
    /// single sheet. With the warm tint on, a page's white multiplies to exactly the tint's cream
    /// (#f1e9d9); with it off, the sites' own near-white. (A lighter "paper" chrome read as white
    /// strips against the tinted pages; system materials added a cool grey cast.)
    static func chrome(_ scheme: ColorScheme, warm: Bool = ChorusTheme.warmPages) -> Color {
        Color(nsColor: chromeNS(dark: scheme == .dark, warm: warm))
    }
    static func chromeNS(dark: Bool, warm: Bool = ChorusTheme.warmPages) -> NSColor {
        if dark {
            return warm ? NSColor(srgbRed: 0.133, green: 0.125, blue: 0.114, alpha: 1)
                        : NSColor(srgbRed: 0.118, green: 0.118, blue: 0.125, alpha: 1)
        }
        return warm ? NSColor(srgbRed: 0.945, green: 0.914, blue: 0.851, alpha: 1)    // #f1e9d9
                    : NSColor(srgbRed: 0.984, green: 0.980, blue: 0.972, alpha: 1)
    }

    /// 1px lines between panes, under pane headers and above the composer.
    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color(red: 0.149, green: 0.129, blue: 0.102).opacity(0.12)
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
            chromeNS(dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        }
    }

    /// A CONCRETE color for the window background, resolved against the *app's* current
    /// (possibly forced) appearance — NOT the dynamic color's `.cgColor`, which resolves
    /// against the *system* appearance and would pick the dark branch when the system is in
    /// dark mode even though Chorus is forced light. Used for webview backdrops where a
    /// dynamic NSColor isn't reliably resolved (WebKit's `underPageBackgroundColor`, CALayer
    /// backgroundColor).
    static func windowBackgroundColor(warm: Bool = ChorusTheme.warmPages) -> NSColor {
        chromeNS(dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua, warm: warm)
    }
    static func windowBackgroundCGColor() -> CGColor { windowBackgroundColor().cgColor }
}

/// The 1pt line between panes, under a pane's header and above the composer — the only
/// structure the split view draws (warm ink, as in the film, rather than neutral black).
struct PaneDivider: View {
    let vertical: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(ChorusTheme.hairline(scheme))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
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


/// A tiny drawing of a window split into panes — the shape the picker actually produces.
/// Drawn rather than taken from SF Symbols: the symbol set has no connected 3x2, and its
/// `square.grid.*` glyphs are DETACHED squares, which read as "a bunch of things" (a launcher)
/// instead of "one window divided into panes".
struct LayoutGlyph: View {
    let cols: Int
    let rows: Int
    var side: CGFloat = 15
    var lineWidth: CGFloat = 1.2

    var body: some View {
        let w = side
        let h = side * 0.8
        Path { path in
            let r = CGRect(x: lineWidth / 2, y: lineWidth / 2, width: w - lineWidth, height: h - lineWidth)
            path.addRoundedRect(in: r, cornerSize: CGSize(width: 2.5, height: 2.5))
            for i in 1 ..< max(cols, 1) {
                let x = r.minX + r.width * CGFloat(i) / CGFloat(cols)
                path.move(to: CGPoint(x: x, y: r.minY))
                path.addLine(to: CGPoint(x: x, y: r.maxY))
            }
            for i in 1 ..< max(rows, 1) {
                let y = r.minY + r.height * CGFloat(i) / CGFloat(rows)
                path.move(to: CGPoint(x: r.minX, y: y))
                path.addLine(to: CGPoint(x: r.maxX, y: y))
            }
        }
        .stroke(style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
        .frame(width: w, height: h)
    }
}
