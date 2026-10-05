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
/// The text is selected the way a text view's is — a drag across cells and
/// rows, a double click for a word, a triple click for a row, ⌘A for the
/// table — and ⌘C copies it with a tab between cells and a line per row, which
/// a spreadsheet takes as the table it was. The selection is the table's, not
/// a row's, so that it can run from one row into the next.
@MainActor final class DetailTableView: NSView {
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

    override var isFlipped: Bool { true }

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

    // MARK: - Selecting text

    /// A place between two characters of the table: a row, and a place in it.
    struct Spot: Comparable {
        var row: Int
        var mark: DetailTableRow.Mark
        static func < (a: Spot, b: Spot) -> Bool { (a.row, a.mark) < (b.row, b.mark) }
    }

    /// The selected text's ends. Nil when nothing is selected.
    private(set) var selection: Range<Spot>?

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        select(nil)
        return true
    }

    /// A click beside a row's link lands here, passed up from the row: it
    /// selects from where it fell to where the drag lets go.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        window.makeFirstResponder(self)
        let start = spot(at: convert(event.locationInWindow, from: nil))
        let unit: Range<Spot>
        switch event.clickCount {
        case 1: unit = start..<start
        case 2: unit = word(at: start)
        default: unit = wholeRow(start.row)
        }
        select(unit)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]),
              next.type == .leftMouseDragged {
            autoscroll(with: next)
            extend(unit, to: convert(next.locationInWindow, from: nil))
        }
    }

    /// The selection from `unit` — the place, word or row the click took — to
    /// the place under `point`.
    func extend(_ unit: Range<Spot>, to point: NSPoint) {
        let end = spot(at: point)
        select(min(unit.lowerBound, end)..<max(unit.upperBound, end))
    }

    func select(_ range: Range<Spot>?) {
        selection = range?.isEmpty == false ? range : nil
        for index in rows.indices { rows[index].selected = span(of: index) }
    }

    /// The place under `point`: above the table its start, below it its end.
    func spot(at point: NSPoint) -> Spot {
        guard let last = rows.indices.last else { return Spot(row: 0, mark: .init(column: 0, index: 0)) }
        guard point.y >= 0 else { return Spot(row: 0, mark: rows[0].start) }
        let row = Int(point.y / (rowHeight + Self.rowSpacing))
        guard row <= last else { return Spot(row: last, mark: rows[last].end) }
        return Spot(row: row, mark: rows[row].mark(at: point.x))
    }

    private func word(at spot: Spot) -> Range<Spot> {
        let marks = rows[spot.row].word(at: spot.mark)
        return Spot(row: spot.row, mark: marks.lowerBound)..<Spot(row: spot.row, mark: marks.upperBound)
    }

    private func wholeRow(_ row: Int) -> Range<Spot> {
        Spot(row: row, mark: rows[row].start)..<Spot(row: row, mark: rows[row].end)
    }

    /// The part of the selection in one row.
    private func span(of row: Int) -> Range<DetailTableRow.Mark>? {
        guard let selection, (selection.lowerBound.row...selection.upperBound.row).contains(row)
        else { return nil }
        let start = selection.lowerBound.row == row ? selection.lowerBound.mark : rows[row].start
        let end = selection.upperBound.row == row ? selection.upperBound.mark : rows[row].end
        return start < end ? start..<end : nil
    }

    /// What is selected, a tab between cells and a line per row.
    var selectedText: String? {
        guard let selection else { return nil }
        let lines = (selection.lowerBound.row...selection.upperBound.row).compactMap { row in
            span(of: row).map { rows[row].text(in: $0) }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        guard let first = rows.indices.first, let last = rows.indices.last else { return }
        select(Spot(row: first, mark: rows[first].start)..<Spot(row: last, mark: rows[last].end))
    }

    /// ⌘C and ⌘A while the table has the focus. The Edit menu's own Copy and
    /// Select All are the dump's — they copy and select bytes — so the table
    /// answers these keys before the menu is asked.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "c" where selection != nil: copy(nil); return true
        case "a": selectAll(nil); return true
        default: return super.performKeyEquivalent(with: event)
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
@MainActor final class DetailTableRow: NSView {
    struct Cell {
        var text: String
        var font: NSFont
        var color: NSColor
    }

    /// A place between two characters of the row: a column, and a UTF-16
    /// offset into that cell's text.
    struct Mark: Comparable {
        var column: Int
        var index: Int
        static func < (a: Mark, b: Mark) -> Bool { (a.column, a.index) < (b.column, b.index) }
    }

    /// The part of the table's selection in this row.
    var selected: Range<Mark>? {
        didSet { if selected != oldValue { needsDisplay = true } }
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
        guard let selected, !cells.isEmpty else { return }
        NSColor.selectedTextBackgroundColor.setFill()
        let last = min(selected.upperBound.column, cells.count - 1)
        for column in selected.lowerBound.column...last {
            let cellRect = rect(of: column)
            let from = column == selected.lowerBound.column ? selected.lowerBound.index : 0
            let x0 = cellRect.minX + offset(column, from)
            let x1: CGFloat
            if column < last, column + 1 < offsets.count {
                x1 = offsets[column + 1]
            } else {
                let to = column == selected.upperBound.column ? selected.upperBound.index : length(column)
                x1 = min(cellRect.minX + offset(column, to), cellRect.maxX)
            }
            if x1 > x0 { NSRect(x: x0, y: 0, width: x1 - x0, height: bounds.height).fill() }
        }
    }

    // MARK: - Places in the text

    var start: Mark { Mark(column: 0, index: 0) }

    var end: Mark {
        cells.isEmpty ? start : Mark(column: cells.count - 1, index: length(cells.count - 1))
    }

    /// The place nearest `x`: in the cell it falls on, or at the end of the
    /// cell whose gap it falls in.
    func mark(at x: CGFloat) -> Mark {
        guard !cells.isEmpty, !offsets.isEmpty else { return start }
        let column = cells.indices.last { $0 < offsets.count && x >= offsets[$0] } ?? 0
        let local = x - offsets[column]
        guard local > 0 else { return Mark(column: column, index: 0) }
        guard local < naturalWidth(of: column) else { return Mark(column: column, index: length(column)) }
        let index = CTLineGetStringIndexForPosition(lines[column], CGPoint(x: local, y: 0))
        return Mark(column: column, index: index == kCFNotFound ? 0 : min(max(0, index), length(column)))
    }

    /// The word around `mark`, within its cell.
    func word(at mark: Mark) -> Range<Mark> {
        let count = length(mark.column)
        guard count > 0 else { return mark..<mark }
        let word = strings[mark.column].doubleClick(at: min(mark.index, count - 1))
        return Mark(column: mark.column, index: word.lowerBound)..<Mark(column: mark.column, index: word.upperBound)
    }

    /// The text between two places, a tab between cells.
    func text(in range: Range<Mark>) -> String {
        let last = min(range.upperBound.column, cells.count - 1)
        guard range.lowerBound.column <= last else { return "" }
        return (range.lowerBound.column...last).map { column in
            let text = cells[column].text as NSString
            let from = column == range.lowerBound.column ? range.lowerBound.index : 0
            let to = column == range.upperBound.column ? range.upperBound.index : text.length
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
        let text: String
        if let selection = (superview as? DetailTableView)?.selectedText {
            text = selection
        } else if let column = cells.indices.first(where: { rect(of: $0).insetBy(dx: -7, dy: 0).contains(point) }) {
            text = cells[column].text
        } else {
            return nil
        }
        let menu = NSMenu()
        let item = NSMenuItem(title: L("Copy"), action: #selector(copyCell(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = text
        menu.addItem(item)
        return menu
    }

    @objc private func copyCell(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
