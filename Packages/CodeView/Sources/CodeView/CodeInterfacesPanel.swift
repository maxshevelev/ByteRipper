import AppKit
import CodeAnalysis
import HelpBook
import HelpUI
import Localization
import ToolModuleKit

/// The navigator's Interfaces tab: what the module installs, looks up and is
/// notified of, as its review recorded them (`ModuleInterfaces`). The
/// navigator is narrow, so it is a tree rather than a table: a kind, its
/// interfaces under it, and under each interface what the review says of it
/// — why the module needs it, when, the GUID, and the places in the code,
/// which open there.
///
/// It shows what it is given; the pane goes to an address it asks for.
// help: panel.code.interfaces
final class CodeInterfacesPanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// One of the record's three lists, or the dependency expression: a
    /// row of the first level.
    final class GroupItem {
        let title: String
        let symbol: String
        let help: HelpLink
        /// Nil while the review has not answered the list.
        let entries: [EntryItem]?
        /// The dependency expression's conditions, in place of interfaces.
        /// Nil for the review's lists.
        let conditions: [ConditionItem]?
        init(title: String, symbol: String, help: HelpLink, entries: [EntryItem]?,
             conditions: [ConditionItem]? = nil) {
            self.title = title
            self.symbol = symbol
            self.help = help
            self.entries = entries
            self.conditions = conditions
        }

        /// Rows under it.
        var children: [Any] { conditions ?? entries ?? [] }
    }

    /// A row of the dependency expression: one condition — an interface by
    /// its name and GUID — or a group of them, a choice (`One of`) or what
    /// must all hold inside one, with its conditions a level under it.
    final class ConditionItem {
        let text: NSAttributedString
        let children: [ConditionItem]
        /// The GUID of a condition that names an interface: its row is one
        /// line with the GUID's mark, the GUID in its tooltip.
        let guid: String?
        init(text: NSAttributedString, children: [ConditionItem] = [], guid: String? = nil) {
            self.text = text
            self.children = children
            self.guid = guid
        }
        var isGroup: Bool { !children.isEmpty }
    }

    /// One interface: a row of the second level.
    final class EntryItem {
        let interface: ModuleInterfaces.Interface
        /// Grey after the name: reinstalls, handed over, required, optional.
        let marks: [String]
        let details: [DetailItem]
        init(interface: ModuleInterfaces.Interface, marks: [String], details: [DetailItem]) {
            self.interface = interface
            self.marks = marks
            self.details = details
        }
    }

    /// What the review says of an interface: a row of the third level. A
    /// row with an address opens the code there.
    final class DetailItem {
        let text: NSAttributedString
        let address: CodeAddress?
        init(text: NSAttributedString, address: CodeAddress? = nil) {
            self.text = text
            self.address = address
        }
    }

    let summaryLabel = NSTextField(labelWithString: "")
    let outline = SearchOutlineView()
    private let scroll = NSScrollView()
    private(set) var groups: [GroupItem] = []

    /// A row with an address was chosen.
    var onChoose: ((CodeAddress) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The navigator has no fill of its own; the panel takes the window's, so
    /// the list it stands over does not show through.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }

    private func build() {
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.alignment = .center
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.init(240), for: .horizontal)

        let column = NSTableColumn(identifier: .init("interface"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.style = .inset
        outline.backgroundColor = .clear
        outline.indentationPerLevel = 0
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let below = NSBox()
        below.boxType = .separator
        below.translatesAutoresizingMaskIntoConstraints = false
        for view in [summaryLabel, below, scroll] { addSubview(view) }
        NSLayoutConstraint.activate([
            summaryLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            below.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 5),
            below.leadingAnchor.constraint(equalTo: leadingAnchor),
            below.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: below.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    // MARK: - What is shown

    /// Shows a module's record. `place` names the code an address is in —
    /// the function, and the offset into it — or nil where the artifact has
    /// no instruction there.
    func show(_ interfaces: ModuleInterfaces?, dependencies: DependencyOutline? = nil, place: (CodeAddress) -> String?) {
        groups = Self.groups(of: interfaces, dependencies: dependencies, place: place)
        outline.reloadData()
        // The kinds open; each interface closed, its name and marks a line.
        for group in groups { outline.expandItem(group) }
        // The expression open whole, its choices too.
        for condition in groups.flatMap({ $0.conditions ?? [] }) where condition.isGroup {
            outline.expandItem(condition, expandChildren: true)
        }
        summaryLabel.stringValue = Self.summary(of: interfaces)
    }

    static func summary(of interfaces: ModuleInterfaces?) -> String {
        guard let interfaces, interfaces.isComplete else {
            return L("The review has not recorded them all yet")
        }
        let count = [interfaces.installs, interfaces.locates, interfaces.notifies]
            .reduce(0) { $0 + ($1?.count ?? 0) }
        if count == 0 { return L("The module uses no PPI or protocol") }
        return count == 1 ? L("1 interface") : L("%1$@ interfaces", String(count))
    }

    static func groups(of interfaces: ModuleInterfaces?, dependencies: DependencyOutline? = nil,
                       place: (CodeAddress) -> String?) -> [GroupItem] {
        func entries(_ list: [ModuleInterfaces.Interface]?,
                     marks: (ModuleInterfaces.Interface) -> [String]) -> [EntryItem]? {
            list?.map { EntryItem(interface: $0, marks: marks($0), details: details(of: $0, place: place)) }
        }
        // The condition the dispatcher starts the module on, from its
        // firmware file: the PPIs or protocols it waits for, by name.
        var depex: [GroupItem] = []
        if let dependencies {
            depex.append(GroupItem(title: L("Dependency expression"), symbol: "flowchart",
                                   help: .term(HelpTermID("depex")), entries: nil,
                                   conditions: conditionItems(of: dependencies)))
        }
        return depex + [
            GroupItem(title: L("Installs"), symbol: "square.and.arrow.up",
                      help: .term(HelpTermID("module-installs")),
                      entries: entries(interfaces?.installs) { entry in
                          switch entry.method {
                          case .reinstall: [L("reinstalls")]
                          case .handoff: [L("handed over")]
                          default: []
                          }
                      }),
            GroupItem(title: L("Locates"), symbol: "magnifyingglass",
                      help: .term(HelpTermID("module-locates")),
                      entries: entries(interfaces?.locates) { entry in
                          [entry.required == true ? L("required") : L("optional")]
                      }),
            GroupItem(title: L("Notified of"), symbol: "bell",
                      help: .term(HelpTermID("module-notified-of")),
                      entries: entries(interfaces?.notifies) { _ in [] })
        ]
    }

    /// The rows of a dependency expression: what must all hold, one row
    /// each — the interface's name and its GUID — and a choice as a row of
    /// its own with its alternatives under it.
    static func conditionItems(of outline: DependencyOutline) -> [ConditionItem] {
        let plain: [NSAttributedString.Key: Any] = [
            .font: CodePaneView.navigatorFont(), .foregroundColor: NSColor.labelColor
        ]
        let quiet: [NSAttributedString.Key: Any] = [
            .font: CodePaneView.navigatorFont(), .foregroundColor: NSColor.secondaryLabelColor
        ]
        func line(_ words: String, _ attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
            NSAttributedString(string: words, attributes: attributes)
        }
        func interface(_ guid: String, _ name: String?, negated: Bool) -> NSAttributedString {
            let text = NSMutableAttributedString()
            // NOT and the opcodes are the format's words, as ASM and C are.
            if negated { text.append(line("NOT ", quiet)) }
            text.append(line(name ?? guid, plain))
            return text
        }
        func item(_ condition: DependencyOutline.Condition) -> ConditionItem {
            switch condition {
            case .interface(let guid, let name):
                return ConditionItem(text: interface(guid, name, negated: false), guid: guid)
            case .not(.interface(let guid, let name)):
                return ConditionItem(text: interface(guid, name, negated: true), guid: guid)
            case .not(let operand):
                return ConditionItem(text: line("NOT", quiet), children: [item(operand)])
            case .anyOf(let list):
                return ConditionItem(text: line(L("One of"), quiet), children: list.map(item))
            case .allOf(let list):
                return ConditionItem(text: line(L("All of"), quiet), children: list.map(item))
            case .always:
                return ConditionItem(text: line(L("TRUE: the module waits for nothing"), plain))
            case .never:
                return ConditionItem(text: line(L("FALSE: the module is never started"), plain))
            }
        }
        var rows: [ConditionItem] = []
        if let prefix = outline.prefix { rows.append(ConditionItem(text: line(prefix, plain))) }
        if outline.unreadable {
            rows.append(ConditionItem(text: line(L("The expression in the file cannot be read."), quiet)))
        }
        return rows + outline.conditions.map(item)
    }

    /// The rows under an interface: why, when, what it is, and where.
    static func details(of entry: ModuleInterfaces.Interface,
                        place: (CodeAddress) -> String?) -> [DetailItem] {
        let plain: [NSAttributedString.Key: Any] = [
            .font: CodePaneView.navigatorFont(), .foregroundColor: NSColor.labelColor
        ]
        func labelled(_ label: String, _ value: String, value attributes: [NSAttributedString.Key: Any])
            -> NSAttributedString {
            let text = NSMutableAttributedString(string: label + " ", attributes: [
                .font: CodePaneView.navigatorFont(), .foregroundColor: NSColor.secondaryLabelColor
            ])
            text.append(NSAttributedString(string: value, attributes: attributes))
            return text
        }
        let link: [NSAttributedString.Key: Any] = [
            .font: CodePaneView.navigatorFont(), .foregroundColor: NSColor.linkColor
        ]
        let mono: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: CodePaneView.navigatorSize - 1, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        var rows = [DetailItem(text: NSAttributedString(string: entry.purpose, attributes: plain))]
        let when = entry.condition == "always" ? L("always") : entry.condition
        rows.append(DetailItem(text: labelled(L("When:"), when, value: plain)))
        let kind = entry.kind == .ppi ? "PPI" : L("Protocol")
        rows.append(DetailItem(text: labelled(kind, entry.guid, value: mono)))
        let address = CodeAddress(hex: entry.address)
        let at = address.flatMap(place) ?? entry.address
        rows.append(DetailItem(text: labelled(L("At:"), at, value: address.flatMap(place) == nil ? plain : link),
                               address: address.flatMap { place($0) == nil ? nil : $0 }))
        if let callback = entry.callback {
            let target = CodeAddress(hex: callback)
            let name = target.flatMap(place) ?? callback
            rows.append(DetailItem(text: labelled(L("Callback:"), name,
                                                  value: target.flatMap(place) == nil ? plain : link),
                                   address: target.flatMap { place($0) == nil ? nil : $0 }))
        }
        return rows
    }

    // MARK: - The tree

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return groups.count }
        if let group = item as? GroupItem { return group.children.count }
        if let condition = item as? ConditionItem { return condition.children.count }
        return (item as? EntryItem)?.details.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return groups[index] }
        if let group = item as? GroupItem { return group.children[index] }
        if let condition = item as? ConditionItem { return condition.children[index] }
        return (item as! EntryItem).details[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let group = item as? GroupItem { return !group.children.isEmpty }
        if let condition = item as? ConditionItem { return condition.isGroup }
        return item is EntryItem
    }

    /// Where a detail's text starts: under the interface's name.
    static var detailInset: CGFloat { entryInset + CodeNavigatorCell.disclosureRoom + 4 }
    /// Where an interface's row starts: under its kind's name.
    static var entryInset: CGFloat { CodeNavigatorCell.disclosureRoom - 2 }
    static let detailTrailing: CGFloat = 6
    static let detailPadding: CGFloat = 2

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        let row = CodePaneView.navigatorRowHeight
        let text: NSAttributedString
        let inset: CGFloat
        if let detail = item as? DetailItem {
            text = detail.text
            inset = Self.detailInset
        } else if let condition = item as? ConditionItem, !condition.isGroup, condition.guid == nil {
            text = condition.text
            inset = Self.conditionInset(level: outlineView.level(forItem: condition))
        } else {
            return row
        }
        let column = outlineView.numberOfColumns > 0 ? outlineView.rect(ofColumn: 0).width : outlineView.bounds.width
        let width = max(40, column - inset - Self.detailTrailing - 4)
        let measured = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return max(row - 4, ceil(measured) + 2 * Self.detailPadding)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        if let group = item as? GroupItem { return groupCell(group, in: outlineView) }
        if let entry = item as? EntryItem { return entryCell(entry, in: outlineView) }
        if let condition = item as? ConditionItem {
            let level = outlineView.level(forItem: condition)
            if condition.isGroup { return conditionGroupCell(condition, level: level, in: outlineView) }
            if let guid = condition.guid { return conditionCell(condition, guid: guid, level: level, in: outlineView) }
            return textCell(condition.text, inset: Self.conditionInset(level: level), in: outlineView)
        }
        guard let detail = item as? DetailItem else { return nil }
        return textCell(detail.text, inset: Self.detailInset, in: outlineView)
    }

    /// Where a condition's text starts at `level` of the tree: under its
    /// group's name, past the room of a triangle, a level further in for each
    /// group it is in.
    static func conditionInset(level: Int) -> CGFloat {
        entryInset + CGFloat(max(0, level - 1)) * CodeNavigatorCell.disclosureRoom
            + CodeNavigatorCell.disclosureRoom
    }

    /// A choice or a set of conditions: a row with a triangle, its conditions under it.
    private func conditionGroupCell(_ condition: ConditionItem, level: Int, in outlineView: NSOutlineView) -> NSView {
        let id = NSUserInterfaceItemIdentifier("condition-group")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? CodeNavigatorCell
            ?? CodeNavigatorCell(identifier: id)
        cell.showsDisclosure(true)
        cell.showsCalls(expandable: true, expanded: outlineView.isItemExpanded(condition))
        cell.onToggle = { [weak self] in self?.toggle(condition) }
        cell.showsIcon(nil)
        cell.indent = Self.entryInset + CGFloat(max(0, level - 1)) * CodeNavigatorCell.disclosureRoom
        cell.textField?.attributedStringValue = condition.text
        return cell
    }

    /// A condition that names an interface: one line, as an interface of the
    /// review's lists — the GUID's mark and the name, the GUID in its
    /// tooltip — its name under its group's.
    private func conditionCell(_ condition: ConditionItem, guid: String, level: Int,
                               in outlineView: NSOutlineView) -> NSView {
        let id = NSUserInterfaceItemIdentifier("condition")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? CodeNavigatorCell
            ?? CodeNavigatorCell(identifier: id)
        cell.showsDisclosure(true)
        cell.showsCalls(expandable: false, expanded: false)
        cell.onToggle = nil
        cell.showsMark(CodeNavigatorIcon.dependency, named: "guid")
        cell.indent = Self.entryInset + CGFloat(max(0, level - 1)) * CodeNavigatorCell.disclosureRoom
        cell.textField?.attributedStringValue = condition.text
        cell.toolTip = guid
        return cell
    }

    /// A row of text that wraps, starting `inset` in: a detail of an
    /// interface, or one condition of the dependency expression.
    private func textCell(_ text: NSAttributedString, inset: CGFloat, in outlineView: NSOutlineView) -> NSView {
        let id = NSUserInterfaceItemIdentifier("detail-\(CodePaneView.navigatorSize)-\(inset)")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = InterfacesDetailField(wrappingLabelWithString: "")
            text.lineBreakMode = .byWordWrapping
            text.isSelectable = false
            text.translatesAutoresizingMaskIntoConstraints = false
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: inset),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Self.detailTrailing),
                text.topAnchor.constraint(equalTo: cell.topAnchor, constant: Self.detailPadding)
            ])
            return cell
        }()
        (cell.textField as? InterfacesDetailField)?.show(text)
        return cell
    }

    private func groupCell(_ group: GroupItem, in outlineView: NSOutlineView) -> NSView {
        let id = NSUserInterfaceItemIdentifier("group")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? CodeNavigatorCell
            ?? CodeNavigatorCell(identifier: id)
        let expandable = !group.children.isEmpty
        cell.showsDisclosure(true)
        cell.showsCalls(expandable: expandable, expanded: outlineView.isItemExpanded(group))
        cell.onToggle = { [weak self] in self?.toggle(group) }
        // A heading as the Functions list draws a review group's: its sign
        // on a coloured square, the name one weight up in grey, and how many
        // rows it holds.
        cell.showsMark(CodeNavigatorIcon.interfaceGroup(group.symbol), named: group.symbol)
        let detail: String = if let conditions = group.conditions { conditions.isEmpty ? " — " + L("None") : "" } else {
            switch group.entries {
            case nil: " — " + L("Not recorded yet")
            case let list?: " (\(list.count))"
            }
        }
        cell.textField?.attributedStringValue = NSAttributedString(string: group.title + detail, attributes: [
            .font: NSFont.systemFont(ofSize: CodePaneView.navigatorSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        Self.putHelp(group.help, named: group.title, in: cell)
        return cell
    }

    private func entryCell(_ entry: EntryItem, in outlineView: NSOutlineView) -> NSView {
        let id = NSUserInterfaceItemIdentifier("entry")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? CodeNavigatorCell
            ?? CodeNavigatorCell(identifier: id)
        cell.showsDisclosure(true)
        cell.showsCalls(expandable: true, expanded: outlineView.isItemExpanded(entry))
        cell.onToggle = { [weak self] in self?.toggle(entry) }
        // An interface as a function is drawn: its kind's mark, its name in
        // the rows' weight.
        cell.showsMark(entry.interface.kind == .ppi ? CodeNavigatorIcon.ppi : CodeNavigatorIcon.protocolInterface,
                       named: entry.interface.kind == .ppi ? "ppi" : "protocol")
        cell.indent = Self.entryInset
        let line = NSMutableAttributedString(string: entry.interface.name, attributes: [
            .font: CodePaneView.navigatorFont(), .foregroundColor: NSColor.labelColor
        ])
        if !entry.marks.isEmpty {
            line.append(NSAttributedString(string: " " + entry.marks.joined(separator: ", "), attributes: [
                .font: CodePaneView.navigatorFont(), .foregroundColor: NSColor.secondaryLabelColor
            ]))
        }
        cell.textField?.attributedStringValue = line
        cell.toolTip = entry.interface.guid
        return cell
    }

    /// The rows say when they are selected, so what is coloured in them — a
    /// (?), a place in blue — takes the selection's colour.
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        InterfacesRowView()
    }

    /// A width the rows have not been measured at: the lines wrap anew.
    private var measuredWidth: CGFloat = 0

    override func layout() {
        super.layout()
        let width = outline.bounds.width
        guard width != measuredWidth, outline.numberOfRows > 0 else { return }
        measuredWidth = width
        outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
    }

    /// Opens or closes a row, as the Search tab's groups do.
    func toggle(_ item: Any) {
        let opening = !outline.isItemExpanded(item)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            if opening {
                outline.animator().expandItem(item)
            } else {
                outline.animator().collapseItem(item)
            }
        }
    }

    /// The zoom changed: the rows are made again in the new size, what the
    /// reader opened staying open.
    func zoomChanged() {
        let open = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) }
            .filter { outline.isItemExpanded($0) } as [AnyObject]
        outline.reloadData()
        for item in open { outline.expandItem(item) }
        measuredWidth = 0
        if outline.numberOfRows > 0 {
            outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        redrawChevron(notification)
        // The expression opens whole: a choice is part of the condition, not
        // a detail behind a second click.
        if let group = notification.userInfo?["NSObject"] as? GroupItem, let conditions = group.conditions {
            for condition in conditions where condition.isGroup { outline.expandItem(condition, expandChildren: true) }
        }
    }
    func outlineViewItemDidCollapse(_ notification: Notification) { redrawChevron(notification) }

    private func redrawChevron(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] else { return }
        let row = outline.row(forItem: item)
        guard row >= 0,
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? CodeNavigatorCell
        else { return }
        cell.showsCalls(expandable: true, expanded: outline.isItemExpanded(item))
    }

    @objc private func rowClicked() {
        guard outline.clickedRow >= 0 else { return }
        choose(row: outline.clickedRow)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard NSApp.currentEvent?.type == .keyDown else { return }
        choose(row: outline.selectedRow)
    }

    /// A row chosen: an interface opens the code where the module supplies
    /// it, a detail with an address opens that place.
    func choose(row: Int) {
        guard row >= 0, let item = outline.item(atRow: row) else { return }
        if let entry = item as? EntryItem, let address = entry.details.lazy.compactMap(\.address).first {
            onChoose?(address)
        } else if let detail = item as? DetailItem, let address = detail.address {
            onChoose?(address)
        }
    }

    /// The kind's (?) at the row's trailing edge: what the kind is, in the
    /// help. A reused cell has its old one taken off first.
    private static func putHelp(_ link: HelpLink, named name: String, in cell: NSView) {
        cell.subviews.filter { $0 is HelpButton }.forEach { $0.removeFromSuperview() }
        let button = HelpButton.inline(for: link, tooltip: name,
                                       pointSize: (CodePaneView.navigatorSize - 1).rounded())
        cell.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            button.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
    }

    // MARK: - For tests

    /// The tree as text: each kind's line, its interfaces' and their details'.
    var linesForTests: [String] {
        (0..<outline.numberOfRows).compactMap { row -> String? in
            switch outline.item(atRow: row) {
            case let group as GroupItem: group.title
            case let entry as EntryItem: "  " + entry.interface.name
            case let detail as DetailItem: "    " + detail.text.string
            case let condition as ConditionItem:
                String(repeating: "  ", count: outline.level(forItem: condition)) + condition.text.string
            default: nil
            }
        }
    }
}

