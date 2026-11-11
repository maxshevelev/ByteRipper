import ALSplitView
import AppPalette
import AppKit
import FITTool
import HelpUI
import Localization
import ToolModuleKit

/// The panel: the table's entries above, what is wrong with them below.
///
/// It decides nothing. Everything on screen comes from one `show(_:focus:canWrite:)`
/// over a `FITDisplay` built and tested in the pure target, so the list and the
/// outlines in the dump are one state rather than two copies of it.
@MainActor final class FITToolViewController: NSViewController {
    var onSelect: ((Int?) -> Void)?
    /// A click is about to choose a row: a step for the window's navigation
    /// history, taken before the choice changes. The arrow keys are not.
    var onWillChoose: (() -> Void)?

    /// The entries take the keyboard (`ToolSession.focusChoice`).
    func focusEntries() {
        view.window?.makeFirstResponder(entries)
    }
    var onGoToTarget: ((Int) -> Void)?
    var onSelectTable: (() -> Void)?
    var onReplaceMicrocode: ((Int) -> Void)?
    var onRemoveMicrocode: ((Int) -> Void)?
    var onAddMicrocode: (() -> Void)?
    var onGoToProblem: ((Int) -> Void)?
    var onFixChecksum: (() -> Void)?

    private(set) var display = FITDisplay.empty
    /// What the last `show` was allowed to do. Kept so the button and the menu
    /// items can come back exactly as they were once a parse that stood them
    /// down is done.
    private var canWrite = false
    /// True while a parse runs. The modification controls stand down for the
    /// whole of it — a parse reads a snapshot of the file as it is now, so
    /// letting an edit race it would make the bar a lie and the two sides of
    /// the panel disagree.
    private var busy = false

    /// What the detail on screen describes, kept so its rows can be rebuilt at
    /// a new type size without waiting for the next parse — a zoom is not a
    /// re-read.
    private var detailSubject = ""

    /// True while the tables are being loaded from the model — a selection the
    /// code made is not news, and without this the panel selects, publishes,
    /// re-shows and selects again until the stack runs out.
    private var isShowingState = false

    /// The entries, as an outline: a microcode row opens into a plate of the
    /// CPUIDs it is for, and a CPUID's `ⓘ` lists the processors behind it
    /// (`FITProcessorsPopover`).
    let entries = FITEntriesOutlineView()
    /// The outline's rows, rebuilt with every `show`. NSOutlineView knows a
    /// row by the identity of its item, so the items live here between calls.
    private var topItems: [FITOutlineItem] = []
    private var itemsByKind: [FITOutlineItem.Kind: FITOutlineItem] = [:]
    private var childItems: [FITOutlineItem.Kind: [FITOutlineItem]] = [:]
    /// The rows the reader has opened — kept across a re-read, a zoom and an
    /// edit, which rebuild the items.
    private var expandedKinds: Set<FITOutlineItem.Kind> = []
    /// The entries the panel has shown before. One it has not is opened a
    /// level, so its CPUIDs are on screen without a click; one the reader has
    /// closed stays closed.
    private var seenEntries: Set<FITOutlineItem.Kind> = []
    /// Whether the show on hand is the same table again — kept items, kept
    /// scroll — rather than a new one (`rebuildItems`).
    private var keepsScroll = false
    /// The popover a CPUID's `ⓘ` opened, kept so the next one closes it.
    /// Weak: a closed popover lets go of itself (`HelpPopoverController`).
    weak var processorsPopover: FITProcessorsPopover?

    let problems = NSTableView()
    private let entriesScroll = NSScrollView()
    private let problemsScroll = NSScrollView()
    /// The entries and their legend, as one pane of the splitter: the legend
    /// explains the rows, and opens into the table's room rather than the
    /// detail's (`Design/ROW_MARKS.md` §6).
    private let entriesPane = NSView()
    let legend = ToolRowMarksLegend(panel: "FIT", marks: FITRowMarks.legendMarks)
    private static let rowViewIdentifier = NSUserInterfaceItemIdentifier("fitRow")
    /// The detail list in its pane, and the large view Space opens it into.
    let detailPane = ToolDetailPane()
    private var detail: ToolDetailScroll { detailPane.detail }
    private let splitter = ALSplitView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let noticeLabel = NSTextField(labelWithString: "")
    /// The row at the foot of the panel: the notice, and the parse's progress bar on
    /// the same line while one runs — the module's own status line carries its
    /// progress rather than a second strip appearing below it.
    private let bottomRow = NSStackView()
    private let progressBar = NSProgressIndicator()
    private let addButton = NSButton()
    /// The problems list is as tall as its content, capped at half the height
    /// of the entries.
    private var problemsRatio: NSLayoutConstraint?
    private var problemsContent: NSLayoutConstraint?
    /// The panel draws at the app's zoom (`ToolPanelFont`); this is what tells
    /// it the zoom moved.
    private var zoomObserver: NSObjectProtocol?

    private enum Column {
        static let type = NSUserInterfaceItemIdentifier("type")
        static let problem = NSUserInterfaceItemIdentifier("problem")
    }

    /// The one column, with the width it was laid out at — a width for text
    /// at `ToolPanelFont.designSize`, so the panel scales it to whatever size
    /// the zoom is at. It says the entry's type and, after it, what the entry
    /// points at; it takes the panel's width, and only below `minWidth` does
    /// the table scroll sideways.
    ///
    /// No row number, no address and no size: all three are in the detail.
    private static let entryColumns:
    [(id: NSUserInterfaceItemIdentifier, title: String, width: CGFloat, minWidth: CGFloat)] = [
        (Column.type, L("Type"), 300, 80)
    ]
    /// The columns that give way once the last one is down to its floor —
    /// none, with one column.
    private static let yieldingColumns: [NSUserInterfaceItemIdentifier] = []
    /// The width each yielding column was given — by the design, a zoom or a
    /// drag — before a narrow panel squeezed it.
    private var wantedWidths: [NSUserInterfaceItemIdentifier: CGFloat] = [:]
    /// Set while the panel moves the columns itself, so what it does is not
    /// taken for a drag.
    private var isFittingColumns = false
    private static let problemColumnWidth: CGFloat = 420
    /// How many findings the list shows before it scrolls. Past this it is a
    /// list to scroll through, and the table above is what the panel is for.
    private static let maxProblemRows = 8

