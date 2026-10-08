import ALSplitView
import AppKit
import HelpBook
import AppPalette
import HelpUI
import Localization
import MEPresentation
import ToolModuleKit
import UEFIImage
import UEFITool

/// The panel: the tree above, what the node in focus is below.
///
/// It decides nothing. The rows come from the pane's shared tree, the detail is
/// built and tested in the pure target, and the one zone is the presenter's —
/// so what is on screen comes from one `show(...)` over values the panel only
/// lays out. The one thing it does on its own is ask the tree for a branch when
/// a row is opened, and put a "Loading…" row there until it arrives.
@MainActor final class UEFIToolViewController: NSViewController {
    /// The node the user picked in the tree, or nil for nothing.
    var onSelect: ((NodeID?) -> Void)?
    /// The reader is about to choose a row on purpose — a click, a search
    /// match — rather than walk to it with the arrow keys: a step for the
    /// window's navigation history, taken before the choice changes.
    var onWillChoose: (() -> Void)?

    /// The tree takes the keyboard (`ToolSession.focusChoice`).
    func focusTree() {
        view.window?.makeFirstResponder(outline)
    }
    /// The title was clicked. Only ever fired when the summary stands for a
    /// node that has no row of its own.
    var onSelectTop: (() -> Void)?
    /// The title-row reveal button was clicked: show the node under the caret
    /// in the dump.
    var onRevealAtCaret: (() -> Void)?
    /// A node's Open item was chosen: the node itself, or its body alone
    /// (`Design/FRAGMENT_PANELS_PLAN.md`).
    var onOpenNode: ((NodeID, Bool) -> Void)?
    /// A node's Save As item was chosen: the node itself, or its body alone.
    var onSaveNode: ((NodeID, Bool) -> Void)?

    /// A flagged node's Fix Checksum menu item was chosen.
    var onFixChecksum: ((NodeID) -> Void)?
    /// A node in a Top Swap block asked for its twin in the other block.
    var onGoToTopSwapCounterpart: ((NodeID) -> Void)?
    /// A detail table's row named bytes that are not one node: outline them
    /// in the dump, under the name, and leave the focus where it is.
    var onOutlineRange: ((Range<UInt64>, String) -> Void)?
    /// A compressed section's Save Decompressed Body item was chosen.
    var onSaveDecompressed: ((NodeID) -> Void)?
    /// The same section's Open Decompressed Body item was chosen.
    var onOpenDecompressed: ((NodeID) -> Void)?
    /// A node's row was double-clicked: open what it holds
    /// (`UEFIPresenter.content(of:)`).
    var onOpenContent: ((NodeID) -> Void)?
    /// The Open Decompressed item of a bzip2 variable was chosen.
    var onOpenUnpacked: ((NodeID) -> Void)?
    /// The BIOS region's Compare with PFAT Update File item was chosen.
    var onCompareWithUpdate: ((NodeID) -> Void)?
    /// A row was opened or shut. What is open belongs to the file rather than
    /// to this panel, so the session writes it through to where the tree
    /// lives (`UEFITreeProviding.setOpenUEFIRows`).
    var onOpenRowsChanged: (() -> Void)?
    /// A row of the ME sub-tree was picked — its path under the ME region node.
    /// Kept apart from `onSelect` (a `NodeID`) because the two kinds of row
    /// resolve against different trees and the session keeps the two focuses
    /// apart too.
    var onSelectME: (([Int]?) -> Void)?
    /// The ME region node was opened: run the ME analysis (reusing the pane's
    /// cache) and open the row on the sub-tree it presents. The node is not
    /// expandable in the UEFI tree, so this is the only thing that opens it.
    var onOpenMERegion: ((NodeID) -> Void)?
    /// The ME analysis for the region node at `id` started or finished: the
    /// row shows a "Loading…" row while it runs, the way a slow UEFI branch
    /// does. `loading` is true when the analysis starts, false when it lands.
    var onMERegionLoading: ((NodeID, Bool) -> Void)?
    /// A search came round to the other end — going forward, when true. The
    /// session shows the same sign the hex view's find shows.
    var onSearchWrapped: ((Bool) -> Void)?

    /// The tree as one value, for everything that reads it rather than walks
    /// it: the summary line, the title fold, the detail panel. It is the
    /// pane's tree as materialized so far — the same nodes `tree` hands out,
    /// in a shape the pure target already knows how to read.
    private var image: UEFIImage?
    /// The pane's shared lazy tree — what the outline's rows and children come
    /// from, and what materializes a branch when a row is opened. Nil only
    /// before the first `show`, or when there is no file to read.
    private var tree: LazyUEFITree?
    /// The rows of the branch `childrenList` last listed, and what they were
    /// listed from.
    private var listedChildren: (id: NodeID, children: [UEFINode], showsEmptyPadding: Bool,
                                 showsSuperseded: Bool, rows: [Any])?
    /// Per store, the copies of its variables the tree leaves out and the
    /// copy each stands behind (`NvramVariableHistory.supersededCopies`), with
    /// the children they were read from — the same storage test as above.
    private var supersededByStore: [NodeID: (children: [UEFINode], copies: [NodeID: NodeID])] = [:]
    /// True while the tree's top level is still being worked out — a signature
    /// scan of a chip dump with no descriptor, which is the one thing about
    /// opening an image that is never instant. The outline shows one
    /// "Loading…" row for the duration.
    private var isBuilding = false
    /// The tree as it is shown: the outline's top level and the root node the
    /// summary stands for, decided in the pure target. Kept from one show to
    /// the next so the data source reads the same top level the last show laid
    /// out.
    private var presented = UEFITreeDisplay.PresentedImage(title: nil, rows: [])
    /// Whether the tree lists empty padding — off until the reader turns it on
    /// from the tree's menu, and remembered like the panel's other settings.
    private(set) var showsEmptyPadding = ToolPanelFont.defaults.bool(forKey: showsEmptyPaddingKey)
    static let showsEmptyPaddingKey = "UEFIStructure.ShowsEmptyPadding"
    /// Whether the tree lists the copies of variables later entries replaced.
    /// Off unless asked for: on a board that writes a variable every boot
    /// they are nine rows in ten, and each one's history is in the detail of
    /// the copy that stands.
    private(set) var showsSupersededEntries = ToolPanelFont.defaults.bool(forKey: showsSupersededEntriesKey)
    static let showsSupersededEntriesKey = "UEFIStructure.ShowsSupersededEntries"
    private var focus: NodeID?
    /// The detail on screen, kept so the rows can be rebuilt at a new type
    /// size without waiting for the next parse — a zoom is not a re-read.
    private var detailShown: UEFINodeDetail = .empty
    private var detailSubject = ""
    /// The folding tables the reader has opened, by title — kept for the
    /// panel's life, so a table opened on one node is open on the next and
    /// stays open through a re-render, and folded again only at the next
    /// launch.
    private var unfoldedTables: Set<String> = []
    /// The folding tables on screen, by title.
    private var tableFolds: [String: TableFold] = [:]

    /// A folding table on screen: its heading and triangle, what it lists,
    /// and its grid once built. A folded table's grid is not built until it
    /// is first opened: a descriptor's strap words are some three hundred
    /// cells, and building and laying them out was most of the quarter of a
    /// second a click on the descriptor took — for a grid nobody saw.
    private final class TableFold {
        let button: NSButton
        let heading: NSView
        let table: UEFIDetailTable
        var grid: NSView?

        init(button: NSButton, heading: NSView, table: UEFIDetailTable) {
            self.button = button
            self.heading = heading
            self.table = table
        }
    }
    /// The glossary entry the detail list's `?` opens, kept beside the detail
    /// itself so a re-render at a new type size keeps the button.
    private var detailTerm: HelpTermID?
    /// The GUID catalogue the names are read from. The session owns it — it
    /// downloads a fresh one in the background and passes it in on every show —
    /// so the tree shows the GUIDs themselves at first paint and the catalogue
    /// names once the download lands.
    private var catalogue: GuidsCatalogue = .empty
    /// True while the tree is being loaded from the model — a selection the
    /// code made is not news, and without this the panel selects, publishes,
    /// re-shows and selects again until the stack runs out.
    private var isShowingState = false
    /// The nodes whose checksums the last parse found wrong, keyed by node id.
    /// The red triangle before a name and the Fix Checksum menu item both ask
    /// it.
    private var badChecksums: [NodeID: Set<UEFIChecksumField>] = [:]
    /// Whether the file is open for writing. Without it the Fix Checksum menu
    /// item stands down — the module would refuse anyway, but a greyed item
    /// says so before the click.
    private var canWrite = false
    /// One row object per path, so the outline is handed the same item for the
    /// same node every time (`UEFITreeRow`). Emptied when the tree is replaced
    /// or cut back, which is also when the outline's own expansion state stops
    /// meaning anything.
    private var rows: [NodeID: UEFITreeRow] = [:]
    /// The "Loading…" rows, one per branch being read, kept apart from the
    /// rows above so the two never hand out the same object for the same path.
    private var loadingRows: [NodeID: UEFITreeRow] = [:]
    /// The presented ME sub-tree — the rows the ME region node opens onto.
    /// Empty until the ME analysis has run (or was cached), which is why the
    /// region's row is shut on first paint and opens only once this is filled.
    private var meRoots: [MEANode] = []
    /// One row object per ME path, so the outline is handed the same item for
    /// the same ME node every time, the way `rows` does for the UEFI tree.
    private var meRows: [[Int]: MEOutlineRow] = [:]
    /// The ME row in focus, as its path under the ME region node — what the
    /// outline re-selects on a show and the detail and zone read back. Nil when
    /// the focus is a UEFI node or nothing.
    private var meFocus: [Int]?
    /// The ME region's analysis, in flight the moment the reader opened the
    /// row until it lands — the ME half of `opening`, kept apart because the
    /// analysis is run by the session rather than read by the tree. The row
    /// stays shut while it is in flight, and earns a "Loading…" row if it is
    /// slow enough, the way a UEFI branch does.
    private var meOpening: NodeID?
    /// Branches the reader has asked for and the tree has not answered yet,
    /// with the moment we asked. The row stays *shut* while one is in flight:
    /// opening it onto a "Loading…" row that is replaced a few milliseconds
    /// later is two animations over the same rows, and what that looks like is
    /// the whole table rippling.
    private var opening: [NodeID: Date] = [:]
    /// The branches slow enough to have earned a "Loading…" row.
    private var showingPlaceholder: Set<NodeID> = []
    /// How long a branch may take before the reader is told it is being read.
    /// Under this, the row simply opens when it is ready and no placeholder is
    /// ever drawn — which is the common case and the one that used to ripple.
    private static var placeholderDelay: TimeInterval { UEFIToolModule.loadingRowDelay }
    /// How long a row takes to open. Ours to choose, because every expansion
    /// here is the panel's own (`outlineView(_:shouldExpandItem:)` refuses the
    /// click and the panel opens the row when there is something in it), and
    /// it is the window during which nothing else may touch the table.
    private static let expandAnimation: TimeInterval = 0.25

    /// Changes to the table, run one at a time.
    ///
    /// A row opening is an animation, and so is a "Loading…" row giving way to
    /// what was under it. A change that lands on rows another is still moving
    /// leaves the outline animating towards a layout that no longer exists,
    /// and what that looks like is a wave running through the whole table. So
    /// they queue: each runs inside its own animation group, and the next
    /// starts when that group is done.
    private var queued: [(animated: Bool, body: @MainActor () -> Void)] = []
    private var isAnimating = false
    /// True while a key held back by `holdsKeyWhileChanging` is pressed: it
    /// has waited its turn, and is not held again.
    private var isPressingHeldKey = false
    /// Whether a refresh is already queued, and whether any of the shows it
    /// stands for moved rows. One refresh serves however many shows land while
    /// an animation runs.
    private var queuedRefresh: Bool?

    private let summaryLabel = NSTextField(labelWithString: "")
    /// The title row's right-hand button: reveal in the tree the node under
    /// the caret in the dump. Same glyph as the toolbar's Go To, because it is
    /// the same act — go where the caret points — pointed at the tree instead
    /// of the dump.
    /// Replaces the question `askToShowEmptyPadding` puts to the reader; the
    /// answer is whether to show the rows. Tests set it.
    var emptyPaddingQuestion: ((@escaping (Bool) -> Void) -> Void)?

