import AppKit
import HelpUI
import Localization
import ToolModuleKit

/// The Contents search's results, under the tree — the panel the dump's Search
/// All opens under the dump, read the same way: a header with the count and a
/// ×, and a row per match with the bytes around it, the match in bold. What
/// the dump's panel has no need of is said beside them: the volume the match
/// is in — after a badge for each codec its bytes came through, `LZMA`,
/// `XOR 81`, the badge a fragment panel of them wears — and the node that
/// holds it. While the search runs the header carries its progress and a
/// stop button.
///
/// A click goes to the match: the node in the tree and, for a match in the
/// file, the bytes in the dump. A double click on a match behind a codec
/// opens the bytes it is in as a fragment panel, the match selected.
// help: panel.uefi.content-search
@MainActor final class UEFIContentResultsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// One line of the list, as the panel words it.
    struct Row: Equatable {
        var volume: String
        /// The codecs the match's bytes came through, outermost first: a
        /// compression for each compressed section it is in, `XOR 81` for a
        /// LENV block decoded. None for the file's own bytes.
        var codecs: [String]
        /// The file address, or where in a compressed section's decompressed
        /// bytes — said under the pointer.
        var address: String
        var node: String
        /// The names from the top of the tree down to the node.
        var path: String
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
        static let volume = NSUserInterfaceItemIdentifier("volume")
        static let hex = NSUserInterfaceItemIdentifier("hex")
        static let text = NSUserInterfaceItemIdentifier("text")
        static let node = NSUserInterfaceItemIdentifier("node")
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
            (Column.volume, L("Volume"), CGFloat(200),
             L("The volume the match is in, after the codecs its bytes came through")),
            (Column.hex, L("Excerpt Hex"), CGFloat(300), ""),
            (Column.text, L("Excerpt Text"), CGFloat(170), ""),
            (Column.node, L("Node"), CGFloat(160), L("The deepest node that holds the match whole"))
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
        if identifier == Column.volume {
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? UEFIBadgedCell)
                ?? UEFIBadgedCell(identifier: identifier)
            cell.show(badges: line.codecs, text: line.volume)
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
        case Column.text:
            field?.attributedStringValue = textExcerpt(line)
        default:
            field?.attributedStringValue = plain(line.node, font: ToolPanelFont.body())
        }
        cell.toolTip = tooltip
        return cell
    }

    private func plain(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
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

    @objc private func rowClicked() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(row) else { return }
        onChoose?(row)
    }

    @objc private func rowDoubleClicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row) else { return }
        onOpen?(row)
    }

    @objc private func stopClicked() { onStop?() }
    @objc private func closeClicked() { onClose?() }

    /// The row double-clicked, for a test.
    func open(_ row: Int) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        onOpen?(row)
    }

    /// The row chosen, for a test.
    func choose(_ row: Int) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        onChoose?(row)
    }
}

/// The Volume column's cell: a badge for each codec, then the volume's name.
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

    func show(badges: [String], text: String) {
        self.badges = badges
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for badge in badges {
            let view = UEFICodecBadge(text: badge)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            stack.addArrangedSubview(view)
        }
        label.font = ToolPanelFont.body()
        label.stringValue = text
        stack.addArrangedSubview(label)
    }
}

/// A codec's name in a capsule — drawn as the fragment panel's header draws
/// the badge of the codec its bytes went through.
@MainActor final class UEFICodecBadge: NSView {
    private let label: NSTextField
    private static let inset = NSSize(width: 6, height: 1)

    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: max(ToolPanelFont.size - 3, 9), weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset.width),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset.width),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityValue(text)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        let size = label.intrinsicContentSize
        return NSSize(width: size.width + 2 * Self.inset.width, height: size.height + 2 * Self.inset.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.quaternaryLabelColor.setFill()
        path.fill()
    }
}
