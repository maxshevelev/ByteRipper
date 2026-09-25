import ALSplitView
import AppKit
import HelpBook

/// The help window: the contents on the left, the page on the right.
///
/// One window for the whole app, and a *utility* one — it floats over the
/// windows it explains and never takes the document's place. That is the shape
/// a bench needs: the dump stays visible while the page about it is read.
///
/// It is not modal and it is not a sheet. A sheet would pin the help to one
/// window and block it; a modal panel would stop you doing the thing the page
/// is describing while you read it.
@MainActor public final class HelpWindowController: NSWindowController {
    private let book: HelpBook
    private var rows: [HelpOutlineRow] = []
    /// The rows the list is showing: the contents, or the hits of a search.
    private var shown: [HelpOutlineRow] = []
    /// Where the reader has been, so Back goes back. Bounded at a few dozen —
    /// a help window is not a browser, and an unbounded list is a leak with a
    /// polite name.
    private var history: [HelpLink] = []
    private var future: [HelpLink] = []
    private var current: HelpLink?
    /// True while a selection the code made is being applied — without it,
    /// selecting a row would publish a navigation that selects the row again.
    private var isNavigating = false

    private let outline = NSOutlineView()
    private let outlineScroll = NSScrollView()
    private let searchField = NSSearchField()
    private let body = HelpBodyView()
    private let splitter = ALSplitView()
    private let backForward = NSSegmentedControl(
        images: [
            NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
            NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!
        ],
        trackingMode: .momentary, target: nil, action: nil
    )

    private static let sidebarWidth: CGFloat = 240
    private static let column = NSUserInterfaceItemIdentifier("title")

    public init(book: HelpBook = Help.shared) {
        self.book = book
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "ByteRipper Help"
        window.minSize = NSSize(width: 620, height: 400)
        // Closed and reopened, not rebuilt: the reader's place in the book is
        // worth keeping across a close, and a released window would lose it.
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("HelpWindow")
        super.init(window: window)
        window.contentView = makeContent()
        rows = HelpOutlineModel.build(from: book, glossaryNames: book.glossaryNames)
        shown = rows
        outline.reloadData()
        // The first group open, the rest shut: the contents should read as a
        // list of subjects, not as forty page titles.
        if let first = shown.first { outline.expandItem(first) }
        show(.topic(.overview), record: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Showing a page

    /// Opens `link`, selects its row in the contents, and records where the
    /// reader was so Back can return there.
    public func show(_ link: HelpLink, record: Bool = true) {
        guard let content = render(link) else { return }
        if record, let current, current != link {
            history.append(current)
            if history.count > 50 { history.removeFirst() }
            future.removeAll()
        }
        current = link
        body.show(content)
        selectRow(for: link)
        updateBackForward()
    }

    /// The window, open, in front, with `link` shown. The one door the app and
    /// the panels use.
    public func reveal(_ link: HelpLink) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        show(link)
    }

    private func render(_ link: HelpLink) -> NSAttributedString? {
        switch link {
        case .topic(let id): return book.topic(id).map(HelpText.render)
        case .term(let id): return book.term(id).map(HelpText.render)
        }
    }

    /// What the window is showing, for the tests.
    public var shownLink: HelpLink? { current }
    public var shownText: String { body.shownText }

    // MARK: - Building

    private func makeContent() -> NSView {
        let root = NSView()

        searchField.placeholderString = "Search Help"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        // Fires on every keystroke rather than only on Return: the book is
        // small enough to filter live, and a reader who has to press Return to
        // find out there are no hits has paid for nothing.
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        backForward.segmentCount = 2
        backForward.target = self
        backForward.action = #selector(backForwardClicked)
        backForward.setToolTip("Back", forSegment: 0)
        backForward.setToolTip("Forward", forSegment: 1)
        backForward.translatesAutoresizingMaskIntoConstraints = false

        configureOutline()
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.autohidesScrollers = true
        outlineScroll.drawsBackground = false
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(searchField)
        sidebar.addSubview(outlineScroll)
        // Breakable, for the reason every pane's insets in this app are: a
        // split pane is laid out by frame and its first size is nothing at all,
        // which required margins cannot be satisfied in.
        let sideInsets = [
            searchField.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10)
        ]
        sideInsets.forEach { $0.priority = .defaultHigh }
        NSLayoutConstraint.activate(sideInsets + [
            searchField.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 10),
            outlineScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            outlineScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            outlineScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            outlineScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
        ])

