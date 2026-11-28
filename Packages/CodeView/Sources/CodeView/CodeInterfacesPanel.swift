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
final class CodeInterfacesPanel: CodeNavigatorTreePanel {
    /// One of the record's three lists, or the dependency expression: a
    /// row of the first level.
    final class GroupItem: CodeNavigatorTreeNode {
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
        var treeChildren: [AnyObject] { conditions ?? entries ?? [] }

        @MainActor convenience init(_ group: CodeInterfacesOutline.Group) {
            self.init(title: group.title, symbol: group.symbol, help: group.help,
                      entries: group.entries?.map(EntryItem.init), conditions: group.conditions?.map(ConditionItem.init))
        }
    }

    /// A row of the dependency expression: one condition — an interface by
    /// its name and GUID — or a group of them, a choice (`One of`) or what
    /// must all hold inside one, with its conditions a level under it.
    final class ConditionItem: CodeNavigatorTreeNode {
        let text: NSAttributedString
        let children: [ConditionItem]
        /// The GUID of a condition that names an interface: its row is one
        /// line with the GUID's mark, the GUID in its tooltip.
        let guid: String?
        /// What an interface's row opens to: what the GUID is, and where this
        /// module's code uses it.
        var details: [DetailItem]
        init(text: NSAttributedString, children: [ConditionItem] = [], guid: String? = nil,
             details: [DetailItem] = []) {
            self.text = text
            self.children = children
            self.guid = guid
            self.details = details
        }
        var isGroup: Bool { !children.isEmpty }
        /// A group's conditions, or what an interface's row opens to.
        var treeChildren: [AnyObject] { isGroup ? children : details }

        @MainActor convenience init(_ condition: CodeInterfacesOutline.Condition) {
            self.init(text: CodeNavigatorText.attributed(condition.text), children: condition.children.map(ConditionItem.init),
                      guid: condition.guid, details: condition.details.map(DetailItem.init))
        }
    }

    /// One interface: a row of the second level.
    final class EntryItem: CodeNavigatorTreeNode {
        let interface: ModuleInterfaces.Interface
        /// Grey after the name: reinstalls, handed over, required, optional.
        let marks: [String]
        let details: [DetailItem]
        init(interface: ModuleInterfaces.Interface, marks: [String], details: [DetailItem]) {
            self.interface = interface
            self.marks = marks
            self.details = details
        }
        var treeChildren: [AnyObject] { details }

        @MainActor convenience init(_ entry: CodeInterfacesOutline.Entry) {
            self.init(interface: entry.interface, marks: entry.marks, details: entry.details.map(DetailItem.init))
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

        @MainActor convenience init(_ detail: CodeInterfacesOutline.Detail) {
            self.init(text: CodeNavigatorText.attributed(detail.text), address: detail.address)
        }
    }

    let summaryLabel = NSTextField(labelWithString: "")
    private(set) var groups: [GroupItem] = [] {
        didSet { roots = groups }
    }

    /// A row with an address was chosen.
    var onChoose: ((CodeAddress) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.alignment = .center
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.init(240), for: .horizontal)

        setUpOutline(column: "interface")
        let scroll = outlineScroll

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
    func show(_ interfaces: ModuleInterfaces?, dependencies: DependencyOutline? = nil,
              registry: GuidRegistry = GuidRegistry(), place: (CodeAddress) -> String?) {
        groups = Self.groups(of: interfaces, dependencies: dependencies, registry: registry, place: place)
        outline.reloadData()
        // The kinds open; each interface closed, its name and marks a line.
        for group in groups { outline.expandItem(group) }
        // The expression open whole, its choices too; an interface in it
        // closed, as in the review's lists.
        openChoices(groups.flatMap { $0.conditions ?? [] })
        summaryLabel.stringValue = Self.summary(of: interfaces)
    }

    static func summary(of interfaces: ModuleInterfaces?) -> String {
        CodeInterfacesOutline.summary(of: interfaces)
    }

    /// The tab's rows, from the outline the model makes.
    static func groups(of interfaces: ModuleInterfaces?, dependencies: DependencyOutline? = nil,
                       registry: GuidRegistry = GuidRegistry(),
                       place: (CodeAddress) -> String?) -> [GroupItem] {
        CodeInterfacesOutline.groups(of: interfaces, dependencies: dependencies, registry: registry, place: place)
            .map(GroupItem.init)
    }

    /// The rows of a dependency expression.
    static func conditionItems(of outline: DependencyOutline) -> [ConditionItem] {
        CodeInterfacesOutline.conditions(of: outline).map(ConditionItem.init)
    }

    // MARK: - The tree

    /// A found line, a detail, wraps to the lines it needs.
    override var rowsWrap: Bool { true }

    /// An interface always opens: to what the review says of it, even when
    /// that is nothing yet.
    override func isExpandable(_ item: AnyObject) -> Bool {
        item is EntryItem || super.isExpandable(item)
    }

    /// Where a detail's text starts: under the interface's name.
    static var detailInset: CGFloat { detailInset(level: 2) }
    /// Where a detail at `level` of the tree starts: under the name of the
    /// interface it belongs to — one of a review's lists, or a condition of
    /// the expression however deep.
    static func detailInset(level: Int) -> CGFloat {
        entryInset + CGFloat(max(0, level - 2)) * CodeNavigatorCell.disclosureRoom
            + CodeNavigatorCell.disclosureRoom + 4
    }
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
            inset = Self.detailInset(level: outlineView.level(forItem: detail))
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
        return textCell(detail.text, inset: Self.detailInset(level: outlineView.level(forItem: detail)), in: outlineView)
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
        let opens = !condition.details.isEmpty
        cell.showsCalls(expandable: opens, expanded: opens && outlineView.isItemExpanded(condition))
        cell.onToggle = opens ? { [weak self] in self?.toggle(condition) } : nil
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
        cell.textField?.attributedStringValue = NSAttributedString(
            string: group.title + detail, attributes: CodeNavigatorCell.headingAttributes())
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

    /// Opens the choices and sets of conditions at any depth, leaving each
    /// interface in them closed.
    private func openChoices(_ conditions: [ConditionItem]) {
        for condition in conditions where condition.isGroup {
            outline.expandItem(condition)
            openChoices(condition.children)
        }
    }

    /// The expression opens whole: a choice is part of the condition, not a
    /// detail behind a second click.
    override func didOpen(_ item: AnyObject) {
        if let group = item as? GroupItem, let conditions = group.conditions {
            openChoices(conditions)
        }
    }

    /// A row chosen: an interface opens the code where the module supplies
    /// it, a detail with an address opens that place.
    override func choose(_ item: AnyObject) {
        if let entry = item as? EntryItem, let address = entry.details.lazy.compactMap(\.address).first {
            onChoose?(address)
        } else if let condition = item as? ConditionItem, let address = condition.details.lazy.compactMap(\.address).first {
            onChoose?(address)
        } else if let detail = item as? DetailItem, let address = detail.address {
            onChoose?(address)
        }
    }

    /// The kind's (?) right after its words: what the kind is, in the help.
    private static func putHelp(_ link: HelpLink, named name: String, in cell: CodeNavigatorCell) {
        cell.showsAccessory(HelpButton.inline(for: link, tooltip: name,
                                              pointSize: (CodePaneView.navigatorSize - 1).rounded()))
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
