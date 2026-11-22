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
        /// Text under the group itself, in place of interfaces: the
        /// dependency expression. Nil for the review's lists.
        let lines: [DetailItem]?
        init(title: String, symbol: String, help: HelpLink, entries: [EntryItem]?, lines: [DetailItem]? = nil) {
            self.title = title
            self.symbol = symbol
            self.help = help
            self.entries = entries
            self.lines = lines
        }

        /// Rows under it.
        var children: [Any] { lines ?? entries ?? [] }
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
    func show(_ interfaces: ModuleInterfaces?, dependencies: String? = nil, place: (CodeAddress) -> String?) {
        groups = Self.groups(of: interfaces, dependencies: dependencies, place: place)
        outline.reloadData()
        // The kinds open; each interface closed, its name and marks a line.
        for group in groups { outline.expandItem(group) }
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

    static func groups(of interfaces: ModuleInterfaces?, dependencies: String? = nil,
                       place: (CodeAddress) -> String?) -> [GroupItem] {
        func entries(_ list: [ModuleInterfaces.Interface]?,
                     marks: (ModuleInterfaces.Interface) -> [String]) -> [EntryItem]? {
            list?.map { EntryItem(interface: $0, marks: marks($0), details: details(of: $0, place: place)) }
        }
        // The condition the dispatcher starts the module on, from its
        // firmware file: the PPIs or protocols it waits for, by name.
        var depex: [GroupItem] = []
        if let dependencies {
            let text = NSAttributedString(string: dependencies, attributes: [
                .font: CodePaneView.navigatorFont(), .foregroundColor: NSColor.labelColor
            ])
            depex.append(GroupItem(title: L("Dependency expression"), symbol: "flowchart",
                                   help: .term(HelpTermID("depex")), entries: nil,
                                   lines: dependencies.isEmpty ? [] : [DetailItem(text: text)]))
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
        return (item as? EntryItem)?.details.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return groups[index] }
        if let group = item as? GroupItem { return group.children[index] }
        return (item as! EntryItem).details[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let group = item as? GroupItem { return !group.children.isEmpty }
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
        guard let detail = item as? DetailItem else { return row }
        let column = outlineView.numberOfColumns > 0 ? outlineView.rect(ofColumn: 0).width : outlineView.bounds.width
        let width = max(40, column - Self.detailInset - Self.detailTrailing - 4)
        let measured = detail.text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return max(row - 4, ceil(measured) + 2 * Self.detailPadding)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        if let group = item as? GroupItem { return groupCell(group, in: outlineView) }
        if let entry = item as? EntryItem { return entryCell(entry, in: outlineView) }
        guard let detail = item as? DetailItem else { return nil }
        let id = NSUserInterfaceItemIdentifier("detail-\(CodePaneView.navigatorSize)")
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
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Self.detailInset),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Self.detailTrailing),
                text.topAnchor.constraint(equalTo: cell.topAnchor, constant: Self.detailPadding)
            ])
            return cell
        }()
        (cell.textField as? InterfacesDetailField)?.show(detail.text)
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
        cell.showsSymbol(group.symbol)
        let line = NSMutableAttributedString(string: group.title, attributes: [
            .font: CodePaneView.navigatorBoldFont(), .foregroundColor: NSColor.labelColor
        ])
        let detail: String = if let lines = group.lines { lines.isEmpty ? L("None") : "" } else {
            switch group.entries {
            case nil: L("Not recorded yet")
            case let list? where list.isEmpty: L("None")
            case let list?: String(list.count)
            }
        }
        line.append(NSAttributedString(string: " " + detail, attributes: [
            .font: CodePaneView.navigatorFont(), .foregroundColor: NSColor.secondaryLabelColor
        ]))
        cell.textField?.attributedStringValue = line
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
        cell.showsSymbol(entry.interface.kind == .ppi ? "puzzlepiece.extension" : "puzzlepiece")
        cell.indent = Self.entryInset
        let line = NSMutableAttributedString(string: entry.interface.name, attributes: [
            .font: CodePaneView.navigatorBoldFont(), .foregroundColor: NSColor.labelColor
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

    func outlineViewItemDidExpand(_ notification: Notification) { redrawChevron(notification) }
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
