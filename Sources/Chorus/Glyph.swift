import AppKit

/// The app-icon "circle character" (two dot eyes) rendered as a single-color glyph — the brand
/// mark, reused for the menu-bar icon and the quick-input leading slot so they echo the app icon.
/// Drawn in code (crisp at any size, no bundled assets) and returned as a template image so the
/// menu bar tints it for light/dark bars.
///
/// `filled` = solid disc with knocked-out (transparent) eyes — bold, survives 16px.
/// else = line-art outline with solid dot eyes — matches the app icon's stroke style.
enum ChorusGlyph {
    /// `singing` opens its mouth (the menu bar shows this while an AI is answering).
    static func circle(size: CGFloat, filled: Bool = true, singing: Bool = false, template: Bool = true) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(ctx, box: rect, filled: filled, singing: singing)
            return true
        }
        img.isTemplate = template
        return img
    }

    private static func draw(_ ctx: CGContext, box: CGRect, filled: Bool, singing: Bool) {
        let s = box.width
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Raise the body to leave room for the feet, but keep the body+feet group vertically
        // centered in the box (top margin ≈ bottom margin) so the menu bar doesn't render it high.
        let d = s * 0.66
        let cx = box.midX
        let body = CGRect(x: cx - d / 2, y: box.maxY - s * 0.11 - d, width: d, height: d)

        let eyeR = s * 0.05
        let eyeY = body.midY + s * 0.045
        let eyeDX = s * 0.10
        func addEyes() {
            for ex in [cx - eyeDX, cx + eyeDX] {
                ctx.addEllipse(in: CGRect(x: ex - eyeR, y: eyeY - eyeR, width: eyeR * 2, height: eyeR * 2))
            }
        }

        // Two short rounded feet hanging from the bottom (the circle character has 2 legs in the
        // icon — the wider square has 3, but we're drawing the circle).
        let footW = s * 0.052, footH = s * 0.14, footGap = s * 0.084
        let footTopY = body.minY + s * 0.015          // overlap the body a hair so they connect
        func addFeet() {
            for fx in [cx - footGap, cx + footGap] {
                ctx.addPath(CGPath(roundedRect: CGRect(x: fx - footW / 2, y: footTopY - footH, width: footW, height: footH),
                                   cornerWidth: footW / 2, cornerHeight: footW / 2, transform: nil))
            }
        }

        // The film's singing mouth: an upright oval under the eyes.
        func addMouth() {
            let w = s * 0.11, h = s * 0.13
            ctx.addEllipse(in: CGRect(x: cx - w / 2, y: eyeY - s * 0.085 - h, width: w, height: h))
        }

        if filled {
            ctx.addEllipse(in: body); addFeet()      // body + feet = one solid silhouette
            ctx.setFillColor(black); ctx.fillPath()
            ctx.setBlendMode(.clear); addEyes(); if singing { addMouth() }; ctx.fillPath(); ctx.setBlendMode(.normal)
        } else {
            ctx.addEllipse(in: body); ctx.setStrokeColor(black)
            ctx.setLineWidth(max(1, s * 0.08)); ctx.strokePath()
            ctx.setFillColor(black)
            addFeet(); ctx.fillPath()
            addEyes(); if singing { addMouth() }; ctx.fillPath()
        }
    }
}
