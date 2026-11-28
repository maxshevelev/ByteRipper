import ALSplitView
import AnalysisProfiles
import AppKit
import AppPalette
import CodeAnalysis
import Find
import HelpBook
import HelpUI
import Localization
import ToolModuleKit

/// The code screen: all the module's functions on the left, the selected
/// function's ASM or C above, and a read-only hex view of the module below
/// (`Design/CODE_PANEL_PLAN.md`).
///
/// A reader, not a tool-module: no tool panel, no minimap. The code is the
/// main surface; the hex view is there to see the bytes an instruction points
/// at. The two are linked both ways, and a function selects its whole stored
/// range rather than only its first instruction.
///
/// The view draws a `CodeReaderState` and turns clicks into its calls; the
/// lookups are `CodeModel`'s indices, so a click in a large module costs a
/// dictionary hit or a search by halves, not a walk of the artifact.
@MainActor public final class CodePaneView: NSView {
    public typealias List = CodeReaderState.List
    public typealias FunctionOrder = CodeReaderState.FunctionOrder
    typealias FunctionGroup = CodeReaderState.FunctionGroup
    typealias LibrarySection = CodeReaderState.LibrarySection
    typealias FunctionRow = CodeReaderState.FunctionRow

    /// A place in the code Back and Forward return to: the function, the
    /// instruction, and how the reader had it on screen when they left.
    struct Place {
        var function: Int
        var line: Int?
        var view = CodeViewPosition()
    }

    public private(set) var manifest: AnalysisManifest
    public private(set) var artifact: CodeArtifact
    /// Raised each time the pane takes another reading (`adoptReading`): a
    /// read begun for the reading before compares it and lets its answer go.
    public private(set) var readingGeneration = 0
    var state: CodeReaderState
    var model: CodeModel { state.model }
    /// Reads functions' code from the store, by entry, or every function for
    /// nil; nil when it could not. A pane opened on a cut artifact's index reads
    /// a function's code when it is first shown.
    public var onLoadFunctions: ((Set<CodeAddress>?) async -> [CodeArtifact.Function]?)? {
        // The pane is drawn, and put at its place, before it is given this.
        didSet {
            let asked = waitingForFunctions.reduce(into: Set<Int>()) { $0.formUnion($1.wanted) }
            if !asked.isEmpty { whenRead(asked) {} }
            readSelectedFunction()
        }
    }
    private var functionsBeingRead: Set<Int> = []
    private var functionsNotRead: Set<Int> = []
    private var lastFunctionAsked: Int?
    private var waitingForFunctions: [(wanted: Set<Int>, then: @MainActor () -> Void,
                                       otherwise: (@MainActor () -> Void)?)] = []
    /// The readable analyses of the same module, the chosen one first. One
    /// entry is the ordinary case; more makes the header offer the others.
    var recipes: [AnalysisManifest]

    private(set) var functionTable = NSTableView()
    var functionTableForTests: NSTableView { functionTable }
    private(set) var functionScroll = NSScrollView()
    /// The band under the list's switch: the review's groups as a strip, each
    /// as wide as its share of the module's functions.
    private let readinessBar = CodeReviewReadinessBar()
    /// Its height, which is nothing while another list is in front.
    private var readinessHeight: NSLayoutConstraint!
    private let listControl: NSSegmentedControl
    let searchField = NSSearchField()
    /// The header over the POST and Strings columns: one view, put back
    /// whenever a list with columns comes to the front.
    let navigatorHeader = CodeNavigatorHeader()
    /// What an empty list says in place of its rows.
    private let emptyListLabel = NSTextField(wrappingLabelWithString: "")
    /// The places the reader went to, oldest first, and which one is current:
    /// Back and Forward walk it as in an IDE. A jump — a click on a call, a
    /// caller, a function in the list — adds a place; moving inside one
    /// function only moves the current one.
    var history: [Place] = []
    var historyIndex = -1
    /// The annotations on this module's code, by the function and by the
    /// instruction they are on.
    public internal(set) var notes: [CodeNote] = []
    var notesByFunction: [Int: [CodeNote]] = [:]
    var notesByLine: [Int: [CodeNote]] = [:]
    /// Which link each `code:N` in the C text is.
    private var cLinks: [CodeLink] = []
    /// The tokens of the C on screen, in the text's own offsets — past the
    /// annotations heading it.
    var shownCTokens: [CodeToken] = []
    /// What each of `shownCTokens` names, once a highlight has asked.
    var shownCSymbols: [CodeSymbol?]?
    /// The symbol the reader clicked, every occurrence of which is drawn
    /// highlighted in the C and the listing.
    public internal(set) var highlightedSymbol: CodeSymbol?
    /// The function a highlighted variable belongs to.
    var highlightedIn: Int?
    /// Which of the highlighted name's occurrences the reader is at, in the
    /// side on screen — the one clicked, or the last one stepped to. Nil when
    /// the reader has not been at one yet: a step then starts from the caret.
    var currentOccurrence: Int?
    let occurrenceLabel = NSTextField(labelWithString: "")
    let previousOccurrenceButton = NSButton()
    let nextOccurrenceButton = NSButton()
    var occurrenceBar: NSStackView?
    var drawnC: Int?
    /// How far the function's own C starts into the text shown: the
    /// annotations' comments head it.
    var cShift = 0
    /// The line each function was left at, by its entry's address as text —
    /// see `topLinePositions`.
    var topLines: [String: Int] = [:]
    /// The explanation open over the code, if one is.
    var explanationPopover: CodeExplanationPopover?
    var functionPopover: CodeFunctionPopover?
    /// A plain click's popover, waiting to see that no second click follows:
    /// a double click goes to the function and shows nothing on the way.
    var pendingFunctionPopover: DispatchWorkItem?
    var clicksInCode = 0
    var callersPopover: CodeCallersPopover?
    let table = CodeListingTableView()
    let tableScroll = NSScrollView()
    let cTextView = CodeTextView()
    let cScroll = NSScrollView()
    /// ASM, C or the description: which is on screen.
    var mode = 1 { didSet { drawModeControls() } }
    private let modeControl: NSSegmentedControl
    /// Shows and hides the description, at the head of the navigator.
    let descriptionButton = CodeOrderButton()
    /// New, on the book's corner, while the description reads otherwise than
    /// when the reader last had it open.
    private let descriptionBadge = PartBadgeView(text: "")
    let descriptionBadgeHolder = CodeClickThroughView()
    /// The module line's end before the New badge, active while it shows.
    var moduleBeforeBadge: NSLayoutConstraint?
    /// The panel's page in the book: whoever holds the pane sets it in its title
    /// bar, over the whole panel.
    public let titleBarHelp: NSView = HelpButton.greyCircle(for: .topic(.codePanel))

    /// Whoever holds the pane puts a status of its own right after the revision
    /// at the head of the navigator; the pane does not know what it says.
    public func setModuleStatus(_ status: NSView?) {
        moduleStatus?.removeFromSuperview()
        moduleStatus = status
        if let status { moduleLine?.addView(status, in: .leading) }
    }

    let descriptionView = CodeDescriptionView()
    let diffView = CodeDiffView()
    /// The artifact this pane showed before a later revision of its reading
    /// replaced it: what Diff compares the code against, nil while the pane
    /// has seen no revision — beside another recipe, say, or after a restart.
    private var revisionBaseline: CodeArtifact?
    /// The function `revisionBaseline` holds the code of, when it was read for
    /// one; nil when it holds them all.
    var baselineReadFor: CodeAddress?
    /// What the diff on screen was drawn from, so a redraw is made only when
    /// the function or the revision changed.
    private var drawnDiff: (function: Int, revision: Int)?
    /// The function whose diff the view holds. Kept when `drawnDiff` is
    /// dropped for a new revision or another comparison: the same function
    /// redrawn keeps the reader's place, another function's is read from the
    /// line that function was left at.
    private var diffFunction: Int?
    /// Raised with every revision the pane is given.
    private var revisionCount = 0
    /// The revision's model, for the tokens and explanations of removed lines.
    var diffBaselineModel: CodeModel?
    private var diffBaselineIndex: Int?
    /// Whether the two revisions' C differs for the function on screen: the
    /// diff is shown only when it does.
    private(set) var revisionHasChanges = false
    /// The code side the description returns to: the C, or the listing.
    var codeShowsC = true
    /// Where the description is to be scrolled once its text arrives: a
    /// place adopted before the store answered.
    var pendingDescriptionScroll: NSPoint?
    /// The link in the description the reader just followed.
    var leavingDescriptionMark: NSRange?
    let recipeLine = CodeMenuLine(frame: .zero)
    /// Turns while the app reads another analysis the reader chose.
    let recipeSpinner = NSProgressIndicator()
    private let codeContent = NSView()
    private var codeStack: NSView?
    /// Where the surface's Find bar stands over the code or the description
    /// (#41): across the top of the code area, never over the navigator.
    let findBarSlot = CodeFindBarSlot()
    /// The search of the text on screen — the C of the function, or the
    /// description (#41). The app drives it; the pane keeps its content in
    /// step with what it shows and draws what it holds.
    public let finder = TextFindIndexer()
    /// What `finder` was last given to search: the side and its text.
    var findSearched: (side: FindSide, text: String)?
    /// The match a search last selected, while it is still the selection.
    var selectedFindMatch: NSRange?
    /// The yellow that stays on the match a search put the reader on.
    let findPlate = FindMatchPlate()
    /// The selection watches that take the plate off when the reader moves.
    var findPlateWatch: [NSObjectProtocol] = []
    /// The search's showing changed: the app re-reads its count.
    public var onFindChanged: (() -> Void)?
    /// The navigator's Search tab: a search of every function's C and the
    /// description (#41).
    let searchPanel = CodeSearchPanel()
    /// Whether the Search tab is the one in front of the lists.
    public internal(set) var showsSearchTab = false
    /// The navigator's Interfaces tab: what the module installs, looks up
    /// and is notified of, as its review recorded them.
    let interfacesPanel = CodeInterfacesPanel()
    /// Whether the Interfaces tab is the one in front of the lists.
    public internal(set) var showsInterfacesTab = false
    /// The navigator switch's tabs, from the module's analysis profile.
    public private(set) var navigatorTabs: [CodeNavigatorTab]
    /// A record section's tab: the records of one kind the profile declares.
    let recordPanel = CodeRecordSectionView()
    /// The record section in front of the lists, nil when none is.
    public internal(set) var shownRecordSection: String?
    /// The search of every function in flight.
    var searchAllTask: Task<Void, Never>?
    /// The query the Search tab last ran, while its result stands.
    public internal(set) var searchedAll: TextQuery?
    /// A search of every function finished: whether it found anything.
    public var onSearchAllFinished: ((_ query: TextQuery, _ found: Bool) -> Void)?
    /// A screen put back its Search tab's search: the app's field shows it.
    public var onSearchRestored: ((TextQuery) -> Void)?
    /// The description text the Search tab last saw: one that arrives, or
    /// changes, while a search stands is searched too.
    var searchedDescription: String?
    private var descriptionLeading: NSLayoutConstraint?
    let rightSplit = ALSplitView()
    let hexDumpBar = CodeDumpBar()
    let hexDumpButton = NSButton()
    /// The dump bar's revision comparison, as Xcode puts one there: the
    /// current revision, the two arrows, the revision the code is compared
    /// against and Reset.
    private let compareLabel = NSTextField(labelWithString: "")
    private let compareArrows = NSImageView()
    private let revisionLine = CodeMenuLine(frame: .zero)
    private let resetComparisonButton = NSButton()
    /// What the popup offers; empty until the app has read the module's
    /// history, and the bar stays out of sight while it is.
    private var revisionChoices: [RevisionChoice] = []
    /// The functions the revision on screen changed; nil when nobody knows.
    private var changedByCurrentRevision: Set<CodeAddress>?
    /// Whether the module has a history at all, so the bar holds its place
    /// while nothing in it is comparable yet.
    private var hasRevisionHistory = false
    /// The revision the Diff compares against; nil for none.
    public private(set) var comparisonRevision: Int?
    /// What each function was left compared with: the revision its New mark
    /// brought, once the reader has opened it and moved on, or what the reader
    /// picked in the bar for it. A function not listed here is compared only
    /// by a mark it still wears. The panel's, as its marks are, and gone with
    /// the session: nothing writes it to a workspace.
    var functionComparisons: [CodeAddress: FunctionComparison] = [:]
    /// The revision before the one on screen, and its code: what opening a
    /// function the revision changed compares against by itself.
    private var previousRevision: (revision: Int, artifact: CodeArtifact)?
    /// The app asks for a revision when the reader picks one — the artifact
    /// is loaded off the pane's hands — and for none when Reset is pressed.
    public var onChooseRevision: ((Int?) -> Void)?
    /// The code of a revision the reader picked could not be read. The
    /// comparison stays as it was; the app says why, with `showRevisionProblem`.
    public var onRevisionUnreadable: ((Int) -> Void)?
    /// The last pick in the bar each function is still waiting on the code of.
    /// A later pick for the function replaces it, so what comes last from the
    /// store cannot overwrite what the reader chose last.
    private var picksBeingRead: [CodeAddress?: Int] = [:]
    /// The dump bar's left: what the reader is waiting for, and that it moves.
    /// It cannot say how much is left: a read of the store reports no progress.
    private let workBar = NSProgressIndicator()
    private let workLabel = NSTextField(labelWithString: "")
    private var workLabelClearsComparison: NSLayoutConstraint?
    /// Where the strip stands when nothing is under way: what a read the reader
    /// asked for answered, for the function it was asked for. It stays until
    /// they pick again.
    private let problemLabel = NSTextField(labelWithString: "")
    private var problemLabelClearsComparison: NSLayoutConstraint?
    private var barProblems: [CodeAddress?: String] = [:]
    /// The same for an analysis chosen in the header, which is about no function.
    var analysisProblem: String?
    /// What is under way, the last begun last: that one is what the bar names.
    private var worksUnderWay: [(id: Int, words: String, revision: Int?)] = []
    /// The revisions whose code is coming from the server now, and how many
    /// reads wait on each.
    private var revisionDownloads: [Int: Int] = [:]
    private var worksBegun = 0
    private var workReveal: DispatchWorkItem?
    var recipeWork: Int?
    /// A read that ends sooner shows nothing: a bar that flashes explains no
    /// delay.
    var workShownAfter: TimeInterval = 0.3
    let moduleHexView: NSView
    var hexDumpVisible = true
    static let hexDumpHeight: CGFloat = 220

    /// Where the navigator's width is kept. The app points it at its own
    /// store; a package cannot see that a test run reads a suite of its own.
    public static var defaults: UserDefaults = .standard
    static let navigatorWidthKey = "CodeNavigatorWidth"
    /// Room for a POST row's code and function, and a string's address and
    /// the start of its text, before the reader has chosen a width.
    static let defaultNavigatorWidth: CGFloat = 340
    private static let navigatorWidths: ClosedRange<CGFloat> = 180...900
    private static let minimumCodeWidth: CGFloat = 320

    /// The width a code pane's navigator opens with: the one last dragged to.
    static var navigatorWidth: CGFloat {
        let stored = CGFloat(defaults.double(forKey: navigatorWidthKey))
        guard stored > 0 else { return defaultNavigatorWidth }
        return min(max(stored, navigatorWidths.lowerBound), navigatorWidths.upperBound)
    }
    private static let dumpBarHeight: CGFloat = 24
    /// The navigator's header: its fields sit a little further apart than
    /// AppKit's small controls place them, which at the panel's width read as
    /// one cramped block.
    private static let navigatorSpacing: CGFloat = 10
    /// The bar under the list, as Xcode's navigator has it: the filter, and
    /// the switch that lays the Functions list out. It is as tall as the
    /// filter at the standard size and this room around it, since the standard
    /// size is the system's to change from one macOS to the next. Then how far
    /// a call tree's row is set in per level.
    static let navigatorBarRoom: CGFloat = 6
    /// A function-view button: the square each symbol sits in, and the room
    /// between two of them — enough that three read as three buttons.
    private static let orderButtonWidth: CGFloat = 24
    private static let orderButtonHeight: CGFloat = 22
    private static let orderButtonGap: CGFloat = 2
    static let navigatorIndent: CGFloat = 14
    /// How far a review group's function starts past the group's mark.
    static let groupMemberIndent: CGFloat = 13
    /// How deep a call tree's row is drawn: deeper levels keep the last one's
    /// inset rather than running the names off the pane.
    static let navigatorLevels: Int = 10
    /// Where the Functions list's order is kept, like the navigator's width.
    static let navigatorOrderKey = "CodeNavigatorFunctionOrder"
    /// Whether the call tree keeps to the open way, kept the same way.
    static let onlyOpenWayKey = "CodeNavigatorCallTreeOnlyOpenWay"
    private let navigatorBar = CodeNavigatorBar()
    /// The three function-view buttons, kept apart rather than joined into one
    /// segmented control: each is a flat symbol, and the one whose layout is
    /// in front wears the accent colour.
    private let orderButtons = NSStackView()
    /// Takes every New mark at once. It stands in the bar beside the layouts,
    /// so it goes with the Functions list, and stays in its place dimmed while
    /// nothing wears the mark: a button that came and went would move the
    /// filter's edge whenever a revision arrived.
    let clearNewMarksButton = NSButton()
    private var orderButtonViews: [CodeOrderButton] = []
    /// The filter runs to the bar's edge where the buttons are not there.
    private var searchToOrder: NSLayoutConstraint!
    private var searchToEdge: NSLayoutConstraint!
    let staleLabel = NSTextField(labelWithString: "")
    /// Over the code, when the function on screen wears New: what the mark is
    /// about besides the code (`updateNewMarkBanner`).
    private let newMarkBanner = CodeNewMarkBanner()
    /// How the pages start: at the code area's top, or under the plate.
    private var pageTops: [NSLayoutConstraint] = []
    private var belowBannerTops: [NSLayoutConstraint] = []
    /// Whether the pages are under the plate now.
    private var bannerIsUp = false
    /// The navigator's first line — the module, its revision — and the
    /// function over the code, kept to follow the zoom. The versions line
    /// under the module follows with `recipeLine`.
    private var nameLabel: NSTextField?
    /// Before the name, as the UEFI tree shows them beside it: how far the
    /// module's review has got, and whose code it is.
    private let readinessMark = NSImageView()
    private let originBadge = ToolPanelOriginBadge()
    private var readinessSize: [NSLayoutConstraint] = []
    private var moduleLine: NSStackView?
    /// The module line over the versions line.
    private var moduleBlock: NSStackView?
    private var moduleStatus: NSView?
    private var revisionLabel: NSTextField?
    private let functionLabel = CodeTitleField(labelWithString: "")
    /// The function over the code; nothing while the description is on screen.
    private let functionLine = NSStackView()
    private var codeStackLeading: NSLayoutConstraint?
    /// The description's column of sections runs the height of the code area,
    /// beside the header as well; the code's margin, without it.
    private static let codeMargin: CGFloat = 12
    private static let sectionColumnInset: CGFloat = 8
    private static let sectionColumnWidth: CGFloat = 220
    /// After the function's name, a library function's badge as the
    /// navigator draws it, with what the library registry says of it.
    let functionMark = CodeBaselineImageView()
    private var zoomObserver: NSObjectProtocol?
    /// Settings ▸ Code Analysis switching the New marks on or off.
    private var newMarkTrackingObserver: NSObjectProtocol?
    /// Settings ▸ Code Analysis switching the readiness circle on or off.
    private var readinessObserver: NSObjectProtocol?
    /// Set while the view moves a table's selection itself, so the table's
    /// delegate does not take the move for a click.
    var syncingSelection = false

    /// An instruction's bytes from a listing click. The app selects them in
    /// the hex view.
    public var onSelectRange: ((Range<UInt64>) -> Void)?
    /// The bytes a name in the C stands for — a global, a string, a GUID —
    /// reached by ⌘-click, a double click or Show in Dump. The app selects
    /// them and marks them as it marks a search's current match. Without it,
    /// `onSelectRange` selects them.
    public var onPointBytes: ((Range<UInt64>) -> Void)?
    /// A function's whole stored range, shown as the dump's main zone rather
    /// than as a selection: the reader keeps the selection for reading bytes.
    public var onFocusRange: ((Range<UInt64>) -> Void)?
    /// Add Annotation… on a function or an instruction: the place, and the
    /// name the form suggests as the title. The app asks for the note.
    public var onAnnotate: ((CodeLocation, String) -> Void)?
    /// A step through a name's occurrences went round from the last to the
    /// first (true) or from the first to the last: the app shows the same
    /// plate as a search that wrapped.
    public var onWrapOccurrences: ((Bool) -> Void)?
    /// Open Annotation “title” on an annotated row: the annotation's id.
    public var onOpenNote: ((String) -> Void)?
    /// Another stored analysis of the same module was chosen. The app loads
    /// its artifact and rebuilds the screen; the pane does not read the store.
    public var onChooseRecipe: ((AnalysisManifest) -> Void)?

    public convenience init(manifest: AnalysisManifest, artifact: CodeArtifact,
                            moduleBytes: Data? = nil, hexView: NSView,
                            recipes: [AnalysisManifest] = []) {
        self.init(manifest: manifest,
                  model: CodeModel(artifact: artifact, moduleBytes: moduleBytes),
                  hexView: hexView, recipes: recipes)
    }

