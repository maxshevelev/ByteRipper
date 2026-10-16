import AppKit

/// A detail's name/value rows, **one view per row**, with text selected across
/// them the way a text view's is (`ToolSelectableRows`).
///
/// The rows every panel of this app draws a named value with: the UEFI
/// Structure's detail under its tree, the ME Analyzer's Summary tab and the
/// detail under its own tree, the FIT's detail under its table, and a record
/// in the agent window. One row shape
/// means one selection: a drag across rows takes a band of them, a double
/// click a word, a triple click a row, ⌘A the whole list, and ⌘C copies what
/// is selected with a tab between a name and its value — in each of them.
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
    /// One row: its name, its value, and — where the row is a comparison — the
    /// second value beside the first.
    ///
    /// The second value is a *column*, not a suffix: a tab between the three in
    /// what ⌘C copies, and its own width down the list. It is what the ME
    /// Analyzer's Configuration tab is: one setting of a file, what the build
    /// wrote into the image and what the platform holds now, read against each
    /// other. A row without one is the plain name/value row of every other
    /// panel.
    public struct Field {
        public var label: String
        public var value: NSAttributedString
        public var second: NSAttributedString?

        public init(label: String, value: NSAttributedString,
                    second: NSAttributedString? = nil) {
            self.label = label
            self.value = value
            self.second = second
        }
    }

    public private(set) var rows: [ToolFieldRow] = []
    private var laidOutWidth: CGFloat = 0

    /// The name column a list of rows named `names` wants: wide enough for the
    /// widest of them, and never narrower than `atLeast`.
    ///
    /// Here rather than at the panel that asks, because it is the measurement
    /// the rows themselves make — a name's width, laid out by the same engine
    /// that draws it (`TextBlock`) — and two panels asking for it must ask the
    /// same way. The engine's field names run long
    /// (`systemHeaderCRCValid`), and the shared default cut them off mid-word
    /// there; a summary's run longer still. A name that comes to exactly the
    /// column is a name that wraps to a second line, so measuring it with
    /// anything but that engine leaves a column that is a point too narrow.
    public static func nameWidth(
        for names: [String], atLeast: CGFloat = ToolPanelFont.detailLabelWidth
    ) -> CGFloat {
        let widest = names.map { name in
            TextBlock.width(of: NSAttributedString(
                string: name, attributes: [.font: ToolPanelFont.body()]))
        }.max() ?? 0
        return max(atLeast, widest)
    }

    /// The gap between two rows — the one the detail list keeps between its
    /// own lines.
    static let rowSpacing: CGFloat = 3

    /// `nameWidth` is the name column's: a name longer than it wraps. Never
    /// more than half the list, so a list squeezed narrow still has room for
    /// its values.
    public init(fields: [Field], nameWidth: CGFloat = ToolPanelFont.detailLabelWidth) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        rows = fields.map {
            ToolFieldRow(label: $0.label, value: $0.value, second: $0.second,
                         nameWidth: nameWidth)
        }
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

/// One line of a `ToolFieldList`: a name and a value, or — where the row
/// compares two copies of one thing — a name, a value and a second value in a
/// column of its own. Part 0 is the name, part 1 the value, part 2 the second
/// value when there is one.
@MainActor public final class ToolFieldRow: NSView, ToolSelectableRow {
    public let label: String
    private let name: TextBlock
    private let value: TextBlock
    /// The second value's column: nil on a row that has none.
    private let second: TextBlock?
    private let nameWidth: CGFloat
    private var fittedWidth: CGFloat = -1
    private var fittedHeight: CGFloat = 0

    /// The width the name is drawn in at the row's laid-out width: the column
    /// the list asked for, or half the row when the row is narrower than that.
    /// Where a name too long for it wraps, this is what it wraps in.
    public private(set) var nameColumnWidth: CGFloat = 0

    /// The width each value is drawn in on a comparing row — the two columns
    /// under the name are the same width, which is what makes them read as
    /// columns. Zero on a row with one value, whose value takes the rest.
    public private(set) var valueColumnWidth: CGFloat = 0

    /// How tall the row's own text is at the width it was last fitted to — its
    /// name and its value, whichever of the two is the taller. The row's frame
    /// is taller than this by the spacing the list leaves under it.
    public private(set) var textHeight: CGFloat = 0

    /// Between the name column and the value. Public with the row's geometry:
    /// what a name wraps in, and where the value begins, are one measurement
    /// apart, and a reader of either has the other to hand.
    public static let columnSpacing: CGFloat = 6

