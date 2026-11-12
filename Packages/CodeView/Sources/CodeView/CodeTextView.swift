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

    // MARK: - The current line

    // help: panel.code.current-line

    /// The line the reader is on: the one last clicked, moved by the arrow
    /// keys, Page Up and Page Down, Home and End. The C has no caret — it is
    /// read, not edited — so this band says where the reader is, as Xcode's
    /// current line does. Nil until the first click; a new text drops it.
    private(set) var currentLine: NSRange? {
        didSet { if currentLine != oldValue { needsDisplay = true } }
    }

    /// The line holding `character`, as `currentLine`.
    func setCurrentLine(containing character: Int) {
        let text = string as NSString
        guard text.length > 0 else { currentLine = nil; return }
        currentLine = text.lineRange(for: NSRange(location: min(max(character, 0), text.length - 1), length: 0))
    }

    /// The lines' starts, top to bottom.
    private var lineStarts: [Int] {
        let text = string as NSString
        var starts: [Int] = []
        var index = 0
        while index < text.length {
            starts.append(index)
            index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
        }
        return starts
    }

    /// The number of lines one page of the view shows.
    private var linesPerPage: Int {
        let line = layoutManager.map { $0.defaultLineHeight(for: font ?? .systemFont(ofSize: 13)) } ?? 16
        let shown = enclosingScrollView?.contentView.bounds.height ?? visibleRect.height
        // The paragraph style may space the lines further: measure one.
        let measured: CGFloat = {
            guard let layoutManager, layoutManager.numberOfGlyphs > 0 else { return line }
            return layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
        }()
        return max(1, Int(shown / max(measured, 1)) - 1)
    }

    /// Moves the current line `by` lines (negative: up), or to the first or
    /// the last, and brings it into view. With no current line yet the move
    /// starts from the top of what is shown.
    private func moveCurrentLine(by delta: Int? = nil, toEnd: Bool? = nil) {
        let starts = lineStarts
        guard !starts.isEmpty else { return }
        let here: Int = {
            if let currentLine, let index = starts.lastIndex(where: { $0 <= currentLine.location }) { return index }
            let top = characterIndexForInsertion(at: NSPoint(x: textContainerOrigin.x, y: visibleRect.minY + 1))
            return starts.lastIndex { $0 <= top } ?? 0
        }()
        let target: Int
        if let toEnd { target = toEnd ? starts.count - 1 : 0 }
        else { target = min(max(here + (delta ?? 0), 0), starts.count - 1) }
        setCurrentLine(containing: starts[target])
        if let currentLine {
            setSelectedRange(NSRange(location: currentLine.location, length: 0))
            scrollRangeToVisible(currentLine)
        }
    }

    override func moveUp(_ sender: Any?) { moveCurrentLine(by: -1) }
    override func moveDown(_ sender: Any?) { moveCurrentLine(by: 1) }
    override func pageUp(_ sender: Any?) { moveCurrentLine(by: -linesPerPage) }
    override func pageDown(_ sender: Any?) { moveCurrentLine(by: linesPerPage) }
    override func scrollPageUp(_ sender: Any?) { moveCurrentLine(by: -linesPerPage) }
    override func scrollPageDown(_ sender: Any?) { moveCurrentLine(by: linesPerPage) }
    override func moveToBeginningOfDocument(_ sender: Any?) { moveCurrentLine(toEnd: false) }
    override func moveToEndOfDocument(_ sender: Any?) { moveCurrentLine(toEnd: true) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { moveCurrentLine(toEnd: false) }
    override func scrollToEndOfDocument(_ sender: Any?) { moveCurrentLine(toEnd: true) }

    /// A new text, as the pane sets one: the reader is on no line of it yet.
    func textWasReplaced() { currentLine = nil }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // The line clicked is the reader's line, wherever on it the click
        // fell — on a name, past the line's end — and whatever it does next.
        if !event.modifierFlags.contains(.control), (string as NSString).length > 0 {
            setCurrentLine(containing: characterIndexForInsertion(at: point))
        }
        let character = characterIndex(atViewPoint: point)
        if onClick?(character, event) == true { return }
        // A link is followed by the pane, on ⌘-click or a double click; the
        // text view's own handling of a plain click would follow it too.
        // A control-click is the right-click menu, which the text view shows.
        if event.modifierFlags.contains(.control) {
            super.mouseDown(with: event)
            return
        }
        // A click in text puts the caret where it was clicked, and the C is no
        // exception: the selection it had goes under any plain click — on a
        // name that explains itself, on a link, or on plain code alike. The
        // two branches below leave before the text view would run that, so it
        // is done here; a drag still selects, and a ⌘-click or a double click
        // was taken by the pane above.
        if let character { setSelectedRange(NSRange(location: character, length: 0)) }
        // A name that explains itself asks about it on a click — the
        // question-mark pointer's promise. The text view's own handling would
        // follow the link or select the word under a double click, and the
        // popover would never open.
        if let character, explainable.contains(where: { NSLocationInRange(character, $0) }) {
            window?.makeFirstResponder(self)
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

    /// Copy takes the text and nothing else. The C's links are the pane's own
    /// tokens — a call or a global carries `.link` = `code:4` — and AppKit
    /// writes a copied link as a URL beside the text: a selection of just the
    /// name then reached the clipboard as `code:4`, which is no name at all.
    override func copy(_ sender: Any?) {
        copySelectedText(to: .general)
    }

    /// The selection as plain text, for `copy` and for a test's pasteboard.
    func copySelectedText(to board: NSPasteboard) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        let text = (string as NSString).substring(with: range)
        board.clearContents()
        board.setString(text, forType: .string)
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
    /// How far a highlight's box stands in from the top and the bottom of its
    /// line: the lines are taller than the font's, and the box goes round
    /// the glyphs, not the whole line.
    var highlightInset: CGFloat = 0
    /// The match a find's yellow plate stands on: its highlight box is not
    /// drawn, so no grey shows round the yellow.
    var plateRange: NSRange? {
        didSet { if plateRange != oldValue { needsDisplay = true } }
    }

    func highlight(_ ranges: [NSRange]) {
        guard let storage = textStorage else { return }
        highlighted = ranges.filter { $0.location + $0.length <= storage.length }
        needsDisplay = true
    }

    /// Tints drawn behind the text before any highlight: the diff's rows.
    /// They are drawn here rather than set as background attributes because
    /// the text's own background attributes are drawn over this pass — and
    /// over the highlight a click puts behind a name.
    var rowTints: [(range: NSRange, color: NSColor)] = [] {
        didSet { needsDisplay = true }
    }

    /// The highlight is drawn under the text as Xcode draws it: a rounded box
    /// around each occurrence, over the row tints and under the glyphs.
    /// How many times the background pass ran, for a test: the row tints and
    /// the highlight are drawn there.
    static var backgroundDraws = 0

    override func drawBackground(in rect: NSRect) {
        Self.backgroundDraws += 1
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        func boxes(_ range: NSRange, inset: CGFloat, radius: CGFloat, fill: NSColor) {
            guard range.location + range.length <= (string as NSString).length else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            fill.setFill()
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs,
                                                  withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                  in: textContainer) { box, _ in
                let shown = box.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: inset)
                guard shown.intersects(rect) else { return }
                NSBezierPath(roundedRect: shown, xRadius: radius, yRadius: radius).fill()
            }
        }
        for tint in rowTints { boxes(tint.range, inset: 0, radius: 0, fill: tint.color) }
        drawCurrentLine(in: rect, layoutManager: layoutManager, origin: origin)
        guard !highlighted.isEmpty else { return }
        let fill = highlightFill
        for range in highlighted {
            // A box under the plate — the match's own, or a name the match
            // is part of — would show round the yellow.
            if let plateRange, NSIntersectionRange(range, plateRange).length > 0 { continue }
            boxes(range, inset: highlightInset, radius: CodeColors.symbolHighlightRadius, fill: fill)
        }
    }

    /// The current line, over the diff's row tints and under a highlighted
    /// name: half see-through, so a red or green row stays red or green with
    /// the band on it. A selected block hides it — the selection is then
    /// where the reader is.
    private func drawCurrentLine(in rect: NSRect, layoutManager: NSLayoutManager, origin: NSPoint) {
        guard let currentLine, showsCurrentLine, NSMaxRange(currentLine) <= (string as NSString).length else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: currentLine, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        let first = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = layoutManager.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        let band = NSRect(x: bounds.minX, y: first.minY + origin.y, width: bounds.width, height: last.maxY - first.minY)
        guard band.intersects(rect) else { return }
        currentLineFill.setFill()
        band.fill(using: .sourceOver)
    }

    /// Whether the band is drawn: not while a block of the text is selected.
    var showsCurrentLine: Bool { currentLine != nil && selectedRange().length == 0 }

    /// The band's fill: reads as `CodeColors.currentLine` over plain code, and
    /// adds its colour to a diff row's tint instead of covering it.
    static let currentLineAlpha: CGFloat = 0.5
    var currentLineFill: NSColor {
        CodeColors.laidOver(NSColor.textBackgroundColor, alpha: Self.currentLineAlpha, toReadAs: CodeColors.currentLine)
            .withAlphaComponent(Self.currentLineAlpha)
    }

    /// A selection that starts or ends shows or hides the band.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let had = selectedRange().length > 0
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if had != (selectedRange().length > 0) { needsDisplay = true }
    }

    /// How much of the highlight's colour a box lays down — one value over
    /// plain code and over a diff row's tint, so a highlighted name reads the
    /// same everywhere, and a tinted row shows through.
    static let highlightAlpha: CGFloat = 0.6

    /// The fill of a highlight box. The panel's blue-grey, laid at
    /// `highlightAlpha` over the code's background, reads as the box it
    /// always was; the same fill over a tinted row adds to the row's colour
    /// instead of replacing it.
    var highlightFill: NSColor {
        CodeColors.laidOver(NSColor.textBackgroundColor, alpha: Self.highlightAlpha,
                            toReadAs: CodeColors.symbolHighlight)
            .withAlphaComponent(Self.highlightAlpha)
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
