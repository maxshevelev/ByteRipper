import ALSplitView
import AppKit
import CodeAnalysis
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
    private struct Place {
        var function: Int
        var line: Int?
        var view = CodeViewPosition()
    }

    public let manifest: AnalysisManifest
    public let artifact: CodeArtifact
    private var state: CodeReaderState
    private var model: CodeModel { state.model }
    /// The readable analyses of the same module, the chosen one first. One
    /// entry is the ordinary case; more makes the header offer the others.
    private let recipes: [AnalysisManifest]

    private let functionTable = NSTableView()
    private let functionScroll = NSScrollView()
    private let navigatorLabel = NSTextField(labelWithString: "")
    private let listControl: NSSegmentedControl
    private let searchField = NSSearchField()
    /// The header over the POST and Strings columns: one view, put back
    /// whenever a list with columns comes to the front.
    private let navigatorHeader = CodeNavigatorHeader()
    /// What an empty list says in place of its rows.
    private let emptyListLabel = NSTextField(wrappingLabelWithString: "")
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    /// The places the reader went to, oldest first, and which one is current:
    /// Back and Forward walk it as in an IDE. A jump — a click on a call, a
    /// caller, a function in the list — adds a place; moving inside one
    /// function only moves the current one.
    private var history: [Place] = []
    private var historyIndex = -1
    /// The annotations on this module's code, by the function and by the
    /// instruction they are on.
    public private(set) var notes: [CodeNote] = []
    private var notesByFunction: [Int: [CodeNote]] = [:]
    private var notesByLine: [Int: [CodeNote]] = [:]
    /// Which link each `code:N` in the C text is.
    private var cLinks: [CodeLink] = []
    /// The tokens of the C on screen, in the text's own offsets — past the
    /// annotations heading it.
    private var shownCTokens: [CodeToken] = []
    /// What each of `shownCTokens` names, once a highlight has asked.
    private var shownCSymbols: [CodeSymbol?]?
    /// The symbol the reader clicked, every occurrence of which is drawn
    /// highlighted in the C and the listing.
    public private(set) var highlightedSymbol: CodeSymbol?
    /// The function a highlighted variable belongs to.
    private var highlightedIn: Int?
    /// Which of the highlighted name's occurrences the reader is at, in the
    /// side on screen — the one clicked, or the last one stepped to. Nil when
    /// the reader has not been at one yet: a step then starts from the caret.
    private var currentOccurrence: Int?
    private let occurrenceLabel = NSTextField(labelWithString: "")
    private let previousOccurrenceButton = NSButton()
    private let nextOccurrenceButton = NSButton()
    private var occurrenceBar: NSStackView?
    private var drawnC: Int?
    /// How far the function's own C starts into the text shown: the
    /// annotations' comments head it.
    private var cShift = 0
    /// The explanation open over the code, if one is.
    private var explanationPopover: CodeExplanationPopover?
    private var callersPopover: CodeCallersPopover?
    private let table = NSTableView()
    private let tableScroll = NSScrollView()
    private let cTextView = CodeTextView()
    private let cScroll = NSScrollView()
    private let modeControl: NSSegmentedControl
    private let descriptionView = CodeDescriptionView()
    /// The code side the description returns to: the C, or the listing.
    private var codeShowsC = true
    /// Where the description is to be scrolled once its text arrives: a
    /// place adopted before the store answered.
    private var pendingDescriptionScroll: NSPoint?
    /// The link in the description the reader just followed.
    private var leavingDescriptionMark: NSRange?
    private let recipeLine = CodeVersionsLine(frame: .zero)
    /// Turns while the app reads another analysis the reader chose.
    private let recipeSpinner = NSProgressIndicator()
    private let codeContent = NSView()
    private let rightSplit = ALSplitView()
    private let hexDumpBar = CodeDumpBar()
    private let hexDumpButton = NSButton()
    private let moduleHexView: NSView
    private var hexDumpVisible = true
    private static let hexDumpHeight: CGFloat = 220

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
    /// the switch that lays the Functions list out. Then how far a call
    /// tree's row is set in per level.
    private static let navigatorBarHeight: CGFloat = 30
    /// A function-view button: the square each symbol sits in, and the room
    /// between two of them — enough that three read as three buttons.
    private static let orderButtonWidth: CGFloat = 24
    private static let orderButtonHeight: CGFloat = 22
    private static let orderButtonGap: CGFloat = 2
    private static let navigatorIndent: CGFloat = 14
    /// How far a review group's function starts past the group's mark.
    private static let groupMemberIndent: CGFloat = 13
    /// How deep a call tree's row is drawn: deeper levels keep the last one's
    /// inset rather than running the names off the pane.
    private static let navigatorLevels: Int = 10
    /// Where the Functions list's order is kept, like the navigator's width.
    static let navigatorOrderKey = "CodeNavigatorFunctionOrder"
    private let navigatorBar = CodeNavigatorBar()
    /// The three function-view buttons, kept apart rather than joined into one
    /// segmented control: each is a flat symbol, and the one whose layout is
    /// in front carries a plate behind it.
    private let orderButtons = NSStackView()
    private var orderButtonViews: [CodeOrderButton] = []
    /// The filter runs to the bar's edge where the buttons are not there.
    private var searchToOrder: NSLayoutConstraint!
    private var searchToEdge: NSLayoutConstraint!
    private let staleLabel = NSTextField(labelWithString: "")
    /// The header's first line — the module, its revision, the function —
    /// kept to follow the zoom. The versions line under it follows with
    /// `recipeLine`.
    private var nameLabel: NSTextField?
    private var revisionLabel: NSTextField?
    private var pathMark: NSTextField?
    private let functionLabel = CodeTitleField(labelWithString: "")
    /// After the function's name, a library function's badge as the
    /// navigator draws it, with what the library registry says of it.
    let registryMark = CodeBaselineImageView()
    private var zoomObserver: NSObjectProtocol?
    /// Set while the view moves a table's selection itself, so the table's
    /// delegate does not take the move for a click.
    private var syncingSelection = false

    /// An instruction's bytes from a listing click. The app selects them in
    /// the hex view.
    public var onSelectRange: ((Range<UInt64>) -> Void)?
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
        self.moduleHexView = hexView
        // Every analysis newest first, as the agent lists them — the recipe
        // id breaking a tie. The one shown keeps its place: a line where it
        // is not on top says at once that a newer analysis exists.
        var seen: Set<String> = []
        self.recipes = ([manifest] + recipes)
            .filter { seen.insert($0.recipe.id).inserted }
            .sorted {
                $0.analyzedAt == $1.analyzedAt
                    ? $0.recipe.id < $1.recipe.id
                    : $0.analyzedAt > $1.analyzedAt
            }
        // ASM and C are names of formats, not words to translate.
        modeControl = NSSegmentedControl(
            labels: ["ASM", "C", L("Description")], trackingMode: .selectOne,
            target: nil, action: nil)
        listControl = NSSegmentedControl(
            labels: [L("Functions"), L("Strings"), L("POST"), L("Status")],
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
    }

    deinit {
        if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCodeBackground()
    }

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
    var navigatorTitle: String { navigatorLabel.stringValue }
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
    /// description is — what the code shows when the reader goes back to it.
    public var showsDecompiledC: Bool { showsDescription ? codeShowsC : modeControl.selectedSegment == 1 }
    /// The module's description is on screen in place of the code.
    public var showsDescription: Bool { modeControl.selectedSegment == Self.descriptionSegment }
    private static let descriptionSegment = 2

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
        if let origin = pendingDescriptionScroll {
            pendingDescriptionScroll = nil
            layoutSubtreeIfNeeded()
            descriptionView.scroll(to: origin)
        }
    }

    /// Shows the module's description in place of the code, or the code
    /// again — as the segment does.
    public func showDescription(_ shows: Bool) {
        guard shows != showsDescription else { return }
        modeControl.selectedSegment = shows ? Self.descriptionSegment : (codeShowsC ? 1 : 0)
        applyMode()
    }

    /// Back to the code from the description, on the side it was left on.
    private func leaveDescription() {
        guard showsDescription else { return }
        modeControl.selectedSegment = codeShowsC ? 1 : 0
        applyMode()
    }
    /// The analyses the header can offer, the chosen one first.
    public var offeredRecipes: [AnalysisManifest] { recipes }

    /// Chooses one of `offeredRecipes`; the app loads its artifact and rebuilds
    /// the screen.
    public func chooseRecipe(at index: Int) {
        guard recipes.indices.contains(index),
              recipes[index].recipe.id != manifest.recipe.id, !isLoadingRecipe else { return }
        // A large module's artifact takes a moment to read: the dropdown
        // waits, with a spinner beside it, until the app replaces this pane
        // with the chosen analysis — or calls `recipeLoadFailed`.
        recipeLine.isEnabled = false
        recipeSpinner.isHidden = false
        recipeSpinner.startAnimation(nil)
        onChooseRecipe?(recipes[index])
    }

    /// Whether an analysis the reader chose is being read.
    public var isLoadingRecipe: Bool { !recipeSpinner.isHidden }

    /// The chosen analysis could not be read: the pane keeps the one it has,
    /// and the dropdown says so again.
    public func recipeLoadFailed() {
        recipeSpinner.stopAnimation(nil)
        recipeSpinner.isHidden = true
        recipeLine.isEnabled = true
    }

    /// Switches the navigator: Functions, Strings, POST writes, Status codes.
    public func selectList(_ list: List) {
        guard state.show(list) else { return }
        drawNavigator()
        if list != .functions, state.rowCount > 0 {
            selectNavigatorRow(0)
        }
    }

    /// Filters the list in front. Functions match their name, signature,
    /// address or instruction text; strings and the two call lists match what
    /// they say.
    public func filter(by text: String) {
        searchField.stringValue = text
        state.search(text)
        drawNavigator()
    }

    /// Puts the listing back where a screen that moved container left it:
    /// the function, the instruction and the ASM/C choice.
    /// Puts the reader back where it was: at `location` when this artifact
    /// still has it, otherwise at the indices — what a workspace written
    /// before places were kept by address holds.
    public func restore(at location: CodeLocation? = nil, function: Int?, instruction: Int?,
                        showsC: Bool) {
        var function = function
        var instruction = instruction
        if let location, !location.isEmpty {
            let found = artifact.indices(of: location)
            if found.function != nil || found.line != nil {
                function = found.function
                instruction = found.line
            }
        }
        if let function {
            selectFunction(at: function, notify: false)
        }
        if let instruction, model.lines.indices.contains(instruction) {
            select(line: instruction)
        }
        modeControl.selectedSegment = showsC ? 1 : 0
        applyMode()
        resetHistory()
    }

    /// Shows the decompiled C instead of the assembly, or the other way round,
    /// without moving the reader's place: what a Code panel opened with the
    /// listing already showing asks for.
    public func showDecompiledC(_ showsC: Bool) {
        guard showsDecompiledC != showsC || showsDescription else { return }
        modeControl.selectedSegment = showsC ? 1 : 0
        applyMode()
    }

    /// Shows the stale banner. The app calls this when the module's current
    /// bytes no longer match the manifest.
    public func setStale(_ stale: Bool, reason: String? = nil) {
        staleLabel.stringValue = stale
            ? (reason ?? L("The module changed after this analysis."))
            : ""
        staleLabel.isHidden = !stale
    }

    /// Selects a function and its first instruction. A reader's choice also
    /// marks the function's whole stored range as the dump's main zone; it
    /// does not take the selection, which belongs to the reader.
    public func selectFunction(at index: Int, notify: Bool = true) {
        guard model.functions.indices.contains(index) else { return }
        // A caller can point at a function the current search or list hides:
        // show Functions, with the filter cleared, before selecting it.
        revealInNavigator(index)
        state.selectFunction(index)
        // Opening a function a revision changed is what takes its New mark.
        if unopenedChanges.remove(index) != nil {
            syncingSelection = true
            functionTable.reloadData()
            syncingSelection = false
        }
        drawSelection()
        if notify, let range = model.moduleRange(ofFunction: index) {
            onFocusRange?(range)
        }
    }

    /// Marks the selected function's range as the main zone without a click —
    /// what the screen does when it opens on a function.
    public func focusSelectedFunction() {
        guard let function = state.function,
              let range = model.moduleRange(ofFunction: function)
        else { return }
        onFocusRange?(range)
    }

    /// Selects an instruction by its index in the artifact, as a click would.
    public func selectInstruction(at index: Int) {
        guard model.lines.indices.contains(index) else { return }
        select(line: index)
        notifyInstruction()
    }

    /// Selects the instruction covering `range` of the module without moving
    /// the hex view back: the selection came from there.
    public func selectModuleRange(_ range: Range<UInt64>) {
        guard state.list == .functions, !syncingSelection,
              let line = model.line(forModuleRange: range) else { return }
        select(line: line)
    }


    /// The whole stored range of a function, for the hex view and for tests.
    public func moduleRange(forFunction index: Int) -> Range<UInt64>? {
        model.moduleRange(ofFunction: index)
    }

    // MARK: - Drawing the state

    /// Goes to the place a POST code or a status code is sent from, keeping
    /// the list it was chosen in: the instruction in the listing, the call in
    /// the C, its bytes in the hex view. A place Back returns from.
    private func showSite(_ address: CodeAddress) {
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
    private func select(line: Int) {
        revealInNavigator(model.lines[line].function)
        state.selectLine(line)
        drawSelection()
    }

    /// Brings a function into the navigator, redrawing the list when the
    /// state had to switch to Functions or clear the search for it.
    private func revealInNavigator(_ function: Int) {
        guard state.reveal(function: function) else { return }
        listControl.selectedSegment = List.functions.rawValue
        searchField.stringValue = state.searchText
        drawNavigator()
    }

    /// The navigator's title and rows for the list in front, with the selected
    /// function's row chosen when Functions is showing.
    private func drawNavigator() {
        navigatorLabel.stringValue = title(for: state.list)
        listControl.selectedSegment = state.list.rawValue
        // The switch speaks about the functions only: with another list in
        // front the filter takes its room.
        let showsOrder = state.list == .functions
        orderButtons.isHidden = !showsOrder
        searchToOrder.isActive = showsOrder
        searchToEdge.isActive = !showsOrder
        markChosenOrder(state.functionOrder)
        layOutNavigatorColumns()
        drawEmptyList()
        syncingSelection = true
        functionTable.reloadData()
        if state.list == .functions, let function = state.function,
           let row = state.row(ofFunction: function) {
            functionTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
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
        setFunctionOrder(order)
    }

    /// Puts the plate behind the button whose layout is in front and takes it
    /// from the others.
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
    /// mark of its own, the filled `f`; partial, the `f` in a frame; a library
    /// routine, the badge of whose library it is — filled when the function
    /// is the library registry's entry, with a dot when the registry matched
    /// it otherwise.
    static func functionMark(_ group: FunctionGroup, library: LibrarySection? = nil,
                             registry: CodeReaderState.RegistryMark? = nil) -> String {
        switch group {
        case .partial: "function.partial"
        case .library:
            switch registry {
            case .entry?: "library.\(library ?? .unrecorded).entry"
            case .matched?: "library.\(library ?? .unrecorded).matched"
            case nil: "library.\(library ?? .unrecorded)"
            }
        default: "function"
        }
    }

    /// What the library registry says of a function, for its hover and the
    /// header's mark; nil for a function the registry does not hold.
    static func registryDetail(_ function: CodeArtifact.Function) -> String? {
        guard let entry = function.libraryEntry else { return nil }
        let version = String(entry.version)
        var line: String
        switch entry.state {
        case .entry?:
            line = L("Library registry entry, version %1$@", version)
        case .edited?:
            line = L("Library registry entry, version %1$@, changed since: the next publish makes the change its next version", version)
        case .differs?:
            line = entry.differences.isEmpty
                ? L("Matches library registry entry version %1$@; this module's review differs", version)
                : L("Matches library registry entry version %1$@; this module's review differs: %2$@",
                    version, entry.differences.joined(separator: ", "))
        case .conflict?:
            line = entry.base.map {
                L("Matches library registry entry version %1$@; this module's review was made on version %2$@", version, String($0))
            } ?? L("Matches library registry entry version %1$@; this module's review was not made on it", version)
        case nil:
            line = L("Matched with library registry entry version %1$@", version)
        }
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
        case .unrecorded: L("Kind not recorded")
        }
    }

    /// The short name on a library function's badge.
    static func badge(of section: LibrarySection) -> String {
        switch section {
        case .edk2: L("EDK2")
        case .amd: L("AMD")
        case .intel: L("Intel")
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
    /// badge, until the reader opens one.
    public func markRevisionChange(from previous: CodeArtifact) {
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
            if old.name != function.name || old.signature != function.signature
                || old.c != function.c {
                changed.insert(index)
            }
        }
        unopenedChanges = changed
        // The rows changed, not the reader's place: reloading the table must
        // not be taken for a click on a row, which would open one.
        syncingSelection = true
        functionTable.reloadData()
        syncingSelection = false
        drawSelection()
    }

    /// Opens or closes a function's calls in the tree.
    private func toggleCalls(of index: Int) {
        foldRows { $0.toggleExpanded(index) }
        if let row = state.row(ofFunction: index) {
            describeDisclosure(at: row, state.isExpanded(index) ? L("Hide calls") : L("Show calls"))
        }
    }

    /// Opens or closes rows of the Functions list as `change` has the state
    /// do: the rows that come slide in under the one clicked, the rows that
    /// go slide up into it, and every other row keeps its cell — the chevron
    /// clicked is turning still. A change the rows cannot follow one by one
    /// draws the list again.
    private func foldRows(_ change: (inout CodeReaderState) -> Void) {
        func rows() -> [CodeReaderState.FunctionRow] {
            (0..<state.rowCount).compactMap(state.functionRow(at:))
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
        if let function = state.function, let row = state.row(ofFunction: function) {
            functionTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        syncingSelection = false
        drawEmptyList()
    }

    /// The words of the chevron on `row` after it turned: it is not drawn
    /// again, so it does not take them from the row.
    private func describeDisclosure(at row: Int, _ phrase: String) {
        guard row < functionTable.numberOfRows,
              let cell = functionTable.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? CodeNavigatorCell else { return }
        ControlHelp.describe(cell.disclosure, phrase)
    }

    /// The functions a revision the panel received changed, and that the
    /// reader has not opened since: they read bold, with a **New** badge.
    private var unopenedChanges: Set<Int> = []
    /// The function's row, its listing, the selected instruction, its C and
    /// its callers and callees. The listing is reloaded only when the function
    /// changed; a new instruction in the same function only moves the row.
    private var drawnFunction: Int?

    private func drawSelection() {
        syncingSelection = true
        if state.list == .functions, let function = state.function,
           let row = state.row(ofFunction: function), functionTable.selectedRow != row {
            functionTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
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
        updateReferences()
    }

    // help: panel.code.lists
    /// Says why a list has no rows: the search, or what the analysis looks
    /// for. Status is the list that is most often empty — the analysis finds
    /// `ReportStatusCode` calls only through the 32-bit PEI services table.
    private func drawEmptyList() {
        emptyListLabel.font = Self.navigatorFont()
        emptyListLabel.isHidden = state.rowCount > 0
        // An empty list shows no table: its column headers over nothing ran
        // into the sentence that stands in for the rows.
        functionScroll.isHidden = state.rowCount == 0
        guard state.rowCount == 0 else { return }
        if !state.searchText.isEmpty {
            emptyListLabel.stringValue = L("Nothing matches the search.")
        } else if state.list == .statusCodes {
            emptyListLabel.stringValue = L("No ReportStatusCode calls found. The analysis looks for them in 32-bit PEI modules, which call it through the PEI services table.")
        } else {
            emptyListLabel.stringValue = L("The analysis found none in this module.")
        }
    }

    private func title(for list: List) -> String {
        switch list {
        case .functions: L("Functions")
        case .strings: L("Strings")
        case .postCodes: L("POST codes")
        case .statusCodes: L("Status codes")
        }
    }

    @objc private func listChanged() {
        guard let list = List(rawValue: listControl.selectedSegment) else { return }
        selectList(list)
    }

    @objc private func searchChanged() {
        state.search(searchField.stringValue)
        drawNavigator()
    }

    /// The selected function's name in the header, after the module's.
    private func updateReferences() {
        let name = state.selectedFunction.map {
            $0.name.isEmpty ? model.displayAddress($0.entry) : $0.name
        } ?? ""
        functionLabel.stringValue = name
        functionLabel.isHidden = name.isEmpty
        pathMark?.isHidden = name.isEmpty
        updateRegistryMark()
    }

    // help: panel.code.registry
    /// The badge after the function's name in the header: shown for a library
    /// function, filled when it is the registry's entry, with a dot when the
    /// registry matched it otherwise; its hover what the registry says.
    private func updateRegistryMark() {
        guard let index = state.function, model.functions.indices.contains(index),
              state.group(of: index) == .library else {
            registryMark.isHidden = true
            registryMark.image = nil
            return
        }
        let function = model.functions[index]
        let section = state.librarySection(of: index) ?? .unrecorded
        let style: CodeNavigatorIcon.BadgeStyle = switch state.registryMark(of: index) {
        case .entry?: .filled
        case .matched?: .dotted
        case nil: .outlined
        }
        let mark = CodeNavigatorIcon.library(Self.badge(of: section), style: style)
        let side = CodeNavigatorIcon.side(forFontSize: ToolPanelFont.title().pointSize)
        registryMark.image = CodeNavigatorIcon.image(mark.glyph, color: mark.color, side: side)
        registryMark.lineFont = ToolPanelFont.title()
        registryMark.isHidden = false
        let detail = Self.registryDetail(function)
            ?? L("Library function: %1$@. The library registry does not hold it.", Self.title(of: section))
        ControlHelp.describe(registryMark, detail)
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
            popover.show(relativeTo: functionLabel.bounds, of: functionLabel)
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

    // MARK: - Following links, and the way back

    /// A click on a call, a jump's label or a global — in the C or the
    /// listing — goes where it names, as in an IDE: a function opens with its
    /// range as the dump's main zone, an instruction is selected with its
    /// bytes, data selects its bytes in the hex view. The first two are
    /// places Back returns from.
    /// `even`: a move Back returns from even when the function and the
    /// instruction stay what they were.
    func follow(_ link: CodeLink, even: Bool = false) {
        // The code the reader just moved in has the keyboard: ⌘[ goes back
        // here, and the arrows move in the listing.
        takeKeyboard()
        switch link {
        case .function(let index):
            jump { selectFunction(at: index) }
            flashArrival()
        case .line(let line):
            jump(even: even) {
                select(line: line)
                notifyInstruction()
            }
            flashArrival()
        case .bytes(let address):
            if let range = dataRange(at: address) { onSelectRange?(range) }
        case .label(let name):
            // In the same function's C: to the line that defines the label,
            // and to its instruction when the name still spells its address.
            guard let range = labelDefinition(named: name) else { NSSound.beep(); return }
            jump(even: true) {
                if let address = Self.labelAddress(name), let line = model.line(at: address) {
                    select(line: line)
                    notifyInstruction()
                }
                cTextView.setSelectedRange(range)
            }
            flashArrival(cMark: range)
        }
    }

    /// Where `NAME:` stands in the C on screen.
    private func labelDefinition(named name: String) -> NSRange? {
        let text = cTextView.string as NSString
        return shownCTokens.first { token in
            token.kind == .label && token.link == nil && token.start + token.length <= text.length
                && text.substring(with: NSRange(location: token.start, length: token.length)) == name
        }.map { NSRange(location: $0.start, length: $0.length) }
    }

    /// The address a label of Ghidra's own spelling names, `LAB_09dff047`.
    static func labelAddress(_ name: String) -> CodeAddress? {
        guard name.hasPrefix("LAB_") else { return nil }
        return CodeAddress(hex: String(name.dropFirst(4).prefix { $0.isHexDigit }))
    }

    /// The bytes a click on a global selects: a GUID's 16, an integer's or a
    /// pointer's width, or the one byte at the address when the type does
    /// not say.
    private func dataRange(at address: CodeAddress) -> Range<UInt64>? {
        // As wide as its type: a UINT64 is eight bytes, not its first.
        let symbol = artifact.symbols.first { $0.address == address }
        let count = symbol?.type.flatMap(model.width(ofType:)) ?? 1
        return model.moduleRange(of: address, count: count) ?? model.moduleRange(of: address, count: 1)
    }

    private var currentPlace: Place? {
        state.function.map { Place(function: $0, line: state.line) }
    }

    /// The C the reader acted on last — the call they ⌘-clicked — which the
    /// place they leave keeps as its mark.
    private var leavingCMark: NSRange?

    /// How the reader has the code on screen now: both scroll positions, and
    /// in the C the call they followed, or what they selected.
    private var currentView: CodeViewPosition {
        let selected = cTextView.selectedRange()
        let mark = leavingCMark ?? (selected.length > 0 ? selected : nil)
        return CodeViewPosition(listing: tableScroll.contentView.bounds.origin,
                                c: cScroll.contentView.bounds.origin,
                                cMark: mark,
                                cText: state.function.flatMap { model.functions[$0].c },
                                description: showsDescription ? descriptionView.scrollOrigin : nil,
                                descriptionMark: showsDescription ? leavingDescriptionMark : nil)
    }

    /// Keeps the current place as the reader has it now, before they leave it.
    private func recordCurrentPlace() {
        guard historyIndex >= 0, var place = currentPlace else { return }
        place.view = currentView
        history[historyIndex] = place
    }

    /// Moves somewhere new: the place left is kept, what was ahead of it is
    /// dropped, and the new place becomes the current one.
    /// `even`: a new place even when the function and the instruction stay —
    /// a jump to a label in the same function, whose instruction may be
    /// unknown, is still a move Back returns from.
    private func jump(even: Bool = false, _ move: () -> Void) {
        recordCurrentPlace()
        leavingCMark = nil
        leavingDescriptionMark = nil
        move()
        guard let place = currentPlace else { return }
        // Leaving the description for the function on screen is still a
        // move: Back returns to the description.
        if !even, historyIndex >= 0, history[historyIndex].function == place.function,
           history[historyIndex].line == place.line, history[historyIndex].view.description == nil { return }
        history = Array(history.prefix(historyIndex + 1)) + [place]
        historyIndex = history.count - 1
        updateHistoryButtons()
    }

    private func resetHistory() {
        history = currentPlace.map { [$0] } ?? []
        historyIndex = history.count - 1
        updateHistoryButtons()
    }

    /// Back and forward by address, where in it the reader is, and how each
    /// place was on screen: what a pane drawing another artifact of the same
    /// module — a republished review, another recipe — takes over with
    /// `adoptHistory`.
    public var carriedHistory: CodeHistory {
        recordCurrentPlace()
        let places = history.map { place in
            CodeLocation(function: artifact.functions.indices.contains(place.function)
                            ? artifact.functions[place.function].entry : nil,
                         address: place.line.flatMap { model.lines.indices.contains($0)
                            ? model.lines[$0].instruction.address : nil })
        }
        return CodeHistory(places: places, index: historyIndex, views: history.map(\.view))
    }

    /// Takes over another pane's history, place by place, through this
    /// artifact's own numbering; a place this artifact no longer has drops
    /// out. The current place stays where `restore` put it. A place keeps its
    /// scroll positions; its mark in the C only while the function's C is the
    /// same text, since a renamed local moves every offset after it.
    public func adoptHistory(_ carried: CodeHistory) {
        var adopted: [Place] = []
        var current = -1
        for (position, location) in carried.places.enumerated() {
            let found = artifact.indices(of: location)
            guard let function = found.function else { continue }
            if position == carried.index { current = adopted.count }
            var view = carried.views.indices.contains(position) ? carried.views[position] : CodeViewPosition()
            let c = model.functions[function].c
            if view.cText != c {
                view.cMark = nil
                view.cText = c
            }
            adopted.append(Place(function: function, line: found.line, view: view))
        }
        guard current >= 0, var here = currentPlace else { return }
        // The place on screen stays scrolled as it was in the other pane.
        if here.function == adopted[current].function {
            here.view = adopted[current].view
            show(here.view)
            if let origin = here.view.description {
                showDescription(true)
                if descriptionView.hasDescription {
                    descriptionView.scroll(to: origin)
                } else {
                    pendingDescriptionScroll = origin
                }
            }
        }
        adopted[current] = here
        history = adopted
        historyIndex = current
        updateHistoryButtons()
    }

    /// Shows the annotations on this module's code: a mark beside each
    /// annotated function in the list, the title at the end of an annotated
    /// instruction's row, and a comment over the function's C.
    public func setNotes(_ notes: [CodeNote]) {
        guard notes != self.notes else { return }
        self.notes = notes
        notesByFunction = [:]
        notesByLine = [:]
        for note in notes {
            let place = artifact.indices(of: note.location)
            if let function = place.function { notesByFunction[function, default: []].append(note) }
            if let line = place.line { notesByLine[line, default: []].append(note) }
        }
        drawNavigator()
        let selected = table.selectedRow
        syncingSelection = true
        table.reloadData()
        if selected >= 0, selected < table.numberOfRows {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
        syncingSelection = false
        drawnC = nil
        updateC()
    }

    /// Goes to a function, or to an instruction and the function holding it,
    /// as a click on a link would: a place Back returns from. What an
    /// annotation on code and an agent's `open_code` open at.
    public func go(to location: CodeLocation) {
        let place = artifact.indices(of: location)
        if let line = place.line {
            follow(.line(line))
        } else if let function = place.function {
            follow(.function(function))
        }
    }

    /// Makes the listing — or the C, when that is showing — the first
    /// responder, unless something in this pane already is.
    private func takeKeyboard() {
        guard let window else { return }
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: self) { return }
        window.makeFirstResponder(showsDecompiledC ? cTextView : table)
    }

    /// Back: the place before the last jump. View ▸ Back (⌘[) calls this
    /// while the code pane has the keyboard.
    public func goBack() {
        guard canGoBack else { return }
        recordCurrentPlace()
        leavingCMark = nil
        leavingDescriptionMark = nil
        historyIndex -= 1
        go(to: history[historyIndex])
    }

    public func goForward() {
        guard canGoForward else { return }
        recordCurrentPlace()
        leavingCMark = nil
        leavingDescriptionMark = nil
        historyIndex += 1
        go(to: history[historyIndex])
    }

    /// Returns to a place as the reader left it: the same function and
    /// instruction, both scrolled where they were, and the place itself — the
    /// call followed in the C, the instruction in the listing — flashed.
    private func go(to place: Place) {
        selectFunction(at: place.function)
        if let line = place.line, model.lines.indices.contains(line) {
            select(line: line)
            notifyInstruction()
        }
        if let origin = place.view.description {
            showDescription(true)
            descriptionView.scroll(to: origin)
            updateHistoryButtons()
            if let mark = place.view.descriptionMark { descriptionView.flash(mark) }
            return
        }
        leaveDescription()
        show(place.view)
        updateHistoryButtons()
        flashArrival(cMark: place.view.cMark)
    }

    /// A link in the description: the function it names opens in the code,
    /// or the instruction with its function, as a click on a call would. The
    /// description is the place Back returns to.
    private func followFromDescription(_ address: CodeAddress, link: NSRange) {
        let function = model.function(at: address)
        let line = function == nil ? model.line(at: address) : nil
        guard function != nil || line != nil else {
            NSSound.beep()
            return
        }
        // The jump keeps it with the place it leaves.
        leavingDescriptionMark = link
        jump {
            leaveDescription()
            if let function {
                selectFunction(at: function)
            } else if let line {
                select(line: line)
                notifyInstruction()
            }
        }
        takeKeyboard()
        flashArrival()
    }

    /// Scrolls the listing and the C as a place had them, and selects its
    /// mark in the C.
    private func show(_ view: CodeViewPosition) {
        if let origin = view.listing {
            table.layoutSubtreeIfNeeded()
            scroll(tableScroll, to: origin)
        }
        if let mark = view.cMark, NSMaxRange(mark) <= (cTextView.string as NSString).length {
            cTextView.setSelectedRange(mark)
        }
        if let origin = view.c {
            if let layout = cTextView.layoutManager, let container = cTextView.textContainer {
                layout.ensureLayout(for: container)
            }
            scroll(cScroll, to: origin)
        }
    }

    /// The row at the top of `table`'s view, and how far into it the view
    /// starts, as a fraction of the row. Read off the clip view, which a
    /// table hidden behind the C still has: its own visible rect is then
    /// empty. A header over the rows insets the clip view by its height
    /// (measured: the origin is at −28 with the first row whole).
    private func topRow(of table: NSTableView) -> (row: Int, into: CGFloat)? {
        guard let clip = table.enclosingScrollView?.contentView else { return nil }
        let top = clip.bounds.minY + clip.contentInsets.top
        let row = table.row(at: NSPoint(x: 0, y: max(0, top)))
        guard row >= 0 else { return nil }
        let rect = table.rect(ofRow: row)
        return (row, rect.height > 0 ? max(0, top - rect.minY) / rect.height : 0)
    }

    private func scroll(_ table: NSTableView, toTop top: (row: Int, into: CGFloat)) {
        guard let scrollView = table.enclosingScrollView, top.row < table.numberOfRows else { return }
        let rect = table.rect(ofRow: top.row)
        let clip = scrollView.contentView
        let inset = clip.contentInsets.top
        // From the origin that shows the first row whole to the one that shows
        // the last row at the bottom.
        let highest = -inset
        let lowest = max(highest, table.frame.height - clip.bounds.height)
        let y = min(max(highest, rect.minY + top.into * rect.height - inset), lowest)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The character at the top of the C's view, and how far into its line
    /// the view starts, as a fraction of the line.
    private func topOfC() -> (character: Int, into: CGFloat)? {
        guard let layout = cTextView.layoutManager, let container = cTextView.textContainer,
              let storage = cTextView.textStorage, storage.length > 0 else { return nil }
        let origin = cTextView.textContainerOrigin
        let top = cScroll.contentView.bounds.minY - origin.y
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: max(0, top)), in: container)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return (layout.characterIndexForGlyph(at: glyph),
                line.height > 0 ? (top - line.minY) / line.height : 0)
    }

    private func scrollC(toTop place: (character: Int, into: CGFloat)) {
        guard let layout = cTextView.layoutManager, let container = cTextView.textContainer,
              let storage = cTextView.textStorage, place.character < storage.length else { return }
        layout.ensureLayout(for: container)
        cTextView.sizeToFit()
        let glyph = layout.glyphIndexForCharacter(at: place.character)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        scroll(cScroll, to: NSPoint(x: cScroll.contentView.bounds.minX,
                                    y: cTextView.textContainerOrigin.y + line.minY + place.into * line.height))
    }

    private func scroll(_ scrollView: NSScrollView, to origin: NSPoint) {
        guard let document = scrollView.documentView else { return }
        let visible = scrollView.contentView.bounds.size
        let y = max(0, min(origin.y, document.frame.height - visible.height))
        let x = max(0, min(origin.x, document.frame.width - visible.width))
        scrollView.contentView.scroll(to: NSPoint(x: x, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Showing where the reader arrived

    /// What the last arrival flashed, for tests: a row of the listing, or a
    /// range of the C.
    enum Flash: Equatable {
        case row(Int)
        case c(NSRange)
    }
    private(set) var lastFlash: Flash?
    private var flashView: NSView?

    /// Flashes the place the reader just arrived at, in whichever of the
    /// listing and the C is showing: in the C `cMark` when there is one, else
    /// the call made at the selected instruction, else — a function arrived at
    /// from its start — its name in the signature; in the listing the
    /// selected instruction's row.
    private func flashArrival(cMark: NSRange? = nil) {
        lastFlash = nil
        if showsDecompiledC {
            let length = (cTextView.string as NSString).length
            var range = cMark
            if range == nil, let line = state.line, let function = state.selectedFunction,
               let site = function.cSites.first(where: { $0.address == model.lines[line].instruction.address }) {
                range = NSRange(location: site.start + cShift, length: site.length)
            }
            if range == nil, let index = state.function,
               let own = shownCTokens.first(where: { $0.link == .function(index) }) {
                range = NSRange(location: own.start, length: own.length)
            }
            guard let range, range.length > 0, NSMaxRange(range) <= length else { return }
            lastFlash = .c(range)
            cTextView.scrollRangeToVisible(range)
            if cTextView.window != nil { cTextView.showFindIndicator(for: range) }
        } else {
            guard let row = state.selectedRow, row < table.numberOfRows else { return }
            lastFlash = .row(row)
            flashRow(row)
        }
    }

    /// A box over one row of the listing that fades out, as the find
    /// indicator does in the C.
    private func flashRow(_ row: Int) {
        flashView?.removeFromSuperview()
        let rect = table.rect(ofRow: row)
        guard !rect.isEmpty else { return }
        let box = NSView(frame: rect.insetBy(dx: 2, dy: 0))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.findHighlightColor.withAlphaComponent(0.55).cgColor
        box.layer?.cornerRadius = CodeColors.symbolHighlightRadius
        table.addSubview(box)
        flashView = box
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.9
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            box.animator().alphaValue = 0
        } completionHandler: { [weak self, weak box] in
            box?.removeFromSuperview()
            if self?.flashView === box { self?.flashView = nil }
        }
    }

    private func updateHistoryButtons() {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
    }

    @objc private func goBackClicked() { goBack() }
    @objc private func goForwardClicked() { goForward() }

    /// The width the navigator's columns were last fitted to. A pane is built
    /// before it has its size, so the columns are fitted again once it does —
    /// and the table's own last-column sizing does not know that a column in
    /// front of it was resized.
    private var fittedNavigatorWidth: CGFloat = 0

    override public func layout() {
        super.layout()
        let width = functionTable.bounds.width
        guard width > 0, abs(width - fittedNavigatorWidth) > 0.5 else { return }
        fittedNavigatorWidth = width
        layOutNavigatorColumns()
    }

    /// What a navigator row means in the list that is showing. The table has
    /// selected the row already; this puts its bytes or its function on screen.
    private func selectNavigatorRow(_ row: Int) {
        guard row >= 0, row < state.rowCount else { return }
        syncingSelection = true
        functionTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        functionTable.scrollRowToVisible(row)
        syncingSelection = false
        let range: Range<UInt64>?
        switch state.list {
        case .functions:
            guard let index = state.function(atRow: row) else { return }
            jump { selectFunction(at: index) }
            return
        case .strings:
            range = model.moduleRange(of: artifact.strings[state.listedStrings[row]])
        case .postCodes:
            showSite(artifact.postCodes[state.listedPostCodes[row]].address)
            return
        case .statusCodes:
            showSite(artifact.statusCodeCalls[state.listedStatusCodes[row]].address)
            return
        }
        if let range { onSelectRange?(range) }
    }

    // MARK: - Building

    private func build(hexView: NSView) {
        navigatorLabel.stringValue = L("Functions")
        navigatorLabel.font = ToolPanelFont.title()
        navigatorLabel.textColor = .labelColor
        navigatorLabel.alignment = .left
        navigatorLabel.lineBreakMode = .byTruncatingTail
        navigatorLabel.maximumNumberOfLines = 1
        navigatorLabel.translatesAutoresizingMaskIntoConstraints = false

        listControl.target = self
        listControl.action = #selector(listChanged)
        listControl.selectedSegment = List.functions.rawValue
        listControl.controlSize = .small
        listControl.font = .systemFont(ofSize: 11)
        listControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        listControl.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = L("Filter")
        // Xcode's filter mark in place of the magnifier: the field narrows the
        // list, it does not go looking.
        (searchField.cell as? NSSearchFieldCell)?.searchButtonCell?.image =
            NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        configure(functionTable, identifier: "function")
        functionTable.rowHeight = Self.navigatorRowHeight
        functionTable.menu = rowMenu()
        functionScroll.documentView = functionTable
        functionScroll.hasVerticalScroller = true
        functionScroll.drawsBackground = false
        functionScroll.translatesAutoresizingMaskIntoConstraints = false

        let functionPane = NSView()
        functionPane.translatesAutoresizingMaskIntoConstraints = false
        functionPane.addSubview(navigatorLabel)
        functionPane.addSubview(listControl)
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
            (L("Call tree"), L("Hang each function under the one that calls it")),
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
            // reads as selected, and what draws the plate.
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
        markChosenOrder(state.functionOrder)
        navigatorBar.translatesAutoresizingMaskIntoConstraints = false
        navigatorBar.addSubview(searchField)
        navigatorBar.addSubview(orderButtons)
        functionPane.addSubview(navigatorBar)
        searchToOrder = searchField.trailingAnchor.constraint(equalTo: orderButtons.leadingAnchor, constant: -6)
        searchToEdge = searchField.trailingAnchor.constraint(equalTo: navigatorBar.trailingAnchor, constant: -8)
        NSLayoutConstraint.activate([
            emptyListLabel.topAnchor.constraint(equalTo: listControl.bottomAnchor, constant: 16),
            emptyListLabel.leadingAnchor.constraint(equalTo: functionPane.leadingAnchor, constant: 16),
            emptyListLabel.trailingAnchor.constraint(equalTo: functionPane.trailingAnchor, constant: -16),
            navigatorLabel.leadingAnchor.constraint(equalTo: functionPane.leadingAnchor, constant: 12),
            navigatorLabel.trailingAnchor.constraint(equalTo: functionPane.trailingAnchor, constant: -8),
            navigatorLabel.topAnchor.constraint(equalTo: functionPane.topAnchor, constant: 12),
            listControl.topAnchor.constraint(equalTo: navigatorLabel.bottomAnchor, constant: Self.navigatorSpacing),
            listControl.leadingAnchor.constraint(equalTo: functionPane.leadingAnchor, constant: 8),
            listControl.trailingAnchor.constraint(equalTo: functionPane.trailingAnchor, constant: -8),
            functionScroll.topAnchor.constraint(equalTo: listControl.bottomAnchor, constant: Self.navigatorSpacing),
            functionScroll.leadingAnchor.constraint(equalTo: functionPane.leadingAnchor, constant: 8),
            functionScroll.trailingAnchor.constraint(equalTo: functionPane.trailingAnchor, constant: -8),
            functionScroll.bottomAnchor.constraint(equalTo: navigatorBar.topAnchor),
            navigatorBar.leadingAnchor.constraint(equalTo: functionPane.leadingAnchor),
            navigatorBar.trailingAnchor.constraint(equalTo: functionPane.trailingAnchor),
            navigatorBar.bottomAnchor.constraint(equalTo: functionPane.bottomAnchor),
            navigatorBar.heightAnchor.constraint(equalToConstant: Self.navigatorBarHeight),
            searchField.leadingAnchor.constraint(equalTo: navigatorBar.leadingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: navigatorBar.centerYAnchor, constant: 0.5),
            searchToOrder,
            orderButtons.trailingAnchor.constraint(equalTo: navigatorBar.trailingAnchor, constant: -6),
            orderButtons.centerYAnchor.constraint(equalTo: navigatorBar.centerYAnchor, constant: 0.5)
        ])

        codeContent.wantsLayer = true
        applyCodeBackground()

        // The first line is where the reader is: the module, the revision
        // of its review, the function. What produced the analysis is the
        // small grey line under it.
        let nameLabel = label(
            manifest.module.name.isEmpty ? manifest.recipe.id : manifest.module.name,
            font: ToolPanelFont.title())
        let revisionLabel = label(manifest.reading.map { "(r\($0.rev))" } ?? "",
                                  font: ToolPanelFont.title(), color: .secondaryLabelColor)
        revisionLabel.isHidden = manifest.reading == nil
        let pathMark = label("▸", font: ToolPanelFont.title(), color: .tertiaryLabelColor)
        functionLabel.font = ToolPanelFont.title()
        functionLabel.textColor = .labelColor
        functionLabel.lineBreakMode = .byTruncatingTail
        functionLabel.maximumNumberOfLines = 1
        functionLabel.translatesAutoresizingMaskIntoConstraints = false
        functionLabel.onMenu = { [weak self] in self?.functionMenu(for: self?.state.function) }
        // The names are what one searches for elsewhere — in the tree, in a
        // report — so they can be selected and copied.
        nameLabel.isSelectable = true
        functionLabel.isSelectable = true
        // Above the stacks' own hugging (250), so a name is shown whole while
        // the row has room for it; below required, so it is cut when there is
        // none: the versions first, then the function's name — down to a few
        // letters, enough to tell it — and the module's last.
        functionLabel.setContentCompressionResistancePriority(.init(499), for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.init(500), for: .horizontal)
        let functionMinimum = functionLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        functionMinimum.priority = .init(502)
        functionMinimum.isActive = true
        let nameMinimum = nameLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40)
        nameMinimum.priority = .init(501)
        nameMinimum.isActive = true
        for field in [revisionLabel, pathMark] {
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
            field.setContentHuggingPriority(.required, for: .horizontal)
        }
        self.nameLabel = nameLabel
        self.revisionLabel = revisionLabel
        self.pathMark = pathMark
        registryMark.isHidden = true
        registryMark.imageScaling = .scaleNone
        registryMark.setContentHuggingPriority(.required, for: .horizontal)
        registryMark.setContentCompressionResistancePriority(.required, for: .horizontal)
        let pathLine = NSStackView(views: [nameLabel, revisionLabel, pathMark, functionLabel, registryMark])
        pathLine.orientation = .horizontal
        pathLine.alignment = .firstBaseline
        pathLine.spacing = 6
        pathLine.setCustomSpacing(4, after: nameLabel)
        // The line under the names says what produced the analysis — the
        // recipe and the Ghidra version. Where the store holds more than one
        // analysis of the module, the line is the menu that chooses among
        // them, each named the same way.
        let versionsLine: NSView = recipes.count > 1 ? recipeMenu() : recipeVersions()
        let titleBlock = NSStackView(views: [pathLine, versionsLine])
        titleBlock.orientation = .vertical
        titleBlock.alignment = .leading
        titleBlock.spacing = 1
        titleBlock.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        // The decompiled C first: it is what a module is read in.
        modeControl.selectedSegment = 1
        modeControl.setContentHuggingPriority(.required, for: .horizontal)
        modeControl.setContentCompressionResistancePriority(.required, for: .horizontal)

        for (button, action) in [
            (backButton, #selector(goBackClicked)),
            (forwardButton, #selector(goForwardClicked))
        ] {
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.bezelStyle = .inline
            button.controlSize = .regular
            button.target = self
            button.action = action
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        drawNavigationImages()
        // help: panel.code.navigate
        ControlHelp.describe(backButton, name: L("Back"),
                             tooltip: L("Go back to the previous place in the code (⌘[)"))
        ControlHelp.describe(forwardButton, name: L("Forward"),
                             tooltip: L("Go forward again (⌘])"))

        // One line, every control centred on it: the way back and forward,
        // then where the reader is; the platform's round help button and the
        // ASM/C switch at the right — the panel's way to its page in the book.
        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let occurrenceBar = makeOccurrenceBar()
        self.occurrenceBar = occurrenceBar
        let codeHelpButton = HelpButton.standard(for: .topic(.codePanel))
        codeHelpButton.setContentHuggingPriority(.required, for: .horizontal)
        codeHelpButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleRow = NSStackView(views: [backButton, forwardButton, titleBlock, titleSpacer,
                                           occurrenceBar, codeHelpButton, modeControl])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.setCustomSpacing(6, after: backButton)
        titleRow.setCustomSpacing(12, after: forwardButton)
        titleRow.setCustomSpacing(16, after: occurrenceBar)
        // A little air between the round `?` and the switch it stands beside.
        titleRow.setCustomSpacing(12, after: codeHelpButton)
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
        descriptionView.onFollow = { [weak self] address, link in self?.followFromDescription(address, link: link) }
        descriptionView.resolveName = { [weak self] name in
            guard let self, let index = self.model.functions.firstIndex(where: { $0.name == name }) else { return nil }
            return self.model.functions[index].entry
        }
        descriptionView.resolvesAddress = { [weak self] address in
            guard let self else { return false }
            return self.model.function(at: address) != nil || self.model.line(at: address) != nil
        }
        // Until the app has read it: nothing, not "no description".
        descriptionView.show(nil, loaded: false)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tableScroll)
        content.addSubview(cScroll)
        content.addSubview(descriptionView)
        for scroll in [tableScroll, cScroll, descriptionView] {
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: content.topAnchor),
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
        codeContent.addSubview(codeStack)
        NSLayoutConstraint.activate([
            codeStack.leadingAnchor.constraint(equalTo: codeContent.leadingAnchor, constant: 12),
            codeStack.trailingAnchor.constraint(equalTo: codeContent.trailingAnchor, constant: -12),
            codeStack.topAnchor.constraint(equalTo: codeContent.topAnchor, constant: 12)
        ])
        header.widthAnchor.constraint(equalTo: codeStack.widthAnchor).isActive = true
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
        codeContent.addSubview(hexDumpBar)
        NSLayoutConstraint.activate([
            hexDumpBar.leadingAnchor.constraint(equalTo: codeContent.leadingAnchor),
            hexDumpBar.trailingAnchor.constraint(equalTo: codeContent.trailingAnchor),
            hexDumpBar.bottomAnchor.constraint(equalTo: codeContent.bottomAnchor),
            hexDumpBar.heightAnchor.constraint(equalToConstant: Self.dumpBarHeight),
            codeStack.bottomAnchor.constraint(equalTo: hexDumpBar.topAnchor, constant: -8),
            hexDumpButton.trailingAnchor.constraint(equalTo: hexDumpBar.trailingAnchor, constant: -8),
            hexDumpButton.centerYAnchor.constraint(equalTo: hexDumpBar.centerYAnchor)
        ])
        updateHexDumpButton()

        rightSplit.isVertical = false
        rightSplit.dividerThickness = 1
        rightSplit.addPane(codeContent)
        rightSplit.addPane(moduleHexView)
        rightSplit.setPaneLayout(.fill, at: 0)
        rightSplit.setPaneLayout(.fixed(Self.hexDumpHeight), at: 1)
        // A drag is the reader's own fold. The bar stays in the code pane, so
        // it cannot be dragged out of sight; the button follows whether the
        // dump has any height left.
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
    }

    /// Back and Forward, large enough to hit at a glance: the size of the
    /// title's text, in the weight of the title.
    private func drawNavigationImages() {
        for (button, symbol) in [(backButton, "chevron.backward"), (forwardButton, "chevron.forward")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: ToolPanelFont.titleSize + 3, weight: .semibold))
        }
    }

    /// The grey line under the module's name: two points under the body.
    private static func recipeFont() -> NSFont {
        .systemFont(ofSize: max(9, ToolPanelFont.size - 2))
    }

    /// The listing and the C at the zoom's new size, and the titles and rows
    /// around them. Where the reader is stays: the function, the instruction,
    /// the selected row.
    private func zoomChanged() {
        navigatorLabel.font = ToolPanelFont.title()
        emptyListLabel.font = Self.navigatorFont()
        for field in [nameLabel, revisionLabel, pathMark, functionLabel] { field?.font = ToolPanelFont.title() }
        updateRegistryMark()
        drawRecipeIcon()
        drawRecipeChevron()
        drawRecipeTitle()
        staleLabel.font = ToolPanelFont.body()
        drawNavigationImages()
        layOutNavigatorColumns()
        // What the reader was looking at stays where it was: the line at the
        // top of each list and of the C is at the top again, at the new size.
        syncingSelection = true
        for table in [functionTable, table] {
            let selected = table.selectedRow
            let top = topRow(of: table)
            table.rowHeight = table === functionTable ? Self.navigatorRowHeight : Self.codeLineHeight
            table.reloadData()
            if selected >= 0, selected < table.numberOfRows {
                table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            }
            if let top { scroll(table, toTop: top) }
        }
        syncingSelection = false
        drawnC = nil
        updateC(keepingPlace: true)
        descriptionView.redraw()
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

    /// The navigator's lists read a step smaller than the code beside them:
    /// they are an index to the code, not the text being read. The step
    /// follows the zoom.
    static var navigatorSize: CGFloat {
        max(ToolPanelFont.sizeRange.lowerBound, ToolPanelFont.size - 1.5)
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

    // MARK: - The hex dump

    public var isHexDumpVisible: Bool { hexDumpVisible }

    /// Folds the hex view away under its bar, or brings it back, growing the
    /// code on the split's own animation.
    public func setHexDumpVisible(_ visible: Bool, animated: Bool = true) {
        guard hexDumpVisible != visible else { return }
        hexDumpVisible = visible
        updateHexDumpButton()
        let size = visible ? Self.hexDumpHeight : 0
        if animated {
            rightSplit.animateTrailingPaneSize(to: size, duration: 0.2)
        } else {
            rightSplit.setPaneLayout(.fixed(size), at: 1)
            rightSplit.layoutSubtreeIfNeeded()
        }
    }

    @objc private func toggleHexDump() {
        setHexDumpVisible(!hexDumpVisible)
    }

    private func updateHexDumpButton() {
        let phrase = hexDumpVisible ? L("Hide hex dump") : L("Show hex dump")
        hexDumpButton.state = hexDumpVisible ? .on : .off
        hexDumpButton.contentTintColor = hexDumpVisible ? .controlAccentColor : .secondaryLabelColor
        ControlHelp.describe(hexDumpButton, name: phrase, tooltip: phrase)
    }

    /// The POST list's columns, in order: the code, the function that sends
    /// it, the routines it goes through, the address of the call.
    enum PostColumn: String, CaseIterable {
        case code = "post-code", function = "post-function", via = "post-via", address = "post-address"

        var title: String {
            switch self {
            case .code: L("Code")
            case .function: L("Function")
            case .via: L("Through")
            case .address: L("Call address")
            }
        }
    }

    /// The strings list's columns: where the string is, and what it says.
    enum StringColumn: String, CaseIterable {
        case address = "string-address", text = "string-text"

        var title: String {
            switch self {
            case .address: L("Location")
            case .text: L("Text")
            }
        }
    }

    /// The functions list's columns. The by-address order is a table: the
    /// address, then the name. The call tree and the groups lay the name out
    /// as one column, because a row's place there is what a table cannot say.
    enum FunctionColumn: String, CaseIterable {
        case address = "function-address", name = "function"

        var title: String {
            switch self {
            case .address: L("Address")
            case .name: L("Function")
            }
        }
    }

    /// The columns of the list in front, by identifier and header; none for
    /// a one-column list.
    private var navigatorColumns: [(id: String, title: String)] {
        switch state.list {
        case .postCodes: PostColumn.allCases.map { ($0.rawValue, $0.title) }
        case .strings: StringColumn.allCases.map { ($0.rawValue, $0.title) }
        case .functions:
            state.functionOrder == .address
                ? FunctionColumn.allCases.map { ($0.rawValue, $0.title) }
                : []
        case .statusCodes: []
        }
    }

    /// The navigator is one column for Functions and Status, and a table for
    /// POST and Strings: aligned columns under headers. POST is wider than the
    /// pane when it must and scrolls sideways; a string's text takes the
    /// pane's remaining width and is cut there.
    private func layOutNavigatorColumns() {
        let wanted = navigatorColumns
        let wantsColumns = !wanted.isEmpty
        let shown = functionTable.tableColumns.map(\.identifier.rawValue)
        if shown != (wantsColumns ? wanted.map(\.id) : ["function"]) {
            for column in functionTable.tableColumns { functionTable.removeTableColumn(column) }
            if wantsColumns {
                for (id, title) in wanted {
                    let column = NSTableColumn(identifier: .init(id))
                    column.title = title
                    column.resizingMask = .userResizingMask
                    functionTable.addTableColumn(column)
                }
                // A string's text, and a function's name, take what the pane
                // has left after the columns before them.
                if state.list == .strings
                    || (state.list == .functions && state.functionOrder == .address) {
                    functionTable.tableColumns.last?.resizingMask = [.userResizingMask, .autoresizingMask]
                }
                functionTable.headerView = navigatorHeader
                functionTable.allowsColumnReordering = false
                functionTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
                functionTable.intercellSpacing = NSSize(width: 6, height: 0)
                functionScroll.hasHorizontalScroller = state.list == .postCodes
            } else {
                let column = NSTableColumn(identifier: .init("function"))
                column.resizingMask = .autoresizingMask
                functionTable.addTableColumn(column)
                functionTable.headerView = nil
                functionTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
                functionTable.intercellSpacing = NSSize(width: 0, height: 0)
                functionScroll.hasHorizontalScroller = false
                functionTable.sizeLastColumnToFit()
            }
        }
        (functionTable.headerView as? CodeNavigatorHeader)?.zoomChanged()
        let headerFont = Self.navigatorFont()
        // A column's width is its cell's; the gap between columns is extra.
        let padding = 2 * CodeNavigatorHeader.cellTextInset + 4
        func fit(_ id: String, _ widths: [CGFloat], title: String, limit: CGFloat = .greatestFiniteMagnitude) {
            let header = (title as NSString).size(withAttributes: [.font: headerFont]).width
            functionTable.tableColumn(withIdentifier: .init(id))?.width =
                min(limit, ceil(max(header, widths.max() ?? 0)) + padding)
        }
        switch state.list {
        case .postCodes:
            // Each column as wide as what it holds, so the codes line up and
            // nothing is cut; a long chain of routines is cut at a limit.
            let limit = Self.navigatorSize * 18
            for kind in PostColumn.allCases {
                let widths = state.listedPostCodes.map { index -> CGFloat in
                    let entry = artifact.postCodes[index]
                    return (postCodeCell(entry, kind) as NSString).size(withAttributes: [.font: postFont(entry, kind)]).width
                }
                fit(kind.rawValue, widths, title: kind.title, limit: limit)
            }
        case .strings:
            // The addresses are in the code font, so the longest is the widest;
            // the text takes the rest.
            let longest = state.listedStrings.lazy
                .map { self.model.displayAddress(self.artifact.strings[$0].address) }
                .max { $0.count < $1.count } ?? ""
            fit(StringColumn.address.rawValue,
                [(longest as NSString).size(withAttributes: [.font: Self.navigatorCodeFont()]).width],
                title: StringColumn.address.title)
            functionTable.sizeLastColumnToFit()
        case .functions:
            // The address column is as wide as the module's widest address;
            // the name takes the rest.
            guard state.functionOrder == .address else { break }
            let longest = state.listedFunctions.lazy
                .map { self.model.displayAddress(self.model.functions[$0].entry) }
                .max { $0.count < $1.count } ?? ""
            fit(FunctionColumn.address.rawValue,
                [(longest as NSString).size(withAttributes: [.font: Self.navigatorCodeFont()]).width],
                title: FunctionColumn.address.title)
            functionTable.sizeLastColumnToFit()
        case .statusCodes:
            break
        }
    }

    /// Numbers in the code font, words in the panel's: a code and an address
    /// line up digit under digit, "Value unknown" reads as a sentence.
    private func postFont(_ entry: CodeArtifact.PostCode, _ column: PostColumn) -> NSFont {
        switch column {
        case .code where entry.value != nil, .address: Self.navigatorCodeFont()
        default: Self.navigatorFont()
        }
    }

    /// What a POST row says in one column.
    func postCodeCell(_ entry: CodeArtifact.PostCode, _ column: PostColumn) -> String {
        switch column {
        case .code:
            if let value = entry.value {
                let digits = max(2, 2 * (entry.width ?? 1))
                let port = entry.portNumber.map { $0 == 0x80 ? "" : String(format: " → 0x%llX", $0) } ?? ""
                return String(format: "0x%0\(digits)llX", value) + port
            }
            switch entry.unresolved {
            case .portParameter, .portComputed: return L("Port unknown")
            case .valueParameter, .valueComputed: return L("Value unknown")
            case nil: return entry.text
            }
        case .function:
            return entry.function.flatMap(model.function(at:)).map { model.functions[$0].name } ?? ""
        case .via:
            return entry.via.map { $0.name ?? model.displayAddress($0.function) }.joined(separator: " → ")
        case .address:
            return model.displayAddress(entry.address)
        }
    }

    private func configure(_ table: NSTableView, identifier: String) {
        let column = NSTableColumn(identifier: .init(identifier))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowSizeStyle = .custom
        table.rowHeight = Self.codeLineHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.allowsEmptySelection = false
        table.delegate = self
        table.dataSource = self
    }

    private func configureC() {
        cTextView.onClick = { [weak self] character, event in self?.clickC(at: character, event: event) ?? false }
        cTextView.onEscape = { [weak self] in self?.highlight(nil) }
        cTextView.onMenu = { [weak self] character in self?.cMenu(at: character) }
        cTextView.isEditable = false
        cTextView.isSelectable = true
        cTextView.isRichText = true
        cTextView.delegate = self
        // A link keeps the colour of what it is — a function, a global — and
        // shows the hand; no underline over every call.
        cTextView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        cTextView.drawsBackground = false
        cTextView.font = Self.codeFont()
        cTextView.textContainerInset = NSSize(width: 8, height: 8)
        cTextView.isVerticallyResizable = true
        cTextView.isHorizontallyResizable = false
        cTextView.autoresizingMask = [.width]
        cTextView.textContainer?.widthTracksTextView = true
        cTextView.minSize = .zero
    }

    /// The plugin that produced the analysis and the Ghidra it ran in, as the
    /// quiet parenthesis after the module's name. The recipe id carries both;
    /// the exporter and Ghidra fields are what it was built from.
    private func recipeSummary() -> String { Self.recipeSummary(of: manifest) }

    private static func recipeSummary(of manifest: AnalysisManifest) -> String {
        let plugin = manifest.recipe.id
            .components(separatedBy: "-ghidra-").first ?? manifest.recipe.id
        var parts = [plugin]
        if let ghidra = manifest.recipe.ghidra, !ghidra.isEmpty {
            parts.append("Ghidra \(ghidra)")
        }
        return parts.joined(separator: " · ")
    }

    /// The versions line as a menu: the analysis shown, named as the plain
    /// line names it, and a small chevron that says the line opens — a jump
    /// bar's. The button has no bezel of its own, so the line reads as the
    /// plain one does until the pointer is over it, and then it takes the
    /// rounded ground an inline button shows. The spinner turns beside it
    /// while the app reads the chosen analysis.
    private func recipeMenu() -> NSView {
        drawRecipeIcon()
        drawRecipeTitle()
        drawRecipeChevron()
        recipeLine.translatesAutoresizingMaskIntoConstraints = false
        // Above the stacks' own hugging as the plain line was, so the text is
        // shown whole while the row has room and gives way, truncated, first.
        recipeLine.setContentCompressionResistancePriority(.init(498), for: .horizontal)
        recipeLine.onOpen = { [weak self] in self?.recipeMenuClicked() }
        // help: panel.code.analysis
        ControlHelp.describe(recipeLine, name: L("Analysis"),
                             tooltip: L("Choose the stored analysis shown here"))

        recipeSpinner.style = .spinning
        recipeSpinner.controlSize = .small
        recipeSpinner.isDisplayedWhenStopped = false
        recipeSpinner.isHidden = true
        recipeSpinner.translatesAutoresizingMaskIntoConstraints = false

        let line = NSStackView(views: [recipeLine, recipeSpinner])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 6
        return line
    }

    /// The line with one analysis: the icon and the summary, no menu.
    private func recipeVersions() -> NSView {
        drawRecipeIcon()
        drawRecipeTitle()
        recipeLine.translatesAutoresizingMaskIntoConstraints = false
        // Above the stacks' own hugging as the plain line was, so the text is
        // shown whole while the row has room and gives way, truncated, first.
        recipeLine.setContentCompressionResistancePriority(.init(498), for: .horizontal)
        return recipeLine
    }

    /// The tray before the versions: what the line is about, and the edge the
    /// line is read from.
    private func drawRecipeIcon() {
        let size = max(Self.recipeFont().pointSize, 9)
        recipeLine.setIcon(NSImage(systemSymbolName: "tray", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular)))
    }

    /// The line's text: the analysis and the Ghidra version in the quiet grey
    /// of the versions line, whatever the pointer is doing.
    private func drawRecipeTitle() {
        recipeLine.title = Self.recipeSummary(of: manifest)
        recipeLine.setFont(Self.recipeFont())
    }

    /// The small up-and-down chevron the line wears when it opens a menu, as
    /// a jump bar's does: the system's own symbol, sized with the line.
    private func drawRecipeChevron() {
        let size = max(Self.recipeFont().pointSize - 1, 8)
        recipeLine.setChevron(NSImage(systemSymbolName: "chevron.up.chevron.down",
                                      accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular)))
    }

    private func label(_ text: String, font: NSFont,
                       color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    // MARK: - Selection

    @objc private func modeChanged() {
        applyMode()
    }

    /// The line opens the analyses the store holds, the one shown ticked. A
    /// menu pops below it, as a control's menu does.
    @objc private func recipeMenuClicked() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, recipe) in recipes.enumerated() {
            let item = NSMenuItem(title: Self.recipeSummary(of: recipe),
                                  action: #selector(recipeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = recipe.recipe.id == manifest.recipe.id ? .on : .off
            menu.addItem(item)
        }
        recipeLine.menuOpened()
        defer { recipeLine.menuClosed() }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: recipeLine)
    }

    @objc private func recipeChosen(_ item: NSMenuItem) {
        chooseRecipe(at: item.tag)
    }

    // help: panel.code.description
    private func applyMode() {
        let segment = modeControl.selectedSegment
        if segment != Self.descriptionSegment { codeShowsC = segment == 1 }
        let c = segment == 1
        tableScroll.isHidden = segment != 0
        cScroll.isHidden = !c
        descriptionView.isHidden = segment != Self.descriptionSegment
        if c { updateC() }
        currentOccurrence = nil
        drawOccurrenceBar()
    }

    private func notifyInstruction() {
        guard let line = state.line, let range = model.moduleRange(ofLine: line) else { return }
        onSelectRange?(range)
    }

    /// The selected function's C. Set only when it is another text: a new
    /// instruction in the same function does not lay the text out again.
    private func updateC(keepingPlace: Bool = false) {
        guard drawnC != state.function || cTextView.string.isEmpty else { return }
        let place = keepingPlace ? topOfC() : nil
        let selection = cTextView.selectedRange()
        drawnC = state.function
        let font = Self.codeFont()
        cLinks = []
        var tokensShown: [CodeToken] = []
        let text: NSAttributedString
        if let index = state.function, let c = model.functions[index].c {
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
        cTextView.textStorage?.setAttributedString(spaced)
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
            // Another function's C is read from its top; Back puts a place
            // left further down back where it was.
            cTextView.setSelectedRange(NSRange(location: 0, length: 0))
            cTextView.scroll(.zero)
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

    // MARK: - Highlighting a symbol

    /// The symbol a token is an occurrence of, or nil for one that is not a
    /// name: a keyword, a type, a constant, an address.
    func symbol(of token: CodeToken, in text: String) -> CodeSymbol? {
        symbol(of: token, in: Array(text.utf16))
    }

    /// The same over the text's UTF-16 units, made once by a caller that
    /// asks for many tokens: a copy of the whole text per token made a click
    /// in a long function's C cost seconds.
    private func symbol(of token: CodeToken, in units: [UTF16.CodeUnit]) -> CodeSymbol? {
        func name() -> String {
            guard token.start >= 0, token.start + token.length <= units.count else { return "" }
            return String(decoding: units[token.start..<token.start + token.length], as: UTF16.self)
        }
        switch token.kind {
        case .label:
            // By name: a `goto` links to its label and the definition links
            // nowhere, and a click on either highlights both.
            return .named(.label, name())
        case .function, .global, .pcode:
            if let link = token.link { return .target(link) }
            return .named(token.kind, name())
        case .parameter, .local:
            return .variable(name())
        default:
            return nil
        }
    }

    private func highlightedRanges(in tokens: [CodeToken], of text: String) -> [NSRange] {
        guard let highlightedSymbol else { return [] }
        let units = Array(text.utf16)
        return tokens.filter { symbol(of: $0, in: units) == highlightedSymbol }
            .map { NSRange(location: $0.start, length: $0.length) }
    }

    /// The occurrences of the highlighted symbol in the C on screen. What
    /// each token names is worked out once per text shown, so a click costs
    /// a pass over the names, not a reading of the text.
    private func highlightedRangesInC() -> [NSRange] {
        guard let highlightedSymbol else { return [] }
        if shownCSymbols == nil {
            let units = Array(cTextView.string.utf16)
            shownCSymbols = shownCTokens.map { symbol(of: $0, in: units) }
        }
        return zip(shownCTokens, shownCSymbols ?? []).compactMap { token, symbol in
            symbol == highlightedSymbol ? NSRange(location: token.start, length: token.length) : nil
        }
    }

    /// Highlights every occurrence of `symbol` — in the C on screen and in the
    /// listing's rows — or clears the highlight.
    public func highlight(_ symbol: CodeSymbol?) {
        guard symbol != highlightedSymbol else { return }
        highlightedSymbol = symbol
        highlightedIn = state.function
        currentOccurrence = nil
        cTextView.highlight(highlightedRangesInC())
        drawOccurrenceBar()
        // Every row, not only the visible ones: the listing may be behind the
        // C, and a row with no view yet costs nothing to reload.
        guard table.numberOfRows > 0 else { return }
        syncingSelection = true
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows),
                         columnIndexes: IndexSet(integer: 0))
        syncingSelection = false
    }

    // MARK: - Stepping through a name's occurrences

    /// One place the highlighted name is at: a range of the C, or a row of
    /// the listing and the range in it.
    struct Occurrence: Equatable {
        var row: Int?
        var range: NSRange
    }

    /// The highlighted name's occurrences in the side on screen, in reading
    /// order. None while the description shows: it is not code.
    func occurrences() -> [Occurrence] {
        guard highlightedSymbol != nil, !showsDescription else { return [] }
        if showsDecompiledC { return highlightedRangesInC().map { Occurrence(row: nil, range: $0) } }
        return listingOccurrences().map { Occurrence(row: $0.row, range: $0.range) }
    }

    /// The listing's rows that name the highlighted symbol, row by row. Read
    /// when asked — a step or the counter — not while the rows are drawn.
    private func listingOccurrences() -> [(row: Int, range: NSRange)] {
        guard highlightedSymbol != nil else { return [] }
        let lines = state.lines
        var found: [(row: Int, range: NSRange)] = []
        for row in 0..<lines.count {
            let shown = model.listingRow(ofLine: lines[lines.startIndex + row].global)
            for range in highlightedRanges(in: shown.tokens, of: shown.text) { found.append((row, range)) }
        }
        return found
    }

    /// Which occurrence the reader is at, counted from 0, and how many there
    /// are — what the counter in the header says.
    var occurrencePosition: (current: Int?, count: Int) {
        (currentOccurrence, occurrences().count)
    }

    // help: panel.code.occurrences
    /// Goes to the next (or the previous) occurrence of the highlighted name
    /// in the C or the listing on screen: selects it, scrolls to it and
    /// flashes it. From the last it goes round to the first, and the app
    /// shows the plate a wrapped search shows. With none current yet, the
    /// step starts from the caret in the C, or the selected row.
    public func goToOccurrence(forward: Bool) {
        let all = occurrences()
        guard !all.isEmpty else { NSSound.beep(); return }
        var target: Int
        var wrapped = false
        if let current = currentOccurrence, all.indices.contains(current) {
            target = current + (forward ? 1 : -1)
        } else if showsDecompiledC {
            let caret = cTextView.selectedRange().location
            target = forward ? (all.firstIndex { $0.range.location > caret } ?? all.count)
                             : ((all.lastIndex { $0.range.location < caret }) ?? -1)
        } else {
            let selected = state.selectedRow ?? -1
            target = forward ? (all.firstIndex { ($0.row ?? 0) > selected } ?? all.count)
                             : ((all.lastIndex { ($0.row ?? 0) < selected }) ?? -1)
        }
        if target >= all.count { target = 0; wrapped = true }
        if target < 0 { target = all.count - 1; wrapped = true }
        currentOccurrence = target
        show(all[target])
        drawOccurrenceBar()
        if wrapped, all.count > 1 { onWrapOccurrences?(forward) }
    }

    private func show(_ occurrence: Occurrence) {
        if let row = occurrence.row {
            let lines = state.lines
            guard row < lines.count else { return }
            select(line: lines[lines.startIndex + row].global)
            notifyInstruction()
            lastFlash = .row(row)
            flashRow(row)
        } else {
            cTextView.setSelectedRange(occurrence.range)
            cTextView.scrollRangeToVisible(occurrence.range)
            lastFlash = .c(occurrence.range)
            if cTextView.window != nil { cTextView.showFindIndicator(for: occurrence.range) }
        }
    }

    /// Edit ▸ Find Next (⌘G) and Find Previous (⇧⌘G) in the code panel while
    /// a name is highlighted: they step through its occurrences. With nothing
    /// highlighted the pane does not answer them, and they go on to the
    /// window's find in the dump.
    @objc func findNextMatch() { goToOccurrence(forward: true) }
    @objc func findPreviousMatch() { goToOccurrence(forward: false) }

    override public func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(findNextMatch) || aSelector == #selector(findPreviousMatch) {
            return highlightedSymbol != nil && !showsDescription && super.responds(to: aSelector)
        }
        return super.responds(to: aSelector)
    }

    private func makeOccurrenceBar() -> NSStackView {
        occurrenceLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        occurrenceLabel.textColor = .secondaryLabelColor
        for (button, symbol, action) in [
            (previousOccurrenceButton, "chevron.up", #selector(previousOccurrenceClicked)),
            (nextOccurrenceButton, "chevron.down", #selector(nextOccurrenceClicked))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.bezelStyle = .inline
            button.target = self
            button.action = action
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        ControlHelp.describe(previousOccurrenceButton, name: L("Previous Use"),
                             tooltip: L("Go to the previous use of the highlighted name (⇧⌘G)"))
        ControlHelp.describe(nextOccurrenceButton, name: L("Next Use"),
                             tooltip: L("Go to the next use of the highlighted name (⌘G)"))
        let bar = NSStackView(views: [occurrenceLabel, previousOccurrenceButton, nextOccurrenceButton])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 2
        bar.setCustomSpacing(6, after: occurrenceLabel)
        bar.setContentHuggingPriority(.required, for: .horizontal)
        bar.setContentCompressionResistancePriority(.required, for: .horizontal)
        bar.isHidden = true
        return bar
    }

    @objc private func previousOccurrenceClicked() { goToOccurrence(forward: false) }
    @objc private func nextOccurrenceClicked() { goToOccurrence(forward: true) }

    /// The counter beside the ASM/C switch: "3 of 12" and the two arrows,
    /// while a name is highlighted in the side on screen; "12" until the
    /// reader is at one of them.
    private func drawOccurrenceBar() {
        guard let occurrenceBar else { return }
        let count = highlightedSymbol == nil || showsDescription ? 0 : occurrences().count
        occurrenceBar.isHidden = count == 0
        guard count > 0 else { return }
        if let current = currentOccurrence, current < count {
            occurrenceLabel.stringValue = String(format: L("%1$@ of %2$@"), "\(current + 1)", "\(count)")
        } else {
            occurrenceLabel.stringValue = "\(count)"
        }
    }

    /// What the counter says, for tests; nil while it is hidden.
    var occurrenceCounterText: String? {
        occurrenceBar?.isHidden == false ? occurrenceLabel.stringValue : nil
    }

    /// Whether a click jumps to what it is on: ⌘-click, or a double click.
    /// A plain click highlights, as in Xcode.
    static func isJump(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command) || event.clickCount >= 2
    }

    // help: panel.code.highlight
    /// A click in the C: on a name, it highlights the name's every
    /// occurrence; ⌘-click or a double click on a call or a global goes there,
    /// and on the function's own name in its signature shows its callers.
    func clickC(at character: Int?, event: NSEvent) -> Bool {
        let token = character.flatMap { index in
            shownCTokens.filter { $0.start <= index && index < $0.start + $0.length }
                .min { $0.length < $1.length }
        }
        if let token, let link = token.link, Self.isJump(event) {
            let range = NSRange(location: token.start, length: token.length)
            if case .function(let index) = link {
                // ⌘-click on the function's own name in its signature asks
                // who calls it; on a call it goes to the function.
                if range == signatureName()?.range {
                    highlight(.target(link))
                    if callers(of: index).isEmpty { NSSound.beep() } else { showCallers(of: index, at: range) }
                } else {
                    jumpToDefinition(of: index, from: range)
                }
                return true
            }
            leavingCMark = range
            follow(link)
            return true
        }
        let clicked = token.flatMap { symbol(of: $0, in: cTextView.string) }
        highlight(clicked)
        if let token, clicked != nil {
            currentOccurrence = highlightedRangesInC().firstIndex { $0.location == token.start }
            drawOccurrenceBar()
        }
        if let clicked, case .variable = clicked, Self.isJump(event) {
            selectDefinition(of: clicked)
            return true
        }
        // A plain click on the function's own name in its signature asks
        // who calls it, as a click on an explained name asks what it is.
        if !Self.isJump(event), let token, case .function(let index)? = token.link,
           let own = signatureName(), own.function == index,
           own.range == NSRange(location: token.start, length: token.length), !callers(of: index).isEmpty {
            afterClick(inC: true) { [weak self] in
                self?.showCallers(of: index, at: own.range)
            }
            return false
        }
        if !Self.isJump(event), let character { explainC(at: character, token: token) }
        return false
    }

    // MARK: - What a name stands for

    // help: panel.code.explain
    /// A click on a name the review explained — a constant's name, a type, a
    /// field, the line for the blocks the decompiler removed — opens what it stands for beside it. After the click is done:
    /// the text view's own tracking of it would otherwise close the popover.
    private func explainC(at character: Int, token: CodeToken?) {
        guard let index = state.function else { return }
        let local = character - cShift
        var found: (CodeExplanation, NSRange)?
        if let token, Self.explainedInC.contains(token.kind),
           let explained = model.explanation(ofC: CodeToken(start: token.start - cShift, length: token.length,
                                                            kind: token.kind, link: token.link), inFunction: index) {
            found = (explained, NSRange(location: token.start, length: token.length))
        } else if let field = model.field(atC: local, inFunction: index),
                  let explained = model.explanation(ofField: field, inFunction: index) {
            found = (explained, NSRange(location: field.start + cShift, length: field.length))
        }
        guard let (explained, range) = found, let rect = cRect(range) else { return }
        afterClick(inC: true) { [weak self] in
            guard let self else { return }
            self.showExplanation(explained, relativeTo: rect, of: self.cTextView)
            self.explainedInC = range
        }
    }

    /// Runs `show` once the press ends — after the text view's or the table's
    /// own tracking of it — and only if it was a click. A press that became a
    /// drag to select text is not a question about the name it started on:
    /// the popover then stays shut (it opened at the end of every selection
    /// that started on an explained name). A drag is the pointer let go more
    /// than a few points from where it went down, or, in the C, a selection.
    private func afterClick(inC: Bool, _ show: @escaping () -> Void) {
        let down = NSApp.currentEvent.flatMap { $0.type == .leftMouseDown ? $0.locationInWindow : nil }
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            guard let self else { return }
            if inC, self.cTextView.selectedRange().length > 0 { return }
            if let down, let up = NSApp.currentEvent, up.type == .leftMouseUp,
               hypot(up.locationInWindow.x - down.x, up.locationInWindow.y - down.y) > Self.clickSlop {
                return
            }
            show()
        }
    }

    /// How far the pointer may move between press and release for the two to
    /// still be a click.
    static let clickSlop: CGFloat = 3

    /// A click on a number of the listing that the review named: the same
    /// explanation as the name in the C.
    private func explainListing(line: Int, token: CodeToken, text: String, rect: NSRect, in view: NSView) {
        guard token.kind == .constant, let value = Self.listingNumber(text),
              let explained = model.explanation(ofConstant: value, onLine: line) else { return }
        let inTable = table.convert(rect, from: view)
        afterClick(inC: false) { [weak self] in
            guard let self else { return }
            self.showExplanation(explained, relativeTo: inTable, of: self.table)
        }
    }

    /// The kinds of C token a click explains: the names the artifact holds
    /// something about — a constant's name, a type, the removed blocks' line,
    /// a named global, and a p-code operation the processor model named for an
    /// instruction (SIDT written as `InterruptDescriptorTableRegister`).
    /// A field of a structure is found by its place in the C, not by its kind.
    static let explainedInC: Set<CodeToken.Kind> = [.constant, .type, .comment, .global, .pcode]

    /// The names in the C on screen that a click explains: the named
    /// constants and the types the artifact holds, and the fields of those.
    private func explainableInC() -> [NSRange] {
        guard let index = state.function else { return [] }
        var ranges = shownCTokens.compactMap { token -> NSRange? in
            guard Self.explainedInC.contains(token.kind),
                  model.explanation(ofC: CodeToken(start: token.start - cShift, length: token.length,
                                                   kind: token.kind, link: token.link), inFunction: index) != nil
            else { return nil }
            return NSRange(location: token.start, length: token.length)
        }
        for field in model.functions[index].cFields
        where model.explanation(ofField: field, inFunction: index) != nil {
            ranges.append(NSRange(location: field.start + cShift, length: field.length))
        }
        return ranges
    }

    /// The numbers of a listing row that the review named.
    func explainableInListing(_ row: (text: String, tokens: [CodeToken]), line: Int) -> [NSRange] {
        let units = Array(row.text.utf16)
        return row.tokens.compactMap { token in
            guard token.kind == .constant, token.start + token.length <= units.count,
                  let value = Self.listingNumber(String(decoding: units[token.start..<token.start + token.length],
                                                        as: UTF16.self)),
                  model.explanation(ofConstant: value, onLine: line) != nil else { return nil }
            return NSRange(location: token.start, length: token.length)
        }
    }

    /// A number as the listing writes it: `0xcf8`, `-0x1`, `12`.
    static func listingNumber(_ text: String) -> UInt64? {
        var digits = Substring(text.trimmingCharacters(in: .whitespaces))
        let negative = digits.hasPrefix("-")
        if negative { digits = digits.dropFirst() }
        let value: UInt64?
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") {
            value = UInt64(digits.dropFirst(2), radix: 16)
        } else {
            value = UInt64(digits)
        }
        guard let value else { return nil }
        return negative ? UInt64(bitPattern: -Int64(bitPattern: value)) : value
    }

    private func showExplanation(_ explained: CodeExplanation, relativeTo rect: NSRect, of view: NSView) {
        guard view.window != nil else { return }
        explanationPopover?.close()
        explainedInC = nil
        let popover = CodeExplanationPopover(explanation: explained, model: model)
        popover.onUse = { [weak self] line in self?.goToUse(line) }
        popover.show(relativeTo: rect, of: view)
        explanationPopover = popover
    }

    /// A place under the popover's "Used at": a move Back returns from, even
    /// to the instruction already selected — a click in the C selects the
    /// instruction under it, and the use is often that one.
    public func goToUse(_ line: Int) {
        // The name the popover was opened on is the place left: Back selects
        // and flashes it, as it does the call a jump was made from — without
        // it, Back flashed the function's name and scrolled up to it.
        leavingCMark = explainedInC
        follow(.line(line), even: true)
    }

    /// The name in the C the open popover explains; nil for one opened on
    /// the listing.
    private var explainedInC: NSRange?

    /// What the popover open over the code explains, if one is open.
    var shownExplanation: CodeExplanation? {
        guard let explanationPopover, explanationPopover.isShown else { return nil }
        return explanationPopover.explanationShown
    }

    func shownExplanationClose() {
        explanationPopover?.close()
        explanationPopover = nil
    }

    /// Where characters of the C are drawn, in the text view's coordinates.
    private func cRect(_ range: NSRange) -> NSRect? {
        guard let layout = cTextView.layoutManager, let container = cTextView.textContainer,
              range.location + range.length <= (cTextView.string as NSString).length else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += cTextView.textContainerOrigin.x
        rect.origin.y += cTextView.textContainerOrigin.y
        return rect
    }

    /// The function on screen's own name in its signature: the first token
    /// that names it.
    private func signatureName() -> (function: Int, range: NSRange)? {
        guard let index = state.function,
              let own = shownCTokens.first(where: { $0.link == .function(index) }) else { return nil }
        return (index, NSRange(location: own.start, length: own.length))
    }

    /// Jump to Definition on a call in the C at `call`: opens the function
    /// called, a place Back returns from. A recursive call's definition is
    /// the signature above it, selected and flashed without a jump.
    func jumpToDefinition(of index: Int, from call: NSRange) {
        guard index != state.function else {
            guard let own = signatureName()?.range else { return }
            cTextView.setSelectedRange(own)
            flashArrival(cMark: own)
            return
        }
        leavingCMark = call
        follow(.function(index))
    }

    /// ⌘-click or a double click on a parameter or a local selects where it
    /// is defined: its first occurrence, since Ghidra writes the parameters in
    /// the signature and declares every local at the top of the body.
    private func selectDefinition(of symbol: CodeSymbol) {
        let text = cTextView.string
        let first: CodeToken? = shownCTokens.first { token in self.symbol(of: token, in: text) == symbol }
        guard let definition = first else { return }
        let range = NSRange(location: definition.start, length: definition.length)
        cTextView.window?.makeFirstResponder(cTextView)
        cTextView.setSelectedRange(range)
        cTextView.scrollRangeToVisible(range)
    }

    /// A click in the listing: on a reference, it highlights the instructions
    /// that refer to the same place; ⌘-click or a double click goes there.
    /// Anywhere else it clears the highlight. The row is selected either way.
    func clickListing(on link: CodeLink?, event: NSEvent, line: Int? = nil) -> Bool {
        if let link, Self.isJump(event) {
            // The row clicked is the place Back returns to, though the jump
            // leaves before the table selects it.
            if let line, model.lines.indices.contains(line), line != state.line { select(line: line) }
            follow(link)
            return true
        }
        highlight(link.map(CodeSymbol.target))
        if link != nil, let line, let row = state.lines.firstIndex(where: { $0.global == line }) {
            currentOccurrence = listingOccurrences().firstIndex { $0.row == row - state.lines.startIndex }
            drawOccurrenceBar()
        }
        return false
    }

    /// Escape clears the highlight.
    public override func cancelOperation(_ sender: Any?) {
        highlight(nil)
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

extension CodePaneView: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === functionTable ? state.rowCount : state.lines.count
    }

    /// A group's node, and a library kind's, is not a function: it opens and
    /// closes its rows and is not selected.
    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !(tableView === functionTable && state.list == .functions
            && state.functionRow(at: row)?.isHeading == true)
    }

    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === functionTable {
            guard row >= 0, row < state.rowCount else { return nil }
            let functionRow = state.list == .functions ? state.functionRow(at: row) : nil
            if let group = functionRow?.group {
                return groupCell(in: tableView, group: group, row: row)
            }
            if let section = functionRow?.section {
                return sectionCell(in: tableView, section: section, row: row)
            }
            // The by-address table's first column: where the function is.
            if state.list == .functions, tableColumn?.identifier.rawValue == FunctionColumn.address.rawValue,
               let index = functionRow?.function {
                let cell = cell(in: tableView, identifier: .init("code-function-address"), monospaced: true)
                cell.showsDisclosure(false)
                cell.showsIcon(nil)
                cell.showsBadge(false)
                cell.onToggle = nil
                cell.textField?.font = Self.navigatorCodeFont()
                cell.textField?.stringValue = model.displayAddress(model.functions[index].entry)
                cell.textField?.textColor = .secondaryLabelColor
                cell.toolTip = nil
                return cell
            }
            if state.list == .postCodes, let id = tableColumn?.identifier.rawValue,
               let column = PostColumn(rawValue: id) {
                let entry = artifact.postCodes[state.listedPostCodes[row]]
                let cell = cell(in: tableView, identifier: .init("code-post"), monospaced: false)
                cell.textField?.font = postFont(entry, column)
                cell.textField?.stringValue = postCodeCell(entry, column)
                let unknown = entry.value == nil && entry.unresolved != nil
                cell.textField?.textColor = unknown || column == .via || column == .address
                    ? .secondaryLabelColor : .labelColor
                cell.toolTip = postCodeDetail(entry)
                return cell
            }
            if state.list == .strings, let id = tableColumn?.identifier.rawValue,
               let column = StringColumn(rawValue: id) {
                let entry = artifact.strings[state.listedStrings[row]]
                let cell = cell(in: tableView, identifier: .init("code-string"), monospaced: false)
                let text = stringCell(entry, column)
                cell.textField?.font = column == .address ? Self.navigatorCodeFont() : Self.navigatorFont()
                cell.textField?.stringValue = text
                cell.textField?.textColor = column == .address ? .secondaryLabelColor : .labelColor
                // The whole string, which the column may have cut.
                cell.toolTip = column == .text && !text.isEmpty ? text : nil
                return cell
            }
            let cell = cell(in: tableView, identifier: .init("code-navigator"), monospaced: false)
            // A cell from the queue was made at the size before a zoom.
            cell.textField?.font = Self.navigatorFont()
            cell.textField?.stringValue = navigatorText(at: row)
            // The triangle belongs to a function of the call tree; the badge
            // to a function a revision changed. Both are set per row, and a
            // reused cell must not keep either.
            cell.showsDisclosure(false)
            cell.showsIcon(nil)
            cell.onToggle = nil
            cell.showsBadge(false)
            // A name the module's own evidence gave reads as a name; Ghidra's
            // FUN_ placeholder reads quieter. The reason is one hover away.
            var color = NSColor.labelColor
            var reason: String?
            if state.list == .functions, let functionRow, let index = functionRow.function {
                let function = model.functions[index]
                if function.hasPlaceholderName { color = .secondaryLabelColor }
                reason = function.nameReason
                // In the grouped order the hover also says where the review
                // stands: its level, and what still keeps it from full.
                if state.functionOrder == .review {
                    reason = [reason, Self.reviewDetail(function)]
                        .compactMap { $0 }.joined(separator: "\n")
                }
                // help: panel.code.registry
                // A function the library registry matched says so wherever
                // it is listed.
                if let registry = Self.registryDetail(function) {
                    reason = [reason, registry].compactMap { $0 }.joined(separator: "\n")
                }
                // A call tree's rows stand in as deep as they are; a deeper
                // level keeps the last one's inset rather than running the
                // name off the pane. A group's functions start under its
                // name, past its chevron and a step beyond its mark, as a
                // source list nests its items; a library kind's, a step
                // further under the kind.
                if state.functionOrder == .review, state.searchText.isEmpty {
                    cell.indent = CodeNavigatorCell.disclosureRoom
                        + Self.groupMemberIndent * CGFloat(functionRow.level)
                } else {
                    cell.indent = CGFloat(min(functionRow.level, Self.navigatorLevels)) * Self.navigatorIndent
                }
                // The mark says how far the review has got, in every order: a
                // root of the tree and a call under it alike.
                cell.showsIcon(Self.functionMark(state.group(of: index),
                                                 library: state.librarySection(of: index),
                                                 registry: state.registryMark(of: index)))
                if unopenedChanges.contains(index) {
                    cell.textField?.font = Self.navigatorBoldFont()
                    cell.badge.text = L("New")
                    cell.showsBadge(true)
                }
                // A search is one alphabetical list of what it found: the
                // calls it would open say nothing about a find.
                if state.functionOrder == .calls, state.searchText.isEmpty {
                    let expandable = state.hasCalls(index)
                    let expanded = state.isExpanded(index)
                    cell.showsDisclosure(true)
                    cell.showsCalls(expandable: expandable, expanded: expanded)
                    ControlHelp.describe(cell.disclosure,
                                         expanded ? L("Hide calls") : L("Show calls"))
                    cell.onToggle = { [weak self] in self?.toggleCalls(of: index) }
                }
            }
            if state.list == .postCodes {
                let entry = artifact.postCodes[state.listedPostCodes[row]]
                if entry.value == nil, entry.unresolved != nil { color = .secondaryLabelColor }
                reason = postCodeDetail(entry)
            }
            cell.textField?.textColor = color
            cell.toolTip = reason
            if state.list == .functions, let index = functionRow?.function,
               let notes = notesByFunction[index], !notes.isEmpty,
               let field = cell.textField {
                let marked = NSMutableAttributedString(string: field.stringValue, attributes: [
                    .foregroundColor: color, .font: field.font ?? Self.navigatorFont()
                ])
                marked.append(NSAttributedString(string: "  ◆", attributes: [
                    .foregroundColor: CodeColors.color(for: notes[0].kind), .font: field.font ?? Self.navigatorFont()
                ]))
                field.attributedStringValue = marked
                cell.toolTip = ([reason].compactMap { $0 } + notes.map(\.heading)).joined(separator: "\n")
            }
            return cell
        }
        let lines = state.lines
        guard row >= 0, row < lines.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("code-line")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? CodeLineCell
            ?? CodeLineCell(identifier: identifier)
        let global = lines[lines.startIndex + row].global
        var shown = model.listingRow(ofLine: global)
        // An annotated instruction carries its note at the end of the row.
        for note in notesByLine[global] ?? [] {
            let mark = "    ◆ \(note.heading)"
            shown.tokens.append(CodeToken(start: shown.text.utf16.count + 4,
                                          length: mark.utf16.count - 4, kind: note.kind))
            shown.text += mark
        }
        cell.line.show(shown.text, tokens: shown.tokens, font: Self.codeFont(),
                       highlighted: highlightedRanges(in: shown.tokens, of: shown.text),
                       explainable: explainableInListing((shown.text, shown.tokens), line: global))
        cell.line.onClick = { [weak self] link, event in
            self?.clickListing(on: link, event: event, line: global) ?? false
        }
        cell.line.onExplain = { [weak self, weak view = cell.line] token, text, rect in
            guard let self, let view else { return }
            self.explainListing(line: global, token: token, text: text, rect: rect, in: view)
        }
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection, let table = notification.object as? NSTableView else { return }
        if table === functionTable {
            let row = functionTable.selectedRow
            guard row >= 0 else { return }
            leaveDescription()
            selectNavigatorRow(row)
        } else if table === self.table {
            let lines = state.lines
            let row = table.selectedRow
            guard row >= 0, row < lines.count else { return }
            select(line: lines[lines.startIndex + row].global)
            notifyInstruction()
        }
    }

    private func navigatorText(at row: Int) -> String {
        switch state.list {
        case .functions:
            guard let index = state.function(atRow: row) else { return "" }
            let function = model.functions[index]
            return function.name.isEmpty ? model.displayAddress(function.entry) : function.name
        case .strings:
            let entry = artifact.strings[state.listedStrings[row]]
            return entry.value.isEmpty
                ? stringCell(entry, .address)
                : "\(stringCell(entry, .address))  \(stringCell(entry, .text))"
        case .postCodes:
            return postCodeText(artifact.postCodes[state.listedPostCodes[row]])
        case .statusCodes:
            let entry = artifact.statusCodeCalls[state.listedStatusCodes[row]]
            return "\(model.displayAddress(entry.address))  \(entry.text)"
        }
    }

    /// What a string's row says in one column. The text is one line: a line
    /// break, a tab or another control character in it is written as C
    /// writes it — the strings are mostly C's own format strings — so a row
    /// never runs onto the next.
    func stringCell(_ entry: CodeArtifact.StringEntry, _ column: StringColumn) -> String {
        switch column {
        case .address: return model.displayAddress(entry.address)
        case .text: return Self.oneLine(entry.value)
        }
    }

    static func oneLine(_ text: String) -> String {
        var line = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": line += "\\n"
            case "\r": line += "\\r"
            case "\t": line += "\\t"
            case "\0"..<" ", "\u{7F}"..."\u{9F}":
                line += String(format: "\\x%02X", scalar.value)
            case "\u{2028}", "\u{2029}":
                line += String(format: "\\u%04X", scalar.value)
            default: line.unicodeScalars.append(scalar)
            }
        }
        return line
    }

    // help: panel.code.post-codes
    /// A POST code's row: the value, at the width it is written, and the
    /// function that sends it. One the analysis could not tell says what it
    /// lacks. An artifact before v5 lists its OUT instructions as they read.
    private func postCodeText(_ entry: CodeArtifact.PostCode) -> String {
        guard entry.value != nil || entry.unresolved != nil else {
            return "\(model.displayAddress(entry.address))  \(entry.text)"
        }
        let place = postCodeCell(entry, .function)
        return postCodeCell(entry, .code) + "  " + (place.isEmpty ? model.displayAddress(entry.address) : place)
    }

    /// What a POST code's row says on hover: where it is sent, through what,
    /// and why a value is missing.
    private func postCodeDetail(_ entry: CodeArtifact.PostCode) -> String? {
        guard entry.value != nil || entry.unresolved != nil else { return nil }
        var lines = [String(format: L("Sent at %1$@"), model.displayAddress(entry.address))]
        if !entry.via.isEmpty {
            lines.append(String(format: L("Through %1$@"),
                                entry.via.map { $0.name ?? model.displayAddress($0.function) }.joined(separator: " → ")))
        }
        if let width = entry.width {
            lines.append(String(format: L("%1$@-byte write to port %2$@"), "\(width)",
                                entry.portNumber.map { String(format: "0x%llX", $0) } ?? "?"))
        }
        switch entry.unresolved {
        case .portParameter: lines.append(L("The port comes from a caller this module does not show: a service other modules call."))
        case .portComputed: lines.append(L("The port is worked out at run time."))
        case .valueParameter: lines.append(L("The value comes from a caller this module does not show."))
        case .valueComputed: lines.append(L("The value is worked out at run time: from a table, a loop or a read."))
        case nil: break
        }
        return lines.joined(separator: "\n")
    }

    /// A row's cell, reused from the table's queue when it has one: a listing
    /// of a large function scrolls through thousands of rows.
    private func cell(in tableView: NSTableView, identifier: NSUserInterfaceItemIdentifier,
                      monospaced: Bool) -> CodeNavigatorCell {
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil)
            as? CodeNavigatorCell {
            // A cell from the queue was inset by the row that used it before,
            // and keeps the triangle and the badge of whatever list it was
            // drawn in: both belong to a function row alone.
            reused.indent = 0
            reused.showsDisclosure(false)
            reused.showsIcon(nil)
            reused.showsBadge(false)
            reused.onToggle = nil
            return reused
        }
        let cell = CodeNavigatorCell(identifier: identifier)
        cell.textField?.font = monospaced ? Self.navigatorCodeFont() : Self.navigatorFont()
        return cell
    }

    /// A node of the grouped order: the group's name and how many functions it
    /// holds, in the panel's grey and one weight up from the rows under it,
    /// with the triangle that opens and closes those rows.
    private func groupCell(in tableView: NSTableView, group: FunctionGroup, row: Int) -> NSView {
        let cell = cell(in: tableView, identifier: .init("code-group"), monospaced: false)
        cell.textField?.font = .systemFont(ofSize: Self.navigatorSize, weight: .semibold)
        cell.textField?.textColor = .secondaryLabelColor
        cell.textField?.stringValue = Self.title(of: group)
            + " (\(state.groupCount(at: row) ?? 0))"
        cell.showsIcon("group.\(group)")
        cell.showsBadge(false)
        cell.indent = 0
        cell.showsDisclosure(true)
        let expanded = state.isGroupExpanded(group)
        cell.showsCalls(expandable: true, expanded: expanded)
        ControlHelp.describe(cell.disclosure,
                             expanded ? L("Hide functions") : L("Show functions"))
        cell.toolTip = nil
        cell.onToggle = { [weak self] in self?.toggleGroup(group) }
        return cell
    }

    /// A library kind's node under Library functions: its name and how many
    /// functions it holds, set in under the group with the kind's badge, and
    /// the chevron that opens and closes them.
    private func sectionCell(in tableView: NSTableView, section: LibrarySection, row: Int) -> NSView {
        let cell = cell(in: tableView, identifier: .init("code-section"), monospaced: false)
        cell.textField?.font = .systemFont(ofSize: Self.navigatorSize, weight: .semibold)
        cell.textField?.textColor = .secondaryLabelColor
        let count = state.groupCount(at: row) ?? 0
        let entries = state.registryCount(at: row) ?? 0
        cell.textField?.stringValue = entries > 0
            ? L("%1$@ (%2$@, %3$@ in the registry)", Self.title(of: section), String(count), String(entries))
            : Self.title(of: section) + " (\(count))"
        cell.showsIcon("library.\(section)")
        cell.showsBadge(false)
        cell.indent = Self.groupMemberIndent
        cell.showsDisclosure(true)
        let expanded = state.isSectionExpanded(section)
        cell.showsCalls(expandable: true, expanded: expanded)
        ControlHelp.describe(cell.disclosure,
                             expanded ? L("Hide functions") : L("Show functions"))
        cell.toolTip = nil
        cell.onToggle = { [weak self] in self?.toggleSection(section) }
        return cell
    }

    /// Opens or closes a library kind's functions.
    private func toggleSection(_ section: LibrarySection) {
        foldRows { $0.toggleSectionExpanded(section) }
        if let row = (0..<state.rowCount).first(where: { state.functionRow(at: $0)?.section == section }) {
            describeDisclosure(at: row, state.isSectionExpanded(section) ? L("Hide functions") : L("Show functions"))
        }
    }

    /// Opens or closes a review group's functions.
    private func toggleGroup(_ group: FunctionGroup) {
        foldRows { $0.toggleGroupExpanded(group) }
        if let row = (0..<state.rowCount).first(where: { state.functionRow(at: $0)?.group == group }) {
            describeDisclosure(at: row, state.isGroupExpanded(group) ? L("Hide functions") : L("Show functions"))
        }
    }

}