    private let revealButton = NSButton()
    /// What the tree leaves out — empty padding, the copies later entries
    /// replaced — as a menu under one icon left of the reveal button. Ticked
    /// out in the title row, the choices took the width the image's name
    /// needs; they are set once and seldom changed, so a click away is near
    /// enough. The icon is tinted while the tree lists anything it leaves out
    /// by default, so a longer tree than usual says why.
    private let filterButton = NSButton()
    /// Opens and shuts the search bar: left of the filter, the same quiet icon.
    private let searchButton = NSButton()
    private let searchBar = UEFISearchBar()
    /// What the search has opened in the tree and owes a closing.
    private var searchOpenings = UEFISearchOpenings()
    /// The match the search last stood on: where it goes on from, until the
    /// reader selects another row. Shutting the branch it is in takes the
    /// selection away, but not the place.
    private var searchCursor: NodeID?
    /// True while the panel itself opens a row — a reveal, a restore, a
    /// search, a branch arriving — so the outline's notice is told apart from
    /// a row the reader opened.
    private var isPanelExpanding = false
    /// True while the selection being reported is the reader's own — a click
    /// or a key moved it — rather than one the panel made (a search match, a
    /// reveal), which reports itself in the middle of its own work.
    private(set) var isReportingReadersSelection = false
    /// True while the panel itself is folding a row (`panelCollapses`): a
    /// fold of the panel's own is not the reader's, and is not held back to
    /// keep the scroll still (`foldsBeforeScrolling`).
    private var isPanelCollapsing = false
    /// Rows the reader opened whose branch was still being read: once it is
    /// there, the tree scrolls to show it.
    private var openedByReader: Set<NodeID> = []
    /// Which search is the current one: a new ask, a changed query or a new
    /// tree makes the number move on, and a search still reading branches
    /// finds itself out of date and stops.
    private var searchRun = 0
    /// The query the panel last saw, so a change is told from a repeat.
    private var shownQuery = UEFISearchSettings.query
    private var searchObserver: NSObjectProtocol?
    private var splitterBelowSummary: NSLayoutConstraint?
    private var splitterBelowBar: NSLayoutConstraint?
    private let paddingItem = NSMenuItem(title: L("Show Empty Padding"), action: nil, keyEquivalent: "")
    private let supersededItem = NSMenuItem(title: L("Show Superseded Entries"), action: nil, keyEquivalent: "")
    private let outline = UEFIOutlineView()
    private let outlineScroll = NSScrollView()
    /// The tree and its legend, as one pane of the splitter: the legend
    /// explains the rows, and opens into the tree's room rather than the
    /// detail's.
    private let treePane = NSView()
    private let legend = ToolRowMarksLegend(panel: "UEFIStructure", marks: UEFITreeMarks.legendMarks)
    private static let rowViewIdentifier = NSUserInterfaceItemIdentifier("uefiRow")
    /// The detail list in its pane, and the large view Space opens it into.
    let detailPane = ToolDetailPane()
    private var detail: ToolDetailScroll { detailPane.detail }
    private let splitter = ALSplitView()
    private let noticeLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let bottomRow = NSStackView()
    /// The panel draws at the app's zoom (`ToolPanelFont`); this is what tells
    /// it the zoom moved.
    private var zoomObserver: NSObjectProtocol?

    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let type = NSUserInterfaceItemIdentifier("type")
        static let subtype = NSUserInterfaceItemIdentifier("subtype")
    }

    /// What each column was laid out at — a width for text at
    /// `ToolPanelFont.designSize`, scaled from there to the size the zoom is
    /// at.
    ///
    /// Type and Subtype are as wide as the words they hold and no wider: what
    /// they say is one short word on almost every row ("Volume", "Section",
    /// "Driver", "Free space"), and the few long ones — "FlashDeviceMap store"
    /// — are not worth two columns of empty space on every other row. Name is
    /// the column with something to say, so it gets the rest: the widest thing
    /// in the tree is a GUID or a catalogue name, and a truncated one is the
    /// row the reader came for.
    ///
    /// Both are as narrow as they can be and still hold the longest word a
    /// normal row puts in them — "Free space" and "Empty (FFh)", measured at
    /// the design size with the cell's own 2-point insets — so taking another
    /// few points off either would start truncating the rows that are there on
    /// every dump.
    private static let nameWidth: CGFloat = 319
    private static let typeWidth: CGFloat = 62
    private static let subtypeWidth: CGFloat = 69

    /// The size the widths on screen were scaled for. A zoom moves them by
    /// what has changed since, so a column the user dragged keeps the width
    /// they gave it rather than snapping back to the design's.
    private var columnWidthSize = ToolPanelFont.designSize

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 520))
        view.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = ToolPanelFont.body(weight: .medium)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        // The title names the image, not a row: the one root the tree folded
        // into it is selected by a click as its row would. Without a root to
        // fold, the title is not clickable — the module guards.
        summaryLabel.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(summaryClicked))
        )

        // Borderless and quiet, like every other icon control in a panel
        // header: the glyph carries the meaning, not a bezel.
        // help: panel.uefi.reveal
        revealButton.image = NSImage(
            systemSymbolName: "dot.scope",
            accessibilityDescription: L("Reveal node at caret")
        )
        revealButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 12, weight: .regular
        )
        revealButton.isBordered = false
        revealButton.imagePosition = .imageOnly
        revealButton.contentTintColor = .secondaryLabelColor
        ControlHelp.describe(revealButton, L("Show the node under the caret in the tree"))
        revealButton.target = self
        revealButton.action = #selector(revealClicked)
        revealButton.translatesAutoresizingMaskIntoConstraints = false

        // help: panel.uefi.filter
        filterButton.image = NSImage(
            systemSymbolName: "line.3.horizontal.decrease.circle",
            accessibilityDescription: L("Filter")
        )
        filterButton.symbolConfiguration = revealButton.symbolConfiguration
        filterButton.isBordered = false
        filterButton.imagePosition = .imageOnly
        ControlHelp.describe(filterButton, name: L("Filter"), tooltip: L("Choose what the tree lists"))
        filterButton.target = self
        filterButton.action = #selector(filterClicked)
        filterButton.translatesAutoresizingMaskIntoConstraints = false

        // help: panel.uefi.search
        searchButton.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: L("Search the tree")
        )
        searchButton.symbolConfiguration = revealButton.symbolConfiguration
        searchButton.isBordered = false
        searchButton.imagePosition = .imageOnly
        ControlHelp.describe(searchButton, name: L("Search the tree"),
                             tooltip: L("Look for a node by its name, its GUID or its type"))
        searchButton.target = self
        searchButton.action = #selector(searchClicked)
        searchButton.translatesAutoresizingMaskIntoConstraints = false
        searchBar.onSearch = { [weak self] direction in self?.search(direction) }
        searchBar.onStop = { [weak self] in self?.stopSearching() }

        paddingItem.target = self
        paddingItem.action = #selector(paddingItemClicked)
        ControlHelp.describe(paddingItem, L("List the padding nobody wrote to — erased bytes between structures"))
        // help: panel.uefi.superseded-entries
        supersededItem.target = self
        supersededItem.action = #selector(supersededItemClicked)
        ControlHelp.describe(supersededItem, L("List the copies of variables that later entries replaced — their history is in the detail of the copy that stands"))
        let filterMenu = NSMenu()
        filterMenu.autoenablesItems = false
        filterMenu.addItem(paddingItem)
        filterMenu.addItem(supersededItem)
        // A right click opens it too, as a button with a menu does.
        filterButton.menu = filterMenu
        updateFilter()
        // The title gives way: a long image name truncates before it runs
        // under the buttons.
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureOutline()

        outlineScroll.hasVerticalScroller = true
        outlineScroll.hasHorizontalScroller = true
        outlineScroll.autohidesScrollers = true
        outlineScroll.borderType = .bezelBorder
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false
        outlineScroll.documentView = outline

        // Top: the tree. Bottom: the detail. The divider is the user's to
        // move. `ALSplitView` places its panes by frame from its own bounds, so
        // the third the detail starts with is a policy rather than a position
        // measured off a view that has not been laid out yet.
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

        noticeLabel.font = ToolPanelFont.body()
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.lineBreakMode = .byWordWrapping
        noticeLabel.maximumNumberOfLines = 2
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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
        view.addSubview(searchButton)
        view.addSubview(filterButton)
        view.addSubview(revealButton)
        view.addSubview(searchBar)
        view.addSubview(splitter)
        view.addSubview(bottomRow)

        let barWidth = progressBar.widthAnchor.constraint(equalToConstant: 150)
        barWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            summaryLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            summaryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            // The button owns the title row's right end; a long image name
            // truncates before it rather than running under it.
            summaryLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: searchButton.leadingAnchor, constant: -8
            ),
            searchButton.widthAnchor.constraint(equalToConstant: 18),
            searchButton.heightAnchor.constraint(equalToConstant: 18),
            searchButton.trailingAnchor.constraint(equalTo: filterButton.leadingAnchor, constant: -4),
            searchButton.centerYAnchor.constraint(equalTo: summaryLabel.centerYAnchor),
            filterButton.widthAnchor.constraint(equalToConstant: 18),
            filterButton.heightAnchor.constraint(equalToConstant: 18),
            filterButton.trailingAnchor.constraint(equalTo: revealButton.leadingAnchor, constant: -4),
            filterButton.centerYAnchor.constraint(equalTo: summaryLabel.centerYAnchor),

            // A small square: the glyph is 12 point, and a button the size of
            // its image alone would be a needlessly thin thing to hit.
            revealButton.widthAnchor.constraint(equalToConstant: 18),
            revealButton.heightAnchor.constraint(equalToConstant: 18),
            revealButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            revealButton.centerYAnchor.constraint(equalTo: summaryLabel.centerYAnchor),

            searchBar.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 8),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            splitter.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            splitter.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            splitter.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -6),

            bottomRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            bottomRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            bottomRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            barWidth
        ])

        // The tree starts under the title, or under the search bar while it is
        // open; one of the two is always in force.
        splitterBelowSummary = splitter.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 6)
        splitterBelowBar = splitter.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 10)
        applySearchVisibility()
        searchObserver = NotificationCenter.default.addObserver(
            forName: UEFISearchSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.searchSettingsChanged() }
        }

        zoomObserver = ToolPanelFont.observeZoom { [weak self] in
            self?.applyPanelFont()
        }
    }

    deinit {
        if let zoomObserver {
            NotificationCenter.default.removeObserver(zoomObserver)
        }
        if let searchObserver {
            NotificationCenter.default.removeObserver(searchObserver)
        }
    }

    /// Re-reads the panel's type size and puts everything on screen at it: the
    /// two lines around the splitter, the tree's rows and header, and the
    /// detail's own rows — which are views built per field, so they have to be
    /// rebuilt rather than restyled.
    private func applyPanelFont() {
        summaryLabel.font = ToolPanelFont.body(weight: .medium)
        noticeLabel.font = ToolPanelFont.body()
        searchBar.applyFont()
        ToolPanelTable.apply(to: outline)
        applyColumnWidths()
        outline.reloadData()
        renderDetail(detailShown, subject: detailSubject)
    }

    /// Moves the columns to the size on screen — the widths grow and shrink
    /// with the type, since a column that does not is a column whose text no
    /// longer fits it.
    private func applyColumnWidths() {
        let size = ToolPanelFont.size
        guard size != columnWidthSize else { return }
        ToolPanelTable.scaleColumnWidths(of: outline, by: size / columnWidthSize)
        columnWidthSize = size
    }

    private func configureOutline() {
        outline.style = .inset
        // An opened row's indentation comes out of the Name column rather than
        // widening it: widened, the outline outgrows its scroll view, and the
        // inset style's margins — and the rounded selection — scroll off the
        // edges (the system's own behaviour, Finder's list view does the same).
        outline.autoresizesOutlineColumn = false
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = false
        // The column order is the design's, not a drag target.
        outline.allowsColumnReordering = false
        outline.dataSource = self
        outline.delegate = self
        // A right-click is answered here rather than with a `menu` assigned to
        // the view: a plain menu pops over a clean row too, and this panel's
        // whole contextual menu is the one item a flagged row earns.
        outline.onContextMenu = { [weak self] event in self?.contextMenu(for: event) }
        // A click on the row that is already the selection publishes its zone,
        // exactly as a click that moved the selection would — the outline only
        // reports that second kind itself (see `UEFIOutlineView`).
        outline.onRowReclick = { [weak self] row in self?.chooseNode(atRow: row) }
        // A double click opens what the row holds as a panel over the dump.
        outline.onRowDoubleClick = { [weak self] row in self?.openContent(atRow: row) }
        outline.holdsKey = { [weak self] event in self?.holdsKeyWhileChanging(event) ?? false }

        let name = NSTableColumn(identifier: Column.name)
        name.title = L("Name")
        name.width = Self.nameWidth
        // Draggable, and the one column that also takes the slack when the
        // panel is resized. Without `.userResizingMask` a column cannot be
        // dragged at all, whatever `allowsColumnResizing` says.
        name.resizingMask = [.autoresizingMask, .userResizingMask]
        outline.addTableColumn(name)
        outline.outlineTableColumn = name

        let type = NSTableColumn(identifier: Column.type)
        type.title = L("Type")
        type.width = Self.typeWidth
        type.resizingMask = .userResizingMask
        outline.addTableColumn(type)

        let subtype = NSTableColumn(identifier: Column.subtype)
        subtype.title = L("Subtype")
        subtype.width = Self.subtypeWidth
        subtype.resizingMask = .userResizingMask
        outline.addTableColumn(subtype)

        // The rows, the header and the widths — laid out just above for text at
        // `ToolPanelFont.designSize` — follow the app's zoom, so this comes
        // after the columns exist rather than with the rest of the tree's
        // setup.
        ToolPanelTable.apply(to: outline)
        applyColumnWidths()
    }

    // MARK: - A parse's progress

    /// Something is being read. Indeterminate on purpose: what the panel waits
    /// for now is a branch of the tree or a node's checksum, and neither
    /// reports a fraction of anything the reader would recognise.
    func showBusy() {
        guard progressBar.superview == nil else { return }
        bottomRow.addArrangedSubview(progressBar)
        progressBar.startAnimation(nil)
    }

    func endBusy() {
        guard progressBar.superview != nil else { return }
        progressBar.stopAnimation(nil)
        bottomRow.removeArrangedSubview(progressBar)
        progressBar.removeFromSuperview()
    }

    /// A line under the splitter — what happened, or what to do next.
    func say(_ text: String, asProblem: Bool = false) {
        noticeLabel.stringValue = text
        noticeLabel.textColor = asProblem ? SemanticColors.bad : SemanticColors.quiet
    }

    /// Everything the panel shows, in one call. `tree` is the pane's shared
    /// lazy tree — what the outline's rows are materialized from; `image` is
    /// the same tree as one value, which is what the summary line, the title
    /// fold and the detail panel read.
    ///
    /// `rowsChanged` says whether the *set* of rows can have moved. A branch
    /// arriving is not one of these — the panel opens that row itself, in one
    /// animation — so the common shows (a checksum pass, the GUID catalogue, a
    /// selection) only re-render what is already there.
    func show(
        image: UEFIImage?,
        tree: LazyUEFITree?,
        focus: NodeID?,
        detail: UEFINodeDetail,
        /// What the `?` in the detail list's corner explains: the glossary
        /// entry for the node in focus. Decided by the session, which is what
        /// holds the node — the panel is handed a `UEFINodeDetail`, which is
        /// fields and has no kind to ask about.
        helpTerm: HelpTermID? = nil,
        catalogue: GuidsCatalogue,
        badChecksums: [NodeID: Set<UEFIChecksumField>],
        canWrite: Bool,
        isBuilding: Bool,
        rowsChanged: Bool,
        meRoots: [MEANode] = [],
        meFocus: [Int]? = nil
    ) {
        // A different tree is a different file: the rows standing for the old
        // one's paths mean nothing now, and the outline's memory of which of
        // them were open means nothing either. The ME sub-tree goes with it —
        // it is built from this file's ME region, and a new file has its own.
        if tree !== self.tree {
            rows.removeAll()
            loadingRows.removeAll()
            meRows.removeAll()
            // The loading latches are keyed by path, and a new file's rows have
            // the same paths: its ME region would inherit the last file's dead
            // "Loading…" row. Both go with the rows they stood for.
            showingPlaceholder.removeAll()
            meOpening = nil
            supersededByStore.removeAll()
            listedChildren = nil
            // What the search opened was in the last file's tree.
            cancelSearch()
            searchOpenings.release()
            searchCursor = nil
        }
        self.image = image
        self.tree = tree
        self.focus = focus
        self.catalogue = catalogue
        self.badChecksums = badChecksums
        self.canWrite = canWrite
        self.isBuilding = isBuilding
        self.meRoots = meRoots
        self.meFocus = meFocus
        // Without a tree there is nothing to reveal the caret into.
        revealButton.isEnabled = image != nil
        isShowingState = true
        defer { isShowingState = false }

        presented = image.map(UEFITreeDisplay.present)
            ?? UEFITreeDisplay.PresentedImage(title: nil, rows: [])
        summaryLabel.stringValue = UEFITreeDisplay.summary(of: image)
        searchBar.showsMENote = presented.rows.contains(where: isMERegion)
        updateSummaryEmphasis()
        // What the protected ranges in the summary cannot say (§8).
        if let ranges = image?.protectedRanges, !ranges.ranges.isEmpty {
            summaryLabel.toolTip = [summaryLabel.toolTip, UEFIDetail.protectionCaveat]
                .compactMap { $0 }.joined(separator: "\n\n")
        }
        detailTerm = helpTerm
        renderDetail(detail, subject: focus?.description ?? "")
        queueRefresh(rowsChanged: rowsChanged)
    }

    /// A new focus, and nothing else: the detail is drawn for it and the
    /// title's emphasis follows it. The tree is not presented again and no
    /// row of the table is reloaded — a row draws nothing that depends on the
    /// focus, and the selection is already where the reader put it. Doing the
    /// whole of `show` on every step of an arrow key held down walked the
    /// whole image and rebuilt every row on screen, and the table stuttered.
    ///
    /// False, and nothing done, when the panel is not showing `tree` as it
    /// is: the caller shows it whole instead.
    func showSelection(of tree: LazyUEFITree, focus: NodeID?, detail: UEFINodeDetail,
                       helpTerm: HelpTermID?, meFocus: [Int]?) -> Bool {
        guard tree === self.tree, !isBuilding else { return false }
        self.focus = focus
        self.meFocus = meFocus
        detailTerm = helpTerm
        renderDetail(detail, subject: focus?.description ?? "")
        updateSummaryEmphasis()
        return true
    }

    /// The table half of a show, queued behind whatever the outline is
    /// animating. Everything it reads is already stored above, so a refresh
    /// that runs a moment later draws the latest state rather than the state
    /// its own show was called with — which is why several shows arriving
    /// during one animation collapse into one refresh.
    private func queueRefresh(rowsChanged: Bool) {
        if let already = queuedRefresh {
            queuedRefresh = already || rowsChanged
            return
        }
        queuedRefresh = rowsChanged
        enqueue(animated: false) { [weak self] in
            guard let self else { return }
            let rowsChanged = self.queuedRefresh ?? false
            self.queuedRefresh = nil
            self.refreshTheOutline(rowsChanged: rowsChanged)
            self.updateRowMarks()
        }
    }

    private func refreshTheOutline(rowsChanged: Bool) {
        isShowingState = true
        defer { isShowingState = false }

        if rowsChanged {
            outline.reloadData()
        } else {
            // Only what the rows *say* changed — a checksum pass landing, the
            // GUID catalogue arriving, a new selection. Re-rendering the cells
            // leaves the row set alone.
            outline.reloadData(
                forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows),
                columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns)
            )
        }

        // The ME focus is the sub-tree's half of the selection: it reveals its
        // own row, not a UEFI node. The two focuses are apart, so only one is
        // in play at a time.
        if let meFocus {
            revealME(meFocus)
            return
        }

        // The focus is the root the tree folded into the title: it has no row
        // to select, and the title already stands for it in accent colour, so
        // there is nothing to do to the tree.
        if presented.title != nil, focus == presented.title?.id {
            outline.deselectAll(nil)
            return
        }

        guard let focus, let tree, tree.node(focus) != nil else {
            outline.deselectAll(nil)
            return
        }
        reveal(focus, in: tree)
    }

    /// The ME sub-tree's half of `reveal`: selects and scrolls to the row at
    /// `path`. Its ancestors are the ME region node and the rows above it in
    /// the sub-tree — opened on the way the UEFI reveal opens its own — so the
    /// row exists by the time a selection is asked to land on it.
    private func revealME(_ path: [Int]) {
        guard !path.isEmpty else {
            deselectForShow()
            return
        }
        // Open every ME ancestor the row sits under. The sub-tree is a value,
        // so an ancestor's children are always in hand and each opens at once —
        // unlike a UEFI branch, which may still be reading.
        for depth in 1..<path.count {
            let index = outline.row(forItem: meRow(Array(path.prefix(depth))))
            guard index >= 0 else { return }
            let item = outline.item(atRow: index)
            if !outline.isItemExpanded(item) {
                panelExpands { outline.expandItem(item) }
            }
        }
        let row = outline.row(forItem: meRow(path))
        guard row >= 0 else {
            deselectForShow()
            return
        }
        // The same rule the UEFI half's `selectAndScroll` keeps: a show that
        // finds the row where it already was does not move the table.
        guard outline.selectedRow != row else { return }
        outline.scrollRowToVisible(row)
        // The selection is the panel's own doing, not the reader's, so it must
        // not read back as a click — the same reason `reveal` sets this around
        // its own selection. This reaches here from inside a scope that may
        // already hold it, so it is put back as it was found rather than
        // cleared.
        let wasShowingState = isShowingState
        isShowingState = true
        defer { isShowingState = wasShowingState }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// Clears the outline's selection without the panel reading it back as the
    /// reader having picked nothing, which would drop the focus and publish an
    /// empty zone map off a path that merely stopped resolving.
    private func deselectForShow() {
        let wasShowingState = isShowingState
        isShowingState = true
        defer { isShowingState = wasShowingState }
        outline.deselectAll(nil)
    }

    /// The ME analysis has landed for the region node at `id`: open its row onto
    /// the sub-tree it presents, then settle the selection on the row `preferred`
    /// names while it resolves — else on the ME focus, else on the first root, so
    /// an open always lands somewhere. The region row is a UEFI row, so it opens
    /// through the UEFI path; the sub-tree it opens onto is the ME half, and the
    /// selection that follows it is a ME reveal.
    func openMERegion(_ id: NodeID, settlingOn preferred: [Int]? = nil) {
        expandRow(id) { [weak self] in
            guard let self else { return }
            let settled = [preferred, self.meFocus].compactMap { $0 }
                .first { self.meNode(of: self.meRow($0)) != nil }
                ?? self.meRoots.first?.path
            guard let settled else { return }
            self.revealME(settled)
            // The panel chose this row, so the session is told outright rather
            // than the outline being asked. A selection read back off the
            // delegate is one the panel mistakes for a click; and guarding that
            // read-back the way the UEFI half's `reveal` does — which is what
            // `revealME` now does — would leave the row highlighted with no
            // detail and no zones behind it.
            self.onSelectME?(settled)
        }
    }

    // MARK: - One change to the table at a time

    /// A key that moves through the tree, pressed while the table is still
    /// changing — a row opening or folding, the scroll that goes with it —
    /// waits its turn behind the change and is pressed then, in order.
    ///
    /// Pressed at once, it moved from the table as it was: the row opening
    /// had not got its rows yet, so Down went past them to the next row, which
    /// by the time the change landed could be off the screen. A key is not
    /// dropped either — the reader pressed it — only put where it means what
    /// the reader meant.
    private func holdsKeyWhileChanging(_ event: NSEvent) -> Bool {
        guard !isPressingHeldKey, isAnimating || !queued.isEmpty,
              Self.navigationKeys.contains(event.keyCode) else { return false }
        enqueue(animated: false) { [weak self] in
            guard let self else { return }
            self.isPressingHeldKey = true
            defer { self.isPressingHeldKey = false }
            self.outline.keyDown(with: event)
        }
        return true
    }

    /// The arrows, Page Up and Down, Home and End.
    private static let navigationKeys: Set<UInt16> = [123, 124, 125, 126, 116, 121, 115, 119]

    private func enqueue(animated: Bool, _ body: @escaping @MainActor () -> Void) {
        queued.append((animated, body))
        runTheNextChange()
    }

    private func runTheNextChange() {
        guard !isAnimating, !queued.isEmpty else { return }
        let change = queued.removeFirst()
        isAnimating = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = change.animated ? Self.expandAnimation : 0
            change.body()
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAnimating = false
                self.runTheNextChange()
            }
        }
    }

    /// Selects and scrolls to `nodeID`'s row, expanding every ancestor first —
    /// through the tree (materializing a closed volume or region) and then in
    /// the outline itself. An ancestor's expansion finishes later than this
    /// call; either way, the selection lands once the whole path is as
    /// expanded as it can be.
    private func reveal(_ nodeID: NodeID, in tree: LazyUEFITree) {
        // Only while the node is still the focus: a reveal queued behind a
        // branch that was being read must not open the rows above a node the
        // reader — or the tree's search — has since moved away from, after
        // they were shut.
        expandAncestors(of: nodeID, in: tree, while: { [weak self] in self?.focus == nodeID }) { [weak self] in
            // Still the focus at the end of the way, too: the branches on the
            // way are read off the main actor, and by the time they land the
            // search or the reader may have chosen another node. The reveal
            // that selected the old one then took the selection back from the
            // new one — what the full show after every selection used to
            // paper over, by revealing the focus again.
            guard let self, self.focus == nodeID, tree.node(nodeID) != nil else { return }
            // The selection is the panel's own doing, not the reader's, so it
            // must not read back as a click — that would publish a zone and
            // scroll the dump away from the byte a reveal was asked about.
            self.isShowingState = true
            defer { self.isShowingState = false }
            self.selectAndScroll(to: nodeID)
        }
    }

    private func selectAndScroll(to nodeID: NodeID) {
        var row = outline.row(forItem: row(nodeID))
        // A copy the tree leaves out is shown by the row of the copy it stands
        // behind; its own detail stays up.
        if row < 0, !showsSupersededEntries, !nodeID.path.isEmpty,
           let store = tree?.node(NodeID(Array(nodeID.path.dropLast()))),
           let standing = supersededCopies(in: store)[nodeID] {
            row = outline.row(forItem: self.row(standing))
        }
        guard row >= 0 else { return }
        // A show that finds the focus where it already was — a branch opening,
        // the checksum pass that follows it, an edit — is not a reason to move
        // the table. The reader may have scrolled somewhere else to look at
        // something, and the row this would scroll to is already the selection,
        // so there is nothing to move to and nothing to select.
        guard outline.selectedRow != row else { return }
        outline.scrollRowToVisible(row)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// The rows that are open, by the place in the tree each stands for.
    var openRows: Set<NodeID> {
        var open: Set<NodeID> = []
        for row in 0..<outline.numberOfRows {
            guard let item = outline.item(atRow: row), outline.isItemExpanded(item),
                  let treeRow = item as? UEFITreeRow, !treeRow.isLoading
            else { continue }
            open.insert(treeRow.id)
        }
        return open
    }

    /// Puts back the rows that were open when the reader last looked at this
    /// file, outermost first — a row cannot be opened before the row holding
    /// it is, and a branch that has been dropped since is read again on the
    /// way. Each waits for the one before it, so every row exists by the time
    /// its own turn comes.
    func restoreOpenRows(_ rows: Set<NodeID>) {
        openInTurn(rows.sorted { $0.path.count < $1.path.count }, from: 0)
    }

    private func openInTurn(_ rows: [NodeID], from index: Int) {
        guard index < rows.count else { return }
        let id = rows[index]
        guard let tree, let node = tree.node(id) else {
            openInTurn(rows, from: index + 1)
            return
        }
        guard node.children.isEmpty, node.isExpandable else {
            expandRow(id) { [weak self] in self?.openInTurn(rows, from: index + 1) }
            return
        }
        tree.expand(id) { [weak self] _ in
            guard let self else { return }
            self.expandRow(id) { [weak self] in self?.openInTurn(rows, from: index + 1) }
        }
    }

    /// Opens `id`'s row, when it has one — animated, and behind whatever the
    /// outline is already animating.
    ///
    /// Through the outline's own item, resolved when the change runs rather
    /// than when it is queued: an outline recognises only the object it is
    /// itself holding, and by the time this runs the rows may have moved.
    private func expandRow(_ id: NodeID, while wanted: (@MainActor () -> Bool)? = nil,
                           then done: (@MainActor () -> Void)? = nil) {
        enqueue(animated: true) { [weak self] in
            guard let self else { return }
            if wanted?() ?? true, let item = self.outlineItem(for: id) {
                self.panelExpands { self.outline.animator().expandItem(item) }
            }
            // Inside the same step, so whatever follows an opening sees the
            // rows it opened. A caller that runs when the opening is merely
            // *queued* is a caller looking at a table that has not changed yet
            // — which is how a reveal came to open the tree and select nothing.
            done?()
        }
    }

    /// Expands, in order, every ancestor of `nodeID` that the tree has not
    /// already expanded — a volume synchronously, a region once its
    /// background scan completes — calling `completion` exactly once the
    /// whole path is as far along as it can go. Stops early, without calling
    /// `completion` again, if a step's node cannot be found (the path no
    /// longer resolves — an edit moved or removed it).
    private func expandAncestors(
        of nodeID: NodeID, in tree: LazyUEFITree, while wanted: (@MainActor () -> Bool)? = nil,
        completion: @escaping () -> Void
    ) {
        func step(_ index: Int) {
            guard index < nodeID.path.count - 1 else { completion(); return }
            let partialID = NodeID(Array(nodeID.path.prefix(index + 1)))
            guard let ancestor = tree.node(partialID) else { completion(); return }
            guard ancestor.isExpandable, ancestor.children.isEmpty else {
                expandRow(partialID, while: wanted) { step(index + 1) }
                return
            }
            tree.expand(partialID) { [weak self] _ in
                guard let self else { return }
                self.expandRow(partialID, while: wanted) { step(index + 1) }
            }
        }
        step(0)
    }

    /// The title reads as clickable only when it stands for a folded root, and
    /// reads as *selected* when that root is the focus — the accent colour is
    /// the row the root would have got.
    private func updateSummaryEmphasis() {
        guard presented.title != nil else {
            summaryLabel.toolTip = nil
            summaryLabel.textColor = .labelColor
            return
        }
        summaryLabel.toolTip = L("Show the whole image in the dump")
        summaryLabel.textColor = focus == presented.title?.id ? .controlAccentColor : .labelColor
    }

    /// Rebuilds the detail list from the fields the pure target decided.
    private func renderDetail(_ node: UEFINodeDetail, subject: String) {
        detailShown = node
        detailSubject = subject
        tableFolds.removeAll()
        // What the `?` in the list's corner explains. Set before the early
        // return too: a node with no fields to list is still a node whose kind
        // the glossary can name.
        detail.setTerm(detailTerm)
        guard !node.fields.isEmpty else {
            detail.showPlaceholder(node.title.isEmpty
                ? L("Select a node to see what it is.")
                : node.title)
            return
        }
        detail.prepareForRows(subject: subject)

        if !node.title.isEmpty {
            let title = NSTextField(labelWithString: node.title)
            title.font = ToolPanelFont.title()
            title.translatesAutoresizingMaskIntoConstraints = false
            detail.content.addArrangedSubview(title)
        }

        // A view per field, its text selectable across the rows: a bench
        // copies an offset or a GUID out of here, and a value it cannot select
        // is one it has to retype. A value that carries a status is drawn the
        // way the ME panel draws its own — bold, and in the tone's colour — so
        // a checksum that does not check out reads here the way a "Configured"
        // reads there.
        let fields = ToolFieldList(fields: node.fields.map {
            .init(label: $0.label, value: $0.tone.attributedValue($0.value))
        })
        detail.content.addArrangedSubview(fields)
        // As wide as the list, so a value too long for the column — a GUID, a
        // hash — wraps inside it instead of running off the side.
        fields.widthAnchor.constraint(equalTo: detail.content.widthAnchor).isActive = true

        for table in node.tables { addTable(table) }
        if let picture = node.picture { addPicture(picture) }
        if let sound = node.sound { addSound(sound) }
    }

    /// The sound a node is, with a player under its rows, as wide as the list
    /// (`SoundPlayerView`). Bytes AVFoundation cannot play leave the rows as
    /// they are.
    // help: panel.uefi.sound-player
    private func addSound(_ bytes: [UInt8]) {
        guard let view = SoundPlayerView(wav: bytes) else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        if let above = detail.content.arrangedSubviews.last {
            detail.content.setCustomSpacing(12, after: above)
        }
        detail.content.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: detail.content.widthAnchor).isActive = true
    }

    /// The picture a node is, drawn under its rows: as wide as the list at
    /// most, never larger than its own pixels, in its own proportions, on a
    /// background a click changes (`PicturePreviewView`). Bytes
    /// AppKit cannot decode leave the rows as they are — the fields have
    /// already said what the parser read.
    // help: panel.uefi.picture-preview
    private func addPicture(_ bytes: [UInt8]) {
        guard let image = NSImage(data: Data(bytes)),
              let pixels = image.representations.first,
              pixels.pixelsWide > 0, pixels.pixelsHigh > 0
        else { return }
        let view = PicturePreviewView(image: image, hasAlpha: pixels.hasAlpha)
        view.translatesAutoresizingMaskIntoConstraints = false
        // Its own size is the image's in points, which is not what decides
        // here: the list's width and the pixels do.
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        if let above = detail.content.arrangedSubviews.last {
            detail.content.setCustomSpacing(12, after: above)
        }
        detail.content.addArrangedSubview(view)
        let natural = view.widthAnchor.constraint(equalToConstant: CGFloat(pixels.pixelsWide))
        natural.priority = .defaultLow
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(lessThanOrEqualTo: detail.content.widthAnchor),
            view.widthAnchor.constraint(lessThanOrEqualToConstant: CGFloat(pixels.pixelsWide)),
            natural,
            view.heightAnchor.constraint(
                equalTo: view.widthAnchor,
                multiplier: CGFloat(pixels.pixelsHigh) / CGFloat(pixels.pixelsWide)
            ),
        ])
    }

    /// A table block under the rows: an icon and a heading, then the table —
    /// a header line and a view per row, its columns lined up whatever is in
    /// them rather than fixed-width text pretending to be a table
    /// (`DetailTableView`).
    private func addTable(_ table: UEFIDetailTable) {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: table.symbol,
                             accessibilityDescription: table.title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(
                pointSize: ToolPanelFont.size, weight: .regular))
        icon.contentTintColor = .secondaryLabelColor
        icon.isHidden = icon.image == nil
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: table.title)
        title.font = ToolPanelFont.body(weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSStackView(views: [icon, title])
        heading.orientation = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = 5
        heading.translatesAutoresizingMaskIntoConstraints = false

        // A table that folds wears a disclosure triangle after its heading's
        // words, and the icon and the words are the switch too: the triangle
        // is a small target.
        var disclosure: NSButton?
        if table.startsFolded {
            // help: panel.uefi.folding-table
            let button = NSButton(title: "", target: self, action: #selector(tableFoldClicked(_:)))
            button.bezelStyle = .disclosure
            button.setButtonType(.onOff)
            button.state = unfoldedTables.contains(table.title) ? .on : .off
            button.identifier = NSUserInterfaceItemIdentifier(table.title)
            ControlHelp.describe(button, name: table.title, tooltip: L("Show or hide the table"))
            button.translatesAutoresizingMaskIntoConstraints = false
            heading.addArrangedSubview(button)
            heading.alignment = .centerY
            // On the icon and the words, not the whole heading: a recogniser
            // there would see the triangle's own click too, and fold the
            // table back the moment the button opened it.
            for part in [icon, title] as [NSView] {
                part.identifier = button.identifier
                part.addGestureRecognizer(
                    NSClickGestureRecognizer(target: self, action: #selector(tableHeadingClicked(_:))))
            }
            disclosure = button
        }
        // Set on whatever comes before rather than after each table, so the
        // first one is as clear of the rows above it as the next is of the
        // table above it.
        if let above = detail.content.arrangedSubviews.last {
            detail.content.setCustomSpacing(12, after: above)
        }
        detail.content.addArrangedSubview(heading)
        detail.content.setCustomSpacing(8, after: heading)

        guard let disclosure else {
            install(makeGrid(table), after: heading)
            return
        }
        let fold = TableFold(button: disclosure, heading: heading, table: table)
        tableFolds[table.title] = fold
        if disclosure.state == .on {
            fold.grid = makeGrid(table)
            install(fold.grid!, after: heading)
        }
    }

    /// `grid` in the list right under `heading`, kept inside the list's width.
    private func install(_ grid: NSView, after heading: NSView) {
        let list = detail.content
        let index = (list.arrangedSubviews.firstIndex(of: heading) ?? list.arrangedSubviews.count - 1) + 1
        list.insertArrangedSubview(grid, at: index)
        list.setCustomSpacing(8, after: heading)
        // A table under it is as clear of this one as of any other.
        if index + 1 < list.arrangedSubviews.count { list.setCustomSpacing(12, after: grid) }
        // Inside the list, never past it: a table wider than the panel is
        // clipped at the edge rather than drawn over the dump.
        grid.trailingAnchor.constraint(lessThanOrEqualTo: list.trailingAnchor).isActive = true
    }

    /// The table's header line and rows, one view per row
    /// (`DetailTableView`); a row's link leads where its target says.
    private func makeGrid(_ table: UEFIDetailTable) -> NSView {
        DetailTableView(table: table) { [weak self] target in self?.follow(target) }
    }

    @objc private func tableFoldClicked(_ sender: NSButton) {
        guard let title = sender.identifier?.rawValue else { return }
        setTable(title, unfolded: sender.state == .on)
    }

    @objc private func tableHeadingClicked(_ click: NSClickGestureRecognizer) {
        guard let title = click.view?.identifier?.rawValue else { return }
        setTable(title, unfolded: !unfoldedTables.contains(title))
    }

    /// Opens or folds a folding table in place: its grid built the first
    /// time it is opened, shown or hidden after that; nothing else rebuilt.
    private func setTable(_ title: String, unfolded: Bool) {
        if unfolded { unfoldedTables.insert(title) } else { unfoldedTables.remove(title) }
        guard let fold = tableFolds[title] else { return }
        fold.button.state = unfolded ? .on : .off
        if unfolded, fold.grid == nil {
            let grid = makeGrid(fold.table)
            fold.grid = grid
            install(grid, after: fold.heading)
        }
        fold.grid?.isHidden = !unfolded
        // Folded, the heading is the table's last line, and what follows it
        // keeps the gap a table keeps from the next.
        let list = detail.content
        if let index = list.arrangedSubviews.firstIndex(of: fold.heading),
           list.arrangedSubviews.dropFirst(index + 1).contains(where: { $0 !== fold.grid }) {
            list.setCustomSpacing(unfolded ? 8 : 12, after: fold.heading)
        }
    }

    /// The title names the image, not a row; the module decides what the fold
    /// stands for and does nothing when there is nothing to select.
    @objc private func summaryClicked() {
        onSelectTop?()
    }

    /// The reveal button: show the node the caret in the dump is in. The
    /// module reads the caret and decides; this is only the click.
    @objc private func revealClicked() {
        onRevealAtCaret?()
    }

    // MARK: - Searching the tree

    /// What one search is: the walk, what it looks for, and which search it is.
    private final class SearchRun {
        var walk: UEFITreeSearch
        let query: UEFITreeQuery
        let token: Int
        /// The row the walk looked at last: what the progress bar places.
        var looking: NodeID?

        init(walk: UEFITreeSearch, query: UEFITreeQuery, token: Int) {
            self.walk = walk
            self.query = query
            self.token = token
        }
    }

    /// How long a search may hold the main thread before it lets go for a
    /// moment, so a long walk over rows already read still draws.
    private static let searchSlice: TimeInterval = 0.008
    /// How long a search runs before its bar shows a progress bar.
    private static let searchStatusDelay: TimeInterval = 0.2

    /// Edit ▸ Find with the keyboard in the tree or its details: the tree's
    /// search, not the dump's. The panel sits in the responder chain ahead of
    /// the window, so it answers the menu's action first; with the keyboard
    /// anywhere else the window's own Find bar opens as before.
    @objc func findPattern() {
        UEFISearchSettings.isOpen = true
        searchBar.focusField()
    }

    @objc private func searchClicked() {
        UEFISearchSettings.isOpen.toggle()
        guard UEFISearchSettings.isOpen else { return }
        DispatchQueue.main.async { [weak self] in self?.searchBar.focusField() }
    }

    /// The bar open or shut, and the button saying so. Shutting it ends the
    /// search: what it opened is the reader's from here.
    private func applySearchVisibility() {
        let open = UEFISearchSettings.isOpen
        searchBar.isHidden = !open
        splitterBelowSummary?.isActive = !open
        splitterBelowBar?.isActive = open
        searchButton.contentTintColor = open ? .controlAccentColor : .secondaryLabelColor
        if !open {
            cancelSearch()
            searchOpenings.release()
        }
    }

    /// The stored query or the bar's state moved, in this panel or the other:
    /// a search for the old query is over, and what it opened is left as it is.
    private func searchSettingsChanged() {
        applySearchVisibility()
        let query = UEFISearchSettings.query
        guard query != shownQuery else { return }
        shownQuery = query
        cancelSearch()
        searchOpenings.release()
    }

    /// The row the search goes on from: the last match, unless the reader has
    /// chosen another row since; then the one selected — or, in the ME
    /// sub-tree, the ME region it hangs from. None when nothing is selected, or
    /// the title is.
    private func searchOrigin() -> NodeID? {
        if let searchCursor, tree?.node(searchCursor) != nil { return searchCursor }
        var item = outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) : nil
        while let current = item {
            if let row = current as? UEFITreeRow, !row.isLoading { return row.id }
            item = outline.parent(forItem: current)
        }
        return nil
    }

    private func search(_ direction: UEFITreeSearch.Direction) {
        let query = UEFISearchSettings.query
        guard let tree, !isBuilding, !query.isEmpty else { return }
        cancelSearch()
        searchBar.status = .none
        searchRun += 1
        let run = SearchRun(
            walk: UEFITreeSearch(origin: searchOrigin(), direction: direction),
            query: query, token: searchRun
        )
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.searchStatusDelay * 1_000_000_000))
            guard let self, self.searchRun == run.token else { return }
            self.searchBar.status = .searching
            self.showSearchProgress(run)
        }
        drive(run, in: tree)
    }

    /// The reader stopped a search that was reading branches.
    private func stopSearching() {
        cancelSearch()
    }

    /// Ends the search in hand, if there is one.
    private func cancelSearch() {
        searchRun += 1
        if searchBar.status == .searching { searchBar.status = .none }
    }

    private var searchSource: UEFITreeSearchSource {
        UEFITreeSearchSource(
            topRows: { [weak self] in
                guard let self else { return [] }
                return UEFITreeDisplay.listed(self.presented.rows, showsEmptyPadding: self.showsEmptyPadding)
                    .map(\.id)
            },
            // Nil is "read this branch first", and means something else than
            // none: a view that has gone leaves nothing to look through.
            listedChildren: { [weak self] id in
                guard let self else { return [] }
                return self.listedChildIDs(of: id)
            }
        )
    }

    /// The rows listed under `id` as the outline would list them; nil for a
    /// branch not read yet. The ME region lists none: its sub-tree is another
    /// structure, which a name, a GUID and a type do not describe.
    private func listedChildIDs(of id: NodeID) -> [NodeID]? {
        guard let tree, let node = tree.node(id) else { return [] }
        if isMERegion(node) { return [] }
        guard node.children.isEmpty else {
            let hiding = showsSupersededEntries ? [] : Set(supersededCopies(in: node).keys)
            return UEFITreeDisplay.listed(node.children, showsEmptyPadding: showsEmptyPadding, hiding: hiding)
                .map(\.id)
        }
        return node.isExpandable ? nil : []
    }

    private func matches(_ id: NodeID, _ query: UEFITreeQuery) -> Bool {
        guard let node = tree?.node(id) else { return false }
        return query.matches(node, name: UEFITreeDisplay.name(for: node, catalogue: catalogue, in: image))
    }

    /// Walks on until a row matches, a branch has to be read, or every row has
    /// been seen. A branch is read in the background and the walk goes on when
    /// it is there; a long stretch of rows already read lets go of the main
    /// thread now and then.
    private func drive(_ run: SearchRun, in tree: LazyUEFITree) {
        guard run.token == searchRun, tree === self.tree else { return }
        let source = searchSource
        let began = Date()
        while true {
            switch run.walk.advance(in: source) {
            case .candidate(let id):
                run.looking = id
                if matches(id, run.query) {
                    land(on: id, run: run)
                    return
                }
                if Date().timeIntervalSince(began) > Self.searchSlice {
                    showSearchProgress(run)
                    DispatchQueue.main.async { [weak self] in self?.drive(run, in: tree) }
                    return
                }
            case .expand(let id):
                run.looking = id
                showSearchProgress(run)
                tree.expand(id) { [weak self] _ in self?.drive(run, in: tree) }
                return
            case .exhausted:
                searchRun += 1      // over: the late status timer finds itself stale
                        searchBar.status = .notFound
                return
            }
        }
    }

    /// Puts the progress bar at the place in the file of the row the walk is
    /// at: its own offset, or — inside a compressed section, whose bytes are
    /// no bytes of the file — the offset of the section it was unpacked from.
    private func showSearchProgress(_ run: SearchRun) {
        guard searchBar.status == .searching, let tree, let id = run.looking else { return }
        let size = tree.imageReader.count
        guard size > 0 else { return }
        for depth in stride(from: id.path.count, through: 1, by: -1) {
            if let offset = tree.node(NodeID(Array(id.path.prefix(depth))))?.fileRange?.lowerBound {
                searchBar.progress = Double(offset) / Double(size)
                return
            }
        }
    }

    /// The search found `id`: open the way to the match and one level under
    /// it, select it as a click on it would, and only then shut what the search
    /// opened for the last match and this one does not need.
    ///
    /// In that order because a branch read in the meantime makes the session
    /// show the node it still has in focus again — and showing it opens the
    /// rows above it. Shut first, the old match's volume would be opened again
    /// behind the search; shut after the new match is the focus, the rows that
    /// are shown are the new match's own.
    private func land(on id: NodeID, run: SearchRun) {
        searchCursor = id
        searchRun += 1
        searchBar.status = .none
        var way = (0..<id.path.count).map { NodeID(Array(id.path.prefix($0 + 1))) }
        // The ME region opens by running an analysis, which is not a search's
        // to start.
        if let node = tree?.node(id), isMERegion(node) { way.removeLast() }
        openForSearch(way, from: 0) { [weak self] in
            guard let self, self.tree?.node(id) != nil else { return }
            self.onWillChoose?()
            self.selectSearchMatch(id)
            self.closeForSearch(self.searchOpenings.closings(whenLandingOn: id), keepingInView: id)
            if run.walk.wrapped { self.onSearchWrapped?(run.walk.direction == .forward) }
        }
    }

    /// Shuts `ids`, deepest first, and brings `match` back into view: the rows
    /// above it have gone, and it has moved with them.
    private func closeForSearch(_ ids: [NodeID], keepingInView match: NodeID) {
        guard !ids.isEmpty else { return }
        for id in ids {
            searchOpenings.forget(id)
            enqueue(animated: false) { [weak self] in
                guard let self, let item = self.outlineItem(for: id),
                      self.outline.isItemExpanded(item) else { return }
                self.panelCollapses { self.outline.collapseItem(item) }
            }
        }
        enqueue(animated: false) { [weak self] in
            guard let self else { return }
            let row = self.outline.row(forItem: self.row(match))
            if row >= 0 { self.scrollToShowChildren(of: self.outline.item(atRow: row)) }
        }
    }

    /// Opens, in turn, each row of `way` that is shut, the search noting what it
    /// opened — a row the reader had open is theirs and is left alone.
    private func openForSearch(_ way: [NodeID], from index: Int, then done: @escaping () -> Void) {
        guard index < way.count, let tree, let node = tree.node(way[index]) else {
            done()
            return
        }
        let id = way[index]
        let open = { [weak self] in
            self?.enqueue(animated: false) { [weak self] in
                guard let self else { return }
                if let item = self.outlineItem(for: id), !self.outline.isItemExpanded(item),
                   self.outline.isExpandable(item) {
                    self.searchOpenings.record(id)
                    self.panelExpands { self.outline.expandItem(item) }
                }
                self.openForSearch(way, from: index + 1, then: done)
            }
        }
        if node.children.isEmpty, node.isExpandable {
            tree.expand(id) { _ in open() }
        } else {
            open()
        }
    }

    /// Selects `id` as a click on it would — the detail and the dump follow —
    /// without taking the keyboard from the search field.
    private func selectSearchMatch(_ id: NodeID) {
        let row = outline.row(forItem: self.row(id))
        guard row >= 0 else { return }
        let wasShowingState = isShowingState
        isShowingState = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        scrollToShowChildren(of: outline.item(atRow: row))
        isShowingState = wasShowingState
        chooseNode(atRow: row)
    }

    /// A row was shut. A row the search opened that the reader shuts is
    /// theirs from now on — shut, or opened again — and the search will not
    /// shut it. Only a shutting tells: the search shuts nothing it still
    /// owns, and a row it opened can be opened again only once shut — while
    /// the outline's notice of the search's own opening can come after the
    /// opening has returned, and tell nothing about who did it.
    private func noteCollapse(_ notification: Notification) {
        guard let row = notification.userInfo?["NSObject"] as? UEFITreeRow, !row.isLoading else { return }
        searchOpenings.forget(row.id)
    }
}

