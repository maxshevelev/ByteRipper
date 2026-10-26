import AppKit

/// The decompiled C: a read-only text view whose links — a call, a global —
/// underline under the pointer, as links in an IDE do. The underline is a
/// temporary attribute of the layout, not of the text, so the C itself is
/// never rewritten for it.
final class CodeTextView: NSTextView {
    private var hovered: NSRange?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited,
                                                         .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        underline(linkAt: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        underline(nil)
    }

    /// The link whose glyphs are under `point`, in the view's coordinates.
    func linkRange(at point: NSPoint) -> NSRange? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0
        else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard box.contains(inContainer) else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard character < storage.length else { return nil }
        var range = NSRange()
        guard storage.attribute(.link, at: character, effectiveRange: &range) != nil else { return nil }
        return range
    }

    private func underline(linkAt point: NSPoint?) {
        underline(point.flatMap(linkRange(at:)))
    }

    private func underline(_ range: NSRange?) {
        guard range != hovered, let layoutManager else { return }
        if let hovered { layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: hovered) }
        if let range {
            layoutManager.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                                forCharacterRange: range)
        }
        hovered = range
    }

    /// The link under the pointer now, for tests.
    var hoveredLink: NSRange? { hovered }

    /// New text: whatever was underlined is gone with the old.
    override func didChangeText() {
        super.didChangeText()
        hovered = nil
    }

    func hover(at point: NSPoint?) { underline(linkAt: point) }
}