        let page = NSView()
        page.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(backForward)
        page.addSubview(body)
        NSLayoutConstraint.activate([
            backForward.topAnchor.constraint(equalTo: page.topAnchor, constant: 10),
            backForward.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 20),
            body.topAnchor.constraint(equalTo: backForward.bottomAnchor, constant: 6),
            body.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: page.bottomAnchor)
        ])

        body.onFollow = { [weak self] link in self?.show(link) }

        splitter.isVertical = true
        splitter.dividerThickness = 1
        splitter.translatesAutoresizingMaskIntoConstraints = false
        splitter.addPane(sidebar)
        splitter.addPane(page)
        // The contents keeps its width and the page takes the rest: a window
        // widened to read a long page should widen the prose, not the list of
        // titles beside it.
        splitter.setPaneLayout(.fixed(Self.sidebarWidth), at: 0)
        splitter.setPaneLayout(.fill, at: 1)

        root.addSubview(splitter)
        NSLayoutConstraint.activate([
            splitter.topAnchor.constraint(equalTo: root.topAnchor),
            splitter.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitter.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitter.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        return root
    }

    private func configureOutline() {
        let column = NSTableColumn(identifier: Self.column)
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 14
        outline.style = .sourceList
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
    }

    // MARK: - Selection and history

    private func selectRow(for link: HelpLink) {
        guard let row = HelpOutlineModel.row(for: link, in: shown) else { return }
        isNavigating = true
        defer { isNavigating = false }
        expandParents(of: row)
        let index = outline.row(forItem: row)
        guard index >= 0 else { return }
        outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        outline.scrollRowToVisible(index)
    }

    /// Opens whichever group holds `row`, so a jump from a `?` button lands on
    /// a row the reader can see rather than inside a shut section.
    private func expandParents(of row: HelpOutlineRow) {
        for group in shown where group.children.contains(where: { $0 === row }) {
            outline.expandItem(group)
        }
    }

    private func updateBackForward() {
        backForward.setEnabled(!history.isEmpty, forSegment: 0)
        backForward.setEnabled(!future.isEmpty, forSegment: 1)
    }

    @objc private func backForwardClicked() {
        switch backForward.selectedSegment {
        case 0: goBack()
        default: goForward()
        }
    }

    public func goBack() {
        guard let previous = history.popLast() else { return }
        if let current { future.append(current) }
        show(previous, record: false)
    }

    public func goForward() {
        guard let next = future.popLast() else { return }
        if let current { history.append(current) }
        show(next, record: false)
    }

    // MARK: - Searching

    @objc private func searchChanged() {
        let query = searchField.stringValue
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            shown = rows
            outline.reloadData()
            if let first = shown.first { outline.expandItem(first) }
            if let current { selectRow(for: current) }
            return
        }
        // The hits as one flat group, because a search's answer is a list of
        // results and not a shape of the book.
        let hits = book.search(query).map { result -> HelpOutlineRow in
            switch result {
            case .topic(let topic): return HelpOutlineRow(kind: .topic(topic))
            case .term(let term): return HelpOutlineRow(kind: .term(term))
            }
        }
        let title = hits.isEmpty ? "No results" : "\(hits.count) result\(hits.count == 1 ? "" : "s")"
        shown = [HelpOutlineRow(kind: .group(title), children: hits)]
        outline.reloadData()
        if let group = shown.first { outline.expandItem(group) }
    }

    /// What the list is showing, for the tests that drive the search field.
    public var listedTitles: [String] {
        shown.flatMap { [$0.title] + $0.children.map(\.title) }
    }

    /// Types into the search field the way a user does, for tests.
    public func search(_ query: String) {
        searchField.stringValue = query
        searchChanged()
    }
}

extension HelpWindowController: NSOutlineViewDataSource {
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let row = item as? HelpOutlineRow else { return shown.count }
        return row.children.count
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let row = item as? HelpOutlineRow else { return shown[index] }
        return row.children[index]
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? HelpOutlineRow).map { !$0.children.isEmpty } ?? false
    }
}

extension HelpWindowController: NSOutlineViewDelegate {
    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                            item: Any) -> NSView? {
        guard let row = item as? HelpOutlineRow else { return nil }
        let label = NSTextField(labelWithString: row.title)
        label.lineBreakMode = .byTruncatingTail
        label.font = row.isGroup
            ? .systemFont(ofSize: 11, weight: .semibold)
            : .systemFont(ofSize: 12)
        label.textColor = row.isGroup ? .secondaryLabelColor : .labelColor
        let cell = NSTableCellView()
        cell.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    /// A group is a heading, not a destination: it opens and shuts rather than
    /// showing a page of its own.
    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? HelpOutlineRow)?.isGroup == false
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isNavigating,
              let row = outline.item(atRow: outline.selectedRow) as? HelpOutlineRow,
              let link = row.link
        else { return }
        show(link)
    }
}
