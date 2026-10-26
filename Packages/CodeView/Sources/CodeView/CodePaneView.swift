import ALSplitView
import AppKit
import CodeAnalysis
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

    /// A place in the code Back and Forward return to.
    private struct Place: Equatable {
        var function: Int
        var line: Int?
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
    private let callersButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    /// The places the reader went to, oldest first, and which one is current:
    /// Back and Forward walk it as in an IDE. A jump — a click on a call, a
    /// caller, a function in the list — adds a place; moving inside one
    /// function only moves the current one.
    private var history: [Place] = []
    private var historyIndex = -1
    /// Which link each `code:N` in the C text is.
    private var cLinks: [CodeLink] = []
    private var drawnC: Int?
    private let referencesRow = NSStackView()
    private let table = NSTableView()
    private let tableScroll = NSScrollView()
    private let cTextView = NSTextView()
    private let cScroll = NSScrollView()
    private let modeControl: NSSegmentedControl
    private let recipePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private var recipePopUpCollapsed: NSLayoutConstraint?
    private let codeContent = NSView()
    private let rightSplit = ALSplitView()
    private let hexDumpBar = CodeDumpBar()
    private let hexDumpButton = NSButton()
    private let moduleHexView: NSView
    private var hexDumpVisible = true
    private static let hexDumpHeight: CGFloat = 220
    private static let dumpBarHeight: CGFloat = 24
    private let staleLabel = NSTextField(labelWithString: "")
    /// Set while the view moves a table's selection itself, so the table's
    /// delegate does not take the move for a click.
    private var syncingSelection = false

    /// An instruction's bytes from a listing click. The app selects them in
    /// the hex view.
    public var onSelectRange: ((Range<UInt64>) -> Void)?
    /// A function's whole stored range, shown as the dump's main zone rather
    /// than as a selection: the reader keeps the selection for reading bytes.
    public var onFocusRange: ((Range<UInt64>) -> Void)?
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
        self.moduleHexView = hexView
        var allRecipes = [manifest]
        for recipe in recipes where !allRecipes.contains(where: { $0.recipe.id == recipe.recipe.id }) {
            allRecipes.append(recipe)
        }
        self.recipes = allRecipes
        // ASM and C are names of formats, not words to translate.
        modeControl = NSSegmentedControl(
            labels: ["ASM", "C"], trackingMode: .selectOne,
            target: nil, action: nil)
        listControl = NSSegmentedControl(
            labels: [L("Functions"), L("Strings"), L("POST"), L("Status")],
            trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        build(hexView: moduleHexView)
        drawNavigator()
        drawSelection()
        resetHistory()
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

    public var showsDecompiledC: Bool { modeControl.selectedSegment == 1 }
    /// The analyses the header can offer, the chosen one first.
    public var offeredRecipes: [AnalysisManifest] { recipes }

    /// Chooses one of `offeredRecipes`; the app loads its artifact and rebuilds
    /// the screen.
    public func chooseRecipe(at index: Int) {
        guard recipes.indices.contains(index),
              recipes[index].recipe.id != manifest.recipe.id else { return }
        onChooseRecipe?(recipes[index])
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
    public func restore(function: Int?, instruction: Int?, showsC: Bool) {
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

    private func title(for list: List) -> String {
        switch list {
        case .functions: L("Functions")
        case .strings: L("Strings")
        case .postCodes: L("POST writes")
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

    /// The callers and callees of the selected function, as short menus: a
    /// target is one click away, and an address with no function still names
    /// itself rather than disappearing.
    private func updateReferences() {
        guard let function = state.selectedFunction else {
            referencesRow.isHidden = true
            return
        }
        // The callees are in the code itself: every call is a link there.
        fill(callersButton, title: L("Callers"), with: function.callers)
        referencesRow.isHidden = function.callers.isEmpty
    }

    private func fill(_ button: NSPopUpButton, title: String,
                      with addresses: [CodeAddress]) {
        button.removeAllItems()
        let heading = NSMenuItem(title: "\(title) (\(addresses.count))",
                                 action: nil, keyEquivalent: "")
        button.menu?.addItem(heading)
        for address in addresses {
            let item = NSMenuItem(title: model.name(for: address),
                                  action: #selector(callTargetChosen(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: address.value)
            button.menu?.addItem(item)
        }
    }

    @objc private func callTargetChosen(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        navigate(to: CodeAddress(number.uint64Value))
    }

    /// A reference goes to the function at its target when there is one, or to
    /// the bytes there when the module holds them. An external target does
    /// nothing rather than pretending to go somewhere.
    private func navigate(to address: CodeAddress) {
        if let link = model.link(to: address) { follow(link) }
    }

    // MARK: - Following links, and the way back

    /// A click on a call, a jump's label or a global — in the C or the
    /// listing — goes where it names, as in an IDE: a function opens with its
    /// range as the dump's main zone, an instruction is selected with its
    /// bytes, data selects its bytes in the hex view. The first two are
    /// places Back returns from.
    func follow(_ link: CodeLink) {
        switch link {
        case .function(let index):
            jump { selectFunction(at: index) }
        case .line(let line):
            jump {
                select(line: line)
                notifyInstruction()
            }
        case .bytes(let address):
            if let range = dataRange(at: address) { onSelectRange?(range) }
        }
    }

    /// The bytes a click on a global selects: a GUID's 16, a pointer's width,
    /// or the one byte at the address when the artifact does not say.
    private func dataRange(at address: CodeAddress) -> Range<UInt64>? {
        let symbol = artifact.symbols.first { $0.address == address }
        var count = 1
        if let type = symbol?.type {
            if type == "EFI_GUID" { count = 16 }
            else if type.hasSuffix("*") { count = (artifact.program?.is64Bit ?? false) ? 8 : 4 }
        }
        return model.moduleRange(of: address, count: count) ?? model.moduleRange(of: address, count: 1)
    }

    private var currentPlace: Place? {
        state.function.map { Place(function: $0, line: state.line) }
    }

    /// Moves somewhere new: the place left is kept, what was ahead of it is
    /// dropped, and the new place becomes the current one.
    private func jump(_ move: () -> Void) {
        if historyIndex >= 0, let place = currentPlace { history[historyIndex] = place }
        move()
        guard let place = currentPlace else { return }
        if historyIndex >= 0, history[historyIndex].function == place.function,
           history[historyIndex].line == place.line { return }
        history = Array(history.prefix(historyIndex + 1)) + [place]
        historyIndex = history.count - 1
        updateHistoryButtons()
    }

    private func resetHistory() {
        history = currentPlace.map { [$0] } ?? []
        historyIndex = history.count - 1
        updateHistoryButtons()
    }

    /// Back: the place before the last jump. View ▸ Back (⌘[) calls this
    /// while the code pane has the keyboard.
    public func goBack() {
        guard canGoBack else { return }
        if let place = currentPlace { history[historyIndex] = place }
        historyIndex -= 1
        go(to: history[historyIndex])
    }

    public func goForward() {
        guard canGoForward else { return }
        if let place = currentPlace { history[historyIndex] = place }
        historyIndex += 1
        go(to: history[historyIndex])
    }

    private func go(to place: Place) {
        selectFunction(at: place.function)
        if let line = place.line, model.lines.indices.contains(line) {
            select(line: line)
            notifyInstruction()
        }
        updateHistoryButtons()
    }

    private func updateHistoryButtons() {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
    }

    @objc private func goBackClicked() { goBack() }
    @objc private func goForwardClicked() { goForward() }

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
            let function = state.listedFunctions[row]
            jump { selectFunction(at: function) }
            return
        case .strings:
            range = model.moduleRange(of: artifact.strings[state.listedStrings[row]])
        case .postCodes:
            range = model.moduleRange(
                of: artifact.postCodes[state.listedPostCodes[row]].address, count: 1)
        case .statusCodes:
            range = model.moduleRange(
                of: artifact.statusCodeCalls[state.listedStatusCodes[row]].address, count: 1)
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

        searchField.placeholderString = L("Search")
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        configure(functionTable, identifier: "function")
        functionScroll.documentView = functionTable
        functionScroll.hasVerticalScroller = true
        functionScroll.drawsBackground = false
        functionScroll.translatesAutoresizingMaskIntoConstraints = false

        let functionPane = NSView()
        functionPane.translatesAutoresizingMaskIntoConstraints = false
        functionPane.addSubview(navigatorLabel)
        functionPane.addSubview(listControl)
        functionPane.addSubview(searchField)
        functionPane.addSubview(functionScroll)
        NSLayoutConstraint.activate([
            navigatorLabel.leadingAnchor.constraint(equalTo: functionPane.leadingAnchor, constant: 12),
            navigatorLabel.trailingAnchor.constraint(equalTo: functionPane.trailingAnchor, constant: -8),
            navigatorLabel.topAnchor.constraint(equalTo: functionPane.topAnchor, constant: 12),
            listControl.topAnchor.constraint(equalTo: navigatorLabel.bottomAnchor, constant: 6),
            listControl.leadingAnchor.constraint(equalTo: functionPane.leadingAnchor, constant: 8),
            listControl.trailingAnchor.constraint(equalTo: functionPane.trailingAnchor, constant: -8),
            searchField.topAnchor.constraint(equalTo: listControl.bottomAnchor, constant: 6),
            searchField.leadingAnchor.constraint(equalTo: functionPane.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: functionPane.trailingAnchor, constant: -8),
            functionScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            functionScroll.leadingAnchor.constraint(equalTo: functionPane.leadingAnchor, constant: 8),
            functionScroll.trailingAnchor.constraint(equalTo: functionPane.trailingAnchor, constant: -8),
            functionScroll.bottomAnchor.constraint(equalTo: functionPane.bottomAnchor, constant: -8)
        ])

        codeContent.wantsLayer = true
        applyCodeBackground()

        let titleLabel = label(L("Code analysis"), font: ToolPanelFont.title())
        let nameLabel = label(
            manifest.module.name.isEmpty ? manifest.recipe.id : manifest.module.name,
            font: ToolPanelFont.body(weight: .medium))
        let recipeLabel = label(recipeSummary(), font: ToolPanelFont.body(),
                                color: .secondaryLabelColor)
        recipeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        recipeLabel.lineBreakMode = .byTruncatingMiddle

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = 0
        modeControl.setContentHuggingPriority(.required, for: .horizontal)
        modeControl.setContentCompressionResistancePriority(.required, for: .horizontal)

        // The ASM/C switch is the screen's only format control and belongs in
        // its top-right corner, level with the title; the dump bar carries the
        // analysis and the fold.
        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        for (button, symbol, action) in [
            (backButton, "chevron.backward", #selector(goBackClicked)),
            (forwardButton, "chevron.forward", #selector(goForwardClicked))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.bezelStyle = .inline
            button.controlSize = .small
            button.target = self
            button.action = action
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        // help: panel.code.navigate
        ControlHelp.describe(backButton, name: L("Back"),
                             tooltip: L("Go back to the previous place in the code (⌘[)"))
        ControlHelp.describe(forwardButton, name: L("Forward"),
                             tooltip: L("Go forward again (⌘])"))
        let titleRow = NSStackView(views: [titleLabel, titleSpacer, backButton, forwardButton,
                                           modeControl])
        titleRow.orientation = .horizontal
        titleRow.alignment = .top
        titleRow.spacing = 8
        titleRow.setContentHuggingPriority(.required, for: .vertical)
        titleRow.setContentCompressionResistancePriority(.required, for: .vertical)
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        // The module and what produced the analysis read as one line: its
        // name, then the plugin and Ghidra versions in grey parentheses.
        let detailSpacer = NSView()
        detailSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let detailRow = NSStackView(views: [nameLabel, recipeLabel, detailSpacer])
        detailRow.orientation = .horizontal
        detailRow.alignment = .firstBaseline
        detailRow.spacing = 6
        detailRow.translatesAutoresizingMaskIntoConstraints = false
        detailRow.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // The analysis dropdown, in the dump bar's right side. It shows the
        // recipe in front; the others are its menu.
        recipePopUp.controlSize = .small
        recipePopUp.font = .systemFont(ofSize: 11)
        recipePopUp.removeAllItems()
        for recipe in recipes {
            recipePopUp.addItem(withTitle: recipe.recipe.id)
        }
        recipePopUp.selectItem(withTitle: manifest.recipe.id)
        recipePopUp.target = self
        recipePopUp.action = #selector(recipeChanged)
        recipePopUp.translatesAutoresizingMaskIntoConstraints = false
        recipePopUp.isHidden = recipes.count <= 1
        let collapsed = recipePopUp.widthAnchor.constraint(equalToConstant: 0)
        collapsed.isActive = recipes.count <= 1
        recipePopUpCollapsed = collapsed
        recipePopUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ControlHelp.describe(recipePopUp, name: L("Analysis"),
                             tooltip: L("Choose the stored analysis shown here"))

        for button in [callersButton] {
            button.bezelStyle = .inline
            button.isBordered = false
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.contentTintColor = .linkColor
            // Each target item carries its own action; the button's would be
            // sent with the button, not an item, as its sender.
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        ControlHelp.describe(callersButton, name: L("Callers"),
                             tooltip: L("Functions that call this one"))
        referencesRow.orientation = .horizontal
        referencesRow.alignment = .centerY
        referencesRow.spacing = 12
        referencesRow.translatesAutoresizingMaskIntoConstraints = false
        referencesRow.addArrangedSubview(callersButton)
        referencesRow.addArrangedSubview(NSView())
        referencesRow.isHidden = true

        staleLabel.font = ToolPanelFont.body()
        staleLabel.textColor = .systemOrange
        staleLabel.lineBreakMode = .byWordWrapping
        staleLabel.maximumNumberOfLines = 0
        staleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        staleLabel.isHidden = true

        let header = NSStackView(views: [titleRow, detailRow, referencesRow, staleLabel])
        header.orientation = .vertical
        header.alignment = .width
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false

        configure(table, identifier: "instruction")
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

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tableScroll)
        content.addSubview(cScroll)
        for scroll in [tableScroll, cScroll] {
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
        detailRow.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        referencesRow.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
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
        hexDumpBar.addSubview(recipePopUp)
        codeContent.addSubview(hexDumpBar)
        NSLayoutConstraint.activate([
            hexDumpBar.leadingAnchor.constraint(equalTo: codeContent.leadingAnchor),
            hexDumpBar.trailingAnchor.constraint(equalTo: codeContent.trailingAnchor),
            hexDumpBar.bottomAnchor.constraint(equalTo: codeContent.bottomAnchor),
            hexDumpBar.heightAnchor.constraint(equalToConstant: Self.dumpBarHeight),
            codeStack.bottomAnchor.constraint(equalTo: hexDumpBar.topAnchor, constant: -8),
            hexDumpButton.trailingAnchor.constraint(equalTo: hexDumpBar.trailingAnchor, constant: -8),
            hexDumpButton.centerYAnchor.constraint(equalTo: hexDumpBar.centerYAnchor),
            recipePopUp.trailingAnchor.constraint(equalTo: hexDumpButton.leadingAnchor, constant: -12),
            recipePopUp.centerYAnchor.constraint(equalTo: hexDumpBar.centerYAnchor),
            recipePopUp.leadingAnchor.constraint(greaterThanOrEqualTo: hexDumpBar.leadingAnchor,
                                                 constant: 8)
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
        split.setPaneLayout(.fixed(220), at: 0)
        split.setPaneLayout(.fill, at: 1)
        split.translatesAutoresizingMaskIntoConstraints = false
        addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: topAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    private func applyCodeBackground() {
        codeContent.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
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

    private func configure(_ table: NSTableView, identifier: String) {
        let column = NSTableColumn(identifier: .init(identifier))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowSizeStyle = .custom
        table.rowHeight = ToolPanelFont.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.allowsEmptySelection = false
        table.delegate = self
        table.dataSource = self
    }

    private func configureC() {
        cTextView.isEditable = false
        cTextView.isSelectable = true
        cTextView.isRichText = true
        cTextView.delegate = self
        // A link keeps the colour of what it is — a function, a global — and
        // shows the hand; no underline over every call.
        cTextView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        cTextView.drawsBackground = false
        cTextView.font = .monospacedSystemFont(ofSize: ToolPanelFont.size, weight: .regular)
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
    private func recipeSummary() -> String {
        let plugin = manifest.recipe.id
            .components(separatedBy: "-ghidra-").first ?? manifest.recipe.id
        var parts = [plugin]
        if let ghidra = manifest.recipe.ghidra, !ghidra.isEmpty {
            parts.append("Ghidra \(ghidra)")
        }
        return "(" + parts.joined(separator: " · ") + ")"
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

    @objc private func recipeChanged() {
        chooseRecipe(at: recipePopUp.indexOfSelectedItem)
    }

    private func applyMode() {
        let c = modeControl.selectedSegment == 1
        tableScroll.isHidden = c
        cScroll.isHidden = !c
        if c { updateC() }
    }

    private func notifyInstruction() {
        guard let line = state.line, let range = model.moduleRange(ofLine: line) else { return }
        onSelectRange?(range)
    }

    /// The selected function's C. Set only when it is another text: a new
    /// instruction in the same function does not lay the text out again.
    private func updateC() {
        guard drawnC != state.function || cTextView.string.isEmpty else { return }
        drawnC = state.function
        let font = NSFont.monospacedSystemFont(ofSize: ToolPanelFont.size, weight: .regular)
        cLinks = []
        let text: NSAttributedString
        if let index = state.function, let c = model.functions[index].c {
            text = CodeColors.attributed(c, tokens: model.cTokens(ofFunction: index), font: font,
                                         links: &cLinks, asTextLinks: true)
        } else {
            let message = state.selectedFunction == nil
                ? L("The analysis holds no functions.")
                : L("No decompiled C for this function.")
            text = NSAttributedString(string: message, attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor
            ])
        }
        cTextView.textStorage?.setAttributedString(text)
    }
}

extension CodePaneView: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === functionTable ? state.rowCount : state.lines.count
    }

    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === functionTable {
            guard row >= 0, row < state.rowCount else { return nil }
            let cell = cell(in: tableView, identifier: .init("code-navigator"), monospaced: false)
            cell.textField?.stringValue = navigatorText(at: row)
            // A name the module's own evidence gave reads as a name; Ghidra's
            // FUN_ placeholder reads quieter. The reason is one hover away.
            var color = NSColor.labelColor
            var reason: String?
            if state.list == .functions {
                let function = model.functions[state.listedFunctions[row]]
                if function.hasPlaceholderName { color = .secondaryLabelColor }
                reason = function.nameReason
            }
            cell.textField?.textColor = color
            cell.toolTip = reason
            return cell
        }
        let lines = state.lines
        guard row >= 0, row < lines.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("code-line")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? CodeLineCell
            ?? CodeLineCell(identifier: identifier)
        let shown = model.listingRow(ofLine: lines[lines.startIndex + row].global)
        cell.line.show(shown.text, tokens: shown.tokens,
                       font: .monospacedSystemFont(ofSize: ToolPanelFont.size, weight: .regular))
        cell.line.onLink = { [weak self] link in self?.follow(link) }
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection, let table = notification.object as? NSTableView else { return }
        if table === functionTable {
            let row = functionTable.selectedRow
            guard row >= 0 else { return }
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
            let function = model.functions[state.listedFunctions[row]]
            return function.name.isEmpty ? model.displayAddress(function.entry) : function.name
        case .strings:
            let entry = artifact.strings[state.listedStrings[row]]
            return entry.value.isEmpty
                ? model.displayAddress(entry.address)
                : "\(model.displayAddress(entry.address))  \(entry.value)"
        case .postCodes:
            let entry = artifact.postCodes[state.listedPostCodes[row]]
            return "\(model.displayAddress(entry.address))  \(entry.text)"
        case .statusCodes:
            let entry = artifact.statusCodeCalls[state.listedStatusCodes[row]]
            return "\(model.displayAddress(entry.address))  \(entry.text)"
        }
    }

    /// A row's cell, reused from the table's queue when it has one: a listing
    /// of a large function scrolls through thousands of rows.
    private func cell(in tableView: NSTableView, identifier: NSUserInterfaceItemIdentifier,
                      monospaced: Bool) -> NSTableCellView {
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil)
            as? NSTableCellView {
            return reused
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.font = monospaced
            ? .monospacedSystemFont(ofSize: ToolPanelFont.size, weight: .regular)
            : ToolPanelFont.body()
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = field
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
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
    /// A click on a call or a global in the C.
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
