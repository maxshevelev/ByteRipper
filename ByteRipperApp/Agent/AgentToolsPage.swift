import Cocoa
import AgentKit
import ALSplitView
import AppPalette
import Localization
import ToolModuleKit

/// The Tools page of the Agent window: every tool an agent is offered, with
/// where it comes from, what it does and how it has been used since the app
/// started; below, the selected tool as the agent is told about it — its
/// description and the arguments it takes.
// help: window.agent.tools
@MainActor
final class AgentToolsPage: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    private let scroll = NSScrollView()
    /// The list above, the selected tool below, as the log's.
    let split = ALSplitView()
    let detailPane = ToolDetailPane()
    private var details: ToolDetailScroll { detailPane.detail }
    var onSelectionChanged: () -> Void = {}
    private(set) var rows: [AgentToolEntry] = []
    private(set) var stats: [String: AgentToolStats] = [:]

    private enum Column: String, CaseIterable {
        case tool, group, kind, calls, failures, average, size, last

        var title: String {
            switch self {
            case .tool: return L("Tool")
            case .group: return L("Group")
            case .kind: return L("Kind")
            case .calls: return L("Calls")
            case .failures: return L("Not Answered")
            case .average: return L("Average")
            case .size: return L("Answers")
            case .last: return L("Last Call")
            }
        }

        var width: CGFloat {
            switch self {
            case .tool: return 140
            case .group: return 120
            case .kind: return 90
            case .calls: return 50
            case .failures: return 70
            case .average: return 64
            case .size: return 70
            case .last: return 64
            }
        }

        var isNumber: Bool { ![.tool, .group, .kind].contains(self) }
    }

    func build() {
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = ToolPanelFont.scaled(column.width)
            tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
            tableColumn.minWidth = ToolPanelFont.scaled(36)
            table.addTableColumn(tableColumn)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        AgentTableStyle.apply(to: table)
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        details.borderType = .bezelBorder
        details.showPlaceholder(L("Select a tool to see what the agent is told about it."))
        split.isVertical = false
        split.dividerThickness = 1
        split.addPane(scroll)
        split.addPane(detailPane)
        detailPane.attach(to: table)
        split.setPaneLayout(.fill, at: 0)
        split.setPaneLayout(.fixed(170), at: 1)
    }

    /// The tools and their use; the selection stays with the tool it was on.
    func show(_ entries: [AgentToolEntry], stats: [String: AgentToolStats]) {
        let chosen = table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow].tool.name : nil
        rows = entries
        self.stats = stats
        table.reloadData()
        if let chosen, let row = rows.firstIndex(where: { $0.tool.name == chosen }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        showDetails()
    }

    var hasStats: Bool { !stats.isEmpty }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let column = Column(rawValue: id.rawValue) else { return nil }
        let cell = AgentTableStyle.cell(in: tableView, id: id, owner: self, digits: column.isNumber, code: column == .tool)
        cell.textField?.stringValue = text(row: row, column)
        cell.textField?.textColor = column == .failures && (stats[rows[row].tool.name]?.failures ?? 0) > 0
            ? SemanticColors.bad : .labelColor
        cell.textField?.alignment = column.isNumber ? .right : .natural
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showDetails()
        onSelectionChanged()
    }

    private func text(row: Int, _ column: Column) -> String {
        let entry = rows[row]
        let used = stats[entry.tool.name]
        switch column {
        case .tool: return entry.tool.name
        case .group: return entry.group.title
        case .kind: return entry.kind.title
        case .calls: return used.map { "\($0.calls)" } ?? ""
        case .failures: return used.map { $0.failures == 0 ? "" : "\($0.failures)" } ?? ""
        case .average: return used?.average.map(Self.durationText) ?? ""
        case .size: return used.map { ByteCountFormatter.string(fromByteCount: Int64($0.answerBytes), countStyle: .memory) } ?? ""
        case .last: return used?.last.map { Self.timeFormatter.string(from: $0) } ?? ""
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func durationText(_ duration: Duration) -> String {
        let milliseconds = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return milliseconds < 1000
            ? L("%1$@ ms", Int(milliseconds.rounded()))
            : L("%1$@ s", String(format: "%.1f", milliseconds / 1000))
    }

    // MARK: - Details

    /// The selected tool: what it is and how it was used, then the words the
    /// agent reads — the description and the arguments' schema, in English
    /// as the agent gets them.
    private func showDetails() {
        let row = table.selectedRow
        guard row >= 0, row < rows.count else {
            details.showPlaceholder(L("Select a tool to see what the agent is told about it."))
            return
        }
        let entry = rows[row]
        details.prepareForRows(subject: entry.tool.name)
        let title = NSTextField(labelWithString: entry.tool.name)
        title.font = ToolPanelFont.title()
        title.translatesAutoresizingMaskIntoConstraints = false
        details.content.addArrangedSubview(title)
        let list = ToolFieldList(fields: Self.detailFields(of: entry, stats[entry.tool.name]).map { field in
            .init(label: field.label, value: NSAttributedString(string: field.value, attributes: [
                .font: ToolPanelFont.body(),
                .foregroundColor: field.isProblem ? SemanticColors.bad : NSColor.labelColor]))
        })
        details.content.addArrangedSubview(list)
        list.widthAnchor.constraint(equalTo: details.content.widthAnchor).isActive = true
        var last: NSView = list
        for (heading, text, code) in [(L("Description"), entry.tool.description, false),
                                      (L("Arguments"), entry.tool.inputSchema.prettyText, true)] {
            let label = NSTextField(labelWithString: heading)
            label.font = ToolPanelFont.title()
            label.translatesAutoresizingMaskIntoConstraints = false
            details.content.setCustomSpacing(10, after: last)
            details.content.addArrangedSubview(label)
            let body = ToolWrappingLabel(string: text)
            body.font = code ? .monospacedSystemFont(ofSize: ToolPanelFont.body().pointSize, weight: .regular)
                : ToolPanelFont.body()
            body.lineBreakMode = code ? .byCharWrapping : .byWordWrapping
            body.isSelectable = true
            details.content.addArrangedSubview(body)
            body.widthAnchor.constraint(equalTo: details.content.widthAnchor).isActive = true
            last = body
        }
    }

    /// The rows the details list shows for a tool, above its description.
    static func detailFields(of entry: AgentToolEntry, _ used: AgentToolStats?) -> [AgentWindowController.DetailField] {
        var fields: [AgentWindowController.DetailField] = []
        if let title = entry.tool.title { fields.append(.init(label: L("Title"), value: title)) }
        fields.append(.init(label: L("Group"), value: entry.group.title))
        fields.append(.init(label: L("Kind"), value: entry.kind.title))
        guard let used else {
            fields.append(.init(label: L("Calls"), value: L("None yet")))
            return fields
        }
        fields.append(.init(label: L("Calls"), value: "\(used.calls)"))
        if used.failures > 0 { fields.append(.init(label: L("Not Answered"), value: "\(used.failures)", isProblem: true)) }
        if let average = used.average { fields.append(.init(label: L("Average"), value: durationText(average))) }
        fields.append(.init(label: L("Longest"), value: durationText(used.longest)))
        fields.append(.init(label: L("Answers"), value: L("%1$@ bytes", used.answerBytes)))
        if let last = used.last {
            fields.append(.init(label: L("Last Call"), value: DateFormatter.localizedString(
                from: last, dateStyle: .none, timeStyle: .medium)))
        }
        return fields
    }

    /// A row's text, for tests.
    func shownText(row: Int, column: String) -> String? {
        guard row < rows.count, let column = Column(rawValue: column) else { return nil }
        return text(row: row, column)
    }

    /// The description and the schema as the details show them, for tests.
    var shownTexts: [String] {
        details.content.arrangedSubviews.compactMap { ($0 as? ToolWrappingLabel)?.stringValue }
    }

    func select(_ row: Int) {
        table.selectRowIndexes([row], byExtendingSelection: false)
    }
}
