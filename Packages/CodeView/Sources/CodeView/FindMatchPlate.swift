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
    static let radius: CGFloat = 3.5
    /// Xcode's plate: a pale yellow, a thin darker edge and a soft shadow,
    /// as tall as the text and a point or two wider — not the line's band.
    static let fill = NSColor(srgbRed: 1.0, green: 0.98, blue: 0.52, alpha: 1)
    static let edge = NSColor(srgbRed: 0.78, green: 0.72, blue: 0.18, alpha: 0.55)
    static let padding = NSSize(width: 1.5, height: 1)

    /// The plates over `range`, one per line it runs over: from the font's
    /// ascender to its descender around the line's baseline.
    static func plates(for range: NSRange, in view: NSTextView) -> [NSRect] {
        guard let layout = view.layoutManager, let container = view.textContainer,
              let storage = view.textStorage, NSMaxRange(range) <= storage.length, range.length > 0
        else { return [] }
        let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            ?? view.font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let origin = view.textContainerOrigin
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var plates: [NSRect] = []
        var index = glyphs.location
        while index < NSMaxRange(glyphs) {
            var lineGlyphs = NSRange()
            let line = layout.lineFragmentRect(forGlyphAt: index, effectiveRange: &lineGlyphs)
            let piece = NSIntersectionRange(lineGlyphs, glyphs)
            guard piece.length > 0 else { break }
            let box = layout.boundingRect(forGlyphRange: piece, in: container)
            let baseline = line.minY + layout.location(forGlyphAt: piece.location).y
            let top = baseline - font.ascender
            let height = font.ascender - font.descender
            plates.append(NSRect(x: box.minX + origin.x, y: top + origin.y, width: box.width, height: height)
                .insetBy(dx: -padding.width, dy: -padding.height))
            index = NSMaxRange(piece)
        }
        return plates
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let view = textView, let range, let layout = view.layoutManager,
              NSMaxRange(range) <= (view.string as NSString).length else { return }
        for plate in Self.plates(for: range, in: view) where plate.insetBy(dx: -4, dy: -4).intersects(dirtyRect) {
            let path = NSBezierPath(roundedRect: plate, xRadius: Self.radius, yRadius: Self.radius)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.set()
            Self.fill.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            Self.edge.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        layout.drawGlyphs(forGlyphRange: glyphs, at: view.textContainerOrigin)
    }
}
