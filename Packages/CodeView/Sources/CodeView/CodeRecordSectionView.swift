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
final class CodeRecordSectionView: CodeNavigatorTreePanel {
    /// The record id the section shows, nil before the first `show`.
    private(set) var recordID: String?
    /// The line over the list: the record's name and its status, and an
    /// (i) after them whose popover says what the record's rows cover and
    /// what the review has not checked — both the review's, for every record.
    let legendTitle = NSButton()
    let statusInfo = ToolPanelInfoButton()
    private var titleText = ""
    /// At the foot, as the Functions list's filter (`CodePaneView.dressFilter`).
    let searchField = NSSearchField()
    let filterBar = NSView()
    /// The rows, a tree for a grouped record and a flat list otherwise. The
    /// outline draws no triangle of its own: a branch carries its chevron.
    var table: CodeNavigatorOutlineView { outline }
    var tableScroll: NSScrollView { outlineScroll }
    /// The selected row's fields, in the pane the firmware panels' details
    /// stand in: under the list in a splitter, Space or the corner button
    /// opening it large (`ToolDetailPane`).
    let detailPane = ToolDetailPane()
    var details: ToolDetailScroll { detailPane.detail }
    /// The list over the details, as the firmware panels have them.
    let splitter = ALSplitView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    let popover = NSPopover()
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
    private var storedScope: String?
    private var storedNotChecked: String?
    private var storedOpenHead: String?
    /// Every row of the record, in the document's (key) order.
    private var allRows: [[String: RecordValue]] = []
    /// The rows shown: filtered, branch after branch for a grouped record.
    private(set) var shownRows: [[String: RecordValue]] = []
    /// The outline's items: branches for a grouped record, rows otherwise.
    private var items: [AnyObject] = [] {
        didSet { roots = items }
    }
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
        let key = selected.count == 1 ? values(atRow: selected.first!).map(section.keyText) : nil
        places[recordID] = (key, tableScroll.contentView.bounds.origin)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // help: panel.code.record-sections
        ControlHelp.describe(statusInfo, L("What the record's rows cover and what the review has not checked"))
        statusInfo.target = self
        statusInfo.action = #selector(statusInfoClicked)
        legendTitle.isBordered = false
        legendTitle.target = self
        legendTitle.action = #selector(legendTitleClicked)
        (legendTitle.cell as? NSButtonCell)?.wraps = false
        legendTitle.cell?.lineBreakMode = .byTruncatingTail
        legendTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        setUpOutline(column: "row")
        table.allowsMultipleSelection = true
        let menu = NSMenu()
        // help: panel.code.record-sections
        menu.addItem(withTitle: L("Copy Row as TSV"), action: #selector(copyRows), keyEquivalent: "").target = self
        table.menu = menu
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

        let heading = NSStackView(views: [legendTitle, statusInfo])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 2
        let words = NSStackView(views: [heading])
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
        titleText = CodeRecordSection.title(of: id, fallback: fallbackTitle)
        emptyLabel.font = font
        table.rowHeight = CodePaneView.navigatorRowHeight
        if changed {
            searchField.stringValue = ""
            collapsedGroups = []
        }

        let stored = records[id]
        let status = stored?.status
            ?? statuses[id].flatMap(AnalysisProfile.RecordStatus.init) ?? .unanswered
        let statusText = CodeRecordSection.statusText(status, note: stored?.note)
        let note = status == .none ? nil : stored?.note
        storedNote = note
        let parts = CodeRecordSection.notedParts(note: note, notChecked: status == .none ? nil : stored?.notChecked)
        storedScope = parts.scope
        storedNotChecked = parts.open
        storedOpenHead = parts.head
        shownStatus = statusText
        let short = statusText.hasSuffix(".") ? String(statusText.dropLast()) : statusText
        let line = NSMutableAttributedString(string: titleText, attributes: [
            .font: NSFont.systemFont(ofSize: ToolPanelFont.size, weight: .semibold), .foregroundColor: NSColor.labelColor
        ])
        line.append(NSAttributedString(string: " · " + short, attributes: [
            .font: ToolPanelFont.body(), .foregroundColor: NSColor.secondaryLabelColor
        ]))
        legendTitle.attributedTitle = line
        statusInfo.isHidden = parts.scope == nil && parts.open == nil
        allRows = (stored?.rows ?? []).sorted(by: section.keyOrder)
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
    /// The branches shown, in order: the value, the branch's words, its long
    /// words and how many rows it holds.
    var shownGroups: [(value: String, title: String, summary: String?, rows: Int)] {
        items.compactMap { $0 as? RecordGroupItem }.map { ($0.value, $0.label, $0.summary, $0.children.count) }
    }
    /// The outline's row of the data row whose key text is `key`.
    func tableRow(key: String) -> Int? {
        for item in items {
            let rows: [AnyObject] = (item as? RecordGroupItem)?.children ?? [item]
            for case let row as RecordRowItem in rows where section.keyText(row.values) == key {
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
        guard let column = section.columns.first(where: { $0.id == id }), let values = values(atRow: row) else { return "" }
        return section.text(of: values, column)
    }
    /// The list's line of the data row at `row`: its key and its label.
    func listText(row: Int) -> String {
        guard let values = values(atRow: row) else { return "" }
        return CodeRecordSection.line(key: section.keyDisplay(values), label: section.label(values))
    }
    /// The row view's cell at `row`, as the outline makes it.
    func cell(row: Int) -> NSTableCellView? {
        guard let item = table.item(atRow: row) else { return nil }
        return outlineView(table, viewFor: table.tableColumns.first, item: item) as? NSTableCellView
    }
    /// Follows the value of column `id` of the row at `row`, as a click on
    /// it in the details does: the first place it names.
    func click(row: Int, column id: String) {
        guard let values = values(atRow: row), let column = section.columns.first(where: { $0.id == id }) else { return }
        places(values, column).first?.1()
    }
    /// The selected rows' TSV, as Copy Row puts it on the pasteboard; a
    /// branch's own row adds nothing, its rows carry its value.
    func tsv(rows: IndexSet) -> String {
        rows.compactMap { values(atRow: $0) }.map { values in
            section.columns.map { section.text(of: values, $0) }.joined(separator: "\t")
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

    /// The record's words and order, apart from the drawing.
    private var section: CodeRecordSection { CodeRecordSection(profile: profile, record: record) }

    // MARK: - The list

    /// The branches the reader closes stay closed as the rows are shown anew.
    override func didClose(_ item: AnyObject) {
        if let group = item as? RecordGroupItem { collapsedGroups.insert(group.value) }
    }

    override func didOpen(_ item: AnyObject) {
        if let group = item as? RecordGroupItem { collapsedGroups.remove(group.value) }
    }

    /// The row's one mark, in the cell's marker slot: the `?` of an inferred
    /// row; otherwise a pin's direction — up for out, down for in.
    private func mark(_ row: [String: RecordValue]) -> (symbol: String, tip: String)? {
        guard CodeRecordSection.isInference(row) else { return nil }
        return ("circle.dashed", CodeRecordSection.inferenceToolTip(note: row["note"]?.string))
    }

    /// Whether the rows stand under branches.
    private var isGrouped: Bool { items.first is RecordGroupItem }

    /// Where a row's label starts: past the widest key and its tag.
    private var keyColumnWidth: CGFloat = 0

    private func measureKeys() {
        let mono = CodePaneView.navigatorCodeFont()
        let tagFont = NSFont.systemFont(ofSize: max(CodePaneView.navigatorSize - 2, 9), weight: .bold)
        keyColumnWidth = allRows.map { row -> CGFloat in
            var width = (section.keyDisplay(row) as NSString).size(withAttributes: [.font: mono]).width
            if let tag = section.tag(row) { width += (" " + tag as NSString).size(withAttributes: [.font: tagFont]).width }
            if mark(row) != nil { width += CodePaneView.navigatorSize + 4 }
            return width
        }.max().map { ($0 + 8).rounded(.up) } ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? RecordGroupItem { return groupCell(group, in: outlineView) }
        guard let values = (item as? RecordRowItem)?.values else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("record.row")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? RecordRowCell
            ?? RecordRowCell(identifier: identifier)
        let inference = CodeRecordSection.isInference(values)
        // An interrupt the firmware leaves off reads in grey.
        let off = record?.id == "irq_map" && values["enabled_by_firmware"] == .bool(false)
        let ink: NSColor = off ? .secondaryLabelColor : .labelColor
        func styled(_ font: NSFont) -> NSFont {
            inference ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
        }
        let body = styled(CodePaneView.navigatorFont())
        let mark = mark(values)
        let key = section.keyDisplay(values), tag = section.tag(values), label = section.label(values), tabStop = keyColumnWidth
        let net = record?.id == "gpio" ? values["net"]?.string.flatMap { $0.isEmpty ? nil : $0 } : nil
        // The line for a row on the selection's fill (`on`) or off it: on it
        // every colour — the tag's orange, the mark's grey — takes the
        // selection's text colour, as a function's name does.
        let draw: (Bool) -> NSAttributedString = { on in
        let ink = on ? NSColor.alternateSelectedControlTextColor : ink
        let line = NSMutableAttributedString(string: key, attributes: [
            .font: styled(CodePaneView.navigatorCodeFont()), .foregroundColor: ink
        ])
        if let tag {
            line.append(NSAttributedString(string: " " + tag, attributes: [
                .font: NSFont.systemFont(ofSize: max(CodePaneView.navigatorSize - 2, 9), weight: .bold),
                .foregroundColor: on ? ink : NSColor.systemOrange
            ]))
        }
        // The row's one mark stands after the key, in grey, as the Interfaces
        // tab writes an interface's marks after its name.
        if let mark, let image = NSImage(systemSymbolName: mark.symbol, accessibilityDescription: mark.tip)?
            .withSymbolConfiguration(.init(pointSize: CodePaneView.navigatorSize - 2, weight: .regular)
                .applying(.init(hierarchicalColor: on ? ink : .secondaryLabelColor))) {
            let attachment = NSTextAttachment()
            attachment.image = image
            let font = CodePaneView.navigatorFont()
            attachment.bounds = NSRect(x: 0, y: (font.capHeight - image.size.height) / 2,
                                       width: image.size.width, height: image.size.height)
            line.append(NSAttributedString(string: " "))
            line.append(NSAttributedString(attachment: attachment))
        }
        if !label.isEmpty {
            line.append(NSAttributedString(string: "\t" + label, attributes: [.font: body, .foregroundColor: ink]))
            // A pin's signal name, the board's, stands out from what it is.
            if let net, label.hasPrefix(net) {
                let start = line.length - (label as NSString).length
                line.addAttribute(.font, value: NSFontManager.shared.convert(body, toHaveTrait: .boldFontMask),
                                  range: NSRange(location: start, length: (net as NSString).length))
            }
        }
        // The labels start in one column, past the widest key and its mark.
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: tabStop)]
        paragraph.lineBreakMode = .byTruncatingTail
        line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
        return line
        }
        cell.showsDisclosure(isGrouped)
        cell.showsCalls(expandable: false, expanded: false)
        cell.indent = isGrouped ? CodeNavigatorCell.disclosureRoom - 2 : 0
        // A row under a branch carries its branch's mark; a list with no
        // branches, the record's letter.
        cell.show(line: draw, mark: isGrouped ? Self.groupMark(record) : Self.rowMark(record?.id), said: mark?.tip)
        // No pointer words that repeat the line: the note only, which the
        // line does not show, and on a marked row what the mark says.
        // A pin's line is net and label: its function is the pointer's.
        cell.toolTip = record?.id == "gpio"
            ? (values["function"]?.string ?? mark?.tip) : (mark?.tip ?? values["note"]?.string)
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
        case "ec_ram": (.bareSymbol("cpu.fill"), NSColor(name: nil) { appearance in
            // Dark green on a light list; the system's green on a dark one,
            // where a darker one would sink into the background.
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .systemGreen : NSColor(srgbRed: 0.10, green: 0.50, blue: 0.20, alpha: 1)
        })
        case "smbus_peers": (.letter("S"), .systemIndigo)
        case "gpio": (.letter("P"), .systemBrown)
        case "eflash_area": (.letter("V"), .systemGreen)
        default: nil
        }
    }

    /// A branch's mark: the record's own sign on its colour, as the
    /// Interfaces tab's headings carry theirs.
    static func groupMark(_ record: AnalysisProfile.Record?) -> (glyph: CodeNavigatorIcon.Glyph, color: NSColor)? {
        guard let symbol = record?.panel?.symbol, let color = rowMark(record?.id)?.color else { return nil }
        // A pin's branch reads I/O, as the trade writes it, not a plug.
        if record?.id == "gpio" { return (.letter("I/O"), color) }
        return (.symbol(symbol), color)
    }

    /// Opens or closes a branch, as the Interfaces tab's kinds do.


    // MARK: - The (i) popovers

    @objc private func legendTitleClicked() { showStatusInfo() }

    @objc private func statusInfoClicked() { showStatusInfo() }

    /// Shows the review's note on the record from the (i) after its status:
    /// what the rows cover, then — under a warning — what is not checked yet.
    /// The status is on the line the (i) stands in, and is not said again.
    func showStatusInfo() {
        guard storedScope != nil || storedNotChecked != nil else { return }
        shownPopoverText = [storedScope, storedNotChecked].compactMap { $0 }.joined(separator: "\n\n")
        let stack = ToolPanelPopover.stack()
        if let scope = storedScope { stack.addArrangedSubview(ToolPanelPopover.prose(scope)) }
        if let open = storedNotChecked {
            let mark = NSImageView()
            let config = NSImage.SymbolConfiguration(pointSize: ToolPanelPopover.size, weight: .semibold)
                .applying(.init(paletteColors: [.white, .systemOrange]))
            if let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                   accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                mark.image = image
                mark.widthAnchor.constraint(equalToConstant: image.size.width).isActive = true
            }
            let words = NSTextField(labelWithString: storedOpenHead == "Partial:" ? Self.partialTitle : Self.notCheckedTitle)
            words.font = .systemFont(ofSize: ToolPanelPopover.size, weight: .bold)
            let heading = NSStackView(views: [mark, words])
            heading.orientation = .horizontal
            heading.spacing = 4
            stack.addArrangedSubview(heading)
            stack.addArrangedSubview(ToolPanelPopover.prose(open))
        }
        let controller = NSViewController()
        controller.view = ToolPanelPopover.content(stack)
        guard statusInfo.window != nil else { return }
        ToolPanelPopover.show(popover, with: controller, relativeTo: statusInfo.bounds, of: statusInfo, edge: .maxY)
    }

    static var notCheckedTitle: String { L("Not checked:") }
    static var partialTitle: String { L("Partial:") }

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
        // From the (i) itself, where it stands after the branch's words; the
        // row's frame only when the button is not drawn.
        if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? RecordGroupCell,
           !cell.info.isHidden, cell.info.window != nil {
            showInfo(title: group.label, text: text, relativeTo: cell.info.bounds, of: cell.info, edge: .maxX)
        } else {
            showInfo(title: group.label, text: text, relativeTo: table.rect(ofRow: row), of: table, edge: .maxX)
        }
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

    override func selectionChanged() { showDetails() }

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
        shownDetailTitle = label.isEmpty ? section.keyDisplay(values) : "\(section.keyDisplay(values)) · \(label)"
        let titled = Set((record?.key ?? []).filter { $0 != record?.groupBy && $0 != "mode" })
        let shown = section.columns.filter { column in
            // The branch the row stands in says its value already.
            !(column.id == "label" || column.id == record?.groupBy || titled.contains(column.id))
        }
        for column in shown where !CodeRecordSection.isLink(column) {
            let text = section.text(of: values, column).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != label else { continue }
            let name = CodeRecordSection.columnTitle(column.title)
            if column.id == section.mainColumn?.id { shownDetailSentence = text }
            if column.kind == .rows {
                // A small table of its own, under the rows, as a panel adds
                // what is its own after the list.
                shownDetails.append((name, text))
                let heading = NSTextField(labelWithString: name)
                heading.font = ToolPanelFont.body()
                heading.textColor = .secondaryLabelColor
                extras += [heading, commandsGrid(values[column.id], column: column)]
            } else {
                add(name, plain(column.kind == .enum ? CodeRecordSection.valueTitle(text) : text))
            }
        }
        for column in shown where CodeRecordSection.isLink(column) {
            let places = places(values, column)
            guard !places.isEmpty else { continue }
            add(CodeRecordSection.columnTitle(column.title), linked(places, separator: ", "))
        }
        for (name, places) in backReferences(values) where !places.isEmpty {
            add(name, linked(places, separator: "\n"))
        }
        let inference = CodeRecordSection.isInference(values)
        add(Self.confidenceTitle, plain(inference ? Self.inferenceTitle : Self.establishedTitle))
        if let note = values["note"]?.string, !note.isEmpty { add(Self.noteTitle, plain(note)) }

        let list = details.showRows(subject: section.keyText(values), title: shownDetailTitle, fields: fields)
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
        let key = section.keyText(row)
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
                let ordered = rows.sorted(by: section.of(other).keyOrder)
                let name = other.id == "host_commands" ? Self.usedByCommandsTitle
                    : other.id == "eflash_area" ? Self.flashAreasTitle
                    : CodeRecordSection.title(of: other.id, fallback: other.title)
                let places: [(String, () -> Void)] = ordered.map { target in
                    let words = section.of(other).line(target)
                    let targetKey = ModuleRecords.rowKey(target, key: other.key)
                    return (words, { [weak self] in self?.showRef(other.id, key: targetKey) })
                }
                found.append((name, places))
            }
        }
        return found
    }

    /// An SMBus device's commands: a small table of command, R/W, size and
    /// meaning.
    private func commandsGrid(_ value: RecordValue?, column: AnalysisProfile.Column) -> NSView {
        let inner = column.columns ?? []
        let rows: [[NSView]] = (value?.array ?? []).map { item in
            let object = item.object ?? [:]
            return inner.map { part in
                let text = object[part.id].map { CodeRecordSection.text($0, kind: part.kind, column: part, profile: profile) } ?? ""
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
        let rows = section.filtered(allRows, by: query)
        if let groupBy = record?.groupBy, let groupColumn = record?.column(groupBy) {
            let groups = CodeRecordSection.groups(of: rows, by: groupColumn, keepEmpty: query.isEmpty,
                                     notes: records[recordID ?? ""]?.branchNotes ?? [:])
            items = groups.map(RecordGroupItem.init)
            shownRows = groups.flatMap(\.rows)
        } else {
            items = rows.map(RecordRowItem.init)
            shownRows = rows
        }
        // The row chosen before stays chosen while the filter still shows it.
        let chosen = table.selectedRowIndexes.count == 1
            ? values(atRow: table.selectedRowIndexes.first!).map(section.keyText) : nil
        table.reloadData()
        for case let group as RecordGroupItem in items where !collapsedGroups.contains(group.value) {
            table.expandItem(group)
        }
        if let chosen, let row = tableRow(key: chosen) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        let empty = allRows.isEmpty
        tableScroll.isHidden = shownRows.isEmpty
        // No row shown, no details pane: nothing is there to choose.
        splitter.isHidden = shownRows.isEmpty
        filterBar.isHidden = empty
        emptyLabel.isHidden = !shownRows.isEmpty || (empty && records[recordID ?? ""]?.status == AnalysisProfile.RecordStatus.none)
        emptyLabel.stringValue = empty ? Self.emptyText : L("Nothing matches the search.")
        showDetails()
    }

    // MARK: - Places

    /// Where a value leads: an address, or a row of another record.
    private func places(_ row: [String: RecordValue], _ column: AnalysisProfile.Column) -> [(String, () -> Void)] {
        guard let value = row[column.id] else { return [] }
        let kind = column.kind == .list ? (column.of ?? .text) : column.kind
        let values = column.kind == .list ? (value.array ?? []) : [value]
        switch kind {
        case .code, .data:
            let addresses = values.compactMap { CodeRecordSection.number($0).map { CodeAddress(UInt64($0)) } }
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
                return (CodeRecordSection.refText(item, column: column, profile: profile), { [weak self] in self?.showRef(target, key: key) })
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
        if !shownRows.contains(where: { section.keyText($0) == key }), !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            applyFilter()
        }
        for case let group as RecordGroupItem in items
        where group.children.contains(where: { section.keyText($0.values) == key }) && !table.isItemExpanded(group) {
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
}

/// A branch of a grouped record: a value of its `groupBy` column.
final class RecordGroupItem: CodeNavigatorTreeNode {
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
    var treeChildren: [AnyObject] { children }

    convenience init(_ group: CodeRecordSection.Group) {
        self.init(value: group.value, title: group.title, label: group.label, summary: group.summary,
                  note: group.note, children: group.rows.map(RecordRowItem.init))
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

    private var draw: ((Bool) -> NSAttributedString)?

    func show(line: @escaping (Bool) -> NSAttributedString, mark: (glyph: CodeNavigatorIcon.Glyph, color: NSColor)?,
              said: String?) {
        showsMark(mark, named: "record.row")
        draw = line
        shownMark = said
        redraw()
    }

    /// On the selection's fill the line is drawn again in its colour.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { redraw() } }
    }

    private func redraw() {
        textField?.attributedStringValue = draw?(backgroundStyle == .emphasized) ?? NSAttributedString()
    }
}
