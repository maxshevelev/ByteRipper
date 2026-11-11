import AppKit

/// The yellow plate that stays on a found match once the find indicator has
/// bounced and gone, as Xcode leaves it: the match drawn dark on the find
/// yellow over the text, until the reader moves the selection off it, the
/// text changes, or the search is put away.
///
/// The selection under it cannot carry the colour: while the keyboard is in
/// the Find bar the text view draws its selection grey. So the plate is a
/// view of its own, over the text view's whole surface, drawing only the
/// match — it scrolls with the text and takes no clicks.
final class FindMatchPlate: NSView {
    private(set) weak var textView: NSTextView?
    /// The match the plate stands on, in the text view's characters.
    private(set) var range: NSRange?
    /// The text the plate was put on: another text is no place for it.
    private var shownText = ""

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Puts the plate on `range` of `view`, taking it off wherever it was.
    func show(_ range: NSRange, in view: NSTextView) {
        hide()
        guard range.length > 0, NSMaxRange(range) <= (view.string as NSString).length,
              let layout = view.layoutManager else { return }
        textView = view
        self.range = range
        shownText = view.string
        // The glyphs drawn on the plate are dark, whatever their syntax
        // colour: the yellow is light in both appearances.
        layout.addTemporaryAttribute(.foregroundColor, value: Self.ink, forCharacterRange: range)
        frame = view.bounds
        autoresizingMask = [.width, .height]
        if superview !== view { view.addSubview(self) }
        needsDisplay = true
    }

    /// Takes the plate away and gives the match its own colours back.
    func hide() {
        // Over the whole text: a text put in its place may have kept the
        // colour on characters that are no longer the match's.
        if let view = textView, let layout = view.layoutManager {
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange:
                NSRange(location: 0, length: (view.string as NSString).length))
        }
        range = nil
        textView = nil
        removeFromSuperview()
    }

    /// The text may have been replaced, or the selection moved: the plate
    /// goes unless it still stands on the selected match of the same text.
    func check() {
        guard let view = textView, let range else { return }
        if view.string != shownText || view.selectedRange() != range { hide() }
    }

    /// Whether the plate is on a match now.
    var isShown: Bool { range != nil && superview != nil }

    static let ink = NSColor.black
    static let radius: CGFloat = 3

    override func draw(_ dirtyRect: NSRect) {
        guard let view = textView, let range, let layout = view.layoutManager,
              let container = view.textContainer,
              NSMaxRange(range) <= (view.string as NSString).length else { return }
        let origin = view.textContainerOrigin
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        NSColor.findHighlightColor.setFill()
        layout.enumerateEnclosingRects(forGlyphRange: glyphs,
                                       withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                       in: container) { box, _ in
            let plate = box.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: 0)
            guard plate.intersects(dirtyRect) else { return }
            NSBezierPath(roundedRect: plate, xRadius: Self.radius, yRadius: Self.radius).fill()
        }
        layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }
}