/// One row of the outline: the place in the tree it stands for, and nothing
/// else. Public because it is what an outline item *is* here — a caller
/// reading a row asks the tree what is at `id`, the way the panel does.
///
/// The outline is handed these rather than `UEFINode` values, and that is the
/// whole point of the type. An outline decides what it is looking at by
/// comparing the item it was handed, and a node is a value that *changes* as
/// its branch arrives: `children` fills in, `isExpandable` goes false. The row
/// drawn before the branch and the row drawn after are two different values,
/// so the outline drops everything it knew about the first — including the
/// fact that the reader had just opened it, which is how a click on a
/// disclosure triangle came to close itself again a moment later.
///
/// A path does not change. One instance per path, handed out by
/// `row(_:)`, so the outline sees the same object for the same node for as
/// long as the tree holds it.
public final class UEFITreeRow {
    public let id: NodeID
    /// True for the "Loading…" row standing in for a branch still being read.
    /// `id` is that branch's, so every opening branch gets a placeholder of its
    /// own — an outline needs each of its items to be a distinct object, and
    /// one shared placeholder under two branches opening at once is the same
    /// object in two places, which is a tree the outline cannot lay out.
    public let isLoading: Bool

    init(_ id: NodeID, isLoading: Bool = false) {
        self.id = id
        self.isLoading = isLoading
    }
}

