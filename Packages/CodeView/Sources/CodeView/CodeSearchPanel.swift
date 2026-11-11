import AppKit
import Find
import Localization
import ToolModuleKit

/// The navigator's Search tab (#41): the app's query controls across the top,
/// a line saying what was found, and the occurrences as a tree — a function,
/// and under it the lines of its C that hold the pattern.
///
/// It shows what it is given and says what is chosen; the search itself is
/// the pane's.
final class CodeSearchPanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// A function with matches: a row of the first level.
    final class FunctionItem {
        let index: Int
        let name: String
        let children: [HitItem]
        init(index: Int, name: String, hits: [TextSearchHit]) {
            self.index = index
            self.name = name
            children = hits.map { HitItem(function: index, hit: $0) }
        }
    }

    /// One occurrence: a row of the second level.
    final class HitItem {
        let function: Int
        let hit: TextSearchHit
        init(function: Int, hit: TextSearchHit) {
            self.function = function
            self.hit = hit
        }
    }

    /// Where the app puts its query controls.
    let querySlot = NSView()
    let summaryLabel = NSTextField(labelWithString: "")
    let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private(set) var items: [FunctionItem] = []

    /// A row was chosen: the function, and the occurrence when it is one.
    var onChoose: ((_ function: Int, _ hit: TextSearchHit?) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The navigator has no fill of its own; the panel takes the window's, so
    /// the list it stands over does not show through.
    override func draw(_ dirtyRect: NSRect) {
        // Inside the panel only: a view does not clip to its bounds (macOS
        // 14), and the rect asked for can reach over the header above it.
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }

    private func build() {
        querySlot.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.init(240), for: .horizontal)

        let column = NSTableColumn(identifier: .init("occurrence"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.indentationPerLevel = 12
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(querySlot)
        addSubview(summaryLabel)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            querySlot.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            querySlot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            querySlot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            summaryLabel.topAnchor.constraint(equalTo: querySlot.bottomAnchor, constant: 6),
            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// The app's controls, laid across the top.
    var queryView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let queryView else { return }
            queryView.translatesAutoresizingMaskIntoConstraints = false
            querySlot.addSubview(queryView)
            NSLayoutConstraint.activate([
                queryView.topAnchor.constraint(equalTo: querySlot.topAnchor),
                queryView.bottomAnchor.constraint(equalTo: querySlot.bottomAnchor),
                queryView.leadingAnchor.constraint(equalTo: querySlot.leadingAnchor),
                queryView.trailingAnchor.constraint(equalTo: querySlot.trailingAnchor)
            ])
        }
    }

    // MARK: - What is shown

    /// Shows a search's result: every function opened on its occurrences.
    func show(_ items: [FunctionItem], truncated: Bool) {
        self.items = items
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        let hits = items.reduce(0) { $0 + $1.children.count }
        if items.isEmpty {
            summaryLabel.stringValue = L("No results")
        } else if truncated {
            summaryLabel.stringValue = L("The first %1$@ results in %2$@ functions — refine the pattern",
                                         String(hits), String(items.count))
        } else {
            summaryLabel.stringValue = L("%1$@ results in %2$@ functions", String(hits), String(items.count))
        }
    }

    /// Says what is happening instead of a result: reading, searching.
    func show(status: String) {
        summaryLabel.stringValue = status
    }

    /// Empties the list: the search it showed no longer stands.
    func clear() {
        items = []
        outline.reloadData()
        summaryLabel.stringValue = ""
    }

    // MARK: - The tree

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return items.count }
        return (item as? FunctionItem)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return items[index] }
        return (item as! FunctionItem).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is FunctionItem
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        ceil(ToolPanelFont.size * 1.6)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }()
        if let function = item as? FunctionItem {
            let line = NSMutableAttributedString(string: function.name, attributes: [
                .font: NSFont.systemFont(ofSize: ToolPanelFont.size, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ])
            line.append(NSAttributedString(string: "  \(function.children.count)", attributes: [
                .font: NSFont.systemFont(ofSize: ToolPanelFont.size - 1),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
            cell.textField?.attributedStringValue = line
        } else if let hit = item as? HitItem {
            cell.textField?.attributedStringValue = Self.line(of: hit.hit)
        }
        return cell
    }

    /// The occurrence's line in the code's type, the match set off as the
    /// code sets off a found match.
    static func line(of hit: TextSearchHit) -> NSAttributedString {
        let font = ToolPanelFont.monospaced(size: ToolPanelFont.size - 1, bold: false)
        let text = NSMutableAttributedString(string: hit.lineText, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor
        ])
        let length = text.length
        let start = min(hit.rangeInLine.lowerBound, length)
        let end = min(hit.rangeInLine.upperBound, length)
        if end > start {
            let range = NSRange(location: start, length: end - start)
            text.addAttribute(.font, value: ToolPanelFont.monospaced(size: font.pointSize, bold: true), range: range)
            text.addAttribute(.backgroundColor, value: CodePaneView.findMatchFill, range: range)
        }
        return text
    }

    @objc private func rowClicked() {
        guard outline.clickedRow >= 0 else { return }
        choose(row: outline.clickedRow)
    }

    /// The arrow keys walk the occurrences as clicks would.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard NSApp.currentEvent?.type == .keyDown else { return }
        choose(row: outline.selectedRow)
    }

    /// The row at `row` chosen, as a click chooses it.
    func choose(row: Int) {
        guard row >= 0, let item = outline.item(atRow: row) else { return }
        if let hit = item as? HitItem {
            onChoose?(hit.function, hit.hit)
        } else if let function = item as? FunctionItem {
            onChoose?(function.index, nil)
        }
    }
}
