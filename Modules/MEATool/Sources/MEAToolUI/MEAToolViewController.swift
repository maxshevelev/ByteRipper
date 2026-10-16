import ALSplitView
import AppPalette
import AppKit
import HelpUI
import Localization
import MEATool
import MEPresentation
import ToolModuleKit

/// The panel: a Summary / Full Info switch — the MEA-style summary on the
/// first tab, the analysis tree (with the focused row's detail below it) on the
/// second.
///
/// It decides nothing. The summary is the pure target's `MEASummary` and the
/// tree is the curator's, both tested in the pure target; the analysis runs in
/// the session; the one zone is `MEAZones`. What is on screen comes from one
/// `show(...)` over values the panel only lays out.
@MainActor final class MEAToolViewController: NSViewController {
    /// The user picked a row in the tree, or cleared it. The value is the row's
    /// tree path — the identity a parked session keeps.
    var onSelect: (([Int]?) -> Void)?
    /// A click is about to choose a row: a step for the window's navigation
    /// history, taken before the choice changes. The arrow keys are not.
    var onWillChoose: (() -> Void)?

    /// The tree takes the keyboard (`ToolSession.focusChoice`).
    func focusTree() {
        view.window?.makeFirstResponder(outline)
    }
    /// The user picked a tab (0 = Summary, 1 = Full Info).
    var onTabChanged: ((Int) -> Void)?
    /// The status row's Try Again was pressed, after a failed analysis.
    var onRetry: (() -> Void)?
    /// The summary went to the clipboard as text, and the screenshot as a
    /// picture. Told rather than announced here: the plate that says a copy
    /// happened is the window's, and a panel that drew its own would be a
    /// second convention for the same confirmation (`ToolHost.showNotice`).
    var onSummaryCopied: (() -> Void)?
    var onScreenshotCopied: (() -> Void)?

    /// The tree as it is shown, kept from one show to the next so the data
    /// source reads the same roots the last show laid out.
    private var roots: [MEANode] = []
    /// The selected row, as its path in `roots`. Nil for nothing selected.
    private var focusPath: [Int]?
    /// The summary as it was last built — kept so a re-show with the same
    /// analysis neither rebuilds the rows nor loses the user's scroll.
    private var summaryBlocks: [MEASummaryBlock] = []
    /// The configuration as it was last built, the same way.
    private var configurationBlocks: [MEAConfigurationBlock] = []
    /// The tab on screen.
    private var tabIndex = 0
    /// True while state is being shown — a selection the code made is not news,
    /// and without this the panel would select, publish, re-show and select
    /// again until the stack ran out.
    private var isShowingState = false

