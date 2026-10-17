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
///
/// A table with sections (`UEFIDetailTable.Section`) draws each under a line
/// of its own with a disclosure triangle, folded until the reader opens it;
/// the rows of every section line up in the same columns, open or folded, so
/// opening one never moves another. Such a table has no header line of its
/// own: each open section carries the column names over its rows, where a
/// reader who has scrolled seventy words down still sees them. Its first
/// column is held to `firstColumnLimit`, and a name longer than that wraps
/// onto a further line: one long name in seventy words would otherwise push
/// every value of the table to the right.
@MainActor final class DetailTableView: ToolSelectableRows {
    let table: UEFIDetailTable
    /// The header line, then the table's rows — under a section's line each,
    /// where the table has sections — in the order they are drawn.
    private(set) var rows: [DetailTableRow] = []
    /// Each section's line, by section.
    private(set) var sectionRows: [DetailTableRow] = []
    /// The sections open, by title.
    private(set) var openSections: Set<String>
    /// Which section each row of `rows` belongs to; nil for the header line.
    private var sectionOfRow: [Int?] = []
    private var widths: [CGFloat] = []
    private let rowHeight: CGFloat
    private let onToggleSection: (String, Bool) -> Void

    static let columnSpacing: CGFloat = 14
    static let rowSpacing: CGFloat = 2

    /// The widest a sectioned table's first column grows, following the
    /// zoom with the type. Chosen once from the names it holds rather than
    /// measured at every showing: in each of the strap tables at hand
    /// (`DescriptorStrapMap.all`) nineteen names in twenty are no wider than
    /// 290 to 302 points at the default size, and the longest is 415 — the
    /// long tail (`CSME_CSE_SSS_EMUL_HVM_OVR_SOC_DEV_REUSE_PROHIBITED`) that
    /// would otherwise set the width of all seventy words. 256 at the design
    /// size is 303 at the default one.
    static var firstColumnLimit: CGFloat { ToolPanelFont.scaled(256) }

