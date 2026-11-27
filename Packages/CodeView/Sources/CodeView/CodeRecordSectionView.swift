import AnalysisProfiles
import ALSplitView
import AppKit
import CodeAnalysis
import HelpUI
import Localization
import ToolModuleKit

/// A navigator tab for one kind of record a review keeps — an EC image's
/// interrupts, host commands, EC RAM and so on, as the module's analysis
/// profile declares them. Made for the narrow navigator column, in the
/// Functions list's manner: the title with an (i) for what the record is, the
/// status on one line, a list of one line a row — the row's key and a short
/// label — the selected row's fields under it, and the filter at the foot.
///
/// The rows come from the review document of the revision the pane shows
/// (`setRecords`); until it is read, the manifest's statuses stand for it.
/// In the details an address is a link (`onOpenAddress`) and a value naming a
/// row of another record switches to that record and selects the row; so does
/// a row of another record that names this one.
///
/// A record with `groupBy` is a tree: a branch per value of that column, with
/// the value's short name (`valueTitles`) and, where the value has words of
/// its own (`valueSummaries`), an (i) for them; such a value is a branch even
/// with no rows. A filter hides a branch none of whose rows match.
// help: panel.code.record-sections
final class CodeRecordSectionView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// The record id the section shows, nil before the first `show`.
    private(set) var recordID: String?
    /// The legend over the list, as a panel's marks legend: shut, one line —
    /// the record's name and its status; open, what the record is (the
    /// profile's `header`) and the review's note on it. Open or shut is
    /// remembered per record (`legendKey`), shut until the reader opens it.
    let legendDisclosure = NSButton()
    let legendTitle = NSButton()
    private let legendBody = NSStackView()
    private let headerLabel = NSTextField(wrappingLabelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private var titleText = ""
    /// At the foot, as the Functions list's filter (`CodePaneView.dressFilter`).
    let searchField = NSSearchField()
    let filterBar = NSView()
    /// The rows, a tree for a grouped record and a flat list otherwise. The
    /// outline draws no triangle of its own: a branch carries its chevron.
    let table = SearchOutlineView()
    let tableScroll = NSScrollView()
    /// The selected row's fields, in the pane the firmware panels' details
    /// stand in: under the list in a splitter, Space or the corner button
    /// opening it large (`ToolDetailPane`).
    let detailPane = ToolDetailPane()
    var details: ToolDetailScroll { detailPane.detail }
    /// The list over the details, as the firmware panels have them.
    let splitter = ALSplitView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let popover = NSPopover()
    /// The words the last (i) showed, for the tests.
    private(set) var shownPopoverText: String?

    /// Opens an address of the module — a `code` or `data` value clicked.
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
    private var storedNote: String?
    /// Every row of the record, in the document's (key) order.
    private var allRows: [[String: RecordValue]] = []
    /// The rows shown: filtered, branch after branch for a grouped record.
    private(set) var shownRows: [[String: RecordValue]] = []
    /// The outline's items: branches for a grouped record, rows otherwise.
    private var items: [AnyObject] = []
    /// The branches the reader closed, by value; every other one is open.
    private var collapsedGroups: Set<String> = []
    /// The key text of a row to select once the record is shown.
    private var pendingSelection: String?
    /// Where the reader left each record: the selected row's key and the
    /// list's scroll, kept while the pane lives, so a tab switched away
    /// from and back — or a new revision — shows the same row.
    private var places: [String: (key: String?, scroll: NSPoint)] = [:]

    /// Notes the shown record's selected row and scroll in `places`.
    private func rememberPlace() {
        guard let recordID, record != nil else { return }
        let selected = table.selectedRowIndexes
        let key = selected.count == 1 ? values(atRow: selected.first!).map(keyText) : nil
        places[recordID] = (key, tableScroll.contentView.bounds.origin)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        legendDisclosure.bezelStyle = .disclosure
        legendDisclosure.setButtonType(.pushOnPushOff)
        legendDisclosure.title = ""
        legendDisclosure.target = self
        legendDisclosure.action = #selector(legendToggled)
        // help: panel.code.record-sections
        ControlHelp.describe(legendDisclosure, name: L("About this record"),
                             tooltip: L("Show or hide what this record is and the review's note on it"))
        legendTitle.isBordered = false
        legendTitle.target = self
        legendTitle.action = #selector(legendTitleClicked)
        (legendTitle.cell as? NSButtonCell)?.wraps = false
        legendTitle.cell?.lineBreakMode = .byTruncatingTail
        legendTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [headerLabel, noteLabel] {
            label.isSelectable = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        noteLabel.textColor = .secondaryLabelColor
        // The same quiet, centred words as the navigator's empty lists.
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isSelectable = false

        CodePaneView.dressFilter(searchField)
        ControlHelp.describe(searchField, L("Filter the record's rows"))
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(filterChanged)

        // One column and no header, as the Functions list.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.outlineTableColumn = column
        table.dataSource = self
        table.delegate = self
        CodeNavigatorCell.dress(table)
        table.allowsMultipleSelection = true
        let menu = NSMenu()
        // help: panel.code.record-sections
        menu.addItem(withTitle: L("Copy Row as TSV"), action: #selector(copyRows), keyEquivalent: "").target = self
        table.menu = menu
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = false
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = false

        details.showPlaceholder(Self.noSelectionText)
        detailPane.attach(to: table)
        splitter.isVertical = false
        splitter.dividerThickness = 1
        splitter.addPane(tableScroll)
        splitter.addPane(detailPane)
        splitter.setPaneLayout(.fill, at: 0)
        splitter.setPaneLayout(.proportional(0.4), at: 1)

        let heading = NSStackView(views: [legendDisclosure, legendTitle])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 2
        legendBody.orientation = .vertical
        legendBody.alignment = .leading
        legendBody.spacing = 4
        legendBody.detachesHiddenViews = true
        // Under the title, not under the chevron, as the marks legend.
        legendBody.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        legendBody.addArrangedSubview(headerLabel)
        legendBody.addArrangedSubview(noteLabel)
        let words = NSStackView(views: [heading, legendBody])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 4
        words.detachesHiddenViews = true
        filterBar.addSubview(searchField)
        let parts: [NSView] = [words, splitter, filterBar, emptyLabel]
        for view in parts + [searchField] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        for view in parts { addSubview(view) }
        NSLayoutConstraint.activate([
            words.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            words.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            words.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: words.trailingAnchor),
            legendBody.widthAnchor.constraint(equalTo: words.widthAnchor),
            splitter.topAnchor.constraint(equalTo: words.bottomAnchor, constant: 6),
            splitter.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitter.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitter.bottomAnchor.constraint(equalTo: filterBar.topAnchor),
            filterBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            filterBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            filterBar.heightAnchor.constraint(equalTo: searchField.heightAnchor,
                                              constant: 2 * CodePaneView.navigatorBarRoom),
            searchField.centerYAnchor.constraint(equalTo: filterBar.centerYAnchor, constant: 0.5),
            searchField.leadingAnchor.constraint(equalTo: filterBar.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: filterBar.trailingAnchor, constant: -8),
            emptyLabel.topAnchor.constraint(equalTo: words.bottomAnchor, constant: 12),
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
        rememberPlace()
        let changed = recordID != id
        recordID = id
        self.fallbackTitle = fallbackTitle
        record = profile?.records.first { $0.id == id }
        titleText = Self.title(of: id, fallback: fallbackTitle)
        emptyLabel.font = font
        headerLabel.font = CodePaneView.navigatorFont()
        noteLabel.font = CodePaneView.navigatorFont()
        table.rowHeight = CodePaneView.navigatorRowHeight
        if changed {
            searchField.stringValue = ""
            collapsedGroups = []
        }

        let stored = records[id]
        let status = stored?.status
            ?? statuses[id].flatMap(AnalysisProfile.RecordStatus.init) ?? .unanswered
        let statusText = Self.statusText(status, note: stored?.note)
        let note = status == .none ? nil : stored?.note
        storedNote = note
        shownStatus = statusText
        let short = statusText.hasSuffix(".") ? String(statusText.dropLast()) : statusText
        let line = NSMutableAttributedString(string: titleText, attributes: [
            .font: NSFont.systemFont(ofSize: ToolPanelFont.size, weight: .semibold), .foregroundColor: NSColor.labelColor
        ])
        line.append(NSAttributedString(string: " · " + short, attributes: [
            .font: ToolPanelFont.body(), .foregroundColor: NSColor.secondaryLabelColor
        ]))
        legendTitle.attributedTitle = line
        let header = record?.header.map(Self.header) ?? ""
        headerLabel.stringValue = header
        headerLabel.isHidden = header.isEmpty
        noteLabel.stringValue = note ?? ""
        noteLabel.isHidden = (note ?? "").isEmpty
        legendDisclosure.isHidden = header.isEmpty && (note ?? "").isEmpty
        applyLegend()
        allRows = (stored?.rows ?? []).sorted(by: keyOrder)
        measureKeys()
        applyFilter()
        if let key = pendingSelection {
            pendingSelection = nil
            select(key: key)
        } else if let place = places[id] {
            // Back to this record, or a new revision of it: the row the
            // reader left selected, if its key is still there, and the
            // scroll where it was.
            if let key = place.key { select(key: key) }
            table.scroll(place.scroll)
        }
        showDetails()
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

    static var noSelectionText: String { L("Select a row to see its details.") }
    static var confidenceTitle: String { L("Confidence") }
    static var inferenceTitle: String { L("Inference") }
    static var establishedTitle: String { L("Established") }
    static var noteTitle: String { L("Note") }
    /// Back-references in the details: the rows of another record that name
    /// this one.
    static var usedByCommandsTitle: String { L("Used by host commands") }
    static var flashAreasTitle: String { L("Flash data areas") }

    // MARK: - For tests

    var shownTitle: String { titleText }
    /// The status alone, without the note after it.
    private(set) var shownStatus = ""
    /// The legend's one line: the record's name and its status.
    var shownLegendLine: String { legendTitle.attributedTitle.string }
    var shownNote: String { storedNote ?? "" }
    /// What the legend says the record is; empty when it has no words.
    var shownHeader: String { headerLabel.isHidden ? "" : headerLabel.stringValue }
    /// Whether the legend's words are on screen.
    var legendIsOpen: Bool { !legendBody.isHidden }
    /// The branches shown, in order: the value, the branch's words, its long
    /// words and how many rows it holds.
    var shownGroups: [(value: String, title: String, summary: String?, rows: Int)] {
        items.compactMap { $0 as? RecordGroupItem }.map { ($0.value, $0.label, $0.summary, $0.children.count) }
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
    func setFilter(_ text: String) {
        searchField.stringValue = text
        filterChanged()
    }
    /// The text of `column` id of the data row at `row`, as the details write
    /// it; empty on a branch.
    func cellText(row: Int, column id: String) -> String {
        guard let column = columns.first(where: { $0.id == id }), let values = values(atRow: row) else { return "" }
        return text(of: values, column)
    }
    /// The list's line of the data row at `row`: its key and its label.
    func listText(row: Int) -> String {
        guard let values = values(atRow: row) else { return "" }
        return Self.line(key: keyDisplay(values), label: label(values))
    }
    /// The row view's cell at `row`, as the outline makes it.
    func cell(row: Int) -> NSTableCellView? {
        guard let item = table.item(atRow: row) else { return nil }
        return outlineView(table, viewFor: table.tableColumns.first, item: item) as? NSTableCellView
    }
    /// Follows the value of column `id` of the row at `row`, as a click on
    /// it in the details does: the first place it names.
    func click(row: Int, column id: String) {
        guard let values = values(atRow: row), let column = columns.first(where: { $0.id == id }) else { return }
        places(values, column).first?.1()
    }
    /// The selected rows' TSV, as Copy Row puts it on the pasteboard; a
    /// branch's own row adds nothing, its rows carry its value.
    func tsv(rows: IndexSet) -> String {
        rows.compactMap { values(atRow: $0) }.map { values in
            columns.map { text(of: values, $0) }.joined(separator: "\t")
        }.joined(separator: "\n")
    }
    /// The details shown: each field's name and value, in order.
    private(set) var shownDetails: [(name: String, value: String)] = []
    /// The details' title and their sentence.
    private(set) var shownDetailTitle = ""
    private(set) var shownDetailSentence = ""

    /// The data row at the outline's `row`; nil for a branch.
    private func values(atRow row: Int) -> [String: RecordValue]? {
        guard row >= 0, row < table.numberOfRows else { return nil }
        return (table.item(atRow: row) as? RecordRowItem)?.values
    }

    // MARK: - Words of a row

    private var columns: [AnalysisProfile.Column] { record?.columns ?? [] }

    /// The column that says what a row does, by record: its first sentence
    /// is the label a row without one shows, and the details' sentence.
    private var mainColumn: AnalysisProfile.Column? {
        for id in ["effect", "purpose", "meaning", "function", "device"] {
            if let column = record?.column(id) { return column }
        }
        return nil
    }

    /// The first sentence of `text`.
    static func firstSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in [". ", "; ", "\n"] {
            if let range = trimmed.range(of: separator) {
                return String(trimmed[..<range.lowerBound])
            }
        }
        return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
    }

    /// The row's short label: the review's `label`, or the first sentence of
    /// its main text, whole — the line cuts it at the list's width, not here.
    func label(_ row: [String: RecordValue]) -> String {
        if let label = row["label"]?.string, !label.isEmpty { return label }
        guard let main = mainColumn else { return "" }
        return Self.firstSentence(text(of: row, main))
    }

    /// The row's key as the list writes it: `IRQ 24`, `0x59/0x02`, the range
    /// `0x2A–0x2B` of a wider EC RAM field, `0x0B`, `GPJ5`, `0x2A600`.
    func keyDisplay(_ row: [String: RecordValue]) -> String {
        func hex(_ id: String) -> String? { row[id].flatMap(Self.number).map { String(format: "0x%02X", $0) } }
        switch record?.id {
        case "irq_map":
            return row["irq"].flatMap(Self.number).map { "IRQ \($0)" } ?? ""
        case "host_commands":
            let cmd = hex("cmd") ?? ""
            return hex("sub").map { "\(cmd)/\($0)" } ?? cmd
        case "ec_ram":
            guard let offset = row["offset"].flatMap(Self.number) else { return row["offset"]?.text ?? "" }
            let width = row["width"].flatMap(Self.number) ?? 1
            let first = String(format: "0x%02X", offset)
            return width > 1 ? "\(first)–" + String(format: "0x%02X", offset + width - 1) : first
        default:
            return (record?.key ?? []).filter { $0 != record?.groupBy }.compactMap { id -> String? in
                guard let column = record?.column(id) else { return nil }
                let part = text(of: row, column)
                return part.isEmpty ? nil : part
            }.joined(separator: " ")
        }
    }

    static func line(key: String, label: String) -> String {
        label.isEmpty ? key : "\(key)  \(label)"
    }

    /// A value as the column writes it: hex where the column is, enum words
    /// raw, a list joined, a nested table as a count.
    private func text(of row: [String: RecordValue], _ column: AnalysisProfile.Column) -> String {
        if column.kind == .computed { return computed(row, column) ?? "" }
        guard let value = row[column.id], value != .null else { return "" }
        return Self.text(value, kind: column.kind, column: column, profile: profile)
    }

    /// The number an `int` or `byte` value holds: a JSON number, or the
    /// `0x…` or decimal text the review's store writes.
    static func number(_ value: RecordValue) -> Int? {
        if case .double(let double) = value, double.rounded() == double { return Int(double) }
        return value.int
    }

    static func text(_ value: RecordValue, kind: AnalysisProfile.ColumnKind, column: AnalysisProfile.Column,
                     profile: AnalysisProfile?) -> String {
        switch kind {
        case .byte:
            guard let number = number(value) else { return value.text }
            return String(format: "0x%02X", number)
        case .int:
            // A word the column takes instead of a number (runtime, mailbox)
            // stays a word.
            if let word = value.string, column.values?.contains(word) == true { return word }
            guard let number = number(value) else { return value.text }
            return column.hex == true ? String(format: "0x%02X", number) : String(number)
        case .code, .data:
            guard let number = number(value) else { return value.text }
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
            guard let offset = row["offset"].flatMap(Self.number),
                  let base = record?.parameters["ec_ram_base"].flatMap(RecordValue.integer) else { return nil }
            return CodeAddress(UInt64(base + offset)).description
        case "smbus_address_8bit":
            guard let address = row["address"], address.string.map({ RecordValue.integer($0) != nil }) ?? true,
                  let seven = Self.number(address) else { return nil }
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

    private static func isLink(_ column: AnalysisProfile.Column) -> Bool {
        [.code, .data, .ref].contains(column.kind)
            || (column.kind == .list && [.code, .data, .ref].contains(column.of ?? .text))
    }

    // MARK: - The list

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

    /// Only the chevron is drawn again: a branch's row is not made anew, so
    /// nothing in it can change as it opens and closes.
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let group = notification.userInfo?["NSObject"] as? RecordGroupItem else { return }
        collapsedGroups.insert(group.value)
        redrawChevron(group)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let group = notification.userInfo?["NSObject"] as? RecordGroupItem else { return }
        collapsedGroups.remove(group.value)
        redrawChevron(group)
    }

    private func redrawChevron(_ group: RecordGroupItem) {
        let row = table.row(forItem: group)
        guard row >= 0, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? RecordGroupCell
        else { return }
        cell.showsCalls(expandable: !group.children.isEmpty, expanded: table.isItemExpanded(group))
    }

    /// The row's one mark, in the cell's marker slot: the `?` of an inferred
    /// row; otherwise a pin's direction — up for out, down for in.
    private func mark(_ row: [String: RecordValue]) -> (symbol: String, tip: String)? {
        if Self.isInference(row) { return ("circle.dashed", Self.inferenceToolTip(note: row["note"]?.string)) }
        guard record?.id == "gpio" else { return nil }
        let direction = row["direction"]?.string ?? ""
        let symbol: String? = switch direction {
        case "out": "arrow.up"
        case "in": "arrow.down"
        case "bidir": "arrow.up.arrow.down"
        default: nil
        }
        guard let symbol, let tip = Self.directionTip(direction) else { return nil }
        return (symbol, tip)
    }

    /// What a pin's arrow says.
    static func directionTip(_ direction: String) -> String? {
        switch direction {
        case "out": L("Output")
        case "in": L("Input")
        case "bidir": L("Input and output")
        default: nil
        }
    }

    /// Whether the rows stand under branches.
    private var isGrouped: Bool { items.first is RecordGroupItem }

    /// Where a row's label starts: past the widest key and its tag.
    private var keyColumnWidth: CGFloat = 0

    private func measureKeys() {
        let mono = CodePaneView.navigatorCodeFont()
        let tagFont = NSFont.systemFont(ofSize: max(CodePaneView.navigatorSize - 2, 9), weight: .bold)
        keyColumnWidth = allRows.map { row -> CGFloat in
            var width = (keyDisplay(row) as NSString).size(withAttributes: [.font: mono]).width
            if let tag = tag(row) { width += (" " + tag as NSString).size(withAttributes: [.font: tagFont]).width }
            if mark(row) != nil { width += CodePaneView.navigatorSize + 4 }
            return width
        }.max().map { ($0 + 8).rounded(.up) } ?? 0
    }

    /// A short word after the key: `flash` for a command taken in flash mode,
    /// `PEC` for an SMBus device whose transfers carry one.
    private func tag(_ row: [String: RecordValue]) -> String? {
        switch record?.id {
        case "host_commands" where row["mode"]?.string == "flash": Self.valueTitle("flash")
        case "smbus_peers" where row["pec"] == .bool(true): "PEC"
        default: nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? RecordGroupItem { return groupCell(group, in: outlineView) }
        guard let values = (item as? RecordRowItem)?.values else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("record.row")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? RecordRowCell
            ?? RecordRowCell(identifier: identifier)
        let inference = Self.isInference(values)
        // An interrupt the firmware leaves off reads in grey.
        let off = record?.id == "irq_map" && values["enabled_by_firmware"] == .bool(false)
        let ink: NSColor = off ? .secondaryLabelColor : .labelColor
        func styled(_ font: NSFont) -> NSFont {
            inference ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
        }
        let body = styled(CodePaneView.navigatorFont())
        let line = NSMutableAttributedString(string: keyDisplay(values), attributes: [
            .font: styled(CodePaneView.navigatorCodeFont()), .foregroundColor: ink
        ])
        if let tag = tag(values) {
            line.append(NSAttributedString(string: " " + tag, attributes: [
                .font: NSFont.systemFont(ofSize: max(CodePaneView.navigatorSize - 2, 9), weight: .bold),
                .foregroundColor: NSColor.systemOrange
            ]))
        }
        // The row's one mark stands after the key, in grey, as the Interfaces
        // tab writes an interface's marks after its name.
        let mark = mark(values)
        if let mark, let image = NSImage(systemSymbolName: mark.symbol, accessibilityDescription: mark.tip)?
            .withSymbolConfiguration(.init(pointSize: CodePaneView.navigatorSize - 2, weight: .regular)
                .applying(.init(hierarchicalColor: .secondaryLabelColor))) {
            let attachment = NSTextAttachment()
            attachment.image = image
            let font = CodePaneView.navigatorFont()
            attachment.bounds = NSRect(x: 0, y: (font.capHeight - image.size.height) / 2,
                                       width: image.size.width, height: image.size.height)
            line.append(NSAttributedString(string: " "))
            line.append(NSAttributedString(attachment: attachment))
        }
        let label = label(values)
        if !label.isEmpty {
            line.append(NSAttributedString(string: "\t" + label, attributes: [.font: body, .foregroundColor: ink]))
        }
        // The labels start in one column, past the widest key and its mark.
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: keyColumnWidth)]
        paragraph.lineBreakMode = .byTruncatingTail
        line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
        cell.showsDisclosure(isGrouped)
        cell.showsCalls(expandable: false, expanded: false)
        cell.indent = isGrouped ? CodeNavigatorCell.disclosureRoom - 2 : 0
        cell.show(line: line, mark: Self.rowMark(record?.id), said: mark?.tip)
        // No pointer words that repeat the line: the note only, which the
        // line does not show, and on a marked row what the mark says.
        cell.toolTip = mark?.tip ?? values["note"]?.string
        return cell
    }

    /// A branch's row: its own chevron, its words one weight up with the
    /// number of its rows, and an (i) for its long words.
    private func groupCell(_ group: RecordGroupItem, in outlineView: NSOutlineView) -> NSView {
        let id = NSUserInterfaceItemIdentifier("record.group")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? RecordGroupCell
            ?? RecordGroupCell(identifier: id)
        cell.showsDisclosure(true)
        cell.showsCalls(expandable: !group.children.isEmpty, expanded: outlineView.isItemExpanded(group))
        cell.onToggle = { [weak self] in self?.toggle(group) }
        cell.show(group, mark: Self.groupMark(record))
        cell.info.target = self
        cell.info.action = #selector(groupInfoClicked(_:))
        return cell
    }

    /// A record row's mark: a letter on the record's colour, as an interface
    /// carries its `G`.
    static func rowMark(_ record: String?) -> (glyph: CodeNavigatorIcon.Glyph, color: NSColor)? {
        switch record {
        case "irq_map": (.letter("I"), .systemOrange)
        case "host_commands": (.letter("C"), .systemTeal)
        case "ec_ram": (.letter("R"), .systemGreen)
        case "smbus_peers": (.letter("S"), .systemIndigo)
        case "gpio": (.letter("P"), .systemBrown)
        case "eflash_area": (.letter("F"), .systemPink)
        default: nil
        }
    }

    /// A branch's mark: the record's own sign on its colour, as the
    /// Interfaces tab's headings carry theirs.
    static func groupMark(_ record: AnalysisProfile.Record?) -> (glyph: CodeNavigatorIcon.Glyph, color: NSColor)? {
        guard let symbol = record?.panel?.symbol, let color = rowMark(record?.id)?.color else { return nil }
        return (.symbol(symbol), color)
    }

    /// Opens or closes a branch, as the Interfaces tab's kinds do.
    private func toggle(_ group: RecordGroupItem) {
        CodeNavigatorCell.toggle(group, in: table)
    }

    // MARK: - The (i) popovers

    /// Where the legend's state is remembered: per record, in the store
    /// every panel setting lives in.
    static func legendKey(_ record: String) -> String { "RecordLegendExpanded.\(record)" }

    /// Forgets the legend's state for `record`, for the tests.
    static func forgetLegend(_ record: String) {
        ToolPanelFont.defaults.removeObject(forKey: legendKey(record))
    }

    @objc private func legendToggled() {
        setLegendOpen(legendDisclosure.state == .on)
    }

    @objc private func legendTitleClicked() {
        guard !legendDisclosure.isHidden else { return }
        setLegendOpen(legendBody.isHidden)
    }

    /// Opens or shuts the legend, and remembers it for this record.
    func setLegendOpen(_ open: Bool) {
        guard let recordID else { return }
        ToolPanelFont.defaults.set(open, forKey: Self.legendKey(recordID))
        applyLegend()
    }

    private func applyLegend() {
        let open = recordID.map { ToolPanelFont.defaults.object(forKey: Self.legendKey($0)) as? Bool ?? false } ?? false
        let shows = open && !legendDisclosure.isHidden
        legendDisclosure.state = shows ? .on : .off
        legendBody.isHidden = !shows
    }

    @objc private func groupInfoClicked(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard row >= 0 else { return }
        showGroupInfo(row: row)
    }

    /// Shows the (i) of the branch at `row`: from the row, `.maxX`, so the
    /// rows under it stay in sight.
    func showGroupInfo(row: Int) {
        // What the ports are, from the profile, then what the review says
        // of this branch: what it covered and left out there.
        guard let group = table.item(atRow: row) as? RecordGroupItem, group.hasInfo else { return }
        let text = [group.summary, group.note].compactMap { $0 }.joined(separator: "\n\n")
        showInfo(title: group.label, text: text, relativeTo: table.rect(ofRow: row), of: table, edge: .maxX)
    }

    private func showInfo(title: String, text: String, relativeTo rect: NSRect, of view: NSView, edge: NSRectEdge) {
        shownPopoverText = text
        let stack = ToolPanelPopover.stack()
        stack.addArrangedSubview(ToolPanelPopover.title(title))
        stack.addArrangedSubview(ToolPanelPopover.prose(text))
        let controller = NSViewController()
        controller.view = ToolPanelPopover.content(stack)
        guard view.window != nil else { return }
        ToolPanelPopover.show(popover, with: controller, relativeTo: rect, of: view, edge: edge)
    }

    // MARK: - Details

    func outlineViewSelectionDidChange(_ notification: Notification) { showDetails() }

    /// The selected row, in the rows every firmware panel's details are
    /// drawn with (`ToolDetailScroll.showRows`): its key and the review's
    /// label as the title, then its fields in the record's order — facts,
    /// the main text whole among them, then the places it leads to as links,
    /// then the rows of other records that name it — and last the confidence
    /// and the note. Each text once: no first sentence over the text it
    /// starts, no field for the branch the row stands in.
    private func showDetails() {
        shownDetails = []
        shownDetailTitle = ""
        shownDetailSentence = ""
        linkActions = []
        let selected = table.selectedRowIndexes
        guard selected.count == 1, let values = values(atRow: selected.first!) else {
            details.showPlaceholder(allRows.isEmpty ? "" : Self.noSelectionText)
            return
        }
        var fields: [ToolFieldList.Field] = []
        var extras: [NSView] = []
        func add(_ name: String, _ value: NSAttributedString) {
            fields.append(.init(label: name, value: value))
            shownDetails.append((name, value.string))
        }
        // Every value in the firmware panels' one font (`ToolValueTone`).
        func plain(_ text: String) -> NSAttributedString { ToolValueTone.standard.attributedValue(text) }
        func linked(_ places: [(String, () -> Void)], separator: String) -> NSAttributedString {
            let text = NSMutableAttributedString()
            for (index, (title, action)) in places.enumerated() {
                if index > 0 { text.append(plain(separator)) }
                linkActions.append(action)
                text.append(ToolFieldList.link(title, to: linkActions.count - 1))
            }
            return text
        }

        let label = values["label"]?.string ?? ""
        shownDetailTitle = label.isEmpty ? keyDisplay(values) : "\(keyDisplay(values)) · \(label)"
        let titled = Set((record?.key ?? []).filter { $0 != record?.groupBy && $0 != "mode" })
        let shown = columns.filter { column in
            // The branch the row stands in says its value already.
            !(column.id == "label" || column.id == record?.groupBy || titled.contains(column.id))
        }
        for column in shown where !Self.isLink(column) {
            let text = text(of: values, column).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != label else { continue }
            let name = Self.columnTitle(column.title)
            if column.id == mainColumn?.id { shownDetailSentence = text }
            if column.kind == .rows {
                // A small table of its own, under the rows, as a panel adds
                // what is its own after the list.
                shownDetails.append((name, text))
                let heading = NSTextField(labelWithString: name)
                heading.font = ToolPanelFont.body()
                heading.textColor = .secondaryLabelColor
                extras += [heading, commandsGrid(values[column.id], column: column)]
            } else {
                add(name, plain(column.kind == .enum ? Self.valueTitle(text) : text))
            }
        }
        for column in shown where Self.isLink(column) {
            let places = places(values, column)
            guard !places.isEmpty else { continue }
            add(Self.columnTitle(column.title), linked(places, separator: ", "))
        }
        for (name, places) in backReferences(values) where !places.isEmpty {
            add(name, linked(places, separator: "\n"))
        }
        let inference = Self.isInference(values)
        add(Self.confidenceTitle, plain(inference ? Self.inferenceTitle : Self.establishedTitle))
        if let note = values["note"]?.string, !note.isEmpty { add(Self.noteTitle, plain(note)) }

        let list = details.showRows(subject: keyText(values), title: shownDetailTitle, fields: fields)
        list.onLink = { [weak self] target in
            guard let self, let index = target as? Int, self.linkActions.indices.contains(index) else { return }
            self.linkActions[index]()
        }
        for view in extras { details.content.addArrangedSubview(view) }
    }

    /// What each link of the details does, by the index its run carries.
    private var linkActions: [() -> Void] = []

    /// Rows of other records that name this one: the host commands that
    /// touch an EC RAM field, the flash areas a host command reaches.
    private func backReferences(_ row: [String: RecordValue]) -> [(String, [(String, () -> Void)])] {
        guard let profile, let id = record?.id else { return [] }
        let key = keyText(row)
        var found: [(String, [(String, () -> Void)])] = []
        for other in profile.records where other.id != id {
            for column in other.columns where column.ref == id {
                let rows = (records[other.id]?.rows ?? []).filter { candidate in
                    let named = column.kind == .list ? (candidate[column.id]?.array ?? []) : [candidate[column.id]].compactMap { $0 }
                    return named.contains { item in
                        let itemKey = record!.key.count == 1
                            ? ModuleRecords.rowKey([record!.key[0]: item], key: record!.key)
                            : ModuleRecords.rowKey(item.object ?? [:], key: record!.key)
                        return itemKey == key
                    }
                }
                guard !rows.isEmpty else { continue }
                let saved = record
                record = other
                let ordered = rows.sorted(by: keyOrder)
                record = saved
                let name = other.id == "host_commands" ? Self.usedByCommandsTitle
                    : other.id == "eflash_area" ? Self.flashAreasTitle
                    : Self.title(of: other.id, fallback: other.title)
                let places: [(String, () -> Void)] = ordered.map { target in
                    let words = otherLine(target, in: other)
                    let targetKey = ModuleRecords.rowKey(target, key: other.key)
                    return (words, { [weak self] in self?.showRef(other.id, key: targetKey) })
                }
                found.append((name, places))
            }
        }
        return found
    }

    /// A row of another record as a back-reference writes it: its key and label.
    private func otherLine(_ row: [String: RecordValue], in other: AnalysisProfile.Record) -> String {
        let saved = record
        record = other
        defer { record = saved }
        return Self.line(key: keyDisplay(row), label: label(row))
    }

    /// An SMBus device's commands: a small table of command, R/W, size and
    /// meaning.
    private func commandsGrid(_ value: RecordValue?, column: AnalysisProfile.Column) -> NSView {
        let inner = column.columns ?? []
        let rows: [[NSView]] = (value?.array ?? []).map { item in
            let object = item.object ?? [:]
            return inner.map { part in
                let text = object[part.id].map { Self.text($0, kind: part.kind, column: part, profile: profile) } ?? ""
                let field = NSTextField(wrappingLabelWithString: text)
                field.font = part.kind == .byte ? ToolPanelFont.monospaced(size: ToolPanelFont.size) : ToolPanelFont.body()
                field.isSelectable = true
                return field
            }
        }
        guard !rows.isEmpty else { return NSTextField(labelWithString: "") }
        let grid = NSGridView(views: rows)
        grid.columnSpacing = 8
        grid.rowSpacing = 2
        if let last = grid.column(at: grid.numberOfColumns - 1) as NSGridColumn? { last.xPlacement = .leading }
        return grid
    }

    // MARK: - Filter and order

    @objc private func filterChanged() { applyFilter() }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        var rows = allRows
        if !query.isEmpty {
            rows = rows.filter { row in
                keyDisplay(row).localizedCaseInsensitiveContains(query)
                    || label(row).localizedCaseInsensitiveContains(query)
            }
        }
        if let groupBy = record?.groupBy, let groupColumn = record?.column(groupBy) {
            let groups = Self.groups(of: rows, by: groupColumn, keepEmpty: query.isEmpty,
                                     notes: records[recordID ?? ""]?.branchNotes ?? [:])
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
        splitter.isHidden = empty
        filterBar.isHidden = empty
        emptyLabel.isHidden = !shownRows.isEmpty || (empty && records[recordID ?? ""]?.status == AnalysisProfile.RecordStatus.none)
        emptyLabel.stringValue = empty ? Self.emptyText : L("Nothing matches the search.")
        showDetails()
    }

    /// The value a row stands under: its own, `other` for a row with none
    /// when the column has that value, a bool as `true` or `false`.
    private static func groupValue(_ row: [String: RecordValue], _ column: AnalysisProfile.Column) -> String {
        if case .bool(let on)? = row[column.id] { return on ? "true" : "false" }
        let value = row[column.id]?.text ?? ""
        if value.isEmpty, column.values?.contains("other") == true { return "other" }
        return value
    }

    /// The branches of a grouped record: one per value of `column` in the
    /// order it declares them (a bool: true, then false), then any other
    /// value the rows hold. A value with words of its own is a branch with no
    /// rows too, unless a filter is on.
    private static func groups(of rows: [[String: RecordValue]], by column: AnalysisProfile.Column,
                               keepEmpty: Bool, notes: [String: String]) -> [RecordGroupItem] {
        let declared = column.values ?? (column.kind == .bool ? ["true", "false"] : [])
        let found = Set(rows.map { groupValue($0, column) })
        let others = found.subtracting(declared).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return (declared + others).compactMap { name in
            let children = rows.filter { groupValue($0, column) == name }.map(RecordRowItem.init)
            let english = column.valueSummaries?[name]
            guard !children.isEmpty || (keepEmpty && english != nil) else { return nil }
            let title = column.valueTitles?[name].map(valueTitle) ?? ""
            // A port pair is read by its numbers and its purpose; a branch
            // with a name of its own by the name; a bare value by its column.
            let label = title.isEmpty ? "\(columnTitle(column.title)) \(name)"
                : english != nil ? "\(name)  \(title)" : title
            return RecordGroupItem(value: name, title: title, label: label,
                                   summary: english.map(valueSummary), note: notes[name], children: children)
        }
    }

    /// Rows in key order, the grouping column aside: a number as a number, a
    /// row without a part (a command with no subcommand) before one with it,
    /// an enum by the order its values are declared (normal before flash).
    private func keyOrder(_ left: [String: RecordValue], _ right: [String: RecordValue]) -> Bool {
        for id in record?.key ?? [] where id != record?.groupBy {
            guard let column = record?.column(id) else { continue }
            let a = keyRank(left, column), b = keyRank(right, column)
            if let x = a.number, let y = b.number {
                if x != y { return x < y }
                continue
            }
            if a.number != nil || b.number != nil {
                // A missing part first; a number before a word.
                if a.text.isEmpty != b.text.isEmpty { return a.text.isEmpty }
                return a.number != nil
            }
            let order = a.text.localizedStandardCompare(b.text)
            if order != .orderedSame { return order == .orderedAscending }
        }
        return false
    }

    private func keyRank(_ row: [String: RecordValue], _ column: AnalysisProfile.Column) -> (number: Int?, text: String) {
        if column.kind == .enum, let value = row[column.id]?.text, let index = column.values?.firstIndex(of: value) {
            return (index, value)
        }
        let number: Int? = switch column.kind {
        case .int, .byte, .code, .data: row[column.id].flatMap(Self.number)
        default: nil
        }
        return (number, text(of: row, column))
    }

    // MARK: - Places

    /// Where a value leads: an address, or a row of another record.
    private func places(_ row: [String: RecordValue], _ column: AnalysisProfile.Column) -> [(String, () -> Void)] {
        guard let value = row[column.id] else { return [] }
        let kind = column.kind == .list ? (column.of ?? .text) : column.kind
        let values = column.kind == .list ? (value.array ?? []) : [value]
        switch kind {
        case .code, .data:
            let addresses = values.compactMap { Self.number($0).map { CodeAddress(UInt64($0)) } }
            return addresses.map { address in (address.description, { [weak self] in self?.onOpenAddress?(address) }) }
        case .ref:
            guard let target = column.ref,
                  let referenced = profile?.records.first(where: { $0.id == target }) else { return [] }
            return values.map { item in
                let key: String
                if referenced.key.count == 1 {
                    key = ModuleRecords.rowKey([referenced.key[0]: item], key: referenced.key)
                } else {
                    key = ModuleRecords.rowKey(item.object ?? [:], key: referenced.key)
                }
                return (Self.refText(item, column: column, profile: profile), { [weak self] in self?.showRef(target, key: key) })
            }
        default:
            return []
        }
    }

    private func showRef(_ target: String, key: String) {
        pendingSelection = key
        if let onShowRecord {
            onShowRecord(target)
        } else {
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
        case "Group": L("Group")
        case "Handler": L("Handler")
        case "Host commands": L("Host commands")
        case "In the image": L("In the image")
        case "Initial state": L("Initial state")
        case "IRQ": L("IRQ")
        case "Label": L("Label")
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
            L("Host commands are commands the host — the BIOS, SMM or the operating system's ACPI driver — writes to the EC's I/O ports. On the bus they are ordinary I/O cycles over LPC or, on eSPI, over the peripheral channel. Each port pair is a data port and a command port; the command byte is written to the command port, the data bytes go through the data port.")
        default: english
        }
    }

    /// What a branch's value stands for, in the reader's language.
    static func valueSummary(_ english: String) -> String {
        switch english {
        case AnalysisProfile.kbcPortsSummary:
            L("Ports 0x60 (data) and 0x64 (command): the keyboard controller interface (KBC, i8042) — keyboard, touchpad and the legacy commands. In the EC the KBC block takes them.")
        case AnalysisProfile.acpiPortsSummary:
            L("Ports 0x62 (data) and 0x66 (command): the standard ACPI embedded controller interface — EC RAM read and write (0x80/0x81), query 0x84 and the SCI. In the EC the first PMC channel (PMC1) takes them.")
        case AnalysisProfile.oemPortsSummary:
            L("Ports 0x68 (data) and 0x6C (command): the second PMC channel (PMC2), usually the manufacturer's (OEM) commands — modes, flash mode, service functions.")
        default: english
        }
    }

    /// A value's short name, in the reader's language.
    static func valueTitle(_ english: String) -> String {
        switch english {
        case "Keyboard controller": L("Keyboard controller")
        case "ACPI EC": L("ACPI EC")
        case "OEM channel": L("OEM channel")
        case "flash": L("flash")
        case "Enabled": L("Enabled")
        case "Not enabled": L("Not enabled")
        case "Power": L("Power")
        case "Chipset": L("Chipset")
        case "Input": L("Input")
        case "Indicators": L("Indicators")
        case "USB": L("USB")
        case "Other": L("Other")
        default: english
        }
    }
}

/// A branch of a grouped record: a value of its `groupBy` column.
final class RecordGroupItem {
    let value: String
    /// The value's short name, empty when the profile gives none.
    let title: String
    /// What the branch's row reads: "62/66  ACPI EC", "Enabled", "Channel A".
    let label: String
    let summary: String?
    /// The review's note for the branch, in the review's words.
    let note: String?
    var hasInfo: Bool { summary != nil || note != nil }
    let children: [RecordRowItem]

    init(value: String, title: String, label: String, summary: String?, note: String? = nil,
         children: [RecordRowItem]) {
        self.note = note
        self.value = value
        self.title = title
        self.label = label
        self.summary = summary
        self.children = children
    }
}

/// A row of a record, as the outline holds it.
final class RecordRowItem {
    let values: [String: RecordValue]
    init(_ values: [String: RecordValue]) { self.values = values }
}

/// A branch's row, drawn as the Interfaces tab draws its headings
/// (`CodeNavigatorCell`): the chevron, the record's sign on a coloured
/// square, the words one weight up in grey with the number of rows, and an
/// (i) at the trailing edge for the branch's long words.
final class RecordGroupCell: CodeNavigatorCell {
    let info = ToolPanelInfoButton()
    /// The branch's words, for tests.
    var label: NSTextField { textField! }

    override init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(identifier: identifier)
        // help: panel.code.record-sections
        ControlHelp.describe(info, L("What these ports are"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ group: RecordGroupItem, mark: (glyph: CodeNavigatorIcon.Glyph, color: NSColor)?) {
        showsMark(mark, named: "record.group")
        textField?.attributedStringValue = NSAttributedString(
            string: group.label + " (\(group.children.count))",
            attributes: CodeNavigatorCell.headingAttributes())
        showsAccessory(group.hasInfo ? info : nil)
        info.isHidden = !group.hasInfo
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { info.backgroundStyle = backgroundStyle }
    }
}

/// A record's row, drawn as an interface of the Interfaces tab or a function
/// of the list (`CodeNavigatorCell`): the record's mark, the key, a pin's
/// arrow or an inferred row's `?` after it, and the label.
final class RecordRowCell: CodeNavigatorCell {
    /// What the row's one mark says — an inferred row's or a pin's — for
    /// tests and for the pointer over the line.
    private(set) var shownMark: String?

    func show(line: NSAttributedString, mark: (glyph: CodeNavigatorIcon.Glyph, color: NSColor)?,
              said: String?) {
        showsMark(mark, named: "record.row")
        textField?.attributedStringValue = line
        shownMark = said
    }
}
