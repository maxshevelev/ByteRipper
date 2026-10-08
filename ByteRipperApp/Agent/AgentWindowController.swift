import Cocoa
import AgentKit
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
    private let table = NSTableView()
    private let clearButton = NSButton(title: "", target: nil, action: nil)
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
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        clearButton.title = L("Clear Log")
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearLog)

        settingsButton.title = L("Agent Settings…")
        settingsButton.bezelStyle = .rounded
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)

        let help = HelpButton.standard(for: .topic(.agent))

        for view in [statusLabel, scroll, clearButton, settingsButton, help] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: help.leadingAnchor, constant: -8),

            help.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            help.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            clearButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
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
        clearButton.isEnabled = !rows.isEmpty
        if followed, !rows.isEmpty { table.scrollRowToVisible(rows.count - 1) }
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
        cell.textColor = column == .result && Self.isProblem(rows[row]) ? .systemRed : .labelColor
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

    @objc private func clearLog() {
        service?.clearLog()
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
}