    /// The size the widths on screen were scaled for. A zoom moves them by
    /// what has changed since, so a column the user dragged keeps the width
    /// they gave it rather than snapping back to the design's.
    private var columnWidthSize = ToolPanelFont.designSize

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 500))
        view.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = ToolPanelFont.body(weight: .medium)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        // The title names the table; clicking it takes the dump there and puts
        // the whole table in focus rather than a row.
        summaryLabel.toolTip = L("Show the whole table in the dump")
        summaryLabel.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(summaryClicked))
        )

        configure(entries, doubleAction: #selector(entryDoubleClicked))
        // The table keeps inside its scroll view, as the UEFI and ME trees do:
        // wider than it, the inset style's margins and rounded selection
        // scroll off the edges and the rows run edge to edge. The one column
        // takes whatever width the panel gives, down to a floor — and only
        // below that does the table scroll sideways. A cut-short row still
        // says the whole of it under the pointer.
        entries.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for spec in Self.entryColumns {
            column(entries, spec.id, spec.title, spec.width, minWidth: spec.minWidth,
                   resizesWithTable: spec.id == Column.type)
        }
        for id in Self.yieldingColumns {
            wantedWidths[id] = entries.tableColumn(withIdentifier: id)?.width
        }
        // The arrow leads the row, as in the UEFI tree, and the levels under
        // it are indented under their microcode.
        entries.outlineTableColumn = entries.tableColumn(withIdentifier: Column.type)
        entries.indentationPerLevel = 16
        // The column is the panel's width, and an opened level is indented
        // inside it — not added to it, which would push the table past the
        // panel's edge the moment a microcode opens.
        entries.autoresizesOutlineColumn = false
        entriesScroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(entriesClipResized),
            name: NSView.frameDidChangeNotification, object: entriesScroll.contentView
        )
        entries.menu = contextMenu()

        configure(problems, doubleAction: #selector(problemDoubleClicked))
        problems.headerView = nil
        // A list of findings is read, not picked from: the double-click reads
        // the row under the pointer, and nothing else acts on a selection — so
        // a highlighted row would be a selection that means nothing.
        problems.selectionHighlightStyle = .none
        // Plain, not inset: the inset style pads its rows away from the edge
        // and rounds the selection, and this list is a strip of lines under
        // the table rather than a table of its own.
        problems.style = .plain
        column(problems, Column.problem, L("Problem"), Self.problemColumnWidth)

        // The rows, the headers and the widths — laid out just above for text
        // at `ToolPanelFont.designSize` — follow the app's zoom, so this comes
        // after the columns exist rather than with the rest of a table's setup.
        ToolPanelTable.apply(to: entries)
        ToolPanelTable.apply(to: problems)
        applyColumnWidths()

        for (scroll, table) in [(entriesScroll, entries), (problemsScroll, problems)] {
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .bezelBorder
            scroll.translatesAutoresizingMaskIntoConstraints = false
        }
        // No frame around the findings: a box that hugs one line reads as an
        // empty box with a line in it, and there is nothing below it to be
        // told apart from.
        problemsScroll.borderType = .noBorder

        // Top: the entries. Bottom: the detail for the row in focus. The
        // divider is the user's to move. `ALSplitView` places its panes by
        // frame from its own bounds, so the third the detail starts with is a
        // policy rather than a position measured off a view that has not been
        // laid out yet.
        splitter.isVertical = false
        splitter.dividerThickness = 1
        splitter.translatesAutoresizingMaskIntoConstraints = false
        entriesPane.translatesAutoresizingMaskIntoConstraints = false
        // The list over its legend, with the legend's edges breakable against
        // a pane that is still zero-sized while the panel opens.
        legend.install(below: entriesScroll, in: entriesPane)
        legend.onShowMarkingsChanged = { [weak self] _ in self?.updateRowMarks() }
        splitter.addPane(entriesPane)
        splitter.addPane(detailPane)
        detailPane.attach(to: entries)
        splitter.setPaneLayout(.fill, at: 0)
        splitter.setPaneLayout(.proportional(1.0 / 3), at: 1)

        func button(_ button: NSButton, _ title: String, _ action: Selector, _ tip: String) {
            button.title = title
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
            ControlHelp.describe(button, tip)
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        // Remove and Fix Checksum are not buttons: they are offered where they
        // apply, in the row's menu, rather than on a bar that is always there.
        // Add is a row of the table, under the last microcode — where what it
        // adds will go (`addMicrocodeCell`).
        button(addButton, L("Add Microcode…"), #selector(addMicrocodeClicked),
               L("Put a microcode in the image and name it in the table"))

        noticeLabel.font = ToolPanelFont.body()
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.lineBreakMode = .byWordWrapping
        noticeLabel.maximumNumberOfLines = 2
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        // The bar takes its width and the notice gives way: while a parse runs
        // the notice is one short sentence, and there is no bar when it is not.
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The reading's bar, not in the row yet — a session puts it there with
        // `showBusy()` and takes it away with `endBusy()`, so the notice owns
        // the whole row the rest of the time. Indeterminate: what the panel
        // waits for is the tree opening the branches its rows point into, and
        // that is a handful of chains rather than a fraction of the image.
        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.controlSize = .small
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 8
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        bottomRow.addArrangedSubview(noticeLabel)

        view.addSubview(summaryLabel)
        view.addSubview(splitter)
        view.addSubview(problemsScroll)
        view.addSubview(bottomRow)

        // As tall as its rows — capped at eight of them by
        // `problemListHeight`, and at half the splitter's height here — and no
        // height at all when there is nothing to say: an empty box under a
        // table that checks out is a box the user has to work out the meaning
        // of. The panel cap is on the splitter, not on the entries scroll
        // inside it: a constraint that reaches into a split view's subview
        // fights the split view's own layout and is how the detail below loses
        // its height.
        let ratio = problemsScroll.heightAnchor.constraint(
            lessThanOrEqualTo: splitter.heightAnchor, multiplier: 0.5
        )
        problemsRatio = ratio
        let content = problemsScroll.heightAnchor.constraint(equalToConstant: 0)
        content.priority = .defaultHigh
        problemsContent = content
        let bottom = bottomRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        // Breakable, for the reason the panel's own insets are (§19.2): a panel
        // squeezed to nothing is a legal state, and this chain must give way
        // there rather than log a conflict against the header's height.
        bottom.priority = .defaultHigh
        // The bar keeps this width while the notice wraps around it; high, not
        // required, so a row squeezed very narrow gives the bar up first.
        let barWidth = progressBar.widthAnchor.constraint(equalToConstant: 150)
        barWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            summaryLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            summaryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            splitter.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 6),
            splitter.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            splitter.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            splitter.bottomAnchor.constraint(
                equalTo: problemsScroll.topAnchor, constant: -6
            ),

            // Full width and flush with the panel's edges: without a frame
            // there is nothing for an inset to hold away from anything.
            problemsScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            problemsScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            problemsScroll.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -6),
            ratio, content,


            bottomRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            bottomRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            bottom,
            barWidth
        ])

        zoomObserver = ToolPanelFont.observeZoom { [weak self] in
            self?.applyPanelFont()
        }
    }

    deinit {
        if let zoomObserver {
            NotificationCenter.default.removeObserver(zoomObserver)
        }
    }

    /// Re-reads the panel's type size and puts everything on screen at it: the
    /// two lines around the tables, both tables' rows and headers, and the
    /// detail's own rows — which are drawn in the font they were built with,
    /// so they have to be rebuilt rather than restyled. The problem list is as
    /// tall as its rows, so its height is re-measured at the new row height.
    private func applyPanelFont() {
        summaryLabel.font = ToolPanelFont.body(weight: .medium)
        noticeLabel.font = ToolPanelFont.body()
        ToolPanelTable.apply(to: entries)
        ToolPanelTable.apply(to: problems)
        applyColumnWidths()
        reloadEntries()
        problems.reloadData()
        renderDetail(display.detail, subject: detailSubject)
        if !display.problems.isEmpty {
            problemsContent?.constant = problemListHeight()
        }
    }

    // MARK: - A parse's progress

    /// A parse is running: the bar joins the row at the foot of the panel, and the
    /// one button — Add — stands down for the whole of it, with the menu items
    /// that modify the table (Remove Microcode, Fix Checksum) standing down
    /// beside it. A parse reads a snapshot of the file as it is *now*, so an
    /// edit that slipped in while it ran would make the bar a lie and the
    /// panel's next re-read the two of them disagreeing.
    ///
    /// The notice is left alone — `start()` has said "Reading…" and a re-read
    /// that follows an edit must not wipe the note the edit just earned — so
    /// this is only ever a bar appearing beside text, never a second line.
    func showBusy() {
        busy = true
        updateButtons()
        guard progressBar.superview == nil else { return }
        bottomRow.addArrangedSubview(progressBar)
        progressBar.startAnimation(nil)
    }

    /// The reading is done: the bar leaves the row and the button comes back as
    /// the last reading said they should.
    func endBusy() {
        busy = false
        updateButtons()
        guard progressBar.superview != nil else { return }
        progressBar.stopAnimation(nil)
        bottomRow.removeArrangedSubview(progressBar)
        progressBar.removeFromSuperview()
    }

    /// What the one button is allowed to do right now. While a parse runs it
    /// stands down — the menu items that modify the table stand down with it,
    /// in `menuNeedsUpdate` — otherwise it follows the reading on show:
    /// nothing to add when the table is empty.
    private func updateButtons() {
        addButton.isEnabled = !busy && canWrite && !display.rows.isEmpty
    }

    private func configure(_ table: NSTableView, doubleAction: Selector) {
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        // The column order is the design's, not a drag target.
        table.allowsColumnReordering = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = doubleAction
    }

    private func column(
        _ table: NSTableView,
        _ identifier: NSUserInterfaceItemIdentifier,
        _ title: String,
        _ width: CGFloat,
        minWidth: CGFloat? = nil,
        resizesWithTable: Bool = false
    ) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        if let minWidth {
            column.resizingMask = resizesWithTable ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            column.minWidth = minWidth
        }
        table.addTableColumn(column)
    }

    @objc private func entriesClipResized(_ notification: Notification) {
        fitColumnsToThePanel()
    }

    /// The last column takes the width the others leave; below its floor,
    /// the yielding columns give way down to theirs, and get it back with room
    /// again. With one column, it is the panel's width down to its floor.
    private func fitColumnsToThePanel() {
        guard !isFittingColumns, let target = entries.tableColumn(withIdentifier: Column.type),
              entriesScroll.contentView.bounds.width > 0
        else { return }
        isFittingColumns = true
        defer { isFittingColumns = false }

        entries.sizeLastColumnToFit()
        // The frame is the columns' only once the table has tiled again: until
        // then it is the width it had before the panel moved.
        entries.tile()
        let clip = entriesScroll.contentView.bounds.width
        var overflow = entries.frame.width - clip
        for id in Self.yieldingColumns where overflow > 0.5 {
            guard let column = entries.tableColumn(withIdentifier: id) else { continue }
            let give = min(overflow, column.width - column.minWidth)
            guard give > 0 else { continue }
            column.width -= give
            overflow -= give
        }
        if overflow <= 0.5 {
            var slack = target.width - target.minWidth
            for id in Self.yieldingColumns.reversed() where slack > 0.5 {
                guard let column = entries.tableColumn(withIdentifier: id) else { continue }
                let take = min(slack, (wantedWidths[id] ?? column.width) - column.width)
                guard take > 0 else { continue }
                column.width += take
                slack -= take
            }
        }
        entries.sizeLastColumnToFit()
    }

    func outlineViewColumnDidResize(_ notification: Notification) {
        tableViewColumnDidResize(notification)
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard !isFittingColumns, notification.object as AnyObject? === entries,
              let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              Self.yieldingColumns.contains(column.identifier)
        else { return }
        // A drag: the width the reader chose is the one to come back to.
        wantedWidths[column.identifier] = column.width
    }

    /// Moves the columns to the size on screen — the widths grow and shrink
    /// with the type, since a column that does not is a column whose text no
    /// longer fits it.
    private func applyColumnWidths() {
        let size = ToolPanelFont.size
        guard size != columnWidthSize else { return }
        let ratio = size / columnWidthSize
        isFittingColumns = true
        ToolPanelTable.scaleColumnWidths(of: entries, by: ratio)
        ToolPanelTable.scaleColumnWidths(of: problems, by: ratio)
        for (id, width) in wantedWidths { wantedWidths[id] = (width * ratio).rounded() }
        isFittingColumns = false
        columnWidthSize = size
        fitColumnsToThePanel()
    }

    /// Everything the panel shows, in one call.
    func show(_ display: FITDisplay, focus: Int?, canWrite: Bool) {
        // A choice moves the focus, the zones and the detail, and nothing in
        // the table: the same rows, the same backup, the same problems. Then
        // the tree is left as it is — rebuilding it for a click was work for
        // nothing, and moved the table under the reader.
        let sameTable = display.rows == self.display.rows
            && display.backupStart == self.display.backupStart
            && display.backupHeading == self.display.backupHeading
            && display.problems == self.display.problems
        self.display = display
        self.canWrite = canWrite
        isShowingState = true
        defer { isShowingState = false }

        summaryLabel.stringValue = display.summary
        if !sameTable {
            rebuildItems()
            reloadEntries()
            updateRowMarks()
            problems.reloadData()
        }
        renderDetail(display.detail, subject: focus.map(String.init) ?? "")
        if let focus, let row = tableRow(of: .entry(focus)) {
            entries.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            entries.deselectAll(nil)
        }
        updateButtons()

        let hasProblems = !display.problems.isEmpty
        problemsScroll.isHidden = !hasProblems
        problemsContent?.constant = hasProblems ? problemListHeight() : 0
    }

    /// Rebuilds the detail list from the fields the pure target decided.
    private func renderDetail(_ rowDetail: FITRowDetail, subject: String) {
        detailSubject = subject
        guard !rowDetail.fields.isEmpty else {
            detail.showPlaceholder(rowDetail.title.isEmpty
                ? L("Select a row to see what it is.")
                : rowDetail.title)
            return
        }
        detail.prepareForRows(subject: subject)

        if !rowDetail.title.isEmpty {
            let title = NSTextField(labelWithString: rowDetail.title)
            title.font = ToolPanelFont.title()
            title.translatesAutoresizingMaskIntoConstraints = false
            detail.content.addArrangedSubview(title)
        }

        // One `ToolFieldList` — the rows the UEFI Structure's detail and the
        // ME panel's are drawn with — so a bench selects and copies them here
        // as it does there: a drag takes a band of rows, ⌘A the list, and ⌘C
        // copies with a tab between a name and its value. A value is drawn by
        // its tone, the same call those panels make: a checksum that does not
        // check out — what Fix Checksum would write — is the one value in here
        // drawn red. The name column is as wide as the longest name, and never
        // wider than half the list, where a name that still does not fit
        // wraps.
        let fields = ToolFieldList(
            fields: rowDetail.fields.map {
                .init(label: $0.label,
                      value: ($0.isProblem ? ToolValueTone.bad : .standard).attributedValue($0.value))
            },
            nameWidth: ToolFieldList.nameWidth(for: rowDetail.fields.map(\.label)))
        detail.content.addArrangedSubview(fields)
        // As wide as the list, so a value too long for the column — a GUID, a
        // hash — wraps inside it instead of running off the side.
        fields.widthAnchor.constraint(equalTo: detail.content.widthAnchor).isActive = true
    }

    /// How tall the findings list is: exactly its rows, up to
    /// `maxProblemRows` of them.
    ///
    /// Exactly — no slack. A box taller than the line in it reads as a box
    /// with something missing, and the row inside it looks pushed off centre.
    /// The row height is read off the table rather than assumed, so a list at
    /// any zoom still fits its rows.
    private func problemListHeight() -> CGFloat {
        let row = problems.rowHeight + problems.intercellSpacing.height
        let rows = min(display.problems.count, Self.maxProblemRows)
        return CGFloat(rows) * row
    }

    /// A line at the foot of the panel — what happened, or what to do next. The panel
    /// has no room for an alert sheet and nothing here is worth one.
    ///
    /// A refusal is red, because it is the one kind of line the user has to
    /// read: they pressed something and it did not happen. Everything else is
    /// a note about what did.
    func say(_ text: String, asProblem: Bool = false) {
        noticeLabel.stringValue = text
        noticeLabel.textColor = asProblem ? SemanticColors.bad : SemanticColors.quiet
    }

    // MARK: - Actions

    @objc private func fixChecksumClicked() { onFixChecksum?() }
    @objc private func addMicrocodeClicked() { onAddMicrocode?() }
    @objc private func summaryClicked() { onSelectTable?() }

    @objc private func replaceMicrocodeFromMenuClicked() {
        guard let row = clickedEntry() else { return }
        onReplaceMicrocode?(row.index)
    }

    @objc private func removeMicrocodeFromMenuClicked() {
        guard let row = clickedEntry() else { return }
        onRemoveMicrocode?(row.index)
    }

    @objc private func entryDoubleClicked() {
        guard let row = displayRow(atTableRow: entries.clickedRow) else { return }
        onGoToTarget?(row.key)
    }

    /// Built fresh every time it opens, for the row under the pointer:
    /// `clickedRow` is what a right-click sets, and an item that does not apply
    /// to that row should not be there rather than be there and greyed.
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    @objc private func goToOffsetClicked() {
        guard let row = clickedEntry() else { return }
        onGoToTarget?(row.key)
    }

    private func clickedEntry() -> FITDisplayRow? {
        displayRow(atTableRow: entries.clickedRow)
    }

    @objc private func problemDoubleClicked() {
        guard problems.clickedRow >= 0, problems.clickedRow < display.problems.count else { return }
        onGoToProblem?(problems.clickedRow)
    }
}