/// A row of the Interfaces tree. On the selection's fill a link's blue and the
/// (?)'s cannot be seen: while the row is selected in a focused list they take
/// the selection's text colour, and a place keeps an underline to say it is a
/// link.
final class InterfacesRowView: NSTableRowView {
    override var isSelected: Bool { didSet { restyle() } }
    override var isEmphasized: Bool { didSet { restyle() } }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        restyle()
    }

    /// Whether the row stands on the accent fill.
    var onSelection: Bool { isSelected && isEmphasized }

    func restyle() {
        let on = onSelection
        func walk(_ view: NSView) {
            if let button = view as? HelpButton {
                button.contentTintColor = on ? .alternateSelectedControlTextColor : .linkColor
            } else if let field = view as? InterfacesDetailField {
                field.selected = on
            }
            view.subviews.forEach(walk)
        }
        subviews.forEach(walk)
    }
}

/// A detail's text, drawn again in the selection's colour while its row is
/// selected.
final class InterfacesDetailField: NSTextField {
    private var shown = NSAttributedString()

    var selected = false {
        didSet { if selected != oldValue { draw() } }
    }

    func show(_ text: NSAttributedString) {
        shown = text
        selected = (enclosingRow as? InterfacesRowView)?.onSelection ?? false
        draw()
    }

