import XCTest
import SwiftUI
@testable import Chorus

/// Side by side — the quick input's "everyone" trio, the panel headers — the characters should
/// read as the same size. Measured on what's actually drawn: the ink's extent in the same frame.
@MainActor
final class InkSizeTests: XCTestCase {
    /// The drawn ink's height and width, as fractions of the frame.
    static func inkExtent(_ kind: InkCast, frame: CGSize = CGSize(width: 180, height: 220)) -> (height: CGFloat, width: CGFloat) {
        let r = ImageRenderer(content: InkCharacter(kind: kind, fill: .clear).frame(width: frame.width, height: frame.height))
        r.scale = 1
        guard let img = r.cgImage, let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return (0, 0) }
        let bpr = img.bytesPerRow, bpp = img.bitsPerPixel / 8
        let alphaOffset = img.alphaInfo == .premultipliedFirst || img.alphaInfo == .first ? 0 : bpp - 1
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<img.height {
            for x in 0..<img.width where p[y * bpr + x * bpp + alphaOffset] > 60 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return (0, 0) }
        return (CGFloat(maxY - minY + 1) / frame.height, CGFloat(maxX - minX + 1) / frame.width)
    }

    /// Each in the slot `InkCharacter.width` gives it, as the trio and the panel headers do.
    func testTrioReadsTheSameHeight() {
        func measure(_ k: InkCast) -> (height: CGFloat, width: CGFloat, slot: CGFloat) {
            let slot = InkCharacter.width(k, height: 22)
            let e = Self.inkExtent(k, frame: CGSize(width: slot * 10, height: 220))
            return (e.height, e.width, slot)
        }
        let circle = measure(.circle), square = measure(.square), triangle = measure(.triangle)
        print(String(format: "[ink] slots %.0f/%.0f/%.0f | heights circle %.3f square %.3f triangle %.3f | widths %.3f %.3f %.3f",
                     circle.slot, square.slot, triangle.slot, circle.height, square.height, triangle.height,
                     circle.width, square.width, triangle.width))
        // The triangle within 6% of the circle (its tip reads lighter, so it may stand a touch
        // taller). The square is held a little shorter on purpose — it carries the most ink — so
        // it gets a looser band. Nobody touches the edge of its slot.
        XCTAssertEqual(triangle.height / circle.height, 1.0, accuracy: 0.06)
        XCTAssertEqual(square.height / circle.height, 1.0, accuracy: 0.08)
        for w in [circle.width, square.width, triangle.width] { XCTAssertLessThan(w, 0.99) }
    }
}
