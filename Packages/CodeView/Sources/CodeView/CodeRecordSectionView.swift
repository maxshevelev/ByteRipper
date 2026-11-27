import AnalysisProfiles
import AppKit
import CodeAnalysis
import HelpUI
import Localization
import ToolModuleKit

/// A navigator tab for one kind of record a review keeps — an EC image's
/// interrupts, host commands, EC RAM and so on, as the module's analysis
/// profile declares them: the record's status and note over a table of its
/// rows, the columns the profile's.
///
/// The rows come from the review document of the revision the pane shows
/// (`setRecords`); until it is read, the manifest's statuses stand for it.
/// An address cell is a link (`onOpenAddress`); a cell naming a row of
/// another record switches to that record and selects the row.
// help: panel.code.record-sections
final class CodeRecordSectionView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// The record id the section shows, nil before the first `show`.
    private(set) var recordID: String?
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let searchField = NSSearchField()
    let table = NSTableView()
    private let tableScroll = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")

    /// Opens an address of the module — a `code` or `data` cell clicked.
    var onOpenAddress: ((CodeAddress) -> Void)?
    /// Puts another record's tab in front; the section then selects the row
    /// a ref named. Nil shows the record here.
    var onShowRecord: ((String) -> Void)?

    private var profile: AnalysisProfile?
    private var records = ModuleRecords()
    /// The manifest's statuses, while the document is not read.
    private var statuses: [String: String] = [:]
    private var record: AnalysisProfile.Record?
    private var fallbackTitle = ""
    /// Every row of the record, in the document's (key) order.
    private var allRows: [[String: RecordValue]] = []
    /// The rows shown: filtered and sorted.
    private(set) var shownRows: [[String: RecordValue]] = []
    /// The key text of a row to select once the record is shown.
    private var pendingSelection: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        for label in [statusLabel, noteLabel] {
            label.isSelectable = true
            label.textColor = .secondaryLabelColor
        }
        // The same quiet, centred words as the navigator's empty lists.
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isSelectable = false

        searchField.placeholderString = L("Filter rows")
        ControlHelp.describe(searchField, L("Filter the record's rows"))
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(filterChanged)
        searchField.controlSize = .small

        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.target = self
        table.action = #selector(clicked)
        let menu = NSMenu()
        // help: panel.code.record-sections
        menu.addItem(withTitle: L("Copy Row as TSV"), action: #selector(copyRows), keyEquivalent: "").target = self
        table.menu = menu
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.autohidesScrollers = true

        let column = [titleLabel, statusLabel, noteLabel, searchField, tableScroll, emptyLabel]
        for view in column {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            noteLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 2),
            noteLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            noteLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            searchField.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 6),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            tableScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            tableScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        ])
    }

    /// As the Interfaces and Search tabs: the window's fill, so the list the
    /// section stands over does not show through.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - What it shows

    /// The records of the revision on screen: the document's when read
    /// (`records`), the manifest's statuses until then.
    func setRecords(_ records: ModuleRecords?, statuses: [String: String]?, profile: AnalysisProfile?) {
        self.records = records ?? ModuleRecords()
        self.statuses = statuses ?? [:]
        self.profile = profile
        if let recordID { show(id: recordID, fallbackTitle: fallbackTitle, font: emptyLabel.font ?? .systemFont(ofSize: 11)) }
    }

    /// Shows the section of record `id`, `fallbackTitle` being the profile's
    /// English title for an id the app has no words for.
    func show(id: String, fallbackTitle: String, font: NSFont) {
        let changed = recordID != id
        recordID = id
        self.fallbackTitle = fallbackTitle
        record = profile?.records.first { $0.id == id }
        titleLabel.stringValue = Self.title(of: id, fallback: fallbackTitle)
        emptyLabel.font = font
        if changed { searchField.stringValue = "" }

        let stored = records[id]
        let status = stored?.status
            ?? statuses[id].flatMap(AnalysisProfile.RecordStatus.init) ?? .unanswered
        statusLabel.stringValue = Self.statusText(status, note: stored?.note)
        let note = status == .none ? nil : stored?.note
        noteLabel.stringValue = note ?? ""
        noteLabel.isHidden = (note ?? "").isEmpty
        allRows = stored?.rows ?? []
        buildColumns()
        applyFilter()
        if let key = pendingSelection {
            pendingSelection = nil
            select(key: key)
        }
    }

    /// The status line: what the review has done with the record.
    static func statusText(_ status: AnalysisProfile.RecordStatus, note: String?) -> String {
        switch status {
        case .unanswered: L("Not answered yet.")
        case .partial: L("Review continues.")
        case .complete: L("Complete.")
        case .none: L("None: %1$@", note ?? "")
        }
    }

    /// What a section with no rows says.
    static var emptyText: String {
        L("The review has recorded none yet. They appear here when the review is published.")
    }

    // MARK: - For tests

    var shownTitle: String { titleLabel.stringValue }
    var shownStatus: String { statusLabel.stringValue }
    var shownNote: String { noteLabel.isHidden ? "" : noteLabel.stringValue }
    var shownEmptyText: String { emptyLabel.isHidden ? "" : emptyLabel.stringValue }
    var columnTitles: [String] { table.tableColumns.map(\.title) }
    func setFilter(_ text: String) {
        searchField.stringValue = text
        filterChanged()
    }
    /// The text of the cell at `row`, column `id`, as drawn.
    func cellText(row: Int, column id: String) -> String {
        guard let column = columns.first(where: { $0.id == id }) else { return "" }
        return text(of: shownRows[row], column)
    }
    /// The cell view at `row`, column `id`, as the table makes it.
    func cell(row: Int, column id: String) -> NSTableCellView? {
        guard let index = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }) else { return nil }
        return tableView(table, viewFor: table.tableColumns[index], row: row) as? NSTableCellView
    }
    /// Clicks the cell at `row`, column `id`, as the reader would.
    func click(row: Int, column id: String) {
        guard let index = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }) else { return }
        follow(row: row, column: index)
    }
    /// The selected rows' TSV, as Copy Row puts it on the pasteboard.
    func tsv(rows: IndexSet) -> String {
        rows.filter { shownRows.indices.contains($0) }.map { row in
            columns.map { text(of: shownRows[row], $0) }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    // MARK: - Columns and cells

    private var columns: [AnalysisProfile.Column] { record?.columns ?? [] }

    private func buildColumns() {
        let wanted = columns.map(\.id)
        guard table.tableColumns.map(\.identifier.rawValue) != wanted else { return }
        for column in table.tableColumns { table.removeTableColumn(column) }
        let size = ToolPanelFont.size
        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = Self.columnTitle(column.title)
            tableColumn.headerToolTip = column.summary
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: true)
            tableColumn.minWidth = size * 3
            switch column.kind {
            case .text, .rows: tableColumn.width = (size * 16).rounded()
            case .list: tableColumn.width = (size * 10).rounded()
            default: tableColumn.width = (size * 6).rounded()
            }
            table.addTableColumn(tableColumn)
        }
        table.sortDescriptors = []
        ToolPanelTable.apply(to: table)
    }

    /// A column's header in the reader's language: the profiles carry
    /// English, and a title not listed here stays the profile's.
    static func columnTitle(_ english: String) -> String {
        switch english {
        case "Access": L("Access")
        case "Accessed by": L("Accessed by")
        case "Active level": L("Active level")
        case "Address": L("Address")
        case "Body": L("Body")
        case "Bus address": L("Bus address")
        case "Callers": L("Callers")
        case "Channel": L("Channel")
        case "Command": L("Command")
        case "Commands": L("Commands")
        case "Data in": L("Data in")
        case "Data out": L("Data out")
        case "Device": L("Device")
        case "Direction": L("Direction")
        case "EC RAM": L("EC RAM")
        case "Effect": L("Effect")
        case "Enabled": L("Enabled")
        case "Format": L("Format")
        case "Function": L("Function")
        case "Handler": L("Handler")
        case "Host commands": L("Host commands")
        case "In the image": L("In the image")
        case "Initial state": L("Initial state")
        case "IRQ": L("IRQ")
        case "Meaning": L("Meaning")
        case "Mode": L("Mode")
        case "Name": L("Name")
        case "Offset": L("Offset")
        case "PEC": L("PEC")
        case "Pin": L("Pin")
        case "Ports": L("Ports")
        case "Purpose": L("Purpose")
        case "Raises": L("Raises")
        case "Readers": L("Readers")
        case "Size": L("Size")
        case "Source known from": L("Source known from")
        case "Source": L("Source")
        case "Subcommand": L("Subcommand")
        case "Task slot": L("Task slot")
        case "Values": L("Values")
        case "Width": L("Width")
        case "Writer": L("Writer")
        case "Writers": L("Writers")
        default: english
        }
    }

    /// A value as the column writes it: hex where the column is, enum words
    /// raw, a list joined, a nested table as a count.
    private func text(of row: [String: RecordValue], _ column: AnalysisProfile.Column) -> String {
        if column.kind == .computed { return computed(row, column) ?? "" }
        guard let value = row[column.id], value != .null else { return "" }
        return Self.text(value, kind: column.kind, column: column, profile: profile)
    }

    static func text(_ value: RecordValue, kind: AnalysisProfile.ColumnKind, column: AnalysisProfile.Column,
                     profile: AnalysisProfile?) -> String {
        switch kind {
        case .byte:
            guard let number = value.int else { return value.text }
            return String(format: "0x%02X", number)
        case .int:
            guard column.hex == true, let number = value.int, value.string.map({ column.values?.contains($0) != true }) ?? true
            else { return value.text }
            return String(format: "0x%02X", number)
        case .code, .data:
            guard let number = value.int else { return value.text }
            return CodeAddress(UInt64(number)).description
        case .bool:
            if case .bool(let on) = value { return on ? L("Yes") : L("No") }
            return value.text
        case .list:
            let element = column.of ?? .text
            return (value.array ?? [value]).map { text($0, kind: element, column: column, profile: profile) }
                .joined(separator: ", ")
        case .rows:
            let count = value.array?.count ?? 0
            return L("%1$@ entries", String(count))
        case .ref:
            return refText(value, column: column, profile: profile)
        default:
            return value.text
        }
    }

    /// A ref as the row it names: its key values, written as their columns are.
    private static func refText(_ value: RecordValue, column: AnalysisProfile.Column,
                                profile: AnalysisProfile?) -> String {
        guard let target = profile?.records.first(where: { $0.id == column.ref }) else { return value.text }
        if target.key.count == 1, let keyColumn = target.column(target.key[0]) {
            return text(value, kind: keyColumn.kind, column: keyColumn, profile: profile)
        }
        let object = value.object ?? [:]
        return target.key.compactMap { id in
            guard let part = object[id], let keyColumn = target.column(id) else { return nil }
            return text(part, kind: keyColumn.kind, column: keyColumn, profile: profile)
        }.joined(separator: " ")
    }

    /// A computed column: EC RAM's address in the EC, an SMBus peer's 8-bit
    /// bus address. Nothing where the row has no number to compute from (a
    /// runtime or mailbox address).
    private func computed(_ row: [String: RecordValue], _ column: AnalysisProfile.Column) -> String? {
        switch column.compute {
        case "ec_ram_address":
            guard let offset = row["offset"]?.int,
                  let base = record?.parameters["ec_ram_base"].flatMap(RecordValue.integer) else { return nil }
            return CodeAddress(UInt64(base + offset)).description
        case "smbus_address_8bit":
            guard let address = row["address"], address.string.map({ RecordValue.integer($0) != nil }) ?? true,
                  let seven = address.int else { return nil }
            return String(format: "0x%02X", seven * 2)
        default:
            return nil
        }
    }

    /// The row's key text, as `ModuleRecords.rowKey` writes it.
    private func keyText(_ row: [String: RecordValue]) -> String {
        ModuleRecords.rowKey(row, key: record?.key ?? [])
    }

    private static func isInference(_ row: [String: RecordValue]) -> Bool {
        row["confidence"]?.string == AnalysisProfile.RowConfidence.inference.rawValue
    }

    /// The `?` beside an inferred row, and what it says.
    static func inferenceToolTip(note: String?) -> String {
        guard let note, !note.isEmpty else { return L("Inference") }
        return L("Inference: %1$@", note)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shownRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, shownRows.indices.contains(row),
              let column = columns.first(where: { $0.id == tableColumn.identifier.rawValue }) else { return nil }
        let first = tableColumn === tableView.tableColumns.first
        let identifier = NSUserInterfaceItemIdentifier(first ? "record.first" : "record.cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? ToolPanelTable.makeCell(identifier: identifier, marker: first)
        let values = shownRows[row]
        let inference = Self.isInference(values)
        let note = values["note"]?.string
        let isLink = [.code, .data, .ref].contains(column.kind)
            || (column.kind == .list && [.code, .data, .ref].contains(column.of ?? .text))
        let size = ToolPanelFont.size
        var font: NSFont = isLink || column.kind == .byte || column.hex == true || column.kind == .computed
            ? ToolPanelFont.monospaced(size: size) : ToolPanelFont.body()
        if inference {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        cell.textField?.font = font
        cell.textField?.stringValue = text(of: values, column)
        cell.textField?.textColor = isLink && values[column.id] != nil ? .linkColor : .labelColor
        var tip: String?
        if column.kind == .rows { tip = rowsToolTip(values[column.id], column: column) }
        if tip == nil, let note, !note.isEmpty { tip = note }
        cell.textField?.toolTip = tip
        if first {
            ToolPanelTable.setMarker(symbol: inference ? "questionmark.circle" : nil,
                                     tint: inference ? .secondaryLabelColor : nil,
                                     toolTip: inference ? Self.inferenceToolTip(note: note) : nil, on: cell)
        }
        return cell
    }

    /// A nested table's rows, one a line, for the cell's tooltip.
    private func rowsToolTip(_ value: RecordValue?, column: AnalysisProfile.Column) -> String? {
        guard let rows = value?.array, !rows.isEmpty else { return nil }
        let inner = column.columns ?? []
        return rows.map { item in
            let object = item.object ?? [:]
            return inner.compactMap { part in
                object[part.id].map { Self.text($0, kind: part.kind, column: part, profile: profile) }
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    // MARK: - Filter and sort

    @objc private func filterChanged() { applyFilter() }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        var rows = allRows
        if !query.isEmpty {
            rows = rows.filter { row in
                columns.contains { text(of: row, $0).localizedCaseInsensitiveContains(query) }
                    || (row["note"]?.string?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        if let sort = table.sortDescriptors.first, let id = sort.key,
           let column = columns.first(where: { $0.id == id }) {
            func before(_ a: (number: Int?, text: String), _ b: (number: Int?, text: String)) -> Bool {
                if let x = a.number, let y = b.number { return x < y }
                return a.text.localizedStandardCompare(b.text) == .orderedAscending
            }
            rows.sort { left, right in
                let a = sortKey(left, column), b = sortKey(right, column)
                return sort.ascending ? before(a, b) : before(b, a)
            }
        }
        shownRows = rows
        table.reloadData()
        let empty = allRows.isEmpty
        tableScroll.isHidden = shownRows.isEmpty
        searchField.isHidden = empty
        emptyLabel.isHidden = !shownRows.isEmpty || (empty && records[recordID ?? ""]?.status == AnalysisProfile.RecordStatus.none)
        emptyLabel.stringValue = empty ? Self.emptyText : L("Nothing matches the search.")
    }

    private func sortKey(_ row: [String: RecordValue], _ column: AnalysisProfile.Column) -> (number: Int?, text: String) {
        let number: Int? = switch column.kind {
        case .int, .byte, .code, .data: row[column.id]?.int
        case .computed: computed(row, column).flatMap(RecordValue.integer)
        default: nil
        }
        return (number, text(of: row, column))
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applyFilter()
    }

    // MARK: - Clicks

    @objc private func clicked() {
        guard table.clickedRow >= 0, table.clickedColumn >= 0 else { return }
        follow(row: table.clickedRow, column: table.clickedColumn)
    }

    private func follow(row: Int, column index: Int) {
        guard shownRows.indices.contains(row), table.tableColumns.indices.contains(index),
              let column = columns.first(where: { $0.id == table.tableColumns[index].identifier.rawValue }),
              let value = shownRows[row][column.id] else { return }
        let kind = column.kind == .list ? (column.of ?? .text) : column.kind
        let values = column.kind == .list ? (value.array ?? []) : [value]
        switch kind {
        case .code, .data:
            let addresses = values.compactMap { $0.int.map { CodeAddress(UInt64($0)) } }
            choose(addresses.map { address in
                (address.description, { [weak self] in self?.onOpenAddress?(address) })
            }, at: row, column: index)
        case .ref:
            guard let target = column.ref,
                  let referenced = profile?.records.first(where: { $0.id == target }) else { return }
            choose(values.map { item in
                let key: String
                if referenced.key.count == 1 {
                    key = ModuleRecords.rowKey([referenced.key[0]: item], key: referenced.key)
                } else {
                    key = ModuleRecords.rowKey(item.object ?? [:], key: referenced.key)
                }
                return (Self.refText(item, column: column, profile: profile), { [weak self] in self?.showRef(target, key: key) })
            }, at: row, column: index)
        default:
            return
        }
    }

    /// One place goes at once; several are offered in a menu at the cell.
    private func choose(_ places: [(String, () -> Void)], at row: Int, column: Int) {
        guard !places.isEmpty else { return }
        guard places.count > 1, window != nil else { return places[0].1() }
        let menu = NSMenu()
        for (title, action) in places {
            let item = RecordMenuItem(title: title, action: #selector(RecordMenuItem.perform(_:)), keyEquivalent: "")
            item.handler = action
            item.target = item
            menu.addItem(item)
        }
        let rect = table.frameOfCell(atColumn: column, row: row)
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY), in: table)
    }

    private func showRef(_ target: String, key: String) {
        if let onShowRecord {
            pendingSelection = key
            onShowRecord(target)
        } else {
            pendingSelection = key
            show(id: target, fallbackTitle: target, font: emptyLabel.font ?? .systemFont(ofSize: 11))
        }
    }

    /// Selects the row whose key text is `key`, clearing a filter that hides it.
    func select(key: String) {
        if !shownRows.contains(where: { keyText($0) == key }), !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            applyFilter()
        }
        guard let row = shownRows.firstIndex(where: { keyText($0) == key }) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: - Copy

    @objc private func copyRows() {
        var rows = table.selectedRowIndexes
        if table.clickedRow >= 0, !rows.contains(table.clickedRow) { rows = IndexSet(integer: table.clickedRow) }
        let text = tsv(rows: rows)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The section's title in the reader's language: the profiles carry
    /// English, and an id not listed here keeps the profile's word.
    static func title(of id: String, fallback: String) -> String {
        switch id {
        case "irq_map": L("Interrupts")
        case "host_commands": L("Host commands")
        case "ec_ram": L("EC RAM")
        case "smbus_peers": L("SMBus and I2C")
        case "gpio": L("GPIO")
        case "eflash_area": L("Flash data area")
        default: fallback
        }
    }
}

/// A menu item that runs a closure: one of several places a cell names.
private final class RecordMenuItem: NSMenuItem {
    var handler: (() -> Void)?
    @objc func perform(_ sender: Any?) { handler?() }
}
