import AppKit
import AppPalette
import XCTest
@testable import ByteRipper

/// A notice's sign and words are drawn in the notice colour, the sign at the
/// size its picture is, and a plate that is only a sign holds it in the middle.
@MainActor
final class TransientNoticeViewTests: XCTestCase {
    private func symbol(_ name: String) throws -> NSImage {
        try XCTUnwrap(NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 72, weight: .regular)))
    }

    private func symbolView(in view: NSView) -> SymbolView? {
        if let found = view as? SymbolView { return found }
        for subview in view.subviews {
            if let found = symbolView(in: subview) { return found }
        }
        return nil
    }

    /// The glyph carries the tint's alpha: a symbol image is a template that
    /// draws opaque black, and a composite that keeps the glyph's own alpha
    /// turns a translucent grey into that black.
    func testTheGlyphIsDrawnInTheNoticeColourAtItsOwnSize() throws {
        let image = try symbol("hammer.fill")
        let view = SymbolView()
        view.appearance = NSAppearance(named: .aqua)
        view.image = image
        // Larger than the picture on every side: drawn at its own size and
        // centred, the margin stays empty.
        let margin: CGFloat = 12
        view.frame = NSRect(x: 0, y: 0, width: ceil(image.size.width) + 2 * margin,
                            height: ceil(image.size.height) + 2 * margin)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        var strongest: CGFloat = 0
        var inMargin: CGFloat = 0
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let edge = Int(margin * scale) - 1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let alpha = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
                strongest = max(strongest, alpha)
                if x < edge || y < edge || x >= rep.pixelsWide - edge || y >= rep.pixelsHigh - edge {
                    inMargin = max(inMargin, alpha)
                }
            }
        }
        XCTAssertEqual(strongest, NoticeColors.Sets.icon.light.alpha, accuracy: 0.03,
                       "the glyph is the notice grey, not opaque black")
        XCTAssertLessThan(inMargin, 0.01, "drawn at the picture's size, not stretched to the frame")
    }

    /// The words are the sign's colour: a plate is one object.
    func testTheWordsAreTheSignsColour() throws {
        let notice = TransientNoticeView(symbol: "hammer.fill", lines: ["Build Succeeded", "0 warnings"])
        let labels = allSubviews(of: notice).compactMap { $0 as? NSTextField }
        XCTAssertEqual(labels.map(\.stringValue), ["Build Succeeded", "0 warnings"])
        for label in labels {
            XCTAssertEqual(label.textColor, NoticeColors.icon)
        }
        XCTAssertEqual(symbolView(in: notice)?.tint, NoticeColors.icon)
    }

    /// A plate that is only a sign keeps it in the middle: no empty stack of
    /// lines takes the spacing under it.
    func testAGlyphOnlyPlateHoldsTheGlyphInTheMiddle() throws {
        let notice = TransientNoticeView(glyph: "arrow.uturn.down")
        notice.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        notice.layoutSubtreeIfNeeded()
        let glyph = try XCTUnwrap(symbolView(in: notice))
        let centre = glyph.convert(NSPoint(x: glyph.bounds.midX, y: glyph.bounds.midY), to: notice)
        XCTAssertEqual(centre.y, notice.bounds.midY, accuracy: 0.5)
        XCTAssertEqual(centre.x, notice.bounds.midX, accuracy: 0.5)
    }

    /// The notice and the landing screen are two meanings, and two colours.
    func testTheNoticeAndTheLandingScreenAreDifferentColours() {
        XCTAssertNotEqual(NoticeColors.Sets.icon.light.alpha, EmptyStateColors.Sets.icon.light.alpha)
        XCTAssertNotEqual(NoticeColors.Sets.icon.dark.alpha, EmptyStateColors.Sets.icon.dark.alpha)
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews(of:))
    }
}
