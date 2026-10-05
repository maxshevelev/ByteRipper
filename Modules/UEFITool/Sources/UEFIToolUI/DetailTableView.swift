import AppKit
import AppPalette
import HelpUI
import Localization
import ToolModuleKit
import UEFITool

/// A table in the detail list: its header line and its rows, **one view per
/// row** (`DetailTableRow`), each drawing its own cells.
///
/// A grid of text fields was the first way this was drawn, and it cost a field,
/// its constraints and — for a row that leads somewhere — a click recogniser per
/// cell: a descriptor's strap words came to some three hundred views, and laying
/// them out was most of the quarter of a second a click on the descriptor took.
/// A row is one view that measures and draws its few strings, and the table
/// places its rows by frame, so a table costs a view per row and no
/// constraints inside it.
///
/// The columns line up because the table measures them once, across every
/// row, and hands each row the same offsets: every column is as wide as its
/// widest cell, and the table as wide as its columns — a two-column table of
/// short values stays two columns side by side rather than one at either edge
/// of the list. In a list narrower than that, the last column gives way: cut
/// short, with the whole text under the pointer.
///
/// The text is selected as the detail's own rows are (`ToolSelectableRows`):
/// across cells and rows, and copied with a tab between cells and a line per
/// row.
@MainActor final class DetailTableView: ToolSelectableRows {
    let table: UEFIDetailTable
    /// The header line, then one row per table row.
    private(set) var rows: [DetailTableRow] = []
    private var widths: [CGFloat] = []
    private let rowHeight: CGFloat

    static let columnSpacing: CGFloat = 14
    static let rowSpacing: CGFloat = 2

    init(table: UEFIDetailTable, onFollow: @escaping (UEFIDetailTable.Target) -> Void) {
        self.table = table
        let body = ToolPanelFont.body()
        let bold = ToolPanelFont.body(weight: .semibold)
        rowHeight = ceil(max(NSLayoutManager().defaultLineHeight(for: body),
                             NSLayoutManager().defaultLineHeight(for: bold)))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        rows.append(DetailTableRow(
            cells: table.columns.map { .init(text: $0, font: body, color: .secondaryLabelColor) },
            target: nil, linkColumn: nil, onFollow: onFollow))
        for (index, row) in table.rows.enumerated() {
            let target = index < table.rowTargets.count ? table.rowTargets[index] : nil
            rows.append(DetailTableRow(
                cells: row.enumerated().map { column, cell in
                    // A permission is read by its colour as much as by its
                    // word, which is the whole point of drawing this as a
                    // table: a column of green with one red in it answers at
                    // a glance. The address of a row that leads somewhere
                    // reads as a link, the one cue a line of text can give.
                    switch cell.tone {
                    case .yes: return .init(text: cell.text, font: bold, color: SemanticColors.good)
                    case .no: return .init(text: cell.text, font: bold, color: SemanticColors.bad)
                    case .plain:
                        let link = target != nil && column == table.linkColumn
                        return .init(text: cell.text, font: body, color: link ? .linkColor : .labelColor)
                    }
                },
                target: target, linkColumn: target == nil ? nil : table.linkColumn, onFollow: onFollow))
        }
        rows.forEach(addSubview)

        let columns = table.columns.count
        widths = (0..<columns).map { column in
            rows.map { $0.naturalWidth(of: column) }.max() ?? 0
        }
        var x: CGFloat = 0
        let offsets = widths.map { width -> CGFloat in
            defer { x += width + Self.columnSpacing }
            return x
        }
        rows.forEach { $0.setColumns(offsets: offsets, widths: widths) }

        // As wide as its columns, and no wider; narrower when the list is,
        // its last column giving way.
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh - 10, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var selectableRows: [any ToolSelectableRow] { rows }

    override var intrinsicContentSize: NSSize {
        let width = widths.reduce(0, +) + Self.columnSpacing * CGFloat(max(0, widths.count - 1))
        let height = CGFloat(rows.count) * rowHeight + CGFloat(max(0, rows.count - 1)) * Self.rowSpacing
        return NSSize(width: ceil(width), height: height)
    }

    override func layout() {
        super.layout()
        // A row takes the spacing under it, so that a selection running
        // through several rows is one band rather than stripes.
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let spacing = index == rows.count - 1 ? 0 : Self.rowSpacing
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight + spacing)
            y += rowHeight + spacing
        }
    }
}