extension FITToolViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // The items that modify the table stand down for a parse — greyed, not
        // gone, so the menu still says what it would do once the reading is
        // done — and a parse reads a snapshot of the file, so an edit that
        // slipped in while it ran would make the two sides of the panel
        // disagree.
        menu.autoenablesItems = false
        guard let row = clickedEntry() else { return }
        for command in row.commands {
            let action: Selector
            switch command {
            case .goToOffset: action = #selector(goToOffsetClicked)
            case .replaceMicrocode: action = #selector(replaceMicrocodeFromMenuClicked)
            case .removeMicrocode: action = #selector(removeMicrocodeFromMenuClicked)
            case .fixChecksum: action = #selector(fixChecksumClicked)
            }
            let item = menu.addItem(withTitle: command.title.text, action: action, keyEquivalent: "")
            item.target = self
            if busy {
                switch command {
                case .replaceMicrocode, .removeMicrocode, .fixChecksum:
                    item.isEnabled = false
                default:
                    break
                }
            }
        }
    }
}

/// One row of the entries' outline: an entry of the table, a line under a
/// microcode entry, or the heading in front of the Top Swap backup's copy. A
/// class, because NSOutlineView knows its rows by identity.
final class FITOutlineItem: NSObject {
    enum Kind: Hashable {
        case heading
        /// The row's key (`FITDisplayRow.key`).
        case entry(Int)
        /// The row's key: the plate of the CPUIDs a microcode serves, under
        /// it — one row, not one a CPUID, and not one that can be chosen.
        case cpuids(Int)
        /// Add Microcode…, under the table's last microcode.
        case addMicrocode

