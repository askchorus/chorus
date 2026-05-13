import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Generates a meme-flavored Chorus icon: warm gradient + whip-style "C" + 3 colored dots.
// Uses Core Graphics directly so it works in `swift script.swift` without an AppKit run loop.

let sizes: [(filename: String, size: Int)] = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
]

func drawIcon(size: Int) -> Data? {
    let s = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else { return nil }

    // Squircle clip
    let cornerRadius = s * 0.225
    let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(bgPath)
    ctx.clip()

    // Warm sunset gradient (amber → burnt red)
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.96, green: 0.58, blue: 0.22, alpha: 1.0),
            CGColor(red: 0.78, green: 0.22, blue: 0.13, alpha: 1.0),
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: s/2, y: s),
        end: CGPoint(x: s/2, y: 0),
        options: []
    )

    // Whip-style "C": thick arc with a flicked tail
    let center = CGPoint(x: s / 2 + s * 0.02, y: s / 2 + s * 0.05)
    let radius = s * 0.30
    let lineWidth = s * 0.13

    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // CG arc angles in radians, default counterclockwise=false means clockwise in CG's flipped coords
    // We want a C opening to the right: arc from ~50° around through top, left, bottom to ~310°
    let startAngle = CGFloat(50.0 * .pi / 180.0)
    let endAngle = CGFloat(310.0 * .pi / 180.0)
    ctx.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
    ctx.strokePath()

    // Tail/flick at bottom right
    let tailStart = CGPoint(
        x: center.x + radius * cos(endAngle),
        y: center.y + radius * sin(endAngle)
    )
    let tailEnd = CGPoint(x: tailStart.x + s * 0.20, y: tailStart.y - s * 0.06)
    let tailC1 = CGPoint(x: tailStart.x + s * 0.08, y: tailStart.y - s * 0.10)
    let tailC2 = CGPoint(x: tailEnd.x - s * 0.03, y: tailEnd.y - s * 0.03)

    ctx.setLineWidth(lineWidth * 0.55)
    ctx.move(to: tailStart)
    ctx.addCurve(to: tailEnd, control1: tailC1, control2: tailC2)
    ctx.strokePath()

    // Three colored dots = the 3 AIs being conducted (with white rings for contrast)
    let dotY = s * 0.18
    let dotRadius = s * 0.055
    let ringExtra = s * 0.012
    let dotColors: [CGColor] = [
        CGColor(red: 0.06, green: 0.64, blue: 0.50, alpha: 1.0), // ChatGPT-ish green
        CGColor(red: 0.85, green: 0.46, blue: 0.30, alpha: 1.0), // Claude-ish orange
        CGColor(red: 0.26, green: 0.52, blue: 0.96, alpha: 1.0), // Gemini-ish blue
    ]
    let dotSpacing = s * 0.165
    let startX = s / 2 - dotSpacing

    for (i, color) in dotColors.enumerated() {
        let x = startX + CGFloat(i) * dotSpacing
        // Ring
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(
            x: x - dotRadius - ringExtra,
            y: dotY - dotRadius - ringExtra,
            width: (dotRadius + ringExtra) * 2,
            height: (dotRadius + ringExtra) * 2
        ))
        // Dot
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(
            x: x - dotRadius,
            y: dotY - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        ))
    }

    guard let cgImage = ctx.makeImage() else { return nil }

    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Chorus.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

for (filename, size) in sizes {
    guard let data = drawIcon(size: size) else {
        FileHandle.standardError.write("Failed: \(filename)\n".data(using: .utf8)!)
        continue
    }
    let path = "\(outputDir)/\(filename)"
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("✓ \(path)")
    } catch {
        FileHandle.standardError.write("Write failed \(path): \(error)\n".data(using: .utf8)!)
    }
}
