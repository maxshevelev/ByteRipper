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
@MainActor public final class CodePaneView: NSView {
    private struct Line {
        /// The instruction's index in the whole artifact. Table rows are the
        /// selected function's instructions only, so a row is not this.
        let global: Int
        let function: Int
        let instruction: CodeArtifact.Instruction
    }

    /// What the left navigator lists. One at a time, so every function stays
    /// visible when Functions is chosen; the other lists are a click away.
    public enum List: Int, CaseIterable {
        case functions, strings, postCodes, statusCodes
    }

    public let manifest: AnalysisManifest
    public let artifact: CodeArtifact
    private let layout: ModuleLayout?
    private let functions: [CodeArtifact.Function]
    /// Every instruction in the artifact, and the selected function's rows —
    /// the listing shows one function, the way C does.
    private var allLines: [Line] = []
    private var lines: [Line] = []
    /// The navigator's rows for the list in front, after the search filter.
    private var listedFunctions: [CodeArtifact.Function] = []
    private var listedStrings: [CodeArtifact.StringEntry] = []
    private var listedPostCodes: [CodeArtifact.PostCode] = []
    private var listedStatusCodes: [CodeArtifact.StatusCodeCall] = []
    private var list: List = .functions
    private var searchText = ""
    /// The selected function by its place in the artifact, not by a row: the
    /// navigator may be showing strings at the time.
    private var functionNumber: Int?

    private let functionTable = NSTableView()
    private let functionScroll = NSScrollView()
    private let navigatorLabel = NSTextField(labelWithString: "")
    private let listControl: NSSegmentedControl
    private let searchField = NSSearchField()
    private let callersButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let calleesButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let referencesRow = NSStackView()
    private let table = NSTableView()
    private let tableScroll = NSScrollView()
    private let cTextView = NSTextView()
    private let cScroll = NSScrollView()
    private let modeControl: NSSegmentedControl
    private let codeContent = NSView()
    private let staleLabel = NSTextField(labelWithString: "")
    private var syncingSelection = false

    /// An instruction's bytes from a listing click. The app selects them in
    /// the hex view.
    public var onSelectRange: ((Range<UInt64>) -> Void)?
    /// A function's whole stored range, shown as the dump's main zone rather
    /// than as a selection: the reader keeps the selection for reading bytes.
    public var onFocusRange: ((Range<UInt64>) -> Void)?