    private var enclosingRow: NSView? {
        var view = superview
        while let current = view, !(current is NSTableRowView) { view = current.superview }
        return view
    }

    private func draw() {
        guard selected else {
            attributedStringValue = shown
            return
        }
        let text = NSMutableAttributedString(attributedString: shown)
        let whole = NSRange(location: 0, length: text.length)
        shown.enumerateAttribute(.foregroundColor, in: whole) { color, range, _ in
            if (color as? NSColor) == NSColor.linkColor {
                text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        text.addAttribute(.foregroundColor, value: NSColor.alternateSelectedControlTextColor, range: whole)
        attributedStringValue = text
    }
}

extension DependencyOutline {
    /// The expression with each interface under the GUID registry's name,
    /// where the registry holds its GUID.
    func named(by registry: GuidRegistry) -> DependencyOutline {
        guard !registry.entries.isEmpty else { return self }
        func renamed(_ condition: Condition) -> Condition {
            switch condition {
            case let .interface(guid, name): .interface(guid: guid, name: registry.name(of: guid) ?? name)
            case let .not(inner): .not(renamed(inner))
            case let .allOf(list): .allOf(list.map(renamed))
            case let .anyOf(list): .anyOf(list.map(renamed))
            case .always, .never: condition
            }
        }
        return DependencyOutline(conditions: conditions.map(renamed), prefix: prefix, unreadable: unreadable)
    }
}
