import ALSplitView
import AppKit
import AppPalette
import HelpUI
import LenovoDMITool
import Localization
import ToolModuleKit

/// The panel: the log and the two blocks as a tree, the row in focus in detail
/// under it, and what reads wrong underneath both.
///
/// It decides nothing. Everything on screen comes from one `show(_:focus:)`
/// over a `LenovoDMIDisplay` built and tested in the pure target.
@MainActor final class LenovoDMIToolViewController: NSViewController {
    var onSelect: ((String?) -> Void)?
    var onGoTo: ((String) -> Void)?
    var onCopyValue: ((String) -> Void)?

    private(set) var display = LenovoDMIDisplay.empty
    private var focus: String?

    /// True while the tree is being loaded from the model — a selection the
    /// code made is not news, and without this the panel selects, publishes,
    /// re-shows and selects again.
    private var isShowingState = false

    let outline = NSOutlineView()
    private let outlineScroll = NSScrollView()
    private let detail = ToolDetailScroll()
    private let splitter = ALSplitView()
    private let summaryLabel = NSTextField(labelWithString: "")
    /// The findings, one per line: a wiped store, a checksum that does not add
    /// up, blocks that disagree.
    private let notesLabel = NSTextField(wrappingLabelWithString: "")
    private let noticeLabel = NSTextField(labelWithString: "")
    private var zoomObserver: NSObjectProtocol?
    private var columnWidthSize = ToolPanelFont.designSize

    /// The tree's items. `NSOutlineView` holds its items by identity, so a row
    /// is wrapped in an object that stays the same across a re-read of the
    /// same layout — which is what keeps an opened block open after an edit.
    private var items: [String: Item] = [:]