/// One line of a detail table: its cells, drawn at the offsets the table
/// measured, and — when the row leads somewhere — a link in one of them.
///
/// The link is the row's one live zone: a click on the link cell's text
/// follows it, under a pointing hand and with what it does under the pointer;
/// a click anywhere else on the row selects text, which the table does. A
/// right click copies the selection, or with none, the cell under the pointer.
@MainActor final class DetailTableRow: NSView, ToolSelectableRow {
    struct Cell {
        var text: String
        var font: NSFont
        var color: NSColor
    }

    /// A place in the row: a column, and an offset into that cell's text.
    typealias Mark = ToolTextMark

    /// The part of the table's selection in this row.
    var selectedRange: Range<Mark>? {
        didSet { if selectedRange != oldValue { needsDisplay = true } }
    }

    let cells: [Cell]
    let target: UEFIDetailTable.Target?
    /// The column the link is drawn in. Nil for a row that leads nowhere.
    let linkColumn: Int?
    private let onFollow: (UEFIDetailTable.Target) -> Void
    private var offsets: [CGFloat] = []
    private var widths: [CGFloat] = []

    init(cells: [Cell], target: UEFIDetailTable.Target?, linkColumn: Int?,
         onFollow: @escaping (UEFIDetailTable.Target) -> Void) {
        self.cells = cells
        self.target = target
        self.linkColumn = linkColumn
        self.onFollow = onFollow
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The cells' words, in order — what a reader, VoiceOver and the tests read.
    var texts: [String] { cells.map(\.text) }

    func naturalWidth(of column: Int) -> CGFloat {
        guard column < cells.count else { return 0 }
        return ceil(strings[column].size().width)
    }

    func setColumns(offsets: [CGFloat], widths: [CGFloat]) {
        self.offsets = offsets
        self.widths = widths
        needsDisplay = true
    }

    private lazy var strings: [NSAttributedString] = cells.map { cell in
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: cell.text, attributes: [
            .font: cell.font, .foregroundColor: cell.color, .paragraphStyle: style,
        ])
    }

    /// The cells set as lines, which say where each character falls.
    private lazy var lines: [CTLine] = strings.map { CTLineCreateWithAttributedString($0) }

    private func length(_ column: Int) -> Int { (cells[column].text as NSString).length }

    /// Where the character at `index` of a cell starts, from the cell's left.
    private func offset(_ column: Int, _ index: Int) -> CGFloat {
        CTLineGetOffsetForStringIndex(lines[column], index, nil)
    }

    /// Where a cell is drawn: its column, the last one cut at the row's edge.
    private func rect(of column: Int) -> NSRect {
        guard column < offsets.count else { return .zero }
        let x = offsets[column]
        let isLast = column == offsets.count - 1
        let width = isLast ? max(0, min(widths[column], bounds.width - x)) : widths[column]
        return NSRect(x: x, y: 0, width: width, height: bounds.height)
    }

    /// Whether the cell is cut short at the row's edge.
    private func isCut(_ column: Int) -> Bool {
        column < cells.count && rect(of: column).width < naturalWidth(of: column)
    }

    /// The link's own zone: the link cell's text, not its whole column.
    var linkZone: NSRect? {
        guard let linkColumn, linkColumn < cells.count else { return nil }
        var zone = rect(of: linkColumn)
        zone.size.width = min(zone.width, naturalWidth(of: linkColumn))
        return zone.isEmpty ? nil : zone
    }

