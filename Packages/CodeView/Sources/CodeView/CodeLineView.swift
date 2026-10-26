import AppKit
import CodeAnalysis

/// One listing row: a coloured line of text whose links — a call's target, a
/// jump's label, a read's global — are clickable, as in an IDE.
///
/// A single line: AppKit draws it, so the system colours follow the
/// appearance; a Core Text line of the same string finds the character under
/// the pointer. A click off a link is passed on, and the table selects the row
/// as it would for any cell.
final class CodeLineView: NSView {
    private(set) var string = ""
    private var attributed = NSAttributedString()
    private var line: CTLine?
    private var links: [CodeLink] = []
    /// The link under the pointer: drawn underlined, as a link in an IDE.
    private(set) var hoveredLink: NSRange?
    private var tracking: NSTrackingArea?
    /// A click on the line: the link it landed on, if any, and the event.
    /// True when the pane took it — a jump — and the row is not selected.
    var onClick: ((CodeLink?, NSEvent) -> Bool)?
    /// The occurrences of the symbol the reader clicked, drawn behind the text.
    private(set) var highlighted: [NSRange] = []

    override var isFlipped: Bool { true }

    func show(_ text: String, tokens: [CodeToken], font: NSFont, highlighted: [NSRange] = []) {
        string = text
        self.highlighted = highlighted
        links = []
        attributed = CodeColors.attributed(text, tokens: tokens, font: font,
                                           links: &links, asTextLinks: false)
        line = CTLineCreateWithAttributedString(attributed)
        hoveredLink = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

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
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hover(at: nil)
    }

    /// Underlines the link under `point`, or none.
    func hover(at point: NSPoint?) {
        let range = point.flatMap(linkRange(at:))
        guard range != hoveredLink else { return }
        hoveredLink = range
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        var shown = attributed
        if let hoveredLink {
            let underlined = NSMutableAttributedString(attributedString: attributed)
            underlined.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: hoveredLink)
            shown = underlined
        }
        let height = shown.size().height
        let top = ((bounds.height - height) / 2).rounded(.down)
        if let line, !highlighted.isEmpty {
            CodeColors.symbolHighlight.setFill()
            for range in highlighted where range.location + range.length <= attributed.length {
                let start = CTLineGetOffsetForStringIndex(line, range.location, nil)
                let end = CTLineGetOffsetForStringIndex(line, range.location + range.length, nil)
                NSBezierPath(roundedRect: NSRect(x: start - 2, y: top, width: end - start + 4, height: height),
                             xRadius: CodeColors.symbolHighlightRadius,
                             yRadius: CodeColors.symbolHighlightRadius).fill()
            }
        }
        shown.draw(at: NSPoint(x: 0, y: top))
    }

    /// The link under a point of the view, if the point is on one.
    func link(at point: NSPoint) -> CodeLink? {
        guard let range = linkRange(at: point),
              let number = attributed.attribute(CodeColors.linkKey, at: range.location,
                                                effectiveRange: nil) as? Int,
              links.indices.contains(number) else { return nil }
        return links[number]
    }

    /// The characters of the link under `point`.
    func linkRange(at point: NSPoint) -> NSRange? {
        guard let line, point.x >= 0 else { return nil }
        let index = CTLineGetStringIndexForPosition(line, CGPoint(x: point.x, y: 0))
        guard index != kCFNotFound, index < attributed.length else { return nil }
        // Core Text answers with the caret position nearest the point: the
        // character is the one whose box holds the point.
        var character = index
        let offset = CTLineGetOffsetForStringIndex(line, index, nil)
        if offset > point.x, character > 0 { character -= 1 }
        var range = NSRange()
        guard attributed.attribute(CodeColors.linkKey, at: character, effectiveRange: &range) != nil,
              range.location + range.length <= attributed.length else { return nil }
        // Past the end of the line's text is not on the link.
        let end = CTLineGetOffsetForStringIndex(line, range.location + range.length, nil)
        guard point.x <= end else { return nil }
        return range
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if onClick?(link(at: point), event) == true { return }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        guard let line else { return }
        attributed.enumerateAttribute(CodeColors.linkKey,
                                      in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard value != nil else { return }
            let start = CTLineGetOffsetForStringIndex(line, range.location, nil)
            let end = CTLineGetOffsetForStringIndex(line, range.location + range.length, nil)
            addCursorRect(NSRect(x: start, y: 0, width: end - start, height: bounds.height),
                          cursor: .pointingHand)
        }
    }
}
