import SwiftUI
import AppKit
import CoreText

// The Chorus look, in code: the promo film's ink line, its three characters and its small props
// (trophy, sparkle, note, send button), ported from promo/promo.html so the app, the film and the
// landing page draw with one hand. Everything is drawn — no image assets, crisp at any size.
//
// Units are the film's: a character stands on its feet at (0, 0), about 230 units tall. Views
// scale that to whatever frame they get and thicken lines/eyes at small sizes so a 20pt status
// character still reads.

// MARK: - Palette

enum Ink {
    /// #26211a — the film's line and text colour.
    static let ink = Color(red: 0.149, green: 0.129, blue: 0.102)
    /// #FFFCF6 — the film's character / card fill.
    static let cream = Color(red: 1.0, green: 0.988, blue: 0.965)
    static let gold = ChorusTheme.trophyGold
    static let orange = ChorusTheme.brandOrange

    /// Line colour for the current appearance: ink on cream, cream on dark.
    static func line(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.93, green: 0.90, blue: 0.85) : ink
    }
    /// Fill behind a drawn outline (a character's body, a key cap).
    static func fill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.19, green: 0.18, blue: 0.17) : cream
    }
}

// MARK: - The film's randomness and "boil"

enum InkNoise {
    /// mulberry32 — the film's PRNG, bit for bit (UInt32 wrapping = JS int32 bit patterns).
    static func mulberry32(_ seed: UInt32) -> () -> Double {
        var a = seed
        return {
            a = a &+ 0x6D2B79F5
            var t = (a ^ (a >> 15)) &* (1 | a)
            t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
            return Double(t ^ (t >> 14)) / 4_294_967_296
        }
    }
    static func rand(_ a: Int, _ b: Int = 0, _ c: Int = 0) -> Double {
        mulberry32(UInt32(truncatingIfNeeded: (a &* 73_856_093) ^ (b &* 19_349_663) ^ (c &* 83_492_791)))()
    }
    static let boilFPS = 10.0
    /// Offset along a contour at u ∈ [0, 1): low-frequency wobble, re-drawn 10×/s as t advances
    /// (t = 0 gives one fixed, hand-drawn-looking wobble).
    static func contour(_ id: Int, _ t: Double, _ amp: CGFloat) -> (CGFloat) -> CGFloat {
        let b = Int(floor(t * boilFPS)), tau = 2 * CGFloat.pi
        let p1 = CGFloat(rand(id, b, 1)) * tau, p2 = CGFloat(rand(id, b, 2)) * tau, p3 = CGFloat(rand(id, b, 3)) * tau
        return { u in amp * (0.55 * sin(tau * 2 * u + p1) + 0.3 * sin(tau * 3 * u + p2) + 0.15 * sin(tau * 5 * u + p3)) }
    }
}

// MARK: - Contours

enum InkGeometry {
    struct Pt { var x, y, nx, ny: CGFloat }

