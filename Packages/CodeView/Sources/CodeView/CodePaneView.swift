import AppKit
import CodeAnalysis
import Localization
import ToolModuleKit

/// The pane beside a module's bytes: its functions, the disassembly or the
/// decompiled C, and the link back to the bytes
/// (`Design/CODE_PANEL_PLAN.md`).
///
/// A reader, not a tool-module: it owns the content width and its own
/// selection, and it knows nothing about the UEFI tree or the store. The
/// artifact is a snapshot; a stale module is said out loud rather than shown as
/// if it were current.
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

    private let functionPopup = NSPopUpButton()
    private let modeControl: NSSegmentedControl
    private let table = NSTableView()
    private let tableScroll = NSScrollView()
    private let cTextView = NSTextView()
    private let cScroll = NSScrollView()
    private let staleLabel = NSTextField(labelWithString: "")
    private var syncingSelection = false

    /// The module range of the instruction the reader chose, in the part's own
    /// offsets. The app selects it in the hex view.
    public var onSelectRange: ((Range<UInt64>) -> Void)?

    public init(manifest: AnalysisManifest, artifact: CodeArtifact,
                moduleBytes: Data? = nil) {
        self.manifest = manifest
        self.artifact = artifact
        self.functions = artifact.functions
        self.layout = moduleBytes.flatMap { try? ModuleLayout(module: $0) }
        modeControl = NSSegmentedControl(
            labels: [L("Disassembly"), "C"], trackingMode: .selectOne,
            target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        for (index, function) in functions.enumerated() {
            for instruction in function.instructions {
                lines.append(Line(function: index, instruction: instruction))
            }
        }
        build()
        selectInitialRow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: - What the reader sees

    /// How many instructions the pane lists.
    public var instructionCount: Int { lines.count }

    /// The instruction the table has selected, if it has one.
    public var selectedInstruction: CodeArtifact.Instruction? {
        guard table.selectedRow >= 0, table.selectedRow < lines.count else { return nil }
        return lines[table.selectedRow].instruction
    }

    public var selectedFunction: CodeArtifact.Function? {
        if functionPopup.indexOfSelectedItem >= 0,
           functionPopup.indexOfSelectedItem < functions.count {
            return functions[functionPopup.indexOfSelectedItem]
        }
        if table.selectedRow >= 0, table.selectedRow < lines.count {
            return functions[lines[table.selectedRow].function]
        }
        return nil
    }

    /// The decompiled C shown for the selected function, or the sentence that
    /// says why there is none. Read by the tests without reaching into the
    /// text view.
    public var decompiledText: String { cTextView.string }

    /// Shows the stale banner. The app calls this when the module's current
    /// bytes no longer match the manifest.
    public func setStale(_ stale: Bool, reason: String? = nil) {
        staleLabel.stringValue = stale
            ? (reason ?? L("The module changed after this analysis."))
            : ""
        staleLabel.isHidden = !stale
    }

    /// Selects the instruction covering `range` of the module, without moving
    /// the hex view back: the selection came from there. A caret at an
    /// instruction's first byte selects it; a range between instructions picks
    /// the one it overlaps or the nearest preceding one.
    public func selectModuleRange(_ range: Range<UInt64>) {
        guard !lines.isEmpty, !syncingSelection else { return }
        guard let row = row(forModuleRange: range) else { return }
        syncingSelection = true
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        syncingSelection = false
        selectFunctionForRow(row)
        updateC()
    }

    /// Selects an instruction by its row, as a click would. Public for the
    /// tests and for a future function navigator elsewhere.
    public func selectInstruction(at index: Int) {
        guard index >= 0, index < lines.count else { return }
        syncingSelection = true
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
        syncingSelection = false
        selectFunctionForRow(index)
        updateC()
        notifySelection()
    }

    // MARK: - Building

    private func build() {
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

        functionPopup.target = self
        functionPopup.action = #selector(functionChosen)
        functionPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if functions.isEmpty {
            functionPopup.addItem(withTitle: L("No functions"))
            functionPopup.isEnabled = false
        } else {
            functionPopup.addItems(withTitles: functions.map {
                $0.name.isEmpty ? $0.entry.description : $0.name
            })
            functionPopup.selectItem(at: 0)
        }

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = 0
        modeControl.setContentHuggingPriority(.required, for: .horizontal)

        let controls = NSStackView(views: [functionPopup, modeControl])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.distribution = .fill

        configureTable()
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

        let root = NSStackView(views: [header, controls, content])
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
        header.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        controls.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: .init("line"))
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
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    // MARK: - Selection

    private func selectInitialRow() {
        guard !lines.isEmpty else { return }
        syncingSelection = true
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        syncingSelection = false
        selectFunctionForRow(0)
        updateC()
    }

    private func selectFunctionForRow(_ row: Int) {
        guard row >= 0, row < lines.count, !functions.isEmpty else { return }
        functionPopup.selectItem(at: lines[row].function)
    }

    @objc private func functionChosen() {
        let index = functionPopup.indexOfSelectedItem
        guard index >= 0, index < functions.count else { return }
        guard let row = lines.firstIndex(where: { $0.function == index }) else {
            updateC()
            return
        }
        selectInstruction(at: row)
    }

    @objc private func modeChanged() {
        let c = modeControl.selectedSegment == 1
        tableScroll.isHidden = c
        cScroll.isHidden = !c
        if c { updateC() }
    }

    private func notifySelection() {
        guard let instruction = selectedInstruction,
              let range = moduleRange(for: instruction)
        else { return }
        onSelectRange?(range)
    }

    private func moduleRange(for instruction: CodeArtifact.Instruction) -> Range<UInt64>? {
        guard let layout else { return nil }
        return layout.fileRange(for: instruction.address, count: instruction.bytes.count,
                                imageBase: artifact.program?.imageBase?.value)
    }

    private func row(forModuleRange range: Range<UInt64>) -> Int? {
        guard !lines.isEmpty else { return nil }
        var preceding: Int?
        for (index, line) in lines.enumerated() {
            guard let candidate = moduleRange(for: line.instruction) else { continue }
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
    public func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < lines.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("code-line")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView ?? makeLineCell(identifier: identifier)
        cell.textField?.stringValue = display(lines[row].instruction)
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection else { return }
        updateC()
        notifySelection()
    }

    private func makeLineCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedSystemFont(ofSize: ToolPanelFont.size, weight: .regular)
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
