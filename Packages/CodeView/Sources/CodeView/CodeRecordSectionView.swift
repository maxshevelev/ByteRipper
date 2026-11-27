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
///
/// A record with a `header` says above its status line what its subject is;
/// one with `groupBy` is a tree: a branch per value of that column — the
/// value in bold with what it stands for (`valueSummaries`) — and the rows
/// under it. A value with words of its own is a branch even with no rows,
/// so the reader sees every port pair; a filter hides a branch none of
/// whose rows match.
// help: panel.code.record-sections
final class CodeRecordSectionView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// The record id the section shows, nil before the first `show`.
    private(set) var recordID: String?
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let headerLabel = NSTextField(wrappingLabelWithString: "")
    private let searchField = NSSearchField()
    /// The rows, a tree for a grouped record and a flat list otherwise. The
    /// outline draws no triangle of its own: a branch carries its chevron.
    let table = SearchOutlineView()
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
    /// The rows shown: filtered and sorted, branch after branch for a
    /// grouped record.
    private(set) var shownRows: [[String: RecordValue]] = []
    /// The outline's items: branches for a grouped record, rows otherwise.
    private var items: [AnyObject] = []
    /// The branches the reader closed, by value; every other one is open.
    private var collapsedGroups: Set<String> = []
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
        headerLabel.isSelectable = true
        headerLabel.textColor = .labelColor
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
        table.floatsGroupRows = false
        table.indentationPerLevel = 0
        table.autoresizesOutlineColumn = false
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

        // The words over the table stand in a stack, so a header or a note
        // the record has not got takes no room.
        let words = NSStackView(views: [titleLabel, headerLabel, statusLabel, noteLabel])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 4
        words.setCustomSpacing(2, after: statusLabel)
        words.detachesHiddenViews = true
        let column = [words, searchField, tableScroll, emptyLabel]
        for view in column {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            words.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            words.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            words.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: words.trailingAnchor),
            headerLabel.widthAnchor.constraint(equalTo: words.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: words.widthAnchor),
            noteLabel.widthAnchor.constraint(equalTo: words.widthAnchor),
            searchField.topAnchor.constraint(equalTo: words.bottomAnchor, constant: 6),
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
        if changed {
            searchField.stringValue = ""
            collapsedGroups = []
        }
        let header = record?.header.map(Self.header) ?? ""
        headerLabel.stringValue = header
        headerLabel.isHidden = header.isEmpty

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
    var shownHeader: String { headerLabel.isHidden ? "" : headerLabel.stringValue }
    /// The branches shown, in order: the value and its words.
    var shownGroups: [(value: String, summary: String?, rows: Int)] {
        items.compactMap { $0 as? RecordGroupItem }.map { ($0.value, $0.summary, $0.children.count) }
    }
    /// The outline's row of the data row whose key text is `key`.
    func tableRow(key: String) -> Int? {
        for item in items {
            let rows: [AnyObject] = (item as? RecordGroupItem)?.children ?? [item]
            for case let row as RecordRowItem in rows where keyText(row.values) == key {
                let index = table.row(forItem: row)
                return index >= 0 ? index : nil
            }
        }
        return nil
    }
    var shownEmptyText: String { emptyLabel.isHidden ? "" : emptyLabel.stringValue }
    var columnTitles: [String] { table.tableColumns.map(\.title) }
    func setFilter(_ text: String) {
        searchField.stringValue = text
        filterChanged()
    }
    /// The text of the cell at `row` of the outline, column `id`, as drawn;
    /// empty on a branch.
    func cellText(row: Int, column id: String) -> String {
        guard let column = columns.first(where: { $0.id == id }), let values = values(atRow: row) else { return "" }
        return text(of: values, column)
    }
    /// The cell view at `row`, column `id`, as the table makes it.
    func cell(row: Int, column id: String) -> NSTableCellView? {
        guard let index = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }),
              let item = table.item(atRow: row) else { return nil }
        return outlineView(table, viewFor: table.tableColumns[index], item: item) as? NSTableCellView
    }
    /// Clicks the cell at `row`, column `id`, as the reader would.
    func click(row: Int, column id: String) {
        guard let index = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }) else { return }
        follow(row: row, column: index)
    }
    /// The selected rows' TSV, as Copy Row puts it on the pasteboard; a
    /// branch's own row adds nothing, its rows carry its value.
    func tsv(rows: IndexSet) -> String {
        rows.compactMap { values(atRow: $0) }.map { values in
            columns.map { text(of: values, $0) }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// The data row at the outline's `row`; nil for a branch.
    private func values(atRow row: Int) -> [String: RecordValue]? {
        guard row >= 0, row < table.numberOfRows else { return nil }
        return (table.item(atRow: row) as? RecordRowItem)?.values
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
        table.outlineTableColumn = table.tableColumns.first
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

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return items.count }
        return (item as? RecordGroupItem)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let group = item as? RecordGroupItem else { return items[index] }
        return group.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? RecordGroupItem)?.children.isEmpty ?? true)
    }

    /// A branch spans the row: its value and what the value stands for.
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is RecordGroupItem }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let group = notification.userInfo?["NSObject"] as? RecordGroupItem else { return }
        collapsedGroups.insert(group.value)
        table.reloadItem(group)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let group = notification.userInfo?["NSObject"] as? RecordGroupItem else { return }
        collapsedGroups.remove(group.value)
        table.reloadItem(group)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? RecordGroupItem { return groupCell(group, in: outlineView) }
        guard let tableColumn, let values = (item as? RecordRowItem)?.values,
              let column = columns.first(where: { $0.id == tableColumn.identifier.rawValue }) else { return nil }
        let first = tableColumn === outlineView.tableColumns.first
        let identifier = NSUserInterfaceItemIdentifier(first ? "record.first" : "record.cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? ToolPanelTable.makeCell(identifier: identifier, marker: first)
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

    /// A branch's row, as the Interfaces tab draws a kind: its own chevron,
    /// the value one weight up with the number of its rows, then what the
    /// value stands for in grey.
    private func groupCell(_ group: RecordGroupItem, in outlineView: NSOutlineView) -> NSView {
        let id = NSUserInterfaceItemIdentifier("record.group")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? CodeNavigatorCell
            ?? CodeNavigatorCell(identifier: id)
        cell.showsDisclosure(true)
        cell.showsCalls(expandable: !group.children.isEmpty, expanded: outlineView.isItemExpanded(group))
        cell.onToggle = { [weak self] in self?.toggle(group) }
        let size = ToolPanelFont.size
        let line = NSMutableAttributedString(string: "\(group.value) (\(group.children.count))", attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.labelColor
        ])
        if let summary = group.summary {
            line.append(NSAttributedString(string: "  " + summary, attributes: [
                .font: ToolPanelFont.body(), .foregroundColor: NSColor.secondaryLabelColor
            ]))
        }
        cell.textField?.attributedStringValue = line
        cell.textField?.lineBreakMode = .byTruncatingTail
        cell.toolTip = group.summary
        return cell
    }

    /// Opens or closes a branch, as the Interfaces tab's kinds do.
    private func toggle(_ group: RecordGroupItem) {
        if table.isItemExpanded(group) {
            table.collapseItem(group)
        } else {
            table.expandItem(group)
        }
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
        if let groupBy = record?.groupBy, let groupColumn = record?.column(groupBy) {
            if table.sortDescriptors.isEmpty { rows.sort(by: keyOrder) }
            let groups = Self.groups(of: rows, by: groupColumn, keepEmpty: query.isEmpty)
            items = groups
            shownRows = groups.flatMap { $0.children.map(\.values) }
        } else {
            items = rows.map(RecordRowItem.init)
            shownRows = rows
        }
        table.reloadData()
        for case let group as RecordGroupItem in items where !collapsedGroups.contains(group.value) {
            table.expandItem(group)
        }
        let empty = allRows.isEmpty
        tableScroll.isHidden = shownRows.isEmpty
        searchField.isHidden = empty
        emptyLabel.isHidden = !shownRows.isEmpty || (empty && records[recordID ?? ""]?.status == AnalysisProfile.RecordStatus.none)
        emptyLabel.stringValue = empty ? Self.emptyText : L("Nothing matches the search.")
    }

    /// The branches of a grouped record: one per value of `column` in the
    /// order it declares them, then any other value the rows hold. A value
    /// with words of its own is a branch with no rows too, unless a filter
    /// is on.
    private static func groups(of rows: [[String: RecordValue]], by column: AnalysisProfile.Column,
                               keepEmpty: Bool) -> [RecordGroupItem] {
        func value(_ row: [String: RecordValue]) -> String { row[column.id]?.text ?? "" }
        let declared = column.values ?? []
        let found = Set(rows.map(value))
        let others = found.subtracting(declared).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return (declared + others).compactMap { name in
            let children = rows.filter { value($0) == name }.map(RecordRowItem.init)
            let english = column.valueSummaries?[name]
            guard !children.isEmpty || (keepEmpty && english != nil) else { return nil }
            return RecordGroupItem(value: name, summary: english.map(valueSummary), children: children)
        }
    }

    /// Rows in key order, the grouping column aside: an enum by the order
    /// its values are declared (normal before flash), a number as a number.
    private func keyOrder(_ left: [String: RecordValue], _ right: [String: RecordValue]) -> Bool {
        for id in record?.key ?? [] where id != record?.groupBy {
            guard let column = record?.column(id) else { continue }
            let a = keyRank(left, column), b = keyRank(right, column)
            if let x = a.number, let y = b.number {
                if x != y { return x < y }
                continue
            }
            if a.number != nil || b.number != nil { return a.number != nil }
            let order = a.text.localizedStandardCompare(b.text)
            if order != .orderedSame { return order == .orderedAscending }
        }
        return false
    }

    private func keyRank(_ row: [String: RecordValue], _ column: AnalysisProfile.Column) -> (number: Int?, text: String) {
        if column.kind == .enum, let value = row[column.id]?.text, let index = column.values?.firstIndex(of: value) {
            return (index, value)
        }
        return sortKey(row, column)
    }

    private func sortKey(_ row: [String: RecordValue], _ column: AnalysisProfile.Column) -> (number: Int?, text: String) {
        let number: Int? = switch column.kind {
        case .int, .byte, .code, .data: row[column.id]?.int
        case .computed: computed(row, column).flatMap(RecordValue.integer)
        default: nil
        }
        return (number, text(of: row, column))
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applyFilter()
    }

    // MARK: - Clicks

    @objc private func clicked() {
        guard table.clickedRow >= 0, table.clickedColumn >= 0 else { return }
        follow(row: table.clickedRow, column: table.clickedColumn)
    }

    private func follow(row: Int, column index: Int) {
        guard let shown = values(atRow: row), table.tableColumns.indices.contains(index),
              let column = columns.first(where: { $0.id == table.tableColumns[index].identifier.rawValue }),
              let value = shown[column.id] else { return }
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

    /// Selects the row whose key text is `key`, clearing a filter that hides
    /// it and opening the branch it stands in.
    func select(key: String) {
        if !shownRows.contains(where: { keyText($0) == key }), !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            applyFilter()
        }
        for case let group as RecordGroupItem in items
        where group.children.contains(where: { keyText($0.values) == key }) && !table.isItemExpanded(group) {
            table.expandItem(group)
        }
        guard let row = tableRow(key: key) else { return }
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

extension CodeRecordSectionView {
    /// A record's header in the reader's language: the profiles carry
    /// English, and words not listed here stay the profile's.
    static func header(_ english: String) -> String {
        switch english {
        case AnalysisProfile.hostCommandsHeader:
            L("Host commands are commands the host — the BIOS, SMM or the operating system's ACPI driver — writes to the EC's I/O ports. On the bus they are ordinary I/O cycles over LPC or, on eSPI, over the peripheral channel; in the EC the KBC and PMC blocks take them. Each port pair is a data port and a command port; the command byte is written to the command port.")
        default: english
        }
    }

    /// What a branch's value stands for, in the reader's language.
    static func valueSummary(_ english: String) -> String {
        switch english {
        case "Keyboard controller interface (KBC, i8042): keyboard, touchpad, legacy commands.":
            L("Keyboard controller interface (KBC, i8042): keyboard, touchpad, legacy commands.")
        case "The standard ACPI embedded controller (PMC1): EC RAM read and write (0x80/0x81), query 0x84, SCI.":
            L("The standard ACPI embedded controller (PMC1): EC RAM read and write (0x80/0x81), query 0x84, SCI.")
        case "The second PMC channel, usually the manufacturer's (OEM) commands: modes, flash mode, service functions.":
            L("The second PMC channel, usually the manufacturer's (OEM) commands: modes, flash mode, service functions.")
        default: english
        }
    }
}

/// A branch of a grouped record: a value of its `groupBy` column.
final class RecordGroupItem {
    let value: String
    let summary: String?
    let children: [RecordRowItem]

    init(value: String, summary: String?, children: [RecordRowItem]) {
        self.value = value
        self.summary = summary
        self.children = children
    }
}

/// A row of a record, as the outline holds it.
final class RecordRowItem {
    let values: [String: RecordValue]
    init(_ values: [String: RecordValue]) { self.values = values }
}

/// A menu item that runs a closure: one of several places a cell names.
private final class RecordMenuItem: NSMenuItem {
    var handler: (() -> Void)?
    @objc func perform(_ sender: Any?) { handler?() }
}