    static func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, n: Int = 96) -> [Pt] {
        (0..<n).map { i in
            let a = -CGFloat.pi / 2 + CGFloat(i) / CGFloat(n) * 2 * .pi
            return Pt(x: cx + r * cos(a), y: cy + r * sin(a), nx: cos(a), ny: sin(a))
        }
    }

    /// Rounded polygon, vertices clockwise on screen (y down); handles reflex corners.
    static func roundedPoly(_ vs: [CGPoint], _ rs: [CGFloat], n: Int = 110) -> [Pt] {
        struct Corner { let c: CGPoint; let r, a1, sweep: CGFloat; let t1, t2: CGPoint; let reflex: Bool }
        let m = vs.count
        var corners: [Corner] = []
        for i in 0..<m {
            let P = vs[(i - 1 + m) % m], V = vs[i], N = vs[(i + 1) % m]
            var ax = P.x - V.x, ay = P.y - V.y; let al = hypot(ax, ay); ax /= al; ay /= al
            var bx = N.x - V.x, by = N.y - V.y; let bl = hypot(bx, by); bx /= bl; by /= bl
            let theta = acos(max(-1, min(1, ax * bx + ay * by)))
            let r = min(rs[i], 0.45 * min(al, bl) * tan(theta / 2))
            let d = r / tan(theta / 2), cd = r / sin(theta / 2)
            var hx = ax + bx, hy = ay + by; let hl = hypot(hx, hy) == 0 ? 1 : hypot(hx, hy); hx /= hl; hy /= hl
            let c = CGPoint(x: V.x + hx * cd, y: V.y + hy * cd)
            let t1 = CGPoint(x: V.x + ax * d, y: V.y + ay * d), t2 = CGPoint(x: V.x + bx * d, y: V.y + by * d)
            let reflex = (V.x - P.x) * (N.y - V.y) - (V.y - P.y) * (N.x - V.x) < 0
            let a1 = atan2(t1.y - c.y, t1.x - c.x)
            var sweep = atan2(t2.y - c.y, t2.x - c.x) - a1
            while sweep > .pi { sweep -= 2 * .pi }
            while sweep < -.pi { sweep += 2 * .pi }
            corners.append(Corner(c: c, r: r, a1: a1, sweep: sweep, t1: t1, t2: t2, reflex: reflex))
        }
        enum Piece { case arc(Corner), line(CGPoint, CGPoint) }
        var pieces: [(Piece, CGFloat)] = []
        for i in 0..<m {
            let k = corners[i], nk = corners[(i + 1) % m]
            pieces.append((.arc(k), abs(k.sweep) * k.r))
            pieces.append((.line(k.t2, nk.t1), hypot(nk.t1.x - k.t2.x, nk.t1.y - k.t2.y)))
        }
        let total = pieces.reduce(0) { $0 + $1.1 }
        var pts: [Pt] = []
        for i in 0..<n {
            var d = CGFloat(i) / CGFloat(n) * total
            for (j, (piece, len)) in pieces.enumerated() {
                if d <= len || j == pieces.count - 1 {
                    let f = len > 0 ? max(0, min(1, d / len)) : 0
                    switch piece {
                    case .arc(let k):
                        let a = k.a1 + k.sweep * f, s: CGFloat = k.reflex ? -1 : 1
                        pts.append(Pt(x: k.c.x + k.r * cos(a), y: k.c.y + k.r * sin(a), nx: s * cos(a), ny: s * sin(a)))
                    case .line(let a, let b):
                        let ex = b.x - a.x, ey = b.y - a.y, el = max(hypot(ex, ey), 0.0001)
                        pts.append(Pt(x: a.x + ex * f, y: a.y + ey * f, nx: ey / el, ny: -ex / el))
                    }
                    break
                }
                d -= len
            }
        }
        return pts
    }

    static func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, n: Int = 110) -> [Pt] {
        roundedPoly([CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)],
                    [r, r, r, r], n: n)
    }

    /// A closed contour pushed in/out along its normals by the boil, as one smooth path.
    static func contourPath(_ pts: [Pt], id: Int, t: Double, amp: CGFloat) -> Path {
        let off = amp > 0 ? InkNoise.contour(id, t, amp) : nil, n = pts.count
        let q = pts.enumerated().map { k, p -> CGPoint in
            let d = off?(CGFloat(k) / CGFloat(n)) ?? 0
            return CGPoint(x: p.x + p.nx * d, y: p.y + p.ny * d)
        }
        func mid(_ i: Int) -> CGPoint { let a = q[i], b = q[(i + 1) % n]; return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        var path = Path()
        path.move(to: mid(n - 1))
        for i in 0..<n { path.addQuadCurve(to: mid(i), control: q[i]) }
        path.closeSubpath()
        return path
    }
}

// MARK: - The characters

/// Circle, square, triangle — the app icon's line-up — and, for panels four to six, three more
/// drawn the same way (a loaf, a pill, a diamond) so no two on-screen panels share one.
enum InkCast: Int, CaseIterable {
    case circle, square, triangle, loaf, pill, diamond
    /// The film's and the icon's trio (line-ups, the welcome sheet, the share card).
    static let trio: [InkCast] = [.circle, .square, .triangle]
    static func forPanel(_ index: Int) -> InkCast { InkCast(rawValue: ((index % 6) + 6) % 6) ?? .circle }