/// One row of the ME sub-tree grafted under the ME region node: the place in
/// the presented ME tree it stands for, and nothing else. The node itself is a
/// value the panel resolves from the presented roots by `path`
/// (`MEATree.node`), so a re-parse that moves a row is picked up on the next
/// read rather than frozen into the row object.
///
/// Kept apart from `UEFITreeRow` (which stands for a `NodeID`) because the two
/// kinds of row resolve against different trees — the UEFI tree and the
/// presented ME tree — and the outline's data source switches on which it was
/// handed.
final class MEOutlineRow {
    /// The node's position in the presented ME tree, under the ME region node.
    let path: [Int]

    init(_ path: [Int]) {
        self.path = path
    }
}

extension UEFIToolViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// `item`'s children as the outline should see them right now: the ones
    /// the tree has, or the single "Loading…" row a branch slow enough to have
    /// earned one shows in their place.
    ///
    /// A row is not normally opened before its branch is there — that is
    /// `outlineView(_:shouldExpandItem:)`'s job — so this mostly answers with
    /// real children. The rest of it covers a row opened some other way.
    private func childrenList(for id: NodeID) -> [Any] {
        guard let tree, let node = tree.node(id) else { return [] }
        // The ME region node is not expandable in the UEFI tree, but it opens
        // the ME sub-tree: its children are the presented ME roots, not a raw
        // area scan. Empty until the analysis has run (or been cached) — and,
        // while a fresh analysis is slow enough to have earned one, the single
        // "Loading…" row that stands in for it, the way a UEFI branch shows.
        if isMERegion(node) {
            if showingPlaceholder.contains(id) { return [placeholder(under: id)] }
            return meRoots.map { meRow($0.path) }
        }
        if !node.children.isEmpty {
            // AppKit asks for a branch's children one index at a time, and
            // building the list each time made opening a branch of thousands
            // of rows — a Dell DVAR store has 3 300 — quadratic: seconds with
            // the window frozen. The list is kept for the branch last asked
            // about, as long as the node still has the very same children —
            // the same array storage, which the kept copy holds on to, so the
            // storage cannot be freed and reused for another array.
            if let listed = listedChildren, listed.id == id, listed.showsEmptyPadding == showsEmptyPadding,
               listed.showsSuperseded == showsSupersededEntries,
               Self.sameStorage(listed.children, node.children) {
                return listed.rows
            }
            let hiding = showsSupersededEntries ? [] : Set(supersededCopies(in: node).keys)
            let rows: [Any] = UEFITreeDisplay.listed(node.children, showsEmptyPadding: showsEmptyPadding, hiding: hiding)
                .map { row($0.id) }
            listedChildren = (id, node.children, showsEmptyPadding, showsSupersededEntries, rows)
            return rows
        }
        guard node.isExpandable else { return [] }
        if showingPlaceholder.contains(id) { return [placeholder(under: id)] }
        beginOpening(id)
        return showingPlaceholder.contains(id) ? [placeholder(under: id)] : []
    }

    /// The copies `store`'s rows leave out, read once per store and kept
    /// while it has the same children.
    private func supersededCopies(in store: UEFINode) -> [NodeID: NodeID] {
        if let known = supersededByStore[store.id], Self.sameStorage(known.children, store.children) {
            return known.copies
        }
        guard let reader = tree?.spaceReaders.reader(for: store.space) else { return [:] }
        let copies = NvramVariableHistory.supersededCopies(in: store, reader: reader)
        supersededByStore[store.id] = (store.children, copies)
        return copies
    }

    private static func sameStorage(_ a: [UEFINode], _ b: [UEFINode]) -> Bool {
        a.count == b.count && a.withUnsafeBufferPointer { left in
            b.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress }
        }
    }

    /// A row the reader clicked open whose branch has not been read yet stays
    /// shut, and the reading starts. The row opens in `branchArrived(_:)` —
    /// once, with what is actually in it.
    ///
    /// Except once the branch has been slow enough to earn a "Loading…" row:
    /// this is asked for a programmatic `expandItem` too, so refusing then
    /// would refuse the panel's own attempt to put that row up, and the branch
    /// would never open at all.
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        if let meRow = item as? MEOutlineRow {
            let path = meRow.path
            return !opensAfterMakingRoom(item) { [weak self] in self?.meRow(path) }
        }
        guard let row = item as? UEFITreeRow, !row.isLoading, let tree,
              let node = tree.node(row.id)
        else { return true }
        let id = row.id
        let resolve = { @MainActor [weak self] () -> Any? in self?.outlineItem(for: id) }
        // The ME region node is not expandable in the UEFI tree, but opening it
        // runs the ME analysis and opens the row on the sub-tree it presents —
        // so it is answered here rather than left to the tree, which would scan
        // a raw area and find nothing.
        //
        // This is asked both when the reader clicks the triangle and when the
        // panel's own `expandItem` runs the open — AppKit asks on the way in
        // either way. Until the sub-tree is presented there is nothing to open
        // onto, so the first ask starts the analysis and holds the row shut;
        // once the roots are in hand the same ask lets the open through, or the
        // panel's `expandItem` would re-ask and re-start the analysis forever.
        //
        // The "Loading…" row is the one exception to holding the row shut: it
        // is put up by the panel's own `expandItem`, and refusing that ask would
        // refuse the panel's attempt to show it.
        if isMERegion(node) {
            guard meRoots.isEmpty else { return !opensAfterMakingRoom(item, resolve) }
            guard !showingPlaceholder.contains(row.id) else { return true }
            // An open already in flight is not asked for a second time. The
            // analysis is reading, the panel has its clock on the row but no
            // placeholder yet, and a second ask would be a second full read of
            // the region — two passes where the session means to make one.
            guard meOpening != row.id else { return false }
            meRegionOpening(row.id)
            onOpenMERegion?(row.id)
            return false
        }
        guard node.children.isEmpty, node.isExpandable,
              !showingPlaceholder.contains(row.id)
        else { return !opensAfterMakingRoom(item, resolve) }
        if !isPanelExpanding { openedByReader.insert(row.id) }
        beginOpening(row.id)
        return false
    }

    /// Starts reading a branch, and — only if it turns out to be slow — puts a
    /// "Loading…" row up to say so.
    private func beginOpening(_ id: NodeID) {
        guard let tree, opening[id] == nil else { return }
        opening[id] = Date()
        tree.expand(id) { [weak self] _ in self?.branchArrived(id) }
        guard opening[id] != nil else { return }   // it was already in hand

        Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.placeholderDelay * 1_000_000_000)
            )
            guard let self, self.opening[id] != nil else { return }
            self.showingPlaceholder.insert(id)
            self.expandRow(id)
        }
    }

    /// The branch is there. A row that never showed a placeholder simply opens
    /// now, in one animation, with its real children in it. A row that did has
    /// them put in its place — but not while the outline is still animating the
    /// placeholder in.
    private func branchArrived(_ id: NodeID) {
        guard opening.removeValue(forKey: id) != nil else { return }
        let resolve = { @MainActor [weak self] () -> Any? in self?.outlineItem(for: id) }
        guard showingPlaceholder.remove(id) != nil else {
            if openedByReader.contains(id) { makeRoom(for: resolve) }
            expandRow(id) { [weak self] in self?.showBranchIfAsked(id) }
            return
        }
        if openedByReader.contains(id) { makeRoom(for: resolve) }
        enqueue(animated: true) { [weak self] in
            guard let self, let item = self.outlineItem(for: id) else { return }
            self.outline.reloadItem(item, reloadChildren: true)
            self.showBranchIfAsked(id)
        }
    }

    /// Runs `open` as the panel's own opening of a row, not the reader's.
    private func panelExpands(_ open: () -> Void) {
        let was = isPanelExpanding
        isPanelExpanding = true
        open()
        isPanelExpanding = was
    }

    /// Runs `fold` as the panel's own folding of a row, not the reader's.
    private func panelCollapses(_ fold: () -> Void) {
        let was = isPanelCollapsing
        isPanelCollapsing = true
        fold()
        isPanelCollapsing = was
    }

    /// The row's own item, found again when a later change runs: the rows may
    /// have moved by then, and an outline knows only the object it holds.
    private func resolver(for item: Any) -> @MainActor () -> Any? {
        if let meRow = item as? MEOutlineRow {
            let path = meRow.path
            return { [weak self] in self?.meRow(path) }
        }
        if let row = item as? UEFITreeRow, !row.isLoading {
            let id = row.id
            return { [weak self] in self?.outlineItem(for: id) }
        }
        return { item }
    }

    /// Whether a row the reader folds is folded by the panel instead — first
    /// the fold, then the scroll — and if so, does both, in that order.
    ///
    /// Folded near the end of the table, a row takes away rows the view was
    /// showing, the table comes up short of the view, and the scroll had to
    /// move with the rows still sliding away: the fold drew torn. So the
    /// table keeps its height while the row folds, then scrolls up to its new
    /// end, then lets the height go. A fold that leaves the scroll where it
    /// is, an Option-click and a fold of the panel's own fold at once, as
    /// before.
    private func foldsBeforeScrolling(_ item: Any) -> Bool {
        guard !isPanelCollapsing, NSApp.currentEvent?.modifierFlags.contains(.option) != true,
              let clip = outline.enclosingScrollView?.contentView else { return false }
        let row = outline.row(forItem: item)
        guard row >= 0 else { return false }
        let level = outline.level(forRow: row)
        var end = row + 1
        while end < outline.numberOfRows, outline.level(forRow: end) > level { end += 1 }
        guard end > row + 1 else { return false }
        let removed = outline.rect(ofRow: end - 1).maxY - outline.rect(ofRow: row).maxY
        let rowsAfter = outline.rect(ofRow: outline.numberOfRows - 1).maxY - removed
        // Only a fold that would move the scroll: one that leaves the clip
        // past the table's new end.
        let insets = clip.contentInsets
        let lowestAfter = max(rowsAfter + insets.bottom - clip.bounds.height, -insets.top)
        guard clip.bounds.minY > lowestAfter + 0.5 else { return false }

        let resolve = resolver(for: item)
        outline.heldHeight = outline.frame.height
        enqueue(animated: true) { [weak self] in
            guard let self, let item = resolve() else { return }
            self.panelCollapses { self.outline.animator().collapseItem(item) }
        }
        enqueue(animated: true) { [weak self] in
            guard let self else { return }
            let rows = self.outline.numberOfRows > 0
                ? self.outline.rect(ofRow: self.outline.numberOfRows - 1).maxY : 0
            let lowest = rows + insets.bottom - clip.bounds.height
            let top = max(min(clip.bounds.minY, lowest), -insets.top)
            guard top != clip.bounds.minY else { return }
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: top))
            clip.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        enqueue(animated: false) { [weak self] in self?.outline.heldHeight = 0 }
        return true
    }

    /// A branch the reader asked for is there: show it.
    private func showBranchIfAsked(_ id: NodeID) {
        guard openedByReader.remove(id) != nil else { return }
        // Behind the opening's animation, which a scroll inside it is lost to.
        enqueue(animated: false) { [weak self] in
            guard let self, let item = self.outlineItem(for: id) else { return }
            self.scrollToShowChildren(of: item)
        }
    }

    /// Scrolls so that `item`'s rows are on screen — as many as fit — without
    /// taking `item` itself off the top: one scroll to the stretch from the row
    /// to its last child, or, when that is taller than the view, to the row at
    /// the top.
    private func scrollToShowChildren(of item: Any?) {
        guard let item, let move = roomMove(for: item, beforeOpening: false) else { return }
        move.clip.scroll(to: move.origin)
        move.clip.enclosingScrollView?.reflectScrolledClipView(move.clip)
    }

    /// Whether a row the reader opens is held shut while the table first
    /// makes room for what it holds — and if so, does both, in that order.
    ///
    /// Scrolled while the rows open, the table moved under an animation that
    /// was sliding the new rows in, and they came in torn. So the table moves
    /// first, to where the row and its rows will be in view, and the row opens
    /// once it stands still. A row whose rows are in view already, an opening
    /// of the panel's own, and an Option-click — which opens everything under
    /// the row, too many rows to make room for — open at once, as before.
    private func opensAfterMakingRoom(_ item: Any, _ resolve: @escaping @MainActor () -> Any?) -> Bool {
        guard !isPanelExpanding, NSApp.currentEvent?.modifierFlags.contains(.option) != true,
              roomMove(for: item, beforeOpening: true) != nil else { return false }
        makeRoom(for: resolve)
        enqueue(animated: true) { [weak self] in
            guard let self, let item = resolve() else { return }
            self.panelExpands { self.outline.animator().expandItem(item) }
        }
        return true
    }

    /// Scrolls, animated and as one of the panel's changes to the table, to
    /// where the row `resolve` finds and the rows it is about to show will be
    /// in view. Resolved when the change runs: the rows may have moved.
    private func makeRoom(for resolve: @escaping @MainActor () -> Any?) {
        enqueue(animated: true) { [weak self] in
            guard let self, let item = resolve(),
                  let move = self.roomMove(for: item, beforeOpening: true) else { return }
            // The rows are not there yet, so neither is the table's height
            // for them, and a scroll past its end stops at the end. The
            // opening that follows sizes the table to its rows again.
            let needed = move.origin.y + move.clip.bounds.height
            if needed > self.outline.frame.height {
                self.outline.setFrameSize(NSSize(width: self.outline.frame.width, height: needed))
            }
            move.clip.animator().setBoundsOrigin(move.origin)
            move.clip.enclosingScrollView?.reflectScrolledClipView(move.clip)
        }
    }

    /// Where the clip has to stand for `item`'s row and its rows to be in
    /// view, or nil when they are. `beforeOpening`, the rows are the ones the
    /// row will show once open — its children, a row each, below it; after,
    /// the ones it shows.
    private func roomMove(for item: Any, beforeOpening: Bool) -> (clip: NSClipView, origin: NSPoint)? {
        let row = outline.row(forItem: item)
        guard row >= 0 else { return nil }
        // The table as tall as its rows now: right after an opening it still
        // has the height it had, and a scroll past that stops at its end.
        outline.tile()
        let rowRect = outline.rect(ofRow: row)
        var target = rowRect
        if beforeOpening {
            let count = outline.dataSource?.outlineView?(outline, numberOfChildrenOfItem: item) ?? 0
            target.size.height += CGFloat(count) * rowRect.height
        } else {
            let count = outline.isItemExpanded(item) ? outline.numberOfChildren(ofItem: item) : 0
            if count > 0 {
                let last = outline.row(forItem: outline.child(count - 1, ofItem: item))
                if last >= 0 { target = rowRect.union(outline.rect(ofRow: last)) }
            }
        }
        // Moved through the clip view itself: asked of the table, a scroll
        // made inside one of the panel's changes is not carried out.
        guard let clip = outline.enclosingScrollView?.contentView else { return nil }
        // The column header lies over the top of the clip: what is seen
        // starts under it. Placed at the clip's own top, the row would sit
        // under the header — one row off the screen.
        let header = outline.headerView?.frame.height ?? 0
        let visible = clip.documentVisibleRect
        let seenTop = visible.minY + header
        let seenHeight = visible.height - header
        var top = seenTop
        if target.maxY > seenTop + seenHeight { top = target.maxY - seenHeight }
        if rowRect.minY < top { top = rowRect.minY }
        guard top != seenTop else { return nil }
        return (clip, NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + (top - seenTop)))
    }

    /// The ME region's analysis is about to run: hold the row shut and — only
    /// if it turns out to be slow — put a "Loading…" row up, the way
    /// `beginOpening` does for a UEFI branch. The reading itself is the
    /// session's (`onOpenMERegion`), so this only keeps the placeholder's clock.
    func meRegionOpening(_ id: NodeID) {
        guard meOpening == nil else { return }
        meOpening = id
        Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.placeholderDelay * 1_000_000_000)
            )
            guard let self, self.meOpening == id else { return }
            self.showingPlaceholder.insert(id)
            self.expandRow(id)
        }
    }

    /// The ME region's analysis has landed — or failed. The row's placeholder
    /// gives way: a row that never earned one simply opens now (the open
    /// `openMERegion(_:)` makes, a moment later); a row that did has its
    /// "Loading…" row replaced by the sub-tree, or shut again on a failure.
    func meRegionLoading(_ id: NodeID) {
        guard meOpening == id else { return }
        meOpening = nil
        guard showingPlaceholder.remove(id) != nil else { return }
        enqueue(animated: true) { [weak self] in
            guard let self, let item = self.outlineItem(for: id) else { return }
            if self.meRoots.isEmpty {
                self.panelCollapses { self.outline.collapseItem(item) }
            } else {
                self.outline.reloadItem(item, reloadChildren: true)
            }
        }
    }

    /// The one "Loading…" row standing in for `id`'s branch.
    private func placeholder(under id: NodeID) -> UEFITreeRow {
        if let row = loadingRows[id] { return row }
        let row = UEFITreeRow(id, isLoading: true)
        loadingRows[id] = row
        return row
    }

    /// The outline's own item for this path, when it has a row.
    private func outlineItem(for id: NodeID) -> Any? {
        let row = outline.row(forItem: row(id))
        guard row >= 0 else { return nil }
        return outline.item(atRow: row)
    }

    /// The one row object standing for this place in the tree.
    private func row(_ id: NodeID) -> UEFITreeRow {
        if let row = rows[id] { return row }
        let row = UEFITreeRow(id)
        rows[id] = row
        return row
    }

    /// The node an outline item stands for, as the tree has it now. A
    /// "Loading…" row stands for no node at all — its `id` is the branch it is
    /// waiting on, not something to select, name or publish.
    private func node(of item: Any) -> UEFINode? {
        guard let row = item as? UEFITreeRow, !row.isLoading else { return nil }
        return tree?.node(row.id)
    }

    /// Whether a node of the UEFI tree is the ME region — the graft point the
    /// ME sub-tree opens under. The descriptor names it by its region type
    /// (0x02), and it is the one region the UEFI tree does not scan as a raw
    /// area: opening it runs the ME analysis instead (`Design/ME_REGION_IN_UEFI_TREE_PLAN.md`).
    private func isMERegion(_ node: UEFINode) -> Bool {
        node.kind == .region && node.subtype == UInt8(FlashRegionType.me.rawValue)
    }

    /// The one row object standing for this place in the presented ME tree, the
    /// way `row(_:)` does for the UEFI tree.
    private func meRow(_ path: [Int]) -> MEOutlineRow {
        if let row = meRows[path] { return row }
        let row = MEOutlineRow(path)
        meRows[path] = row
        return row
    }

    /// The presented ME node an outline item stands for, as the last show laid
    /// it out. Resolved by path from the presented roots, so a re-parse that
    /// moves a row is picked up on the next read rather than frozen into the
    /// row object.
    private func meNode(of row: MEOutlineRow) -> MEANode? {
        MEATree.node(at: row.path, in: meRoots)
    }

    /// What an ME row's cell reads in each column: the name for the Name
    /// column, nothing for Type and Subtype — the ME sub-tree is a semantic
    /// tree, not a structural one, and has no UEFI type or subtype to show.
    private func text(for node: MEANode, in column: NSUserInterfaceItemIdentifier) -> String {
        column == Column.name ? node.title : ""
    }

    /// The marks an outline item of either kind wears: a UEFI row's, worked out
    /// from the tree, or an ME row's, carried by the node itself.
    private func marks(of item: Any) -> ToolRowMarks {
        if let meRow = item as? MEOutlineRow {
            return meNode(of: meRow)?.marks ?? .none
        }
        return node(of: item).map { marks(for: $0) } ?? .none
    }

    /// The outline's own top level: one "Loading…" row while the tree is still
    /// working out what the top level is, and the presented rows once it has.
    private var topLevelRows: [Any] {
        isBuilding
            ? [placeholder(under: .root)]
            : UEFITreeDisplay.listed(presented.rows, showsEmptyPadding: showsEmptyPadding).map { row($0.id) }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return topLevelRows.count }
        if let meRow = item as? MEOutlineRow {
            return meNode(of: meRow)?.children.count ?? 0
        }
        guard let row = item as? UEFITreeRow, !row.isLoading else { return 0 }
        return childrenList(for: row.id).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let row = item as? MEOutlineRow {
            let children = meNode(of: row)?.children ?? []
            return meRow(children[index].path)
        }
        guard let item, let row = item as? UEFITreeRow, !row.isLoading
        else { return topLevelRows[index] }
        return childrenList(for: row.id)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let meRow = item as? MEOutlineRow {
            return meNode(of: meRow)?.isExpandable ?? false
        }
        guard let node = node(of: item) else { return false }
        // The ME region node offers the triangle even though the UEFI tree
        // marks it non-expandable: it opens the ME sub-tree, not a raw area.
        if isMERegion(node) { return true }
        // A branch read to nothing but empty padding has nothing to open on
        // while that padding is hidden.
        return node.isExpandable
            || !UEFITreeDisplay.listed(node.children, showsEmptyPadding: showsEmptyPadding).isEmpty
    }

    /// The loading row is a placeholder, not a node — nothing to select, no
    /// zone to publish, no menu to offer. An ME row is always selectable: it is
    /// a real row of the sub-tree, and selecting it is what reads its detail.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if item is MEOutlineRow { return true }
        return (item as? UEFITreeRow)?.isLoading == false
    }

    /// A row's cell, view-based and with its text centred.
    ///
    /// Not `objectValueFor`: that is the cell-based path, and an
    /// `NSTextFieldCell` draws its text against the TOP of the row rather than
    /// down the middle of it, which reads as every row in the tree sitting too
    /// high. Every other table in the project is view-based for the same
    /// reason.
    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let identifier = tableColumn?.identifier else { return nil }
        if (item as? UEFITreeRow)?.isLoading == true {
            // Built the same way a real row's cell is, warning view included:
            // cells go back into one reuse pool per column, and a placeholder
            // that made a Name cell without the warning would hand it on to
            // the next flagged row, which then has nowhere to draw its
            // triangle.
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self)
                as? NSTableCellView
                ?? ToolPanelTable.makeCell(identifier: identifier,
                                           warning: identifier == Column.name,
                                       badges: identifier == Column.name)
            cell.textField?.stringValue = identifier == Column.name ? L("Loading…") : ""
            cell.textField?.font = ToolPanelFont.body()
            // The colour too: cells share one pool per column, so a cell that
            // was grey for an empty ME section would hand its grey on to a
            // placeholder that has nothing to do with it.
            cell.textField?.textColor = .labelColor
            if identifier == Column.name {
                ToolPanelTable.dress(cell, with: .none)
            }
            return cell
        }
        if let meRow = item as? MEOutlineRow {
            guard let node = meNode(of: meRow) else { return nil }
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self)
                as? NSTableCellView
                ?? ToolPanelTable.makeCell(identifier: identifier,
                                           warning: identifier == Column.name,
                                           badges: identifier == Column.name)
            cell.textField?.stringValue = text(for: node, in: identifier)
            cell.textField?.font = ToolPanelFont.body()
            // A section that holds nothing reads grey — the whole row, name
            // included, every column: it is a place in the layout rather than
            // something to go and look at. The ME Analyzer draws it this way,
            // and greying the value alone left the row reading as loud as a
            // real one, with the quiet half looking like a rendering slip.
            cell.textField?.textColor = node.isEmptySection
                ? .secondaryLabelColor
                : .labelColor
            // The Name column wears the row's marks, the way a UEFI row does —
            // the rail and badges the ME node was built with.
            if identifier == Column.name {
                ToolPanelTable.dress(cell, with: node.marks)
            }
            return cell
        }
        guard let node = node(of: item) else { return nil }
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView
            ?? ToolPanelTable.makeCell(identifier: identifier,
                                       warning: identifier == Column.name,
                                       badges: identifier == Column.name)
        cell.textField?.stringValue = text(for: node, in: identifier)
        // Set per row, not once when the cell is made: a reused cell carries
        // the font it was made with, and the zoom moves under it.
        cell.textField?.font = ToolPanelFont.body()
        // The colour too, for the same reason. Empty padding, free space and
        // an erased pad file read grey, the whole row, the way an empty ME section does; every
        // other row is back to the label colour, whatever the cell wore last.
        cell.textField?.textColor = UEFITreeDisplay.isEmptySpace(node)
            ? .secondaryLabelColor
            : .labelColor
        // The Name column wears the row's icons: its problem, with what is
        // wrong under the pointer, and its badges (`Design/ROW_MARKS.md`).
        if identifier == Column.name {
            ToolPanelTable.dress(cell, with: marks(for: node))
        }
        return cell
    }

    /// What a row wears besides its name, decided in the pure target.
    private func marks(for node: UEFINode) -> ToolRowMarks {
        guard let image else { return .none }
        return UEFITreeMarks.marks(for: node, in: image, badChecksums: badChecksums[node.id] ?? [],
                                   isOpen: outline.isItemExpanded(row(node.id)))
    }

    /// One row's marks again, on its row view and its Name cell — what a row
    /// opening or shutting changes: a compressed section wears the rail only
    /// while it is open on its subtree.
    private func updateMarks(ofItem item: Any?) {
        guard let item, let node = node(of: item) else { return }
        let index = outline.row(forItem: item)
        guard index >= 0 else { return }
        let marks = marks(for: node)
        (outline.rowView(atRow: index, makeIfNecessary: false) as? ToolPanelRowView)?.marks = marks
        let column = outline.column(withIdentifier: Column.name)
        if column >= 0,
           let cell = outline.view(atColumn: column, row: index, makeIfNecessary: false) as? NSTableCellView {
            ToolPanelTable.dress(cell, with: marks)
        }
    }

    /// The row views that are on screen, given their background and rail
    /// again. Reloading cells does not reach a row view, so a show that only
    /// re-renders the cells — a checksum pass, a branch opening — ends here.
    private func updateRowMarks() {
        outline.enumerateAvailableRowViews { rowView, row in
            guard let rowView = rowView as? ToolPanelRowView else { return }
            rowView.showsMarkings = legend.showsMarkings
            rowView.marks = outline.item(atRow: row).map { marks(of: $0) } ?? .none
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = outlineView.makeView(withIdentifier: Self.rowViewIdentifier, owner: self)
            as? ToolPanelRowView ?? {
                let created = ToolPanelRowView()
                created.identifier = Self.rowViewIdentifier
                return created
            }()
        rowView.showsMarkings = legend.showsMarkings
        rowView.marks = marks(of: item)
        return rowView
    }

    private func text(
        for node: UEFINode, in column: NSUserInterfaceItemIdentifier
    ) -> String {
        switch column {
        case Column.type:
            return UEFITreeDisplay.typeText(for: node)
        case Column.subtype:
            return UEFITreeDisplay.subtypeText(for: node)
        default:
            // A variable's row says its value, which is bytes in the node's
            // space; a VSS one is read by its store's format, and the store
            // is in the tree as it has been opened, not in the image.
            let reader = UEFITreeDisplay.showsValue(node) ? tree?.spaceReaders.reader(for: node.space) : nil
            let store = node.kind == .vssEntry && !node.id.path.isEmpty
                ? tree?.node(NodeID(Array(node.id.path.dropLast()))) : nil
            return UEFITreeDisplay.name(for: node, catalogue: catalogue, in: image, reader: reader, store: store)
        }
    }

    /// The menu a right-click asks for, from what the node under the pointer
    /// offers: Fix Checksum when its checksum is wrong, an export when it is —
    /// or is inside — a compressed section that opened, and nothing at all on
    /// any other row. Fix greys out on a read-only file rather than vanishing,
    /// so the menu still says what fixing would do. It is never offered inside
    /// a compressed section: the file holds those bytes compressed.
    private func contextMenu(for event: NSEvent) -> NSMenu? {
        let point = outline.convert(event.locationInWindow, from: nil)
        let row = outline.row(at: point)
        guard row >= 0, let clicked = outline.item(atRow: row), let node = node(of: clicked) else {
            return nil
        }
        let items = nodeMenuItems(for: node)
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        return menu
    }

    /// Turns the empty padding rows on or off, and remembers the choice.
    func setShowsEmptyPadding(_ shows: Bool) {
        guard shows != showsEmptyPadding else { return }
        showsEmptyPadding = shows
        ToolPanelFont.defaults.set(shows, forKey: Self.showsEmptyPaddingKey)
        updateFilter()
        outline.reloadData()
        updateRowMarks()
    }

    /// The reveal reached empty padding, which the tree hides: asks whether to
    /// show it, and runs `then` once it is shown.
    func askToShowEmptyPadding(then: @escaping () -> Void) {
        let answer: (Bool) -> Void = { [weak self] yes in
            guard yes, let self else { return }
            self.setShowsEmptyPadding(true)
            then()
        }
        if let question = emptyPaddingQuestion { question(answer); return }
        let alert = NSAlert()
        alert.messageText = L("The node under the caret is empty padding")
        alert.informativeText = L("Empty padding is hidden in the tree. Show it?")
        alert.addButton(withTitle: L("Show Empty Padding"))
        alert.addButton(withTitle: L("Cancel"))
        if let window = view.window {
            alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
        } else {
            answer(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    @objc private func paddingItemClicked() {
        setShowsEmptyPadding(!showsEmptyPadding)
    }

    /// The filter's menu, under its icon.
    @objc private func filterClicked() {
        filterButton.menu?.popUp(
            positioning: nil, at: NSPoint(x: 0, y: filterButton.bounds.maxY + 4), in: filterButton
        )
    }

    /// The menu's ticks, and the icon tinted while the tree lists more than
    /// it does by default.
    private func updateFilter() {
        paddingItem.state = showsEmptyPadding ? .on : .off
        supersededItem.state = showsSupersededEntries ? .on : .off
        filterButton.contentTintColor = showsEmptyPadding || showsSupersededEntries
            ? .controlAccentColor : .secondaryLabelColor
    }

    // help: panel.uefi.variable-history
    // help: panel.uefi.map-regions
    /// A table row's link was clicked: where it leads.
    private func follow(_ target: UEFIDetailTable.Target) {
        // A link followed from the large view closes it first: where it goes
        // is the dump or the tree, and the card would stand in front of both.
        detailPane.closeQuickLook()
        switch target {
        case .node(let node): onSelect?(node)
        case .range(let range, let name): onOutlineRange?(range, name)
        }
    }

    /// Turns the superseded copies' rows on or off, and remembers the choice.
    func setShowsSupersededEntries(_ shows: Bool) {
        guard shows != showsSupersededEntries else { return }
        showsSupersededEntries = shows
        ToolPanelFont.defaults.set(shows, forKey: Self.showsSupersededEntriesKey)
        updateFilter()
        outline.reloadData()
        updateRowMarks()
    }

    @objc private func supersededItemClicked() {
        setShowsSupersededEntries(!showsSupersededEntries)
    }

    /// What the tree's menu offers for one node.
    private func nodeMenuItems(for node: UEFINode) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if !(badChecksums[node.id]?.isEmpty ?? true), node.space == .file {
            let item = NSMenuItem(
                title: L("Fix Checksum"),
                action: #selector(fixChecksumClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.isEnabled = canWrite
            // The node the click was on, read back when the item fires — by id,
            // not by node: a parse between the click and the action re-reads
            // the tree, and the id is what still points at the node.
            item.representedObject = node.id
            items.append(item)
        }
        // Every node can be taken out and read as a file of its own, and a
        // node with a header can have its body taken out without it.
        for body in [false, true] {
            guard let title = UEFIPresenter.nodeOpenTitle(for: node, body: body),
                  !body || !node.header.isEmpty
            else { continue }
            let item = NSMenuItem(title: title, action: #selector(openNodeClicked(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = NodeOpenTarget(id: node.id, body: body)
            items.append(item)
        }
        // The same bytes, saved to a file rather than opened.
        for body in [false, true] {
            guard let title = UEFIPresenter.nodeSaveTitle(for: node, body: body),
                  !body || !node.header.isEmpty
            else { continue }
            let item = NSMenuItem(title: title, action: #selector(saveNodeClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NodeOpenTarget(id: node.id, body: body)
            items.append(item)
        }
        // A node of either Top Swap block steps to its twin in the other, so
        // the reader sees which copy of a volume or file stands for which.
        if let image, let counterpart = UEFITopSwap.counterpart(of: node, in: image) {
            let item = NSMenuItem(
                title: counterpart.menuTitle,
                action: #selector(goToTopSwapCounterpartClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = node.id
            items.append(item)
        }
        if let decompressed = UEFIPresenter.decompressedBody(for: node) {
            let open = NSMenuItem(
                title: decompressed.openTitle,
                action: #selector(openDecompressedClicked(_:)),
                keyEquivalent: ""
            )
            open.target = self
            open.representedObject = node.id
            items.append(open)
            let item = NSMenuItem(
                title: decompressed.saveTitle,
                action: #selector(saveDecompressedClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = node.id
            items.append(item)
        }
        if UEFIPresenter.isBZip2Variable(node) {
            let open = NSMenuItem(
                title: L("Open Decompressed Variable"),
                action: #selector(openUnpackedClicked(_:)),
                keyEquivalent: ""
            )
            open.target = self
            open.representedObject = node.id
            items.append(open)
        }
        // Offered on a read-only file too: comparing writes nothing, and the
        // sheet says that writing is what it cannot do.
        if UEFIPresenter.isBIOSRegion(node) {
            let item = NSMenuItem(
                title: L("Compare with PFAT Update File…"),
                action: #selector(compareWithUpdateClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = node.id
            items.append(item)
        }
        return items
    }

    @objc private func compareWithUpdateClicked(_ sender: NSMenuItem) {
        guard let nodeID = sender.representedObject as? NodeID else { return }
        onCompareWithUpdate?(nodeID)
    }

    /// Which node an Open item means, and whether it means its body. Carried by
    /// id rather than by node: a parse between the click and the action re-reads
    /// the tree, and the id is what still points at the node.
    private struct NodeOpenTarget {
        let id: NodeID
        let body: Bool
    }

    @objc private func openNodeClicked(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? NodeOpenTarget else { return }
        onOpenNode?(target.id, target.body)
    }

    @objc private func saveNodeClicked(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? NodeOpenTarget else { return }
        onSaveNode?(target.id, target.body)
    }

    @objc private func goToTopSwapCounterpartClicked(_ sender: NSMenuItem) {
        guard let nodeID = sender.representedObject as? NodeID else { return }
        onGoToTopSwapCounterpart?(nodeID)
    }

    @objc private func fixChecksumClicked(_ sender: NSMenuItem) {
        guard let nodeID = sender.representedObject as? NodeID else { return }
        onFixChecksum?(nodeID)
    }

    @objc private func saveDecompressedClicked(_ sender: NSMenuItem) {
        guard let nodeID = sender.representedObject as? NodeID else { return }
        onSaveDecompressed?(nodeID)
    }

    @objc private func openUnpackedClicked(_ sender: NSMenuItem) {
        guard let nodeID = sender.representedObject as? NodeID else { return }
        onOpenUnpacked?(nodeID)
    }

    @objc private func openDecompressedClicked(_ sender: NSMenuItem) {
        guard let nodeID = sender.representedObject as? NodeID else { return }
        onOpenDecompressed?(nodeID)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        // Before the guard: a row the panel opens itself changes its rail too.
        updateMarks(ofItem: notification.userInfo?["NSObject"])
        // A row the reader opened brings what it holds into view.
        if !isPanelExpanding, let item = notification.userInfo?["NSObject"] {
            DispatchQueue.main.async { [weak self] in self?.scrollToShowChildren(of: item) }
        }
        guard !isShowingState else { return }
        onOpenRowsChanged?()
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        !foldsBeforeScrolling(item)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        updateMarks(ofItem: notification.userInfo?["NSObject"])
        noteCollapse(notification)
        guard !isShowingState else { return }
        onOpenRowsChanged?()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isShowingState else { return }
        // The reader went somewhere else: what the search opened stays as it is.
        searchOpenings.release()
        // A row chosen is where the next search starts. A selection that went
        // because its branch was shut is not a choice: the search goes on from
        // where it was.
        if outline.selectedRow >= 0 { searchCursor = nil }
        if outline.isHandlingClick { onWillChoose?() }
        isReportingReadersSelection = true
        defer { isReportingReadersSelection = false }
        chooseNode(atRow: outline.selectedRow)
    }

    /// A row was chosen — by a selection that moved, or by a click on the row
    /// that was already the selection. Both publish the row's zone; the outline
    /// only reports the second kind itself (see `UEFIOutlineView`).
    /// A double click: the node's content opens as a panel. A row that is no
    /// UEFI node — an ME row, a Loading row — has none to open.
    private func openContent(atRow row: Int) {
        guard row >= 0, let item = outline.item(atRow: row), let node = node(of: item) else { return }
        onOpenContent?(node.id)
    }


    private func chooseNode(atRow row: Int) {
        let item = row >= 0 ? outline.item(atRow: row) : nil
        // The panel's own focus moves with the row at once. The session
        // follows a reader's choice a moment later, and a refresh of the table
        // in between — a checksum pass landing — would otherwise reveal the
        // focus the panel still held, and take the row back to it.
        // An ME row resolves against the presented ME tree, not the UEFI tree,
        // so it is published on its own callback with its ME path.
        if let meRow = item as? MEOutlineRow {
            meFocus = meRow.path
            focus = nil
            onSelectME?(meRow.path)
            return
        }
        focus = (item as? UEFITreeRow)?.id
        meFocus = nil
        onSelect?((item as? UEFITreeRow)?.id)
    }
}

/// The tree, with two behaviours past NSOutlineView's.
///
/// It answers a right-click itself: a plain outline given a `menu` pops it
/// over every row — a flagged node's Fix Checksum item and a clean row's empty
/// menu alike — but AppKit asks `menu(for:)` first and shows nothing when it
/// answers nil, which is how a clean row gets no popup at all. The controller
/// decides per row.
///
/// And it reports a plain click on the row that is already the one selection.
/// AppKit treats that click as a change of nothing and posts no
/// `selectionDidChange`, so it would answer nothing — though a click that moved
/// the selection would publish the row's zone. A row the reveal chose sits in
/// exactly that state: shown and selected, but deliberately not published (the
/// dump does not move). A click on it is how the user asks for the zone, so it
/// chooses the row afresh. The disclosure triangle, a double click and a
/// modifier click keep their own meanings.
private final class UEFIOutlineView: ToolPanelOutlineView {
    /// What a right-click on this outline offers, decided on the main actor.
    var onContextMenu: ((NSEvent) -> NSMenu?)?
    /// A plain click landed on the row that was already selected.
    var onRowReclick: ((Int) -> Void)?
    /// A plain double click landed on a row, not on its disclosure triangle.
    var onRowDoubleClick: ((Int) -> Void)?
    /// The least height the table keeps, whatever its rows: held while a row
    /// folds, so the rows going away do not pull the table's end up past the
    /// view mid-fold. Let go, the table is sized to its rows again.
    var heldHeight: CGFloat = 0 {
        didSet { if heldHeight < oldValue { tile() } }
    }

    /// Asked first of every key press: true when the panel has taken it to
    /// press again later — the table is still changing, and the row it would
    /// move from is not where it will be.
    var holdsKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if holdsKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: newSize.width, height: max(newSize.height, heldHeight)))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?(event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let clickedItem = clickedRow >= 0 ? item(atRow: clickedRow) : nil
        let wasSelected = clickedRow >= 0 && selectedRowIndexes.contains(clickedRow)
        let wasExpanded = clickedItem.map { isItemExpanded($0) }
        // The triangle folds or unfolds on every click, however quick.
        let onDisclosure = clickedRow >= 0
            && frameOfOutlineCell(atRow: clickedRow).insetBy(dx: -2, dy: -2).contains(point)
            && !frameOfOutlineCell(atRow: clickedRow).isEmpty
        super.mouseDown(with: event)

        if event.clickCount == 2, clickedRow >= 0, !onDisclosure,
           event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty {
            onRowDoubleClick?(clickedRow)
            return
        }

        // A click that moved the selection needs no help — the outline reports
        // it. Only the click on the row that was already selected is answered
        // here (see the class doc).
        guard wasSelected, let clickedItem, let wasExpanded else { return }
        guard clickedRow == selectedRow,
              event.clickCount == 1,
              event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
              // Not the disclosure triangle: that click folds or unfolds, and
              // keeps meaning what it always meant.
              !frameOfOutlineCell(atRow: clickedRow).insetBy(dx: -2, dy: -2).contains(point),
              isItemExpanded(clickedItem) == wasExpanded
        else { return }
        onRowReclick?(clickedRow)
    }
}
