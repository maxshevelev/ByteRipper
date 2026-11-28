import AppKit

/// A row of a navigator tab's tree that has rows under it.
protocol CodeNavigatorTreeNode: AnyObject {
    /// The rows a level under it, in order.
    var treeChildren: [AnyObject] { get }
}

/// The outline every navigator tab draws its tree in: the rows draw their
/// own chevron (`CodeNavigatorCell`), so the outline's triangle takes no
/// room and is never drawn.
final class CodeNavigatorOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
}

/// What the navigator's tabs — Search, Interfaces and a record's section —
/// share: one outline in a scroll view, its rows given by the tab's nodes,
/// the chevron redrawn as a branch opens and closes, a row chosen by a click
/// or by the arrow keys, and the zoom remaking the rows with what the reader
/// opened kept open and the top row at the top.
///
/// A tab gives its roots, its cells and what choosing a row does; the tree's
/// mechanics are here, once, so the tabs behave as one.
class CodeNavigatorTreePanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = CodeNavigatorOutlineView()
    let outlineScroll = NSScrollView()
    /// The rows of the first level.
    var roots: [AnyObject] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The navigator has no fill of its own; a tab takes the window's, so the
    /// list it stands over does not show through. Inside the tab only: a view
    /// does not clip to its bounds (macOS 14), and the rect asked for can
    /// reach over the header above it.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }

    /// One column, no header, the navigator's rows; a click chooses its row.
    func setUpOutline(column identifier: String) {
        let column = NSTableColumn(identifier: .init(identifier))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        CodeNavigatorCell.dress(outline)
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.drawsBackground = false
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - The tree

    /// The rows under `item`, the roots under nil.
    func children(of item: AnyObject?) -> [AnyObject] {
        guard let item else { return roots }
        return (item as? CodeNavigatorTreeNode)?.treeChildren ?? []
    }

    /// Whether the row opens: by default, when it has rows under it.
    func isExpandable(_ item: AnyObject) -> Bool { !children(of: item).isEmpty }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item as AnyObject?).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item as AnyObject?)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        isExpandable(item as AnyObject)
    }

    // MARK: - Opening and closing

    /// Opens or closes a row, its rows sliding in or out as the Functions
    /// list's do; the chevron has already turned.
    func toggle(_ item: AnyObject) {
        CodeNavigatorCell.toggle(item, in: outline)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as AnyObject? else { return }
        redrawChevron(item)
        didOpen(item)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as AnyObject? else { return }
        redrawChevron(item)
        didClose(item)
    }

    /// A row the reader opened; for a tab that keeps what is open.
    func didOpen(_ item: AnyObject) {}
    /// A row the reader closed.
    func didClose(_ item: AnyObject) {}

    /// Only the chevron is drawn again: the row is not made anew, so nothing
    /// in it changes as it opens and closes.
    func redrawChevron(_ item: AnyObject) {
        let row = outline.row(forItem: item)
        guard row >= 0,
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? CodeNavigatorCell
        else { return }
        cell.showsCalls(expandable: isExpandable(item), expanded: outline.isItemExpanded(item))
    }

    // MARK: - Choosing a row

    @objc private func rowClicked() {
        guard outline.clickedRow >= 0, let item = outline.item(atRow: outline.clickedRow) else { return }
        choose(item as AnyObject)
    }

    /// The arrow keys walk the rows as clicks would.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        selectionChanged()
        guard NSApp.currentEvent?.type == .keyDown, let item = outline.item(atRow: outline.selectedRow) else { return }
        choose(item as AnyObject)
    }

    /// The row at `row` chosen, as a click chooses it.
    func choose(row: Int) {
        guard row >= 0, let item = outline.item(atRow: row) else { return }
        choose(item as AnyObject)
    }

    /// What choosing a row does: the tab's.
    func choose(_ item: AnyObject) {}

    /// The selection changed, by any means.
    func selectionChanged() {}

    // MARK: - Remaking the rows

    /// The rows made again — at a new zoom, for a new state of the same
    /// nodes — with what was open still open and the top row at the top.
    func reloadKeepingPlace() {
        let open = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as AnyObject? }
            .filter { outline.isItemExpanded($0) }
        let top = outline.row(at: NSPoint(x: 0, y: outlineScroll.contentView.bounds.minY))
        let topItem = top >= 0 ? outline.item(atRow: top) as AnyObject? : nil
        outline.reloadData()
        for item in open { outline.expandItem(item) }
        measuredWidth = 0
        noteRowHeightsChanged()
        if let topItem {
            let row = outline.row(forItem: topItem)
            if row >= 0 { outline.scroll(outline.rect(ofRow: row).origin) }
        }
    }

    /// The zoom changed: the rows are made again in the new size.
    func zoomChanged() {
        outline.rowHeight = CodePaneView.navigatorRowHeight
        reloadKeepingPlace()
    }

    /// A width the rows have not been measured at: a row that wraps is as
    /// tall as its lines, so a new width measures them anew.
    private var measuredWidth: CGFloat = 0

    /// Whether a row's height follows its text's lines: such a tab measures
    /// its rows again at a new width. A tab of one-line rows does not.
    var rowsWrap: Bool { false }

    override func layout() {
        super.layout()
        guard rowsWrap else { return }
        let width = outline.bounds.width
        guard width != measuredWidth, outline.numberOfRows > 0 else { return }
        measuredWidth = width
        noteRowHeightsChanged()
    }

    private func noteRowHeightsChanged() {
        guard outline.numberOfRows > 0 else { return }
        outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
    }
}

/// A navigator row's styled text in the navigator's type: each tone its
/// font and colour.
@MainActor
enum CodeNavigatorText {
    static func attributed(_ text: CodeStyledText) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for part in text.parts {
            result.append(NSAttributedString(string: part.text, attributes: attributes(part.tone)))
        }
        return result
    }

    static func attributes(_ tone: CodeStyledText.Tone) -> [NSAttributedString.Key: Any] {
        switch tone {
        case .plain: [.font: CodePaneView.navigatorFont(), .foregroundColor: NSColor.labelColor]
        case .quiet: [.font: CodePaneView.navigatorFont(), .foregroundColor: NSColor.secondaryLabelColor]
        case .link: [.font: CodePaneView.navigatorFont(), .foregroundColor: NSColor.linkColor]
        case .mono: [.font: NSFont.monospacedSystemFont(ofSize: CodePaneView.navigatorSize - 1, weight: .regular),
                     .foregroundColor: NSColor.secondaryLabelColor]
        }
    }
}