    private let tabs = NSSegmentedControl(labels: [L("Summary"), L("Configuration"), L("Full Info")],
                                          trackingMode: .selectOne,
                                          target: nil, action: nil)
    /// Taking the summary somewhere else: as text to paste into a note or a
    /// report, or as a picture of the whole of it. They sit in the tab row,
    /// against its trailing edge, and belong to the Summary tab — the tree has
    /// its own ways out (a zone, a reveal) and no one page to hand over.
    private let copyButton = NSButton()
    private let screenshotButton = NSButton()
    private let summaryActions = NSStackView()
    private let contentBox = NSView()
    /// The empty Summary tab: an icon over a line saying what the panel is
    /// doing, or why there is nothing to read.
    private let placeholder = NSStackView()
    private let placeholderIcon = NSImageView()
    private let placeholderTitle = NSTextField(labelWithString: "")
    private let placeholderCaption = NSTextField(labelWithString: "")
    /// Which of the three things the empty tab is saying, kept so a zoom change
    /// can re-lay it out without the caller saying it again.
    private var placeholderState = Placeholder.waiting
    private let outline = MEOutlineView()
    private let outlineScroll = NSScrollView()
    /// The tree and its legend, as one pane of the splitter: the legend
    /// explains the rows, and opens into the tree's room rather than the
    /// detail's (`Design/ROW_MARKS.md` §6).
    private let treePane = NSView()
    let legend = ToolRowMarksLegend(panel: "MEAnalyzer", marks: MEATreeMarks.legendMarks)
    private static let rowViewIdentifier = NSUserInterfaceItemIdentifier("meaRow")
    /// The detail list in its pane, and the large view Space opens it into.
    let detailPane = ToolDetailPane()
    private var detail: ToolDetailScroll { detailPane.detail }
    private let summaryScroll = ToolDetailScroll()
    /// The Configuration tab: the same rows, one block per configuration file.
    private let configurationScroll = ToolDetailScroll()
    private let splitter = ALSplitView()
    private let noticeLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: L("Try Again"), target: nil, action: nil)
    private let progressBar = NSProgressIndicator()
    private let bottomRow = NSStackView()
    /// The panel draws at the app's zoom (`ToolPanelFont`); this tells it when
    /// the zoom moved.
    private var zoomObserver: NSObjectProtocol?

    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let summary = NSUserInterfaceItemIdentifier("summary")
    }

    /// What an empty Summary tab is: the analysis is running, it finished with
    /// nothing to summarise, or it did not finish. An empty tab used to say the
    /// same sentence in all three — "the summary will appear here" — which is a
    /// promise while a parse runs and a lie once one has failed. The panel is
    /// the only screen the user is looking at while the ME region is read, so
    /// this is where it says so.
    enum Placeholder {
        case waiting
        case empty
        case failed
        /// The Configuration tab of an image that *was* read: the firmware is
        /// there, and the other two tabs show it, but no configuration file was
        /// read from it — a generation with no map, or one whose files are not
        /// in the image. "No ME firmware" there contradicted the tab beside it.
        case noConfiguration

        /// The system symbol the state wears. A running analysis is the engine
        /// the panel is about; nothing found is a question; a failure is the
        /// warning that goes with the red line under the panel.
        var symbol: String {
            switch self {
            case .waiting: return "cpu"
            case .empty: return "questionmark.circle"
            case .failed: return "exclamationmark.octagon.fill"
            case .noConfiguration: return "list.bullet.rectangle"
            }
        }

        var title: String {
            switch self {
            case .waiting: return L("Analyzing the ME firmware…")
            case .empty: return L("No ME firmware")
            case .failed: return L("The analysis did not finish")
            case .noConfiguration: return L("No configuration read")
            }
        }

        /// The second line — what the user can do with the wait, or where the
        /// rest of the answer is. A failure's reason is in the status row, in
        /// red, so the caption points at it rather than repeating it.
        var caption: String {
            switch self {
            case .waiting: return L("Reading the region and its partitions.")
            case .empty: return L("Nothing in this file reads as Intel ME firmware.")
            case .failed: return L("The line below says what went wrong.")
            case .noConfiguration:
                return L("The settings are read on CSME 13 to 16, from the configuration files the image carries.")
            }
        }
    }

    /// What each summary row's label column is wide at
    /// `ToolPanelFont.designSize` — wider than the detail list's
    /// (`detailLabelWidth`), because the summary carries long MEA labels
    /// ("TCB Security Version Number") that would otherwise truncate.
    private static let summaryLabelWidth: CGFloat = 200

    /// What each column was laid out at — a width for text at
    /// `ToolPanelFont.designSize`, scaled from there to the zoom's size. Name is
    /// the column with something to say, so it gets the rest; Summary is as wide
    /// as the longest second line a normal row puts in it ("0x126000 · 0x200").
    private static let nameWidth: CGFloat = 300
    private static let summaryWidth: CGFloat = 150
    private var columnWidthSize = ToolPanelFont.designSize

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 520))
        view.translatesAutoresizingMaskIntoConstraints = false

        configureTabs()
        configureSummaryActions()
        configureOutline()

        outlineScroll.hasVerticalScroller = true
        outlineScroll.hasHorizontalScroller = true
        outlineScroll.autohidesScrollers = true
        outlineScroll.borderType = .bezelBorder
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false
        outlineScroll.documentView = outline

        // Top: the tree. Bottom: the detail. The divider is the user's to move.
        splitter.isVertical = false
        splitter.dividerThickness = 1
        splitter.translatesAutoresizingMaskIntoConstraints = false
        treePane.translatesAutoresizingMaskIntoConstraints = false
        // The list over its legend, with the legend's edges breakable against
        // a pane that is still zero-sized while the panel opens.
        legend.install(below: outlineScroll, in: treePane)
        legend.onShowMarkingsChanged = { [weak self] _ in self?.updateRowMarks() }
        splitter.addPane(treePane)
        splitter.addPane(detailPane)
        detailPane.attach(to: outline)
        splitter.setPaneLayout(.fill, at: 0)
        splitter.setPaneLayout(.proportional(1.0 / 3), at: 1)

        configurePlaceholder()

        contentBox.translatesAutoresizingMaskIntoConstraints = false
        contentBox.addSubview(placeholder)
        contentBox.addSubview(summaryScroll)
        contentBox.addSubview(configurationScroll)
        contentBox.addSubview(splitter)
        // The empty tab's own margins are breakable: a collapsed panel is not
        // 32 points wide, and a required pair there is one AppKit strikes out
        // to recover — taking the panel's own edge pins with it.
        let placeholderInsets = [
            placeholder.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentBox.leadingAnchor, constant: 16),
            placeholder.trailingAnchor.constraint(
                lessThanOrEqualTo: contentBox.trailingAnchor, constant: -16),
        ]
        placeholderInsets.forEach { $0.priority = .defaultHigh }

        NSLayoutConstraint.activate(placeholderInsets + [
            placeholder.centerXAnchor.constraint(equalTo: contentBox.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: contentBox.centerYAnchor),
            // The summary, the configuration rows and the tree all fill the box
            // to its edges; only one is visible at a time, so overlapping
            // edge-pinned siblings are fine — visibility is the switch, not
            // geometry.
            summaryScroll.topAnchor.constraint(equalTo: contentBox.topAnchor),
            summaryScroll.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor),
            summaryScroll.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor),
            summaryScroll.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor),
            configurationScroll.topAnchor.constraint(equalTo: contentBox.topAnchor),
            configurationScroll.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor),
            configurationScroll.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor),
            configurationScroll.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor),
            splitter.topAnchor.constraint(equalTo: contentBox.topAnchor),
            splitter.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor),
            splitter.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor),
            splitter.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor),
        ])

        noticeLabel.font = ToolPanelFont.body()
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        retryButton.isHidden = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.controlSize = .small
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 8
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        bottomRow.addArrangedSubview(noticeLabel)
        bottomRow.addArrangedSubview(retryButton)

        view.addSubview(tabs)
        view.addSubview(summaryActions)
        view.addSubview(contentBox)
        view.addSubview(bottomRow)

        let barWidth = progressBar.widthAnchor.constraint(equalToConstant: 150)
        barWidth.priority = .defaultHigh
        // Clear of the tabs, and giving way before them: the switch is what the
        // row is for.
        let clearOfTabs = summaryActions.leadingAnchor.constraint(
            greaterThanOrEqualTo: tabs.trailingAnchor, constant: 8
        )
        clearOfTabs.priority = .defaultHigh
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),

            clearOfTabs,
            summaryActions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            summaryActions.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),

            contentBox.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
            contentBox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            contentBox.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            contentBox.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -6),

            bottomRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            bottomRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            bottomRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            barWidth,
        ])

        zoomObserver = ToolPanelFont.observeZoom { [weak self] in
            self?.applyPanelFont()
        }
        selectTab(tabIndex)
    }

    deinit {
        if let zoomObserver {
            NotificationCenter.default.removeObserver(zoomObserver)
        }
    }

    /// The empty tab's icon and two lines, stacked and centred. The icon is a
    /// system symbol, so it follows the theme and the accessibility weights on
    /// its own; a build of macOS without one just shows the words.
    private func configurePlaceholder() {
        placeholderIcon.imageScaling = .scaleProportionallyUpOrDown
        placeholderIcon.contentTintColor = .tertiaryLabelColor
        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false

        for label in [placeholderTitle, placeholderCaption] {
            label.alignment = .center
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            // A sentence in the middle of the panel must not be what decides
            // how narrow the panel can be dragged: it gives its width up and
            // takes another line instead. Without this the caption's own
            // length became the panel's minimum width, and the tree and the
            // detail beside it were laid out for a panel wider than the one
            // on screen.
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        placeholderTitle.textColor = .secondaryLabelColor
        placeholderCaption.textColor = .tertiaryLabelColor

        placeholder.orientation = .vertical
        placeholder.alignment = .centerX
        placeholder.spacing = 4
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.addArrangedSubview(placeholderIcon)
        placeholder.setCustomSpacing(10, after: placeholderIcon)
        placeholder.addArrangedSubview(placeholderTitle)
        placeholder.addArrangedSubview(placeholderCaption)

        applyPlaceholder()
    }

    /// Says what the empty Summary tab is showing. The three states are the
    /// three ways there can be no summary, and the panel is told which by the
    /// module that knows — a parse starting, one ending with nothing, one
    /// failing.
    func setPlaceholder(_ state: Placeholder) {
        placeholderState = state
        applyPlaceholder()
        // A parse starting is news for what is on screen, not only for what the
        // placeholder says: it is told before any roots arrive, and the tab it
        // is standing in for is whichever one is open.
        selectTab(tabIndex)
    }

    /// What the placeholder says on the tab that is open. The module's state
    /// is about the analysis; on the Configuration tab an analysis that found
    /// firmware but no configuration is a different answer from one that
    /// found no firmware at all.
    private var shownPlaceholder: Placeholder {
        let analysed = !summaryBlocks.isEmpty || !roots.isEmpty
        return tabIndex == 1 && placeholderState == .empty && analysed
            ? .noConfiguration : placeholderState
    }

    /// The placeholder as the state and the current zoom make it. The icon is
    /// sized off the panel's type rather than fixed, so it stays the same
    /// weight beside the words at every zoom.
    private func applyPlaceholder() {
        let placeholderState = shownPlaceholder
        let side = (ToolPanelFont.size * 3).rounded()
        let icon = NSImage(systemSymbolName: placeholderState.symbol,
                           accessibilityDescription: placeholderState.title)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: side, weight: .regular)
            )
        // Re-stated: the configuration hands back a new image, and what it
        // carries over is not promised. The description is what the state is
        // called, so a screen reader says the same thing the words below do.
        icon?.accessibilityDescription = placeholderState.title
        placeholderIcon.image = icon
        placeholderIcon.isHidden = icon == nil

        placeholderTitle.font = ToolPanelFont.body(weight: .semibold)
        placeholderTitle.stringValue = placeholderState.title
        placeholderCaption.font = ToolPanelFont.body()
        placeholderCaption.stringValue = placeholderState.caption
    }

    private func configureTabs() {
        tabs.controlSize = .small
        tabs.font = .systemFont(ofSize: 10)
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0
        tabs.translatesAutoresizingMaskIntoConstraints = false
        // The switch keeps its own width whatever else is in the row.
        tabs.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// The glyph each of the summary's two ways out wears — on its own button
    /// and on the notice that confirms the copy. One sign for one action, so
    /// the plate that appears after a click is recognisably about the control
    /// that was clicked; named here rather than written twice so the button and
    /// the plate cannot come to wear different ones.
    static let copySummaryGlyph = "doc.on.doc"
    static let copyScreenshotGlyph = "camera"

    /// The two ways out of the Summary tab, as icons in its own row: the rows
    /// as text to paste, and the whole page as a picture.
    private func configureSummaryActions() {
        for (button, symbol, name, action) in [
            (copyButton, Self.copySummaryGlyph, L("Copy Summary"), #selector(copySummary)),
            (screenshotButton, Self.copyScreenshotGlyph, L("Copy Screenshot"), #selector(copyScreenshot)),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
            button.imagePosition = .imageOnly
            // The panel's own close button's treatment: a plain symbol in the
            // chrome's colour, not a control with a box around it.
            button.bezelStyle = .inline
            button.controlSize = .small
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            ControlHelp.describe(button, name)
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
        }

        summaryActions.orientation = .horizontal
        summaryActions.alignment = .centerY
        summaryActions.spacing = 10
        summaryActions.translatesAutoresizingMaskIntoConstraints = false
        summaryActions.addArrangedSubview(copyButton)
        summaryActions.addArrangedSubview(screenshotButton)
    }

    /// Re-reads the panel's type size and puts everything on screen at it: the
    /// tree's rows and header, and the summary/detail rows — which are views
    /// built per field, so they have to be rebuilt rather than restyled.
    private func applyPanelFont() {
        noticeLabel.font = ToolPanelFont.body()
        applyPlaceholder()
        ToolPanelTable.apply(to: outline)
        applyColumnWidths()
        outline.reloadData()
        renderSummary()
        // The configuration tab's rows are built per field too, so they are
        // rebuilt at the new size the same way — and not at all where there are
        // none, which would take the empty tab's own words away.
        if !configurationBlocks.isEmpty { renderConfiguration() }
        renderDetail(focusPath.flatMap { MEATree.node(at: $0, in: roots) })
    }

    private func applyColumnWidths() {
        let size = ToolPanelFont.size
        guard size != columnWidthSize else { return }
        ToolPanelTable.scaleColumnWidths(of: outline, by: size / columnWidthSize)
        columnWidthSize = size
    }

    private func configureOutline() {
        outline.style = .inset
        // An opened row's indentation comes out of the Name column rather than
        // widening it, so the tree keeps inside its scroll view and the inset
        // style's margins stay on screen — as in the UEFI tree.
        outline.autoresizesOutlineColumn = false
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = false
        outline.allowsColumnReordering = false
        outline.dataSource = self
        outline.delegate = self

        let name = NSTableColumn(identifier: Column.name)
        name.title = L("Name")
        name.width = Self.nameWidth
        name.resizingMask = [.autoresizingMask, .userResizingMask]
        outline.addTableColumn(name)
        outline.outlineTableColumn = name

        let summary = NSTableColumn(identifier: Column.summary)
        summary.title = ""
        summary.width = Self.summaryWidth
        summary.resizingMask = .userResizingMask
        outline.addTableColumn(summary)

        ToolPanelTable.apply(to: outline)
        applyColumnWidths()
    }

    /// Which content the selected tab shows: the summary for Summary, the
    /// configuration rows for Configuration, the tree (with its detail below)
    /// for Full Info — and, for any of them with nothing in it yet, the
    /// placeholder saying why. A tab is empty for the same reasons on every
    /// side, and while the ME region is being read an empty tree is a wait, not
    /// an answer; an empty outline with a spinner under it said nothing about
    /// which.
    private func selectTab(_ index: Int) {
        tabIndex = index
        let showTree = index == 2 && !roots.isEmpty
        let showSummary = index == 0 && !summaryBlocks.isEmpty
        let showConfiguration = index == 1 && !configurationBlocks.isEmpty
        splitter.isHidden = !showTree
        summaryScroll.isHidden = !showSummary
        configurationScroll.isHidden = !showConfiguration
        placeholder.isHidden = showSummary || showTree || showConfiguration
        // Nothing to copy and nothing to picture until the summary is up.
        summaryActions.isHidden = !showSummary
        tabs.selectedSegment = index
        // The words depend on the tab as well as on the state.
        if !placeholder.isHidden { applyPlaceholder() }
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        selectTab(sender.selectedSegment)
        onTabChanged?(sender.selectedSegment)
    }

    @objc private func retryClicked() {
        onRetry?()
    }

    // MARK: - Taking the summary away

    /// The summary as rich text on the clipboard: headings bold, each row a
    /// label and its value on one tabbed line, so it pastes into a note or a
    /// report as the table it is on screen rather than as a run-on paragraph.
    /// An `NSAttributedString` carries both spellings — the RTF and the plain
    /// text under it — so a plain-text field gets a readable version for free.
    ///
    /// The session is told afterwards, and only if the pasteboard took it: the
    /// plate says the summary is on the clipboard, and a copy that failed is
    /// not something to say happened.
    @objc func copySummary() {
        guard !summaryBlocks.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([Self.richText(of: summaryBlocks)]) else { return }
        onSummaryCopied?()
    }

    /// A picture of the whole summary on the clipboard — all of it, not the
    /// part that happens to be scrolled into view: the document view is as tall
    /// as its rows, and that is what is cached.
    @objc func copyScreenshot() {
        guard !summaryBlocks.isEmpty, let image = summaryPicture() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([image]) else { return }
        onScreenshotCopied?()
    }

    /// A picture of the summary's rows, drawn whole and cropped to them.
    ///
    /// The rows rather than the list they scroll in: the list is as wide as the
    /// panel and at least as tall as the visible area, so picturing it would
    /// hand over the summary in the middle of a field of empty background.
    /// `cacheDisplay` draws a view and everything under it whatever an ancestor
    /// clips, so the rows below the fold come too.
    ///
    /// Nil when there is nothing laid out to draw — a panel that has never been
    /// on screen has no size.
    func summaryPicture() -> NSImage? {
        let rows = summaryScroll.content
        let bounds = rows.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let cache = rows.bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        rows.cacheDisplay(in: bounds, to: cache)
        let cached = NSImage(size: bounds.size)
        cached.addRepresentation(cache)

        let margin: CGFloat = 10
        let size = NSSize(width: bounds.width + margin * 2, height: bounds.height + margin * 2)
        let picture = NSImage(size: size)
        picture.lockFocus()
        // Under the theme the rows were *drawn* in, not the one that happens to
        // be current here. A dark panel's rows are pale, and a background
        // resolved outside its appearance comes back the light one — pale text
        // on white, which is a picture of nothing.
        summaryScroll.effectiveAppearance.performAsCurrentDrawingAppearance {
            // The rows draw no background of their own; the list behind them
            // does. Without it the picture would paste as text on nothing.
            (summaryScroll.drawsBackground ? summaryScroll.backgroundColor : .textBackgroundColor)
                .setFill()
            NSRect(origin: .zero, size: size).fill()
            cached.draw(in: NSRect(x: margin, y: margin,
                                   width: bounds.width, height: bounds.height))
        }
        picture.unlockFocus()
        return picture
    }

    /// The blocks as one attributed string. The label column is a tab stop
    /// rather than padding, so the values line up in whatever font the reader's
    /// document is in.
    static func richText(of blocks: [MEASummaryBlock]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let size = ToolPanelFont.size
        let rowStyle = NSMutableParagraphStyle()
        rowStyle.tabStops = [NSTextTab(textAlignment: .left, location: size * 16)]
        rowStyle.defaultTabInterval = size * 16
        rowStyle.headIndent = size * 16

        for block in blocks {
            if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
            if let title = block.title {
                text.append(NSAttributedString(string: title + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: size + 1, weight: .semibold),
                ]))
            }
            for row in block.rows {
                text.append(NSAttributedString(string: row.label + "\t", attributes: [
                    .font: NSFont.systemFont(ofSize: size),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: rowStyle,
                ]))
                // The words and the weight the panel gives the row.
                let value = row.value.text(in: Localization.appLanguage)
                let emphasized = row.isEmphasized
                text.append(NSAttributedString(string: value + "\n", attributes: [
                    .font: value.hasPrefix("0x")
                        ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
                        : NSFont.systemFont(ofSize: size, weight: emphasized ? .bold : .regular),
                    .foregroundColor: row.tone.color,
                    .paragraphStyle: rowStyle,
                ]))
            }
        }
        return text
    }

    // MARK: - A parse's progress

    func showBusy() {
        guard progressBar.superview == nil else { return }
        progressBar.startAnimation(nil)
        bottomRow.addArrangedSubview(progressBar)
    }

    func endBusy() {
        guard progressBar.superview != nil else { return }
        progressBar.stopAnimation(nil)
        bottomRow.removeArrangedSubview(progressBar)
        progressBar.removeFromSuperview()
    }

    /// A line under the content — what happened, or what to do next.
    func say(_ text: String, asProblem: Bool = false) {
        noticeLabel.stringValue = text
        noticeLabel.textColor = asProblem ? SemanticColors.bad : SemanticColors.quiet
    }

    /// Show or hide the status row's Try Again, for a failure the user can act
    /// on (an offline database fetch, a rate limit).
    func showRetry(_ shown: Bool) {
        retryButton.isHidden = !shown
    }

    /// Everything the panel shows, in one call.
    func show(roots: [MEANode], focusPath: [Int]?, tab: Int) {
        self.roots = roots
        self.focusPath = focusPath
        isShowingState = true
        defer { isShowingState = false }

        selectTab(tab)
        outline.reloadData()
        updateRowMarks()
        let focus = focusPath.flatMap { MEATree.node(at: $0, in: roots) }
        renderDetail(focus)

        guard let focus else {
            outline.deselectAll(nil)
            return
        }
        expandPath(to: focusPath ?? [])
        let row = outline.row(forItem: focus)
        if row >= 0 {
            outline.scrollRowToVisible(row)
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    /// Expands each ancestor of the row so its row is on screen, like the UEFI
    /// tool re-opens the path to the node it is re-showing.
    private func expandPath(to path: [Int]) {
        guard !path.isEmpty else { return }
        for depth in 0..<path.count {
            let prefix = Array(path.prefix(depth + 1))
            guard let node = MEATree.node(at: prefix, in: roots) else { return }
            // The last step is the row itself; its ancestors above are expanded.
            if depth < path.count - 1, !node.children.isEmpty,
               outline.row(forItem: node) >= 0 {
                outline.expandItem(node)
            }
        }
    }

    // MARK: - Summary

    /// Hands the Summary tab the analysis's blocks. A re-show with the same
    /// blocks — a selection move, a parked restore that re-parsed the same
    /// file — changes nothing, so the user's scroll survives; a *different*
    /// summary (a fresh analysis, or none after a failure) is rebuilt and, when
    /// there is something to read, read from the top.
    func showSummary(_ blocks: [MEASummaryBlock]) {
        guard blocks != summaryBlocks else { return }
        summaryBlocks = blocks
        renderSummary()
        selectTab(tabIndex)
        if !blocks.isEmpty {
            summaryScroll.documentView?.scroll(.zero)
        }
    }

    /// The Configuration tab's blocks, fed and kept the way the summary's are.
    func showConfiguration(_ blocks: [MEAConfigurationBlock]) {
        guard blocks != configurationBlocks else { return }
        configurationBlocks = blocks
        renderConfiguration()
        selectTab(tabIndex)
        if !blocks.isEmpty {
            configurationScroll.documentView?.scroll(.zero)
        }
    }

    /// Rebuilds the summary's rows — the blocks `showSummary` last accepted,
    /// at the current zoom. Only label and value texts: the values come
    /// pre-formatted from `MEASummary`, so nothing is decided here.
    ///
    /// A block is one `ToolFieldList` — the same rows the UEFI Structure and
    /// this panel's own detail are drawn with — under the block's heading. The
    /// list is what gives a reader the selection: a drag down the rows takes a
    /// band of them, ⌘A the block, and ⌘C copies it with a tab between a name
    /// and its value, which a summary pasted into a report wants.
    private func renderSummary() {
        let stack = summaryScroll.content
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        summaryScroll.placeholder.isHidden = true

        for (index, block) in summaryBlocks.enumerated() {
            // A real gap before each block after the first (the table needs no
            // title, the messages block does — and both read better apart).
            if index > 0, let last = stack.arrangedSubviews.last {
                stack.setCustomSpacing(14, after: last)
            }
            if let title = block.title {
                let heading = NSTextField(labelWithString: title)
                heading.font = ToolPanelFont.title()
                heading.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(heading)
            }
            guard !block.rows.isEmpty else { continue }
            let rows = ToolFieldList(
                fields: block.rows.map(Self.summaryField),
                nameWidth: ToolPanelFont.scaled(Self.summaryLabelWidth))
            stack.addArrangedSubview(rows)
            // As wide as the list itself, so a long value has a column to wrap
            // inside rather than a line to run off the side of.
            rows.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    /// Rebuilds the Configuration tab's rows: one block per configuration
    /// file, each setting with the two copies of the file it lives in side by
    /// side.
    ///
    /// The rows are the shared detail list's (`ToolFieldList`), as the Summary
    /// tab's are — a row that draws its own texts, selected the way a text
    /// view's is, copied with a tab between the setting and each of its two
    /// copies — with a row's *second value* being the column the detail list
    /// does not otherwise carry. So the tab reads as a table and behaves as a
    /// list: the two columns line up down the page, and a drag across the rows
    /// takes a band of them.
    ///
    /// The name column is one width for every list in the tab, and so are the
    /// two value columns — which is what makes the columns of one file line up
    /// with the columns of the next, and with the heading row above them.
    ///
    /// A pair that disagrees is drawn bold — the one emphasis the tab uses, and
    /// no colour: a setting the platform rewrote is not a fault, and the
    /// palette's greens and browns are verdicts about a state, which this is
    /// not. A value one copy does not carry is not a disagreement — an image
    /// nobody has booted has one column and no argument — and is drawn as the
    /// quiet dash it is.
    private func renderConfiguration() {
        let stack = configurationScroll.content
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        configurationScroll.placeholder.isHidden = true

        let columns = configurationColumns
        let nameWidth = ToolFieldList.nameWidth(
            for: configurationBlocks.flatMap { $0.rows.map(\.name) })
        place(Self.configurationHeadingRow(columns, nameWidth: nameWidth), in: stack)
        for (index, block) in configurationBlocks.enumerated() {
            // The first block sits right under the column names, which is a
            // nearer relation than the next block is to the one before it.
            if let last = stack.arrangedSubviews.last {
                stack.setCustomSpacing(index == 0 ? 12 : 14, after: last)
            }
            stack.addArrangedSubview(Self.configurationFileHeading(block))
            let rows = ToolFieldList(
                fields: block.rows.map { row in
                    .init(label: row.name,
                          value: Self.configurationCell(columns.first(row),
                                                        differs: row.differs),
                          second: columns.compares
                              ? Self.configurationCell(row.mfs, differs: row.differs)
                              : nil)
                },
                nameWidth: nameWidth)
            place(rows, in: stack)
        }
    }

    /// Which of the tab's two value columns carry anything at all in this
    /// render. A copy the image does not carry in *any* file — no OEM
    /// Configuration partition at all, or a file system nobody could read — is
    /// not a column of dashes: the tab then names the one copy it has, in the
    /// one value column the rows have.
    private var configurationColumns: ConfigurationColumns {
        ConfigurationColumns(
            fitc: configurationBlocks.contains { block in
                block.rows.contains { $0.fitc != nil }
            },
            mfs: configurationBlocks.contains { block in
                block.rows.contains { $0.mfs != nil }
            })
    }

    /// Which of the two value columns carry values, and what the first of them
    /// is.
    private struct ConfigurationColumns {
        let fitc: Bool
        let mfs: Bool

        /// Whether the tab shows the two copies side by side — both of them
        /// present somewhere in this image.
        var compares: Bool { fitc && mfs }

        /// What the first value column shows: the build's copy where the image
        /// carries one, the file system's where it is the only one there is.
        func first(_ row: MEAConfigurationRow) -> String? { fitc ? row.fitc : row.mfs }

        /// What the first value column is called.
        var firstName: String { fitc ? MEAText.configurationFITC(in: Localization.appLanguage)
                                     : MEAText.configurationMFS(in: Localization.appLanguage) }
    }

    /// A block of the tab — a file's heading or its rows — into the list, as
    /// wide as the list itself, which is what gives the rows their width to
    /// divide into columns.
    private func place(_ row: NSView, in stack: NSStackView) {
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// A file's heading: MFIT's own name for it in bold, and where it lives and
    /// how long it is in the ordinary weight — one line, so the two read as one
    /// heading rather than as a title with a subtitle under it.
    private static func configurationFileHeading(_ block: MEAConfigurationBlock) -> NSTextField {
        let heading = NSTextField(labelWithString: "")
        let text = NSMutableAttributedString(
            string: block.alias, attributes: [.font: ToolPanelFont.title()])
        text.append(NSAttributedString(
            string: " " + block.detail,
            attributes: [.font: ToolPanelFont.body(), .foregroundColor: NSColor.secondaryLabelColor]))
        heading.attributedStringValue = text
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heading.translatesAutoresizingMaskIntoConstraints = false
        return heading
    }

    /// The tab's column names, once at the top: the rows' own component with an
    /// empty name, so the two names sit over the columns they name — the same
    /// widths, by construction, and no second set of column arithmetic to keep
    /// in step with the rows'.
    private static func configurationHeadingRow(_ columns: ConfigurationColumns,
                                                nameWidth: CGFloat) -> ToolFieldList {
        return ToolFieldList(
            fields: [.init(label: "",
                           value: configurationHeading(columns.firstName),
                           second: columns.compares
                               ? configurationHeading(MEAText.configurationMFS(
                                   in: Localization.appLanguage))
                               : nil)],
            nameWidth: nameWidth)
    }

    /// One column heading: the quiet weight a table's header carries, so it is
    /// read as a name for the column rather than as a row of its own.
    private static func configurationHeading(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: ToolPanelFont.body(weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    /// One value cell of a row. A pair that disagrees is drawn bold, in the
    /// ordinary colour: the emphasis, without a verdict. A value one copy does
    /// not carry is the quiet dash, in the colour of a thing that is not there.
    private static func configurationCell(_ text: String?, differs: Bool) -> NSAttributedString {
        guard let text else {
            return NSAttributedString(
                string: MEAText.configurationAbsent,
                attributes: [.font: ToolPanelFont.body(),
                             .foregroundColor: NSColor.tertiaryLabelColor])
        }
        return NSAttributedString(
            string: text,
            attributes: [.font: ToolPanelFont.body(weight: differs ? .semibold : .regular),
                         .foregroundColor: NSColor.labelColor])
    }

    /// One Summary row as a field of the shared detail list: the label, and the
    /// value drawn as the row's tone asks. A verdict is the answer in the
    /// row's tone and what it was read from in brackets in the ordinary font
    /// and colour — the tone is the verdict's, and the evidence beside it must
    /// not borrow it; a status value is bold and coloured, with the tick a
    /// passed check carries, all of it from the tone, which is the same
    /// rendering the tree's detail and the UEFI Structure's use; a
    /// `.comingSoon` value is drawn grey, the shape of a row the engine will
    /// answer once the bridge reaches it, and so is a `.pending` one, which
    /// the reading under way will answer.
    private static func summaryField(_ row: MEASummaryRow) -> ToolFieldList.Field {
        let text = row.value.text(in: Localization.appLanguage)
        switch row.value {
        case .verdict(let verdict, let evidence):
            return .init(label: row.label,
                         value: toned(verdict, tone: row.tone, evidence: evidence))
        case .value:
            return .init(label: row.label, value: row.tone.attributedValue(text))
        case .comingSoon, .pending:
            return .init(label: row.label, value: NSAttributedString(
                string: text,
                attributes: [.font: ToolPanelFont.body(),
                             .foregroundColor: NSColor.secondaryLabelColor]))
        }
    }

    /// A verdict in its tone, and what it was read from in brackets after it
    /// in the ordinary font and colour — one drawing for the Summary's rows and
    /// the tree's detail, so the two cannot come apart.
    private static func toned(_ verdict: String, tone: ToolValueTone,
                              evidence: String) -> NSAttributedString {
        let drawn = NSMutableAttributedString(attributedString: tone.attributedValue(verdict))
        if !evidence.isEmpty {
            drawn.append(ToolValueTone.standard.attributedValue(" (\(evidence))"))
        }
        return drawn
    }

    /// Rebuilds the detail list from the focused row's own fields.
    ///
    /// One `ToolFieldList` — the rows the UEFI Structure's detail is drawn
    /// with — so a bench selects and copies them here as it does there.
    private func renderDetail(_ focus: MEANode?) {
        // What the `?` in the list's corner explains: the glossary entry the
        // curator gave this row. Set before the early return as well, so a row
        // with no fields — an empty section — still offers the paragraph that
        // says what such a row *is*.
        detail.setTerm(focus?.helpTerm)
        guard let focus, !focus.fields.isEmpty else {
            detail.showPlaceholder(focus == nil
                ? L("Select a row to see what it is.")
                : L("Nothing more to show for this row."))
            return
        }
        detail.prepareForRows(subject: focus.title)

        let title = NSTextField(labelWithString: focus.title)
        title.font = ToolPanelFont.title()
        title.translatesAutoresizingMaskIntoConstraints = false
        detail.content.addArrangedSubview(title)

        // The engine's field names run long — "systemHeaderCRCValid",
        // "matchesMFSDictionary" — and the shared default column cut them off
        // mid-word. The column is as wide as the longest name it carries, so
        // one that fits is shown whole; never narrower than the default, so a
        // list of short names reads exactly as it did; and never wider than
        // half the list, where a name that still does not fit wraps rather
        // than crowding the value out.
        let fields = ToolFieldList(
            fields: focus.fields.map {
                // One rendering for a value that carries a status, wherever it
                // is drawn — bold, in the tone's colour, and led by the tick
                // when the status is a passed check. This is the same call the
                // UEFI Structure's detail makes for the same field, and the
                // Summary's row asks the tone for the same string, so the
                // three cannot come apart. Evidence follows in brackets in the
                // ordinary drawing, as the Summary's verdict rows carry theirs.
                .init(label: $0.label,
                      value: Self.toned($0.value, tone: $0.tone, evidence: $0.evidence))
            },
            nameWidth: ToolFieldList.nameWidth(for: focus.fields.map(\.label)))
        detail.content.addArrangedSubview(fields)
        // As wide as the list, so a value too long for the column — a hash, a
        // GUID — wraps inside it instead of running off the side.
        fields.widthAnchor.constraint(equalTo: detail.content.widthAnchor).isActive = true
    }
}

extension MEAToolViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard !roots.isEmpty else { return 0 }
        guard let node = item as? MEANode else { return roots.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? MEANode else { return roots[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? MEANode)?.children.isEmpty == false
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? MEANode, let identifier = tableColumn?.identifier
        else { return nil }
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView
            ?? ToolPanelTable.makeCell(identifier: identifier,
                                       warning: identifier == Column.name,
                                       badges: identifier == Column.name)
        cell.textField?.stringValue = text(for: node, in: identifier)
        // The row's problem and badges sit in the column the row is named by.
        if identifier == Column.name {
            ToolPanelTable.dress(cell, with: node.marks)
        }
        cell.textField?.font = identifier == Column.summary && node.subtitle.hasPrefix("0x")
            ? ToolPanelFont.monospacedDigits()
            : ToolPanelFont.body()
        // A section that holds nothing reads grey — the whole row, name
        // included: it is a place in the layout rather than something to go and
        // look at. Greying the value alone left the row reading as loud as a
        // real one, with the quiet half looking like a rendering slip rather
        // than a statement about the section.
        cell.textField?.textColor = node.isEmptySection
            ? .secondaryLabelColor
            : .labelColor
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = outlineView.makeView(withIdentifier: Self.rowViewIdentifier, owner: self)
            as? ToolPanelRowView ?? {
                let created = ToolPanelRowView()
                created.identifier = Self.rowViewIdentifier
                return created
            }()
        rowView.showsMarkings = legend.showsMarkings
        rowView.marks = (item as? MEANode)?.marks ?? .none
        return rowView
    }

    /// The row views on screen, given their rail again: reloading the cells
    /// does not reach a row view, and the switch changes every row at once.
    private func updateRowMarks() {
        outline.enumerateAvailableRowViews { rowView, row in
            guard let rowView = rowView as? ToolPanelRowView else { return }
            rowView.showsMarkings = legend.showsMarkings
            rowView.marks = (outline.item(atRow: row) as? MEANode)?.marks ?? .none
        }
    }

    private func text(
        for node: MEANode, in column: NSUserInterfaceItemIdentifier
    ) -> String {
        column == Column.summary ? node.subtitle : node.title
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isShowingState else { return }
        let row = outline.selectedRow
        let node = row >= 0 ? outline.item(atRow: row) as? MEANode : nil
        if outline.isHandlingClick { onWillChoose?() }
        onSelect?(node?.path)
    }
}

/// The tree, with no behaviour past NSOutlineView's — kept as its own subclass
/// so a future context menu (like the UEFI tool's Fix Checksum) has a home.
private final class MEOutlineView: ToolPanelOutlineView {}
