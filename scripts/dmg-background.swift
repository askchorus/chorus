import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Render the DMG window background: a warm cream gradient, the "Chorus" wordmark, a one-line
// install hint, and an arrow pointing from the app icon slot toward the Applications slot.
// CoreGraphics + CoreText only (AppKit drawing fails in headless `swift script` context).
// NOTE: gradient + orange mirror ChorusTheme.cardCream / .brandOrange (Sources/Chorus/Theme.swift);
// this script can't import the app module, so keep the values in sync by hand.
// Usage: swift dmg-background.swift <out.png>   (defaults to /tmp/chorus-dmg-bg.png)

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/chorus-dmg-bg.png"
let W = 640, H = 400
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Warm cream gradient (CG origin is bottom-left): deeper at the bottom, lighter at the top.
let grad = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.970, green: 0.938, blue: 0.874, alpha: 1),   // bottom
    CGColor(red: 0.992, green: 0.979, blue: 0.951, alpha: 1),   // top
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CGFloat(H)), options: [])

// Centered text helper (baselineY in CG bottom-left coords).
func draw(_ s: String, fontName: String, size: CGFloat, color: CGColor, centerX: CGFloat, baselineY: CGFloat) {
    let font = CTFontCreateWithName(fontName as CFString, size, nil)
    let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
    let attr = CFAttributedStringCreate(nil, s as CFString, attrs)!
    let line = CTLineCreateWithAttributedString(attr)
    var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
    let w = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead))
    ctx.textPosition = CGPoint(x: centerX - w / 2, y: baselineY)
    CTLineDraw(line, ctx)
}

let cx = CGFloat(W) / 2
// Wordmark + install hint near the top.
draw("Chorus", fontName: "AvenirNext-Bold", size: 40,
     color: CGColor(red: 0.224, green: 0.184, blue: 0.149, alpha: 1),
     centerX: cx, baselineY: CGFloat(H) - 82)
draw("把 Chorus 拖进 Applications 即可安装", fontName: "PingFangSC-Medium", size: 15.5,
     color: CGColor(red: 0.46, green: 0.40, blue: 0.33, alpha: 0.95),
     centerX: cx, baselineY: CGFloat(H) - 114)

// Arrow between the two icon slots. Icons are centered by Finder at image-y≈215 → CG y = 400-215.
let arrowY: CGFloat = CGFloat(H) - 215
let orange = CGColor(red: 0.847, green: 0.506, blue: 0.247, alpha: 1)
ctx.setStrokeColor(orange); ctx.setFillColor(orange)
ctx.setLineWidth(5); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 262, y: arrowY)); ctx.addLine(to: CGPoint(x: 372, y: arrowY)); ctx.strokePath()
ctx.move(to: CGPoint(x: 372, y: arrowY + 11))
ctx.addLine(to: CGPoint(x: 393, y: arrowY))
ctx.addLine(to: CGPoint(x: 372, y: arrowY - 11))
ctx.closePath(); ctx.fillPath()

let img = ctx.makeImage()!
let data = NSMutableData()
let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
try? (data as Data).write(to: URL(fileURLWithPath: outPath))
print("✓ dmg background -> \(outPath)")
