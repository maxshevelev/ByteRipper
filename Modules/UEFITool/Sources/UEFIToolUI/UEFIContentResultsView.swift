import AppKit
import HelpUI
import Localization
import ToolModuleKit

/// The Contents search's results, under the tree — the panel the dump's Search
/// All opens under the dump, read the same way: a header with the count and a
/// ×, and a row per match with the bytes around it, the match in bold. What
/// the dump's panel has no need of comes first: the node that holds the match,
/// after the node above it where that one has a name of its own — `VSS store:
/// SetupMode` — and after a badge for each codec its bytes came through,
/// `LZMA`, `XOR 81`, the badge a fragment panel of them wears. While the
/// search runs the header carries its progress and a stop button.
///
/// A click goes to the match: the node in the tree and, for a match in the
/// file, the bytes in the dump. A double click on a match behind a codec
/// opens the bytes it is in as a fragment panel, the match selected — and so
/// does the row's right-click menu, which names what opens.
// help: panel.uefi.content-search
@MainActor final class UEFIContentResultsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// One line of the list, as the panel words it.
    struct Row: Equatable {
        /// The node that holds the match, after its parent's name where the
        /// parent has one of its own: `VSS store: SetupMode`.
        var node: String
        /// The codecs the match's bytes came through, outermost first: a
        /// compression for each compressed section it is in, `XOR 81` for a
        /// LENV block decoded. None for the file's own bytes.
        var codecs: [String]
        /// The file address, or where in a compressed section's decompressed
        /// bytes — said under the pointer.
        var address: String
        /// The names from the top of the tree down to the node.
        var path: String
        /// What opening the row opens — Open Decompressed Body, Open Decoded
        /// Block — for a match behind a codec; nil for the file's own bytes,
        /// which the dump already shows.
        var openTitle: String?
        /// The bytes around the match, and where the match is in them.
        var excerpt: [UInt8]
        var excerptMatch: Range<Int>
    }

    /// What the panel says.
    enum State: Equatable {
        /// Nothing yet.
        case idle
        /// The search is running, this far through.
        case searching(Double)
        /// It is over: every match, and where it looked — nil for the whole
        /// tree.
        case done(total: Int, scope: String?)
    }

    /// The reader chose a row.
    var onChoose: ((Int) -> Void)?
    /// The reader double-clicked a row.
    var onOpen: ((Int) -> Void)?
    /// The reader closed the panel.
    var onClose: (() -> Void)?
    /// The reader stopped the search.
    var onStop: (() -> Void)?

    private(set) var rows: [Row] = []
    private(set) var state: State = .idle

    private let header = NSTextField(labelWithString: "")
    let progressBar = NSProgressIndicator()
    private let stopButton = NSButton()
    private let closeButton = NSButton()
    private let message = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    let table = NSTableView()

    /// The panel's height when it opens.
    static let panelHeight: CGFloat = 180

    private enum Column {
        static let node = NSUserInterfaceItemIdentifier("node")
        static let hex = NSUserInterfaceItemIdentifier("hex")
        static let text = NSUserInterfaceItemIdentifier("text")
    }

    init() {
        super.init(frame: .zero)
        build()
        apply()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Building

    private func build() {
        // A split view's pane: clipped, so the header does not paint over the
        // detail while the pane is shut to nothing.
        wantsLayer = true
        layer?.masksToBounds = true

        header.font = ToolPanelFont.body(weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingTail
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1

        configure(stopButton, symbol: "xmark.circle.fill", name: L("Stop searching"),
                  tooltip: L("Stop the search through the contents"), action: #selector(stopClicked))
        stopButton.contentTintColor = .tertiaryLabelColor
        configure(closeButton, symbol: "xmark", name: L("Close search results"),
                  tooltip: L("Close search results"), action: #selector(closeClicked))

        for (identifier, title, width, tooltip) in [
            (Column.node, L("Node"), CGFloat(240),
             L("The node that holds the match, after the node above it and the codecs its bytes came through")),
            (Column.hex, L("Excerpt Hex"), CGFloat(300), ""),
            (Column.text, L("Excerpt Text"), CGFloat(170), "")
        ] {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = 40
            if !tooltip.isEmpty { column.headerToolTip = tooltip }
            table.addTableColumn(column)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.doubleAction = #selector(rowDoubleClicked)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.setAccessibilityLabel(L("Search results"))
        ToolPanelTable.apply(to: table)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        message.font = ToolPanelFont.body()
        message.textColor = .secondaryLabelColor
        message.alignment = .center

        // Everything sits in a box at least as tall as a header and a row,
        // clipped by the pane: shut to no height, the pane would otherwise
        // leave the header and the list with no size the layout can solve.
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let followsPane = content.heightAnchor.constraint(equalTo: heightAnchor)
        followsPane.priority = .defaultHigh
        let followsWidth = content.widthAnchor.constraint(equalTo: widthAnchor)
        followsWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            followsWidth,
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            followsPane,
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
        for view in [header, progressBar, stopButton, closeButton, scroll, message] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let headerEnd = header.trailingAnchor.constraint(lessThanOrEqualTo: progressBar.leadingAnchor, constant: -8)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 2),
            headerEnd,
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -2),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
            stopButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            stopButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: 16),
            stopButton.heightAnchor.constraint(equalToConstant: 16),
            progressBar.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -6),
            progressBar.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            progressBar.widthAnchor.constraint(equalToConstant: 120),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            message.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            message.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            message.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 10)
        ])
    }

    private func configure(_ button: NSButton, symbol: String, name: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        ControlHelp.describe(button, name: name, tooltip: tooltip)
        button.target = self
        button.action = action
    }

    // MARK: - What it shows

    /// The search started, or moved on.
    func showSearching(_ progress: Double) {
        if case .searching = state {} else {
            rows = []
            table.reloadData()
        }
        state = .searching(min(max(progress, 0), 1))
        apply()
    }

    /// The search is over.
    func show(_ rows: [Row], total: Int, scope: String?) {
        self.rows = rows
        state = .done(total: total, scope: scope)
        table.reloadData()
        if !rows.isEmpty { table.scrollRowToVisible(0) }
        apply()
    }

    /// The search was stopped, or the file changed: nothing to list.
    func clear() {
        rows = []
        state = .idle
        table.reloadData()
        apply()
    }

    private func apply() {
        switch state {
        case .idle:
            header.stringValue = L("Search results (0)")
            message.stringValue = ""
        case .searching(let progress):
            header.stringValue = L("Search results (searching…)")
            progressBar.doubleValue = progress
            message.stringValue = L("Searching…")
        case .done(let total, let scope):
            let count = rows.count == total
                ? Self.grouped(total)
                : L("%1$@, the first %2$@ listed", Self.grouped(total), Self.grouped(rows.count))
            header.stringValue = scope.map { L("Search results in %1$@ (%2$@)", $0, count) }
                ?? L("Search results (%1$@)", count)
            message.stringValue = L("No matches.")
        }
        let searching: Bool
        if case .searching = state { searching = true } else { searching = false }
        progressBar.isHidden = !searching
        stopButton.isHidden = !searching
        let listing = !rows.isEmpty
        scroll.isHidden = !listing
        message.isHidden = listing
    }

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    func applyFont() {
        header.font = ToolPanelFont.body(weight: .semibold)
        message.font = ToolPanelFont.body()
        ToolPanelTable.apply(to: table)
        table.reloadData()
    }

    // MARK: - The table

    private var regularFont: NSFont { .monospacedSystemFont(ofSize: ToolPanelFont.size, weight: .regular) }
    private var boldFont: NSFont { .monospacedSystemFont(ofSize: ToolPanelFont.size, weight: .bold) }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, rows.indices.contains(row) else { return nil }
        let line = rows[row]
        let tooltip = [line.path, line.address].filter { !$0.isEmpty }.joined(separator: "\n")
        if identifier == Column.node {
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? UEFIBadgedCell)
                ?? UEFIBadgedCell(identifier: identifier)
            cell.show(badges: line.codecs, text: line.node)
            cell.toolTip = tooltip
            return cell
        }
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? ToolPanelTable.makeCell(identifier: identifier)
        let field = cell.textField
        field?.usesSingleLineMode = true
        switch identifier {
        case Column.hex:
            field?.attributedStringValue = hexExcerpt(line)
        default:
            field?.attributedStringValue = textExcerpt(line)
        }
        cell.toolTip = tooltip
        return cell
    }

    /// "AB CD EF", the matched bytes bold — as the dump's results draw them.
    private func hexExcerpt(_ line: Row) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, byte) in line.excerpt.enumerated() {
            let font = line.excerptMatch.contains(index) ? boldFont : regularFont
            result.append(NSAttributedString(string: String(format: "%02X", byte),
                                             attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            if index < line.excerpt.count - 1 {
                result.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
        }
        return result
    }

    /// The bytes as ASCII, a dot dimmed for one that is not a printable
    /// character, the matched bytes bold.
    private func textExcerpt(_ line: Row) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, byte) in line.excerpt.enumerated() {
            let font = line.excerptMatch.contains(index) ? boldFont : regularFont
            let printable = byte >= 0x20 && byte < 0x7F
            result.append(NSAttributedString(
                string: printable ? String(UnicodeScalar(byte)) : ".",
                attributes: [.font: font, .foregroundColor: printable ? NSColor.labelColor : NSColor.secondaryLabelColor]))
        }
        return result
    }

    /// True between a selection moving and the click that moved it, so the
    /// click does not go to the row a second time.
    private var selectionJustMoved = false

    /// A row chosen by the keyboard — the arrows, also while the details are
    /// open large — or by a click on another row.
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard rows.indices.contains(row) else { return }
        selectionJustMoved = true
        DispatchQueue.main.async { [weak self] in self?.selectionJustMoved = false }
        onChoose?(row)
    }

    /// A click on the row already selected goes to it again.
    @objc private func rowClicked() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(row) else { return }
        if selectionJustMoved {
            selectionJustMoved = false
            return
        }
        onChoose?(row)
    }

    @objc private func rowDoubleClicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row) else { return }
        onOpen?(row)
    }

    /// The right-click menu: the row's Open, when it has one.
    func menuNeedsUpdate(_ menu: NSMenu) {
        fill(menu, row: table.clickedRow)
    }

    /// The menu a right-click on `row` shows, for a test.
    func menu(forRow row: Int) -> NSMenu {
        let menu = NSMenu()
        fill(menu, row: row)
        return menu
    }

    private func fill(_ menu: NSMenu, row: Int) {
        menu.removeAllItems()
        guard rows.indices.contains(row), let title = rows[row].openTitle else { return }
        let item = NSMenuItem(title: title, action: #selector(openFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.tag = row
        ControlHelp.describe(item, L("Open the bytes this match is in as a panel, the match selected"))
        menu.addItem(item)
    }

    @objc private func openFromMenu(_ item: NSMenuItem) {
        guard rows.indices.contains(item.tag) else { return }
        onOpen?(item.tag)
    }

    @objc private func stopClicked() { onStop?() }
    @objc private func closeClicked() { onClose?() }

    /// The row double-clicked, for a test.
    func open(_ row: Int) {
        onOpen?(row)
    }

    /// The row chosen, for a test.
    func choose(_ row: Int) {
        if table.selectedRow == row {
            onChoose?(row)
        } else {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }
}

/// The Node column's cell: a badge for each codec, then the node's name.
@MainActor final class UEFIBadgedCell: NSTableCellView {
    private let stack = NSStackView()
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = label
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let trailing = stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2)
        trailing.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            trailing,
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The badges, read in order, then the name.
    private(set) var badges: [String] = []

    /// A selected row is filled, and the badge on it takes the selection's
    /// ink, as a pill does when its panel is up.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateBadgeInk() }
    }

    private func updateBadgeInk() {
        let ink: NSColor? = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : nil
        for case let badge as PartBadgeView in stack.arrangedSubviews {
            badge.ink = ink
        }
    }

    func show(badges: [String], text: String) {
        self.badges = badges
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for badge in badges {
            let view = PartBadgeView(text: badge, isTransform: true)
            view.font = .systemFont(ofSize: max(ToolPanelFont.size - 3, 9), weight: .medium)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            stack.addArrangedSubview(view)
        }
        updateBadgeInk()
        label.font = ToolPanelFont.body()
        label.stringValue = text
        stack.addArrangedSubview(label)
    }
}
