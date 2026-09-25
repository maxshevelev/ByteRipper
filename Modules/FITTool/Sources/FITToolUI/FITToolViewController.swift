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
    var onGoToTarget: ((Int) -> Void)?
    var onSelectTable: (() -> Void)?
    var onCopyCPUID: ((Int) -> Void)?
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

    let entries = NSTableView()
    let problems = NSTableView()
    private let entriesScroll = NSScrollView()
    private let problemsScroll = NSScrollView()
    /// The entries and their legend, as one pane of the splitter: the legend
    /// explains the rows, and opens into the table's room rather than the
    /// detail's (`Design/ROW_MARKS.md` §6).
    private let entriesPane = NSView()
    let legend = ToolRowMarksLegend(panel: "FIT", marks: FITRowMarks.legendMarks)
    private static let rowViewIdentifier = NSUserInterfaceItemIdentifier("fitRow")
    private let detail = ToolDetailScroll()
    private let splitter = ALSplitView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let noticeLabel = NSTextField(labelWithString: "")
    /// The row under the buttons: the notice, and the parse's progress bar on
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
        static let index = NSUserInterfaceItemIdentifier("index")
        static let type = NSUserInterfaceItemIdentifier("type")
        static let address = NSUserInterfaceItemIdentifier("address")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let target = NSUserInterfaceItemIdentifier("target")
        static let problem = NSUserInterfaceItemIdentifier("problem")
    }

    /// The columns, with the width each was laid out at — a width for text at
    /// `ToolPanelFont.designSize`, so the panel scales it to whatever size the
    /// zoom is at rather than leaving "Points at" saying "Microco…" the moment
    /// the type grows.
    ///
    /// `minWidth` is how far a column gives way when the panel is narrow: the
    /// row number and the eight hex digits of an address not at all, the rest
    /// to where their text starts to be cut short.
    private static let entryColumns:
    [(id: NSUserInterfaceItemIdentifier, title: String, width: CGFloat, minWidth: CGFloat)] = [
        (Column.index, "#", 20, 20),
        (Column.type, L("Type"), 96, 56),
        (Column.address, L("Address", context: "column"), 76, 76),
        (Column.size, L("Size"), 84, 40),
        (Column.target, L("Points at"), 300, 80)
    ]
    /// The columns that give way, in order, once "Points at" is down to its
    /// floor and the table is still wider than the panel — and get their
    /// width back, the other way round, when the panel grows again.
    private static let yieldingColumns = [Column.size, Column.type]
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
        // scroll off the edges and the rows run edge to edge. "Points at", the
        // column with something to say, takes whatever width the panel gives;
        // narrowed, it gives way first, then Size and Type, each down to a
        // floor — and only below all of those does the table scroll sideways.
        // A cut-short cell still says the whole of it under the pointer.
        //
        // Only "Points at" is resized with the table. AppKit's sequential
        // styles give way from the last column but grow from the first, which
        // puts a wider panel's width into the row number; Size and Type are
        // squeezed by hand instead (`fitColumnsToThePanel`).
        entries.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for spec in Self.entryColumns {
            column(entries, spec.id, spec.title, spec.width, minWidth: spec.minWidth,
                   resizesWithTable: spec.id == Column.target)
        }
        for id in Self.yieldingColumns {
            wantedWidths[id] = entries.tableColumn(withIdentifier: id)?.width
        }
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
        splitter.addPane(detail)
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
        button(addButton, L("Add Microcode…"), #selector(addMicrocodeClicked),
               L("Put a microcode in the image and name it in the table"))

        let buttons = NSStackView(views: [addButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false

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
        view.addSubview(buttons)
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
            problemsScroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -6),
            ratio, content,

            buttons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),
            buttons.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -6),

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
    /// detail's own rows — which are views built per field, so they have to be
    /// rebuilt rather than restyled. The problem list is as tall as its rows,
    /// so its height is re-measured at the new row height.
    private func applyPanelFont() {
        summaryLabel.font = ToolPanelFont.body(weight: .medium)
        noticeLabel.font = ToolPanelFont.body()
        ToolPanelTable.apply(to: entries)
        ToolPanelTable.apply(to: problems)
        applyColumnWidths()
        entries.reloadData()
        problems.reloadData()
        renderDetail(display.detail, subject: detailSubject)
        if !display.problems.isEmpty {
            problemsContent?.constant = problemListHeight()
        }
    }

    // MARK: - A parse's progress

    /// A parse is running: the bar joins the row under the buttons, and the
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

    /// The reading is done: the bar leaves the row and the buttons come back as
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

    /// "Points at" takes the width the other columns leave. Below its floor,
    /// Size and then Type give way down to theirs; with room again, Type and
    /// then Size get back what they gave, and "Points at" the rest.
    private func fitColumnsToThePanel() {
        guard !isFittingColumns, let target = entries.tableColumn(withIdentifier: Column.target),
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
        self.display = display
        self.canWrite = canWrite
        isShowingState = true
        defer { isShowingState = false }

        summaryLabel.stringValue = display.summary
        entries.reloadData()
        updateRowMarks()
        problems.reloadData()
        renderDetail(display.detail, subject: focus.map(String.init) ?? "")
        if let focus, let row = tableRow(ofKey: focus) {
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

        for field in rowDetail.fields {
            let label = NSTextField(labelWithString: field.label)
            label.font = ToolPanelFont.body()
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(
                equalToConstant: ToolPanelFont.detailLabelWidth
            ).isActive = true

            let value = ToolWrappingLabel(string: field.value)
            value.font = field.value.hasPrefix("0x")
                ? ToolPanelFont.monospacedDigits()
                : ToolPanelFont.body()
            // A checksum that does not check out is the one value in here
            // worth colouring red: it is what Fix Checksum would write.
            if field.isProblem {
                value.textColor = SemanticColors.bad
            }
            // Selectable, not a dead label: a bench copies an offset or a CPUID
            // out of here, and a value it cannot select is one it has to retype.
            value.isSelectable = true

            let row = NSStackView(views: [label, value])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            detail.content.addArrangedSubview(row)
            // As wide as the list, so a value too long for the column — a
            // GUID, a hash — wraps inside it instead of running off the side.
            row.widthAnchor.constraint(
                equalTo: detail.content.widthAnchor
            ).isActive = true
        }
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

    /// A line under the buttons — what happened, or what to do next. The panel
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

    @objc private func copyCPUIDClicked() {
        guard let row = clickedEntry() else { return }
        onCopyCPUID?(row.key)
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
            case .copyCPUID: action = #selector(copyCPUIDClicked)
            case .goToOffset: action = #selector(goToOffsetClicked)
            case .replaceMicrocode: action = #selector(replaceMicrocodeFromMenuClicked)
            case .removeMicrocode: action = #selector(removeMicrocodeFromMenuClicked)
            case .fixChecksum: action = #selector(fixChecksumClicked)
            }
            let item = menu.addItem(withTitle: command.title, action: action, keyEquivalent: "")
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

extension FITToolViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === problems ? display.problems.count : tableRowCount
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
    -> NSView? {
        if tableView === entries, isHeading(row) {
            return headingView(in: tableView)
        }
        guard let column = tableColumn else { return nil }
        let cell = tableView.makeView(withIdentifier: column.identifier, owner: self)
            as? NSTableCellView
            ?? ToolPanelTable.makeCell(identifier: column.identifier,
                                       warning: column.identifier == Column.type,
                                       marker: column.identifier == Column.type,
                                       badges: column.identifier == Column.type)

        if tableView === problems {
            guard row < display.problems.count else { return nil }
            let problem = display.problems[row]
            cell.textField?.stringValue = problem.message
            cell.textField?.font = ToolPanelFont.body()
            cell.textField?.textColor = problem.severity == .error
                ? SemanticColors.bad : SemanticColors.quiet
            return cell
        }

        guard let entry = displayRow(atTableRow: row) else { return nil }
        let monospaced = ToolPanelFont.monospacedDigits()
        // The Type column wears the row's problem — the red octagon for an
        // error, the orange circle for a caution, as in the UEFI tree, rather
        // than the whole row in red — and, ahead of it, the microcode row's
        // verdict against the catalogue. Both are row-wide states worn on the
        // column the row is named by, in the icons of the shared catalogue.
        if column.identifier == Column.type {
            ToolPanelTable.dress(cell, with: marks(ofRow: row))
            let verdict = FITRowMarks.verdict(of: entry.latestState)
            ToolPanelTable.setVerdict(verdict?.mark, toolTip: verdict?.toolTip, on: cell)
        }
        switch column.identifier {
        case Column.index:
            // The number the reader counts, from one — not the row's zero-based
            // place, which the header would show as 0.
            cell.textField?.stringValue = "\(entry.displayNumber)"
            cell.textField?.font = monospaced
        case Column.type:
            cell.textField?.stringValue = entry.typeText
            cell.textField?.font = ToolPanelFont.body()
        case Column.address:
            cell.textField?.stringValue = entry.addressText
            cell.textField?.font = monospaced
        case Column.size:
            cell.textField?.stringValue = entry.sizeText
            cell.textField?.font = monospaced
        default:
            cell.textField?.stringValue = entry.targetText
            cell.textField?.font = ToolPanelFont.body()
        }
        // The backup's rows read quieter: they are there to be compared, and
        // nothing on them is changed on its own.
        cell.textField?.textColor = entry.isBackup ? .secondaryLabelColor : .labelColor
        // The version is a real field and it decides how a policy row's address
        // is read (§7.3), but it is the same 1.00 on almost every row — so it
        // lives where a curious pointer finds it rather than in a column.
        cell.textField?.toolTip = column.identifier == Column.type
            ? "Version \(entry.versionText)"
            : (entry.targetText.isEmpty ? nil : entry.targetText)
        return cell
    }

    /// The entries' rows carry the Boot Guard background; the findings list
    /// under them is a strip of lines, not rows of the image, and keeps the
    /// plain row.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard tableView === entries, !isHeading(row) else { return nil }
        let rowView = tableView.makeView(withIdentifier: Self.rowViewIdentifier, owner: self)
            as? ToolPanelRowView ?? {
                let created = ToolPanelRowView()
                created.identifier = Self.rowViewIdentifier
                return created
            }()
        rowView.showsMarkings = legend.showsMarkings
        rowView.marks = marks(ofRow: row)
        return rowView
    }

    /// What an entry row wears besides its text, decided in the pure target.
    private func marks(ofRow row: Int) -> ToolRowMarks {
        guard let entry = displayRow(atTableRow: row) else { return .none }
        return FITRowMarks.marks(for: entry, problems: display.problems)
    }

    /// The row views on screen, given their background again: reloading the
    /// cells does not reach a row view, and the ranges land after the rows.
    private func updateRowMarks() {
        entries.enumerateAvailableRowViews { rowView, row in
            guard let rowView = rowView as? ToolPanelRowView else { return }
            rowView.showsMarkings = legend.showsMarkings
            rowView.marks = marks(ofRow: row)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isShowingState, notification.object as AnyObject? === entries else { return }
        let row = entries.selectedRow
        onSelect?(displayRow(atTableRow: row)?.key)
    }

    // MARK: - The Top Swap backup's heading

    /// The table's rows: the entries, and — for an image that keeps a Top Swap
    /// backup — a heading in front of the backup's copy.
    private var tableRowCount: Int { display.rows.count + (display.backupStart == nil ? 0 : 1) }

    private func isHeading(_ row: Int) -> Bool { display.backupStart == row }

    private func displayRow(atTableRow row: Int) -> FITDisplayRow? {
        guard row >= 0, !isHeading(row) else { return nil }
        let index = display.backupStart.map { row > $0 ? row - 1 : row } ?? row
        return index < display.rows.count ? display.rows[index] : nil
    }

    private func tableRow(ofKey key: Int) -> Int? {
        guard let index = display.rows.firstIndex(where: { $0.key == key }) else { return nil }
        return display.backupStart.map { index >= $0 ? index + 1 : index } ?? index
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

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        tableView === entries && isHeading(row)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !(tableView === entries && isHeading(row))
    }

}
