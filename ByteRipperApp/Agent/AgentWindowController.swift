import Cocoa
import AgentKit
import ALSplitView
import AppPalette
import HelpBook
import HelpUI
import Localization
import ToolModuleKit

/// Window ▸ Agent: whether the agent service is running, who is connected,
/// and every call an agent has made, newest at the bottom
/// (`Design/AGENT_PLAN.md`, "Its own window, not the tool panel").
///
/// A window of its own rather than a panel in the tab, because the panel is
/// where the tree the conversation is about stays on screen. One for the app,
/// like Settings: the service is the app's, not a tab's.
// help: window.agent
@MainActor
final class AgentWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    /// The service shown. The app's own unless a test hands it another.
    var service: AgentService? {
        didSet { refresh() }
    }
    /// Opens Settings on the Agent tab.
    var showSettings: () -> Void = {}

    private let statusLabel = NSTextField(labelWithString: "")
    private let pages = NSSegmentedControl()
    private let table = NSTableView()
    private let logScroll = NSScrollView()
    /// The log above, the selected call's details below: the table cuts the
    /// arguments to a column, and an agent's arguments are what a reader
    /// checks it against.
    private let logSplit = ALSplitView()
    /// The details in their pane, and the large view they open into — Space
    /// on the log or the button in the list's corner, as a tool panel's do.
    private let detailPane = ToolDetailPane()
    private var details: ToolDetailScroll { detailPane.detail }
    private let marks = AgentMarksTable()
    private let marksScroll = NSScrollView()
    private let findings = AgentFindingsTable()
    private let findingsScroll = NSScrollView()
    private let tools = AgentToolsPage()
    private let clearButton = NSButton(title: "", target: nil, action: nil)
    private let removeButton = NSButton(title: "", target: nil, action: nil)
    private let settingsButton = NSButton(title: "", target: nil, action: nil)
    /// Whether the log scrolls to each new request as it comes in.
    private let followButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    /// Where the choice is kept, so the window opens the way it was left.
    static let followKey = "AgentLogFollowsNewRequests"
    private var observer: NSObjectProtocol?
    private var zoomObserver: NSObjectProtocol?
    /// The size the tables were last drawn at, so a zoom scales their
    /// columns by what it changed.
    private var drawnSize = ToolPanelFont.size
    private var rows: [AgentCallRecord] = []

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(service: AgentService?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 360),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = L("Agent")
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AgentWindow")
        window.minSize = NSSize(width: 480, height: 220)
        self.service = service
        super.init(window: window)
        buildContent()
        observer = NotificationCenter.default.addObserver(
            forName: AgentService.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // The tables are drawn as the tool panels' are, and follow the same
        // zoom.
        zoomObserver = ToolPanelFont.observeZoom { [weak self] in self?.zoomChanged() }
        refresh()
    }

    private func zoomChanged() {
        let ratio = ToolPanelFont.size / drawnSize
        drawnSize = ToolPanelFont.size
        for table in [table, marks.table, findings.table, tools.table] {
            ToolPanelTable.scaleColumnWidths(of: table, by: ratio)
            AgentTableStyle.apply(to: table)
            table.reloadData()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
    }

    // MARK: - Content

    private enum Column: String, CaseIterable {
        case time, tool, arguments, duration, size, result

        var title: String {
            switch self {
            case .time: return L("Time")
            case .tool: return L("Tool")
            case .arguments: return L("Arguments")
            case .duration: return L("Took")
            case .size: return L("Answer")
            case .result: return L("Result")
            }
        }

        var width: CGFloat {
            switch self {
            case .time: return 64
            case .tool: return 90
            case .arguments: return 250
            case .duration: return 60
            case .size: return 64
            case .result: return 150
            }
        }
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingTail

        // The two things the window lists: what the agent asked, and what it
        // marked. One at a time, the way Activity Monitor's tabs are — both
        // are long lists that want the whole height.
        pages.segmentCount = 4
        pages.setLabel(L("Log"), forSegment: 0)
        pages.setLabel(L("Marks"), forSegment: 1)
        pages.setLabel(L("Findings"), forSegment: 2)
        pages.setLabel(L("Tools"), forSegment: 3)
        pages.trackingMode = .selectOne
        pages.selectedSegment = 0
        pages.target = self
        pages.action = #selector(pageChanged)

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = ToolPanelFont.scaled(column.width)
            // Every column gives way with the window, in proportion: with the
            // text at the panels' size there is less room to spare, and one
            // column left to take all the shortfall was squeezed to nothing.
            tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
            tableColumn.minWidth = ToolPanelFont.scaled(36)
            table.addTableColumn(tableColumn)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        AgentTableStyle.apply(to: table)
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        logScroll.documentView = table
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder

        details.borderType = .bezelBorder
        details.showPlaceholder(L("Select a request to see all of it."))
        logSplit.isVertical = false
        logSplit.dividerThickness = 1
        logSplit.addPane(logScroll)
        logSplit.addPane(detailPane)
        detailPane.attach(to: table)
        logSplit.setPaneLayout(.fill, at: 0)
        logSplit.setPaneLayout(.fixed(170), at: 1)

        marks.build()
        marks.onShow = { [weak self] id in self?.service?.markTools.show(id) }
        marks.onSelectionChanged = { [weak self] in self?.refreshButtons() }
        marksScroll.documentView = marks.table
        marksScroll.hasVerticalScroller = true
        marksScroll.borderType = .bezelBorder
        marksScroll.isHidden = true

        findings.build()
        findings.onShow = { [weak self] finding in self?.service?.dumpTools.show(finding) }
        findings.onSelectionChanged = { [weak self] in self?.refreshButtons() }
        findingsScroll.documentView = findings.table
        findingsScroll.hasVerticalScroller = true
        findingsScroll.borderType = .bezelBorder
        findingsScroll.isHidden = true

        tools.build()
        tools.onSelectionChanged = { [weak self] in self?.refreshButtons() }
        tools.split.isHidden = true

        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearPage)

        removeButton.title = L("Remove Mark")
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeMarks)
        removeButton.isHidden = true

        // help: window.agent.follow
        followButton.title = L("Follow New Requests")
        ControlHelp.describe(followButton, name: L("Follow New Requests"),
                             tooltip: L("Scroll the log to each new request as it arrives"))
        followButton.state = Self.follows ? .on : .off
        followButton.target = self
        followButton.action = #selector(followChanged)

        settingsButton.title = L("Agent Settings…")
        settingsButton.bezelStyle = .rounded
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)

        let help = HelpButton.standard(for: .topic(.agent))

        for view in [statusLabel, pages, logSplit, marksScroll, findingsScroll, tools.split, clearButton, removeButton,
                     followButton, settingsButton, help] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: help.leadingAnchor, constant: -8),

            help.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            help.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            pages.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            pages.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            logSplit.topAnchor.constraint(equalTo: pages.bottomAnchor, constant: 8),
            logSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            logSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            marksScroll.topAnchor.constraint(equalTo: logSplit.topAnchor),
            marksScroll.leadingAnchor.constraint(equalTo: logSplit.leadingAnchor),
            marksScroll.trailingAnchor.constraint(equalTo: logSplit.trailingAnchor),
            marksScroll.bottomAnchor.constraint(equalTo: logSplit.bottomAnchor),

            findingsScroll.topAnchor.constraint(equalTo: logSplit.topAnchor),
            findingsScroll.leadingAnchor.constraint(equalTo: logSplit.leadingAnchor),
            findingsScroll.trailingAnchor.constraint(equalTo: logSplit.trailingAnchor),
            findingsScroll.bottomAnchor.constraint(equalTo: logSplit.bottomAnchor),

            tools.split.topAnchor.constraint(equalTo: logSplit.topAnchor),
            tools.split.leadingAnchor.constraint(equalTo: logSplit.leadingAnchor),
            tools.split.trailingAnchor.constraint(equalTo: logSplit.trailingAnchor),
            tools.split.bottomAnchor.constraint(equalTo: logSplit.bottomAnchor),

            removeButton.centerYAnchor.constraint(equalTo: clearButton.centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: clearButton.trailingAnchor, constant: 8),

            followButton.centerYAnchor.constraint(equalTo: clearButton.centerYAnchor),
            followButton.leadingAnchor.constraint(equalTo: clearButton.trailingAnchor, constant: 12),

            clearButton.topAnchor.constraint(equalTo: logSplit.bottomAnchor, constant: 12),
            clearButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            clearButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            settingsButton.centerYAnchor.constraint(equalTo: clearButton.centerYAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
        ])
    }

    /// Reads the service's state and log into the window. New calls are
    /// added at the bottom. The selection stays with the calls it was on —
    /// found by identity, since the log drops its oldest rows — and the view
    /// stays where the reader left it, unless Follow New Requests is on and a
    /// call came in: then it goes to the newest.
    func refresh() {
        statusLabel.stringValue = AgentSettingsViewController.statusText(of: service)
        let log = service?.log ?? []
        let selected = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil })
        let arrived = log.last?.id != rows.last?.id && !log.isEmpty
        let origin = logScroll.contentView.bounds.origin
        rows = log
        table.reloadData()
        let reselected = IndexSet(rows.indices.filter { selected.contains(rows[$0].id) })
        if reselected != table.selectedRowIndexes {
            table.selectRowIndexes(reselected, byExtendingSelection: false)
        }
        if arrived, Self.follows {
            table.scrollRowToVisible(rows.count - 1)
        } else {
            logScroll.contentView.scroll(to: origin)
            logScroll.reflectScrolledClipView(logScroll.contentView)
        }
        showDetails()
        marks.show(service?.markTools.all() ?? [])
        findings.show(service?.dumpTools.findings ?? [])
        tools.show(service?.catalogue ?? [], stats: service?.toolStats ?? [:])
        refreshButtons()
    }

    private enum Page: Int { case log, marks, findings, tools }
    private var page: Page { Page(rawValue: pages.selectedSegment) ?? .log }
    private var showsMarks: Bool { page == .marks }

    private func refreshButtons() {
        switch page {
        case .log:
            clearButton.title = L("Clear Log")
            clearButton.isEnabled = !rows.isEmpty
            removeButton.isHidden = true
            followButton.isHidden = false
        case .marks:
            clearButton.title = L("Clear Marks")
            clearButton.isEnabled = !marks.isEmpty
            removeButton.title = L("Remove Mark")
            removeButton.isHidden = false
            removeButton.isEnabled = !marks.selectedIDs.isEmpty
            followButton.isHidden = true
        case .findings:
            clearButton.title = L("Clear Findings")
            clearButton.isEnabled = !findings.isEmpty
            removeButton.isHidden = true
            followButton.isHidden = true
        case .tools:
            clearButton.title = L("Reset Statistics")
            clearButton.isEnabled = tools.hasStats
            removeButton.isHidden = true
            followButton.isHidden = true
        }
    }

    @objc private func pageChanged() {
        logSplit.isHidden = page != .log
        marksScroll.isHidden = page != .marks
        findingsScroll.isHidden = page != .findings
        tools.split.isHidden = page != .tools
        refreshButtons()
        focusList()
    }

    /// The table of the page in view.
    var shownList: NSTableView {
        switch page {
        case .log: return table
        case .marks: return marks.table
        case .findings: return findings.table
        case .tools: return tools.table
        }
    }

    /// Puts the keyboard on the page's table, so the arrows walk its rows and
    /// Space opens the details — when the window is shown and when a page is
    /// picked.
    func focusList() {
        window?.makeFirstResponder(shownList)
    }

    /// Shows the Findings list, for tests.
    func showFindings() {
        pages.selectedSegment = 2
        pageChanged()
    }

    /// Shows the Tools list, for tests.
    func showTools() {
        pages.selectedSegment = 3
        pageChanged()
    }

    /// Shows the Marks list, for the menu bar and the tests.
    func showMarks() {
        pages.selectedSegment = 1
        pageChanged()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let column = Column(rawValue: id.rawValue) else { return nil }
        let cell = AgentTableStyle.cell(in: tableView, id: id, owner: self, code: column == .arguments)
        let field = cell.textField!
        field.stringValue = Self.text(of: rows[row], column)
        field.textColor = column == .result && Self.isProblem(rows[row]) ? SemanticColors.bad : .labelColor
        cell.toolTip = column == .arguments || column == .result ? field.stringValue : nil
        return cell
    }

    private static func text(of record: AgentCallRecord, _ column: Column) -> String {
        switch column {
        case .time:
            return timeFormatter.string(from: record.finished)
        case .tool:
            return record.tool
        case .arguments:
            // The arguments as the agent wrote them: they are the agent's
            // words, and what a reader checks the agent against.
            return record.arguments == .object([:]) ? "" : record.arguments.jsonText
        case .duration:
            let milliseconds = Double(record.duration.components.seconds) * 1000
                + Double(record.duration.components.attoseconds) / 1e15
            return milliseconds < 1000
                ? L("%1$@ ms", Int(milliseconds.rounded()))
                : L("%1$@ s", String(format: "%.1f", milliseconds / 1000))
        case .size:
            return ByteCountFormatter.string(fromByteCount: Int64(record.answerBytes), countStyle: .memory)
        case .result:
            switch record.outcome {
            case .answered: return L("Answered")
            case .toolError(let message): return message
            case .overBound: return L("Too long, not sent")
            case .cancelled: return L("Cancelled")
            }
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showDetails()
    }

    // MARK: - Details

    /// The call in focus — the row clicked last, or the one selected — with
    /// every field whole: the result's full sentence, and the arguments as the
    /// agent sent them, the whole JSON laid out with one member to a line.
    // help: window.agent.details
    private func showDetails() {
        let row = table.clickedRow >= 0 && table.isRowSelected(table.clickedRow) ? table.clickedRow : table.selectedRow
        guard row >= 0, row < rows.count else {
            details.showPlaceholder(L("Select a request to see all of it."))
            return
        }
        let record = rows[row]
        details.prepareForRows(subject: "\(row)")
        let title = NSTextField(labelWithString: record.tool)
        title.font = ToolPanelFont.title()
        title.translatesAutoresizingMaskIntoConstraints = false
        details.content.addArrangedSubview(title)
        let list = ToolFieldList(fields: Self.detailFields(of: record).map { field in
            let value = NSAttributedString(string: field.value, attributes: [
                .font: ToolPanelFont.body(),
                .foregroundColor: field.isProblem ? SemanticColors.bad : NSColor.labelColor
            ])
            return .init(label: field.label, value: value)
        })
        details.content.addArrangedSubview(list)
        list.widthAnchor.constraint(equalTo: details.content.widthAnchor).isActive = true

        let heading = NSTextField(labelWithString: L("Arguments"))
        heading.font = ToolPanelFont.title()
        heading.translatesAutoresizingMaskIntoConstraints = false
        details.content.setCustomSpacing(10, after: list)
        details.content.addArrangedSubview(heading)
        let json = ToolWrappingLabel(string: Self.argumentsText(of: record))
        json.font = .monospacedSystemFont(ofSize: ToolPanelFont.body().pointSize, weight: .regular)
        json.lineBreakMode = .byCharWrapping
        json.isSelectable = true
        details.content.addArrangedSubview(json)
        json.widthAnchor.constraint(equalTo: details.content.widthAnchor).isActive = true
    }

    /// The arguments as the agent sent them, laid out: one member to a line,
    /// nested ones indented, keys sorted.
    static func argumentsText(of record: AgentCallRecord) -> String {
        record.arguments.prettyText
    }

    struct DetailField: Equatable {
        var label: String
        var value: String
        var isProblem = false
    }

    /// The rows the details list shows for `record`, above its arguments.
    static func detailFields(of record: AgentCallRecord) -> [DetailField] {
        var fields = [
            DetailField(label: L("Time"), value: DateFormatter.localizedString(
                from: record.finished, dateStyle: .none, timeStyle: .medium)),
            DetailField(label: L("Took"), value: text(of: record, .duration)),
            DetailField(label: L("Answer"), value: L("%1$@ bytes", record.answerBytes)),
            DetailField(label: L("Result"), value: text(of: record, .result), isProblem: isProblem(record))
        ]
        if let client = record.client {
            fields.insert(DetailField(label: L("Client"), value: client), at: 1)
        }
        return fields
    }

    private static func isProblem(_ record: AgentCallRecord) -> Bool {
        if case .answered = record.outcome { return false }
        return true
    }

    // MARK: - Actions

    @objc private func clearPage() {
        switch page {
        case .log: service?.clearLog()
        case .marks: service?.markTools.remove { _ in true }
        case .findings: service?.dumpTools.clearFindings()
        case .tools: service?.resetToolStats()
        }
    }

    @objc private func removeMarks() {
        let chosen = Set(marks.selectedIDs)
        service?.markTools.remove { chosen.contains($0.mark.id) }
    }

    @objc private func openSettings() {
        showSettings()
    }

    /// Whether the log follows new requests: on until the person turns it off.
    static var follows: Bool {
        get { AppDefaults.store.object(forKey: followKey) as? Bool ?? true }
        set { AppDefaults.store.set(newValue, forKey: followKey) }
    }

    @objc private func followChanged() {
        Self.follows = followButton.state == .on
        if Self.follows, !rows.isEmpty { table.scrollRowToVisible(rows.count - 1) }
    }

    /// Turns Follow New Requests on or off, as a click does, for tests.
    func setFollowsForTesting(_ on: Bool) {
        followButton.state = on ? .on : .off
        followChanged()
    }

    /// Scrolls the log to its first row, for tests.
    func logScrollToTopForTesting() {
        table.scrollRowToVisible(0)
    }

    /// The log's selected rows and the rows on screen, for tests.
    var logSelection: IndexSet { table.selectedRowIndexes }
    var logVisibleRows: Range<Int> {
        let visible = table.rows(in: table.visibleRect)
        return visible.location..<(visible.location + visible.length)
    }

    /// Selects a row of the log, as a click does, for tests.
    func selectLogRow(_ row: Int) {
        table.selectRowIndexes([row], byExtendingSelection: false)
    }

    /// The details list on screen: its rows' names and values, for tests.
    var shownDetails: [(label: String, value: String)] {
        details.content.arrangedSubviews.compactMap { $0 as? ToolFieldList }.flatMap(\.rows)
            .map { ($0.label, $0.valueText) }
    }

    /// The arguments' JSON as the details show it, for tests.
    var shownArguments: String? {
        details.content.arrangedSubviews.compactMap { $0 as? ToolWrappingLabel }.first?.stringValue
    }

    /// The details' pane, whose large view the tests open.
    var detailsPane: ToolDetailPane { detailPane }

    /// The rows' texts, for tests.
    func shownText(row: Int, column: String) -> String? {
        guard row < rows.count, let column = Column(rawValue: column) else { return nil }
        return Self.text(of: rows[row], column)
    }

    var statusText: String { statusLabel.stringValue }

    /// The Tools page, for tests.
    var toolsPage: AgentToolsPage { tools }

    /// The marks list, for tests.
    var marksList: AgentMarksTable { marks }
    /// The findings list, for tests.
    var findingsList: AgentFindingsTable { findings }
}

