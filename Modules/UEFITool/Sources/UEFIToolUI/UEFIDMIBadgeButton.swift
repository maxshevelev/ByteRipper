import AppKit
import Localization

/// The DMI button in the panel's header: the word in a rounded frame, a badge
/// rather than a glyph — no symbol says "the board's identity", and the
/// technician knows the area by that name.
///
/// Drawn rather than built from a layer, so the frame and the word follow the
/// appearance: a layer's colour is a `CGColor` fixed when it was set.
final class UEFIDMIBadgeButton: NSButton {
    private static let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
    /// Room between the word and the frame, across.
    private static let inset: CGFloat = 5
    /// The frame's height, centred in the button's.
    private static let badgeHeight: CGFloat = 15

    init() {
        super.init(frame: .zero)
        title = L("DMI")
        isBordered = false
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var attributedWord: NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: Self.font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributedWord.size().width) + 2 * Self.inset, height: Self.badgeHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let badge = NSRect(x: 0.5, y: ((bounds.height - Self.badgeHeight) / 2).rounded() + 0.5,
                           width: bounds.width - 1, height: Self.badgeHeight - 1)
        let path = NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4)
        if isHighlighted {
            NSColor.quaternaryLabelColor.setFill()
            path.fill()
        }
        NSColor.secondaryLabelColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        // Centred on its capitals, not on its line: the line keeps room below
        // for descenders a word in capitals has none of, and centring that
        // lifts the word.
        let word = attributedWord
        let font = Self.font
        let baseline = isFlipped
            ? badge.midY + font.capHeight / 2
            : badge.midY - font.capHeight / 2
        let lineOrigin = isFlipped ? baseline - font.ascender : baseline + font.descender
        word.draw(at: NSPoint(x: (bounds.width - word.size().width) / 2, y: lineOrigin))
    }
}
