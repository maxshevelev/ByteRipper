import AppKit
import AppPalette
import HelpUI
import Localization
import ToolModuleKit
import UEFITool

/// The sheet over a dump compared with a vendor's update file: one row per
/// part the file's table names, what state it is in, and a tick for each part
/// that differs, saying whether Write puts the update's bytes there.
///
/// It decides nothing — the comparison, the defaults and the transaction are
/// `UEFIUpdateComparison`'s, which is tested without a window. What it owns
/// is the ticks the user changes.
@MainActor final class UEFIUpdateViewController: NSViewController {
    var onWrite: ((Set<Int>) -> Void)?
    var onCancel: (() -> Void)?
    /// A row was selected: the session shows that part in the dump.
    var onSelectRow: ((Int?) -> Void)?

    private let comparison: UEFIUpdateComparison
    private let fileName: String
    private let blockCount: Int
    private let canWrite: Bool
    /// The rows Write will write.
    private(set) var chosen: Set<Int>

    let table = NSTableView()
    private let scrollView = NSScrollView()
    private let summaryLabel = ToolWrappingLabel(string: "")
    private let writeButton = NSButton()

    private enum Column {
        static let write = NSUserInterfaceItemIdentifier("write")
        static let name = NSUserInterfaceItemIdentifier("name")
        static let address = NSUserInterfaceItemIdentifier("address")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let state = NSUserInterfaceItemIdentifier("state")
    }

    init(comparison: UEFIUpdateComparison, fileName: String, blockCount: Int, canWrite: Bool) {
        self.comparison = comparison
        self.fileName = fileName
        self.blockCount = blockCount
        self.canWrite = canWrite
        chosen = canWrite ? Set(comparison.rows.indices.filter { comparison.rows[$0].writesByDefault }) : []
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 520))

        let title = NSTextField(labelWithString: L("Compare with PFAT Update File"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let region = comparison.region
        let source = ToolWrappingLabel(string: L(
            "%1$@: AMI BIOS Guard update for %2$@, %3$@ blocks. BIOS region of this dump: %4$@–%5$@.",
            fileName, comparison.platform, blockCount,
            Self.hex(region.lowerBound), Self.hex(region.upperBound - 1)
        ))
        source.font = .systemFont(ofSize: 11)
        let scope = ToolWrappingLabel(string: L(
            "Only the BIOS region is compared. An update file carries no descriptor, and an ME image it may carry is an update image, not the region."
        ))
        scope.font = .systemFont(ofSize: 11)
        scope.textColor = .secondaryLabelColor

        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.rowSizeStyle = .small
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsColumnReordering = false
        table.dataSource = self
        table.delegate = self
        column(Column.write, L("Write", context: "action"), 72)
        column(Column.name, L("Name"), 230)
        column(Column.address, L("Offset"), 84)
        column(Column.size, L("Size"), 74)
        column(Column.state, L("State"), 270)

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor

        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        writeButton.title = L("Write", context: "action")
        writeButton.bezelStyle = .rounded
        writeButton.keyEquivalent = "\r"
        writeButton.target = self
        writeButton.action = #selector(writeClicked)
        ControlHelp.describe(writeButton, L("Write the ticked parts from the update file into the dump, as one undo step"))

        let buttons = NSStackView(views: [summaryLabel, cancel, writeButton])
        buttons.orientation = .horizontal
        buttons.alignment = .lastBaseline
        buttons.spacing = 8

        let stack = NSStackView(views: [title, source, scope, scrollView, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            source.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scope.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 280)
        ])
        update()
    }

    private func column(_ identifier: NSUserInterfaceItemIdentifier, _ title: String, _ width: CGFloat) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        table.addTableColumn(column)
    }

    /// The summary and the button, after the ticks changed.
    private func update() {
        var text = comparison.summary(writing: chosen)
        if !canWrite { text += " " + L("This file is open read-only.") }
        summaryLabel.stringValue = text
        writeButton.isEnabled = canWrite && !chosen.isEmpty
    }

    /// Ticks or unticks a row, as its checkbox does. For the app's tests: a
    /// click into a table cell is not something a test can make.
    func setChosen(_ row: Int, _ on: Bool) {
        guard comparison.rows.indices.contains(row), !comparison.rows[row].isIdentical, canWrite else { return }
        if on { chosen.insert(row) } else { chosen.remove(row) }
        table.reloadData(forRowIndexes: [row], columnIndexes: [0])
        update()
    }

    @objc private func tickClicked(_ sender: NSButton) {
        setChosen(sender.tag, sender.state == .on)
    }

    @objc private func writeClicked() { onWrite?(chosen) }
    @objc private func cancelClicked() { onCancel?() }

    static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }
}

extension UEFIUpdateViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { comparison.rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard comparison.rows.indices.contains(row), let column = tableColumn else { return nil }
        let entry = comparison.rows[row]
        if column.identifier == Column.write {
            let box = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSButton
                ?? makeTick()
            box.tag = row
            box.state = chosen.contains(row) ? .on : .off
            // A part that is the same has nothing to write.
            box.isEnabled = canWrite && !entry.isIdentical
            box.isHidden = entry.isIdentical
            return box
        }
        let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: column.identifier)
        cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        cell.textField?.textColor = .labelColor
        switch column.identifier {
        case Column.name:
            cell.textField?.stringValue = entry.nameText
            cell.textField?.font = .systemFont(ofSize: 11)
        case Column.address:
            cell.textField?.stringValue = Self.hex(entry.range.lowerBound)
        case Column.size:
            cell.textField?.stringValue = Self.hex(UInt64(entry.range.count))
        default:
            cell.textField?.stringValue = entry.stateText
            cell.textField?.font = .systemFont(ofSize: 11)
            cell.textField?.textColor = entry.isIdentical ? SemanticColors.quiet
                : entry.isBoardData ? SemanticColors.caution : SemanticColors.plain
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        onSelectRow?(row >= 0 ? row : nil)
    }

    private func makeTick() -> NSButton {
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(tickClicked(_:)))
        box.identifier = Column.write
        box.controlSize = .small
        ControlHelp.describe(box, L("Write this part from the update file"))
        return box
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