    static let leg: CGFloat = 34
    var bodySize: CGSize {
        switch self {
        case .circle: return CGSize(width: 196, height: 196)
        case .square: return CGSize(width: 186, height: 178)
        case .triangle: return CGSize(width: 208, height: 184)
        case .loaf: return CGSize(width: 206, height: 150)
        case .pill: return CGSize(width: 128, height: 206)
        case .diamond: return CGSize(width: 200, height: 188)
        }
    }
    var height: CGFloat { Self.leg + bodySize.height }
    fileprivate var eyeY: CGFloat {
        [-Self.leg - 102, -Self.leg - 87, -Self.leg - 184 * 0.32, -Self.leg - 75, -Self.leg - 120, -Self.leg - 94][rawValue]
    }
    fileprivate var eyeDX: CGFloat { [15, 15, 14, 16, 12, 14][rawValue] }
    fileprivate var legDX: CGFloat { [16, 16, 18, 18, 14, 10][rawValue] }
    fileprivate var contour: [InkGeometry.Pt] { Self.contours[rawValue] }
    private static let contours: [[InkGeometry.Pt]] = InkCast.allCases.map { c in
        let b = c.bodySize, top = -leg - b.height, bot = -leg
        switch c {
        case .circle: return InkGeometry.circle(0, -leg - b.height / 2, b.height / 2, n: 96)
        case .square: return InkGeometry.rrect(-b.width / 2, top, b.width, b.height, 36, n: 120)
        case .triangle:
            return InkGeometry.roundedPoly([CGPoint(x: 0, y: top), CGPoint(x: b.width / 2, y: bot), CGPoint(x: -b.width / 2, y: bot)],
                                           [34, 22, 22], n: 110)
        case .loaf:      // rounded shoulders, flat feet
            return InkGeometry.roundedPoly([CGPoint(x: -b.width / 2, y: top), CGPoint(x: b.width / 2, y: top),
                                            CGPoint(x: b.width / 2, y: bot), CGPoint(x: -b.width / 2, y: bot)],
                                           [96, 96, 20, 20], n: 120)
        case .pill:
            return InkGeometry.rrect(-b.width / 2, top, b.width, b.height, 64, n: 120)
        case .diamond:   // the bottom vertex sits low enough that its rounding just meets the legs
            let low = bot + 11.6, high = low - 200
            return InkGeometry.roundedPoly([CGPoint(x: 0, y: high), CGPoint(x: 100, y: high + 100),
                                            CGPoint(x: 0, y: low), CGPoint(x: -100, y: high + 100)],
                                           [28, 24, 28, 24], n: 120)
        }
    }
}

/// How a character looks at one instant (the film's charState, trimmed to what the app uses).
struct InkPose: Equatable {
    var eye: CGFloat = 1            // 1 open … 0.14 shut
    var happy = false               // ^ ^ eyes
    var mouth: CGFloat = 0          // 0 closed … 1 singing wide
    var lookX: CGFloat = 0          // −1 … 1
    var lookY: CGFloat = 0
    var hop: CGFloat = 0            // film units off the ground
    var squash: CGFloat = 0
    var rot: CGFloat = 0

    /// Mid-song: mouth opening and closing, a small bounce.
    static func singing(_ t: Double, phase: Double = 0) -> InkPose {
        let s = t * 2 * .pi
        return InkPose(mouth: 0.55 + 0.35 * CGFloat(sin(s * 2.6 + phase)),
                       hop: 5 * CGFloat(abs(sin(s * 1.3 + phase))),
                       squash: 0.025 * CGFloat(sin(s * 2.6 + phase)))
    }
}