    public init(manifest: AnalysisManifest, artifact: CodeArtifact,
                moduleBytes: Data? = nil, hexView: NSView) {
        self.manifest = manifest
        self.artifact = artifact
        self.functions = artifact.functions
        self.layout = moduleBytes.flatMap { try? ModuleLayout(module: $0) }
        // ASM and C are names of formats, not words to translate.
        modeControl = NSSegmentedControl(
            labels: ["ASM", "C"], trackingMode: .selectOne,
            target: nil, action: nil)
        listControl = NSSegmentedControl(
            labels: [L("Functions"), L("Strings"), L("POST"), L("Status")],
            trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        for (index, function) in functions.enumerated() {
            for instruction in function.instructions {
                allLines.append(Line(global: allLines.count, function: index,
                                     instruction: instruction))
            }
        }
        build(hexView: hexView)
        refreshNavigator()
        selectFunction(at: 0, notify: false)
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

    public var functionCount: Int { functions.count }
    public var instructionCount: Int { allLines.count }
    /// The rows the listing shows: the selected function's instructions.
    public var listedInstructionCount: Int { lines.count }
    public var listedFunctionCount: Int { listedFunctions.count }
    public var listedStringCount: Int { listedStrings.count }
    public var listedPostCodeCount: Int { listedPostCodes.count }
    public var listedStatusCodeCount: Int { listedStatusCodes.count }

    public var selectedInstruction: CodeArtifact.Instruction? {
        guard table.selectedRow >= 0, table.selectedRow < lines.count else { return nil }
        return lines[table.selectedRow].instruction
    }

    public var selectedFunction: CodeArtifact.Function? {
        guard let functionNumber, functions.indices.contains(functionNumber) else { return nil }
        return functions[functionNumber]
    }

    public var decompiledText: String { cTextView.string }
    public var selectedFunctionIndex: Int? { functionNumber }
    public var selectedInstructionIndex: Int? {
        guard table.selectedRow >= 0, table.selectedRow < lines.count else { return nil }
        return lines[table.selectedRow].global
    }
    public var selectedString: CodeArtifact.StringEntry? {
        guard list == .strings, functionTable.selectedRow >= 0,
              functionTable.selectedRow < listedStrings.count else { return nil }
        return listedStrings[functionTable.selectedRow]
    }
    public var selectedPostCode: CodeArtifact.PostCode? {
        guard list == .postCodes, functionTable.selectedRow >= 0,
              functionTable.selectedRow < listedPostCodes.count else { return nil }
        return listedPostCodes[functionTable.selectedRow]
    }
    public var selectedStatusCode: CodeArtifact.StatusCodeCall? {
        guard list == .statusCodes, functionTable.selectedRow >= 0,
              functionTable.selectedRow < listedStatusCodes.count else { return nil }
        return listedStatusCodes[functionTable.selectedRow]
    }
    public var showsDecompiledC: Bool { modeControl.selectedSegment == 1 }

    /// Switches the navigator: Functions, Strings, POST writes, Status codes.
    public func selectList(_ list: List) {
        guard self.list != list else { return }
        self.list = list
        listControl.selectedSegment = list.rawValue
        refreshNavigator()
        if list != .functions, numberOfRows(in: functionTable) > 0 {
            selectNavigatorRow(0)
        }
    }

    /// Filters the list in front. Functions match their name, signature,
    /// address or instruction text; strings and the two call lists match what
    /// they say.
    public func filter(by text: String) {
        searchField.stringValue = text
        searchText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshNavigator()
    }

    // MARK: - The navigator

    private func title(for list: List) -> String {
        switch list {
        case .functions: L("Functions")
        case .strings: L("Strings")
        case .postCodes: L("POST writes")
        case .statusCodes: L("Status codes")
        }
    }

    /// Applies the search filter to the list in front and lets the table ask
    /// for its rows again.
    private func refreshNavigator() {
        let needle = searchText.lowercased()
        listedFunctions = functions.filter { function in
            guard !needle.isEmpty else { return true }
            if function.name.lowercased().contains(needle)
                || function.entry.description.lowercased().contains(needle)
                || (function.signature?.lowercased().contains(needle) ?? false) {
                return true
            }
            return function.instructions.contains { instruction in
                instruction.text.lowercased().contains(needle)
                    || (instruction.mnemonic?.lowercased().contains(needle) ?? false)
            }
        }
        listedStrings = artifact.strings.filter { entry in
            needle.isEmpty
                || entry.value.lowercased().contains(needle)
                || entry.type.lowercased().contains(needle)
                || entry.address.description.lowercased().contains(needle)
        }
        listedPostCodes = artifact.postCodes.filter { entry in
            needle.isEmpty
                || entry.text.lowercased().contains(needle)
                || entry.port.lowercased().contains(needle)
                || entry.address.description.lowercased().contains(needle)
        }
        listedStatusCodes = artifact.statusCodeCalls.filter { entry in
            needle.isEmpty
                || entry.text.lowercased().contains(needle)
                || entry.address.description.lowercased().contains(needle)
                || entry.context.contains { $0.lowercased().contains(needle) }
        }
        navigatorLabel.stringValue = title(for: list)
        syncingSelection = true
        functionTable.reloadData()
        if list == .functions, let functionNumber,
           let row = listedFunctions.firstIndex(where: {
               $0.entry == functions[functionNumber].entry
           }) {
            functionTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            functionTable.scrollRowToVisible(row)
        } else {
            functionTable.deselectAll(nil)
        }
        syncingSelection = false
    }

    @objc private func listChanged() {
        guard let list = List(rawValue: listControl.selectedSegment) else { return }
        selectList(list)
    }

    @objc private func searchChanged() {
        searchText = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshNavigator()
    }

    /// The callers and callees of the selected function, as short menus: a
    /// target is one click away, and an address with no function still names
    /// itself rather than disappearing.
    private func updateReferences() {
        guard let function = selectedFunction else {
            referencesRow.isHidden = true
            return
        }
        fill(callersButton, title: L("Callers"), with: function.callers)
        fill(calleesButton, title: L("Callees"), with: function.callees)
        referencesRow.isHidden = function.callers.isEmpty && function.callees.isEmpty
    }

    private func fill(_ button: NSPopUpButton, title: String,
                      with addresses: [CodeAddress]) {
        button.removeAllItems()
        let heading = NSMenuItem(title: "\(title) (\(addresses.count))",
                                 action: nil, keyEquivalent: "")
        button.menu?.addItem(heading)
        guard !addresses.isEmpty else { return }
        for address in addresses {
            let item = NSMenuItem(title: name(for: address),
                                  action: #selector(callTargetChosen(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: address.value)
            button.menu?.addItem(item)
        }
    }

    private func name(for address: CodeAddress) -> String {
        functions.first(where: { $0.entry == address })?.name ?? displayAddress(address)
    }

    @objc private func callTargetChosen(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        navigate(to: CodeAddress(number.uint64Value))
    }

    /// A reference goes to the function at its target when there is one, or to
    /// the bytes there when the module holds them. An external target does
    /// nothing rather than pretending to go somewhere.
    private func navigate(to address: CodeAddress) {
        if let index = functions.firstIndex(where: { $0.entry == address }) {
            selectFunction(at: index)
        } else if let range = addressRange(address) {
            onSelectRange?(range)
        }
    }

    private func addressRange(_ address: CodeAddress) -> Range<UInt64>? {
        guard let layout else { return nil }
        return layout.fileRange(for: address, count: 1,
                                imageBase: artifact.program?.imageBase?.value)
    }

    /// The bytes a string occupies: its terminator included, and two bytes per
    /// character when Ghidra says it is a wide string. When the layout has no
    /// range for it the first byte is still worth showing.
    private func stringRange(_ entry: CodeArtifact.StringEntry) -> Range<UInt64>? {
        guard let layout else { return nil }
        let type = entry.type.lowercased()
        let wide = type.contains("unicode") || type.contains("wide") || type.contains("utf16")
        let count = wide
            ? max(2, (entry.value.utf16.count + 1) * 2)
            : max(1, entry.value.utf8.count + 1)
        let base = artifact.program?.imageBase?.value
        return layout.fileRange(for: entry.address, count: count, imageBase: base)
            ?? layout.fileRange(for: entry.address, count: 1, imageBase: base)
    }

    private func selectString(at row: Int) {
        guard listedStrings.indices.contains(row),
              let range = stringRange(listedStrings[row]) else { return }
        onSelectRange?(range)
    }

    /// What a navigator row means in the list that is showing. The table has
    /// selected the row already; this puts its bytes or its function on screen.
    private func selectNavigatorRow(_ row: Int) {
        guard row >= 0 else { return }
        syncingSelection = true
        functionTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        functionTable.scrollRowToVisible(row)
        syncingSelection = false
        switch list {
        case .functions:
            guard row < listedFunctions.count,
                  let index = functions.firstIndex(where: {
                      $0.entry == listedFunctions[row].entry
                  }) else { return }
            selectFunction(at: index)
        case .strings:
            selectString(at: row)
        case .postCodes:
            guard row < listedPostCodes.count else { return }
            guard let range = addressRange(listedPostCodes[row].address) else { return }
            onSelectRange?(range)
        case .statusCodes:
            guard row < listedStatusCodes.count else { return }
            guard let range = addressRange(listedStatusCodes[row].address) else { return }
            onSelectRange?(range)
        }
    }

    /// Puts the listing back where a screen that moved container left it:
    /// the function, the instruction and the ASM/C choice.
    public func restore(function: Int?, instruction: Int?, showsC: Bool) {
        if let function {
            selectFunction(at: function, notify: false)
        }
        if let instruction, allLines.indices.contains(instruction) {
            reveal(globalInstruction: instruction)
        }
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
        guard functions.indices.contains(index) else { return }
        // A caller can point at a function the current search or list hides:
        // show Functions, with the filter cleared, before selecting it.
        ensureFunctionVisible(index)
        functionNumber = index
        syncingSelection = true
        if let row = listedFunctions.firstIndex(where: { $0.entry == functions[index].entry }) {
            functionTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            functionTable.scrollRowToVisible(row)
        }
        showInstructions(of: index)
        if !lines.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        syncingSelection = false
        updateC()
        updateReferences()
        if notify, let range = moduleRange(forFunction: index) {
            onFocusRange?(range)
        }
    }

    /// Marks the selected function's range as the main zone without a click —
    /// what the screen does when it opens on a function.
    public func focusSelectedFunction() {
        guard let functionNumber,
              let range = moduleRange(forFunction: functionNumber)
        else { return }
        onFocusRange?(range)
    }

    /// Selects an instruction by its index in the artifact, as a click would.
    public func selectInstruction(at index: Int) {
        guard allLines.indices.contains(index) else { return }
        reveal(globalInstruction: index)
        updateC()
        notifyInstruction()
    }

    /// Selects the instruction covering `range` of the module without moving
    /// the hex view back: the selection came from there.
    public func selectModuleRange(_ range: Range<UInt64>) {
        guard list == .functions, !allLines.isEmpty, !syncingSelection else { return }
        guard let row = row(forModuleRange: range) else { return }
        reveal(globalInstruction: row)
        updateC()
    }

    /// Shows the function holding `index` and selects that instruction.
    private func reveal(globalInstruction index: Int) {
        guard allLines.indices.contains(index) else { return }
        let line = allLines[index]
        ensureFunctionVisible(line.function)
        functionNumber = line.function
        syncingSelection = true
        if let functionRow = listedFunctions.firstIndex(where: {
            $0.entry == functions[line.function].entry
        }) {
            functionTable.selectRowIndexes(IndexSet(integer: functionRow),
                                           byExtendingSelection: false)
            functionTable.scrollRowToVisible(functionRow)
        }
        showInstructions(of: line.function)
        if let row = lines.firstIndex(where: { $0.global == index }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        syncingSelection = false
        updateReferences()
    }

    /// Makes sure the navigator is showing Functions and that `index` survived
    /// the search, clearing the search if it did not.
    private func ensureFunctionVisible(_ index: Int) {
        guard functions.indices.contains(index) else { return }
        if list != .functions
            || !listedFunctions.contains(where: { $0.entry == functions[index].entry }) {
            list = .functions
            listControl.selectedSegment = List.functions.rawValue
            if !searchText.isEmpty {
                searchField.stringValue = ""
                searchText = ""
            }
            refreshNavigator()
        }
    }

    /// The listing is the selected function's instructions, nothing else.
    private func showInstructions(of function: Int) {
        lines = allLines.filter { $0.function == function }
        table.reloadData()
    }

    /// The whole stored range of a function, for the hex view and for tests.
    public func moduleRange(forFunction index: Int) -> Range<UInt64>? {
        guard index >= 0, index < functions.count else { return nil }
        let function = functions[index]
        guard let layout else { return nil }
        let base = artifact.program?.imageBase?.value
        if let size = function.size, size > 0,
           let range = layout.fileRange(for: function.entry, count: size, imageBase: base) {
            return range
        }
        let ranges = function.instructions.compactMap { instructionRange($0) }
        guard let lower = ranges.map(\.lowerBound).min(),
              let upper = ranges.map(\.upperBound).max()
        else { return nil }
        return lower..<upper
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

        // The ASM/C switch is the screen's only control and belongs in its
        // top-right corner, level with the title.
        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let titleRow = NSStackView(views: [titleLabel, titleSpacer, modeControl])
        titleRow.orientation = .horizontal
        titleRow.alignment = .top
        titleRow.spacing = 8
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

        for button in [callersButton, calleesButton] {
            button.bezelStyle = .inline
            button.isBordered = false
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.contentTintColor = .linkColor
            button.target = self
            button.action = #selector(callTargetChosen(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        ControlHelp.describe(callersButton, name: L("Callers"),
                             tooltip: L("Functions that call this one"))
        ControlHelp.describe(calleesButton, name: L("Callees"),
                             tooltip: L("Functions this one calls"))
        referencesRow.orientation = .horizontal
        referencesRow.alignment = .centerY
        referencesRow.spacing = 12
        referencesRow.translatesAutoresizingMaskIntoConstraints = false
        referencesRow.addArrangedSubview(callersButton)
        referencesRow.addArrangedSubview(calleesButton)
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
            codeStack.topAnchor.constraint(equalTo: codeContent.topAnchor, constant: 12),
            codeStack.bottomAnchor.constraint(equalTo: codeContent.bottomAnchor, constant: -12)
        ])
        header.widthAnchor.constraint(equalTo: codeStack.widthAnchor).isActive = true
        titleRow.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        detailRow.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        referencesRow.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        staleLabel.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true

        let rightSplit = ALSplitView()
        rightSplit.isVertical = false
        rightSplit.dividerThickness = 1
        rightSplit.addPane(codeContent)
        rightSplit.addPane(hexView)
        rightSplit.setPaneLayout(.fill, at: 0)
        rightSplit.setPaneLayout(.fixed(220), at: 1)

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
        cTextView.isRichText = false
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

    private func selectFunctionRow(_ index: Int) {
        guard functions.indices.contains(index) else { return }
        syncingSelection = true
        if let row = listedFunctions.firstIndex(where: { $0.entry == functions[index].entry }) {
            functionTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            functionTable.scrollRowToVisible(row)
        }
        syncingSelection = false
    }

    @objc private func modeChanged() {
        applyMode()
    }

    private func applyMode() {
        let c = modeControl.selectedSegment == 1
        tableScroll.isHidden = c
        cScroll.isHidden = !c
        if c { updateC() }
    }

    private func notifyInstruction() {
        guard let instruction = selectedInstruction,
              let range = instructionRange(instruction)
        else { return }
        onSelectRange?(range)
    }

    private func instructionRange(_ instruction: CodeArtifact.Instruction) -> Range<UInt64>? {
        guard let layout else { return nil }
        return layout.fileRange(for: instruction.address, count: instruction.bytes.count,
                                imageBase: artifact.program?.imageBase?.value)
    }

    private func row(forModuleRange range: Range<UInt64>) -> Int? {
        guard !allLines.isEmpty else { return nil }
        var preceding: Int?
        for line in allLines {
            guard let candidate = instructionRange(line.instruction) else { continue }
            if range.isEmpty {
                if candidate.contains(range.lowerBound) { return line.global }
            } else if candidate.overlaps(range) {
                return line.global
            }
            if candidate.lowerBound <= range.lowerBound { preceding = line.global }
        }
        return preceding
    }

    private func updateC() {
        guard let function = selectedFunction else {
            cTextView.string = L("The analysis holds no functions.")
            return
        }
        cTextView.string = function.c ?? L("No decompiled C for this function.")
    }
}

extension CodePaneView: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        guard tableView === functionTable else { return lines.count }
        switch list {
        case .functions: return listedFunctions.count
        case .strings: return listedStrings.count
        case .postCodes: return listedPostCodes.count
        case .statusCodes: return listedStatusCodes.count
        }
    }

    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === functionTable {
            let text: String
            switch list {
            case .functions:
                guard row >= 0, row < listedFunctions.count else { return nil }
                let function = listedFunctions[row]
                text = function.name.isEmpty ? displayAddress(function.entry) : function.name
            case .strings:
                guard row >= 0, row < listedStrings.count else { return nil }
                let entry = listedStrings[row]
                text = entry.value.isEmpty
                    ? displayAddress(entry.address)
                    : "\(displayAddress(entry.address))  \(entry.value)"
            case .postCodes:
                guard row >= 0, row < listedPostCodes.count else { return nil }
                let entry = listedPostCodes[row]
                text = "\(displayAddress(entry.address))  \(entry.text)"
            case .statusCodes:
                guard row >= 0, row < listedStatusCodes.count else { return nil }
                let entry = listedStatusCodes[row]
                text = "\(displayAddress(entry.address))  \(entry.text)"
            }
            let cell = makeCell(identifier: .init("code-navigator"), monospaced: false)
            cell.textField?.stringValue = text
            return cell
        }
        guard row >= 0, row < lines.count else { return nil }
        let cell = makeCell(identifier: .init("code-line"), monospaced: true)
        cell.textField?.stringValue = display(lines[row].instruction)
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection, let table = notification.object as? NSTableView else { return }
        if table === functionTable {
            let row = functionTable.selectedRow
            guard row >= 0 else { return }
            selectNavigatorRow(row)
        } else if table === self.table {
            guard table.selectedRow >= 0, table.selectedRow < lines.count else { return }
            selectFunctionRow(lines[table.selectedRow].function)
            updateC()
            notifyInstruction()
        }
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier,
                          monospaced: Bool) -> NSTableCellView {
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

    private func display(_ instruction: CodeArtifact.Instruction) -> String {
        let address = displayAddress(instruction.address)
            .padding(toLength: 10, withPad: " ", startingAt: 0)
        let bytes = instruction.bytes.map { String(format: "%02X", $0) }
            .joined(separator: " ")
        let byteColumn = bytes.padding(toLength: 26, withPad: " ", startingAt: 0)
        return address + "  " + byteColumn + "  " + instruction.text
    }

    /// The offset of an address in the module bytes — the same number the hex
    /// view's offset column shows. Ghidra's virtual addresses are useful to
    /// the code, but a reader looking for bytes needs the module's own offset.
    /// An address with no bytes (an external target) falls back to Ghidra's.
    private func displayAddress(_ address: CodeAddress) -> String {
        guard let layout,
              let offset = layout.fileOffset(for: address,
                                             imageBase: artifact.program?.imageBase?.value)
        else { return address.description }
        return "0x" + String(offset, radix: 16, uppercase: true)
    }
}