/// The Marks page of the Agent window: every mark an agent left, in every
/// open document, with what it is about. A double-click shows the bytes.
@MainActor
final class AgentMarksTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    var onShow: (String) -> Void = { _ in }
    var onSelectionChanged: () -> Void = {}
    private(set) var rows: [AgentMarkTools.Located] = []

    private enum Column: String, CaseIterable {
        case id, label, document, range, note

        var title: String {
            switch self {
            case .id: return L("Mark")
            case .label: return L("Label")
            case .document: return L("File")
            case .range: return L("Bytes")
            case .note: return L("Note")
            }
        }

        var width: CGFloat {
            switch self {
            case .id: return 44
            case .label: return 150
            case .document: return 110
            case .range: return 150
            case .note: return 340
            }
        }
    }

    func build() {
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = ToolPanelFont.scaled(column.width)
            // Every column gives way with the window, in proportion: with the
            // text at the panels' size there is less room to spare, and one
            // column left to take all the shortfall was squeezed to nothing.
            tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
            tableColumn.minWidth = ToolPanelFont.scaled(36)
            table.addTableColumn(tableColumn)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        AgentTableStyle.apply(to: table)
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
    }

    func show(_ marks: [AgentMarkTools.Located]) {
        let chosen = Set(selectedIDs)
        rows = marks
        table.reloadData()
        table.selectRowIndexes(IndexSet(rows.indices.filter { chosen.contains(rows[$0].mark.id) }),
                               byExtendingSelection: false)
    }

    var isEmpty: Bool { rows.isEmpty }
    var selectedIDs: [String] { table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].mark.id : nil } }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let column = Column(rawValue: id.rawValue) else { return nil }
        let cell = AgentTableStyle.cell(in: tableView, id: id, owner: self, digits: column == .range || column == .id)
        cell.textField?.stringValue = text(row: row, column)
        cell.toolTip = column == .note ? cell.textField?.stringValue : nil
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChanged()
    }

    private func text(row: Int, _ column: Column) -> String {
        let located = rows[row]
        switch column {
        case .id: return located.mark.id
        case .label: return located.mark.label
        case .document: return located.place.pane.status.fileName
        case .range:
            let range = located.mark.range
            return String(format: "0x%llX–0x%llX", range.lowerBound, range.upperBound)
        case .note:
            // The marks this one is about follow the note, each by its id and
            // label, so the pair reads without looking the other row up.
            let labels = Dictionary(rows.map { ($0.mark.id, $0.mark.label) }, uniquingKeysWith: { first, _ in first })
            return [located.mark.note, located.mark.relations(labels: labels)]
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        onShow(rows[row].mark.id)
    }

    /// A row's text, for tests.
    func shownText(row: Int, column: String) -> String? {
        guard row < rows.count, let column = Column(rawValue: column) else { return nil }
        return text(row: row, column)
    }
}

