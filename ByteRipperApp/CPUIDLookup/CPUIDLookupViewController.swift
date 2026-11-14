import Cocoa
import HelpUI
import IntelCPUID
import Localization

/// The Intel CPUID Lookup window's content: a search field, a line saying
/// what was found, the entry of a CPUID typed whole, and the models found.
///
/// The search is `CPUIDLookup`'s, built once per installed table; the field
/// offers completions as it is typed in (`CPUIDSuggestions`) and its last ten
/// searches in its menu (`SearchHistory`), kept between launches.
@MainActor
final class CPUIDLookupViewController: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource,
                                       NSTableViewDelegate, NSTextViewDelegate, NSMenuDelegate {
    /// Where the last searches are kept.
    static var defaults: UserDefaults = .standard
    static let historyKey = "CPUIDLookup.recentSearches"
    /// How long a query stands untouched before it counts as a search.
    static var rememberDelay: TimeInterval = 2

    let searchField = NSSearchField()
    let statusLabel = NSTextField(labelWithString: "")
    let headingView = NSTextView()
    let headingScroll = NSScrollView()
    let tableView = NSTableView()
    let tableScroll = NSScrollView()
    let sourceButton = NSButton()
    let help = HelpButton.standard(for: .topic(.cpuidLookup))
    let suggestions = CPUIDSuggestions()

    private(set) var lookup = CPUIDLookup(tables: .empty)
    /// The rows on screen, in the order shown.
    private(set) var shown: [CPUIDLookup.Row] = []
    private(set) var headings: [CPUIDLookup.Heading] = []
    /// Whether a refresh is under way: an empty table then reads "Loading…".
    private var refreshing = false
    /// The heading sections opened by hand — notes, sources — by key.
    private var opened: Set<String> = []
    private var headingHeight: NSLayoutConstraint!
    private var headingFills: NSLayoutConstraint!
    private var tablesWatch: NSObjectProtocol?
    private var rememberTimer: Timer?

    private enum Column: String, CaseIterable {
        case cpuid, model, sSpec, stepping, codeName

        var title: String {
            switch self {
            case .cpuid: return "CPUID"
            case .model: return L("Model")
            case .sSpec: return "S-SPEC"
            case .stepping: return L("Stepping")
            case .codeName: return L("Code name")
            }
        }

        var width: CGFloat {
            switch self {
            case .cpuid: return 110
            case .model: return 260
            case .sSpec: return 200
            case .stepping: return 110
            case .codeName: return 180
            }
        }
    }

    override func loadView() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 920, height: 640))

        searchField.placeholderString = L("CPUID, model or S-SPEC — 306A9, i7-2600K, SR00C")
        ControlHelp.describe(searchField, name: L("Search"),
                             tooltip: L("Search by CPUID, model, S-SPEC, code name or stepping"))
        searchField.font = .systemFont(ofSize: 15)
        searchField.controlSize = .large
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.maximumRecents = SearchHistory.limit
        searchField.searchMenuTemplate = historyMenu()
        searchField.recentSearches = history

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        headingView.isEditable = false
        headingView.isSelectable = true
        headingView.drawsBackground = false
        headingView.textContainerInset = NSSize(width: 4, height: 6)
        headingView.delegate = self
        headingView.isVerticallyResizable = true
        headingView.autoresizingMask = [.width]
        headingView.textContainer?.widthTracksTextView = true
        headingView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        headingScroll.documentView = headingView
        headingScroll.hasVerticalScroller = true
        headingScroll.autohidesScrollers = true
        headingScroll.borderType = .noBorder
        headingScroll.drawsBackground = false

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 60
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            tableView.addTableColumn(tableColumn)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = 22
        tableView.target = self
        tableView.doubleAction = #selector(lookUpClickedRow)
        tableView.autosaveName = "CPUIDLookupTable"
        tableView.autosaveTableColumns = true
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.autohidesScrollers = true

        sourceButton.title = "github.com/maxshevelev/IntelCPUID"
        sourceButton.isBordered = false
        sourceButton.contentTintColor = .linkColor
        sourceButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sourceButton.target = self
        sourceButton.action = #selector(openRepository)
        ControlHelp.describe(sourceButton, L("Open the repository the table is read from"))

        let footer = NSTextField(labelWithString: "")
        footer.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footerLabel = footer

        for view in [searchField, statusLabel, headingScroll, tableScroll, footer, sourceButton, help] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        headingHeight = headingScroll.heightAnchor.constraint(equalToConstant: 0)
        // Down to where the table would end, the table squeezed to nothing.
        headingFills = headingScroll.bottomAnchor.constraint(equalTo: help.topAnchor, constant: -14)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            statusLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),

            headingScroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            headingScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            headingScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            headingHeight,

            tableScroll.topAnchor.constraint(equalTo: headingScroll.bottomAnchor, constant: 4),
            tableScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: help.topAnchor, constant: -10),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            footer.centerYAnchor.constraint(equalTo: help.centerYAnchor),
            sourceButton.leadingAnchor.constraint(equalTo: footer.trailingAnchor, constant: 2),
            sourceButton.firstBaselineAnchor.constraint(equalTo: footer.firstBaselineAnchor),
            sourceButton.trailingAnchor.constraint(lessThanOrEqualTo: help.leadingAnchor, constant: -8),

            help.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            help.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        view = content

        suggestions.onPick = { [weak self] text in self?.pick(text) }
        tablesWatch = NotificationCenter.default.addObserver(
            forName: ProcessorTables.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tablesChanged() }
        }
        tablesChanged()
    }

    private var footerLabel: NSTextField?

    override func viewDidLayout() {
        super.viewDidLayout()
        fitHeading()
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: - The tables

    /// Asks the repository to check for a newer table; the answer comes back
    /// as `ProcessorTables.didChange`.
    func refreshTables() {
        refreshing = true
        render()
        Task { [weak self] in
            await ProcessorTables.refresh()
            self?.refreshing = false
            self?.render()
        }
    }

    private func tablesChanged() {
        lookup = CPUIDLookup(tables: ProcessorTables.current)
        render()
    }

    // MARK: - Searching

    var query: String { searchField.stringValue }

    @objc private func searchChanged() {
        // The menu's recent searches are kept here, not by the field.
        searchField.recentSearches = history
        render()
        showSuggestions()
        rememberSoon()
    }

    /// Puts `text` in the field and searches it, as a search of its own.
    func setQuery(_ text: String) {
        searchField.stringValue = text
        closeSuggestions()
        render()
        rememberQuery()
        tableView.scrollRowToVisible(0)
    }

    private func pick(_ text: String) {
        setQuery(text)
        focusSearch()
        searchField.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    }

    func render() {
        let words = CPUIDLookup.words(query)
        var rows = lookup.rows(matching: query)
        sort(&rows)
        shown = rows
        headings = lookup.headings(for: query)
        tableView.reloadData()

        let status: String
        if lookup.tables.isEmpty {
            status = refreshing
                ? L("Loading…")
                : L("The table has not been read yet. It is read from the repository when the network is available.")
        } else if words.isEmpty {
            status = L("%1$@ processors under %2$@ CPUIDs. Type to search.",
                       String(lookup.modelCount), String(lookup.cpuidCount))
        } else if rows.isEmpty, let heading = headings.first {
            status = heading.family == nil
                ? L("The table has no entry for this CPUID.")
                : L("No models are listed for this CPUID. What is known about it is above.")
        } else if rows.isEmpty {
            status = L("Nothing found. Check the spelling, or try part of the number.")
        } else {
            status = L("Found: %1$@", String(rows.count))
        }
        statusLabel.stringValue = status
        footerLabel?.stringValue = lookup.tables.retrieved.map { L("Updated %1$@. Data and sources:", $0) }
            ?? L("Data and sources:")

        let fills = !words.isEmpty && rows.isEmpty
        tableScroll.isHidden = fills
        headingView.textStorage?.setAttributedString(CPUIDHeadingText.make(headings, opened: opened,
                                                                           expanded: fills))
        headingScroll.isHidden = headings.isEmpty
        headingHeight.isActive = !fills
        headingFills.isActive = fills
        fitHeading()
    }

    /// The heading as tall as its text, up to two fifths of the window; the
    /// rest is the table's. With no table under it, it takes the window.
    private func fitHeading() {
        guard let headingHeight, !headingFills.isActive else { return }
        guard !headings.isEmpty, let container = headingView.textContainer,
              let layout = headingView.layoutManager else {
            headingHeight.constant = 0
            return
        }
        headingView.frame.size.width = headingScroll.contentSize.width
        layout.ensureLayout(for: container)
        let needed = ceil(layout.usedRect(for: container).height + headingView.textContainerInset.height * 2)
        headingHeight.constant = min(needed, max(80, view.bounds.height * 0.4))
    }

    private func sort(_ rows: inout [CPUIDLookup.Row]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key,
              let column = Column(rawValue: key) else { return }
        func value(_ row: CPUIDLookup.Row) -> String {
            switch column {
            case .cpuid: return row.cpuids.joined(separator: ", ")
            case .model: return row.name
            case .sSpec: return row.sSpecs.joined(separator: " ")
            case .stepping: return row.steppings
            case .codeName: return row.codeNames
            }
        }
        let ascending = descriptor.ascending
        rows = rows.enumerated().sorted { a, b in
            let order = value(a.element).localizedStandardCompare(value(b.element))
            if order == .orderedSame { return a.offset < b.offset }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }.map(\.element)
    }

    // MARK: - Completions

    private func showSuggestions() {
        guard let window = view.window, window.isKeyWindow,
              searchField.currentEditor() != nil else { return closeSuggestions() }
        suggestions.show(lookup.hints(for: query), under: searchField, query: query)
    }

    func closeSuggestions() { suggestions.close() }

    func controlTextDidEndEditing(_ obj: Notification) {
        closeSuggestions()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if !suggestions.isOpen { showSuggestions() } else { suggestions.move(by: 1) }
            return suggestions.isOpen
        case #selector(NSResponder.moveUp(_:)):
            guard suggestions.isOpen else { return false }
            suggestions.move(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let chosen = suggestions.chosen {
                pick(chosen)
            } else {
                closeSuggestions()
                rememberQuery()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape closes the completions first; the field clears itself
            // only when there are none.
            guard suggestions.isOpen else { return false }
            closeSuggestions()
            return true
        default:
            return false
        }
    }

    // MARK: - The last searches

    var history: [String] {
        get { Self.defaults.stringArray(forKey: Self.historyKey) ?? [] }
        set { Self.defaults.set(newValue, forKey: Self.historyKey) }
    }

    private func rememberSoon() {
        rememberTimer?.invalidate()
        rememberTimer = Timer.scheduledTimer(withTimeInterval: Self.rememberDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberQuery() }
        }
    }

    /// The query, as a search worth offering again — if it found anything.
    func rememberQuery() {
        rememberTimer?.invalidate()
        rememberTimer = nil
        guard !shown.isEmpty || !headings.isEmpty else { return }
        history = SearchHistory.remembering(query, in: history)
        searchField.recentSearches = history
    }

    private func historyMenu() -> NSMenu {
        let menu = NSMenu(title: L("Recent Searches"))
        let title = NSMenuItem(title: L("Recent Searches"), action: nil, keyEquivalent: "")
        title.tag = NSSearchField.recentsTitleMenuItemTag
        menu.addItem(title)
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.tag = NSSearchField.recentsMenuItemTag
        menu.addItem(item)
        let none = NSMenuItem(title: L("No Recent Searches"), action: nil, keyEquivalent: "")
        none.tag = NSSearchField.noRecentsMenuItemTag
        menu.addItem(none)
        let separator = NSMenuItem.separator()
        separator.tag = NSSearchField.recentsTitleMenuItemTag
        menu.addItem(separator)
        // Not the field's own clear item: the searches are kept here, and
        // the field's would clear only its copy of them.
        let clear = NSMenuItem(title: L("Clear Search History"), action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        return menu
    }

    @objc func clearHistory() {
        history = []
        searchField.recentSearches = []
    }

    // MARK: - The table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let column = Column(rawValue: id.rawValue) else { return nil }
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? CPUIDLookupCell
            ?? CPUIDLookupCell(identifier: id)
        let item = shown[row]
        switch column {
        case .cpuid:
            cell.show(item.cpuids.joined(separator: ", "), query: query, monospaced: true, bold: true)
        case .model:
            cell.show(item.name, query: query, suffix: item.series ? " (" + L("series") + ")" : nil)
        case .sSpec:
            if item.sSpecs.isEmpty {
                cell.show("—", query: "", muted: true)
            } else {
                cell.show(item.sSpecs.joined(separator: ", "), query: query, monospaced: true)
            }
        case .stepping:
            cell.show(item.steppings, query: query)
        case .codeName:
            cell.show(item.codeNames, query: query)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        render()
    }

    @objc private func lookUpClickedRow() {
        let row = tableView.clickedRow
        guard shown.indices.contains(row), let cpuid = shown[row].cpuids.first else { return }
        setQuery(cpuid)
    }

    /// The rows a menu command acts on: those selected, or the one clicked
    /// outside the selection.
    private var targetRows: [CPUIDLookup.Row] {
        let clicked = tableView.clickedRow
        let indexes = clicked >= 0 && !tableView.selectedRowIndexes.contains(clicked)
            ? IndexSet(integer: clicked) : tableView.selectedRowIndexes
        return indexes.filter { shown.indices.contains($0) }.map { shown[$0] }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let rows = targetRows
        guard !rows.isEmpty else { return }
        if rows.count == 1, let cpuid = rows[0].cpuids.first {
            let item = menu.addItem(withTitle: L("Look Up CPUID %1$@", cpuid),
                                    action: #selector(lookUpFromMenu(_:)), keyEquivalent: "")
            item.representedObject = cpuid
            item.target = self
            menu.addItem(.separator())
        }
        for (title, action) in [(L("Copy S-SPEC"), #selector(copySSpecs(_:))),
                                (L("Copy Model"), #selector(copyModels(_:))),
                                (L("Copy Row"), #selector(copy(_:)))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
    }

    @objc private func lookUpFromMenu(_ sender: NSMenuItem) {
        guard let cpuid = sender.representedObject as? String else { return }
        setQuery(cpuid)
    }

    /// Edit ▸ Copy: the rows as lines of tab-separated columns, in the order
    /// the table shows them.
    @objc func copy(_ sender: Any?) {
        put(targetRows.map { row in
            [row.cpuids.joined(separator: ", "), row.name, row.sSpecs.joined(separator: ", "),
             row.steppings, row.codeNames].joined(separator: "\t")
        })
    }

    @objc private func copySSpecs(_ sender: Any?) {
        put(targetRows.map { $0.sSpecs.joined(separator: ", ") }.filter { !$0.isEmpty })
    }

    @objc private func copyModels(_ sender: Any?) {
        put(targetRows.map(\.name))
    }

    private func put(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !targetRows.isEmpty }
        if item.action == #selector(clearHistory) { return !history.isEmpty }
        return true
    }

    // MARK: - The heading's links

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        switch url.scheme {
        case CPUIDHeadingText.lookUpScheme:
            setQuery(CPUIDHeadingText.argument(of: url))
            return true
        case CPUIDHeadingText.toggleScheme:
            let key = CPUIDHeadingText.argument(of: url)
            if opened.contains(key) { opened.remove(key) } else { opened.insert(key) }
            render()
            return true
        default:
            return false   // a source's page: the browser opens it
        }
    }

    @objc private func openRepository() {
        NSWorkspace.shared.open(URL(string: "https://github.com/maxshevelev/IntelCPUID")!)
    }
}
