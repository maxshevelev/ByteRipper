import AppKit
@testable import CodeView
import XCTest

/// A bare symbol mark sits in the middle of its square, whole.
final class CodeBareSymbolMarkTests: XCTestCase {
    private func ink(_ image: NSImage, scale: CGFloat) -> (CGRect, Int, Int) {
        let width = Int(image.size.width * scale), height = Int(image.size.height * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height { for x in 0..<width where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
        return (CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1), width, height)
    }

    func testTheChipIsCentredAndWhole() {
        for inverted in [false, true] {
            for scale: CGFloat in [1, 2] {
                let image = CodeNavigatorIcon.image(.bareSymbol("cpu.fill"), color: .systemGreen, side: 16,
                                                     inverted: inverted)
                let (box, width, height) = ink(image, scale: scale)
                print("INK", inverted, scale, box, width, height)
                if let dir = ProcessInfo.processInfo.environment["MARK_PNG_DIR"] {
                    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: "\(dir)/mark-\(inverted)-\(Int(scale)).png"))
                }
                do {
                    XCTAssertGreaterThan(box.minX, 0, "left edge whole")
                    XCTAssertGreaterThan(box.minY, 0, "bottom edge whole")
                    XCTAssertLessThan(box.maxX, CGFloat(width), "right edge whole")
                    XCTAssertEqual(box.midX, CGFloat(width) / 2, accuracy: scale, "centred across")
                    XCTAssertEqual(box.midY, CGFloat(height) / 2, accuracy: scale, "centred up and down")
                }
            }
        }
    }
}