/// The Findings page of the Agent window: what an agent found, file by file,
/// each a line to check. A double-click opens the file at the place — the tab
/// that has it, or a new one.
@MainActor
final class AgentFindingsTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    var onShow: (AgentFinding) -> Void = { _ in }
    var onSelectionChanged: () -> Void = {}
    private(set) var rows: [AgentFinding] = []

    private enum Column: String, CaseIterable {
        case id, text, file, place

        var title: String {
            switch self {
            case .id: return L("Finding")
            case .text: return L("What was found")
            case .file: return L("File")
            case .place: return L("Where")
            }
        }

        var width: CGFloat {
            switch self {
            case .id: return 50
            case .text: return 330
            case .file: return 140
            case .place: return 150
            }
        }
    }

    func build() {
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = ToolPanelFont.scaled(column.width)
            // Every column gives way with the window, in proportion: with the
            // text at the panels' size there is less room to spare, and one
            // column left to take all the shortfall was squeezed to nothing.
            tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
            tableColumn.minWidth = ToolPanelFont.scaled(36)
            table.addTableColumn(tableColumn)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        AgentTableStyle.apply(to: table)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
    }

    func show(_ findings: [AgentFinding]) {
        rows = findings
        table.reloadData()
    }

    var isEmpty: Bool { rows.isEmpty }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let column = Column(rawValue: id.rawValue) else { return nil }
        let cell = AgentTableStyle.cell(in: tableView, id: id, owner: self, digits: column == .place || column == .id)
        cell.textField?.stringValue = text(row: row, column)
        cell.toolTip = column == .text || column == .file
            ? (column == .file ? rows[row].url.path : cell.textField?.stringValue) : nil
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChanged()
    }

    private func text(row: Int, _ column: Column) -> String {
        let finding = rows[row]
        switch column {
        case .id: return finding.id
        case .text: return finding.text
        case .file: return finding.url.lastPathComponent
        case .place:
            var parts: [String] = []
            if let range = finding.range {
                parts.append(range.isEmpty ? String(format: "0x%llX", range.lowerBound)
                             : String(format: "0x%llX–0x%llX", range.lowerBound, range.upperBound))
            }
            if let node = finding.node { parts.append(L("node %1$@", node)) }
            return parts.joined(separator: " · ")
        }
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        onShow(rows[row])
    }

    /// A row's text, for tests.
    func shownText(row: Int, column: String) -> String? {
        guard row < rows.count, let column = Column(rawValue: column) else { return nil }
        return text(row: row, column)
    }
}

/// The Agent window's tables drawn as the tool panels' are
/// (`ToolPanelTable`): their font and row height, the text centred in its row,
/// the header in the same type — so a log read beside a panel reads as one
/// with it.
@MainActor
enum AgentTableStyle {
    static func apply(to table: NSTableView) {
        ToolPanelTable.apply(to: table)
    }

    /// A cell from the pool or a new one, its text in the panels' body font —
    /// in digits of one width for addresses and ids (`digits`), in a
    /// monospaced face for JSON (`code`).
    static func cell(in tableView: NSTableView, id: NSUserInterfaceItemIdentifier, owner: Any?,
                     digits: Bool = false, code: Bool = false) -> NSTableCellView {
        let cell = tableView.makeView(withIdentifier: id, owner: owner) as? NSTableCellView
            ?? ToolPanelTable.makeCell(identifier: id)
        cell.textField?.font = code ? .monospacedSystemFont(ofSize: ToolPanelFont.size, weight: .regular)
            : digits ? ToolPanelFont.monospacedDigits() : ToolPanelFont.body()
        return cell
    }
}
