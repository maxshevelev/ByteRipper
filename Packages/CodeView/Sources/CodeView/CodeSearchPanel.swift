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
        /// The mark the Functions list draws for it (`CodeNavigatorCell`).
        let mark: String?
        let children: [HitItem]
        init(index: Int, name: String, mark: String? = nil, hits: [TextSearchHit]) {
            self.index = index
            self.name = name
            self.mark = mark
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
    let outline = SearchOutlineView()
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
        // The rows draw their own chevron and inset, as the Functions list's
        // groups do; the outline's own triangle and indent are not used.
        outline.indentationPerLevel = 0
        outline.intercellSpacing = NSSize(width: 0, height: 0)
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
        let row = CodePaneView.navigatorRowHeight
        guard let hit = item as? HitItem else { return row }
        // A long line wraps: the row is as tall as its lines.
        let width = max(40, outlineView.bounds.width - Self.hitInset - Self.hitTrailing - 4)
        let height = Self.line(of: hit.hit)
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return max(row, ceil(height) + 2 * Self.hitPadding)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        if let function = item as? FunctionItem {
            let id = NSUserInterfaceItemIdentifier("function")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? CodeNavigatorCell
                ?? CodeNavigatorCell(identifier: id)
            cell.showsDisclosure(true)
            cell.showsCalls(expandable: true, expanded: outlineView.isItemExpanded(function))
            cell.onToggle = { [weak outlineView, weak cell] in
                guard let outlineView else { return }
                if outlineView.isItemExpanded(function) {
                    outlineView.collapseItem(function)
                } else {
                    outlineView.expandItem(function)
                }
                cell?.showsCalls(expandable: true, expanded: outlineView.isItemExpanded(function))
            }
            cell.showsIcon(function.mark)
            let line = NSMutableAttributedString(string: function.name, attributes: [
                .font: CodePaneView.navigatorBoldFont(), .foregroundColor: NSColor.labelColor
            ])
            line.append(NSAttributedString(string: "  \(function.children.count)", attributes: [
                .font: CodePaneView.navigatorFont(), .foregroundColor: NSColor.secondaryLabelColor
            ]))
            cell.textField?.attributedStringValue = line
            return cell
        }
        guard let hit = item as? HitItem else { return nil }
        let id = NSUserInterfaceItemIdentifier("hit")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(wrappingLabelWithString: "")
            text.maximumNumberOfLines = 0
            text.lineBreakMode = .byWordWrapping
            text.isSelectable = false
            text.translatesAutoresizingMaskIntoConstraints = false
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Self.hitInset),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Self.hitTrailing),
                text.topAnchor.constraint(equalTo: cell.topAnchor, constant: Self.hitPadding)
            ])
            return cell
        }()
        cell.textField?.attributedStringValue = Self.line(of: hit.hit)
        return cell
    }

    /// Where an occurrence's line starts: under the function's name, past
    /// the chevron and the mark, as a group's functions stand under it.
    static var hitInset: CGFloat {
        4 + CodeNavigatorCell.disclosureRoom
            + CodeNavigatorIcon.side(forFontSize: CodePaneView.navigatorSize) + 5
    }
    static let hitTrailing: CGFloat = 8
    static let hitPadding: CGFloat = 3

    /// A width the rows have not been measured at: the lines wrap anew.
    private var measuredWidth: CGFloat = 0

    override func layout() {
        super.layout()
        let width = outline.bounds.width
        guard width != measuredWidth, outline.numberOfRows > 0 else { return }
        measuredWidth = width
        outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
    }

    func outlineViewItemDidExpand(_ notification: Notification) { redrawChevron(notification) }
    func outlineViewItemDidCollapse(_ notification: Notification) { redrawChevron(notification) }

    private func redrawChevron(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? FunctionItem else { return }
        let row = outline.row(forItem: item)
        guard row >= 0,
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? CodeNavigatorCell
        else { return }
        cell.showsCalls(expandable: true, expanded: outline.isItemExpanded(item))
    }

    /// The occurrence's line in the code's type, the match set off as the
    /// code sets off a found match.
    static func line(of hit: TextSearchHit) -> NSAttributedString {
        // The navigator's own type, regular: a line to recognise, not code to
        // read — the code is a click away.
        let text = NSMutableAttributedString(string: hit.lineText, attributes: [
            .font: CodePaneView.navigatorFont(), .foregroundColor: NSColor.labelColor
        ])
        let length = text.length
        let start = min(hit.rangeInLine.lowerBound, length)
        let end = min(hit.rangeInLine.upperBound, length)
        if end > start {
            let range = NSRange(location: start, length: end - start)
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

/// The Search tab's tree: the rows draw their own chevron, so the outline's
/// triangle takes no room and is never drawn.
final class SearchOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
}
