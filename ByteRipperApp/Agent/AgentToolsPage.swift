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
    /// A section's title, or a tool in it.
    private enum Item {
        case header(String)
        case tool(AgentToolEntry)
    }
    private var items: [Item] = []
    private(set) var stats: [String: AgentToolStats] = [:]

    /// The tools in the order the table shows them, section by section.
    var rows: [AgentToolEntry] {
        items.compactMap { if case .tool(let entry) = $0 { return entry } else { return nil } }
    }

    private func entry(at row: Int) -> AgentToolEntry? {
        guard row >= 0, row < items.count, case .tool(let entry) = items[row] else { return nil }
        return entry
    }

    private enum Column: String, CaseIterable {
        case tool, kind, calls, failures, average, size, last

        var title: String {
            switch self {
            case .tool: return L("Tool")
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
            // Wide enough for `uefi_fix_checksum` behind the names' indent.
            case .tool: return 190
            case .kind: return 80
            case .calls: return 44
            case .failures: return 92
            case .average: return 60
            case .size: return 64
            case .last: return 60
            }
        }

        var isNumber: Bool { ![.tool, .kind].contains(self) }
    }

    func build() {
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = ToolPanelFont.scaled(column.width)
            // Only the last column gives way with the window; the others keep
            // the widths they were given, and the person can still drag them.
            tableColumn.resizingMask = column == Column.allCases.last
                ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            tableColumn.minWidth = ToolPanelFont.scaled(36)
            table.addTableColumn(tableColumn)
        }
        table.usesAlternatingRowBackgroundColors = true
        // What the window adds or gives back goes to Last Call, the column at
        // the end. Shared out evenly, every column came to the same width,
        // which cut the longer names short behind their indent and "Not
        // Answered" down to "Not".
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // Plain: the automatic and full-width styles put a 20-point blank
        // band above every section's heading but the first (measured).
        table.style = .plain
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

    /// The tools and their use, a section to each group in the order the
    /// groups first come; the selection stays with the tool it was on.
    func show(_ entries: [AgentToolEntry], stats: [String: AgentToolStats]) {
        let chosen = entry(at: table.selectedRow)?.tool.name
        var order: [String] = []
        var sections: [String: [AgentToolEntry]] = [:]
        for entry in entries {
            let title = entry.group.title
            if sections[title] == nil { order.append(title) }
            sections[title, default: []].append(entry)
        }
        items = order.flatMap { title in [Item.header(title)] + sections[title, default: []].map { .tool($0) } }
        self.stats = stats
        table.reloadData()
        if let chosen, let row = row(of: chosen) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        showDetails()
    }

    var hasStats: Bool { !stats.isEmpty }

    /// The table row of the tool named `name`.
    func row(of name: String) -> Int? {
        items.firstIndex { if case .tool(let entry) = $0 { return entry.tool.name == name } else { return false } }
    }

    /// The sections' titles, in order, for tests.
    var sectionTitles: [String] {
        items.compactMap { if case .header(let title) = $0 { return title } else { return nil } }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard case .header = items[row] else { return tableView.rowHeight }
        // The heading's own line, and room above it that sets the section off
        // from the last tool of the one before.
        let font = Self.headingFont
        return (font.ascender - font.descender + font.leading).rounded(.up)
            + Self.headingSpaceAbove + Self.headingSpaceBelow
    }

    /// A section's heading: a size above the tool names, so the groups read as
    /// groups rather than as one more row.
    static var headingFont: NSFont { .systemFont(ofSize: ToolPanelFont.titleSize, weight: .semibold) }
    private static var headingSpaceAbove: CGFloat { ToolPanelFont.scaled(12) }
    private static var headingSpaceBelow: CGFloat { ToolPanelFont.scaled(4) }
    /// How far the tool names stand in from their headings.
    static var toolIndent: CGFloat { ToolPanelFont.scaled(14) }

    /// A heading's view, which draws its own text. A text field in a group
    /// row is not left to its own font: AppKit sizes the field to the row
    /// style (13 pt here, whatever was set, and read back as set), so the
    /// heading is drawn by a view of its own.
    private final class HeadingView: NSView {
        var title = "" { didSet { needsDisplay = true } }
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: AgentToolsPage.headingFont, .foregroundColor: NSColor.secondaryLabelColor]
            let text = NSAttributedString(string: title, attributes: attributes)
            let size = text.size()
            // On the view's bottom, so the room the row adds lies above it.
            text.draw(at: NSPoint(x: 2, y: bounds.height - size.height - AgentToolsPage.headingSpaceBelow))
        }
    }

    private func headingView(in tableView: NSTableView) -> HeadingView {
        let id = NSUserInterfaceItemIdentifier("section")
        if let view = tableView.makeView(withIdentifier: id, owner: self) as? HeadingView { return view }
        let view = HeadingView()
        view.identifier = id
        return view
    }

    /// A tool name's cell: the shared cell, stood in from the column's edge
    /// so the names sit under their heading rather than flush with it.
    private func toolCell(in tableView: NSTableView, id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        if let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView { return cell }
        let cell = AgentTableStyle.cell(in: tableView, id: id, owner: self, code: true)
        if let field = cell.textField,
           let leading = cell.constraints.first(where: {
               $0.firstAttribute == .leading && ($0.firstItem as? NSView) === field && ($0.secondItem as? NSView) === cell
           }) {
            leading.constant = 2 + Self.toolIndent
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        entry(at: row) != nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if case .header(let title) = items[row] {
            let view = headingView(in: tableView)
            view.title = title
            return view
        }
        guard let id = tableColumn?.identifier, let column = Column(rawValue: id.rawValue),
              let entry = entry(at: row) else { return nil }
        let cell = column == .tool
            ? toolCell(in: tableView, id: id)
            : AgentTableStyle.cell(in: tableView, id: id, owner: self, digits: column.isNumber)
        if column == .tool {
            // Set every time: the shared cell's font follows the panel's size.
            cell.textField?.font = .monospacedSystemFont(ofSize: ToolPanelFont.size, weight: .regular)
        }
        cell.textField?.stringValue = text(row: row, column)
        cell.textField?.textColor = column == .failures && (stats[entry.tool.name]?.failures ?? 0) > 0
            ? SemanticColors.bad : .labelColor
        // Right-aligned figures, except under Last Call: the column that takes
        // the window's extra width would carry its time far from its header.
        cell.textField?.alignment = column.isNumber && column != .last ? .right : .natural
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showDetails()
        onSelectionChanged()
    }

    private func text(row: Int, _ column: Column) -> String {
        guard let entry = entry(at: row) else { return "" }
        let used = stats[entry.tool.name]
        switch column {
        case .tool: return entry.tool.name
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
        guard let entry = entry(at: table.selectedRow) else {
            details.showPlaceholder(L("Select a tool to see what the agent is told about it."))
            return
        }
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
        guard entry(at: row) != nil, let column = Column(rawValue: column) else { return nil }
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