        var isEntry: Bool {
            if case .entry = self { return true }
            return false
        }

        /// The entry this item belongs to.
        var key: Int? {
            switch self {
            case .heading, .addMicrocode: return nil
            case .entry(let key), .cpuids(let key): return key
            }
        }
    }

    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }
}

extension FITToolViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    // MARK: - The items

    /// The outline's items for the display on hand: every row, the heading
    /// where the backup's copy starts, and under a microcode the plate of the
    /// CPUIDs it serves. The processors behind a CPUID are not rows: they are
    /// not part of the update, and its `ⓘ` lists them.
    fileprivate func rebuildItems() {
        // No table — another file, or one still being read — and nothing of
        // the last one's opening is kept: its rows open afresh.
        if display.rows.isEmpty {
            seenEntries = []
            expandedKinds = []
        }
        // The items a row had before are the items it keeps. NSOutlineView
        // knows a row by its item, so a show with new items is a tree closed
        // and opened again — and in between the document is short, AppKit
        // pulls the scroll up to fit it, and the row just clicked lands at the
        // bottom of the view. With the same items a reload is only a reload.
        let previous = display.rows.isEmpty ? [:] : itemsByKind
        keepsScroll = !previous.isEmpty
        topItems = []
        itemsByKind = [:]
        childItems = [:]
        func made(_ kind: FITOutlineItem.Kind) -> FITOutlineItem {
            let item = previous[kind] ?? FITOutlineItem(kind)
            itemsByKind[kind] = item
            return item
        }
        for (index, row) in display.rows.enumerated() {
            if display.backupStart == index { topItems.append(made(.heading)) }
            let entry = FITOutlineItem.Kind.entry(row.key)
            topItems.append(made(entry))
            let groups = row.processorGroups
            guard !groups.isEmpty else { continue }
            childItems[entry] = [made(.cpuids(row.key))]
            if seenEntries.insert(entry).inserted { expandedKinds.insert(entry) }
        }
        if display.backupStart == display.rows.count { topItems.append(made(.heading)) }
        // Add sits under the last microcode of the table — not of the Top Swap
        // backup's copy, which is changed only with the table — or under the
        // header where there is none.
        let table = display.rows.filter { !$0.isBackup }
        if let anchor = table.last(where: { $0.model.entry.type == FIT.microcodeType }) ?? table.first,
           let at = topItems.firstIndex(where: { $0.kind == .entry(anchor.key) }) {
            topItems.insert(made(.addMicrocode), at: at + 1)
        }
        expandedKinds.formIntersection(itemsByKind.keys)
    }

    /// Reloads the entries and opens again the rows the reader had open — a
    /// new table's items are new, and NSOutlineView opens none of them. A
    /// parent opens before its children, so the order is the tree's. The same
    /// table keeps its items and its scroll.
    fileprivate func reloadEntries() {
        let wasShowing = isShowingState
        isShowingState = true
        defer { isShowingState = wasShowing }
        // The same table shown again stays where the reader scrolled it.
        let clip = entriesScroll.contentView
        let origin = clip.bounds.origin
        defer {
            if keepsScroll {
                clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
                entriesScroll.reflectScrolledClipView(clip)
            }
        }
        entries.reloadData()
        func reopen(_ items: [FITOutlineItem]) {
            for item in items where expandedKinds.contains(item.kind) && entries.isExpandable(item) {
                entries.expandItem(item)
                reopen(childItems[item.kind] ?? [])
            }
        }
        reopen(topItems)
    }

    private func item(atRow row: Int) -> FITOutlineItem? {
        row >= 0 ? entries.item(atRow: row) as? FITOutlineItem : nil
    }

    private func entry(ofKey key: Int) -> FITDisplayRow? {
        display.rows.first { $0.key == key }
    }

    /// The entry a row stands for: its own, or — for the CPUIDs' plate under
    /// a microcode — the microcode's, so its menu and its double-click act on
    /// the microcode.
    private func displayRow(atTableRow row: Int) -> FITDisplayRow? {
        item(atRow: row)?.kind.key.flatMap(entry(ofKey:))
    }

    /// The row an item is on, when it is on screen — the plate under a closed
    /// microcode is on none.
    private func tableRow(of kind: FITOutlineItem.Kind) -> Int? {
        guard let item = itemsByKind[kind] else { return nil }
        let row = entries.row(forItem: item)
        return row >= 0 ? row : nil
    }

    private func isHeading(_ row: Int) -> Bool { item(atRow: row)?.kind == .heading }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? FITOutlineItem else { return topItems.count }
        return childItems[item.kind]?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? FITOutlineItem else { return topItems[index] }
        return childItems[item.kind]?[index] ?? FITOutlineItem(.heading)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? FITOutlineItem else { return false }
        return !(childItems[item.kind]?.isEmpty ?? true)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        noteExpansion(notification, expanded: true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        noteExpansion(notification, expanded: false)
    }

    private func noteExpansion(_ notification: Notification, expanded: Bool) {
        guard !isShowingState, let item = notification.userInfo?["NSObject"] as? FITOutlineItem else { return }
        if expanded { expandedKinds.insert(item.kind) } else { expandedKinds.remove(item.kind) }
    }

    // MARK: - Views

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? FITOutlineItem else { return nil }
        switch item.kind {
        case .heading:
            return headingView(in: outlineView)
        case .addMicrocode:
            return tableColumn?.identifier == Column.type ? addMicrocodeCell : nil
        case .entry(let key):
            guard let column = tableColumn, let entry = entry(ofKey: key) else { return nil }
            return entryCell(entry, column: column)
        case .cpuids(let key):
            guard tableColumn?.identifier == Column.type, let entry = entry(ofKey: key) else { return nil }
            return cpuidPlate(entry)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? FITOutlineItem)?.kind == .heading
    }

    /// Every entry is chosen as in the UEFI tree; the heading is a heading,
    /// and the CPUIDs' plate says something about its microcode rather than
    /// being a thing of its own — the arrow keys pass over both.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let kind = (item as? FITOutlineItem)?.kind else { return false }
        return kind.isEntry
    }

    /// The button's row is as tall as the button, the plate's as its lines;
    /// every other row is the table's.
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch (item as? FITOutlineItem)?.kind {
        case .addMicrocode?:
            return max(outlineView.rowHeight, addButton.fittingSize.height + 6)
        case .cpuids(let key)?:
            return FITCPUIDPlate.height(lines: entry(ofKey: key)?.processorGroups.count ?? 0,
                                        textSize: ToolPanelFont.body().pointSize)
        default:
            return outlineView.rowHeight
        }
    }

    /// The entries' rows carry the Boot Guard background; the CPUIDs' plate
    /// under a microcode is about the processor, not about bytes of the image, and
    /// keep the plain row.
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let item = item as? FITOutlineItem, case .entry(let key) = item.kind,
              let entry = entry(ofKey: key)
        else { return nil }
        let rowView = outlineView.makeView(withIdentifier: Self.rowViewIdentifier, owner: self)
            as? ToolPanelRowView ?? {
                let created = ToolPanelRowView()
                created.identifier = Self.rowViewIdentifier
                return created
            }()
        rowView.showsMarkings = legend.showsMarkings
        rowView.marks = marks(of: entry)
        return rowView
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        selectionDidChange()
    }

    private func selectionDidChange() {
        guard !isShowingState else { return }
        let row = entries.selectedRow
        if entries.isHandlingClick { onWillChoose?() }
        onSelect?(displayRow(atTableRow: row)?.key)
    }

    private func entryCell(_ entry: FITDisplayRow, column: NSTableColumn) -> NSView {
        let cell = entries.makeView(withIdentifier: column.identifier, owner: self)
            as? NSTableCellView ?? makeEntryCell(identifier: column.identifier)
        // The row wears its problem ahead of its name — the red octagon for an
        // error, the orange circle for a caution, as in the UEFI tree, rather
        // than the whole row in red — and a microcode's verdict against the
        // catalogue after the word "Microcode", the thing the verdict is about.
        ToolPanelTable.dress(cell, with: marks(of: entry))
        let verdict = FITRowMarks.verdict(of: entry.latestState, in: Localization.appLanguage)
        ToolPanelTable.setVerdict(verdict?.mark, toolTip: verdict?.toolTip, on: cell)
        // The type names the row; what it points at follows in the body's
        // weight. The backup's rows read quieter: they are there to be
        // compared, and nothing on them is changed on its own.
        cell.textField?.stringValue = entry.typeText
        cell.textField?.font = ToolPanelFont.body(weight: .medium)
        cell.textField?.textColor = entry.isBackup ? .secondaryLabelColor : .labelColor
        let target = cell.viewWithTag(Self.targetFieldTag) as? NSTextField
        target?.stringValue = entry.targetText
        target?.font = ToolPanelFont.body()
        target?.textColor = entry.isBackup ? .tertiaryLabelColor : .labelColor
        // The version is a real field and it decides how a policy row's address
        // is read (§7.3), but it is the same 1.00 on almost every row — so it
        // lives where a curious pointer finds it rather than on the line.
        let line = entry.targetText.isEmpty ? entry.typeText : "\(entry.typeText)   \(entry.targetText)"
        let tip = "\(line)\n" + L("Version %1$@", entry.versionText)
        cell.textField?.toolTip = tip
        target?.toolTip = tip
        return cell
    }

    /// The tag of the field after the verdict: what the entry points at.
    private static let targetFieldTag = 6_101

    /// The shared cell — problem slot, badges, text, verdict slot — laid out
    /// for an entry: the type, the verdict right after it, then what the entry
    /// points at taking the rest of the line and cut short first.
    private func makeEntryCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = ToolPanelTable.makeCell(identifier: identifier, warning: true, marker: true, badges: true)
        guard let field = cell.textField,
              let row = field.superview as? NSStackView,
              let marker = cell.viewWithTag(ToolPanelTable.markerTag)
        else { return cell }
        let target = NSTextField(labelWithString: "")
        target.tag = Self.targetFieldTag
        target.lineBreakMode = .byTruncatingTail
        target.maximumNumberOfLines = 1
        target.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        target.setContentHuggingPriority(.init(1), for: .horizontal)
        // The type is short and is never the part cut: it hugs its text, so
        // the verdict sits against it.
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        row.removeArrangedSubview(marker)
        let after = (row.arrangedSubviews.firstIndex(of: field) ?? row.arrangedSubviews.count - 1) + 1
        row.insertArrangedSubview(marker, at: after)
        row.insertArrangedSubview(target, at: after + 1)
        // A hidden verdict leaves the type and the target their own gap.
        row.setCustomSpacing(8, after: field)
        row.setCustomSpacing(8, after: marker)
        return cell
    }

    /// The lines under a microcode: its CPUIDs one under another, each in
    /// the weight of a heading, the `ⓘ` that lists the processors behind it
    /// right after it, and its code names quieter after that. Under a row of
    /// the Top Swap backup's copy everything reads as quietly as that row
    /// does: it is there to be compared.
    private func cpuidPlate(_ entry: FITDisplayRow) -> NSView {
        let plate = entries.makeView(withIdentifier: FITCPUIDPlate.identifier, owner: self) as? FITCPUIDPlate
            ?? FITCPUIDPlate()
        plate.key = entry.key
        // A CPUID the table knows nothing about has no `ⓘ`: there is nothing
        // behind it to open.
        plate.show(entry.processorGroups.map {
            (L("CPUID %1$@", $0.cpuid), $0.codeNames.joined(separator: ", "), !$0.codeNames.isEmpty)
        }, quiet: entry.isBackup)
        plate.onInfo = { [weak self] index, button in
            self?.showProcessors(key: entry.key, group: index, from: button, rect: nil)
        }
        return plate
    }

    /// A CPUID's `ⓘ`: the processors behind it, in a popover off the `ⓘ`.
    // help: fit.processors
    private func showProcessors(key: Int, group: Int, from anchor: NSView, rect: NSRect?) {
        guard let entry = entry(ofKey: key), group < entry.processorGroups.count else { return }
        processorsPopover?.close()
        processorsPopover = FITProcessorsPopover.show(entry.processorGroups[group], from: anchor, rect: rect)
    }

    /// What an entry row wears besides its text, decided in the pure target.
    private func marks(of entry: FITDisplayRow) -> ToolRowMarks {
        FITRowMarks.marks(for: entry, problems: display.problems, in: Localization.appLanguage)
    }

    /// The row views on screen, given their background again: reloading the
    /// cells does not reach a row view, and the ranges land after the rows.
    fileprivate func updateRowMarks() {
        entries.enumerateAvailableRowViews { rowView, row in
            guard let rowView = rowView as? ToolPanelRowView,
                  case .entry(let key)? = item(atRow: row)?.kind,
                  let entry = entry(ofKey: key)
            else { return }
            rowView.showsMarkings = legend.showsMarkings
            rowView.marks = marks(of: entry)
        }
    }

    /// The one cell Add Microcode… sits in. One button, so one cell: the row
    /// is rebuilt with every show, and the button — enabled or not as
    /// `updateButtons` decided — moves with it rather than being made again.
    private var addMicrocodeCell: NSView {
        if let cell = addButton.superview { return cell }
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("addMicrocode")
        cell.addSubview(addButton)
        NSLayoutConstraint.activate([
            addButton.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            addButton.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            addButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func headingView(in tableView: NSTableView) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("backupHeading")
        let label = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? {
            let made = NSTextField(labelWithString: "")
            made.identifier = identifier
            made.lineBreakMode = .byTruncatingTail
            return made
        }()
        label.stringValue = display.backupHeading ?? ""
        label.font = ToolPanelFont.body(weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }
}

/// The findings list is a plain table. The entries answer here too, by row,
/// for whoever asks a table delegate about one of its rows.
extension FITToolViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === problems ? display.problems.count : entries.numberOfRows
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
    -> NSView? {
        if tableView === entries {
            return item(atRow: row).flatMap { outlineView(entries, viewFor: tableColumn, item: $0) }
        }
        guard let column = tableColumn, row < display.problems.count else { return nil }
        let cell = tableView.makeView(withIdentifier: column.identifier, owner: self)
            as? NSTableCellView ?? ToolPanelTable.makeCell(identifier: column.identifier)
        let problem = display.problems[row]
        cell.textField?.stringValue = problem.message.text
        cell.textField?.font = ToolPanelFont.body()
        cell.textField?.textColor = problem.severity == .error
            ? SemanticColors.bad : SemanticColors.quiet
        return cell
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        tableView === entries && isHeading(row)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard tableView === entries else { return true }
        return item(atRow: row).map { outlineView(entries, shouldSelectItem: $0) } ?? false
    }
}

/// The CPUIDs a microcode serves, under its row on the table's own
/// background: a line a CPUID — the CPUID, the `ⓘ` right after it, which
/// belongs to that CPUID, and its code names, cut short where the column is
/// narrow. The lines are not rows of the table: they cannot be chosen, and
/// they are one text, so a reader selects and copies from them as from any
/// text, across lines too.
@MainActor final class FITCPUIDPlate: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("cpuidPlate")
    /// Above and below the lines, inside the row.
    static let margin: CGFloat = 2

    /// The microcode row the lines are under.
    var key: Int?
    let textView = FITCPUIDTextView()
    /// What a click on a line's `ⓘ` asks for: the line's place, and the
    /// `ⓘ` the popover stands off.
    var onInfo: ((Int, NSView) -> Void)?
    /// The lines' `ⓘ`: the panel's own button, as a module's in the UEFI
    /// tree, laid over the room the text keeps for it after the CPUID. A real
    /// button, so the click is its own — a link in the text lost it to the
    /// text's selection and the table's row more often than not. Tagged
    /// with its line; hidden where a line has none.
    private(set) var infoButtons: [ToolPanelInfoButton] = []

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        textView.frame = bounds.insetBy(dx: 0, dy: Self.margin)
        textView.autoresizingMask = [.width, .height]
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        textView.frame = NSRect(x: 2, y: Self.margin, width: max(0, bounds.width - 4),
                                height: max(0, bounds.height - 2 * Self.margin))
        placeInfoButtons()
    }

    /// Sets each `ⓘ` over the room its line keeps for it; one whose room
    /// is cut off by a narrow column is hidden with it.
    private func placeInfoButtons() {
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        for button in infoButtons {
            guard let room = textView.rectOfInfo(button.tag), room.width > 0 else {
                button.isHidden = true
                continue
            }
            let side = ToolPanelInfoButton.side
            button.frame = NSRect(x: room.midX - side / 2, y: room.midY - side / 2, width: side, height: side)
            button.isHidden = room.maxX > textView.bounds.width
        }
    }

    /// Opens line `index`'s processors, as a click on its `ⓘ` does — where
    /// the line has one.
    func openInfo(_ index: Int) {
        guard let button = infoButtons.first(where: { $0.tag == index }) else { return }
        onInfo?(index, button)
    }

    @objc private func infoClicked(_ sender: NSButton) { onInfo?(sender.tag, sender) }

    /// The height of one line at `textSize`.
    static func lineHeight(textSize: CGFloat) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: textSize, weight: .medium))) + 1
    }

    /// The row's height for `lines` lines.
    static func height(lines: Int, textSize: CGFloat) -> CGFloat {
        CGFloat(max(lines, 1)) * lineHeight(textSize: textSize) + 2 * margin
    }

    /// The lines as a reader copies them: the words without the `ⓘ`.
    var lineTexts: [String] { FITCPUIDTextView.plain(textView.string).components(separatedBy: "\n") }

    /// Shows a line for each CPUID — the CPUID, its `ⓘ` where there is
    /// something behind it, its code names. `quiet` greys them all, as under
    /// a row of the Top Swap backup's copy.
    func show(_ lines: [(cpuid: String, names: String, hasInfo: Bool)], quiet: Bool) {
        let size = ToolPanelFont.body().pointSize
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.minimumLineHeight = Self.lineHeight(textSize: size)
        paragraph.maximumLineHeight = paragraph.minimumLineHeight
        let text = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n")) }
            let strong: NSColor = quiet ? .secondaryLabelColor : .labelColor
            text.append(NSAttributedString(string: line.cpuid, attributes: [
                .font: ToolPanelFont.body(weight: .medium), .foregroundColor: strong,
            ]))
            if line.hasInfo {
                text.append(NSAttributedString(string: "  "))
                text.append(FITCPUIDTextView.infoRoom(index: index))
            }
            if !line.names.isEmpty {
                text.append(NSAttributedString(string: "  " + line.names, attributes: [
                    .font: ToolPanelFont.body(),
                    .foregroundColor: quiet ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor,
                ]))
            }
        }
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        textView.textStorage?.setAttributedString(text)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        infoButtons.forEach { $0.removeFromSuperview() }
        infoButtons = lines.indices.filter { lines[$0].hasInfo }.map { index in
            let button = ToolPanelInfoButton()
            button.translatesAutoresizingMaskIntoConstraints = true
            button.tag = index
            button.target = self
            button.action = #selector(infoClicked(_:))
            ControlHelp.describe(button, name: L("Processors"), tooltip: L("Show the processors with this CPUID"))
            textView.addSubview(button)
            return button
        }
        needsLayout = true
        placeInfoButtons()
    }
}