    init(label: String, value: NSAttributedString, second: NSAttributedString? = nil,
         nameWidth: CGFloat) {
        self.label = label
        self.nameWidth = nameWidth
        name = TextBlock(NSAttributedString(string: label, attributes: [
            .font: ToolPanelFont.body(), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        self.value = TextBlock(value)
        self.second = second.map(TextBlock.init)
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

    /// The second value's text the same way. Nil on a row that has none.
    public var secondText: String? { second.map { TextBlock.plain($0.storage.string) } }

    /// The value as it is drawn: its fonts, colours and a passed check's tick.
    public var attributedValue: NSAttributedString { value.storage }

    /// The second value as it is drawn. Nil on a row that has none.
    public var attributedSecond: NSAttributedString? { second?.storage }

    /// The font the name is drawn in.
    public var nameFont: NSFont? {
        name.length == 0 ? nil : name.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }

    /// The name and the value — what VoiceOver and the tests read.
    public var texts: [String] { [label, valueText] + (secondText.map { [$0] } ?? []) }

    private var blocks: [TextBlock] { [name, value] + (second.map { [$0] } ?? []) }

    /// How tall the row is at `width`, its texts set for it.
    ///
    /// A row with one value gives it everything the name column leaves; a row
    /// comparing two gives each of them the *same* width, so the two columns
    /// line up down the list — and the name column stops at half the row, which
    /// is what a squeezed panel leaves the two of them room in.
    func fit(width: CGFloat) -> CGFloat {
        guard width != fittedWidth else { return fittedHeight }
        let column = max(0, min(nameWidth, (width - Self.columnSpacing) / 2))
        name.place(x: 0, width: column)
        let rest = max(1, width - column - Self.columnSpacing)
        if let second {
            let each = max(1, (rest - Self.columnSpacing) / 2)
            value.place(x: column + Self.columnSpacing, width: each)
            second.place(x: column + Self.columnSpacing + each + Self.columnSpacing,
                         width: max(1, rest - each - Self.columnSpacing))
            valueColumnWidth = each
            fittedHeight = max(name.height, value.height, second.height)
        } else {
            value.place(x: column + Self.columnSpacing, width: rest)
            valueColumnWidth = 0
            fittedHeight = max(name.height, value.height)
        }
        fittedWidth = width
        nameColumnWidth = column
        textHeight = fittedHeight
        needsDisplay = true
        return fittedHeight
    }

    public override func draw(_ dirtyRect: NSRect) {
        if let selectedRange {
            NSColor.selectedTextBackgroundColor.setFill()
            let last = blocks.count - 1
            for part in selectedRange.lowerBound.part...min(selectedRange.upperBound.part, last) {
                let from = part == selectedRange.lowerBound.part ? selectedRange.lowerBound.index : 0
                let to = part == selectedRange.upperBound.part ? selectedRange.upperBound.index : blocks[part].length
                blocks[part].rects(from: from, to: to).forEach { $0.fill() }
            }
        }
        blocks.forEach { $0.draw() }
    }

    // MARK: - Selecting

    public var selectedRange: Range<ToolTextMark>? {
        didSet { if selectedRange != oldValue { needsDisplay = true } }
    }

    public var startMark: ToolTextMark { ToolTextMark(part: 0, index: 0) }
    public var endMark: ToolTextMark {
        ToolTextMark(part: blocks.count - 1, index: blocks[blocks.count - 1].length)
    }

    /// The part the point falls in: the name's left of the middle of the gap
    /// after it, and each value's left of the middle of the gap after *it*.
    public func mark(at point: NSPoint) -> ToolTextMark {
        let part = blocks.indices.last {
            $0 > 0 && point.x >= blocks[$0].origin.x - Self.columnSpacing / 2
        } ?? 0
        return ToolTextMark(part: part, index: blocks[part].index(at: point))
    }

    public func word(at mark: ToolTextMark) -> Range<ToolTextMark> {
        let word = blocks[mark.part].word(at: mark.index)
        return ToolTextMark(part: mark.part, index: word.lowerBound)
            ..< ToolTextMark(part: mark.part, index: word.upperBound)
    }

    public func text(in range: Range<ToolTextMark>) -> String {
        let last = blocks.count - 1
        return (range.lowerBound.part...min(range.upperBound.part, last)).map { part in
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
        let under = part == 0 ? label : blocks[part] === second ? secondText : valueText
        return NSMenu.copyMenu(selection: (superview as? ToolSelectableRows)?.selectedText,
                               fallback: under)
    }

    // MARK: - Accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    public override func accessibilityLabel() -> String? { label }
    public override func accessibilityValue() -> Any? {
        secondText.map { "\(valueText), \($0)" } ?? valueText
    }
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

    /// The width a text needs on one line, as the engine that draws it lays it
    /// out — what a name column has to hold for the name not to wrap.
    static func width(of string: NSAttributedString) -> CGFloat {
        let block = TextBlock(string)
        block.place(x: 0, width: 100_000)
        return block.lineWidth
    }

    /// One line's width, at the width the text was placed in.
    private var lineWidth: CGFloat {
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).width)
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
