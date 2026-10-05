import AppKit

/// A detail's name/value rows, **one view per row**, with text selected across
/// them the way a text view's is (`ToolSelectableRows`).
///
/// A row was a name label, a wrapping value label and a stack between them,
/// with the constraints that tie the three together — three views and a field
/// editor's worth of machinery per field, and a selection that stopped at the
/// edge of one value. A row is now one view that sets its two texts and draws
/// them: the name in its column, wrapping onto a further line when it is too
/// long for it, and the value beside it, wrapping inside what is left of the
/// width. ⌘C copies a row as its name, a tab and its value.
///
/// Its height follows its width, as a wrapping label's does: it reads its
/// laid-out width back and asks for the height the rows need at it.
// help: panel.detail-select
@MainActor public final class ToolFieldList: ToolSelectableRows {
    public struct Field {
        public var label: String
        public var value: NSAttributedString

        public init(label: String, value: NSAttributedString) {
            self.label = label
            self.value = value
        }
    }

    public private(set) var rows: [ToolFieldRow] = []
    private var laidOutWidth: CGFloat = 0

    /// The gap between two rows — the one the detail list keeps between its
    /// own lines.
    static let rowSpacing: CGFloat = 3

    /// `nameWidth` is the name column's: a name longer than it wraps. Never
    /// more than half the list, so a list squeezed narrow still has room for
    /// its values.
    public init(fields: [Field], nameWidth: CGFloat = ToolPanelFont.detailLabelWidth) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        rows = fields.map { ToolFieldRow(label: $0.label, value: $0.value, nameWidth: nameWidth) }
        rows.forEach(addSubview)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var selectableRows: [any ToolSelectableRow] { rows }

    /// The width the rows are fitted to: the laid-out one, or before there is
    /// one, enough for every row to stay on one line.
    private var fittingWidth: CGFloat { laidOutWidth > 0 ? laidOutWidth : 10_000 }

    public override var intrinsicContentSize: NSSize {
        let heights = rows.map { $0.fit(width: fittingWidth) }
        let height = heights.reduce(0, +) + Self.rowSpacing * CGFloat(max(0, rows.count - 1))
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    public override func layout() {
        super.layout()
        if bounds.width != laidOutWidth {
            laidOutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let spacing = index == rows.count - 1 ? 0 : Self.rowSpacing
            let height = row.fit(width: fittingWidth)
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: height + spacing)
            y += height + spacing
        }
    }
}

/// One name/value line of a `ToolFieldList`. Part 0 is the name, part 1 the
/// value.
@MainActor public final class ToolFieldRow: NSView, ToolSelectableRow {
    public let label: String
    private let name: TextBlock
    private let value: TextBlock
    private let nameWidth: CGFloat
    private var fittedWidth: CGFloat = -1
    private var fittedHeight: CGFloat = 0

    /// Between the name column and the value.
    static let columnSpacing: CGFloat = 6