enum InkDraw {
    /// Draws one character with its feet at (0, 0) in the context's current (film-unit) space.
    /// `boost` thickens line, eyes and mouth for small renders.
    static func character(_ gc: GraphicsContext, _ kind: InkCast, _ p: InkPose, t: Double,
                          line: Color, fill: Color, boost: CGFloat = 1, shadow: Bool = false, amp: CGFloat = 1.4) {
        let lw = 11 * boost
        if shadow {
            let k = 1 - min(1, p.hop / 110) * 0.55
            gc.fill(Path(ellipseIn: CGRect(x: -74 * k, y: 5 - 9 * k, width: 148 * k, height: 18 * k)),
                    with: .color(line.opacity(0.08)))
        }
        var c = gc
        c.translateBy(x: 0, y: -p.hop)
        c.rotate(by: .radians(Double(p.rot)))
        c.scaleBy(x: 1 + p.squash * 0.7, y: 1 - p.squash)
        let id = 100 + kind.rawValue * 10, tuck = min(1, max(0, p.hop / 40)) * 9
        let b = Int(floor(t * InkNoise.boilFPS))
        for side: CGFloat in [-1, 1] {   // legs: a slightly bowed stroke each, like the film's wline
            let lid = id + (side < 0 ? 1 : 2), j = { (k: Int) in CGFloat(InkNoise.rand(lid, b, k) - 0.5) * 1.6 }
            let a = CGPoint(x: side * kind.legDX + j(1) * 0.4, y: -InkCast.leg + 6 + j(2) * 0.4)
            let e = CGPoint(x: side * kind.legDX + j(3) * 0.4, y: -tuck + j(4) * 0.4)
            var leg = Path()
            leg.move(to: a)
            leg.addQuadCurve(to: e, control: CGPoint(x: (a.x + e.x) / 2 + j(5), y: (a.y + e.y) / 2 + j(6)))
            c.stroke(leg, with: .color(line), style: StrokeStyle(lineWidth: lw, lineCap: .round))
        }
        let body = InkGeometry.contourPath(kind.contour, id: id, t: t, amp: amp)
        c.fill(body, with: .color(fill))
        c.stroke(body, with: .color(line), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))

