import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Turn an AI-generated icon mockup (art on a cream square, possibly with white margin + baked
// shadow) into a clean macOS iconset: crop out the margin, re-clip to a standard squircle with
// transparent corners, and emit every required size.
// Usage: swift process-icon.swift <input.png> <output.iconset dir>

guard CommandLine.arguments.count >= 3 else { FileHandle.standardError.write("need <in> <outdir>\n".data(using: .utf8)!); exit(1) }
let inPath = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let cs = CGColorSpaceCreateDeviceRGB()
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: inPath) as CFURL, nil)!
let full = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let W = full.width, H = full.height

// Crop the centered cream region (drop the white margin + baked shadow/corners).
let inset = 0.11
let cx = Int(Double(W) * inset), cy = Int(Double(H) * inset)
let cropped = full.cropping(to: CGRect(x: cx, y: cy, width: W - 2*cx, height: H - 2*cy))!

let sizes: [(String, Int)] = [
    ("icon_16x16.png",16), ("icon_16x16@2x.png",32),
    ("icon_32x32.png",32), ("icon_32x32@2x.png",64),
    ("icon_128x128.png",128), ("icon_128x128@2x.png",256),
    ("icon_256x256.png",256), ("icon_256x256@2x.png",512),
    ("icon_512x512.png",512), ("icon_512x512@2x.png",1024),
]

func render(_ size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let r = s * 0.225
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s), cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: s, height: s))
    return ctx.makeImage()!
}

func savePNG(_ img: CGImage, _ path: String) {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
    try? (data as Data).write(to: URL(fileURLWithPath: path))
}

for (name, size) in sizes {
    savePNG(render(size), "\(outDir)/\(name)")
    print("✓ \(name)")
}

// Small-size preview strip (actual 16/32/64/128 px on gray) so we can judge legibility.
do {
    let previewSizes = [128, 64, 32, 16]
    let gap = 24
    let totalW = previewSizes.reduce(0, +) + gap * (previewSizes.count + 1)
    let maxH = 128 + gap * 2
    let ctx = CGContext(data: nil, width: totalW, height: maxH, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.55, green: 0.56, blue: 0.58, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: totalW, height: maxH))
    var x = gap
    for ps in previewSizes {
        let img = render(ps)
        ctx.draw(img, in: CGRect(x: x, y: (maxH - ps)/2, width: ps, height: ps))
        x += ps + gap
    }
    savePNG(ctx.makeImage()!, "/tmp/chorus-icons/icon_smallsizes.png")
    print("✓ preview /tmp/chorus-icons/icon_smallsizes.png")
}
