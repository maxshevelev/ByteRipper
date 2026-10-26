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
    /// Called with the link a click landed on.
    var onLink: ((CodeLink) -> Void)?

    override var isFlipped: Bool { true }

    func show(_ text: String, tokens: [CodeToken], font: NSFont) {
        string = text
        links = []
        attributed = CodeColors.attributed(text, tokens: tokens, font: font,
                                           links: &links, asTextLinks: false)
        line = CTLineCreateWithAttributedString(attributed)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = attributed.size().height
        attributed.draw(at: NSPoint(x: 0, y: ((bounds.height - height) / 2).rounded(.down)))
    }

    /// The link under a point of the view, if the point is on one.
    func link(at point: NSPoint) -> CodeLink? {
        guard let line, point.x >= 0 else { return nil }
        let index = CTLineGetStringIndexForPosition(line, CGPoint(x: point.x, y: 0))
        guard index != kCFNotFound, index < attributed.length else { return nil }
        // Core Text answers with the caret position nearest the point: the
        // character is the one whose box holds the point.
        var character = index
        let offset = CTLineGetOffsetForStringIndex(line, index, nil)
        if offset > point.x, character > 0 { character -= 1 }
        guard let number = attributed.attribute(CodeColors.linkKey, at: character,
                                                effectiveRange: nil) as? Int,
              links.indices.contains(number) else { return nil }
        return links[number]
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let link = link(at: point), let onLink {
            onLink(link)
            return
        }
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
