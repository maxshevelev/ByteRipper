import ALSplitView
import AppKit
import CodeAnalysis
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
        let function: Int
        let instruction: CodeArtifact.Instruction
    }

    public let manifest: AnalysisManifest
    public let artifact: CodeArtifact
    private let layout: ModuleLayout?
    private let functions: [CodeArtifact.Function]
    private var lines: [Line] = []

    private let functionTable = NSTableView()
    private let functionScroll = NSScrollView()
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
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        for (index, function) in functions.enumerated() {
            for instruction in function.instructions {
                lines.append(Line(function: index, instruction: instruction))
            }
        }
        build(hexView: hexView)
        selectFunction(at: 0, notify: false)
        updateC()
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
    public var instructionCount: Int { lines.count }

    public var selectedInstruction: CodeArtifact.Instruction? {
        guard table.selectedRow >= 0, table.selectedRow < lines.count else { return nil }
        return lines[table.selectedRow].instruction
    }

    public var selectedFunction: CodeArtifact.Function? {
        guard functionTable.selectedRow >= 0,
              functionTable.selectedRow < functions.count
        else { return nil }
        return functions[functionTable.selectedRow]
    }

    public var decompiledText: String { cTextView.string }
    public var selectedFunctionIndex: Int? {
        functionTable.selectedRow >= 0 && functionTable.selectedRow < functions.count
            ? functionTable.selectedRow : nil
    }
    public var selectedInstructionIndex: Int? {
        table.selectedRow >= 0 && table.selectedRow < lines.count ? table.selectedRow : nil
    }
    public var showsDecompiledC: Bool { modeControl.selectedSegment == 1 }

    /// Puts the listing back where a screen that moved container left it:
    /// the function, the instruction and the ASM/C choice.
    public func restore(function: Int?, instruction: Int?, showsC: Bool) {
        if let function {
            selectFunction(at: function, notify: false)
        }
        if let instruction, instruction >= 0, instruction < lines.count {
            syncingSelection = true
            table.selectRowIndexes(IndexSet(integer: instruction), byExtendingSelection: false)
            table.scrollRowToVisible(instruction)
            functionTable.selectRowIndexes(IndexSet(integer: lines[instruction].function),
                                           byExtendingSelection: false)
            functionTable.scrollRowToVisible(lines[instruction].function)
            syncingSelection = false
            updateC()
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
        guard index >= 0, index < functions.count else { return }
        syncingSelection = true
        functionTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        functionTable.scrollRowToVisible(index)
        if let row = lines.firstIndex(where: { $0.function == index }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        syncingSelection = false
        updateC()
        if notify, let range = moduleRange(forFunction: index) {
            onFocusRange?(range)
        }
    }

    /// Marks the selected function's range as the main zone without a click —
    /// what the screen does when it opens on a function.
    public func focusSelectedFunction() {
        guard functionTable.selectedRow >= 0,
              let range = moduleRange(forFunction: functionTable.selectedRow)
        else { return }
        onFocusRange?(range)
    }

    /// Selects an instruction by its row, as a click would.
    public func selectInstruction(at index: Int) {
        guard index >= 0, index < lines.count else { return }
        syncingSelection = true
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
        syncingSelection = false
        selectFunctionRow(lines[index].function)
        updateC()
        notifyInstruction()
    }

    /// Selects the instruction covering `range` of the module without moving
    /// the hex view back: the selection came from there.
    public func selectModuleRange(_ range: Range<UInt64>) {
        guard !lines.isEmpty, !syncingSelection else { return }
        guard let row = row(forModuleRange: range) else { return }
        syncingSelection = true
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        functionTable.selectRowIndexes(IndexSet(integer: lines[row].function),
                                       byExtendingSelection: false)
        functionTable.scrollRowToVisible(lines[row].function)
        syncingSelection = false
        updateC()
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
        let functionLabel = label(L("Functions"), font: ToolPanelFont.title())
        configure(functionTable, identifier: "function")
        functionScroll.documentView = functionTable
        functionScroll.hasVerticalScroller = true
        functionScroll.drawsBackground = false
        functionScroll.translatesAutoresizingMaskIntoConstraints = false

        let functionPane = NSView()
        functionPane.translatesAutoresizingMaskIntoConstraints = false
        functionPane.addSubview(functionLabel)
        functionPane.addSubview(functionScroll)
        NSLayoutConstraint.activate([
            functionLabel.leadingAnchor.constraint(equalTo: functionPane.leadingAnchor, constant: 8),
            functionLabel.trailingAnchor.constraint(equalTo: functionPane.trailingAnchor, constant: -8),
            functionLabel.topAnchor.constraint(equalTo: functionPane.topAnchor, constant: 8),
            functionScroll.topAnchor.constraint(equalTo: functionLabel.bottomAnchor, constant: 6),
            functionScroll.leadingAnchor.constraint(equalTo: functionPane.leadingAnchor, constant: 8),
            functionScroll.trailingAnchor.constraint(equalTo: functionPane.trailingAnchor, constant: -8),
            functionScroll.bottomAnchor.constraint(equalTo: functionPane.bottomAnchor, constant: -8)
        ])

        codeContent.wantsLayer = true
        applyCodeBackground()

        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 3
        header.addArrangedSubview(label(L("Code analysis"), font: ToolPanelFont.title()))
        header.addArrangedSubview(label(
            manifest.module.name.isEmpty ? manifest.recipe.id : manifest.module.name,
            font: ToolPanelFont.body(weight: .medium)))
        header.addArrangedSubview(label(manifest.recipe.id, font: ToolPanelFont.body(),
                                        color: .secondaryLabelColor))
        staleLabel.font = ToolPanelFont.body()
        staleLabel.textColor = .systemOrange
        staleLabel.lineBreakMode = .byWordWrapping
        staleLabel.maximumNumberOfLines = 0
        staleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        staleLabel.isHidden = true
        header.addArrangedSubview(staleLabel)

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = 0
        modeControl.setContentHuggingPriority(.required, for: .horizontal)

        let controls = NSStackView(views: [modeControl, NSView()])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.distribution = .fill
        if let spacer = controls.arrangedSubviews.last {
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        }

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

        let codeStack = NSStackView(views: [header, controls, content])
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
        controls.widthAnchor.constraint(equalTo: codeStack.widthAnchor).isActive = true

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
        guard index >= 0, index < functions.count else { return }
        syncingSelection = true
        functionTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        functionTable.scrollRowToVisible(index)
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
        guard !lines.isEmpty else { return nil }
        var preceding: Int?
        for (index, line) in lines.enumerated() {
            guard let candidate = instructionRange(line.instruction) else { continue }
            if range.isEmpty {
                if candidate.contains(range.lowerBound) { return index }
            } else if candidate.overlaps(range) {
                return index
            }
            if candidate.lowerBound <= range.lowerBound { preceding = index }
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
        tableView === functionTable ? functions.count : lines.count
    }

    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === functionTable {
            guard row >= 0, row < functions.count else { return nil }
            let cell = makeCell(identifier: .init("code-function"), monospaced: false)
            let function = functions[row]
            cell.textField?.stringValue = function.name.isEmpty
                ? function.entry.description : function.name
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
            let index = functionTable.selectedRow
            guard index >= 0, index < functions.count else { return }
            selectFunction(at: index)
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
        let address = instruction.address.description
            .padding(toLength: 10, withPad: " ", startingAt: 0)
        let bytes = instruction.bytes.map { String(format: "%02X", $0) }
            .joined(separator: " ")
        let byteColumn = bytes.padding(toLength: 26, withPad: " ", startingAt: 0)
        return address + "  " + byteColumn + "  " + instruction.text
    }
}
