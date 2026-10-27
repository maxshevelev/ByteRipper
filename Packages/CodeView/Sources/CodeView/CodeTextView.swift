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

    /// The names that explain themselves on a click — a named constant, a
    /// type, a field: underlined under the pointer like a link, with the
    /// question-mark pointer.
    var explainable: [NSRange] = [] {
        didSet { underline(nil) }
    }

    /// The function's own name in its signature when something calls it:
    /// underlined under the pointer like a call, with the pointing hand; a
    /// click shows its callers. Not a link, since it leads nowhere else.
    var callable: NSRange? {
        didSet { underline(nil) }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        underline(linkAt: point)
        if let hovered, explainable.contains(hovered) { CodeHelpCursor.cursor.set() }
        if let hovered, hovered == callable { NSCursor.pointingHand.set() }
    }

    /// The signature's name under `point`, if it is callable.
    func callableRange(at point: NSPoint) -> NSRange? {
        guard let callable, let character = characterIndex(atViewPoint: point),
              NSLocationInRange(character, callable) else { return nil }
        return callable
    }

    /// The name that explains itself under `point`, if one is.
    func explainableRange(at point: NSPoint) -> NSRange? {
        guard let character = characterIndex(atViewPoint: point) else { return nil }
        return explainable.first { NSLocationInRange(character, $0) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        underline(nil)
    }

    /// A click on the text: the character under it, or nil off the glyphs,
    /// and the event, for its modifiers and its click count. True when the
    /// pane took the click — a jump — and the text view does nothing more.
    var onClick: ((Int?, NSEvent) -> Bool)?
    /// Escape, which a text view otherwise sends as `complete:`.
    var onEscape: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let character = characterIndex(atViewPoint: convert(event.locationInWindow, from: nil))
        if onClick?(character, event) == true { return }
        // A link is followed by the pane, on ⌘-click or a double click; the
        // text view's own handling of a plain click would follow it too.
        // A control-click is the right-click menu, which the text view shows.
        if event.modifierFlags.contains(.control) {
            super.mouseDown(with: event)
            return
        }
        if let character, textStorage?.attribute(.link, at: character, effectiveRange: nil) != nil {
            window?.makeFirstResponder(self)
            return
        }
        super.mouseDown(with: event)
    }

    /// The right-click menu for the character under the pointer, or nil off
    /// the glyphs. The pane's own menu replaces the text view's — Open Link,
    /// Font, Spelling, Speech mean nothing on read-only code.
    var onMenu: ((Int?) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let onMenu else { return super.menu(for: event) }
        return onMenu(characterIndex(atViewPoint: convert(event.locationInWindow, from: nil)))
    }

    override func complete(_ sender: Any?) {
        if let onEscape { onEscape() } else { super.complete(sender) }
    }

    /// The character whose glyph is under `point`, in the view's coordinates.
    func characterIndex(atViewPoint point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0
        else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard box.contains(inContainer) else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        return character < storage.length ? character : nil
    }

    /// The occurrences of the symbol the reader clicked, drawn behind the
    /// glyphs as Xcode does. A temporary attribute, like the underline.
    private var highlighted: [NSRange] = []

    func highlight(_ ranges: [NSRange]) {
        guard let storage = textStorage else { return }
        highlighted = ranges.filter { $0.location + $0.length <= storage.length }
        needsDisplay = true
    }

    /// The highlight is drawn under the text as Xcode draws it: a rounded box
    /// around each occurrence.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !highlighted.isEmpty, let layoutManager, let textContainer else { return }
        CodeColors.symbolHighlight.setFill()
        let origin = textContainerOrigin
        for range in highlighted {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs,
                                                  withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                  in: textContainer) { box, _ in
                let shown = box.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: 0)
                guard shown.intersects(rect) else { return }
                NSBezierPath(roundedRect: shown, xRadius: CodeColors.symbolHighlightRadius,
                             yRadius: CodeColors.symbolHighlightRadius).fill()
            }
        }
    }

    /// What is highlighted now, for tests.
    var highlightedRanges: [NSRange] { highlighted }

    /// The link whose glyphs are under `point`, in the view's coordinates.
    func linkRange(at point: NSPoint) -> NSRange? {
        guard let character = characterIndex(atViewPoint: point), let storage = textStorage else { return nil }
        var range = NSRange()
        guard storage.attribute(.link, at: character, effectiveRange: &range) != nil else { return nil }
        return range
    }

    private func underline(linkAt point: NSPoint?) {
        underline(point.flatMap { linkRange(at: $0) ?? explainableRange(at: $0) ?? callableRange(at: $0) })
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
        highlighted = []
        explainable = []
        callable = nil
    }

    func hover(at point: NSPoint?) { underline(linkAt: point) }
}