    private final class Item {
        var row: LenovoDMIRow
        init(_ row: LenovoDMIRow) { self.row = row }
    }

    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let value = NSUserInterfaceItemIdentifier("value")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 500))
        view.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = ToolPanelFont.body(weight: .medium)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        configureOutline()
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.hasHorizontalScroller = true
        outlineScroll.autohidesScrollers = true
        outlineScroll.borderType = .bezelBorder
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false

        // Top: the tree. Bottom: the detail for the row in focus, a third of
        // the height to start with and the user's to move after that.
        splitter.isVertical = false
        splitter.dividerThickness = 1
        splitter.translatesAutoresizingMaskIntoConstraints = false
        splitter.addPane(outlineScroll)
        splitter.addPane(detail)
        splitter.setPaneLayout(.fill, at: 0)
        splitter.setPaneLayout(.proportional(0.4), at: 1)
        detail.showPlaceholder(L("Select a row to see what it is."))

        notesLabel.font = ToolPanelFont.body()
        notesLabel.translatesAutoresizingMaskIntoConstraints = false
        notesLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        noticeLabel.font = ToolPanelFont.body()
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        view.addSubview(summaryLabel)
        view.addSubview(splitter)
        view.addSubview(notesLabel)
        view.addSubview(noticeLabel)

        // Breakable, for the reason every panel's insets are: a panel squeezed
        // to nothing is a legal state.
        let bottom = noticeLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        bottom.priority = .defaultHigh

        NSLayoutConstraint.activate([
            summaryLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            summaryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            splitter.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 6),
            splitter.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            splitter.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            splitter.bottomAnchor.constraint(equalTo: notesLabel.topAnchor, constant: -6),

            notesLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            notesLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            notesLabel.bottomAnchor.constraint(equalTo: noticeLabel.topAnchor, constant: -4),

            noticeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            noticeLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            bottom
        ])

        zoomObserver = ToolPanelFont.observeZoom { [weak self] in
            self?.applyPanelFont()
        }
    }

    deinit {
        if let zoomObserver {
            NotificationCenter.default.removeObserver(zoomObserver)
        }
    }

    private func configureOutline() {
        outline.style = .inset
        outline.autoresizesOutlineColumn = false
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = false
        outline.allowsColumnReordering = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(rowDoubleClicked)
        outline.menu = contextMenu()

        let name = NSTableColumn(identifier: Column.name)
        name.title = L("Name")
        name.width = 190
        name.resizingMask = .userResizingMask
        outline.addTableColumn(name)
        outline.outlineTableColumn = name

        let value = NSTableColumn(identifier: Column.value)
        value.title = L("Value")
        value.width = 200
        value.resizingMask = [.autoresizingMask, .userResizingMask]
        outline.addTableColumn(value)

        ToolPanelTable.apply(to: outline)
        applyColumnWidths()
    }

    private func applyPanelFont() {
        summaryLabel.font = ToolPanelFont.body(weight: .medium)
        notesLabel.font = ToolPanelFont.body()
        noticeLabel.font = ToolPanelFont.body()
        ToolPanelTable.apply(to: outline)
        applyColumnWidths()
        outline.reloadData()
        renderDetail()
    }

    private func applyColumnWidths() {
        let size = ToolPanelFont.size
        guard size != columnWidthSize else { return }
        ToolPanelTable.scaleColumnWidths(of: outline, by: size / columnWidthSize)
        columnWidthSize = size
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        // help: panel.lenovo-dmi.copy-value
        menu.addItem(withTitle: L("Copy Value"), action: #selector(copyValueClicked), keyEquivalent: "")
            .target = self
        // help: panel.lenovo-dmi.select-in-dump
        menu.addItem(withTitle: L("Select in Dump"), action: #selector(goToClicked), keyEquivalent: "")
            .target = self
        return menu
    }

    // MARK: - Showing a display

    func show(_ display: LenovoDMIDisplay, focus: String?) {
        let layoutChanged = Self.ids(display.rows) != Self.ids(self.display.rows)
        self.display = display
        self.focus = focus

        summaryLabel.stringValue = display.summary
        let notes = NSMutableAttributedString()
        for (index, note) in display.notes.enumerated() {
            notes.append(NSAttributedString(
                string: (index == 0 ? "" : "\n") + note.text,
                attributes: [
                    .font: ToolPanelFont.body(),
                    .foregroundColor: note.isProblem ? SemanticColors.bad : NSColor.secondaryLabelColor
                ]
            ))
        }
        notesLabel.attributedStringValue = notes
        notesLabel.isHidden = display.notes.isEmpty

        isShowingState = true
        defer { isShowingState = false }
        if layoutChanged {
            items = [:]
            outline.reloadData()
        } else {
            refreshItems(display.rows)
            outline.reloadData(
                forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows),
                columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns)
            )
        }
        selectFocus()
        renderDetail()
    }

    func say(_ text: String, asProblem: Bool = false) {
        noticeLabel.stringValue = text
        noticeLabel.textColor = asProblem ? SemanticColors.bad : .secondaryLabelColor
    }

    private static func ids(_ rows: [LenovoDMIRow]) -> [String] {
        rows.flatMap { [$0.id] + ids($0.children) }
    }

    private func item(for row: LenovoDMIRow) -> Item {
        if let existing = items[row.id] { return existing }
        let made = Item(row)
        items[row.id] = made
        return made
    }

    private func refreshItems(_ rows: [LenovoDMIRow]) {
        for row in rows {
            items[row.id]?.row = row
            refreshItems(row.children)
        }
    }

    private func selectFocus() {
        guard let focus, let parent = display.parent(of: focus) else {
            outline.deselectAll(nil)
            return
        }
        if parent.id != focus {
            outline.expandItem(item(for: parent))
        }
        let index = outline.row(forItem: item(for: display.row(focus) ?? parent))
        guard index >= 0 else { return }
        if outline.selectedRow != index {
            outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        outline.scrollRowToVisible(index)
    }

    private func renderDetail() {
        guard let focus, let row = display.row(focus) else {
            detail.setTerm(nil)
            detail.showPlaceholder(display.rows.isEmpty ? "" : L("Select a row to see what it is."))
            return
        }
        detail.prepareForRows(subject: row.id)
        detail.setTerm(row.term)

        let title = NSTextField(labelWithString: row.name)
        title.font = ToolPanelFont.title()
        title.translatesAutoresizingMaskIntoConstraints = false
        detail.content.addArrangedSubview(title)

        for field in row.fields {
            let label = NSTextField(labelWithString: field.label)
            label.font = ToolPanelFont.body()
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: ToolPanelFont.detailLabelWidth).isActive = true

            let value = ToolWrappingLabel(string: field.value)
            value.font = field.value.hasPrefix("0x") ? ToolPanelFont.monospacedDigits() : ToolPanelFont.body()
            if field.isProblem {
                value.textColor = SemanticColors.bad
            }
            // Selectable: a serial number or a UUID is what a bench copies out
            // of here.
            value.isSelectable = true

            let line = NSStackView(views: [label, value])
            line.orientation = .horizontal
            line.alignment = .firstBaseline
            line.spacing = 6
            line.translatesAutoresizingMaskIntoConstraints = false
            detail.content.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: detail.content.widthAnchor).isActive = true
        }
    }

    // MARK: - What the user does

    private var clickedID: String? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard row >= 0 else { return nil }
        return (outline.item(atRow: row) as? Item)?.row.id
    }

    @objc private func rowDoubleClicked() {
        guard let id = clickedID else { return }
        onGoTo?(id)
    }

    @objc private func copyValueClicked() {
        guard let id = clickedID else { return }
        onCopyValue?(id)
    }

    @objc private func goToClicked() {
        guard let id = clickedID else { return }
        onGoTo?(id)
    }
}

extension LenovoDMIToolViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? Item else { return display.rows.count }
        return item.row.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? Item else { return self.item(for: display.rows[index]) }
        return self.item(for: item.row.children[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? Item else { return false }
        return !item.row.children.isEmpty
    }

    func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        guard let item = item as? Item, let identifier = tableColumn?.identifier else { return nil }
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? ToolPanelTable.makeCell(identifier: identifier)
        let isName = identifier == Column.name
        let text = isName ? item.row.name : item.row.value
        cell.textField?.stringValue = text
        cell.textField?.font = isName ? ToolPanelFont.body() : ToolPanelFont.monospacedDigits()
        cell.textField?.textColor = item.row.isProblem ? SemanticColors.bad : .labelColor
        cell.textField?.toolTip = text
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isShowingState else { return }
        let row = outline.selectedRow
        let id = row >= 0 ? (outline.item(atRow: row) as? Item)?.row.id : nil
        onSelect?(id)
    }
}