    init(label: String, value: NSAttributedString, nameWidth: CGFloat) {
        self.label = label
        self.nameWidth = nameWidth
        name = TextBlock(NSAttributedString(string: label, attributes: [
            .font: ToolPanelFont.body(), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        self.value = TextBlock(value)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }

    /// The value's text as a reader reads it: without the character that
    /// stands in for a passed check's tick.
    public var valueText: String { TextBlock.plain(value.storage.string) }

    /// The value as it is drawn: its fonts, colours and a passed check's tick.
    public var attributedValue: NSAttributedString { value.storage }

    /// The font the name is drawn in.
    public var nameFont: NSFont? {
        name.length == 0 ? nil : name.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }

    /// The name and the value — what VoiceOver and the tests read.
    public var texts: [String] { [label, valueText] }

    private var blocks: [TextBlock] { [name, value] }

    /// How tall the row is at `width`, its two texts set for it.
    func fit(width: CGFloat) -> CGFloat {
        guard width != fittedWidth else { return fittedHeight }
        let column = max(0, min(nameWidth, (width - Self.columnSpacing) / 2))
        name.place(x: 0, width: column)
        value.place(x: column + Self.columnSpacing,
                    width: max(1, width - column - Self.columnSpacing))
        fittedWidth = width
        fittedHeight = max(name.height, value.height)
        needsDisplay = true
        return fittedHeight
    }

    public override func draw(_ dirtyRect: NSRect) {
        if let selectedRange {
            NSColor.selectedTextBackgroundColor.setFill()
            for part in selectedRange.lowerBound.part...min(selectedRange.upperBound.part, 1) {
                let from = part == selectedRange.lowerBound.part ? selectedRange.lowerBound.index : 0
                let to = part == selectedRange.upperBound.part ? selectedRange.upperBound.index : blocks[part].length
                blocks[part].rects(from: from, to: to).forEach { $0.fill() }
            }
        }
        name.draw()
        value.draw()
    }

    // MARK: - Selecting

    public var selectedRange: Range<ToolTextMark>? {
        didSet { if selectedRange != oldValue { needsDisplay = true } }
    }

    public var startMark: ToolTextMark { ToolTextMark(part: 0, index: 0) }
    public var endMark: ToolTextMark { ToolTextMark(part: 1, index: value.length) }

    /// The name's, left of the middle of the gap between the two; the value's
    /// right of it.
    public func mark(at point: NSPoint) -> ToolTextMark {
        let part = point.x < value.origin.x - Self.columnSpacing / 2 ? 0 : 1
        return ToolTextMark(part: part, index: blocks[part].index(at: point))
    }

    public func word(at mark: ToolTextMark) -> Range<ToolTextMark> {
        let word = blocks[mark.part].word(at: mark.index)
        return ToolTextMark(part: mark.part, index: word.lowerBound)
            ..< ToolTextMark(part: mark.part, index: word.upperBound)
    }

    public func text(in range: Range<ToolTextMark>) -> String {
        (range.lowerBound.part...min(range.upperBound.part, 1)).map { part in
            let from = part == range.lowerBound.part ? range.lowerBound.index : 0
            let to = part == range.upperBound.part ? range.upperBound.index : blocks[part].length
            return blocks[part].text(from: from, to: to)
        }.joined(separator: "\t")
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    // help: panel.detail-select
    public override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let part = mark(at: point).part
        return NSMenu.copyMenu(selection: (superview as? ToolSelectableRows)?.selectedText,
                               fallback: part == 0 ? label : valueText)
    }

    // MARK: - Accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    public override func accessibilityLabel() -> String? { label }
    public override func accessibilityValue() -> Any? { valueText }
}

/// One wrapping text of a row, laid out by TextKit — which is what draws a
/// passed check's tick, an attachment, and what says exactly where each
/// character it drew has landed, so a click selects the character it was on.
@MainActor private final class TextBlock {
    let storage: NSTextStorage
    private let layout = NSLayoutManager()
    private let container = NSTextContainer()
    private(set) var origin: NSPoint = .zero

    init(_ string: NSAttributedString) {
        storage = NSTextStorage(attributedString: string)
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
    }

    var length: Int { storage.length }

    /// The text without the character an attachment stands on — the tick and
    /// the space after it.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC} ", with: "").replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    func place(x: CGFloat, width: CGFloat) {
        origin = NSPoint(x: x, y: 0)
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
    }

    var height: CGFloat {
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    func draw() {
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: origin)
    }

    /// The place between characters nearest `point`, in the row's coordinates:
    /// above the text its start, below it its end.
    func index(at point: NSPoint) -> Int {
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard length > 0, local.y >= 0 else { return 0 }
        guard local.y < height else { return length }
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let index = layout.characterIndexForGlyph(at: glyph) + (fraction > 0.5 ? 1 : 0)
        return min(max(0, index), length)
    }

    func word(at index: Int) -> Range<Int> {
        guard length > 0 else { return index..<index }
        let word = storage.doubleClick(at: min(index, length - 1))
        return word.lowerBound..<word.upperBound
    }

    func text(from: Int, to: Int) -> String {
        guard to > from else { return "" }
        return Self.plain((storage.string as NSString).substring(with: NSRange(location: from, length: to - from)))
    }

    /// What a selection from `from` to `to` covers, line by line, in the row's
    /// coordinates.
    func rects(from: Int, to: Int) -> [NSRect] {
        guard to > from else { return [] }
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: from, length: to - from),
                                       actualCharacterRange: nil)
        var rects: [NSRect] = []
        layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs,
                                       in: container) { rect, _ in
            rects.append(rect.offsetBy(dx: self.origin.x, dy: self.origin.y))
        }
        return rects
    }
}