/// A navigator row's cell. A call tree's function starts further in the deeper
/// it is — the indent is the row's, so a reused cell takes the next row's —
/// and one whose calls the tree holds carries the triangle that opens them.
/// A function that changed in a revision the panel received reads bold, with
/// **New** in a capsule until the reader opens it.
final class CodeNavigatorCell: NSTableCellView {
    let disclosure = CodeDisclosureButton()
    let icon = NSImageView()
    let badge = PartBadgeView(text: "")
    /// What the row's mark stands for — `function`, or `group.<level>` —
    /// for a test to read.
    private(set) var iconName: String?
    private var leading: NSLayoutConstraint!
    private var disclosureWidth: NSLayoutConstraint!
    private var disclosureGap: NSLayoutConstraint!
    private var iconWidth: NSLayoutConstraint!
    private var iconGap: NSLayoutConstraint!
    private var fieldToEdge: NSLayoutConstraint!
    private var fieldToBadge: NSLayoutConstraint!
    /// What the triangle does, for the row it is drawn in.
    var onToggle: (() -> Void)?
    /// How far the row starts past the cell's own edge, in points.
    var indent: CGFloat = 0 {
        didSet { leading.constant = 4 + indent }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // A chevron that turns down as the row opens.
        disclosure.target = self
        disclosure.action = #selector(toggle)
        disclosure.translatesAutoresizingMaskIntoConstraints = false

        // Decorative: the name beside it is what the row is.
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false

        badge.font = .systemFont(ofSize: 9, weight: .semibold)
        badge.ink = .controlAccentColor
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        textField = field
        for subview in [disclosure, icon, field, badge] { addSubview(subview) }
        leading = disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        disclosureWidth = disclosure.widthAnchor.constraint(equalToConstant: 13)
        disclosure.heightAnchor.constraint(equalToConstant: 13).isActive = true
        disclosureGap = icon.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 0)
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 16)
        iconGap = field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4)
        fieldToEdge = field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        fieldToBadge = field.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -4)
        NSLayoutConstraint.activate([
            leading,
            disclosureWidth,
            disclosureGap,
            iconWidth,
            iconGap,
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        showsDisclosure(false)
        showsIcon(nil)
        showsBadge(false)
    }

    /// The mark the row carries, drawn again when the row is selected or
    /// let go.
    private var mark: (glyph: CodeNavigatorIcon.Glyph, color: NSColor)?

    /// A selected row draws its mark inverted: on the selection's colour the
    /// mark's own colour would not read.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { drawMark() } }
    }

    private func drawMark() {
        let side = CodeNavigatorIcon.side(forFontSize: CodePaneView.navigatorSize)
        icon.image = mark.map {
            CodeNavigatorIcon.image($0.glyph, color: $0.color, side: side,
                                    inverted: backgroundStyle == .emphasized)
        }
    }

    /// The room the chevron and its gap take before a row's mark.
    static let disclosureRoom: CGFloat = 13 + 4

    /// Makes room for the disclosure column — the call tree alone. The room
    /// stays for a function without calls, so names line up under names.
    func showsDisclosure(_ shows: Bool) {
        disclosureWidth.constant = shows ? 13 : 0
        disclosureGap.constant = shows ? 4 : 0
        if !shows { disclosure.isHidden = true }
    }

    /// The triangle's own state for a row: a function with calls shows it,
    /// open or closed; one without shows nothing in the room kept for it.
    func showsCalls(expandable: Bool, expanded: Bool) {
        disclosure.isHidden = !expandable
        disclosure.setOpen(expanded, animated: false)
    }

    /// The row's mark: a function's `f`, or a review group's level, each a
    /// glyph on a coloured square. Nil for a row that is not a function.
    func showsIcon(_ name: String?) {
        iconName = name
        let mark: (glyph: CodeNavigatorIcon.Glyph, color: NSColor)? = switch name {
        case "function"?: CodeNavigatorIcon.function
        case "function.partial"?: CodeNavigatorIcon.partialFunction
        case let name? where name.hasPrefix("library."):
            CodeReaderState.LibrarySection.allCases.lazy.compactMap { section -> (glyph: CodeNavigatorIcon.Glyph, color: NSColor)? in
                let badge = CodePaneView.badge(of: section)
                switch name {
                case "library.\(section)": return CodeNavigatorIcon.library(badge)
                case "library.\(section).entry": return CodeNavigatorIcon.library(badge, style: .filled)
                case "library.\(section).matched": return CodeNavigatorIcon.library(badge, style: .dotted)
                default: return nil
                }
            }.first
        case let name? where name.hasPrefix("group."):
            CodeReaderState.FunctionGroup.allCases
                .first { "group.\($0)" == name }
                .map(CodeNavigatorIcon.group)
        default: nil
        }
        self.mark = mark
        let side = CodeNavigatorIcon.side(forFontSize: CodePaneView.navigatorSize)
        drawMark()
        icon.isHidden = mark == nil
        iconWidth.constant = mark.map { CodeNavigatorIcon.width(of: $0.glyph, side: side) } ?? 0
        iconGap.constant = mark == nil ? 0 : 5
    }

    /// The capsule a revision puts on a function it changed.
    func showsBadge(_ shows: Bool) {
        badge.isHidden = !shows
        fieldToBadge.isActive = shows
        fieldToEdge.isActive = !shows
    }

    /// The click has already flipped the button's state: the chevron turns
    /// to it, and the rows follow.
    @objc private func toggle() {
        disclosure.setOpen(disclosure.state == .on, animated: true)
        onToggle?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// The bar under the navigator's list: the panel's background and a hairline
/// over it, where the list scrolls under — Xcode's filter bar.
/// One of the navigator's function-view buttons: a flat symbol, with a plate
/// behind the one whose layout is in front.
///
/// The three layouts are three buttons, not the segments of one control: the
/// bar reads as a row of separate buttons, and a segmented control would draw
/// them as a single joined frame with dividers — chrome the bar does not have.
/// The plate is drawn rather than left to the bezel, because a bordered button
/// would box every symbol whether or not it is the one in front.
final class CodeOrderButton: NSButton {
    /// Whether this button's layout is the one shown. The button's own state
    /// follows it, which is what a screen reader reads as selected.
    var isChosen: Bool = false {
        didSet {
            guard isChosen != oldValue else { return }
            state = isChosen ? .on : .off
            contentTintColor = isChosen ? .controlAccentColor : .secondaryLabelColor
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isChosen {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                         xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class CodeNavigatorBar: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.minX, y: isFlipped ? bounds.minY : bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class CodeDumpBar: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
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

/// The listing's row: a table cell around one clickable line of code.
final class CodeLineCell: NSTableCellView {
    let line = CodeLineView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

extension CodePaneView: NSMenuItemValidation {
    /// Edit ▸ Copy (⌘C) with the list of functions in focus copies the
    /// selected function's name. The C copies its own selection, and the
    /// header's name is a selectable field.
    @objc public func copy(_ sender: Any?) {
        guard let name = copyableFunctionName else { return }
        Self.copyToPasteboard(name)
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) { return copyableFunctionName != nil }
        return true
    }

    /// The selected function's name, while the list of functions has the
    /// keyboard.
    var copyableFunctionName: String? {
        guard window?.firstResponder === functionTable, state.list == .functions else { return nil }
        let row = functionTable.selectedRow
        guard row >= 0, let index = state.function(atRow: row) else { return nil }
        return model.functions[index].name
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension CodePaneView: NSMenuDelegate {
    /// The right-click menu of the function list and the listing, filled for
    /// the row clicked: Add Annotation…, and Open Annotation for each note
    /// already there.
    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    /// The place the right-click is on, and the notes there.
    func clickedPlace(in tableView: NSTableView) -> (location: CodeLocation, name: String, notes: [CodeNote])? {
        let row = tableView.clickedRow
        guard row >= 0 else { return nil }
        if tableView === functionTable {
            guard state.list == .functions, let index = state.function(atRow: row) else { return nil }
            let function = model.functions[index]
            let onFunction = (notesByFunction[index] ?? []).filter { $0.location.address == nil }
            return (CodeLocation(function: function.entry), function.name, onFunction)
        }
        let lines = state.lines
        guard row < lines.count else { return nil }
        let line = lines[lines.startIndex + row]
        let function = model.functions[line.function]
        return (CodeLocation(function: function.entry, address: line.instruction.address),
                "\(function.name) @ \(model.displayAddress(line.instruction.address))",
                notesByLine[line.global] ?? [])
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let tableView = menu === functionTable.menu ? functionTable : table
        guard let place = clickedPlace(in: tableView) else { return }
        if tableView === functionTable {
            // help: panel.code.copy-name
            let copy = menu.addItem(withTitle: L("Copy Name"), action: #selector(copyNameChosen(_:)),
                                    keyEquivalent: "")
            copy.target = self
            copy.representedObject = place.name
            menu.addItem(.separator())
        }
        for note in place.notes {
            let item = menu.addItem(withTitle: L("Open Annotation “%1$@”", note.title),
                                    action: #selector(openNoteChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = note.id
        }
        guard onAnnotate != nil else { return }
        // help: panel.code.annotate
        let add = menu.addItem(withTitle: L("Add Annotation…"), action: #selector(annotateChosen(_:)),
                               keyEquivalent: "")
        add.target = self
        add.representedObject = CodePlaceBox(location: place.location, name: place.name)
    }

    /// The menu of a function's name — in the header, in the C: Show
    /// Callers, off when nothing calls it.
    /// `call` is the name's range in the C when the name is a call: then
    /// Jump to Definition, what ⌘-click and a double click on it do, comes
    /// first.
    func functionMenu(for index: Int?, call: NSRange? = nil, name: NSRange? = nil) -> NSMenu? {
        guard let index, model.functions.indices.contains(index) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let call {
            let jump = menu.addItem(withTitle: L("Jump to Definition"), action: #selector(jumpToDefinitionChosen(_:)),
                                    keyEquivalent: "")
            jump.target = self
            jump.representedObject = CodeCallBox(function: index, range: call)
        }
        let item = menu.addItem(withTitle: L("Show Callers…"), action: #selector(showCallersChosen(_:)),
                                keyEquivalent: "")
        item.target = self
        item.representedObject = name.map { CodeCallBox(function: index, range: $0) } ?? NSNumber(value: index)
        item.isEnabled = !callers(of: index).isEmpty
        return menu
    }

    /// The C's right-click menu: a function's on a function's name, Copy on
    /// a selection, nothing elsewhere.
    func cMenu(at character: Int?) -> NSMenu? {
        let token = character.flatMap { index in
            shownCTokens.filter { $0.start <= index && index < $0.start + $0.length }
                .min { $0.length < $1.length }
        }
        if let token, case .function(let index)? = token.link {
            let range = NSRange(location: token.start, length: token.length)
            return functionMenu(for: index, call: range == signatureName()?.range ? nil : range, name: range)
        }
        guard cTextView.selectedRange().length > 0 else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "")
            .target = cTextView
        return menu
    }

    @objc private func jumpToDefinitionChosen(_ sender: NSMenuItem) {
        guard let call = sender.representedObject as? CodeCallBox else { return }
        jumpToDefinition(of: call.function, from: call.range)
    }

    @objc private func showCallersChosen(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? CodeCallBox {
            showCallers(of: name.function, at: name.range)
        } else if let index = (sender.representedObject as? NSNumber)?.intValue {
            showCallers(of: index)
        }
    }

    @objc private func copyNameChosen(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Self.copyToPasteboard(name)
    }

    @objc private func openNoteChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onOpenNote?(id)
    }

    @objc private func annotateChosen(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CodePlaceBox else { return }
        onAnnotate?(box.location, box.name)
    }
}

/// Jump to Definition's call: the function called, and where in the C.
private final class CodeCallBox: NSObject {
    let function: Int
    let range: NSRange

    init(function: Int, range: NSRange) {
        self.function = function
        self.range = range
    }
}

/// A menu item's place in the code.
private final class CodePlaceBox: NSObject {
    let location: CodeLocation
    let name: String

    init(location: CodeLocation, name: String) {
        self.location = location
        self.name = name
    }
}

/// The header's function name: selectable, so it can be copied, with the
/// function's own right-click menu in place of the text field's — also while
/// it is selected, when the field editor is what the click lands on.
/// An image that stands in a line of text by its middle: the line aligns by
/// baseline, and an image's own baseline is its bottom edge, which would put
/// it above the words. Its middle sits at the middle of the capitals of
/// `lineFont`.
final class CodeBaselineImageView: NSImageView {
    var lineFont: NSFont = .systemFont(ofSize: NSFont.systemFontSize) {
        didSet { invalidateIntrinsicContentSize() }
    }

    private var height: CGFloat { image?.size.height ?? 0 }

    override var firstBaselineOffsetFromTop: CGFloat { height / 2 + lineFont.capHeight / 2 }
    override var lastBaselineOffsetFromBottom: CGFloat { height / 2 - lineFont.capHeight / 2 }
    override var baselineOffsetFromBottom: CGFloat { lastBaselineOffsetFromBottom }
}

final class CodeTitleField: NSTextField {
    var onMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu?() ?? super.menu(for: event)
    }

    /// The field editor's menu, while the name is selected: the function's,
    /// with Copy first, so the selection can still be copied.
    @objc func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard let own = onMenu?() else { return menu }
        if textView.selectedRange().length > 0 {
            own.insertItem(.separator(), at: 0)
            let copy = NSMenuItem(title: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "")
            copy.target = textView
            own.insertItem(copy, at: 0)
        }
        return own
    }
}