    /// `openSections` are the sections drawn open; `onToggleSection` hears a
    /// section opened or folded, for the panel to keep it so.
    init(table: UEFIDetailTable, openSections: Set<String> = [],
         onFollow: @escaping (UEFIDetailTable.Target) -> Void,
         onToggleSection: @escaping (String, Bool) -> Void = { _, _ in }) {
        self.table = table
        self.openSections = openSections
        self.onToggleSection = onToggleSection
        let body = ToolPanelFont.body()
        let bold = ToolPanelFont.body(weight: .semibold)
        rowHeight = ceil(max(NSLayoutManager().defaultLineHeight(for: body),
                             NSLayoutManager().defaultLineHeight(for: bold)))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        rows.append(DetailTableRow(
            cells: table.columns.map { .init(text: $0, font: body, color: .secondaryLabelColor) },
            target: nil, linkColumn: nil, onFollow: onFollow))
        sectionOfRow.append(nil)
        var fieldRows: [DetailTableRow] = []
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
                        return .init(text: cell.text, font: cell.isStrong ? bold : body,
                                     color: link ? .linkColor : .labelColor)
                    }
                },
                target: target, linkColumn: target == nil ? nil : table.linkColumn, onFollow: onFollow))
        }
        fieldRows = Array(rows.dropFirst())

        let columns = table.columns.count
        widths = (0..<columns).map { column in
            rows.map { $0.naturalWidth(of: column) }.max() ?? 0
        }
        if !table.sections.isEmpty, !widths.isEmpty {
            widths[0] = min(widths[0], Self.firstColumnLimit)
            rows.forEach { $0.wrapFirstCell(at: widths[0]) }
        }
        // Under sections the columns start where a section's words do, past
        // its triangle, so a section's rows read as inside it.
        let indent = table.sections.isEmpty ? 0 : DetailTableRow.disclosureWidth(for: body)
        var x: CGFloat = indent
        let offsets = widths.map { width -> CGFloat in
            defer { x += width + Self.columnSpacing }
            return x
        }
        rows.forEach { $0.setColumns(offsets: offsets, widths: widths) }
        if indent > 0 {
            widths[0] += indent
        }

        if !table.sections.isEmpty {
            buildSections(fieldRows: fieldRows, indent: indent, body: body, bold: bold,
                          offsets: offsets, onFollow: onFollow)
        }
        rows.forEach(addSubview)
        applyOpenSections()

        // As wide as its columns, and no wider; narrower when the list is,
        // its last column giving way.
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh - 10, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The rows in order with a section's line before its rows, and the
    /// section lines' own columns: the title, what the rows share, and the
    /// address, each as wide as its widest so the addresses line up.
    private func buildSections(fieldRows: [DetailTableRow], indent: CGFloat,
                               body: NSFont, bold: NSFont, offsets: [CGFloat],
                               onFollow: @escaping (UEFIDetailTable.Target) -> Void) {
        let header = rows[0]
        var ordered: [DetailTableRow] = []
        var owners: [Int?] = []
        for (index, section) in table.sections.enumerated() {
            let line = DetailTableRow(
                cells: [.init(text: section.title, font: bold, color: .labelColor),
                        .init(text: section.subtitle ?? "", font: body, color: .secondaryLabelColor),
                        .init(text: section.address ?? "", font: body,
                              color: section.target == nil ? .labelColor : .linkColor),
                        // What the folded rows hold that stands out, in the
                        // weight those rows' values are drawn in.
                        .init(text: section.note ?? "", font: bold, color: .labelColor)],
                target: section.target, linkColumn: section.target == nil ? nil : 2,
                onFollow: onFollow)
            line.onToggle = { [weak self] in self?.toggle(section: index) }
            sectionRows.append(line)
            ordered.append(line)
            owners.append(index)
            // The column names, over this section's rows.
            let names = DetailTableRow(cells: header.cells, target: nil, linkColumn: nil,
                                       onFollow: onFollow)
            names.setColumns(offsets: offsets, widths: widths)
            ordered.append(names)
            owners.append(index)
            for row in section.rows where row < fieldRows.count {
                ordered.append(fieldRows[row])
                owners.append(index)
            }
        }
        let lineWidths = (0..<4).map { column in
            sectionRows.map { $0.naturalWidth(of: column) }.max() ?? 0
        }
        var x = indent
        let lineOffsets = lineWidths.map { width -> CGFloat in
            defer { x += width + Self.columnSpacing }
            return x
        }
        sectionRows.forEach { $0.setColumns(offsets: lineOffsets, widths: lineWidths) }
        rows = ordered
        sectionOfRow = owners
        // The table is as wide as the wider of its columns and its lines.
        let linesWidth = x - Self.columnSpacing
        let columnsWidth = widths.reduce(0, +) + Self.columnSpacing * CGFloat(max(0, widths.count - 1))
        if linesWidth > columnsWidth, !widths.isEmpty {
            widths[widths.count - 1] += linesWidth - columnsWidth
        }
    }

    /// Shows the rows of the open sections and hides the rest.
    private func applyOpenSections() {
        guard !table.sections.isEmpty else { return }
        for (index, row) in rows.enumerated() {
            guard let section = sectionOfRow[index] else { continue }
            let title = table.sections[section].title
            if row === sectionRows[section] {
                row.disclosure = openSections.contains(title)
            } else {
                row.isHidden = !openSections.contains(title)
            }
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Opens a folded section or folds an open one.
    func toggle(section index: Int) {
        guard table.sections.indices.contains(index) else { return }
        let title = table.sections[index].title
        let open = !openSections.contains(title)
        if open { openSections.insert(title) } else { openSections.remove(title) }
        // The selection is kept by row number, and the rows have just changed.
        select(nil)
        applyOpenSections()
        onToggleSection(title, open)
    }

    /// The rows on screen: a folded section's are not.
    private var visibleRows: [DetailTableRow] { rows.filter { !$0.isHidden } }

    override var selectableRows: [any ToolSelectableRow] { visibleRows }

    override var intrinsicContentSize: NSSize {
        let width = widths.reduce(0, +) + Self.columnSpacing * CGFloat(max(0, widths.count - 1))
        let shown = visibleRows
        let height = shown.map { $0.height(atLeast: rowHeight) }.reduce(0, +)
            + shown.indices.map { spacing(after: $0, in: shown) }.reduce(0, +)
        return NSSize(width: ceil(width), height: height)
    }

    /// The gap that closes an open section, before the next section's line:
    /// the rows a reader opened end, and the next word begins apart from
    /// them. Follows the zoom with the type.
    static var sectionGap: CGFloat { ToolPanelFont.scaled(5) }

    /// The spacing under the row at `index` of `shown`: none under the last,
    /// the section gap under the last row of an open section, the row
    /// spacing under any other.
    private func spacing(after index: Int, in shown: [DetailTableRow]) -> CGFloat {
        guard index < shown.count - 1 else { return 0 }
        let closesSection = shown[index].disclosure == nil && shown[index + 1].disclosure != nil
        return Self.rowSpacing + (closesSection ? Self.sectionGap : 0)
    }

    override func layout() {
        super.layout()
        // A row takes the spacing under it, so that a selection running
        // through several rows is one band rather than stripes.
        let shown = visibleRows
        var y: CGFloat = 0
        for (index, row) in shown.enumerated() {
            let spacing = spacing(after: index, in: shown)
            let height = row.height(atLeast: rowHeight)
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: height + spacing)
            y += height + spacing
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

    /// On a section's line, whether the section is open — the triangle drawn
    /// before the line's words. Nil on any other row.
    var disclosure: Bool? {
        didSet { if disclosure != oldValue { needsDisplay = true } }
    }
    /// A click on a section's line, away from its link: opens or folds it.
    var onToggle: (() -> Void)?

    /// The room a section's triangle takes before its words, at `font`.
    static func disclosureWidth(for font: NSFont) -> CGFloat {
        ceil(font.pointSize * 1.1)
    }
    /// The column the link is drawn in. Nil for a row that leads nowhere.
    let linkColumn: Int?
    private let onFollow: (UEFIDetailTable.Target) -> Void
    private var offsets: [CGFloat] = []
    private var widths: [CGFloat] = []
    /// The width the first cell wraps in, where it is wider than its
    /// column (`wrapFirstCell`). Nil on a row whose first cell fits.
    private var wrapWidth: CGFloat?
    private var wrappedCache: WrappedCell?

    /// The first cell laid out over several lines — built the first time the
    /// row is laid out or drawn, so the rows of a folded section never pay
    /// for it.
    private var wrapped: WrappedCell? {
        guard let wrapWidth else { return nil }
        if let wrappedCache { return wrappedCache }
        let cell = WrappedCell(strings[0], width: wrapWidth)
        wrappedCache = cell
        return cell
    }

    /// Lays the first cell out in `width`, over as many lines as it needs,
    /// where it is wider than that; a cell that fits stays one line.
    func wrapFirstCell(at width: CGFloat) {
        wrappedCache = nil
        wrapWidth = !cells.isEmpty && naturalWidth(of: 0) > width ? width : nil
        needsDisplay = true
    }

    /// How tall the row's text is: one line, or the lines its first cell
    /// wraps onto.
    func height(atLeast line: CGFloat) -> CGFloat {
        max(line, wrapped?.height ?? 0)
    }

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
        if let disclosure { drawDisclosure(open: disclosure) }
        for column in cells.indices {
            let cellRect = rect(of: column)
            guard cellRect.width > 0, cellRect.intersects(dirtyRect) else { continue }
            if column == 0, let wrapped {
                wrapped.draw(at: NSPoint(x: cellRect.minX, y: 0))
                continue
            }
            strings[column].draw(with: cellRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// The triangle before a section's words: pointing right when folded,
    /// down when open, as a disclosure triangle does.
    private func drawDisclosure(open: Bool) {
        guard let font = cells.first?.font else { return }
        let side = font.pointSize * 0.75
        let config = NSImage.SymbolConfiguration(pointSize: side, weight: .semibold)
            .applying(.init(paletteColors: [.secondaryLabelColor]))
        guard let image = NSImage(systemSymbolName: open ? "chevron.down" : "chevron.right",
                                  accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        let room = Self.disclosureWidth(for: font)
        image.draw(in: NSRect(x: (room - size.width) / 2, y: (bounds.height - Self.spacing - size.height) / 2,
                              width: size.width, height: size.height))
    }

    /// The spacing a row's frame carries under its text (`DetailTableView`).
    private static let spacing = DetailTableView.rowSpacing

    /// The selection's band: through the gap after a cell when it runs on
    /// into the next one, as a text view's runs through a tab.
    private func drawSelection() {
        guard let selected = selectedRange, !cells.isEmpty else { return }
        NSColor.selectedTextBackgroundColor.setFill()
        let last = min(selected.upperBound.part, cells.count - 1)
        for column in selected.lowerBound.part...last {
            let cellRect = rect(of: column)
            let from = column == selected.lowerBound.part ? selected.lowerBound.index : 0
            if column == 0, let wrapped {
                let to = column == selected.upperBound.part ? selected.upperBound.index : length(0)
                var rects = wrapped.rects(from: from, to: to, at: cellRect.origin)
                // Running on into the next cell: the band reaches it, on the
                // line the cell ends on.
                if column < last, offsets.count > 1, let end = rects.last {
                    rects[rects.count - 1] = NSRect(x: end.minX, y: end.minY,
                                                    width: offsets[1] - end.minX, height: end.height)
                }
                rects.forEach { $0.fill() }
                continue
            }
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
        if column == 0, let wrapped {
            return Mark(part: 0, index: wrapped.index(at: NSPoint(x: x - offsets[0], y: point.y)))
        }
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
        if follow(at: point) { return }
        // A section's line is its switch, all of it but the link.
        if let onToggle {
            onToggle()
            return
        }
        super.mouseDown(with: event)
    }

    /// Follows the link when `point` is in its zone. True when it was.
    @discardableResult
    func follow(at point: NSPoint) -> Bool {
        guard let target, let zone = linkZone, zone.contains(point) else { return false }
        onFollow(target)
        return true
    }

    /// A pointing hand over the link, a text cursor over the rest of the row
    /// — an arrow over a section's line, which is a switch, not text.
    override func resetCursorRects() {
        let rest: NSCursor = onToggle == nil ? .iBeam : .arrow
        guard let zone = linkZone else { return addCursorRect(bounds, cursor: rest) }
        addCursorRect(zone, cursor: .pointingHand)
        addCursorRect(NSRect(x: bounds.minX, y: 0, width: zone.minX - bounds.minX, height: bounds.height),
                      cursor: rest)
        addCursorRect(NSRect(x: zone.maxX, y: 0, width: bounds.maxX - zone.maxX, height: bounds.height),
                      cursor: rest)
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
        if disclosure != nil { return .disclosureTriangle }
        return target == nil ? .staticText : .link
    }

    override func accessibilityLabel() -> String? {
        texts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    override func accessibilityValue() -> Any? {
        disclosure.map { $0 ? 1 : 0 }
    }

    // help: panel.uefi.folding-table
    override func accessibilityPerformPress() -> Bool {
        if let onToggle {
            onToggle()
            return true
        }
        guard let target else { return false }
        onFollow(target)
        return true
    }
}

/// A cell too wide for its column, laid out by TextKit over several lines —
/// which also says where each character it drew has landed, so a click
/// selects the one it was on.
///
/// A strap field's name has no spaces to break at — `CSME_CSE_SSS_EMUL_EN` —
/// so it is broken after an underscore, where its words end: what is laid out
/// carries a zero-width space after each one, and the indices are mapped back
/// to the cell's own text, which is what is selected and copied.
@MainActor private final class WrappedCell {
    private let text: String
    private let storage: NSTextStorage
    private let layout = NSLayoutManager()
    private let container: NSTextContainer
    /// Where each break opportunity was added, as an index into the cell's
    /// own text: the place after each underscore.
    private let breaks: [Int]

    init(_ string: NSAttributedString, width: CGFloat) {
        text = string.string
        let shown = NSMutableAttributedString(attributedString: string)
        var breaks: [Int] = []
        let units = Array(text.utf16)
        for (index, unit) in units.enumerated().reversed() where unit == 0x5F && index < units.count - 1 {
            let attributes = shown.attributes(at: index, effectiveRange: nil)
            shown.insert(NSAttributedString(string: "\u{200B}", attributes: attributes), at: index + 1)
            breaks.append(index + 1)
        }
        self.breaks = breaks.reversed()
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        shown.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: shown.length))
        storage = NSTextStorage(attributedString: shown)
        container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
    }

    var height: CGFloat {
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    func draw(at origin: NSPoint) {
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: origin)
    }

    /// An index of the cell's text as an index of what is laid out.
    private func shown(_ index: Int) -> Int {
        index + breaks.filter { $0 <= index }.count
    }

    /// An index of what is laid out as one of the cell's text.
    private func own(_ index: Int) -> Int {
        index - breaks.enumerated().filter { $0.element + $0.offset < index }.count
    }

    /// The place nearest `point`, in the cell's own coordinates.
    func index(at point: NSPoint) -> Int {
        let count = (text as NSString).length
        guard count > 0, point.y >= 0 else { return 0 }
        guard point.y < height else { return count }
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let index = layout.characterIndexForGlyph(at: glyph) + (fraction > 0.5 ? 1 : 0)
        return min(max(0, own(index)), count)
    }

    /// What a selection from `from` to `to` covers, line by line, placed at
    /// `origin`.
    func rects(from: Int, to: Int, at origin: NSPoint) -> [NSRect] {
        guard to > from else { return [] }
        let range = NSRange(location: shown(from), length: shown(to) - shown(from))
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rects: [NSRect] = []
        layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs,
                                       in: container) { rect, _ in
            rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
        return rects
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