    /// A pane over a model already built — off the main actor, for a module
    /// whose indices take a moment.
    public init(manifest: AnalysisManifest, model: CodeModel, hexView: NSView,
                recipes: [AnalysisManifest] = []) {
        self.manifest = manifest
        self.artifact = model.artifact
        self.state = CodeReaderState(model: model)
        // The order the last code panel was read in, before the first list is
        // drawn.
        if let stored = FunctionOrder(rawValue: Self.defaults.integer(forKey: Self.navigatorOrderKey)) {
            self.state.show(stored)
        }
        self.state.showOnlyOpenWay(Self.defaults.bool(forKey: Self.onlyOpenWayKey))
        self.moduleHexView = hexView
        self.recipes = Self.ordered(manifest, recipes)
        // ASM and C are names of formats, not words to translate.
        modeControl = NSSegmentedControl(labels: ["ASM", "C"], trackingMode: .selectOne,
                                         target: nil, action: nil)
        navigatorTabs = CodeNavigatorTab.tabs(for: AnalysisProfile.derive(for: manifest.module))
        listControl = NSSegmentedControl(labels: Self.segmentLabels(navigatorTabs),
                                         trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        build(hexView: moduleHexView)
        drawNavigator()
        drawSelection()
        applyMode()
        resetHistory()
        // The code is read at the size of the dump beside it: View ▸ Zoom In
        // and Zoom Out move both.
        zoomObserver = ToolPanelFont.observeZoom { [weak self] in self?.zoomChanged() }
        newMarkTrackingObserver = CodeRevisionSeen.observeTracking { [weak self] in
            self?.newMarkTrackingChanged()
        }
        readinessObserver = CodeReadinessDisplay.observe { [weak self] in self?.drawModuleMarks() }
    }

    deinit {
        if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
        if let newMarkTrackingObserver { NotificationCenter.default.removeObserver(newMarkTrackingObserver) }
        if let readinessObserver { NotificationCenter.default.removeObserver(readinessObserver) }
    }

    /// Every analysis newest first, as the agent lists them — the recipe id
    /// breaking a tie. The one shown keeps its place: a line where it is not
    /// on top says at once that a newer analysis exists.
    private static func ordered(_ manifest: AnalysisManifest,
                                _ recipes: [AnalysisManifest]) -> [AnalysisManifest] {
        var seen: Set<String> = []
        return ([manifest] + recipes)
            .filter { seen.insert($0.recipe.id).inserted }
            .sorted {
                $0.analyzedAt == $1.analyzedAt
                    ? $0.recipe.id < $1.recipe.id
                    : $0.analyzedAt > $1.analyzedAt
            }
    }

    /// Another reading of the same module — a later revision, another
    /// analysis — drawn in this pane. Only the data changes: the tab in
    /// front, the list's order and filter, ASM or C, the description open or
    /// not, the dump shown or hidden stay as the reader left them. What
    /// belonged to the reading before — its revisions, marks, comparisons,
    /// reads in flight, the place by its numbering — is let go; the caller
    /// puts the place, the marks and the history back by address, as it does
    /// for a pane it has just made.
    public func adoptReading(manifest: AnalysisManifest, model: CodeModel, recipes: [AnalysisManifest]) {
        // What is open over the old code is about the old code.
        explanationPopover?.close()
        explanationPopover = nil
        functionPopover?.close()
        functionPopover = nil
        callersPopover?.close()
        callersPopover = nil
        pendingFunctionPopover?.cancel()
        pendingFunctionPopover = nil
        highlight(nil)
        searchAllTask?.cancel()
        searchAllTask = nil
        descriptionRead?.cancel()
        descriptionRead = nil

        readingGeneration += 1
        self.manifest = manifest
        self.recipes = Self.ordered(manifest, recipes)
        let tabs = CodeNavigatorTab.tabs(for: AnalysisProfile.derive(for: manifest.module))
        if tabs != navigatorTabs {
            navigatorTabs = tabs
            showRecordSection(nil)
            if showsInterfacesTab, segment(of: .interfaces) == nil { showInterfacesTab(false) }
            configureListSegments()
        }
        // Another revision's rows are read again (`setModuleRecords`).
        setModuleRecords(nil)
        state = state.carried(to: model)
        artifact = model.artifact

        // The reads of the code.
        functionsBeingRead = []
        functionsNotRead = []
        lastFunctionAsked = nil
        waitingForFunctions = []
        // What was drawn, by the old numbering.
        history = []
        historyIndex = -1
        cLinks = []
        shownCTokens = []
        shownCSymbols = nil
        drawnC = nil
        drawnFunction = nil
        cShift = 0
        // The revisions and what the code was compared with.
        revisionBaseline = nil
        baselineReadFor = nil
        drawnDiff = nil
        diffFunction = nil
        diffBaselineModel = nil
        diffBaselineIndex = nil
        revisionHasChanges = false
        revisionChoices = []
        changedByCurrentRevision = nil
        hasRevisionHistory = false
        comparisonRevision = nil
        functionComparisons = [:]
        previousRevision = nil
        picksBeingRead = [:]
        barProblems = [:]
        analysisProblem = nil
        unreadableFunction = nil
        readRevisions = [:]
        readOrder = []
        revisionsBeingRead = []
        // The description's comparison and mark.
        descriptionChoice = nil
        descriptionMark = nil
        descriptionBaseline = nil
        descriptionReads = [:]
        descriptionBeingRead = nil
        descriptionChangedByCurrentRevision = nil
        searchedDescription = nil
        // New marks and what the reader has seen: the app gives them again.
        marksWereCleared = false
        unopenedChanges = [:]
        seen = [:]
        seenLoaded = false
        unrecorded = []
        revisionsToSettle = []
        // Whatever was under way was for the reading before.
        worksUnderWay = []
        revisionDownloads = [:]
        recipeWork = nil
        recipeSpinner.stopAnimation(nil)
        recipeSpinner.isHidden = true
        recipeLine.isEnabled = true
        updateWorkLine()

        drawReadingHeader()
        indexNotes()
        drawNavigator()
        drawSelection()
        applyMode()
        resetHistory()
        rebuildRevisionMenu()
        updateProblemLine()
        drawDescriptionButton()
        drawDescriptionBadge()
        if showsInterfacesTab { drawInterfaces() }
    }

    /// The navigator's head over a reading: the module, its revision, its
    /// marks and the versions line.
    private func drawReadingHeader() {
        nameLabel?.stringValue = manifest.module.name.isEmpty ? manifest.recipe.id : manifest.module.name
        revisionLabel?.stringValue = manifest.reading.map { "(r\($0.rev))" } ?? ""
        revisionLabel?.isHidden = manifest.reading == nil
        drawModuleMarks()
        guard let moduleBlock, moduleBlock.arrangedSubviews.count > 1 else { return }
        moduleBlock.arrangedSubviews[1].removeFromSuperview()
        recipeLine.removeFromSuperview()
        recipeSpinner.removeFromSuperview()
        if recipes.count <= 1 { recipeLine.setChoices([], chosen: nil) }
        moduleBlock.insertArrangedSubview(recipes.count > 1 ? recipeMenu() : recipeVersions(), at: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCodeBackground()
    }

    var descriptionChoice: DescriptionChoice?

    /// The revision the description is new against: it reads otherwise than
    /// when the reader last had it open. Taken when they leave it, as a
    /// function's mark is.
    var descriptionMark: Int?

    /// The revision the description is compared with now, and its text then
    /// ("" when it had none).
    var descriptionBaseline: (revision: Int, text: String)?

    var descriptionReads: [Int: String] = [:]

    var descriptionBeingRead: Int?

    var descriptionChangedByCurrentRevision: Bool?

    /// The read a comparison waits on, for a test.
    var descriptionRead: Task<Void, Never>?

    /// Reads the module's description at a revision: "" when it had none,
    /// nil when the store could not give it. The app's half of the seam.
    public var onReadDescription: ((Int) async -> String?)?

    /// Reads a revision's code from the store for one function, for the
    /// comparison a mark puts up; nil when the store has none. It may hold the
    /// other functions without their code. The app's half of the seam.
    public var onReadRevision: ((Int, CodeAddress) async -> CodeArtifact?)?

    var readRevisions: [RevisionRead: CodeArtifact] = [:]

    var readOrder: [RevisionRead] = []

    var revisionsBeingRead: Set<RevisionRead> = []

    /// How many revisions were read for marks, for a test.
    var revisionReads = 0

    /// Set while the pane selects bytes of its own — a link to a global — so
    /// the hex view's report of that selection does not move the code.
    var selectingBytes = false

    /// The name in the C the open popover explains; nil for one opened on
    /// the listing.
    var explainedInC: NSRange?

    /// The C the reader acted on last — the call they ⌘-clicked — which the
    /// place they leave keeps as its mark.
    var leavingCMark: NSRange?

    var lastFlash: Flash?

    var flashView: NSView?

    /// The width the navigator's columns were last fitted to. A pane is built
    /// before it has its size, so the columns are fitted again once it does —
    /// and the table's own last-column sizing does not know that a column in
    /// front of it was resized.
    var fittedNavigatorWidth: CGFloat = 0

    // MARK: - What the reader sees

    public var functionCount: Int { model.functions.count }
    public var instructionCount: Int { model.lines.count }
    /// The rows the listing shows: the selected function's instructions.
    public var listedInstructionCount: Int { state.lines.count }
    public var listedFunctionCount: Int { state.listedFunctions.count }
    public var listedStringCount: Int { state.listedStrings.count }
    public var listedPostCodeCount: Int { state.listedPostCodes.count }
    public var listedStatusCodeCount: Int { state.listedStatusCodes.count }
    /// What a navigator row reads, for tests.
    func navigatorRowText(_ row: Int) -> String { navigatorText(at: row) }
    var navigatorListIndex: Int { listControl.selectedSegment }
    /// The navigator switch itself, for tests that it is kept, not rebuilt.
    var navigatorSwitch: NSSegmentedControl { listControl }
    var descriptionSectionTitles: [String] { descriptionView.sections.map(\.title) }
    /// The section selected in the column, nil when none is shown; for tests.
    var shownSectionTitle: String? { showsSectionColumn ? descriptionView.selectedSectionTitle : nil }
    var showsSectionColumn: Bool { !descriptionView.sectionColumn.isHidden }
    var descriptionButtonIsOn: Bool { descriptionButton.state == .on }
    var descriptionButtonTint: NSColor? { descriptionButton.contentTintColor }
    var descriptionButtonImage: NSImage? { descriptionButton.image }
    var descriptionButtonIsEnabled: Bool { descriptionButton.isEnabled }
    private(set) var descriptionButtonSymbol = ""
    func clickDescriptionButton() { descriptionButton.performClick(nil) }
    func clickCloseDescription() { descriptionView.closeButton.performClick(nil) }
    /// The C's text view and the ASM listing, for the tests of the current line.
    var cTextViewForTests: CodeTextView { cTextView }
    var listingForTests: NSTableView { table }
    var descriptionCloseFrame: NSRect { convert(descriptionView.closeButton.bounds, from: descriptionView.closeButton) }
    var descriptionFrameInPane: NSRect { convert(descriptionView.bounds, from: descriptionView) }
    var codeAreaFrameInPane: NSRect { convert(codeContent.bounds, from: codeContent) }
    /// How far the description's text stands from its view's top and bottom.
    var descriptionTextInset: CGFloat { descriptionView.textView.textContainerInset.height }
    /// How far the column stands from the top of the code area and from the
    /// dump's bar, for a test.
    var sectionColumnGaps: (top: CGFloat, bottom: CGFloat) {
        let column = convert(descriptionView.sectionColumn.bounds, from: descriptionView.sectionColumn)
        let area = convert(codeContent.bounds, from: codeContent)
        let bar = convert(hexDumpBar.bounds, from: hexDumpBar)
        return (area.maxY - column.maxY, column.minY - bar.maxY)
    }
    func clickDescriptionSection(_ index: Int) { descriptionView.clickSection(index) }
    var headerShowsFunction: Bool { codeStack?.isHidden != true }
    /// The navigator's column headers; none for a one-column list.
    var navigatorColumnTitles: [String] {
        functionTable.headerView == nil ? [] : functionTable.tableColumns.map(\.title)
    }
    /// What an empty list says, for tests; nil while it has rows.
    var emptyListText: String? { emptyListLabel.isHidden ? nil : emptyListLabel.stringValue }
    /// What a POST row's column shows, for tests.
    func postCell(_ row: Int, _ column: PostColumn) -> String {
        postCodeCell(artifact.postCodes[state.listedPostCodes[row]], column)
    }

    public var selectedInstruction: CodeArtifact.Instruction? { state.selectedLine?.instruction }
    public var selectedFunction: CodeArtifact.Function? { state.selectedFunction }
    public var decompiledText: String { cTextView.string }
    /// The decompiled C as drawn: its colours and links, for tests.
    public var decompiledAttributedText: NSAttributedString {
        cTextView.textStorage.map { NSAttributedString(attributedString: $0) } ?? NSAttributedString()
    }
    public var canGoBack: Bool { historyIndex > 0 }
    public var canGoForward: Bool { historyIndex + 1 < history.count }
    public var selectedFunctionIndex: Int? { state.function }
    public var selectedInstructionIndex: Int? { state.line }
    /// The place by address: what survives an artifact whose functions are
    /// numbered differently — another recipe, a re-run, a republished review.
    public var selectedLocation: CodeLocation? {
        let location = CodeLocation(function: selectedFunction?.entry,
                                    address: selectedInstruction?.address)
        return location.isEmpty ? nil : location
    }

    /// Where each function was left in the code, by the function's entry —
    /// the line at the top of the code area, counted from zero. The screen
    /// carries it into the workspace and the project, so a long function is
    /// picked up where it was read. The function on screen is included as it
    /// stands; one the code is not showing, because the listing or the
    /// description is, keeps the line it had.
    public var topLinePositions: [String: Int] {
        var lines = topLines
        // A function not read yet shows no code to have a line in.
        if let index = state.function, model.functions.indices.contains(index), !model.isPending(index),
           let line = currentTopLine() {
            lines[model.functions[index].entry.description] = line
        }
        return lines
    }

    /// Puts back the lines the screen kept. Called before `restore`, so the
    /// function it opens on is read from its own line; the pane may already
    /// have drawn one of its own by then, and that one is put back at once.
    public func restoreTopLines(_ lines: [String: Int]) {
        topLines = lines
        guard mode == 1, let index = state.function,
              model.functions.indices.contains(index),
              let line = lines[model.functions[index].entry.description] else { return }
        if showsRevisionDiff { diffView.scroll(toNewLine: line) } else { scrollC(toLine: line) }
    }

    public var selectedString: CodeArtifact.StringEntry? {
        navigatorEntry(in: .strings, state.listedStrings).map { artifact.strings[$0] }
    }
    public var selectedPostCode: CodeArtifact.PostCode? {
        navigatorEntry(in: .postCodes, state.listedPostCodes).map { artifact.postCodes[$0] }
    }
    public var selectedStatusCode: CodeArtifact.StatusCodeCall? {
        navigatorEntry(in: .statusCodes, state.listedStatusCodes).map { artifact.statusCodeCalls[$0] }
    }

    private func navigatorEntry(in list: List, _ listed: [Int]) -> Int? {
        let row = functionTable.selectedRow
        guard state.list == list, listed.indices.contains(row) else { return nil }
        return listed[row]
    }

    /// The C rather than the listing: what is on screen, or — while the
    /// description or the diff is — what the code shows when the reader goes
    /// back to it.
    public var showsDecompiledC: Bool {
        mode > 1 ? codeShowsC : mode == 1
    }
    /// Sizes the C side to the comparison: the diff where the revisions
    /// differ, the code where they do not, and the code whenever the side on
    /// screen is not the C.
    private func refreshDiffVisibility() {
        showsRevisionDiff = updateDiff()
        diffView.isHidden = !showsRevisionDiff
        cScroll.isHidden = mode != 1 || showsRevisionDiff
    }

    /// The C against a revision, while one is compared against, the C side is
    /// the one on screen and the two revisions' C differs there: a function
    /// the revision did not change is shown as the code, not as a diff of
    /// nothing.
    public private(set) var showsRevisionDiff = false
    /// What the comparison would show if the function differed.
    private var wantsRevisionDiff: Bool {
        comparisonRevision != nil && mode == 1
    }
    /// The module's description is on screen in place of the code.
    /// How far the description is scrolled, for a test.
    public var descriptionScrollY: CGFloat { descriptionView.scrollOrigin.y }
    public var showsDescription: Bool { mode == Self.descriptionSegment }
    private static let descriptionSegment = 2

    /// Whether the pane has a revision to compare the code against.
    public var canShowRevisionDiff: Bool { revisionBaseline != nil }

    /// Whether the dump bar shows the comparison — the metalabel, the arrows,
    /// the picker and Reset. The app reads it of a pane it put in a container
    /// of its own: what is wired is not a question the container may answer.
    public var comparisonIsShown: Bool { !compareLabel.isHidden }

    /// A revision the dump bar's picker offers: what it is called, and
    /// whether the store holds the code to compare against.
    public struct RevisionChoice: Equatable, Sendable {
        public let revision: Int
        public let title: String
        public let hasCode: Bool
        /// The functions whose C this revision changed; nil when nobody knows.
        public let changed: Set<CodeAddress>?
        /// Whether this revision changed the module's description; nil when
        /// nobody knows.
        public let changedDescription: Bool?

        public init(revision: Int, title: String, hasCode: Bool, changed: Set<CodeAddress>? = nil,
                    changedDescription: Bool? = nil) {
            self.revision = revision
            self.title = title
            self.hasCode = hasCode
            self.changed = changed
            self.changedDescription = changedDescription
        }
    }

    /// What the dump bar's picker offers and which revision is on screen:
    /// the app reads the module's history and says so here. With nothing to
    /// offer the whole comparison stays out of the bar.
    public func setRevisionChoices(_ choices: [RevisionChoice], current: Int?,
                                   knowsRevisions: Bool = false, currentChanged: Set<CodeAddress>? = nil,
                                   currentChangedDescription: Bool? = nil) {
        revisionChoices = choices
        changedByCurrentRevision = currentChanged
        descriptionChangedByCurrentRevision = currentChangedDescription
        hasRevisionHistory = knowsRevisions || !choices.isEmpty
        compareLabel.stringValue = current.map { L("This revision (r%1$@)", String($0)) } ?? L("This revision")
        keepComparisonChoice()
        rebuildRevisionMenu()
        // A comparison put up before the list arrived — a New mark's, while
        // the store's history is still being read — keeps its place in the
        // bar: a rebuilt menu starts at "No comparison", and the bar would
        // say the code is compared with nothing while the diff shows it is.
        selectRevisionItem(comparisonRevision)
        layOutComparison()
    }

    /// The revision the Diff compares against, its code loaded by the app;
    /// nil clears the comparison. `pinned` is the reader's pick in the bar,
    /// which that function keeps until another pick or Reset. `function` is the
    /// function it was picked for, when the code took long enough to read that
    /// the reader may have moved on; the open one when nil.
    public func setComparisonRevision(_ revision: Int?, artifact: CodeArtifact?,
                                      pinned: Bool = false, function: CodeAddress? = nil) {
        setComparisonRevision(revision, artifact: artifact, pinned: pinned, function: function, readFor: nil)
    }

    /// The reader's pick in the bar, for the function on screen, whose code
    /// has to be read first, by `read`, for that function alone. It may take
    /// long: the reader may move on to another function, which keeps the pick,
    /// or pick again, which replaces it. A read this pane still holds is not
    /// made again. The task is for a test to wait on.
    // help: panel.code.diff
    @discardableResult
    public func compareWithPickedRevision(_ revision: Int,
                                          read: @escaping @MainActor () async -> CodeArtifact?) -> Task<Void, Never> {
        let function = openFunctionEntry
        barProblems[function] = nil
        updateProblemLine()
        if let function, let held = readRevisions[RevisionRead(revision: revision, function: function)] {
            setComparisonRevision(revision, artifact: held, pinned: true, function: function, readFor: function)
            return Task {}
        }
        if let replaced = picksBeingRead[function] { endWork(replaced) }
        let pick = beginRevisionWork(revision)
        picksBeingRead[function] = pick
        let generation = readingGeneration
        return Task { @MainActor [weak self] in
            let artifact = await read()
            guard let self, self.readingGeneration == generation,
                  self.picksBeingRead[function] == pick else { return }
            self.picksBeingRead[function] = nil
            self.endWork(pick)
            if let artifact {
                if let function { self.keepRead(artifact, RevisionRead(revision: revision, function: function)) }
                self.setComparisonRevision(revision, artifact: artifact, pinned: true, function: function,
                                           readFor: function)
            } else {
                if function == self.openFunctionEntry { self.selectRevisionItem(self.comparisonRevision) }
                self.unreadableFunction = function
                self.onRevisionUnreadable?(revision)
            }
        }
    }

    /// The function the last `onRevisionUnreadable` was about: the reader may
    /// have moved on since asking.
    var unreadableFunction: CodeAddress?

    /// Says in the dump bar, until the reader picks again, why the revision
    /// `onRevisionUnreadable` just reported did not come.
    public func showRevisionProblem(_ words: String) {
        barProblems[unreadableFunction] = words
        updateProblemLine()
    }

    /// Names a long read in the dump bar for as long as `body` takes.
    public func whileWorking<T>(_ words: String, _ body: @MainActor () async -> T) async -> T {
        let work = beginWork(words)
        defer { endWork(work) }
        return await body()
    }

    /// Names a read of a revision's code in the dump bar for as long as `body`
    /// takes: as a download while `noteRevisionDownload` says one is under way.
    public func whileReadingRevision<T>(_ revision: Int, _ body: @MainActor () async -> T) async -> T {
        let work = beginRevisionWork(revision)
        defer { endWork(work) }
        return await body()
    }

    /// The code of `revision` has started or finished coming from the server.
    public func noteRevisionDownload(_ revision: Int, underWay: Bool) {
        let count = (revisionDownloads[revision] ?? 0) + (underWay ? 1 : -1)
        revisionDownloads[revision] = count > 0 ? count : nil
        updateWorkLine()
    }

    func beginRevisionWork(_ revision: Int) -> Int {
        beginWork(L("Reading revision r%1$@…", String(revision)), revision: revision)
    }

    func beginWork(_ words: String, revision: Int? = nil) -> Int {
        worksBegun += 1
        worksUnderWay.append((worksBegun, words, revision))
        updateWorkLine()
        return worksBegun
    }

    func endWork(_ id: Int) {
        worksUnderWay.removeAll { $0.id == id }
        updateWorkLine()
    }

    private func updateWorkLine() {
        guard let work = worksUnderWay.last else {
            workReveal?.cancel()
            workReveal = nil
            showWorkLine(false)
            return
        }
        let words = work.revision.flatMap { revisionDownloads[$0] == nil ? nil : $0 }
            .map { L("Downloading revision r%1$@…", String($0)) } ?? work.words
        workLabel.stringValue = words
        ControlHelp.describe(workBar, words)
        guard workBar.isHidden, workReveal == nil else { return }
        guard workShownAfter > 0 else {
            showWorkLine(true)
            return
        }
        let reveal = DispatchWorkItem { [weak self] in
            self?.workReveal = nil
            self?.showWorkLine(true)
        }
        workReveal = reveal
        DispatchQueue.main.asyncAfter(deadline: .now() + workShownAfter, execute: reveal)
    }

    private func showWorkLine(_ shows: Bool) {
        workBar.isHidden = !shows
        workLabel.isHidden = !shows
        workLabelClearsComparison?.isActive = shows
        if shows { workBar.startAnimation(nil) } else { workBar.stopAnimation(nil) }
        updateProblemLine()
    }

    /// The problem of the function on screen, unless the strip has the place.
    func updateProblemLine() {
        let words = workBar.isHidden ? barProblems[openFunctionEntry] ?? analysisProblem : nil
        problemLabel.stringValue = words ?? ""
        ControlHelp.describe(problemLabel, words)
        problemLabel.isHidden = words == nil
        problemLabelClearsComparison?.isActive = words != nil
    }

    /// What the dump bar says went wrong, for a test.
    var shownProblem: String? { problemLabel.isHidden ? nil : problemLabel.stringValue }
    func toolTip(ofProblem: Void) -> String? { problemLabel.toolTip }

    /// What the dump bar says is under way, for a test; nil while it shows nothing.
    var shownWork: String? { workBar.isHidden ? nil : workLabel.stringValue }

    /// `readFor`: the one function `artifact` holds the code of, when it was
    /// read for that function alone.
    func setComparisonRevision(_ revision: Int?, artifact: CodeArtifact?, pinned: Bool,
                                       function: CodeAddress?, readFor: CodeAddress?) {
        if pinned, let pick = picksBeingRead.removeValue(forKey: function ?? openFunctionEntry) { endWork(pick) }
        if pinned, let entry = function ?? openFunctionEntry {
            if let revision, let artifact {
                functionComparisons[entry] = .against(.init(revision: revision, artifact: artifact, readFor: readFor))
            } else {
                functionComparisons[entry] = .noComparison
            }
            guard entry == openFunctionEntry else { return }
        }
        comparisonRevision = artifact == nil ? nil : revision
        revisionBaseline = artifact
        baselineReadFor = artifact == nil ? nil : readFor
        revisionCount += 1
        drawnDiff = nil
        keepComparisonChoice()
        rebuildRevisionMenu()
        selectRevisionItem(comparisonRevision)
        layOutComparison()
        applyMode()
    }

    /// A comparison the picker does not list — a mark's revision, compared
    /// with before the store's list came, or one the list leaves out — is
    /// named in the picker as `rN`: the bar has to say what the code is
    /// compared with. Answers whether the list had to grow.
    @discardableResult
    private func keepComparisonChoice() -> Bool {
        guard let revision = comparisonRevision,
              !revisionChoices.contains(where: { $0.revision == revision }) else { return false }
        revisionChoices.insert(RevisionChoice(revision: revision, title: "r\(revision)", hasCode: true), at: 0)
        hasRevisionHistory = true
        return true
    }

    /// For a test: what the picker offers, by title.
    var revisionChoiceTitles: [String] {
        revisionLine.choices.map(\.title)
    }
    var comparisonIsHidden: Bool { compareLabel.isHidden }
    var comparisonResetIsHidden: Bool { resetComparisonButton.isHidden }
    var comparisonResetIsEnabled: Bool { resetComparisonButton.isEnabled }
    var comparisonResetTint: NSColor? { resetComparisonButton.contentTintColor }
    /// Whether the picker offers a revision, for a test: a revision the store
    /// has no code for is listed greyed and cannot be chosen.
    func revisionChoiceIsEnabled(_ revision: Int) -> Bool? {
        revisionLine.choices.first { $0.tag == revision }?.isEnabled
    }
    /// The title the picker shows as chosen, for a test.
    var selectedRevisionTitle: String? { revisionLine.title }
    /// The bar's words, for a test: their fonts, and the chosen revision's colour.
    var comparisonFonts: [NSFont?] { [compareLabel.font, revisionLine.font, resetComparisonButton.font] }
    var selectedRevisionColor: NSColor? { revisionLine.textColor }

    /// Picks a revision in the bar as the reader would.
    func chooseRevisionMenuTag(_ tag: Int) { chooseRevision(tag) }

    @objc private func resetComparison() {
        if showsDescription { return chooseDescriptionRevision(nil) }
        onChooseRevision?(nil)
    }

    private func chooseRevision(_ tag: Int) {
        if showsDescription { return chooseDescriptionRevision(tag < 0 ? nil : tag) }
        // Reset is a choice too: a mark's comparison does not come back.
        if tag < 0, let entry = openFunctionEntry { functionComparisons[entry] = .noComparison }
        onChooseRevision?(tag < 0 ? nil : tag)
    }

    private static let noComparisonTag = -1

    /// The revisions worth comparing the open function with: those that changed
    /// its C, whose comparison is not empty. The newest of them reads as the
    /// code on screen unless the revision on screen changed it itself, so it is
    /// left out. A revision nobody knows about stays, and so does the one
    /// compared with now: the bar has to say what the diff is against.
    private func offeredRevisionChoices() -> [RevisionChoice] {
        guard let entry = openFunctionEntry else { return revisionChoices }
        var newestReadsAsShown = changedByCurrentRevision.map { !$0.contains(entry) } ?? false
        return revisionChoices.filter { choice in
            var offered = true
            if let changed = choice.changed {
                offered = changed.contains(entry) && !newestReadsAsShown
                if changed.contains(entry) { newestReadsAsShown = false }
            }
            return offered || choice.revision == comparisonRevision
        }
    }

    /// The revisions worth comparing the description with: those that changed
    /// it, as the code's are those that changed the function. The newest of
    /// them reads as the description on screen unless the revision on screen
    /// changed it itself.
    private func offeredDescriptionChoices() -> [RevisionChoice] {
        var newestReadsAsShown = descriptionChangedByCurrentRevision.map { !$0 } ?? false
        return revisionChoices.filter { choice in
            var offered = true
            if let changed = choice.changedDescription {
                offered = changed && !newestReadsAsShown
                if changed { newestReadsAsShown = false }
            }
            return offered || choice.revision == descriptionBaseline?.revision
        }
    }

    /// A revision the store has no code for is listed greyed.
    func rebuildRevisionMenu() {
        var choices = [CodeMenuLine.Choice(title: L("No comparison"), tag: Self.noComparisonTag)]
        let offered = showsDescription ? offeredDescriptionChoices() : offeredRevisionChoices()
        for (index, choice) in offered.enumerated() {
            choices.append(.init(title: choice.title, tag: choice.revision,
                                 isEnabled: showsDescription || choice.hasCode, startsGroup: index == 0))
        }
        revisionLine.setChoices(choices, chosen: barRevision ?? Self.noComparisonTag)
        revisionLine.isEnabled = choices.count > 1
        selectRevisionItem(comparisonRevision)
    }

    /// A revision compared with reads plainly: it is what the diff is against.
    /// "No comparison" keeps the bar's grey, as Reset does then.
    func selectRevisionItem(_ revision: Int?) {
        // The bar speaks of what is on screen: the description has its own.
        let revision = showsDescription ? descriptionBaseline?.revision : revision
        revisionLine.select(revision ?? Self.noComparisonTag)
        revisionLine.setTextColor(revision == nil ? .secondaryLabelColor : .labelColor)
    }

    /// The comparison's words at one size, following the zoom.
    private func drawComparisonFonts() {
        let font = Self.recipeFont()
        compareLabel.font = font
        workLabel.font = font
        problemLabel.font = font
        revisionLine.setFont(font)
        resetComparisonButton.font = font
    }

    /// The comparison shows only when the app found revisions to offer. Reset
    /// stays beside the picker always, disabled while there is nothing to
    /// reset — a control that comes and goes moves the picker under the
    /// pointer.
    private func layOutComparison() {
        let shows = hasRevisionHistory
        for view in [compareLabel, compareArrows, revisionLine, resetComparisonButton] as [NSView] {
            view.isHidden = !shows
        }
        updateResetButton()
    }

    /// Reset is blue while it can act and grey while it cannot: a borderless
    /// button keeps its tint through a disabled state unless it is told.
    func updateResetButton() {
        let enabled = barRevision != nil
        resetComparisonButton.isEnabled = enabled
        resetComparisonButton.contentTintColor = enabled ? .controlAccentColor : .secondaryLabelColor
    }

    /// The diff as drawn, for tests.
    var diffText: String { diffView.shownText }
    var diffCounts: (added: Int, removed: Int)? { diffView.counts }
    var diffPlaceholder: String? { diffView.placeholderText }
    func diffBackground(ofLineContaining line: String) -> NSColor? {
        diffView.background(ofLineContaining: line)
    }
    /// The colour a word of the diff reads in, for a test.
    func diffInk(ofWord word: String) -> NSColor? {
        let range = (diffView.shownText as NSString).range(of: word)
        guard range.location != NSNotFound else { return nil }
        return diffView.ink(of: range)
    }
    /// The ranges the diff has highlighted, for a test.
    var diffHighlightedRanges: [NSRange] { diffView.highlightedRanges }
    var diffExplainableRanges: [NSRange] { diffView.explainable }
    var comparisonRevisionForTest: Int? { comparisonRevision }
    var codeTextWidthForTest: CGFloat { cScroll.contentSize.width }
    var diffSelectedRange: NSRange { diffView.selectedRange }
    /// Where the diff is scrolled, for a test: another function's diff is
    /// read from its top, never from where a longer one was left.
    var diffScrollOrigin: NSPoint {
        get { diffView.scrollOrigin }
        set { diffView.scroll(to: newValue) }
    }
    /// The C's scroll position and the furthest it goes, for a test: a
    /// function is picked up at the line it was left at, and one that came
    /// back shorter shows its last part.
    var cScrollOrigin: NSPoint { cScroll.contentView.bounds.origin }
    var cMaxScroll: CGFloat { max(0, cTextView.frame.height - cScroll.contentView.bounds.height) }
    func scrollCForTest(toLine line: Int) { scrollC(toLine: line) }

    /// The description, as drawn, for tests.
    var descriptionText: String { descriptionView.shownText }
    var descriptionAttributedText: NSAttributedString { descriptionView.attributedText }
    var descriptionPlaceholder: String { descriptionView.placeholderText }
    var descriptionScrollOrigin: NSPoint { descriptionView.scrollOrigin }
    func scrollDescription(to origin: NSPoint) { descriptionView.scroll(to: origin) }
    /// Follows the link at `index` of the description, as a click would.
    @discardableResult
    func followDescriptionLink(at index: Int) -> Bool { descriptionView.followLink(at: index) }

    /// The module's description, Markdown, as the reading names it; nil
    /// when it has none. The app reads it from the store after the pane is
    /// made, so the code is never kept waiting for it.
    public func setModuleDescription(_ markdown: String?) {
        descriptionView.show(markdown)
        findTextMayHaveChanged()
        searchDescriptionAgainIfChanged(markdown)
        hasDescription = !(markdown ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if opensOnDescription, hasDescription { showDescription(true) }
        opensOnDescription = false
        if let origin = pendingDescriptionScroll {
            pendingDescriptionScroll = nil
            layoutSubtreeIfNeeded()
            descriptionView.scroll(to: origin)
        }
    }

    /// Whether the description, once read, takes the code's place: a module
    /// opened afresh is read from what it is for, not from its first
    /// function. Set by the app for a screen with no place to return to; the
    /// reader's own choice first — the switch, the book, a function chosen in
    /// the list, a place gone to — keeps the code.
    public var opensOnDescription = false

    /// Whether the module has a description to read. The book says which of
    /// three it is: closed and unavailable while there is none (or it is
    /// still being read), closed with text on it in the link colour once
    /// there is one, open while it is on screen.
    public private(set) var hasDescription = false {
        didSet { if hasDescription != oldValue { drawDescriptionButton() } }
    }

    private func drawDescriptionButton() {
        let symbol = showsDescription ? "book" : hasDescription ? "text.book.closed" : "book.closed"
        descriptionButtonSymbol = symbol
        descriptionButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        descriptionButton.idleTint = hasDescription ? .linkColor : .secondaryLabelColor
        // Open, it is what closes the description, text or not.
        descriptionButton.isEnabled = hasDescription || showsDescription
    }

    /// Shows the module's description in place of the code, or the code
    /// again — as the segment does.
    public func showDescription(_ shows: Bool) {
        guard shows != showsDescription else { return }
        mode = shows ? Self.descriptionSegment : (codeShowsC ? 1 : 0)
        applyMode()
    }

    // MARK: - Drawing the state

    /// Goes to the place a POST code or a status code is sent from, keeping
    /// the list it was chosen in: the instruction in the listing, the call in
    /// the C, its bytes in the hex view. A place Back returns from.
    func showSite(_ address: CodeAddress) {
        if model.line(at: address) == nil, let pending = model.pendingFunction(holding: address) {
            whenRead([pending]) { [weak self] in self?.showSite(address) }
            return
        }
        guard let line = model.line(at: address) else {
            // An address the listing does not hold: its byte, as before.
            if let range = model.moduleRange(of: address, count: 1) { onSelectRange?(range) }
            return
        }
        jump {
            state.selectLine(line)
            drawSelection()
        }
        selectSiteInC(address)
        notifyInstruction()
        flashArrival()
    }

    /// Selects the call made at `address` in the C showing, when the
    /// artifact places it (v5).
    private func selectSiteInC(_ address: CodeAddress) {
        guard let function = state.selectedFunction,
              let site = function.cSites.first(where: { $0.address == address }) else { return }
        let range = NSRange(location: site.start + cShift, length: site.length)
        guard NSMaxRange(range) <= (cTextView.string as NSString).length else { return }
        cTextView.setSelectedRange(range)
        cTextView.scrollRangeToVisible(range)
    }

    /// Shows the function holding `line` and selects that instruction.
    func select(line: Int) {
        revealInNavigator(model.lines[line].function)
        let previous = state.function
        state.selectLine(line)
        redrawCallTree(leaving: previous)
        drawSelection()
    }

    /// The call tree stands around the selected function, so another selection
    /// redraws it.
    func redrawCallTree(leaving previous: Int?) {
        guard state.function != previous, state.functionOrder == .calls,
              state.list == .functions, state.searchText.isEmpty else { return }
        // A table with no empty selection chooses its first row as it takes its
        // data, while the pane is still being built: the first draw comes after.
        guard searchToOrder != nil else { return }
        keepingChosenRow { drawNavigator() }
    }

    /// Keeps the row chosen where it is on screen while `change` moves the rows
    /// around it, so a click does not move the row under the pointer.
    func keepingChosenRow(_ change: () -> Void) {
        let clip = functionTable.enclosingScrollView?.contentView
        let chosen = functionTable.selectedRow
        let offset = chosen >= 0 ? clip.map { functionTable.rect(ofRow: chosen).minY - $0.bounds.minY } : nil
        change()
        guard let clip, let offset, offset >= 0, offset < clip.bounds.height,
              let function = state.function, let row = state.row(ofFunction: function) else { return }
        let lowest = max(0, functionTable.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX,
                                y: min(max(0, functionTable.rect(ofRow: row).minY - offset), lowest)))
        functionTable.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// Brings a function into the navigator, redrawing the list when the
    /// state had to switch to Functions or clear the search for it.
    func revealInNavigator(_ function: Int) {
        guard state.reveal(function: function) else { return }
        listControl.selectedSegment = segment(of: .list(.functions)) ?? -1
        searchField.stringValue = state.searchText
        drawNavigator()
    }

    /// The navigator's title and rows for the list in front, with the selected
    /// function's row chosen when Functions is showing.
    func drawNavigator() {
        listControl.selectedSegment = shownSegment
        // The switch speaks about the functions only: with another list in
        // front the filter takes its room.
        let showsOrder = state.list == .functions
        orderButtons.isHidden = !showsOrder
        clearNewMarksButton.isHidden = !showsOrder
        // One chain, never two: the filter runs to the layout buttons while
        // the functions are shown and to the bar's edge otherwise, and the
        // navigator is drawn inside a layout pass — the chain being left is
        // let go before the other is taken.
        if showsOrder {
            searchToEdge.isActive = false
            searchToOrder.isActive = true
        } else {
            searchToOrder.isActive = false
            searchToEdge.isActive = true
        }
        // The readiness strip is the function list's: no other list counts.
        if showsOrder {
            var counts: [CodeReaderState.FunctionGroup: Int] = [:]
            for index in model.functions.indices { counts[state.group(of: index), default: 0] += 1 }
            readinessBar.show(counts)
        }
        readinessBar.isHidden = !showsOrder || showsNavigatorTab
        readinessHeight.constant = showsOrder ? CodeReviewReadinessBar.height : 0
        markChosenOrder(state.functionOrder)
        layOutNavigatorColumns()
        drawEmptyList()
        syncingSelection = true
        functionTable.reloadData()
        if state.list == .functions, let function = state.function,
           let row = state.row(ofFunction: function) {
            functionTable.selectRowIndexes(state.selectedFunctionRows, byExtendingSelection: false)
            functionTable.scrollRowToVisible(row)
        } else {
            functionTable.deselectAll(nil)
        }
        syncingSelection = false
    }

    /// How the Functions list is laid out, as the bar's buttons have it.
    public var functionOrder: FunctionOrder { state.functionOrder }

    /// The bar's function-view buttons, in the order they are drawn, for a
    /// test to find them by.
    var navigatorOrderButtons: [NSButton] { orderButtonViews }

    /// The readiness strip's segments — the review's groups and how many
    /// functions each holds — for a test.
    var navigatorReadiness: [(group: CodeReaderState.FunctionGroup, count: Int)] {
        readinessBar.segments
    }

    /// Whether the readiness strip is showing: it speaks about the functions,
    /// so another list in front takes it away.
    var navigatorReadinessIsShown: Bool { !readinessBar.isHidden }

    /// Lays the Functions list out in `order`, as the switch in the bar does,
    /// and keeps the choice for the next code panel.
    public func setFunctionOrder(_ order: FunctionOrder) {
        Self.defaults.set(order.rawValue, forKey: Self.navigatorOrderKey)
        markChosenOrder(order)
        guard state.show(order) else { return }
        drawNavigator()
    }

    @objc private func orderChosen(_ sender: NSButton) {
        guard let order = FunctionOrder(rawValue: sender.tag) else { return }
        // The call tree's button, pressed again, goes round its two forms.
        if order == .calls, state.functionOrder == .calls {
            markChosenOrder(order)
            setShowsOnlyOpenWay(!state.showsOnlyOpenWay)
            return
        }
        setFunctionOrder(order)
    }

    /// Keeps the call tree to the way down to the place being read, or shows
    /// every way again, and keeps the choice for the next code panel.
    func setShowsOnlyOpenWay(_ only: Bool) {
        Self.defaults.set(only, forKey: Self.onlyOpenWayKey)
        state.showOnlyOpenWay(only)
        drawCallTreeButton()
        guard state.functionOrder == .calls else { return }
        keepingChosenRow { drawNavigator() }
    }

    /// The right-click's way to the same two forms: every way shown, the row's
    /// place is made the one read, and the tree keeps to the way down to it.
    func showOnlyWay(atRow row: Int) {
        guard let index = state.function(atRow: row) else { return }
        state.chooseCallPlace(atRow: row)
        guard index != state.function else {
            setShowsOnlyOpenWay(true)
            return
        }
        Self.defaults.set(true, forKey: Self.onlyOpenWayKey)
        state.showOnlyOpenWay(true)
        drawCallTreeButton()
        jump { selectFunction(at: index) }
    }

    /// The call tree's button says which form the tree is in, and what another
    /// press does: its symbol and its words go with the form.
    private func drawCallTreeButton() {
        guard orderButtonViews.indices.contains(FunctionOrder.calls.rawValue) else { return }
        let button = orderButtonViews[FunctionOrder.calls.rawValue]
        let only = state.showsOnlyOpenWay
        button.image = NSImage(systemSymbolName: only ? "point.topleft.down.curvedto.point.bottomright.up"
                                                      : Self.orderSymbol(.calls),
                               accessibilityDescription: nil)
        // help: panel.code.function-view
        ControlHelp.describe(button, name: L("Call tree"), tooltip: only
            ? L("Show the way down to the open function alone and what it calls. Press again for every way")
            : L("Show every way down to the selected function and what it calls. Press again for the open way alone"))
    }

    /// Gives the button whose layout is in front the accent colour and takes
    /// it from the others.
    private func markChosenOrder(_ order: FunctionOrder) {
        for (index, button) in orderButtonViews.enumerated() {
            button.isChosen = index == order.rawValue
        }
    }

    private static func orderSymbol(_ order: FunctionOrder) -> String {
        switch order {
        case .address: "list.number"
        case .calls: "arrow.triangle.branch"
        case .review: "tag"
        }
    }

    /// A function's mark by its review: full, and every level without a
    /// mark of its own, the filled `f`; partial, the `f` in a frame;
    /// decompiler only, the same framed `f` in red — the review has not gone
    /// past the decompiler; no body, the framed `f` in grey; a library
    /// function, which the library registry holds, the badge of whose library it is.
    static func functionMark(_ group: FunctionGroup, library: LibrarySection? = nil) -> String {
        switch group {
        case .partial: "function.partial"
        case .decompiled: "function.decompiled"
        case .noBody: "function.noBody"
        case .library: "library.\(library ?? .unrecorded).entry"
        default: "function"
        }
    }

    /// What the library registry says of a function, for its hover and the
    /// header's mark; nil for a function of the module.
    static func registryDetail(_ function: CodeArtifact.Function) -> String? {
        guard let entry = function.libraryEntry else { return nil }
        var line = L("Shared library function. Stored in the library registry, entry version %1$@", String(entry.version))
        if !entry.codes.isEmpty {
            line += "\n" + L("A variant: assert codes %1$@", entry.codes.joined(separator: ", "))
        }
        return line
    }

    /// A library kind's heading inside Library functions.
    static func title(of section: LibrarySection) -> String {
        switch section {
        case .edk2: L("EDK2")
        case .amd: L("AMD AGESA")
        case .intel: L("Intel FSP/RC")
        case .ite: L("ITE EC library")
        case .toolchain: L("Compiler runtime")
        case .unrecorded: L("Kind not recorded")
        }
    }

    /// The short name on a library function's badge.
    static func badge(of section: LibrarySection) -> String {
        switch section {
        case .edk2: L("EDK2")
        case .amd: L("AMD")
        case .intel: L("Intel")
        case .ite: L("ITE")
        case .toolchain: L("RT")
        case .unrecorded: L("LIB")
        }
    }

    /// A heading of the grouped order.
    static func title(of group: FunctionGroup) -> String {
        switch group {
        case .full: L("Fully reviewed")
        case .partial: L("Partly reviewed")
        case .decompiled: L("Decompiler only")
        case .library: L("Library functions")
        case .noBody: L("No body")
        case .unknown: L("Review level not recorded")
        }
    }

    /// A function's review level and what still keeps it from full, for the
    /// hover of its row in the grouped order: one short line, the level and
    /// the gaps where there are any.
    static func reviewDetail(_ function: CodeArtifact.Function) -> String {
        let level: String
        switch function.reviewLevel {
        case .full: level = L("fully reviewed")
        case .partial: level = L("partly reviewed")
        case .decompiled: level = L("decompiler only")
        case .library:
            let section: LibrarySection = switch function.libraryKind {
            case .edk2: .edk2
            case .amd: .amd
            case .intel: .intel
            case .ite: .ite
            case .toolchain: .toolchain
            case nil: .unrecorded
            }
            level = L("library function: %1$@", title(of: section))
        case .noBody: level = L("no body")
        case nil: level = L("review level not recorded")
        }
        let gaps = function.reviewGaps.compactMap { gap -> String? in
            switch gap {
            case "name": L("the name is a placeholder")
            case "plate": L("missing plate comment")
            case "comments": L("missing step comments")
            case "params": L("unnamed parameters")
            case "locals": L("unnamed locals")
            case "c": L("did not decompile")
            default: nil
            }
        }
        guard !gaps.isEmpty else {
            return L("Review: %1$@", level)
        }
        return L("Review: %1$@ — %2$@", level, gaps.joined(separator: ", "))
    }

    /// Takes the panel from `previous` — the artifact it showed before a new
    /// revision of the same reading arrived. The functions that revision added,
    /// renamed, re-signed or decompiled differently read bold, with a **New**
    /// badge, until the reader has opened one and moved off it; the artifact
    /// itself is kept, because it is what Diff shows the code against.
    public func markRevisionChange(from previous: CodeArtifact, revision: Int? = nil) {
        // An artifact shown from its index tells what changed, not what it
        // was: that code is read from the revision when it is asked for.
        let code = previous.functions.contains(where: \.codeIsPending) ? nil : previous
        revisionBaseline = code
        revisionCount += 1
        drawnDiff = nil
        previousRevision = code.flatMap { code in revision.map { ($0, code) } }
        var before: [CodeAddress: CodeArtifact.Function] = [:]
        for function in previous.functions where before[function.entry] == nil {
            before[function.entry] = function
        }
        var changed: Set<Int> = []
        for (index, function) in artifact.functions.enumerated() {
            guard let old = before[function.entry] else {
                changed.insert(index)
                continue
            }
            if old.readingFingerprint != function.readingFingerprint
                || Self.changedUnseen(old, function, before: previous, after: artifact) {
                changed.insert(index)
            }
        }
        // With the marks switched off a revision marks nothing; the pane drawn
        // for it records everything as seen (`restoreSeen`).
        for index in changed where unopenedChanges[index] == nil && CodeRevisionSeen.tracksNewMarks {
            unopenedChanges[index] = NewMark.Baseline(revision: revision, artifact: code)
            // New again: the comparison it was left with is about an older change.
            functionComparisons[artifact.functions[index].entry] = nil
        }
        marksChanged()
        // The rows changed, not the reader's place: reloading the table must
        // not be taken for a click on a row, which would open one.
        syncingSelection = true
        functionTable.reloadData()
        syncingSelection = false
        drawSelection()
    }

    /// Opens or closes one place's calls in the tree.
    func toggleCalls(at path: [Int]) {
        foldRows { $0.toggleExpanded(path: path) }
        if let row = state.row(ofCallPath: path) {
            describeDisclosure(at: row, state.isExpanded(path: path) ? L("Hide calls") : L("Show calls"))
        }
    }

    /// The places open in the call tree, for the pane drawn after this one.
    public var openCallEntries: [[CodeAddress]] { state.openCallEntries }

    /// Opens what the pane before this one had open: a new revision draws a new
    /// pane, and the tree must not close under the reader each time.
    public func openCallPlaces(_ places: [[CodeAddress]]) {
        guard !places.isEmpty else { return }
        state.openCallPlaces(places)
        drawNavigator()
    }

    /// Opens or closes rows of the Functions list as `change` has the state
    /// do: the rows that come slide in under the one clicked, the rows that
    /// go slide up into it, and every other row keeps its cell — the chevron
    /// clicked is turning still. A change the rows cannot follow one by one
    /// draws the list again.
    func foldRows(_ change: (inout CodeReaderState) -> Void) {
        // A function has a row at each of its places, so a row is told from
        // another by its place: the rows that come and go are those of the
        // place clicked, not the first that look the same.
        struct Place: Equatable {
            let row: CodeReaderState.FunctionRow
            let path: [Int]?
        }
        func rows() -> [Place] {
            (0..<state.rowCount).compactMap { row in
                state.functionRow(at: row).map { Place(row: $0, path: state.callPath(atRow: row)) }
            }
        }
        let before = state.list == .functions ? rows() : []
        change(&state)
        guard state.list == .functions, before.count == functionTable.numberOfRows else {
            drawNavigator()
            return
        }
        let difference = rows().difference(from: before)
        var removed = IndexSet(), inserted = IndexSet()
        for step in difference {
            switch step {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        syncingSelection = true
        // The table animates the rows itself. Not inside an animation group
        // that allows implicit animation: a row view the insert makes starts
        // at the table's origin, and would fly down from the top to its row.
        functionTable.beginUpdates()
        functionTable.removeRows(at: removed, withAnimation: [.slideUp, .effectFade])
        functionTable.insertRows(at: inserted, withAnimation: [.slideDown, .effectFade])
        functionTable.endUpdates()
        // The function the reader is in keeps its row where the list still
        // shows it.
        if !state.selectedFunctionRows.isEmpty {
            functionTable.selectRowIndexes(state.selectedFunctionRows, byExtendingSelection: false)
        }
        syncingSelection = false
        // The rows that stayed keep their views: the open place may have moved.
        functionTable.enumerateAvailableRowViews { rowView, row in
            (rowView as? CodeNavigatorRowView)?.isOpenPlace = state.isOpenPlace(atRow: row)
        }
        drawEmptyList()
    }

    /// The words of the chevron on `row` after it turned: it is not drawn
    /// again, so it does not take them from the row.
    func describeDisclosure(at row: Int, _ phrase: String) {
        guard row < functionTable.numberOfRows,
              let cell = functionTable.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? CodeNavigatorCell else { return }
        ControlHelp.describe(cell.disclosure, phrase)
    }

    /// A function a revision changed and the reader has not looked at yet:
    /// its entry, and the revision it was new against with that revision's
    /// code — nil revision when the app could not name one.
    /// What a function is compared with, once it has been settled for it.
    public enum FunctionComparison {
        /// The reader reset the comparison for this function.
        case noComparison
        case against(NewMark.Baseline)
    }

    public struct NewMark {
        public struct Baseline {
            public let revision: Int?
            /// The code it is new against, when the mark came with it: nil
            /// names `revision` in the store, read when it is first needed.
            public let artifact: CodeArtifact?
            /// The one function `artifact` holds the code of, when it was read
            /// for that function alone: no other function can be compared with it.
            public let readFor: CodeAddress?

            public init(revision: Int?, artifact: CodeArtifact?, readFor: CodeAddress? = nil) {
                self.revision = revision
                self.artifact = artifact
                self.readFor = readFor
            }
        }

        public let entry: CodeAddress
        public let baseline: Baseline

        public init(entry: CodeAddress, baseline: Baseline) {
            self.entry = entry
            self.baseline = baseline
        }
    }

    /// What the pane calls when its marks change — a revision's, a function
    /// left, marks carried in — so the app can keep them for the next launch.
    public var onNewMarksChanged: (([NewMark]) -> Void)?

    /// The marks the reader has not taken yet, by the functions they name:
    /// what the app carries into the pane drawn after the next revision, so a
    /// change the reader has not looked at is not lost to the one after it.
    public var newMarks: [NewMark] {
        unopenedChanges.compactMap { index, baseline in
            guard model.functions.indices.contains(index) else { return nil }
            return NewMark(entry: model.functions[index].entry, baseline: baseline)
        }
    }

    /// Takes the marks of the pane before this one. A function still here
    /// keeps the earliest revision it is new against, whichever pane marked
    /// it: a change the reader has not looked at since then is the change the
    /// mark is about, even when the revisions after it changed the function
    /// again.
    public func setNewMarks(_ marks: [NewMark]) {
        // Switched off, a mark carried from before is not put up.
        guard CodeRevisionSeen.tracksNewMarks else { return }
        var byEntry: [CodeAddress: Int] = [:]
        for (index, function) in model.functions.enumerated() where byEntry[function.entry] == nil {
            byEntry[function.entry] = index
        }
        for mark in marks {
            guard let index = byEntry[mark.entry] else { continue }
            // Changed and changed back: the revision the mark began at reads
            // as the code does now, and there is nothing to show against it.
            if let baseline = mark.baseline.artifact,
               Self.holdsTheSame(artifact.functions[index], in: baseline, now: artifact) { continue }
            if let existing = unopenedChanges[index] {
                switch (mark.baseline.revision, existing.revision) {
                case let (carried?, current?) where carried >= current:
                    continue
                case (nil, _?):
                    continue
                default:
                    break
                }
            }
            unopenedChanges[index] = mark.baseline
        }
        syncingSelection = true
        functionTable.reloadData()
        syncingSelection = false
        drawSelection()
        marksChanged()
    }

    /// The marks changed: the button that takes them follows, and the app keeps
    /// them for the next launch.
    func marksChanged() {
        clearNewMarksButton.isEnabled = !unopenedChanges.isEmpty || descriptionMark != nil
        drawDescriptionBadge()
        onNewMarksChanged?(newMarks)
    }

    @objc private func clearNewMarksChosen() { clearNewMarks() }

    /// Takes the New mark off every function, as leaving each of them would:
    /// what they changed counts as read, so the next launch does not put it up
    /// again. The open function has been opened, so it keeps its comparison as
    /// any function left does. Whatever the revision picker holds stays
    /// comparable.
    public func clearNewMarks() {
        guard !unopenedChanges.isEmpty || descriptionMark != nil else { return }
        if let index = state.function, let mark = unopenedChanges[index] {
            keepComparison(of: index, from: mark)
        }
        unopenedChanges.removeAll()
        if let mark = descriptionMark {
            if showsDescription, descriptionChoice == nil { descriptionChoice = .against(mark) }
            descriptionMark = nil
        }
        if let revision = manifest.reading?.rev {
            seen = allSeenRecords(revision: revision)
            // The last launch's records may still be on their way: they must
            // not put the marks up again when they come.
            marksWereCleared = true
            if seenLoaded { onSeenChanged?(seen) }
        }
        syncingSelection = true
        functionTable.reloadData()
        syncingSelection = false
        if let index = state.function { applyOpenComparison(for: index) }
        drawSelection()
        marksChanged()
    }

    /// Whether the reader has cleared the marks in this pane.
    private var marksWereCleared = false

    /// Settings switched the New marks on or off. Off takes every mark in the
    /// pane as the bar's button does — what they were about counts as read —
    /// and records every function and the description as seen at the revision
    /// on screen, so nothing is left to put up when the marks come back. On
    /// puts nothing up: the marks start from the next revision that changes
    /// something.
    private func newMarkTrackingChanged() {
        guard !CodeRevisionSeen.tracksNewMarks else { return }
        unrecorded = []
        revisionsToSettle = []
        if !unopenedChanges.isEmpty || descriptionMark != nil {
            clearNewMarks()
        } else if let revision = manifest.reading?.rev {
            seen = allSeenRecords(revision: revision)
            marksWereCleared = true
            if seenLoaded { onSeenChanged?(seen) }
        }
        updateNewMarkBanner()
    }

    /// The functions a revision the panel received changed that the reader has
    /// not yet left: they read bold, with a **New** badge, while they are open
    /// and until the reader moves to another function. Each keeps the revision
    /// it was new against and that revision's code, so opening it compares
    /// with the change the mark is about, not with whatever came after; a later
    /// revision adds marks and never takes one, so changes the reader has not
    /// looked at yet do not go unnoticed.
    var unopenedChanges: [Int: NewMark.Baseline] = [:]

    /// For every function, the revision the reader last saw it at and the code
    /// it had then — kept between launches, so a revision that arrived while
    /// the app was closed still puts the functions it changed up as New.
    var seen: [String: SeenRecord] = [:]

    /// What the panel keeps between launches, through the app: the records as
    /// they change — a function opened, a module first read, unchanged
    /// functions moved on with the revision on screen.
    public var onSeenChanged: (([String: SeenRecord]) -> Void)?

    /// Whether the records the last launch kept have been given to the pane.
    /// A note taken before that is not written over the store: the pane's
    /// own opening is noted while the records are still on their way, and
    /// saving then would erase the launch before it — the New marks with it.
    var seenLoaded = false

    /// The records as they stand, for a test.
    public var seenRecords: [String: SeenRecord] { seen }

    /// Takes what the last launch left: every function that reads otherwise
    /// than it did when the reader last saw it goes up as New against the
    /// revision it was seen at. The record says so without the code of that
    /// revision, so the marks are up at once; the code is read when a function
    /// is opened. A function still reading the same is that much further seen;
    /// one the records never had is new against the newest kept revision that
    /// does not read as it does now, and one that reads the same in all of them
    /// is not new at all — that does take the code, and is finished through
    /// `nextRevisionToSettle`. A module the records know nothing of is seeded as
    /// seen now — a first open has nothing to be new against.
    ///
    /// `baselines` is the code already in hand, `available` the revisions the
    /// store holds code for, those included; the others cannot be compared, and
    /// their functions wait unseen.
    public func restoreSeen(_ records: [String: SeenRecord],
                            baselines: [Int: CodeArtifact],
                            available: Set<Int>? = nil) {
        guard let revision = manifest.reading?.rev else { return }
        seenLoaded = true
        // Switched off, the pane is read as a first open: everything on screen
        // counts as seen at this revision, and is recorded so — the marks start
        // again from here when they are switched back on.
        guard !records.isEmpty, !marksWereCleared, CodeRevisionSeen.tracksNewMarks else {
            seen = allSeenRecords(revision: revision)
            onSeenChanged?(seen)
            return
        }
        seen = records
        // The description is new as a function is: it reads otherwise than
        // when the reader last had it open. A record from before it was
        // recorded at all has nothing to be new against.
        let description = descriptionFingerprint
        if let record = records[Self.descriptionSeenKey], record.fingerprint != description,
           record.revision != revision, !description.isEmpty {
            descriptionMark = record.revision
            if showsDescription { applyDescriptionComparison() }
            marksChanged()
        } else {
            seen[Self.descriptionSeenKey] = SeenRecord(revision: revision, fingerprint: description)
        }
        let holds = available ?? Set(baselines.keys)
        var marks: [NewMark] = []
        unrecorded = []
        for (index, function) in artifact.functions.enumerated() {
            let key = function.entry.description
            let fingerprint = Self.fingerprint(of: function)
            guard let record = records[key] else {
                // Never opened: the review made it after the records began.
                unrecorded.append(index)
                continue
            }
            if record.fingerprint == fingerprint {
                seen[key] = SeenRecord(revision: revision, fingerprint: fingerprint)
            } else if let baseline = baselines[record.revision],
                      Self.holdsTheSame(function, in: baseline, now: artifact) {
                // The record was made against another copy of that revision:
                // the store's code for it is the code on screen. Nothing
                // changed, so a mark would be about the bookkeeping and not
                // about the function; the reader is as far along as the code.
                seen[key] = SeenRecord(revision: revision, fingerprint: fingerprint)
            } else if holds.contains(record.revision) {
                // The record stays where it is: the change is not seen until
                // the reader opens the function.
                marks.append(NewMark(entry: function.entry,
                                     baseline: .init(revision: record.revision,
                                                     artifact: baselines[record.revision])))
            }
        }
        if !marks.isEmpty { setNewMarks(marks) }
        revisionsToSettle = holds.sorted(by: >)
        if unrecorded.isEmpty { revisionsToSettle = [] }
        while let next = nextRevisionToSettle, let baseline = baselines[next] {
            settleUnrecorded(revision: next, artifact: baseline, keeping: false)
        }
        // The function on screen is not a reader's choice — the pane opens on
        // one of its own — so nothing is seen yet; a mark it carries still
        // puts its comparison up, as opening it would.
        if let index = state.function { applyOpenComparison(for: index) }
        onSeenChanged?(seen)
    }

    /// The functions the records never had, and the revisions still to look
    /// for them in, newest first.
    private var unrecorded: [Int] = []
    private var revisionsToSettle: [Int] = []

    /// The revision whose code the functions with no record are waiting for;
    /// nil when none are. The app reads it and hands it to `settleUnrecorded`.
    public var nextRevisionToSettle: Int? { unrecorded.isEmpty ? nil : revisionsToSettle.first }

    /// The one function that revision is read for, when only one has no record;
    /// nil when it takes the code of several.
    public var functionToSettle: CodeAddress? {
        unrecorded.count == 1 ? artifact.functions[unrecorded[0]].entry : nil
    }

    /// Compares the functions with no record against `revision`, the newest not
    /// yet looked at: a function that reads otherwise is new against it, with a
    /// record of what it read then, or the next pane — the panel opened in a tab,
    /// the next launch — would look only at the revisions the others' records
    /// name, which by then are this one. A function reading the same everywhere
    /// is seen. Nil is a revision the store could not give.
    public func settleUnrecorded(revision: Int, artifact read: CodeArtifact?) {
        settleUnrecorded(revision: revision, artifact: read, keeping: true)
    }

    private func settleUnrecorded(revision: Int, artifact read: CodeArtifact?, keeping: Bool) {
        revisionsToSettle.removeAll { $0 == revision }
        let readFor = functionToSettle
        var marks: [NewMark] = []
        if let read {
            var old: [CodeAddress: CodeArtifact.Function] = [:]
            for function in read.functions where old[function.entry] == nil { old[function.entry] = function }
            unrecorded.removeAll { index in
                let function = artifact.functions[index]
                let then = old[function.entry]
                if let then, then.readingFingerprint == function.readingFingerprint { return false }
                marks.append(NewMark(entry: function.entry,
                                     baseline: .init(revision: revision, artifact: read, readFor: readFor)))
                seen[function.entry.description] = SeenRecord(revision: revision,
                                                              fingerprint: then.map(Self.fingerprint) ?? "")
                return true
            }
        }
        if revisionsToSettle.isEmpty, read != nil, let current = manifest.reading?.rev {
            for index in unrecorded {
                let function = artifact.functions[index]
                seen[function.entry.description] = SeenRecord(revision: current,
                                                              fingerprint: Self.fingerprint(of: function))
            }
            unrecorded = []
        }
        if !marks.isEmpty { setNewMarks(marks) }
        guard keeping else { return }
        if let index = state.function { applyOpenComparison(for: index) }
        updateNewMarkBanner()
        onSeenChanged?(seen)
    }

    /// Whether `revision` holds `function` as it reads now: the name, the
    /// signature and the C the New mark is about, and nothing the C does not
    /// show changed either. A mark against such a revision would have nothing
    /// to compare and nothing to explain. `now` is the artifact `function` is of.
    static func holdsTheSame(_ function: CodeArtifact.Function, in revision: CodeArtifact,
                                     now: CodeArtifact) -> Bool {
        guard let old = revision.functions.first(where: { $0.entry == function.entry }) else { return false }
        return old.readingFingerprint == function.readingFingerprint
            && !changedUnseen(old, function, before: revision, after: now)
    }

    /// Whether the function changed in a way its C does not show — a comment
    /// the decompiler does not print, the registry link, a constant's
    /// meaning — so that it is New although it reads the same. Only when both
    /// sides have their code at hand: an index entry says nothing of these.
    private static func changedUnseen(_ old: CodeArtifact.Function, _ new: CodeArtifact.Function,
                                      before: CodeArtifact, after: CodeArtifact) -> Bool {
        guard !old.codeIsPending, !new.codeIsPending else { return false }
        return NewMarkChange.between(old: old, new: new,
                                     oldEquates: before.equates, newEquates: after.equates)
            .contains(where: \.marksNew)
    }

    static func seenRecords(of artifact: CodeArtifact, revision: Int) -> [String: SeenRecord] {
        var records: [String: SeenRecord] = [:]
        for function in artifact.functions {
            records[function.entry.description] = SeenRecord(
                revision: revision, fingerprint: fingerprint(of: function))
        }
        return records
    }

    static func fingerprint(of function: CodeArtifact.Function) -> String {
        function.readingFingerprint
    }

    /// Notes that the reader has the function in front of them now: the next
    /// launch must not put it up as New for what they have just read.
    func noteSeen(_ index: Int) {
        guard artifact.functions.indices.contains(index),
              let revision = manifest.reading?.rev else { return }
        let function = artifact.functions[index]
        seen[function.entry.description] = SeenRecord(
            revision: revision, fingerprint: Self.fingerprint(of: function))
        guard seenLoaded else { return }
        onSeenChanged?(seen)
    }
    /// The function's row, its listing, the selected instruction, its C and
    /// its callers and callees. The listing is reloaded only when the function
    /// changed; a new instruction in the same function only moves the row.
    private var drawnFunction: Int?

    func drawSelection() {
        syncingSelection = true
        if state.list == .functions, let function = state.function,
           let row = state.row(ofFunction: function),
           functionTable.selectedRowIndexes != state.selectedFunctionRows {
            functionTable.selectRowIndexes(state.selectedFunctionRows, byExtendingSelection: false)
            functionTable.scrollRowToVisible(row)
        }
        if drawnFunction != state.function || table.numberOfRows != state.lines.count {
            drawnFunction = state.function
            table.reloadData()
        }
        if let row = state.selectedRow {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        syncingSelection = false
        updateC()
        if wantsRevisionDiff { refreshDiffVisibility() }
        updateNewMarkBanner()
        updateReferences()
        readSelectedFunction()
    }

    // MARK: - Code read as it is shown

    /// Whether the listing has no instruction at `address`.
    public func holdsNoInstruction(at address: CodeAddress) -> Bool { model.line(at: address) == nil }

    /// Whether the function `address` lies in has still not been read.
    public func isWaitingForCode(at address: CodeAddress) -> Bool { model.pendingFunction(holding: address) != nil }

    /// Returns once the function holding `location` has its code, or its read
    /// has failed: for a caller that says what stands at the place.
    public func readCode(at location: CodeLocation) async {
        guard let function = model.indices(of: location).function, model.isPending(function),
              onLoadFunctions != nil else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            whenRead([function], otherwise: { done.resume() }, { done.resume() })
        }
    }

    /// Reads the function on screen when its code is not here yet. One whose
    /// read failed is asked for again when the reader comes back to it.
    private func readSelectedFunction() {
        guard let index = state.function, model.isPending(index) else { return }
        if lastFunctionAsked != index {
            lastFunctionAsked = index
            functionsNotRead.remove(index)
        }
        guard !functionsBeingRead.contains(index), !functionsNotRead.contains(index) else { return }
        whenRead([index]) {}
    }

    /// Runs `then` once these functions' code is here, or every function's for
    /// nil: at once when it is, and not at all when it cannot be read. What
    /// needs the code of all of them asks only when the reader asks for it.
    @discardableResult
    func whenRead(_ functions: Set<Int>?, quietly: Bool = false,
                  otherwise: (@MainActor () -> Void)? = nil,
                  _ then: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        let wanted = (functions ?? model.pendingFunctions).intersection(model.pendingFunctions)
        guard !wanted.isEmpty else {
            then()
            return nil
        }
        waitingForFunctions.append((wanted, then, otherwise))
        guard let onLoadFunctions else { return nil }
        let toRead = wanted.subtracting(functionsBeingRead)
        guard !toRead.isEmpty else { return nil }
        functionsBeingRead.formUnion(toRead)
        let entries = functions == nil && toRead == model.pendingFunctions
            ? nil : Set(toRead.map { model.functions[$0].entry })
        let work = beginWork(entries == nil ? L("Reading all functions…") : L("Reading the function…"))
        let generation = readingGeneration
        return Task { @MainActor [weak self] in
            let read = await onLoadFunctions(entries)
            guard let self else { return }
            self.endWork(work)
            // Read for the artifact before: its functions are not this one's.
            guard self.readingGeneration == generation else { return }
            self.functionsBeingRead.subtract(toRead)
            if let read {
                self.state.load(read)
                self.artifact = self.state.model.artifact
            }
            let missing = toRead.intersection(self.model.pendingFunctions)
            self.functionsNotRead.formUnion(missing)
            // The function on screen says so itself.
            if !missing.isEmpty, !quietly, self.state.function.map({ !missing.contains($0) }) ?? true {
                NSSound.beep()
            }
            self.indexNotes()
            if !self.searchField.stringValue.isEmpty { self.drawNavigator() }
            if let shown = self.state.function, toRead.contains(shown) {
                self.drawnC = nil
                self.drawnFunction = nil
                self.drawnDiff = nil
                self.drawSelection()
            }
            let waiting = self.waitingForFunctions
            self.waitingForFunctions = waiting.filter { !$0.wanted.isDisjoint(with: self.functionsBeingRead) }
            for waiter in waiting where waiter.wanted.isDisjoint(with: self.functionsBeingRead) {
                if waiter.wanted.isDisjoint(with: self.model.pendingFunctions) {
                    waiter.then()
                } else {
                    waiter.otherwise?()
                }
            }
        }
    }

    // help: panel.code.new
    /// Says why the function on screen wears New, in the plate over the code:
    /// every change the comparison of the C cannot show (`NewMarkChange`) —
    /// a comment the decompiler does not print, the registry link, a
    /// constant's meaning — or a function this revision added; and, the code
    /// reading the same in both revisions, that the comparison has nothing to
    /// draw. A change the C shows — a rename, a type in a declaration — is
    /// the comparison's: a function with only such changes needs no plate.
    func updateNewMarkBanner() {
        guard mode != Self.descriptionSegment,
              let index = state.function, model.functions.indices.contains(index),
              let mark = unopenedChanges[index] else {
            newMarkBanner.hide()
            layOutBanner(false)
            return
        }
        let function = model.functions[index]
        let before = mark.revision.map { "r\($0)" }
        // Its code is on the way when neither has it: the plate comes with it.
        let read = mark.revision.flatMap { readRevisions[RevisionRead(revision: $0, function: function.entry)] }
        guard let baseline = mark.artifact ?? read else {
            newMarkBanner.hide()
            layOutBanner(false)
            return
        }
        // Said once the function's code is here.
        guard !function.codeIsPending else {
            layOutBanner(false)
            return
        }
        let old = baseline.functions.first { $0.entry == function.entry }
        var bullets: [String] = []
        if let old {
            // Only what the comparison cannot show: a rename or a changed
            // declaration is in the C, and the diff draws it.
            let changes = NewMarkChange.between(old: old, new: function,
                                                oldEquates: baseline.equates, newEquates: artifact.equates,
                                                oldTypes: baseline.types, newTypes: artifact.types)
            bullets = changes.map(\.bullet)
            // With nothing to draw, the reader is told not to look for it.
            if old.c == function.c, old.c != nil, !bullets.isEmpty {
                bullets.append(L("The code reads the same in both revisions, so the comparison has nothing to show."))
            }
        } else if let before {
            bullets.append(L("The function is not in %1$@: this revision added it.", before))
        }
        guard !bullets.isEmpty else {
            newMarkBanner.hide()
            layOutBanner(false)
            return
        }
        layOutBanner(true)
        newMarkBanner.show(title: mark.revision.map { L("New against %1$@", "r\($0)") }
                                ?? L("New against the revision before"),
                           lines: bullets)
    }

    /// Whether the plate over the code is up: why the selected function
    /// wears New, when the comparison cannot say it.
    public var newBannerIsShown: Bool { !newMarkBanner.isHidden }

    /// Puts the plate up, with the pages under it, or takes it away and gives
    /// them the whole area — the plate is not a hidden view in the stack, so
    /// nothing is left of it when it is down.
    private func layOutBanner(_ shows: Bool) {
        guard shows != bannerIsUp else { return }
        bannerIsUp = shows
        NSLayoutConstraint.deactivate(shows ? pageTops : belowBannerTops)
        NSLayoutConstraint.activate(shows ? belowBannerTops : pageTops)
        newMarkBanner.isHidden = !shows
    }

    /// The plate's words, for a test.
    var newBannerTitle: String { newMarkBanner.titleShown }
    var newBannerBullets: [String] { newMarkBanner.bulletsShown }
    var newBannerWordsAreSelectable: Bool { newMarkBanner.wordsAreSelectable }
    var newBannerWordFontPoints: [CGFloat] { newMarkBanner.wordFontPoints }

    // help: panel.code.lists
    /// Says why a list has no rows: the search, or what the analysis looks
    /// for. Status is the list that is most often empty — the analysis finds
    /// `ReportStatusCode` calls only through the 32-bit PEI services table.
    private func drawEmptyList() {
        emptyListLabel.font = Self.navigatorFont()
        emptyListLabel.isHidden = state.rowCount > 0 || showsNavigatorTab
        // An empty list shows no table: its column headers over nothing ran
        // into the sentence that stands in for the rows.
        functionScroll.isHidden = state.rowCount == 0 || showsNavigatorTab
        guard state.rowCount == 0 else { return }
        if !state.searchText.isEmpty {
            emptyListLabel.stringValue = L("Nothing matches the search.")
        } else if state.list == .statusCodes {
            emptyListLabel.stringValue = L("No ReportStatusCode calls found. The analysis looks for them in 32-bit PEI modules, which call it through the PEI services table.")
        } else {
            emptyListLabel.stringValue = L("The analysis found none in this module.")
        }
    }

    @objc private func listChanged() {
        let index = listControl.selectedSegment
        guard navigatorTabs.indices.contains(index) else { return }
        switch navigatorTabs[index] {
        case .search:
            showSearchTab(true)
        case .interfaces:
            showInterfacesTab(true)
        case let .record(id, _, _):
            showRecordSection(id)
        case let .list(list):
            showSearchTab(false)
            showInterfacesTab(false)
            showRecordSection(nil)
            selectList(list)
        }
    }

    /// The segment of `tab` in the switch, nil when the profile leaves it out.
    func segment(of tab: CodeNavigatorTab) -> Int? {
        navigatorTabs.firstIndex(of: tab)
    }

    /// The segment of a record section's tab.
    private func segment(ofRecord id: String) -> Int? {
        navigatorTabs.firstIndex {
            if case let .record(recordID, _, _) = $0 { return recordID == id }
            return false
        }
    }

    /// The segment of the tab in front, -1 when its tab is not in the switch.
    private var shownSegment: Int {
        let segment: Int? = if showsSearchTab {
            segment(of: .search)
        } else if showsInterfacesTab {
            segment(of: .interfaces)
        } else if let shownRecordSection {
            segment(ofRecord: shownRecordSection)
        } else {
            segment(of: .list(state.list))
        }
        return segment ?? -1
    }

    /// The words of the switch's segments: a list's name, and nothing for a
    /// tab drawn as a glyph.
    private static func segmentLabels(_ tabs: [CodeNavigatorTab]) -> [String] {
        tabs.map { tab in
            switch tab {
            case .list(.functions): L("Functions")
            case .list(.strings): L("Strings")
            case .list(.postCodes): L("POST")
            case .list(.statusCodes): L("Status")
            case let .record(id, _, _): CodeRecordSection.tabWord(of: id) ?? ""
            case .interfaces, .search: ""
            }
        }
    }

    /// Gives the switch one segment per tab, each with its word or its glyph
    /// and what it says it is.
    private func configureListSegments() {
        let labels = Self.segmentLabels(navigatorTabs)
        listControl.segmentCount = labels.count
        for (segment, tab) in navigatorTabs.enumerated() {
            listControl.setLabel(labels[segment], forSegment: segment)
            listControl.setImage(nil, forSegment: segment)
            listControl.setToolTip(nil, forSegment: segment)
            switch tab {
            case .list:
                break
            case .search:
                // help: panel.code.search-all
                // The Search tab is a glyph, not a word: the four lists keep
                // their room, and the magnifier says what it is in every
                // language.
                listControl.setImage(NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil),
                                     forSegment: segment)
                ControlHelp.describe(listControl, segment: segment, L("Find in All Functions"))
            case .interfaces:
                // help: panel.code.interfaces
                listControl.setImage(NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil),
                                     forSegment: segment)
                ControlHelp.describe(listControl, segment: segment, name: L("Interfaces"),
                                     tooltip: L("Interfaces: what the module installs, looks up and is notified of"))
            case let .record(id, title, symbol):
                // help: panel.code.record-sections
                // A record's tab is a short word, as the lists are; the
                // profile's glyph only for a record the app has no word for.
                if labels[segment].isEmpty {
                    listControl.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                                         forSegment: segment)
                }
                ControlHelp.describe(listControl, segment: segment,
                                     CodeRecordSection.title(of: id, fallback: title))
            }
        }
        listControl.selectedSegment = shownSegment
    }

    /// Whether the module's profile gives the navigator record sections:
    /// only then has the review document rows worth reading.
    public var hasRecordSections: Bool {
        navigatorTabs.contains { if case .record = $0 { true } else { false } }
    }

    /// The records of the revision on screen, read from its review document:
    /// the rows of each record section. The app reads them after the pane
    /// is made, as it does the description; until then the sections show the
    /// manifest's statuses.
    public func setModuleRecords(_ records: ModuleRecords?) {
        guard hasRecordSections || records == nil else { return }
        recordPanel.setRecords(records, statuses: manifest.reading?.records,
                               profile: AnalysisProfile.derive(for: manifest.module))
    }

    /// Puts a record section's tab in front of the lists — nil puts the lists
    /// back.
    public func showRecordSection(_ id: String?) {
        if let id {
            guard case let .record(_, title, _)? = segment(ofRecord: id).map({ navigatorTabs[$0] }) else { return }
            if showsSearchTab { showsSearchTab = false; searchPanel.isHidden = true }
            if showsInterfacesTab { showsInterfacesTab = false; interfacesPanel.isHidden = true }
            recordPanel.show(id: id, fallbackTitle: title, font: Self.navigatorFont())
        }
        shownRecordSection = id
        recordPanel.isHidden = id == nil
        drawListSwitch()
    }

    /// Puts the Interfaces tab in front of the lists, or the lists back.
    public func showInterfacesTab(_ shows: Bool) {
        if shows, showsSearchTab {
            showsSearchTab = false
            searchPanel.isHidden = true
        }
        if shows, shownRecordSection != nil {
            shownRecordSection = nil
            recordPanel.isHidden = true
        }
        showsInterfacesTab = shows
        interfacesPanel.isHidden = !shows
        if shows { drawInterfaces() }
        drawListSwitch()
    }

    /// The module's dependency expression, from its firmware file in the
    /// dump, the GUIDs named: "" when the file has none, nil when the panel
    /// was not opened from a firmware tree. The tab shows it before the
    /// review's lists, as the module's (i) in the UEFI tree once did.
    public var dependencies: DependencyOutline? {
        didSet { if dependencies != oldValue { drawInterfaces() } }
    }

    /// The GUID registry of the store the code comes from: the tab names
    /// every GUID as it does, over what a review wrote and over the
    /// catalogue's name in the dependency expression.
    public var guidRegistry = GuidRegistry() {
        didSet { if guidRegistry != oldValue { drawInterfaces() } }
    }

    /// The record of the module's review, drawn in the tab.
    func drawInterfaces() {
        var unplaced = false
        interfacesPanel.show(manifest.reading?.interfaces?.named(by: guidRegistry),
                             dependencies: dependencies?.named(by: guidRegistry),
                             registry: guidRegistry) { [weak self] recorded in
            guard let self else { return nil }
            let address = self.interfaceInstruction(for: recorded)
            let place = self.model.indices(of: CodeLocation(address: address))
            if place.function == nil, self.model.function(at: address) == nil { unplaced = true }
            guard let function = place.function ?? self.model.function(at: address) else { return nil }
            let entry = self.model.functions[function].entry
            let name = self.navigatorName(of: function)
            return address == entry ? name : "\(name) + 0x\(String(address.value - entry.value, radix: 16, uppercase: true))"
        }
        // A descriptor's use may lie in code not read yet: read it, quietly,
        // and draw the places again.
        if unplaced, !model.pendingFunctions.isEmpty {
            whenRead(nil, quietly: true) { [weak self] in self?.drawInterfaces() }
        }
    }

    /// Where an interface's recorded place is in the code. An instruction
    /// or a function's entry is itself; an address in the module's data —
    /// the descriptor an install passes, which a review may record in place
    /// of the call — is the instruction that hands it over, its first use.
    func interfaceInstruction(for address: CodeAddress) -> CodeAddress {
        if model.function(at: address) != nil || model.line(at: address) != nil
            || model.pendingFunction(holding: address) != nil { return address }
        return model.uses(of: address).first?.from ?? address
    }

    /// An interface's place, opened from the tab. A function's entry — a
    /// notification's callback — opens the function, as a link does. Any
    /// other place is where the module supplies the GUID: the call is
    /// selected in the C, as a POST code's call is, the C shown for it; a
    /// descriptor no instruction holds selects its bytes.
    func openInterfaceAddress(_ recorded: CodeAddress) {
        let address = interfaceInstruction(for: recorded)
        if showsDescription { showDescription(false) }
        if model.function(at: address) != nil {
            go(to: CodeLocation(function: address))
            return
        }
        if model.line(at: address) == nil, let pending = model.pendingFunction(holding: address) {
            whenRead([pending]) { [weak self] in self?.openInterfaceAddress(address) }
            return
        }
        guard let line = model.line(at: address) else { return showSite(address) }
        if !showsDecompiledC { showDecompiledC(true) }
        jump {
            state.selectLine(line)
            drawSelection()
        }
        // A comparison on screen in place of the C: the statement is
        // selected and flashed in the current revision's side of it.
        if showsRevisionDiff {
            if let range = statementInC(supplying: address), let shown = diffRange(ofC: range) {
                diffView.select(shown)
                diffView.flash(shown)
                lastFlash = .c(shown)
            }
            notifyInstruction()
            return
        }
        // The arrival's flash marks the statement too, not the function's
        // name, which it marks for an instruction the C does not place.
        var statement: NSRange?
        if let range = statementInC(supplying: address) {
            let shown = NSRange(location: range.location + cShift, length: range.length)
            if NSMaxRange(shown) <= (cTextView.string as NSString).length {
                cTextView.setSelectedRange(shown)
                cTextView.scrollRangeToVisible(shown)
                statement = shown
            }
        }
        notifyInstruction()
        flashArrival(cMark: statement)
    }

    /// A range of the current function's C where the comparison shows it:
    /// from its first character's place to its last's. A statement over two
    /// lines between which the comparison puts an old line takes that line in.
    func diffRange(ofC range: NSRange) -> NSRange? {
        guard let start = diffView.range(ofC: range.location, length: 0, currentSide: true),
              let end = diffView.range(ofC: NSMaxRange(range), length: 0, currentSide: true),
              end.location >= start.location else { return nil }
        return NSRange(location: start.location, length: end.location - start.location)
    }

    /// Where in its function's C the module supplies an interface, as a
    /// range of the function's `c`: the whole statement that makes the
    /// call. The review may record the call itself, or the instruction that
    /// hands it the GUID or the descriptor — a `PUSH` of the argument, an
    /// `LEA` into a register. The call is found by its place in the C
    /// (`c_sites`); an argument by the name the C gives what it points at
    /// (`c_spans`), which stands inside the call even when the call goes
    /// through a services table and has no place of its own; failing both,
    /// the first call after the argument that the C places. Nil where none.
    func statementInC(supplying address: CodeAddress) -> NSRange? {
        guard let line = model.line(at: address) else { return nil }
        let function = model.functions[model.lines[line].function]
        guard let c = function.c.map({ $0 as NSString }), let index = function.instructions.firstIndex(where: { $0.address == address })
        else { return nil }
        // A name in the signature is not the call: only the body's.
        let brace = c.range(of: "{").location
        let body = brace == NSNotFound ? 0 : brace
        let anchor: Int? = {
            if let site = function.cSites.first(where: { $0.address == address }) { return site.start }
            let targets = Set(function.instructions[index].references.map(\.to))
            if let span = function.cSpans.first(where: { span in
                span.start > body && span.target.map(targets.contains) == true
            }) { return span.start }
            let sites = Dictionary(function.cSites.map { ($0.address, $0.start) }, uniquingKeysWith: { first, _ in first })
            return function.instructions[index...].lazy.compactMap { sites[$0.address] }.first
        }()
        guard let anchor, anchor < c.length else { return nil }
        // The statement: back from the anchor to the end of the one before
        // it — a `;`, `{` or `}` — past the blanks and comments after that,
        // and on to its own `;`. A call the decompiler breaks over two lines
        // is taken whole.
        func character(_ index: Int) -> Character { Character(UnicodeScalar(c.character(at: index)) ?? " ") }
        // A `;` or a brace inside a comment ends no statement: the walk back
        // steps over a comment whole, or a pre comment's tail would be taken
        // into the statement below it.
        let comments = Self.commentRanges(in: c)
        var start = anchor
        while start > 0 {
            if let comment = comments.last(where: { $0.location < start && start <= NSMaxRange($0) }) {
                start = comment.location
                continue
            }
            if ";{}".contains(character(start - 1)) { break }
            start -= 1
        }
        skipping: while start < anchor {
            if character(start).isWhitespace {
                start += 1
            } else if c.substring(from: start).hasPrefix("/*") {
                let close = c.range(of: "*/", range: NSRange(location: start, length: anchor - start))
                guard close.location != NSNotFound else { break skipping }
                start = NSMaxRange(close)
            } else if c.substring(from: start).hasPrefix("//") {
                let newline = c.range(of: "\n", range: NSRange(location: start, length: anchor - start))
                guard newline.location != NSNotFound else { break skipping }
                start = NSMaxRange(newline)
            } else {
                break
            }
        }
        let semicolon = c.range(of: ";", range: NSRange(location: anchor, length: c.length - anchor))
        let lineRange = c.lineRange(for: NSRange(location: anchor, length: 0))
        let lineEnd = NSMaxRange(lineRange) - (c.substring(with: lineRange).hasSuffix("\n") ? 1 : 0)
        let end = semicolon.location != NSNotFound && semicolon.location - anchor < 600
            ? NSMaxRange(semicolon) : lineEnd
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Where the C's comments are, `/* … */` and `// …` to the line's end,
    /// in order. A string or a character literal holds no comment.
    static func commentRanges(in c: NSString) -> [NSRange] {
        let slash = UInt16(UInt8(ascii: "/")), star = UInt16(UInt8(ascii: "*")), newline = UInt16(UInt8(ascii: "\n"))
        let quote = UInt16(UInt8(ascii: "\"")), apostrophe = UInt16(UInt8(ascii: "'")), backslash = UInt16(UInt8(ascii: "\\"))
        var ranges: [NSRange] = []
        var index = 0
        let length = c.length
        while index < length {
            let unit = c.character(at: index)
            let next = index + 1 < length ? c.character(at: index + 1) : 0
            if unit == slash, next == star {
                let close = c.range(of: "*/", range: NSRange(location: index + 2, length: length - index - 2))
                let end = close.location == NSNotFound ? length : NSMaxRange(close)
                ranges.append(NSRange(location: index, length: end - index))
                index = end
            } else if unit == slash, next == slash {
                var end = index + 2
                while end < length, c.character(at: end) != newline { end += 1 }
                ranges.append(NSRange(location: index, length: end - index))
                index = end
            } else if unit == quote || unit == apostrophe {
                var end = index + 1
                while end < length, c.character(at: end) != unit, c.character(at: end) != newline {
                    end += c.character(at: end) == backslash ? 2 : 1
                }
                index = min(length, end + 1)
            } else {
                index += 1
            }
        }
        return ranges
    }

    /// The switch says which tab is in front: a list, or Search. The list's
    /// filter bar goes while the tab is up — the keyboard with it, or its
    /// focus ring would be drawn over the tab.
    /// Whether a tab stands over the lists: Search, Interfaces or a record.
    var showsNavigatorTab: Bool { showsSearchTab || showsInterfacesTab || shownRecordSection != nil }

    func drawListSwitch() {
        listControl.selectedSegment = shownSegment
        let showsTab = showsNavigatorTab
        if showsTab, let responder = window?.firstResponder as? NSView,
           responder.isDescendant(of: navigatorBar) || responder.isDescendant(of: functionScroll) {
            window?.makeFirstResponder(nil)
        }
        navigatorBar.isHidden = showsTab
        // The lists under a tab are hidden, not only covered: a covered row
        // still answers the pointer with its tooltip, and a function's showed
        // over a record's rows.
        functionScroll.isHidden = showsTab || state.rowCount == 0
        readinessBar.isHidden = showsTab || state.list != .functions
        emptyListLabel.isHidden = showsTab || state.rowCount > 0
    }

    /// What the Search tab searches in its scope: the description as the
    /// pane shows it, then every function's C by its place in the artifact.
    /// A function whose code is not here yet is not in it.
    var searchCorpus: [(id: CodeSearchPanel.Target, text: String)] {
        let scope = searchPanel.scope
        var corpus: [(id: CodeSearchPanel.Target, text: String)] = []
        if scope != .functions, descriptionView.hasDescription {
            corpus.append((.description, descriptionView.shownText))
        }
        guard scope != .description else { return corpus }
        return corpus + model.functions.indices.compactMap { index in
            model.functions[index].c.map { (.function(index), $0) }
        }
    }

    /// A function's mark as the Functions list draws it: how far its review
    /// has got, or the library it is from.
    func navigatorMark(of index: Int) -> String {
        Self.functionMark(state.group(of: index), library: state.librarySection(of: index))
    }

    /// A function's name as the navigator writes it.
    func navigatorName(of index: Int) -> String {
        let function = model.functions[index]
        return function.name.isEmpty ? model.displayAddress(function.entry) : function.name
    }

    /// Whether some function's code still has to be read from the store.
    var hasCodeToRead: Bool { !model.pendingFunctions.isEmpty && onLoadFunctions != nil }

    @objc private func searchChanged() {
        state.search(searchField.stringValue)
        drawNavigator()
        // A search looks through the instructions too, so it reads them all.
        if !searchField.stringValue.isEmpty, !model.pendingFunctions.isEmpty {
            whenRead(nil, quietly: true) { [weak self] in
                guard let self else { return }
                self.state.search(self.searchField.stringValue)
                self.drawNavigator()
            }
        }
    }

    /// The selected function's name in the header, after the module's.
    private func updateReferences() {
        let name = state.selectedFunction.map {
            $0.name.isEmpty ? model.displayAddress($0.entry) : $0.name
        } ?? ""
        functionLabel.stringValue = name
        rebuildRevisionMenu()
        selectRevisionItem(comparisonRevision)
        // Empty rather than hidden: the module's name across the divider is
        // centred on this line, with no function selected as well.
        updateFunctionMark()
    }

    // help: panel.code.registry
    /// The mark before the function's name in the header, as the list draws
    /// it: how far the review has got; for a library function, filled when it
    /// is the registry's entry, with a dot when the registry matched it
    /// otherwise. Its hover says the level and what is missing, or what the
    /// registry says.
    private func updateFunctionMark() {
        guard let index = state.function, model.functions.indices.contains(index) else {
            functionMark.isHidden = true
            functionMark.image = nil
            return
        }
        let function = model.functions[index]
        let mark: (glyph: CodeNavigatorIcon.Glyph, color: NSColor)
        let detail: String
        if state.group(of: index) == .library {
            let section = state.librarySection(of: index) ?? .unrecorded
            mark = CodeNavigatorIcon.library(Self.badge(of: section))
            detail = Self.registryDetail(function) ?? Self.title(of: section)
        } else {
            mark = reviewMark(of: index)
            detail = Self.reviewDetail(function)
        }
        let side = CodeNavigatorIcon.side(forFontSize: ToolPanelFont.title().pointSize)
        functionMark.image = CodeNavigatorIcon.image(mark.glyph, color: mark.color, side: side)
        functionMark.lineFont = ToolPanelFont.title()
        functionMark.isHidden = false
        ControlHelp.describe(functionMark, detail)
    }

    /// Every call to function `index`, one row each — a caller that calls it
    /// three times is three rows — then the callers Ghidra knows whose call
    /// it could not place (through a pointer).
    func callers(of index: Int) -> [CodeCaller] {
        let calls = calls(to: index)
        let placed = Set(calls.map(\.function))
        let unplaced = model.functions[index].callers.compactMap(model.function(at:))
            .filter { !placed.contains($0) }
        return calls.map { CodeCaller(function: $0.function, use: $0) }
            + unplaced.map { CodeCaller(function: $0, use: nil) }
    }

    // help: panel.code.callers
    /// Show Callers: a popover listing every call to function `index`, off
    /// the name it was asked at — `at`, a call or the signature in the C —
    /// or else off the function's name in the signature, or in the header;
    /// a click on a row opens the caller at that call. Without a window — in
    /// a test — the popover is made but not shown.
    @discardableResult
    func showCallers(of index: Int, at name: NSRange? = nil) -> CodeCallersPopover? {
        guard model.functions.indices.contains(index) else { return nil }
        // Every call lies in some function's code.
        guard model.pendingFunctions.isEmpty || onLoadFunctions == nil else {
            whenRead(nil) { [weak self] in _ = self?.showCallers(of: index, at: name) }
            return nil
        }
        explanationPopover?.close()
        callersPopover?.close()
        // The name the callers were asked at is where Back returns: it is
        // the place's mark, selected and flashed on the way back.
        let own = signatureName().flatMap { $0.function == index ? $0.range : nil }
        let asked = name ?? own
        let popover = CodeCallersPopover(model: model, callee: index, callers: callers(of: index)) { [weak self] caller in
            self?.leavingCMark = asked
            self?.goToCaller(caller, of: index)
        }
        callersPopover = popover
        guard window != nil else { return popover }
        if let range = asked, !cTextView.isHiddenOrHasHiddenAncestor, let rect = cRect(range) {
            popover.show(relativeTo: rect, of: cTextView)
        } else {
            // Over the description the header names no function.
            let anchor: NSView = functionLabel.isHiddenOrHasHiddenAncestor ? self : functionLabel
            popover.show(relativeTo: anchor.bounds, of: anchor)
        }
        return popover
    }

    /// The Show Callers popover open now, if one is.
    var shownCallers: CodeCallersPopover? {
        guard let callersPopover, callersPopover.isShown else { return nil }
        return callersPopover
    }

    /// Opens a caller: at its call when the call is placed, at its entry when
    /// it is not.
    func goToCaller(_ caller: CodeCaller, of callee: Int) {
        if let use = caller.use {
            goToCall(use, of: callee)
        } else {
            follow(.function(caller.function))
        }
    }

    /// The instructions that call function `index` — or jump to its entry
    /// from another function, a tail call — in listing order.
    private func calls(to index: Int) -> [CodeModel.Use] {
        model.uses(of: model.functions[index].entry).filter { use in
            let type = use.type.uppercased()
            return type.contains("CALL") || (type.contains("JUMP") && use.function != index)
        }
    }

    /// Goes to one call of `callee`: the calling instruction is selected, its
    /// bytes too, and in the C the call to `callee` it is — the first, second…
    /// of that caller's calls to it, in address order — is selected and shown.
    func goToCall(_ use: CodeModel.Use, of callee: Int) {
        jump {
            select(line: use.line)
            notifyInstruction()
        }
        guard showsDecompiledC, let storage = cTextView.textStorage else {
            flashArrival()
            return
        }
        let ordinal = calls(to: callee).filter { $0.function == use.function }
            .firstIndex { $0.line == use.line } ?? 0
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let text = value as? String, text.hasPrefix("code:"), let number = Int(text.dropFirst(5)),
                  cLinks.indices.contains(number), cLinks[number] == .function(callee) else { return }
            ranges.append(range)
        }
        guard !ranges.isEmpty else {
            flashArrival()
            return
        }
        let range = ranges[min(ordinal, ranges.count - 1)]
        cTextView.setSelectedRange(range)
        flashArrival(cMark: range)
    }

    // MARK: - Building

    /// The readiness circle and the origin badge at the title's size: the
    /// tree's marks, scaled to the larger words they stand before.
    private func drawModuleMarks() {
        let readiness = ToolRowMarks.CodeReadiness(manifest.reviewProgress)
        let image = readiness.image(pointSize: (ToolPanelFont.titleSize * 0.8).rounded())
        readinessMark.image = image
        readinessMark.contentTintColor = RowMarks.codeReviewed
        readinessMark.imageScaling = .scaleNone
        readinessMark.translatesAutoresizingMaskIntoConstraints = false
        // Sized from the picture: a configured symbol's intrinsic size is not it.
        NSLayoutConstraint.deactivate(readinessSize)
        let size = image?.size ?? .zero
        readinessSize = [readinessMark.widthAnchor.constraint(equalToConstant: size.width),
                         readinessMark.heightAnchor.constraint(equalToConstant: size.height)]
        NSLayoutConstraint.activate(readinessSize)
        readinessMark.setContentHuggingPriority(.required, for: .horizontal)
        readinessMark.setContentCompressionResistancePriority(.required, for: .horizontal)
        ControlHelp.describe(readinessMark, readiness.words)
        // Settings ▸ Code Analysis can switch the circle off, here as in the tree.
        readinessMark.isHidden = !CodeReadinessDisplay.showsReadiness
        originBadge.pointSize = (ToolPanelFont.titleSize * 0.75).rounded()
        originBadge.show(manifest.reading?.origin)
    }

    /// What the title's marks show, for the tests.
    var moduleMarks: (readiness: String?, origin: String?) {
        (readinessMark.isHidden ? nil : readinessMark.image?.accessibilityDescription, originBadge.isHidden ? nil : originBadge.word)
    }

    private func build(hexView: NSView) {
        // The navigator's head says what is being read: the module and the
        // revision of its review. What produced the analysis is the small grey
        // line under them.
        let nameLabel = label(
            manifest.module.name.isEmpty ? manifest.recipe.id : manifest.module.name,
            font: ToolPanelFont.title())
        let revisionLabel = label(manifest.reading.map { "(r\($0.rev))" } ?? "",
                                  font: ToolPanelFont.title(), color: .secondaryLabelColor)
        revisionLabel.isHidden = manifest.reading == nil
        // The name is what one searches for elsewhere — in the tree, in a
        // report — so it can be selected and copied.
        nameLabel.isSelectable = true
        // Above the stacks' own hugging (250), so a name is shown whole while
        // the pane has room for it; below required, so it is cut when there is
        // none, the versions first.
        nameLabel.setContentCompressionResistancePriority(.init(500), for: .horizontal)
        let nameMinimum = nameLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40)
        nameMinimum.priority = .init(501)
        nameMinimum.isActive = true
        revisionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        revisionLabel.setContentHuggingPriority(.required, for: .horizontal)
        self.nameLabel = nameLabel
        self.revisionLabel = revisionLabel
        let moduleWords = NSStackView(views: [nameLabel, revisionLabel])
        moduleWords.orientation = .horizontal
        moduleWords.alignment = .firstBaseline
        moduleWords.spacing = 4
        // As wide as its words, so that what follows them follows them; the
        // room left over stays at the line's end.
        moduleWords.setHuggingPriority(.defaultHigh, for: .horizontal)
        // help: panel.uefi.module-origin
        drawModuleMarks()
        // Words line up on their baseline; a status beside them has none.
        let moduleLine = NSStackView(views: [readinessMark, originBadge, moduleWords])
        moduleLine.orientation = .horizontal
        moduleLine.alignment = .centerY
        moduleLine.spacing = 6
        self.moduleLine = moduleLine
        // Where the store holds more than one analysis of the module, the
        // versions line is the menu that chooses among them, each named the
        // same way.
        let versionsLine: NSView = recipes.count > 1 ? recipeMenu() : recipeVersions()
        let moduleBlock = NSStackView(views: [moduleLine, versionsLine])
        self.moduleBlock = moduleBlock
        moduleBlock.orientation = .vertical
        moduleBlock.alignment = .leading
        moduleBlock.spacing = 1
        moduleBlock.translatesAutoresizingMaskIntoConstraints = false
        drawDescriptionButton()
        descriptionButton.imagePosition = .imageOnly
        descriptionButton.isBordered = false
        descriptionButton.bezelStyle = .inline
        descriptionButton.setButtonType(.pushOnPushOff)
        descriptionButton.target = self
        descriptionButton.action = #selector(descriptionButtonClicked)
        descriptionButton.translatesAutoresizingMaskIntoConstraints = false
        descriptionButton.setContentHuggingPriority(.required, for: .horizontal)
        descriptionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        ControlHelp.describe(descriptionButton, name: L("Description"),
                             tooltip: L("Show or hide the module's description"))
        // help: panel.code.description
        // «Новое»: the description, not a function, is new.
        descriptionBadge.text = L("New", context: "description")
        descriptionBadge.font = .systemFont(ofSize: 9, weight: .semibold)
        descriptionBadge.ink = .controlAccentColor
        descriptionBadge.translatesAutoresizingMaskIntoConstraints = false
        // Its width is its words: the module line, tied to the book at 999,
        // ends before it, and must not squeeze it to nothing over the book.
        descriptionBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        descriptionBadgeHolder.translatesAutoresizingMaskIntoConstraints = false
        descriptionBadgeHolder.wantsLayer = true
        descriptionBadgeHolder.layer?.zPosition = 1
        if descriptionBadge.superview == nil { descriptionBadgeHolder.addSubview(descriptionBadge) }
        drawDescriptionBadge()

        listControl.target = self
        listControl.action = #selector(listChanged)
        listControl.controlSize = .small
        listControl.font = .systemFont(ofSize: 11)
        configureListSegments()
        listControl.selectedSegment = segment(of: .list(.functions)) ?? -1
        listControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        listControl.translatesAutoresizingMaskIntoConstraints = false

        Self.dressFilter(searchField)
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        configure(functionTable, identifier: "function")
        // The inset list, as the UEFI tree has it: the selection is the
        // system's rounded block, clear of the panel's edges.
        functionTable.style = .inset
        functionTable.allowsMultipleSelection = true
        functionTable.rowHeight = Self.navigatorRowHeight
        functionTable.menu = rowMenu()
        functionScroll.documentView = functionTable
        functionScroll.hasVerticalScroller = true
        functionScroll.drawsBackground = false
        functionScroll.translatesAutoresizingMaskIntoConstraints = false

        let functionPane = CodeNavigatorFrame()
        functionPane.translatesAutoresizingMaskIntoConstraints = false
        functionPane.addSubview(moduleBlock)
        functionPane.addSubview(descriptionButton)
        functionPane.addSubview(descriptionBadgeHolder)
        functionPane.addSubview(listControl)
        functionPane.addSubview(readinessBar)
        functionPane.addSubview(functionScroll)
        emptyListLabel.textColor = .secondaryLabelColor
        emptyListLabel.alignment = .center
        emptyListLabel.isSelectable = false
        emptyListLabel.isHidden = true
        emptyListLabel.translatesAutoresizingMaskIntoConstraints = false
        functionPane.addSubview(emptyListLabel)

        // The buttons beside the filter: how the functions are laid out. Three
        // flat symbols, each with its own tooltip, rather than a segmented
        // control drawing them as one joined piece of chrome. The list of
        // functions is the only one they speak about, so under Strings, POST
        // and Status the filter has the bar to itself.
        orderButtons.orientation = .horizontal
        orderButtons.spacing = Self.orderButtonGap
        orderButtons.alignment = .centerY
        orderButtons.translatesAutoresizingMaskIntoConstraints = false
        orderButtons.setContentHuggingPriority(.required, for: .horizontal)
        orderButtons.setContentCompressionResistancePriority(.required, for: .horizontal)
        // A screen reader lands on the buttons one by one; the group is the
        // sentence that says what the three of them choose.
        orderButtons.setAccessibilityRole(.group)
        orderButtons.setAccessibilityLabel(L("Function order"))
        let orderPhrases: [(name: String, tooltip: String)] = [
            (L("By address"), L("List the functions in the order they lie in the module")),
            (L("Call tree"), ""),
            (L("Grouped by review state"), L("Gather the functions by how far the review has got with each"))
        ]
        // help: panel.code.function-view
        for (index, order) in FunctionOrder.allCases.enumerated() where index < orderPhrases.count {
            let button = CodeOrderButton()
            button.image = NSImage(systemSymbolName: Self.orderSymbol(order),
                                   accessibilityDescription: nil)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.bezelStyle = .inline
            // A choice, not an action: the state is what a screen reader
            // reads as selected, and what colours the symbol.
            button.setButtonType(.pushOnPushOff)
            button.contentTintColor = .secondaryLabelColor
            button.tag = index
            button.target = self
            button.action = #selector(orderChosen(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: Self.orderButtonWidth).isActive = true
            button.heightAnchor.constraint(equalToConstant: Self.orderButtonHeight).isActive = true
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            ControlHelp.describe(button, name: orderPhrases[index].name,
                                 tooltip: orderPhrases[index].tooltip)
            orderButtons.addArrangedSubview(button)
            orderButtonViews.append(button)
        }
        drawCallTreeButton()
        markChosenOrder(state.functionOrder)
        navigatorBar.translatesAutoresizingMaskIntoConstraints = false
        navigatorBar.addSubview(searchField)
        navigatorBar.addSubview(orderButtons)
        functionPane.addSubview(navigatorBar)
        // The Search tab stands over the list and its filter, under the switch.
        searchPanel.translatesAutoresizingMaskIntoConstraints = false
        searchPanel.isHidden = true
        searchPanel.onChoose = { [weak self] target, hit in self?.openSearchHit(target, hit: hit) }
        searchPanel.onScopeChanged = { [weak self] _ in
            guard let self, let query = self.searchedAll else { return }
            self.searchAllFunctions(query)
        }
        functionPane.addSubview(searchPanel)
        NSLayoutConstraint.activate([
            searchPanel.topAnchor.constraint(equalTo: listControl.bottomAnchor, constant: 4),
            searchPanel.leadingAnchor.constraint(equalTo: functionPane.leadingAnchor),
            searchPanel.trailingAnchor.constraint(equalTo: functionPane.trailingAnchor),
            searchPanel.bottomAnchor.constraint(equalTo: functionPane.bottomAnchor)
        ])
        // The Interfaces tab stands where the Search tab does.
        interfacesPanel.translatesAutoresizingMaskIntoConstraints = false
        interfacesPanel.isHidden = true
        interfacesPanel.onChoose = { [weak self] address in self?.openInterfaceAddress(address) }
        functionPane.addSubview(interfacesPanel)
        NSLayoutConstraint.activate([
            interfacesPanel.topAnchor.constraint(equalTo: listControl.bottomAnchor, constant: 4),
            interfacesPanel.leadingAnchor.constraint(equalTo: functionPane.leadingAnchor),
            interfacesPanel.trailingAnchor.constraint(equalTo: functionPane.trailingAnchor),
            interfacesPanel.bottomAnchor.constraint(equalTo: functionPane.bottomAnchor)
        ])
        // A record section's tab stands there too.
        recordPanel.translatesAutoresizingMaskIntoConstraints = false
        recordPanel.isHidden = true
        recordPanel.onOpenAddress = { [weak self] address in self?.openInterfaceAddress(address) }
        recordPanel.onShowRecord = { [weak self] id in self?.showRecordSection(id) }
        recordPanel.setRecords(nil, statuses: manifest.reading?.records,
                               profile: AnalysisProfile.derive(for: manifest.module))
        functionPane.addSubview(recordPanel)
        NSLayoutConstraint.activate([
            recordPanel.topAnchor.constraint(equalTo: listControl.bottomAnchor, constant: 4),
            recordPanel.leadingAnchor.constraint(equalTo: functionPane.leadingAnchor),
            recordPanel.trailingAnchor.constraint(equalTo: functionPane.trailingAnchor),
            recordPanel.bottomAnchor.constraint(equalTo: functionPane.bottomAnchor)
        ])
        // help: panel.code.new-clear
        clearNewMarksButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        clearNewMarksButton.imagePosition = .imageOnly
        clearNewMarksButton.isBordered = false
        clearNewMarksButton.bezelStyle = .inline
        clearNewMarksButton.contentTintColor = .secondaryLabelColor
        clearNewMarksButton.target = self
        clearNewMarksButton.action = #selector(clearNewMarksChosen)
        clearNewMarksButton.isEnabled = false
        clearNewMarksButton.translatesAutoresizingMaskIntoConstraints = false
        clearNewMarksButton.setContentHuggingPriority(.required, for: .horizontal)
        clearNewMarksButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        ControlHelp.describe(clearNewMarksButton, name: L("Clear New marks"),
                             tooltip: L("Take the New mark off every function: what they changed counts as read"))
        navigatorBar.addSubview(clearNewMarksButton)
        searchToOrder = searchField.trailingAnchor.constraint(equalTo: clearNewMarksButton.leadingAnchor, constant: -6)
        searchToEdge = searchField.trailingAnchor.constraint(equalTo: navigatorBar.trailingAnchor, constant: -8)
        // Horizontal margins inside the navigator yield to a pane laid out at
        // no width: two required margins ask for a negative width there, and
        // the solver breaks some other required constraint instead.
        func margin(_ item: NSLayoutXAxisAnchor, _ pane: NSLayoutXAxisAnchor,
                    _ constant: CGFloat) -> [NSLayoutConstraint] {
            let constraint = item.constraint(equalTo: pane, constant: constant)
            constraint.priority = NSLayoutConstraint.Priority(999)
            return [constraint]
        }
        readinessHeight = readinessBar.heightAnchor
            .constraint(equalToConstant: CodeReviewReadinessBar.height)
        // Built a part at a time: one expression of this many arrays takes
        // the type checker of Xcode 26.3 past its time limit.
        var constraints: [NSLayoutConstraint] = [
            emptyListLabel.topAnchor.constraint(equalTo: listControl.bottomAnchor, constant: 16),
            moduleBlock.topAnchor.constraint(greaterThanOrEqualTo: functionPane.topAnchor, constant: 8),
            listControl.topAnchor.constraint(equalTo: moduleBlock.bottomAnchor,
                                             constant: Self.navigatorSpacing),
            readinessBar.topAnchor.constraint(equalTo: listControl.bottomAnchor, constant: 4),
            readinessHeight,
            functionScroll.topAnchor.constraint(equalTo: readinessBar.bottomAnchor, constant: 4),
            functionScroll.bottomAnchor.constraint(equalTo: navigatorBar.topAnchor),
            navigatorBar.leadingAnchor.constraint(equalTo: functionPane.leadingAnchor),
            navigatorBar.trailingAnchor.constraint(equalTo: functionPane.trailingAnchor),
            navigatorBar.bottomAnchor.constraint(equalTo: functionPane.bottomAnchor),
            navigatorBar.heightAnchor.constraint(equalTo: searchField.heightAnchor,
                                                 constant: 2 * Self.navigatorBarRoom),
            searchField.centerYAnchor.constraint(equalTo: navigatorBar.centerYAnchor, constant: 0.5),
            searchToOrder,
            orderButtons.centerYAnchor.constraint(equalTo: navigatorBar.centerYAnchor, constant: 0.5),
            clearNewMarksButton.widthAnchor.constraint(equalToConstant: Self.orderButtonWidth),
            clearNewMarksButton.heightAnchor.constraint(equalToConstant: Self.orderButtonHeight),
            clearNewMarksButton.centerYAnchor.constraint(equalTo: orderButtons.centerYAnchor),
            clearNewMarksButton.trailingAnchor.constraint(equalTo: orderButtons.leadingAnchor, constant: -6)
        ]
        constraints += margin(emptyListLabel.leadingAnchor, functionPane.leadingAnchor, 16)
        constraints += margin(emptyListLabel.trailingAnchor, functionPane.trailingAnchor, -16)
        // Where the list's rows start their text: the inset list keeps them
        // clear of the pane's edge, and the heading keeps to them.
        constraints += margin(moduleBlock.leadingAnchor, functionPane.leadingAnchor, 12 + Self.insetListShift)
        constraints += margin(moduleBlock.trailingAnchor, descriptionButton.leadingAnchor, -6)
        // Against the pane's padding, as the list below it, whether the New
        // badge shows or not: the book does not move.
        let bookTrailing = descriptionButton.trailingAnchor.constraint(equalTo: functionPane.trailingAnchor,
                                                                       constant: Self.bookTrailing)
        bookTrailing.priority = NSLayoutConstraint.Priority(999)
        constraints.append(bookTrailing)
        constraints.append(descriptionButton.centerYAnchor.constraint(equalTo: moduleLine.centerYAnchor))
        // On the book's left, on its line; the module line ends before it
        // while it shows.
        constraints += [
            descriptionBadge.leadingAnchor.constraint(equalTo: descriptionBadgeHolder.leadingAnchor),
            descriptionBadge.trailingAnchor.constraint(equalTo: descriptionBadgeHolder.trailingAnchor),
            descriptionBadge.topAnchor.constraint(equalTo: descriptionBadgeHolder.topAnchor),
            descriptionBadge.bottomAnchor.constraint(equalTo: descriptionBadgeHolder.bottomAnchor),
            descriptionBadgeHolder.trailingAnchor.constraint(equalTo: descriptionButton.leadingAnchor,
                                                             constant: -Self.badgeToBook),
            descriptionBadgeHolder.centerYAnchor.constraint(equalTo: descriptionButton.centerYAnchor)
        ]
        moduleBeforeBadge = moduleBlock.trailingAnchor.constraint(lessThanOrEqualTo: descriptionBadgeHolder.leadingAnchor,
                                                                  constant: -6)
        constraints += margin(listControl.leadingAnchor, functionPane.leadingAnchor, 8)
        constraints += margin(listControl.trailingAnchor, functionPane.trailingAnchor, -8)
        // Edge to edge: the inset list keeps its rows clear of the edges
        // itself, and a margin of the pane's as well would double it.
        constraints += margin(functionScroll.leadingAnchor, functionPane.leadingAnchor, 0)
        constraints += margin(functionScroll.trailingAnchor, functionPane.trailingAnchor, 0)
        constraints += margin(readinessBar.leadingAnchor, functionPane.leadingAnchor, 8)
        constraints += margin(readinessBar.trailingAnchor, functionPane.trailingAnchor, -8)
        constraints += margin(searchField.leadingAnchor, navigatorBar.leadingAnchor, 8)
        constraints += margin(orderButtons.trailingAnchor, navigatorBar.trailingAnchor, -6)
        NSLayoutConstraint.activate(constraints)
        moduleBeforeBadge?.isActive = descriptionMark != nil
        searchToOrder.priority = NSLayoutConstraint.Priority(999)
        searchToEdge.priority = NSLayoutConstraint.Priority(999)

        codeContent.wantsLayer = true
        applyCodeBackground()

        // Over the code stands where the reader is: the function.
        functionLabel.font = ToolPanelFont.title()
        functionLabel.textColor = .labelColor
        functionLabel.lineBreakMode = .byTruncatingTail
        functionLabel.maximumNumberOfLines = 1
        functionLabel.translatesAutoresizingMaskIntoConstraints = false
        functionLabel.onMenu = { [weak self] in self?.functionMenu(for: self?.state.function) }
        // The name is what one searches for elsewhere, so it can be selected
        // and copied. Above the stacks' own hugging (250), so it is shown whole
        // while the row has room for it; below required, so it is cut when
        // there is none — down to a few letters, enough to tell it.
        functionLabel.isSelectable = true
        functionLabel.setContentCompressionResistancePriority(.init(499), for: .horizontal)
        let functionMinimum = functionLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        functionMinimum.priority = .init(502)
        functionMinimum.isActive = true
        functionMark.isHidden = true
        functionMark.imageScaling = .scaleNone
        functionMark.setContentHuggingPriority(.required, for: .horizontal)
        functionMark.setContentCompressionResistancePriority(.required, for: .horizontal)
        functionLine.addArrangedSubview(functionMark)
        functionLine.addArrangedSubview(functionLabel)
        functionLine.orientation = .horizontal
        functionLine.alignment = .firstBaseline
        functionLine.spacing = 4
        functionLine.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        // The decompiled C first: it is what a module is read in.
        drawModeControls()
        modeControl.setContentHuggingPriority(.required, for: .horizontal)
        modeControl.setContentCompressionResistancePriority(.required, for: .horizontal)

        // One line: where the reader is.
        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let occurrenceBar = makeOccurrenceBar()
        self.occurrenceBar = occurrenceBar
        let titleRow = NSStackView(views: [functionLine, modeControl, titleSpacer, occurrenceBar])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.setCustomSpacing(12, after: functionLine)
        titleRow.setContentHuggingPriority(.required, for: .vertical)
        titleRow.setContentCompressionResistancePriority(.required, for: .vertical)
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        staleLabel.font = ToolPanelFont.body()
        staleLabel.textColor = .systemOrange
        staleLabel.lineBreakMode = .byWordWrapping
        staleLabel.maximumNumberOfLines = 0
        staleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        staleLabel.isHidden = true

        let header = NSStackView(views: [titleRow, staleLabel])
        header.orientation = .vertical
        header.alignment = .width
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false

        configure(table, identifier: "instruction")
        table.menu = rowMenu()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        configureC()
        cScroll.documentView = cTextView
        cScroll.hasVerticalScroller = true
        cScroll.drawsBackground = false
        cScroll.translatesAutoresizingMaskIntoConstraints = false
        cScroll.isHidden = true

        descriptionView.translatesAutoresizingMaskIntoConstraints = false
        descriptionView.isHidden = true
        descriptionView.onChooseSection = { [weak self] index in self?.goToDescriptionSection(index) }
        descriptionView.onClose = { [weak self] in self?.showDescription(false) }
        descriptionView.onSectionsChanged = { [weak self] in self?.updateHeaderForMode() }
        descriptionView.onFollow = { [weak self] address, link in self?.followFromDescription(address, link: link) }
        descriptionView.resolveName = { [weak self] name in
            guard let self, let index = self.model.functions.firstIndex(where: { $0.name == name }) else { return nil }
            return self.model.functions[index].entry
        }
        descriptionView.resolvesAddress = { [weak self] address in
            guard let self else { return false }
            return self.model.function(at: address) != nil || self.model.line(at: address) != nil
                || self.model.pendingFunction(holding: address) != nil
        }
        // Until the app has read it: nothing, not "no description".
        descriptionView.show(nil, loaded: false)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tableScroll)
        content.addSubview(cScroll)
        diffView.translatesAutoresizingMaskIntoConstraints = false
        diffView.isHidden = true
        content.addSubview(diffView)
        // The plate is the code area's own: over the pages when there is
        // something to say about the function, and out of the way — and out of
        // the layout — when there is not.
        content.addSubview(newMarkBanner)
        NSLayoutConstraint.activate([
            newMarkBanner.topAnchor.constraint(equalTo: content.topAnchor),
            newMarkBanner.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            newMarkBanner.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
        // A page sits at the top of the area, or under the plate that is up:
        // one of the two constraints is active at a time (`layOutBanner`).
        pageTops = []
        belowBannerTops = []
        for scroll in [tableScroll, cScroll, diffView] {
            let top = scroll.topAnchor.constraint(equalTo: content.topAnchor)
            let below = scroll.topAnchor.constraint(equalTo: newMarkBanner.bottomAnchor, constant: 8)
            pageTops.append(top)
            belowBannerTops.append(below)
            NSLayoutConstraint.activate([
                top,
                scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor)
            ])
        }

        let codeStack = NSStackView(views: [header, content])
        codeStack.orientation = .vertical
        codeStack.alignment = .width
        codeStack.spacing = 8
        codeStack.translatesAutoresizingMaskIntoConstraints = false
        // The description runs the height of the area, in place of the stack.
        descriptionView.translatesAutoresizingMaskIntoConstraints = false
        codeContent.addSubview(descriptionView)
        codeContent.addSubview(codeStack)
        self.codeStack = codeStack
        findBarSlot.translatesAutoresizingMaskIntoConstraints = false
        codeContent.addSubview(findBarSlot)
        NSLayoutConstraint.activate([
            findBarSlot.topAnchor.constraint(equalTo: codeContent.topAnchor),
            findBarSlot.leadingAnchor.constraint(equalTo: codeContent.leadingAnchor),
            findBarSlot.trailingAnchor.constraint(equalTo: codeContent.trailingAnchor)
        ])
        // The margins yield to a pane narrower than twice the margin — a split
        // view lays a pane it has not sized yet at no width, and two required
        // edges 12 points in would ask for a negative width. The solver then
        // breaks a required constraint somewhere in the pane instead, which
        // took a scroll view's edge with it and logged the break.
        let stackLeading = codeStack.leadingAnchor.constraint(equalTo: codeContent.leadingAnchor, constant: 12)
        let stackTrailing = codeStack.trailingAnchor.constraint(equalTo: codeContent.trailingAnchor,
                                                                constant: -12)
        stackLeading.priority = NSLayoutConstraint.Priority(999)
        codeStackLeading = stackLeading
        stackTrailing.priority = NSLayoutConstraint.Priority(999)
        // The top margin, the gap above the bar and the bar's own height yield
        // in a pane laid out with no height, where they would ask for a stack
        // shorter than nothing.
        let stackTop = codeStack.topAnchor.constraint(equalTo: findBarSlot.bottomAnchor, constant: 12)
        stackTop.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([stackLeading, stackTrailing, stackTop])
        header.widthAnchor.constraint(equalTo: codeStack.widthAnchor).isActive = true
        // The code area takes the pane's width too: the plate inside it gives
        // it a fitting width of its own, and the stack would otherwise lay it
        // out at that width, at the trailing edge.
        content.widthAnchor.constraint(equalTo: codeStack.widthAnchor).isActive = true
        titleRow.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        staleLabel.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true

        // The bar is part of the code panel: it stays when the dump is folded
        // and only the dump moves. Its button is a toggle, filled while the
        // bytes are showing.
        hexDumpBar.translatesAutoresizingMaskIntoConstraints = false
        hexDumpButton.image = NSImage(systemSymbolName: "inset.filled.bottomthird.rectangle",
                                      accessibilityDescription: nil)
        hexDumpButton.imagePosition = .imageOnly
        hexDumpButton.setButtonType(.toggle)
        hexDumpButton.isBordered = false
        hexDumpButton.controlSize = .small
        hexDumpButton.target = self
        hexDumpButton.action = #selector(toggleHexDump)
        hexDumpButton.translatesAutoresizingMaskIntoConstraints = false
        hexDumpBar.addSubview(hexDumpButton)
        // The comparison, on the bar's right as Xcode keeps one: the review
        // shown, the arrows, the revision to compare it against and Reset.
        compareLabel.textColor = .secondaryLabelColor
        compareLabel.lineBreakMode = .byTruncatingTail
        compareLabel.translatesAutoresizingMaskIntoConstraints = false
        compareArrows.image = NSImage(systemSymbolName: "arrow.left.arrow.right",
                                      accessibilityDescription: L("Compare with a revision"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))
        compareArrows.contentTintColor = .tertiaryLabelColor
        compareArrows.translatesAutoresizingMaskIntoConstraints = false
        revisionLine.onChoose = { [weak self] tag in self?.chooseRevision(tag) }
        ControlHelp.describe(revisionLine, L("Compare the code with a revision"))
        revisionLine.setContentCompressionResistancePriority(.init(498), for: .horizontal)
        revisionLine.translatesAutoresizingMaskIntoConstraints = false
        resetComparisonButton.title = L("Reset")
        resetComparisonButton.isBordered = false
        resetComparisonButton.bezelStyle = .inline
        resetComparisonButton.controlSize = .small
        drawComparisonFonts()
        resetComparisonButton.contentTintColor = .controlAccentColor
        resetComparisonButton.target = self
        resetComparisonButton.action = #selector(resetComparison)
        resetComparisonButton.translatesAutoresizingMaskIntoConstraints = false
        for view in [compareLabel, compareArrows, revisionLine, resetComparisonButton] {
            hexDumpBar.addSubview(view)
        }
        // help: panel.code.work
        // What the reader is waiting for, on the bar's left; its words give way
        // first where the bar is narrow.
        workBar.style = .bar
        workBar.isIndeterminate = true
        workBar.controlSize = .small
        workBar.isDisplayedWhenStopped = false
        workBar.isHidden = true
        workBar.translatesAutoresizingMaskIntoConstraints = false
        workLabel.textColor = .secondaryLabelColor
        workLabel.lineBreakMode = .byTruncatingTail
        workLabel.isHidden = true
        workLabel.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        workLabel.translatesAutoresizingMaskIntoConstraints = false
        hexDumpBar.addSubview(workBar)
        hexDumpBar.addSubview(workLabel)
        workLabelClearsComparison = workLabel.trailingAnchor.constraint(lessThanOrEqualTo: compareLabel.leadingAnchor,
                                                                        constant: -8)
        problemLabel.textColor = SemanticColors.bad
        problemLabel.lineBreakMode = .byTruncatingTail
        problemLabel.isHidden = true
        problemLabel.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        problemLabel.translatesAutoresizingMaskIntoConstraints = false
        hexDumpBar.addSubview(problemLabel)
        problemLabelClearsComparison = problemLabel.trailingAnchor.constraint(lessThanOrEqualTo: compareLabel.leadingAnchor,
                                                                              constant: -8)
        codeContent.addSubview(hexDumpBar)
        let barHeight = hexDumpBar.heightAnchor.constraint(equalToConstant: Self.dumpBarHeight)
        barHeight.priority = NSLayoutConstraint.Priority(999)
        let stackAboveBar = codeStack.bottomAnchor.constraint(equalTo: hexDumpBar.topAnchor, constant: -8)
        let column = descriptionView.sectionColumn
        column.isHidden = true
        codeContent.addSubview(column)
        let columnTop = column.topAnchor.constraint(equalTo: findBarSlot.bottomAnchor, constant: Self.sectionColumnInset)
        let columnBottom = column.bottomAnchor.constraint(equalTo: hexDumpBar.topAnchor, constant: -Self.sectionColumnInset)
        // They yield in a pane laid out with no height, as the stack's do.
        columnTop.priority = NSLayoutConstraint.Priority(999)
        columnBottom.priority = NSLayoutConstraint.Priority(999)
        let descriptionStart = descriptionView.leadingAnchor.constraint(equalTo: codeContent.leadingAnchor)
        descriptionLeading = descriptionStart
        NSLayoutConstraint.activate([
            descriptionStart,
            descriptionView.trailingAnchor.constraint(equalTo: codeContent.trailingAnchor),
            descriptionView.topAnchor.constraint(equalTo: findBarSlot.bottomAnchor),
            descriptionView.bottomAnchor.constraint(equalTo: hexDumpBar.topAnchor)
        ])
        NSLayoutConstraint.activate([
            columnTop, columnBottom,
            column.leadingAnchor.constraint(equalTo: codeContent.leadingAnchor, constant: Self.sectionColumnInset),
            column.widthAnchor.constraint(equalToConstant: Self.sectionColumnWidth)
        ])
        stackAboveBar.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            hexDumpBar.leadingAnchor.constraint(equalTo: codeContent.leadingAnchor),
            hexDumpBar.trailingAnchor.constraint(equalTo: codeContent.trailingAnchor),
            hexDumpBar.bottomAnchor.constraint(equalTo: codeContent.bottomAnchor),
            barHeight,
            stackAboveBar,
            hexDumpButton.trailingAnchor.constraint(equalTo: hexDumpBar.trailingAnchor, constant: -8),
            hexDumpButton.centerYAnchor.constraint(equalTo: hexDumpBar.centerYAnchor),
            resetComparisonButton.trailingAnchor.constraint(equalTo: hexDumpButton.leadingAnchor, constant: -10),
            resetComparisonButton.centerYAnchor.constraint(equalTo: hexDumpBar.centerYAnchor),
            revisionLine.trailingAnchor.constraint(equalTo: resetComparisonButton.leadingAnchor, constant: -6),
            revisionLine.centerYAnchor.constraint(equalTo: hexDumpBar.centerYAnchor),
            revisionLine.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            compareArrows.trailingAnchor.constraint(equalTo: revisionLine.leadingAnchor, constant: -6),
            compareArrows.centerYAnchor.constraint(equalTo: hexDumpBar.centerYAnchor),
            compareLabel.trailingAnchor.constraint(equalTo: compareArrows.leadingAnchor, constant: -6),
            compareLabel.centerYAnchor.constraint(equalTo: hexDumpBar.centerYAnchor),
            compareLabel.leadingAnchor.constraint(greaterThanOrEqualTo: hexDumpBar.leadingAnchor, constant: 8),
            workBar.leadingAnchor.constraint(equalTo: hexDumpBar.leadingAnchor, constant: 8),
            workBar.centerYAnchor.constraint(equalTo: hexDumpBar.centerYAnchor),
            workBar.widthAnchor.constraint(equalToConstant: 80),
            workLabel.leadingAnchor.constraint(equalTo: workBar.trailingAnchor, constant: 6),
            workLabel.centerYAnchor.constraint(equalTo: hexDumpBar.centerYAnchor),
            problemLabel.leadingAnchor.constraint(equalTo: hexDumpBar.leadingAnchor, constant: 8),
            problemLabel.centerYAnchor.constraint(equalTo: hexDumpBar.centerYAnchor)
        ])
        updateHexDumpButton()
        layOutComparison()

