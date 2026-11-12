import AppKit
import Find
import HelpUI
import Localization
import ToolModuleKit

/// The navigator's Search tab (#41), laid out as Xcode's Find navigator: the
/// app's query controls across the top, the scope under them, a line between
/// rules saying what was found, and the occurrences as a tree — a function or
/// the description, and under it the lines that hold the pattern.
///
/// It shows what it is given and says what is chosen; the search itself is
/// the pane's.
final class CodeSearchPanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// What a group of occurrences is in.
    enum Target: Hashable, Sendable {
        /// A function's C, by its place in the artifact.
        case function(Int)
        /// The module description, as the pane shows it.
        case description
    }

    /// Where the tab looks.
    enum Scope: Int, CaseIterable {
        case everywhere, functions, description

        var title: String {
            switch self {
            case .everywhere: L("Everywhere")
            case .functions: L("In Functions")
            case .description: L("In the Description")
            }
        }
    }

    /// A function or the description with matches: a row of the first level.
    final class GroupItem {
        let target: Target
        let name: String
        /// Grey after the name: the function's address, the module's name.
        let detail: String
        /// The mark the Functions list draws for a function
        /// (`CodeNavigatorCell`); nil for the description, which has a book.
        let mark: String?
        let children: [HitItem]
        init(target: Target, name: String, detail: String = "", mark: String? = nil,
             hits: [TextSearchHit]) {
            self.target = target
            self.name = name
            self.detail = detail
            self.mark = mark
            children = hits.map { HitItem(target: target, hit: $0) }
        }
    }

    /// One occurrence: a row of the second level.
    final class HitItem {
        let target: Target
        let hit: TextSearchHit
        init(target: Target, hit: TextSearchHit) {
            self.target = target
            self.hit = hit
        }
    }

    /// Where the app puts its query controls.
    let querySlot = NSView()
    let scopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let summaryLabel = NSTextField(labelWithString: "")
    let outline = SearchOutlineView()
    private let scroll = NSScrollView()
    private(set) var items: [GroupItem] = []

    /// A row was chosen: what it is in, and the occurrence when it is one.
    var onChoose: ((_ target: Target, _ hit: TextSearchHit?) -> Void)?
    /// The reader chose another scope.
    var onScopeChanged: ((Scope) -> Void)?

    var scope: Scope {
        get { Scope(rawValue: scopePopup.indexOfSelectedItem) ?? .everywhere }
        set { scopePopup.selectItem(at: newValue.rawValue) }
    }

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

    private func rule() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    private func build() {
        querySlot.translatesAutoresizingMaskIntoConstraints = false

        // A scope that reads as text with the popup's arrows, as Xcode's
        // "In Project" does.
        scopePopup.isBordered = false
        scopePopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scopePopup.controlSize = .small
        scopePopup.addItems(withTitles: Scope.allCases.map(\.title))
        scopePopup.target = self
        scopePopup.action = #selector(scopeChosen)
        scopePopup.translatesAutoresizingMaskIntoConstraints = false
        ControlHelp.describe(scopePopup, name: L("Search Scope"),
                             tooltip: L("Where the search looks: the functions' C, the module description, or both"))

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.alignment = .center
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

        let above = rule()
        let below = rule()
        for view in [querySlot, scopePopup, above, summaryLabel, below, scroll] { addSubview(view) }
        NSLayoutConstraint.activate([
            querySlot.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            querySlot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            querySlot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scopePopup.topAnchor.constraint(equalTo: querySlot.bottomAnchor, constant: 4),
            scopePopup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scopePopup.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            above.topAnchor.constraint(equalTo: scopePopup.bottomAnchor, constant: 4),
            above.leadingAnchor.constraint(equalTo: leadingAnchor),
            above.trailingAnchor.constraint(equalTo: trailingAnchor),
            summaryLabel.topAnchor.constraint(equalTo: above.bottomAnchor, constant: 5),
            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            below.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 5),
            below.leadingAnchor.constraint(equalTo: leadingAnchor),
            below.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: below.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @objc private func scopeChosen() {
        onScopeChanged?(scope)
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

    /// Shows a search's result: every group opened on its occurrences.
    func show(_ items: [GroupItem], truncated: Bool) {
        self.items = items
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        summaryLabel.stringValue = Self.summary(of: items, truncated: truncated)
    }

    static func summary(of items: [GroupItem], truncated: Bool) -> String {
        let hits = String(items.reduce(0) { $0 + $1.children.count })
        let functions = items.filter { if case .function = $0.target { true } else { false } }.count
        let inDescription = items.contains { $0.target == .description }
        if items.isEmpty { return L("No results") }
        if truncated {
            return L("The first %1$@ results in %2$@ functions — refine the pattern", hits, String(functions))
        }
        switch (functions, inDescription) {
        case (0, _): return L("%1$@ results in the description", hits)
        case (_, true): return L("%1$@ results in %2$@ functions and the description", hits, String(functions))
        default: return L("%1$@ results in %2$@ functions", hits, String(functions))
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
        return (item as? GroupItem)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return items[index] }
        return (item as! GroupItem).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is GroupItem
    }

    /// An occurrence's line shows no more than this many lines, the last
    /// cut short — as Xcode's does.
    static let hitLines = 3

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        let row = CodePaneView.navigatorRowHeight
        guard let hit = item as? HitItem else { return row }
        // A long line wraps: the row is as tall as its lines, three at most.
        let width = max(40, outlineView.bounds.width - Self.hitInset - Self.hitTrailing - 4)
        let measured = Self.line(of: hit.hit)
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let most = NSLayoutManager().defaultLineHeight(for: CodePaneView.navigatorBoldFont())
            * CGFloat(Self.hitLines)
        return max(row, ceil(min(measured, most)) + 2 * Self.hitPadding)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        if let group = item as? GroupItem {
            let id = NSUserInterfaceItemIdentifier("group")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? CodeNavigatorCell
                ?? CodeNavigatorCell(identifier: id)
            cell.showsDisclosure(true)
            cell.showsCalls(expandable: true, expanded: outlineView.isItemExpanded(group))
            cell.onToggle = { [weak outlineView, weak cell] in
                guard let outlineView else { return }
                if outlineView.isItemExpanded(group) {
                    outlineView.collapseItem(group)
                } else {
                    outlineView.expandItem(group)
                }
                cell?.showsCalls(expandable: true, expanded: outlineView.isItemExpanded(group))
            }
            if group.target == .description {
                cell.showsSymbol("book.closed")
            } else {
                cell.showsIcon(group.mark)
            }
            let line = NSMutableAttributedString(string: group.name, attributes: [
                .font: CodePaneView.navigatorBoldFont(), .foregroundColor: NSColor.labelColor
            ])
            if !group.detail.isEmpty {
                line.append(NSAttributedString(string: " " + group.detail, attributes: [
                    .font: CodePaneView.navigatorFont(), .foregroundColor: NSColor.secondaryLabelColor
                ]))
            }
            cell.textField?.attributedStringValue = line
            return cell
        }
        guard let hit = item as? HitItem else { return nil }
        // The cell's glyph and insets are set as it is made, for one size: a
        // cell made at another zoom is not taken again.
        let id = NSUserInterfaceItemIdentifier("hit-\(CodePaneView.navigatorSize)")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            // The lines glyph Xcode puts before a found line, under the
            // group's mark.
            let glyph = NSImageView()
            glyph.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: CodePaneView.navigatorSize - 2, weight: .regular))
            glyph.contentTintColor = .tertiaryLabelColor
            glyph.setAccessibilityElement(false)
            glyph.translatesAutoresizingMaskIntoConstraints = false
            let text = NSTextField(wrappingLabelWithString: "")
            text.maximumNumberOfLines = Self.hitLines
            text.lineBreakMode = .byWordWrapping
            text.cell?.truncatesLastVisibleLine = true
            text.isSelectable = false
            text.translatesAutoresizingMaskIntoConstraints = false
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.addSubview(glyph)
            cell.addSubview(text)
            cell.textField = text
            let firstLine = NSLayoutManager().defaultLineHeight(for: CodePaneView.navigatorFont())
            NSLayoutConstraint.activate([
                glyph.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Self.glyphInset),
                glyph.centerYAnchor.constraint(equalTo: cell.topAnchor,
                                               constant: Self.hitPadding + firstLine / 2),
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Self.hitInset),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Self.hitTrailing),
                text.topAnchor.constraint(equalTo: cell.topAnchor, constant: Self.hitPadding)
            ])
            return cell
        }()
        cell.textField?.attributedStringValue = Self.line(of: hit.hit)
        return cell
    }

    /// Where the lines glyph stands: under the group's mark.
    static var glyphInset: CGFloat { 4 + CodeNavigatorCell.disclosureRoom }
    /// Where an occurrence's line starts: under the group's name, past the
    /// chevron and the mark, as a group's functions stand under it.
    static var hitInset: CGFloat {
        glyphInset + CodeNavigatorIcon.side(forFontSize: CodePaneView.navigatorSize) + 5
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

    /// The zoom changed: the rows are made again in the new size and
    /// measured again, the groups the reader closed staying closed.
    func zoomChanged() {
        let closed = items.filter { !outline.isItemExpanded($0) }
        let top = outline.row(at: NSPoint(x: 0, y: scroll.contentView.bounds.minY))
        let topItem = top >= 0 ? outline.item(atRow: top) as AnyObject? : nil
        outline.reloadData()
        for item in items where !closed.contains(where: { $0 === item }) {
            outline.expandItem(item)
        }
        measuredWidth = 0
        if outline.numberOfRows > 0 {
            outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
        }
        if let topItem {
            let row = outline.row(forItem: topItem)
            if row >= 0 { outline.scroll(outline.rect(ofRow: row).origin) }
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) { redrawChevron(notification) }
    func outlineViewItemDidCollapse(_ notification: Notification) { redrawChevron(notification) }

    private func redrawChevron(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? GroupItem else { return }
        let row = outline.row(forItem: item)
        guard row >= 0,
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? CodeNavigatorCell
        else { return }
        cell.showsCalls(expandable: true, expanded: outline.isItemExpanded(item))
    }

    /// How much of a line before the match stays when the match stands far
    /// into it: the rest gives way to an ellipsis, so the match is in the
    /// three lines shown.
    static let leadingContext = 32

    /// The occurrence's line in the navigator's type, grey, the match in
    /// bold and the label's colour: the eye finds it in the line. A match
    /// far into a long line is brought forward, the start cut to "…".
    static func line(of hit: TextSearchHit) -> NSAttributedString {
        var shown = hit.lineText as NSString
        var start = min(hit.rangeInLine.lowerBound, shown.length)
        var end = min(hit.rangeInLine.upperBound, shown.length)
        if start > leadingContext + 8 {
            var cut = start - leadingContext
            // From a word's start, not its middle.
            let separators = CharacterSet.whitespaces.union(.punctuationCharacters)
            while cut < start, let scalar = Unicode.Scalar(shown.character(at: cut - 1)),
                  !separators.contains(scalar) { cut += 1 }
            let rest = shown.substring(from: cut)
            shown = ("…" + rest) as NSString
            let removed = cut - 1
            start -= removed
            end -= removed
        }
        let text = NSMutableAttributedString(string: shown as String, attributes: [
            .font: CodePaneView.navigatorFont(), .foregroundColor: NSColor.secondaryLabelColor
        ])
        if end > start {
            text.addAttributes([.font: CodePaneView.navigatorBoldFont(),
                                .foregroundColor: NSColor.labelColor],
                               range: NSRange(location: start, length: end - start))
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
            onChoose?(hit.target, hit.hit)
        } else if let group = item as? GroupItem {
            onChoose?(group.target, nil)
        }
    }
}

/// The Search tab's tree: the rows draw their own chevron, so the outline's
/// triangle takes no room and is never drawn.
final class SearchOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
}