    override func draw(_ dirtyRect: NSRect) {
        drawSelection()
        for column in cells.indices {
            let cellRect = rect(of: column)
            guard cellRect.width > 0, cellRect.intersects(dirtyRect) else { continue }
            strings[column].draw(with: cellRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// The selection's band: through the gap after a cell when it runs on
    /// into the next one, as a text view's runs through a tab.
    private func drawSelection() {
        guard let selected = selectedRange, !cells.isEmpty else { return }
        NSColor.selectedTextBackgroundColor.setFill()
        let last = min(selected.upperBound.part, cells.count - 1)
        for column in selected.lowerBound.part...last {
            let cellRect = rect(of: column)
            let from = column == selected.lowerBound.part ? selected.lowerBound.index : 0
            let x0 = cellRect.minX + offset(column, from)
            let x1: CGFloat
            if column < last, column + 1 < offsets.count {
                x1 = offsets[column + 1]
            } else {
                let to = column == selected.upperBound.part ? selected.upperBound.index : length(column)
                x1 = min(cellRect.minX + offset(column, to), cellRect.maxX)
            }
            if x1 > x0 { NSRect(x: x0, y: 0, width: x1 - x0, height: bounds.height).fill() }
        }
    }

    // MARK: - Places in the text

    var startMark: Mark { Mark(part: 0, index: 0) }

    var endMark: Mark {
        cells.isEmpty ? startMark : Mark(part: cells.count - 1, index: length(cells.count - 1))
    }

    /// The place nearest `point`: in the cell it falls on, or at the end of
    /// the cell whose gap it falls in.
    func mark(at point: NSPoint) -> Mark {
        let x = point.x
        guard !cells.isEmpty, !offsets.isEmpty else { return startMark }
        let column = cells.indices.last { $0 < offsets.count && x >= offsets[$0] } ?? 0
        let local = x - offsets[column]
        guard local > 0 else { return Mark(part: column, index: 0) }
        guard local < naturalWidth(of: column) else { return Mark(part: column, index: length(column)) }
        let index = CTLineGetStringIndexForPosition(lines[column], CGPoint(x: local, y: 0))
        return Mark(part: column, index: index == kCFNotFound ? 0 : min(max(0, index), length(column)))
    }

    /// The word around `mark`, within its cell.
    func word(at mark: Mark) -> Range<Mark> {
        let count = length(mark.part)
        guard count > 0 else { return mark..<mark }
        let word = strings[mark.part].doubleClick(at: min(mark.index, count - 1))
        return Mark(part: mark.part, index: word.lowerBound)..<Mark(part: mark.part, index: word.upperBound)
    }

    /// The text between two places, a tab between cells.
    func text(in range: Range<Mark>) -> String {
        let last = min(range.upperBound.part, cells.count - 1)
        guard range.lowerBound.part <= last else { return "" }
        return (range.lowerBound.part...last).map { column in
            let text = cells[column].text as NSString
            let from = column == range.lowerBound.part ? range.lowerBound.index : 0
            let to = column == range.upperBound.part ? range.upperBound.index : text.length
            return text.substring(with: NSRange(location: from, length: max(0, to - from)))
        }.joined(separator: "\t")
    }

    // MARK: - The link

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !follow(at: point) { super.mouseDown(with: event) }
    }

    /// Follows the link when `point` is in its zone. True when it was.
    @discardableResult
    func follow(at point: NSPoint) -> Bool {
        guard let target, let zone = linkZone, zone.contains(point) else { return false }
        onFollow(target)
        return true
    }

    /// A pointing hand over the link, a text cursor over the rest of the row.
    override func resetCursorRects() {
        guard let zone = linkZone else { return addCursorRect(bounds, cursor: .iBeam) }
        addCursorRect(zone, cursor: .pointingHand)
        addCursorRect(NSRect(x: bounds.minX, y: 0, width: zone.minX - bounds.minX, height: bounds.height),
                      cursor: .iBeam)
        addCursorRect(NSRect(x: zone.maxX, y: 0, width: bounds.maxX - zone.maxX, height: bounds.height),
                      cursor: .iBeam)
    }

    override func layout() {
        super.layout()
        updateToolTips()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateToolTips()
    }

    /// What the pointer is told: where the link goes, over the link; the
    /// whole text, over a cell cut short.
    private func updateToolTips() {
        removeAllToolTips()
        if let zone = linkZone { addToolTip(zone, owner: self, userData: nil) }
        let last = cells.count - 1
        if last >= 0, last != linkColumn, isCut(last) {
            addToolTip(rect(of: last), owner: self, userData: nil)
        }
    }

    // MARK: - Copying

    // help: panel.uefi.table-copy
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let column = cells.indices.first { rect(of: $0).insetBy(dx: -7, dy: 0).contains(point) }
        return NSMenu.copyMenu(selection: (superview as? ToolSelectableRows)?.selectedText,
                               fallback: column.map { cells[$0].text })
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? {
        target == nil ? .staticText : .link
    }

    override func accessibilityLabel() -> String? {
        texts.joined(separator: ", ")
    }

    override func accessibilityPerformPress() -> Bool {
        guard let target else { return false }
        onFollow(target)
        return true
    }
}

extension DetailTableRow: NSViewToolTipOwner {
    nonisolated func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
                          point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        MainActor.assumeIsolated {
            if let zone = linkZone, zone.contains(point), let target {
                switch target {
                case .node: return L("Show this copy")
                case .range: return L("Show this region in the dump")
                }
            }
            return cells.last?.text ?? ""
        }
    }
}