/// The text the CPUIDs are: selectable, never edited, on no background of
/// its own. Its `ⓘ` are links; a copy leaves them out.
@MainActor final class FITCPUIDTextView: NSTextView, NSTextViewDelegate {
    /// The attribute that marks the room a line keeps for its `ⓘ`; its
    /// value is the line's place.
    static let infoLine = NSAttributedString.Key("FITCPUIDInfoLine")

    convenience init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = false
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        delegate = self
    }

    /// The room a line keeps for its `ⓘ` right after the CPUID: an empty
    /// attachment the button's size, which the plate lays the button over.
    static func infoRoom(index: Int) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let side = ToolPanelInfoButton.side
        attachment.image = NSImage(size: NSSize(width: side, height: side))
        let font = ToolPanelFont.body(weight: .medium)
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - side) / 2, width: side, height: side)
        let room = NSMutableAttributedString(attachment: attachment)
        room.addAttributes([.font: font, Self.infoLine: index],
                           range: NSRange(location: 0, length: room.length))
        return room
    }

    /// `text` as a reader copies it: without the character an `ⓘ` stands on,
    /// and the spaces that set it off from the CPUID.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "  \u{FFFC}", with: "").replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// Where line `index`'s `ⓘ` stands, in this view; nil for a line without.
    func rectOfInfo(_ index: Int) -> NSRect? {
        guard let storage = textStorage, let layoutManager, let textContainer else { return nil }
        var found: NSRect?
        storage.enumerateAttribute(Self.infoLine, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard (value as? Int) == index else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            found = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            stop.pointee = true
        }
        return found
    }

    // MARK: - Copying

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        let text = string as NSString
        let parts = selectedRanges.map { text.substring(with: $0.rangeValue) }
        pboard.setString(Self.plain(parts.joined(separator: "\n")), forType: .string)
        return true
    }

    // A click in the text is the text's: it does not choose the row under it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The entries' outline, which lets a click into the CPUIDs' text reach the
/// text — a table hands a click to a view in a row only when it is asked.
@MainActor final class FITEntriesOutlineView: ToolPanelOutlineView {
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        responder is FITCPUIDTextView || super.validateProposedFirstResponder(responder, for: event)
    }
}
