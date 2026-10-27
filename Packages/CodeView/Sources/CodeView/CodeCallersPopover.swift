import AppKit
import CodeAnalysis
import Localization

/// One row of Show Callers: a call to the function, or a caller the analysis
/// knows but whose call it could not place — through a pointer.
struct CodeCaller: Equatable {
    /// The calling function.
    let function: Int
    /// The calling instruction; nil for a caller with no placed call.
    let use: CodeModel.Use?
}

/// Show Callers: every call to one function, in a popover off its name, as
/// the explanation of a name is. A caller that calls three times is three
/// rows, each with the address and the instruction of its call; a click on
/// one closes the popover and opens the caller at that call.
@MainActor final class CodeCallersPopover: NSViewController {
    enum Column: CaseIterable {
        case caller, address, instruction, kind
    }

    private let model: CodeModel
    private let calleeName: String
    let callers: [CodeCaller]
    /// The row chosen: the pane goes there once the popover is gone.
    private let onChoose: (CodeCaller) -> Void
    private let popover = NSPopover()

    /// More rows than this scroll inside the popover.
    private static let mostRows = 12

    init(model: CodeModel, callee: Int, callers: [CodeCaller], onChoose: @escaping (CodeCaller) -> Void) {
        self.model = model
        self.calleeName = model.functions[callee].name
        self.callers = callers
        self.onChoose = onChoose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        popover.contentViewController = self
        popover.behavior = .transient
        popover.animates = false
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    var isShown: Bool { popover.isShown }

    func close() { popover.performClose(nil) }

    /// What a row says in one column, for the rows and for tests.
    func text(_ caller: CodeCaller, _ column: Column) -> String {
        switch column {
        case .caller:
            return model.functions[caller.function].name
        case .address:
            return caller.use.map { model.displayAddress($0.from) } ?? "—"
        case .instruction:
            guard let use = caller.use, model.lines.indices.contains(use.line) else { return "" }
            return model.lines[use.line].instruction.text
        case .kind:
            guard let use = caller.use else { return L("Call site unknown") }
            return use.type.uppercased().contains("CALL") ? L("Call") : L("Jump")
        }
    }

    /// A row as the popover writes it: `Caller · 0x68 · CALL 0x230`; a jump
    /// says so, and a caller with no placed call says that instead.
    func rowText(_ caller: CodeCaller) -> String {
        guard caller.use != nil else { return "\(text(caller, .caller)) · \(text(caller, .kind))" }
        var row = [text(caller, .caller), text(caller, .address), text(caller, .instruction)]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        if text(caller, .kind) == L("Jump") { row += " (\(L("Jump")))" }
        return row
    }

    override func loadView() {
        let size = CodePaneView.codeFont().pointSize
        let inset = (size * 1.3).rounded()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = (size * 0.6).rounded()
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)

        let title = NSTextField(labelWithString: L("Callers of %1$@", calleeName))
        title.font = .systemFont(ofSize: (size * 1.35).rounded(), weight: .bold)
        title.isSelectable = true
        title.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(title)

        let count = NSTextField(labelWithString: L("Calls: %1$@", "\(callers.count)"))
        count.font = .systemFont(ofSize: size + 1)
        count.textColor = .secondaryLabelColor
        stack.addArrangedSubview(count)

        // A table: the caller, the call's address and its instruction in
        // columns of their own, every cell a way to the call.
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let grid = NSGridView()
        grid.rowSpacing = stack.spacing / 2
        grid.columnSpacing = size
        for (row, caller) in callers.enumerated() {
            let cells: [String]
            if caller.use == nil {
                cells = [text(caller, .caller), text(caller, .kind), ""]
            } else {
                var instruction = text(caller, .instruction)
                if text(caller, .kind) == L("Jump") { instruction += " (\(L("Jump")))" }
                cells = [text(caller, .caller), text(caller, .address), instruction]
            }
            grid.addRow(with: cells.map { cell -> NSView in
                let button = NSButton(title: cell, target: self, action: #selector(rowChosen(_:)))
                button.isBordered = false
                button.font = font
                button.contentTintColor = caller.use == nil ? .secondaryLabelColor : .linkColor
                button.tag = row
                button.setContentCompressionResistancePriority(.required, for: .horizontal)
                return button
            })
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        let table = grid.fittingSize
        let width = ceil(max(table.width, title.fittingSize.width, count.fittingSize.width))
        if callers.count > Self.mostRows {
            stack.addArrangedSubview(CodeExplanationPopover.scrolling(grid, width: width,
                                                                       height: (size * 18).rounded()))
        } else {
            stack.addArrangedSubview(grid)
        }
        // The popover is as wide as its table: no row is cut.
        stack.widthAnchor.constraint(equalToConstant: width + 2 * inset).isActive = true
        view = stack
    }

    /// Goes to the caller in row `row`: what a click on it does.
    func choose(row: Int) {
        guard callers.indices.contains(row) else { return }
        close()
        onChoose(callers[row])
    }

    @objc private func rowChosen(_ sender: NSButton) { choose(row: sender.tag) }
}