        rightSplit.isVertical = false
        rightSplit.dividerThickness = 1
        rightSplit.addPane(codeContent)
        rightSplit.addPane(moduleHexView)
        rightSplit.setPaneLayout(.fill, at: 0)
        rightSplit.setPaneLayout(.fixed(Self.hexDumpHeight), at: 1)
        // A drag is the reader's own fold. The bar stays in the code pane, so
        // it cannot be dragged out of sight; the button follows whether the
        // dump has any height left.
        hexDumpBar.split = rightSplit
        rightSplit.onDividerMoved = { [weak self] _, _ in
            guard let self, !self.rightSplit.isAnimatingDivider else { return }
            self.hexDumpVisible = self.moduleHexView.frame.height > 0.5
            self.updateHexDumpButton()
        }

        let split = ALSplitView()
        split.isVertical = true
        split.dividerThickness = 1
        split.addPane(functionPane)
        split.addPane(rightSplit)
        split.setPaneLayout(.fixed(Self.navigatorWidth), at: 0)
        split.setPaneLayout(.fill, at: 1)
        // The width the reader drags the navigator to is the one every code
        // pane opens with after it; the code keeps room beside it.
        split.clampDividerPosition = { [weak split] _, position in
            let room = (split?.bounds.width ?? 0) - Self.minimumCodeWidth
            return min(max(position, Self.navigatorWidths.lowerBound),
                       max(Self.navigatorWidths.lowerBound, min(room, Self.navigatorWidths.upperBound)))
        }
        split.onDividerMoved = { _, position in
            Self.defaults.set(Double(position), forKey: Self.navigatorWidthKey)
        }
        split.translatesAutoresizingMaskIntoConstraints = false
        addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: topAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        // The module and the function read on one line across the divider, at
        // every zoom: the row is as high as its controls, the module's block
        // is not. The Find bar stands over the code alone (#41): the
        // function's line moves down under it, and the module's stays.
        moduleLine.centerYAnchor.anchorWithOffset(to: titleRow.centerYAnchor)
            .constraint(equalTo: findBarSlot.heightAnchor).isActive = true
    }

    /// The grey line under the module's name: two points under the body.
    static func recipeFont() -> NSFont {
        .systemFont(ofSize: max(9, ToolPanelFont.size - 2))
    }

    /// The listing and the C at the zoom's new size, and the titles and rows
    /// around them. Where the reader is stays: the function, the instruction,
    /// the selected row.
    private func zoomChanged() {
        emptyListLabel.font = Self.navigatorFont()
        for field in [nameLabel, revisionLabel, functionLabel] { field?.font = ToolPanelFont.title() }
        drawModuleMarks()
        updateFunctionMark()
        drawRecipeIcon()
        drawRecipeTitle()
        drawComparisonFonts()
        updateHeaderForMode()
        staleLabel.font = ToolPanelFont.body()
        layOutNavigatorColumns()
        // What the reader was looking at stays where it was: the line at the
        // top of each list and of the C is at the top again, at the new size.
        syncingSelection = true
        for table in [functionTable, table] {
            // Every row selected: the call tree selects a function at each of
            // its places.
            let selected = table.selectedRowIndexes
            let top = topRow(of: table)
            table.rowHeight = table === functionTable ? Self.navigatorRowHeight : Self.codeLineHeight
            table.reloadData()
            let kept = selected.filteredIndexSet { $0 < table.numberOfRows }
            if !kept.isEmpty {
                table.selectRowIndexes(kept, byExtendingSelection: false)
            }
            if let top { scroll(table, toTop: top) }
        }
        syncingSelection = false
        searchPanel.zoomChanged()
        interfacesPanel.zoomChanged()
        recordPanel.zoomChanged()
        drawnC = nil
        drawnDiff = nil
        updateC(keepingPlace: true)
        updateDiff()
        descriptionView.redraw()
    }

    /// The longest line the decompiler writes: Ghidra breaks C at this many
    /// characters unless told otherwise, and nothing here tells it.
    static let longestCodeLine = 100
    /// What the diff puts before a line: two four-digit numbers and the mark.
    /// The C reads in the same width whether or not it is compared.
    static let diffGutterColumns = 14
    /// The commas a line of the limit is allowed for: each is drawn a space
    /// wider than the characters the decompiler counted. An estimate of a
    /// busy argument list, not a bound.
    static let commaColumns = 12

    /// The width the pane needs for any code to fit without wrapping: the list
    /// as the reader left it and the longest line the decompiler can write in
    /// the chosen font, whichever function is on screen.
    public var codeFitWidth: CGFloat {
        let column = ("M" as NSString).size(withAttributes: [.font: Self.codeFont()]).width
        let columns = CGFloat(Self.longestCodeLine + Self.diffGutterColumns + Self.commaColumns)
        let padding = 2 * (cTextView.textContainerInset.width
                           + (cTextView.textContainer?.lineFragmentPadding ?? 0))
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle)
        return Self.navigatorWidth + 1 + ceil(column * columns) + padding + scroller
    }

    /// The listing's and the C's type: the monospaced family Settings names
    /// for the dump, at the zoom.
    static func codeFont() -> NSFont {
        ToolPanelFont.monospaced(size: ToolPanelFont.size)
    }

    /// One line of the code — a row of the listing, a line of the C: the code
    /// font's own line times the spacing Settings has for the code. At 13
    /// points and the default 1.3 that is 21; the font's line alone is 16,
    /// and read cramped beside the listing.
    static var codeLineHeight: CGFloat {
        let line = NSLayoutManager().defaultLineHeight(for: codeFont())
        return (line * ToolPanelFont.codeLineSpacing).rounded()
    }

    /// How far the code font's own line sits in from the top and the bottom
    /// of a line of the code: the C raises its glyphs by this to centre them,
    /// and draws a highlight this far in, around the glyphs.
    static var codeLinePadding: CGFloat {
        (codeLineHeight - NSLayoutManager().defaultLineHeight(for: codeFont())) / 2
    }

    /// How far the inset list (`NSTableView.Style.inset`), standing edge to
    /// edge, puts a row's text past where the plain list, 8 points in, put
    /// it: its padding at the edge and its first cell's own, less those 8
    /// (measured).
    static let insetListShift: CGFloat = 8

    /// The navigator's lists read a step smaller than the code beside them:
    /// they are an index to the code, not the text being read. The step
    /// follows the zoom.
    static var navigatorSize: CGFloat {
        max(ToolPanelFont.sizeRange.lowerBound, ToolPanelFont.size - 1.5)
    }

    /// The navigator's filter, as every tab at the foot of the panel has it:
    /// Xcode's filter mark in place of the magnifier — the field narrows the
    /// list, it does not go looking.
    static var filterPlaceholder: String { L("Filter") }

    static func dressFilter(_ field: NSSearchField) {
        field.placeholderString = filterPlaceholder
        (field.cell as? NSSearchFieldCell)?.searchButtonCell?.image =
            NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)
    }

    static func navigatorFont() -> NSFont { .systemFont(ofSize: navigatorSize) }

    /// The navigator's font for a function a revision changed, while the
    /// reader has not opened it: the same size, a weight up.
    static func navigatorBoldFont() -> NSFont { .systemFont(ofSize: navigatorSize, weight: .bold) }

    static func navigatorCodeFont() -> NSFont {
        ToolPanelFont.monospaced(size: navigatorSize)
    }

    /// A navigator row's height: the line of its font and the padding
    /// `ToolPanelFont.rowHeight` gives a panel's row.
    static var navigatorRowHeight: CGFloat {
        let font = navigatorFont()
        return (font.ascender - font.descender + font.leading).rounded(.up) + 5
    }

    /// A layer's colour is a CGColor, fixed when it is made: it is resolved
    /// in the pane's own appearance, not whatever appearance happens to be
    /// current — that one left a white page under white text in Dark.
    private func applyCodeBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            codeContent.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }

    // MARK: - Selection

    @objc private func modeChanged() {
        opensOnDescription = false
        mode = modeControl.selectedSegment
        applyMode()
    }

    // help: panel.code.description
    @objc private func descriptionButtonClicked() {
        opensOnDescription = false
        showDescription(!showsDescription)
    }

    /// Set outright: a click on the button has just turned its state over.
    private func drawModeControls() {
        if mode < Self.descriptionSegment { modeControl.selectedSegment = mode }
        descriptionButton.isChosen = showsDescription
        descriptionButton.state = showsDescription ? .on : .off
        drawDescriptionButton()
    }

    // help: panel.code.description
    func applyMode() {
        let segment = mode
        let wasDescription = lastAppliedMode == Self.descriptionSegment
        lastAppliedMode = segment
        if segment <= 1 { codeShowsC = segment == 1 }
        tableScroll.isHidden = segment != 0
        descriptionView.isHidden = segment != Self.descriptionSegment
        refreshDiffVisibility()
        if segment == 1, !showsRevisionDiff { updateC() }
        findTextMayHaveChanged()
        updateNewMarkBanner()
        currentOccurrence = nil
        drawOccurrenceBar()
        if showsDescription, !wasDescription {
            noteDescriptionSeen()
            applyDescriptionComparison()
        } else if !showsDescription, wasDescription {
            leaveDescriptionMark()
        }
        // The bar's picker and Reset speak of what is on screen.
        rebuildRevisionMenu()
        updateResetButton()
        updateHeaderForMode()
    }

    private var lastAppliedMode: Int?

    /// The header over the description: it is about the whole module, so no
    /// function stands there. The column of sections stands beside it.
    func updateHeaderForMode() {
        let column = showsDescription && !descriptionView.sections.isEmpty
        descriptionView.sectionColumn.isHidden = !column
        codeStackLeading?.constant = column
            ? Self.sectionColumnInset + Self.sectionColumnWidth + Self.codeMargin
            : Self.codeMargin
        descriptionLeading?.constant = column ? Self.sectionColumnInset + Self.sectionColumnWidth : 0
        // The description runs the height of the area; nothing stands over it.
        codeStack?.isHidden = showsDescription
    }

    /// A jump as a link is: Back returns to where the description stood.
    func goToDescriptionSection(_ index: Int) {
        jump(even: true) { descriptionView.goToSection(index) }
    }

    func notifyInstruction() {
        guard let line = state.line, let range = model.moduleRange(ofLine: line) else { return }
        onSelectRange?(range)
    }

    /// The selected function's C. Set only when it is another text: a new
    /// instruction in the same function does not lay the text out again.
    func updateC(keepingPlace: Bool = false) {
        guard drawnC != state.function || cTextView.string.isEmpty else { return }
        let place = keepingPlace ? topOfC() : nil
        let selection = cTextView.selectedRange()
        drawnC = state.function
        let font = Self.codeFont()
        cLinks = []
        var tokensShown: [CodeToken] = []
        let text: NSAttributedString
        if let index = state.function, model.isPending(index) {
            let words = functionsNotRead.contains(index)
                ? L("The code of this function has not been read, and the analysis store cannot give it now.")
                : L("Reading the function…")
            text = NSAttributedString(string: words, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        } else if let index = state.function, let c = model.functions[index].c {
            // The function's annotations head its C, as comments in the note's
            // hue: what was found, over what it was found in.
            var header = ""
            var tokens: [CodeToken] = []
            for note in notesByFunction[index] ?? [] {
                var line = "// ◆ \(note.heading)"
                if let address = note.location.address { line += " @ \(model.displayAddress(address))" }
                if !note.note.isEmpty { line += " — \(note.note)" }
                tokens.append(CodeToken(start: header.utf16.count, length: line.utf16.count, kind: note.kind))
                header += line + "\n"
            }
            if !header.isEmpty { header += "\n" }
            let shift = header.utf16.count
            cShift = shift
            tokens += model.cTokens(ofFunction: index).map {
                CodeToken(start: $0.start + shift, length: $0.length, kind: $0.kind, link: $0.link)
            }
            // The function's own name in its signature leads nowhere: it is
            // drawn as a name, not a link, and its right-click menu is Show
            // Callers. The token keeps its link, so a click still highlights
            // every call to the function.
            var drawn = tokens
            if let own = drawn.firstIndex(where: { $0.link == .function(index) }) {
                let token = drawn[own]
                drawn[own] = CodeToken(start: token.start, length: token.length, kind: token.kind)
            }
            text = CodeColors.attributed(header + c, tokens: drawn, font: font,
                                         links: &cLinks, asTextLinks: true, spacedCommas: true)
            tokensShown = tokens
        } else {
            let message = state.selectedFunction == nil
                ? L("The analysis holds no functions.")
                : L("No decompiled C for this function.")
            text = NSAttributedString(string: message, attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor
            ])
        }
        // The C's lines at the listing's pitch, each glyph centred in its line.
        let spaced = NSMutableAttributedString(attributedString: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Self.codeLineHeight
        paragraph.maximumLineHeight = Self.codeLineHeight
        let whole = NSRange(location: 0, length: spaced.length)
        spaced.addAttribute(.paragraphStyle, value: paragraph, range: whole)
        spaced.addAttribute(.baselineOffset, value: Self.codeLinePadding, range: whole)
        cTextView.highlightInset = Self.codeLinePadding
        cTextView.hover(at: nil)
        if cTextView.string != spaced.string { cTextView.textWasReplaced() }
        cTextView.textStorage?.setAttributedString(spaced)
        findTextMayHaveChanged()
        // Laid out whole, and the view as tall as the text, before anything
        // scrolls in it: the lines are taller than the font's, and a view
        // sized from an estimate clamps a scroll short of where it was asked
        // to go (measured: Back landed 156 points off its place).
        if let layout = cTextView.layoutManager, let container = cTextView.textContainer {
            layout.ensureLayout(for: container)
            cTextView.sizeToFit()
        }
        if let place {
            // The same text at another size: the reader stays where they were.
            if NSMaxRange(selection) <= spaced.length { cTextView.setSelectedRange(selection) }
            scrollC(toTop: place)
        } else {
            // Another function's C is read from the line it was left at —
            // or, a function that has grown shorter, from its last part;
            // Back puts a place left there back where it was.
            cTextView.setSelectedRange(NSRange(location: 0, length: 0))
            scrollC(toLine: state.function.flatMap { index in
                topLines[model.functions[index].entry.description]
            } ?? 0)
        }
        shownCTokens = tokensShown
        shownCSymbols = nil
        cTextView.explainable = explainableInC()
        cTextView.callable = signatureName().flatMap { callers(of: $0.function).isEmpty ? nil : $0.range }
        // A parameter or a local is its function's alone: another function's
        // `Status` is another variable.
        if case .variable = highlightedSymbol, highlightedIn != state.function { highlightedSymbol = nil }
        cTextView.highlight(highlightedRangesInC())
        currentOccurrence = nil
        drawOccurrenceBar()
    }

    // help: panel.code.diff
    /// The C of the function on screen against the same function in the
    /// revision the pane compares with: what the revision took and what it
    /// brought, line by line, as an editor shows a change, with each line's
    /// code drawn by the tokens of the revision it came from. Answers whether
    /// there is a change to show at all — a function the two revisions hold
    /// the same is shown as the code, not as a diff of nothing.
    @discardableResult
    private func updateDiff() -> Bool {
        guard wantsRevisionDiff else {
            drawnDiff = nil
            diffFunction = nil
            revisionHasChanges = false
            return false
        }
        guard let baseline = revisionBaseline else {
            diffView.showMessage(L("No earlier revision of this reading is open to compare with."))
            drawnDiff = nil
            diffFunction = nil
            return false
        }
        guard let index = state.function else {
            diffView.showMessage(L("The analysis holds no functions."))
            drawnDiff = nil
            diffFunction = nil
            return false
        }
        if let drawnDiff, drawnDiff.function == index, drawnDiff.revision == revisionCount {
            return revisionHasChanges
        }
        // Drawn again when the function's code comes.
        if model.isPending(index) { return false }
        let function = model.functions[index]
        let old = baseline.functions.first { $0.entry == function.entry }?.c
        guard old != nil || function.c != nil else {
            diffView.showMessage(L("No decompiled C for this function in either revision."))
            drawnDiff = (index, revisionCount)
            diffFunction = index
            revisionHasChanges = false
            return false
        }
        let baselineC = old ?? ""
        let currentC = function.c ?? ""
        let diff = LineDiff.between(baselineC, currentC)
        revisionHasChanges = diff.added > 0 || diff.removed > 0
        // Whether this is the function whose diff is already on screen. Its
        // own redrawing keeps the reader's place; another function's is read
        // from the line it was left at, or — a short function — from its last
        // part, never scrolled past its end into an empty view.
        let stays = diffFunction == index
        drawnDiff = (index, revisionCount)
        diffFunction = index
        guard revisionHasChanges else { return false }
        // Each side's tokens, by the line of its C they sit on.
        let baselineModel = CodeModel(artifact: baseline, layout: nil)
        diffBaselineModel = baselineModel
        diffBaselineIndex = baselineModel.functions.firstIndex { $0.entry == function.entry }
        let currentLines = Self.lines(of: currentC)
        let baselineLines = Self.lines(of: baselineC)
        let currentTokens = Self.tokensByLine(tokens: model.cTokens(ofFunction: index), starts: currentLines,
                                              text: currentC)
        let baselineTokens: [[CodeToken]] = diffBaselineIndex.map {
            Self.tokensByLine(tokens: baselineModel.cTokens(ofFunction: $0), starts: baselineLines,
                              text: baselineC)
        } ?? []
        let lines: [CodeDiffLine] = diff.rows.map { row in
            switch row {
            case let .same(_, new, _):
                return CodeDiffLine(row: row, tokens: currentTokens[new - 1],
                                    lineStart: currentLines[new - 1], currentSide: true)
            case let .added(new, _):
                return CodeDiffLine(row: row, tokens: currentTokens[new - 1],
                                    lineStart: currentLines[new - 1], currentSide: true)
            case let .removed(old, _):
                return CodeDiffLine(row: row, tokens: baselineTokens[old - 1],
                                    lineStart: baselineLines[old - 1], currentSide: false)
            }
        }
        diffView.show(diff, lines: lines, font: Self.codeFont(), lineHeight: Self.codeLineHeight,
                      padding: Self.codeLinePadding)
        diffView.onClick = { [weak self] character, event in
            self?.clickDiff(at: character, event: event) ?? false
        }
        diffView.onEscape = { [weak self] in self?.clearDiffHighlight() }
        diffView.explainable = diffView.shownTokens.filter { token in
            Self.explainedInC.contains(token.token.kind) && explanation(of: token) != nil
        }.map(\.range) + explainableFieldsInDiff(baseline: baselineModel)
        // Another function's diff is read from the line it was left at; the
        // same function's, redrawn at a new size, stays where the reader was.
        if !stays {
            diffView.scroll(toNewLine: topLines[function.entry.description] ?? 0)
        }
        return true
    }

    /// The starts of a text's lines, as UTF-16 offsets.
    private static func lines(of text: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        if text.hasSuffix("\n") { starts.removeLast() }
        return starts
    }

    /// The tokens of a function's C, sorted under the line each begins on.
    private static func tokensByLine(tokens: [CodeToken], starts: [Int], text: String) -> [[CodeToken]] {
        var byLine: [[CodeToken]] = Array(repeating: [], count: starts.count)
        for token in tokens {
            guard let line = starts.lastIndex(where: { $0 <= token.start }) else { continue }
            byLine[line].append(token)
        }
        return byLine
    }

    /// What a click on a diff token names — by the word, since the two sides
    /// number their functions and instructions for themselves.
    private struct DiffSymbol: Equatable {
        let kind: CodeToken.Kind
        let word: String
    }

    private func diffSymbol(_ token: CodeDiffToken) -> DiffSymbol? {
        let string = diffView.shownText as NSString
        guard token.range.location + token.range.length <= string.length else { return nil }
        let word = string.substring(with: token.range)
        let kind = token.token.kind
        switch kind {
        case .keyword, .type, .comment, .mnemonic, .address, .bytes, .note, .personNote:
            return nil
        default:
            return DiffSymbol(kind: kind, word: word)
        }
    }

    /// A click in the diff, as in the C: a name highlights its every
    /// occurrence in the diff, ⌘-click or a double click follows what it
    /// names or, on a variable, selects where it is defined, and a click on a
    /// name that explains itself opens its popover. A field of a structure is
    /// found by its place in the C, and a double click asks about it too:
    /// there is nowhere else for one to go.
    func clickDiff(at character: Int?, event: NSEvent) -> Bool {
        pendingFunctionPopover?.cancel()
        guard let character else {
            clearDiffHighlight()
            return false
        }
        let token = diffView.token(at: character)
        if let token {
            if let symbol = diffSymbol(token) {
                diffView.highlight(diffView.shownTokens.filter { diffSymbol($0) == symbol }.map(\.range))
            }
            if Self.isJump(event), let linkIndex = token.linkIndex,
               diffView.shownLinks.indices.contains(linkIndex) {
                followDiff(diffView.shownLinks[linkIndex], side: token)
                return true
            }
            if Self.isJump(event), let definition = diffView.definition(of: token) {
                diffView.select(definition)
                return true
            }
            if !Self.isJump(event), let linkIndex = token.linkIndex,
               diffView.shownLinks.indices.contains(linkIndex),
               case .function(let linked) = diffView.shownLinks[linkIndex],
               let index = functionHere(linked, currentSide: token.currentSide) {
                let range = token.range
                offerFunctionPopover(index) { [weak self] in
                    self?.diffView.anchor(of: range)
                } go: { [weak self] in
                    self?.follow(.function(index))
                }
                return false
            }
            if !Self.isJump(event), let explained = explanation(of: token) {
                explainInDiff(explained, range: token.range, currentSide: token.currentSide)
                return false
            }
        } else {
            clearDiffHighlight()
        }
        if !event.modifierFlags.contains(.command), let field = fieldInDiff(at: character) {
            explainInDiff(field.explained, range: field.range, currentSide: field.currentSide)
        }
        return false
    }

    /// A function a line of the diff names, in this revision: one the earlier
    /// revision's line names is found by its entry, if it is still here.
    private func functionHere(_ index: Int, currentSide: Bool) -> Int? {
        if currentSide { return index }
        guard let baseline = revisionBaseline, baseline.functions.indices.contains(index) else { return nil }
        return model.function(at: baseline.functions[index].entry)
    }

    /// The popover over a name of the diff. A line of the earlier revision
    /// explains itself from that revision's model: its uses name its functions
    /// and its lines.
    private func explainInDiff(_ explained: CodeExplanation, range: NSRange, currentSide: Bool) {
        guard let (rect, text) = diffView.anchor(of: range) else { return }
        afterClick(inC: true) { [weak self] in
            guard let self else { return }
            if currentSide {
                self.showExplanation(explained, relativeTo: rect, of: text)
            } else {
                self.showExplanation(explained, relativeTo: rect, of: text,
                                     in: self.diffBaselineModel,
                                     onUse: { [weak self] line in self?.goToDiffUse(line) })
            }
        }
    }

    /// The field of a structure under a character of the diff, if it explains
    /// itself: from the revision whose line it is.
    private func fieldInDiff(at character: Int) -> (explained: CodeExplanation, range: NSRange, currentSide: Bool)? {
        guard let place = diffView.placeInC(at: character) else { return nil }
        let side = place.currentSide ? state.function.map { (model, $0) }
            : diffBaselineModel.flatMap { read in diffBaselineIndex.map { (read, $0) } }
        guard let (read, index) = side,
              let field = read.field(atC: place.offset, inFunction: index),
              let explained = read.explanation(ofField: field, inFunction: index),
              let range = diffView.range(ofC: field.start, length: field.length,
                                         currentSide: place.currentSide) else { return nil }
        return (explained, range, place.currentSide)
    }

    /// The fields of both revisions' C that the diff shows and a click
    /// explains.
    private func explainableFieldsInDiff(baseline: CodeModel) -> [NSRange] {
        func ranges(_ read: CodeModel, _ index: Int?, currentSide: Bool) -> [NSRange] {
            guard let index, read.functions.indices.contains(index) else { return [] }
            return read.functions[index].cFields.compactMap { field in
                guard read.explanation(ofField: field, inFunction: index) != nil else { return nil }
                return diffView.range(ofC: field.start, length: field.length, currentSide: currentSide)
            }
        }
        return ranges(model, state.function, currentSide: true)
            + ranges(baseline, diffBaselineIndex, currentSide: false)
    }

    private func clearDiffHighlight() { diffView.highlight([]) }

    /// A use the earlier revision's popover names: its line there, followed
    /// by address into the code on screen — the two revisions number their
    /// instructions for themselves.
    private func goToDiffUse(_ line: Int) {
        guard let baseline = diffBaselineModel, baseline.lines.indices.contains(line),
              let here = model.line(at: baseline.lines[line].instruction.address) else {
            NSSound.beep()
            return
        }
        follow(.line(here), even: true)
    }

    /// The explanation of a diff token, from the revision whose line it is.
    private func explanation(of token: CodeDiffToken) -> CodeExplanation? {
        if token.currentSide {
            guard let index = state.function else { return nil }
            return model.explanation(ofC: token.token, inFunction: index)
        }
        guard let model = diffBaselineModel, let index = diffBaselineIndex else { return nil }
        return model.explanation(ofC: token.token, inFunction: index)
    }

    /// Follows what a link of the diff names. The current revision's links go
    /// where the C's go; the earlier revision's are looked up here by the
    /// address they name, since the two revisions number their functions and
    /// instructions for themselves.
    private func followDiff(_ link: CodeLink, side token: CodeDiffToken) {
        guard !token.currentSide else {
            follow(link)
            return
        }
        switch link {
        case .function(let index):
            guard let baseline = revisionBaseline, baseline.functions.indices.contains(index),
                  let here = model.function(at: baseline.functions[index].entry) else {
                NSSound.beep()
                return
            }
            follow(.function(here))
        case .line(let line):
            guard let baseline = diffBaselineModel, baseline.lines.indices.contains(line),
                  let here = model.line(at: baseline.lines[line].instruction.address) else {
                NSSound.beep()
                return
            }
            follow(.line(here))
        case .bytes(let address):
            follow(.bytes(address))
        case .label:
            NSSound.beep()
        }
    }

}

/// What a click highlights the occurrences of. A function, a global or a
/// jump's target is what it leads to, so two spellings of one address are one
/// symbol; one the analysis could not place is its kind and name. A parameter
/// or a local is its name within the function on screen — Ghidra names each
/// of a function's variables once, and declares all of them at its top.
public enum CodeSymbol: Hashable, Sendable {
    case target(CodeLink)
    case named(CodeToken.Kind, String)
    case variable(String)
}


extension CodePaneView: NSTextViewDelegate {
    /// A call or a global in the C pressed other than by the mouse — by
    /// VoiceOver, say; a click is `clickC`'s.
    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard textView === cTextView, let text = link as? String, text.hasPrefix("code:"),
              let number = Int(text.dropFirst(5)), cLinks.indices.contains(number) else { return false }
        follow(cLinks[number])
        return true
    }
}