        // At icon sizes the boosted eyes would touch and the mouth would run into them: spread the
        // eyes, drop the mouth, and lift the triangle's face (its body narrows toward the top).
        let small = boost - 1
        let eyeDX = kind.eyeDX * (1 + small * 0.75)
        let eyeY = kind.eyeY - small * (kind == .triangle ? 20 : 6)
        let ex = p.lookX * 6, ey = p.lookY * 7
        if p.happy {
            for side: CGFloat in [-1, 1] {   // ∩ ∩ — the film's arcs from 1.12π to 1.88π, as a curve
                let cx = side * eyeDX + ex, cy = eyeY + 6 + ey, r = 8 * boost
                var arc = Path()
                arc.move(to: CGPoint(x: cx - r * 0.93, y: cy - r * 0.37))
                arc.addQuadCurve(to: CGPoint(x: cx + r * 0.93, y: cy - r * 0.37), control: CGPoint(x: cx, y: cy - r * 1.63))
                c.stroke(arc, with: .color(line), style: StrokeStyle(lineWidth: 5.5 * boost, lineCap: .round))
            }
        } else {
            let eo = max(0.14, min(1, p.eye))
            for side: CGFloat in [-1, 1] {
                let w = 11 * boost, h = 25 * min(boost, 1.7) * eo
                c.fill(Path(roundedRect: CGRect(x: side * eyeDX - w / 2 + ex, y: eyeY - h / 2 + ey, width: w, height: h),
                            cornerRadius: min(w, h) / 2), with: .color(line))
            }
        }
        if p.mouth > 0.04 {
            let mb = min(boost, 1.6)
            let rx = (4 + 5 * p.mouth) * mb, ry = (2 + 9 * p.mouth) * mb
            c.fill(Path(ellipseIn: CGRect(x: ex * 0.6 - rx, y: eyeY + 32 + small * 24 + ey * 0.5 - ry, width: rx * 2, height: ry * 2)),
                   with: .color(line))
        }
    }

    /// The film's music note, base of the head at (0, 0), in orange.
    static func note(_ gc: GraphicsContext, alpha: Double) {
        guard alpha > 0 else { return }
        var c = gc
        c.opacity = alpha
        var head = c
        head.rotate(by: .radians(-0.35))
        head.fill(Path(ellipseIn: CGRect(x: -13, y: -9.5, width: 26, height: 19)), with: .color(Ink.orange))
        var stem = Path()
        stem.move(to: CGPoint(x: 11, y: -4)); stem.addLine(to: CGPoint(x: 11, y: -46))
        stem.addQuadCurve(to: CGPoint(x: 24, y: -20), control: CGPoint(x: 29, y: -38))
        c.stroke(stem, with: .color(Ink.orange), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
    }

    /// The film's trophy, centred at (0, 0) in a ~104 × 94 box.
    static func trophy(_ gc: GraphicsContext, fill: Color, line: Color, lw: CGFloat = 7) {
        let style = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
        var handles = Path()
        handles.addArc(center: CGPoint(x: -35, y: -22), radius: 15, startAngle: .radians(.pi * 0.5), endAngle: .radians(.pi * 1.5), clockwise: false)
        handles.move(to: CGPoint(x: 35, y: -37))
        handles.addArc(center: CGPoint(x: 35, y: -22), radius: 15, startAngle: .radians(-.pi * 0.5), endAngle: .radians(.pi * 0.5), clockwise: false)
        gc.stroke(handles, with: .color(line), style: style)
        var cup = Path()
        cup.move(to: CGPoint(x: -36, y: -44)); cup.addLine(to: CGPoint(x: 36, y: -44))
        cup.addQuadCurve(to: CGPoint(x: 0, y: 12), control: CGPoint(x: 36, y: 10))
        cup.addQuadCurve(to: CGPoint(x: -36, y: -44), control: CGPoint(x: -36, y: 10))
        cup.closeSubpath()
        gc.fill(cup, with: .color(fill)); gc.stroke(cup, with: .color(line), style: style)
        var stem = Path(); stem.move(to: CGPoint(x: 0, y: 12)); stem.addLine(to: CGPoint(x: 0, y: 28))
        gc.stroke(stem, with: .color(line), style: style)
        let base = Path(roundedRect: CGRect(x: -22, y: 28, width: 44, height: 14), cornerRadius: 5)
        gc.fill(base, with: .color(fill)); gc.stroke(base, with: .color(line), style: style)
    }

    /// The film's four-point sparkle (the "✦" of Compare), radius r at (x, y).
    static func sparklePath(center: CGPoint, r: CGFloat) -> Path {
        var p = Path()
        for k in 0..<4 {
            let a = CGFloat(k) / 4 * 2 * .pi - .pi / 2, b = a + .pi / 4
            let outer = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
            let inner = CGPoint(x: center.x + cos(b) * r * 0.32, y: center.y + sin(b) * r * 0.32)
            if k == 0 { p.move(to: outer) } else { p.addLine(to: outer) }
            p.addLine(to: inner)
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - Views

/// One character, drawn to fit its frame. `t` moves the boil (0 = still).
struct InkCharacter: View {
    let kind: InkCast
    var pose = InkPose()
    var t: Double = 0
    var shadow = false
    @Environment(\.colorScheme) private var scheme

    /// Each character fills its own frame — side by side in panel headers they should read as the
    /// same size. (A shared box kept the icon's line-up proportions, where the circle is biggest
    /// and the triangle smallest; that belongs to InkLineup, not to single characters.)
    static func box(_ kind: InkCast) -> CGRect {
        let w = kind.bodySize.width, h = kind.height
        return CGRect(x: -w / 2 - 12, y: -h - 20, width: w + 24, height: h + 36)
    }
    /// Pointed and narrow shapes carry less ink than a circle at the same height; nudge them up so
    /// the set looks even.
    static func optical(_ kind: InkCast) -> CGFloat {
        switch kind {
        case .triangle: return 1.1
        case .diamond: return 1.06
        case .square: return 0.97
        default: return 1
        }
    }

    var body: some View {
        Canvas { gc, size in
            let box = Self.box(kind)
            let k = min(size.width / box.width, size.height / box.height) * Self.optical(kind)
            var c = gc
            c.translateBy(x: size.width / 2 - box.midX * k, y: size.height / 2 - box.midY * k)
            c.scaleBy(x: k, y: k)
            InkDraw.character(c, kind, pose, t: t, line: Ink.line(scheme), fill: Ink.fill(scheme),
                              boost: InkCharacter.boost(scale: k), shadow: shadow)
        }
        .accessibilityHidden(true)
    }

    /// Thicker line and bigger eyes below ~60pt, so a 20pt character keeps a 1.5pt line.
    static func boost(scale k: CGFloat) -> CGFloat { max(1, min(2.2, 1.5 / (11 * k))) }
}

/// A panel's status character: still while idle, singing while its AI streams an answer, ^ ^ for
/// a moment when it finishes. Only the singing state animates, so idle panels cost nothing.
struct PanelStatusCharacter: View {
    let kind: InkCast
    let singing: Bool
    let answered: Bool
    @State private var happyUntil: Date?

    var body: some View {
        Group {
            if singing {
                TimelineView(.periodic(from: .now, by: 1.0 / 12)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    InkCharacter(kind: kind, pose: .singing(t, phase: Double(kind.rawValue)), t: t)
                }
            } else {
                InkCharacter(kind: kind, pose: InkPose(happy: happyUntil.map { $0 > Date() } ?? false))
            }
        }
        .onChange(of: singing) { now in
            guard !now, answered else { return }
            let until = Date().addingTimeInterval(2.6)
            happyUntil = until
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.7) { if happyUntil == until { happyUntil = nil } }
        }
    }
}

/// The app-icon line-up — circle, square, triangle overlapping — drawn live.
/// `hello` hops them in turn once on appear; `thinking` bounces dots over their heads.
struct InkLineup: View {
    var poses: [InkPose] = [InkPose(), InkPose(), InkPose()]
    var hello = false
    var thinking = false
    var singing = false
    @Environment(\.colorScheme) private var scheme
    @State private var start = Date()

    private static let feet: [CGFloat] = [806, 960, 1114]
    private static let view = CGRect(x: 630, y: 300, width: 670, height: 392)   // as on the landing page
    private static let groundY: CGFloat = 664, scale: CGFloat = 1.18

    var body: some View {
        let animated = hello || thinking || singing
        Group {
            if animated {
                TimelineView(.periodic(from: .now, by: 1.0 / 24)) { ctx in
                    canvas(t: ctx.date.timeIntervalSince(start))
                }
            } else {
                canvas(t: 0)
            }
        }
        .aspectRatio(Self.view.width / Self.view.height, contentMode: .fit)
        .onAppear { start = Date() }
        .accessibilityHidden(true)
    }

    private func canvas(t: Double) -> some View {
        Canvas { gc, size in
            let k = min(size.width / Self.view.width, size.height / Self.view.height)
            var c = gc
            c.translateBy(x: (size.width - Self.view.width * k) / 2 - Self.view.minX * k,
                          y: (size.height - Self.view.height * k) / 2 - Self.view.minY * k)
            c.scaleBy(x: k, y: k)
            let boost = InkCharacter.boost(scale: k * Self.scale)
            for kind in InkCast.trio {
                var p = poses[kind.rawValue]
                if hello {   // one hop each, in turn, like the film's pop-in
                    let t0 = 0.25 + Double(kind.rawValue) * 0.14, u = max(0, min(1, (t - t0) / 0.32))
                    p.hop += 24 * CGFloat(4 * u * (1 - u))
                    if t < t0 + 1.4 && t > t0 + 0.1 { p.happy = true }
                }
                if singing { let s = InkPose.singing(t, phase: Double(kind.rawValue) * 0.9); p.mouth = s.mouth; p.hop += s.hop }
                var cc = c
                cc.translateBy(x: Self.feet[kind.rawValue], y: Self.groundY)
                cc.scaleBy(x: Self.scale, y: Self.scale)
                InkDraw.character(cc, kind, p, t: thinking || singing ? t : 0, line: Ink.line(scheme), fill: Ink.fill(scheme),
                                  boost: boost, shadow: true)
                if thinking {   // three dots over each head, the film's "thinking…"
                    for d in 0..<3 {
                        let phase = t * 2.2 + Double(d) * 0.33 + Double(kind.rawValue) * 0.5
                        let y = -kind.height - 40 + 6 * CGFloat(sin(phase * 2 * .pi))
                        cc.fill(Path(ellipseIn: CGRect(x: -34 + CGFloat(d) * 34 - 9, y: y - 9, width: 18, height: 18)),
                                with: .color(Ink.line(scheme).opacity(0.8)))
                    }
                }
                if singing {   // a note drifting up beside each singer
                    let q = (t * 0.55 + Double(kind.rawValue) * 0.33).truncatingRemainder(dividingBy: 1)
                    var nc = cc
                    let side: CGFloat = kind == .circle ? -1 : 1
                    nc.translateBy(x: side * (118 + 22 * CGFloat(q)), y: -kind.height + 64 - 96 * CGFloat(1 - pow(1 - q, 3)))
                    InkDraw.note(nc, alpha: min(1, q / 0.12) * (1 - max(0, (q - 0.55) / 0.45)))
                }
            }
        }
    }
}

/// The trophy as an icon: outline when not chosen, gold when it is.
struct TrophyGlyph: View {
    var won = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { gc, size in
            let k = min(size.width / 112, size.height / 102)
            var c = gc
            c.translateBy(x: size.width / 2, y: size.height / 2 + 2 * k)
            c.scaleBy(x: k, y: k)
            // Same line and fill as the characters beside it, so it reads as one of the cast's
            // props rather than a system icon; gold once it's awarded.
            InkDraw.trophy(c, fill: won ? Ink.gold : Ink.fill(scheme), line: Ink.line(scheme), lw: max(8, 1.6 / k))
        }
        .aspectRatio(112 / 102, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The film's "✦".
struct SparkleGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        InkDraw.sparklePath(center: CGPoint(x: rect.midX, y: rect.midY), r: min(rect.width, rect.height) / 2)
    }
}

/// The film's send button: an orange disc with a cream arrow; grey when there's nothing to send.
struct InkSendButtonLabel: View {
    var enabled: Bool
    var size: CGFloat = 30
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { gc, sz in
            let r = min(sz.width, sz.height) / 2, k = r / 23
            gc.fill(Path(ellipseIn: CGRect(x: sz.width / 2 - r, y: sz.height / 2 - r, width: r * 2, height: r * 2)),
                    with: .color(enabled ? Ink.orange : Ink.line(scheme).opacity(0.16)))
            var c = gc
            c.translateBy(x: sz.width / 2, y: sz.height / 2)
            c.scaleBy(x: k, y: k)
            var arrow = Path()
            arrow.move(to: CGPoint(x: 0, y: 10)); arrow.addLine(to: CGPoint(x: 0, y: -9))
            arrow.move(to: CGPoint(x: -8, y: -1)); arrow.addLine(to: CGPoint(x: 0, y: -9)); arrow.addLine(to: CGPoint(x: 8, y: -1))
            c.stroke(arrow, with: .color(enabled ? Ink.cream : Ink.line(scheme).opacity(0.45)),
                     style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The composer's chips share one shape: a capsule — cream with a faint ink edge for "…",
/// layout and mic; orange for "✦ 汇总".
struct InkChipBackground: ViewModifier {
    var orange = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(orange ? Ink.orange.opacity(0.12)
                                              : Ink.fill(scheme).opacity(scheme == .dark ? 0.55 : 0.92)))
            .overlay(Capsule().strokeBorder(orange ? Ink.orange.opacity(0.32) : Ink.line(scheme).opacity(0.18)))
    }
}

extension View {
    func inkChip(orange: Bool = false) -> some View { modifier(InkChipBackground(orange: orange)) }
}

/// Images for AppKit-rendered menu labels (which keep only an image and a string).
enum InkImages {
    /// "…" as three ink dots — the film's thinking dots. Template: follows light / dark.
    static let dots: NSImage = {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            NSColor.black.setFill()
            for x in [3.2, 8.0, 12.8] as [CGFloat] { NSBezierPath(ovalIn: NSRect(x: x - 1.8, y: 6.2, width: 3.6, height: 3.6)).fill() }
            return true
        }
        img.isTemplate = true
        return img
    }()

    /// The film's orange "✦".
    static let sparkle: NSImage = {
        let img = NSImage(size: NSSize(width: 13, height: 13), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(InkDraw.sparklePath(center: CGPoint(x: rect.midX, y: rect.midY), r: 6.3).cgPath)
            ctx.setFillColor(NSColor(ChorusTheme.brandOrange).cgColor)
            ctx.fillPath()
            return true
        }
        img.isTemplate = false
        return img
    }()
}

/// A microphone in the ink line; orange (and filled) while listening.
struct InkMicGlyph: View {
    var recording = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { gc, size in
            let k = min(size.width, size.height) / 20
            var c = gc
            c.translateBy(x: size.width / 2, y: size.height / 2)
            c.scaleBy(x: k, y: k)
            let color = recording ? Ink.orange : Ink.line(scheme)
            let style = StrokeStyle(lineWidth: max(1.7, 1.3 / k), lineCap: .round, lineJoin: .round)
            let capsule = Path(roundedRect: CGRect(x: -3.4, y: -8.2, width: 6.8, height: 11.6), cornerRadius: 3.4)
            if recording { c.fill(capsule, with: .color(color)) }
            c.stroke(capsule, with: .color(color), style: style)
            var stand = Path()
            stand.move(to: CGPoint(x: -6.4, y: -1.2))
            stand.addQuadCurve(to: CGPoint(x: 6.4, y: -1.2), control: CGPoint(x: 0, y: 11.6))
            stand.move(to: CGPoint(x: 0, y: 5.2)); stand.addLine(to: CGPoint(x: 0, y: 8.6))
            stand.move(to: CGPoint(x: -3.4, y: 8.6)); stand.addLine(to: CGPoint(x: 3.4, y: 8.6))
            c.stroke(stand, with: .color(color), style: style)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Type

/// The film's type voice for app chrome: SF Rounded for Latin, and for Chinese the rounded face
/// the landing page uses — Resource Han Rounded (SIL OFL 1.1), cut down to the characters in the
/// app's own strings and renamed "Chorus Round" (scripts/build-ui-font.py; build-app.sh bundles
/// it). Characters outside that set, or a build without the font, fall back to PingFang.
/// Content — answers, summaries, what the user types — stays in the system text face.
enum ChorusFont {
    private static let faces = ["ChorusRound-Medium", "ChorusRound-Bold"]

    /// Registers the bundled faces for this process. Safe to call more than once.
    static func register(from directory: URL? = nil) {
        for name in faces {
            let url = directory?.appendingPathComponent(name + ".ttf") ?? Bundle.main.url(forResource: name, withExtension: "ttf")
            guard let url, NSFont(name: name, size: 12) == nil else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    private static var cache: [String: NSFont] = [:]

    static func nsFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let key = "\(size)/\(weight.rawValue)"
        if let f = cache[key] { return f }
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        var descriptor = system.fontDescriptor.withDesign(.rounded) ?? system.fontDescriptor
        if weight.rawValue >= NSFont.Weight.medium.rawValue {
            let cjk = weight.rawValue >= NSFont.Weight.semibold.rawValue ? faces[1] : faces[0]
            if NSFont(name: cjk, size: size) != nil {
                descriptor = descriptor.addingAttributes([.cascadeList: [NSFontDescriptor(name: cjk, size: size)]])
            }
        }
        let font = NSFont(descriptor: descriptor, size: size) ?? system
        cache[key] = font
        return font
    }
}

extension Font {
    /// Chrome text in the Chorus voice (see ChorusFont).
    static func chorus(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let w: NSFont.Weight
        switch weight {
        case .ultraLight: w = .ultraLight
        case .thin: w = .thin
        case .light: w = .light
        case .medium: w = .medium
        case .semibold: w = .semibold
        case .bold: w = .bold
        case .heavy: w = .heavy
        case .black: w = .black
        default: w = .regular
        }
        return Font(ChorusFont.nsFont(size: size, weight: w))
    }
}
