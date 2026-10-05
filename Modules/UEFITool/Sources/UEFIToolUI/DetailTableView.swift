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
        var y: CGFloat = 0
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
            y += rowHeight + Self.rowSpacing
        }
    }
}

/// One line of a detail table: its cells, drawn at the offsets the table
/// measured, and — when the row leads somewhere — a link in one of them.
///
/// The link is the row's one live zone: a click on the link cell's text
/// follows it, under a pointing hand and with what it does under the pointer;
/// a click anywhere else on the row is a click on text. A right click copies
/// the cell under the pointer, which is what a selectable field used to give.
@MainActor final class DetailTableRow: NSView {
    struct Cell {
        var text: String
        var font: NSFont
        var color: NSColor
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
        return ceil(string(column).size().width)
    }

    func setColumns(offsets: [CGFloat], widths: [CGFloat]) {
        self.offsets = offsets
        self.widths = widths
        needsDisplay = true
    }

    private func string(_ column: Int) -> NSAttributedString {
        let cell = cells[column]
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: cell.text, attributes: [
            .font: cell.font, .foregroundColor: cell.color, .paragraphStyle: style,
        ])
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
        for column in cells.indices {
            let cellRect = rect(of: column)
            guard cellRect.width > 0, cellRect.intersects(dirtyRect) else { continue }
            string(column).draw(with: cellRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
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

    override func resetCursorRects() {
        if let zone = linkZone { addCursorRect(zone, cursor: .pointingHand) }
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
        guard let column = cells.indices.first(where: { rect(of: $0).insetBy(dx: -7, dy: 0).contains(point) })
        else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: L("Copy"), action: #selector(copyCell(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = cells[column].text
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
