import Cocoa
import AgentKit
import AppPalette
import HelpBook
import HelpUI
import Localization

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
    private let marks = AgentMarksTable()
    private let marksScroll = NSScrollView()
    private let findings = AgentFindingsTable()
    private let findingsScroll = NSScrollView()
    private let clearButton = NSButton(title: "", target: nil, action: nil)
    private let removeButton = NSButton(title: "", target: nil, action: nil)
    private let settingsButton = NSButton(title: "", target: nil, action: nil)
    private var observer: NSObjectProtocol?
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
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
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
        pages.segmentCount = 3
        pages.setLabel(L("Log"), forSegment: 0)
        pages.setLabel(L("Marks"), forSegment: 1)
        pages.setLabel(L("Findings"), forSegment: 2)
        pages.trackingMode = .selectOne
        pages.selectedSegment = 0
        pages.target = self
        pages.action = #selector(pageChanged)

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.resizingMask = column == .arguments ? .autoresizingMask : .userResizingMask
            table.addTableColumn(tableColumn)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        logScroll.documentView = table
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder

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

        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearPage)

        removeButton.title = L("Remove Mark")
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeMarks)
        removeButton.isHidden = true

        settingsButton.title = L("Agent Settings…")
        settingsButton.bezelStyle = .rounded
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)

        let help = HelpButton.standard(for: .topic(.agent))

        for view in [statusLabel, pages, logScroll, marksScroll, findingsScroll, clearButton, removeButton,
                     settingsButton, help] {
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

            logScroll.topAnchor.constraint(equalTo: pages.bottomAnchor, constant: 8),
            logScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            logScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            marksScroll.topAnchor.constraint(equalTo: logScroll.topAnchor),
            marksScroll.leadingAnchor.constraint(equalTo: logScroll.leadingAnchor),
            marksScroll.trailingAnchor.constraint(equalTo: logScroll.trailingAnchor),
            marksScroll.bottomAnchor.constraint(equalTo: logScroll.bottomAnchor),

            findingsScroll.topAnchor.constraint(equalTo: logScroll.topAnchor),
            findingsScroll.leadingAnchor.constraint(equalTo: logScroll.leadingAnchor),
            findingsScroll.trailingAnchor.constraint(equalTo: logScroll.trailingAnchor),
            findingsScroll.bottomAnchor.constraint(equalTo: logScroll.bottomAnchor),

            removeButton.centerYAnchor.constraint(equalTo: clearButton.centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: clearButton.trailingAnchor, constant: 8),

            clearButton.topAnchor.constraint(equalTo: logScroll.bottomAnchor, constant: 12),
            clearButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            clearButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            settingsButton.centerYAnchor.constraint(equalTo: clearButton.centerYAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
        ])
    }

    /// Reads the service's state and log into the window. New calls are
    /// added at the bottom, and the table follows them while it is scrolled
    /// to the end.
    func refresh() {
        statusLabel.stringValue = AgentSettingsViewController.statusText(of: service)
        let log = service?.log ?? []
        let followed = rows.isEmpty || table.rows(in: table.visibleRect).upperBound >= rows.count
        rows = log
        table.reloadData()
        if followed, !rows.isEmpty { table.scrollRowToVisible(rows.count - 1) }
        marks.show(service?.markTools.all() ?? [])
        findings.show(service?.dumpTools.findings ?? [])
        refreshButtons()
    }

    private enum Page: Int { case log, marks, findings }
    private var page: Page { Page(rawValue: pages.selectedSegment) ?? .log }
    private var showsMarks: Bool { page == .marks }

    private func refreshButtons() {
        switch page {
        case .log:
            clearButton.title = L("Clear Log")
            clearButton.isEnabled = !rows.isEmpty
            removeButton.isHidden = true
        case .marks:
            clearButton.title = L("Clear Marks")
            clearButton.isEnabled = !marks.isEmpty
            removeButton.title = L("Remove Mark")
            removeButton.isHidden = false
            removeButton.isEnabled = !marks.selectedIDs.isEmpty
        case .findings:
            clearButton.title = L("Clear Findings")
            clearButton.isEnabled = !findings.isEmpty
            removeButton.isHidden = true
        }
    }

    @objc private func pageChanged() {
        logScroll.isHidden = page != .log
        marksScroll.isHidden = page != .marks
        findingsScroll.isHidden = page != .findings
        refreshButtons()
    }

    /// Shows the Findings list, for tests.
    func showFindings() {
        pages.selectedSegment = 2
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
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField)
            ?? {
                let field = NSTextField(labelWithString: "")
                field.identifier = id
                field.lineBreakMode = .byTruncatingTail
                field.font = column == .arguments
                    ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
                return field
            }()
        cell.stringValue = Self.text(of: rows[row], column)
        cell.textColor = column == .result && Self.isProblem(rows[row]) ? SemanticColors.bad : .labelColor
        cell.toolTip = column == .arguments || column == .result ? cell.stringValue : nil
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
        }
    }

    @objc private func removeMarks() {
        let chosen = Set(marks.selectedIDs)
        service?.markTools.remove { chosen.contains($0.mark.id) }
    }

    @objc private func openSettings() {
        showSettings()
    }

    /// The rows' texts, for tests.
    func shownText(row: Int, column: String) -> String? {
        guard row < rows.count, let column = Column(rawValue: column) else { return nil }
        return Self.text(of: rows[row], column)
    }

    var statusText: String { statusLabel.stringValue }

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
        case id, label, document, range, note, related

        var title: String {
            switch self {
            case .id: return L("Mark")
            case .label: return L("Label")
            case .document: return L("File")
            case .range: return L("Bytes")
            case .note: return L("Note")
            case .related: return L("About")
            }
        }

        var width: CGFloat {
            switch self {
            case .id: return 44
            case .label: return 150
            case .document: return 110
            case .range: return 150
            case .note: return 220
            case .related: return 120
            }
        }
    }

    func build() {
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.resizingMask = column == .note ? .autoresizingMask : .userResizingMask
            table.addTableColumn(tableColumn)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
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
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byTruncatingTail
            field.font = column == .range || column == .id
                ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
            return field
        }()
        cell.stringValue = text(row: row, column)
        cell.toolTip = column == .note || column == .related ? cell.stringValue : nil
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
        case .note: return located.mark.note
        case .related:
            // Each end of a relation by its id and label, so the pair reads
            // without looking the other row up.
            return located.mark.relatedTo.map { id in
                let label = rows.first { $0.mark.id == id }?.mark.label
                return label.map { "\(id) \($0)" } ?? id
            }.joined(separator: ", ")
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
            tableColumn.width = column.width
            tableColumn.resizingMask = column == .text ? .autoresizingMask : .userResizingMask
            table.addTableColumn(tableColumn)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
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
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byTruncatingTail
            field.font = column == .place || column == .id
                ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
            return field
        }()
        cell.stringValue = text(row: row, column)
        cell.toolTip = column == .text || column == .file ? (column == .file ? rows[row].url.path : cell.stringValue) : nil
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
