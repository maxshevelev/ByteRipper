import AppKit
import CodeAnalysis
import Localization
import ToolModuleKit

/// One row of the Callers window: a call to the function, or a caller the
/// analysis knows but whose call it could not place — through a pointer.
struct CodeCaller: Equatable {
    /// The calling function.
    let function: Int
    /// The calling instruction; nil for a caller with no placed call.
    let use: CodeModel.Use?
}

/// Show Callers: every call to one function, in a sheet over the code. A
/// caller that calls three times is three rows, each with the address and the
/// instruction of its call. A double click — or Go To — closes the sheet and
/// opens the caller at that call.
@MainActor final class CodeCallersSheet: NSViewController {
    enum Column: String, CaseIterable {
        case caller = "callers-function", address = "callers-address"
        case instruction = "callers-instruction", kind = "callers-kind"

        var title: String {
            switch self {
            case .caller: L("Caller")
            case .address: L("Call address")
            case .instruction: L("Instruction")
            case .kind: L("Kind")
            }
        }
    }

    private let model: CodeModel
    private let calleeName: String
    let callers: [CodeCaller]
    /// The row chosen: the pane goes there once the sheet is gone.
    private let onChoose: (CodeCaller) -> Void

    private let table = NSTableView()
    private let goButton = NSButton(title: L("Go To"), target: nil, action: nil)

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

    /// What a row says in one column, for the table and for tests.
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

    override func loadView() {
        let title = NSTextField(labelWithString: L("Callers of %1$@", calleeName))
        title.font = ToolPanelFont.title()
        title.lineBreakMode = .byTruncatingMiddle
        title.isSelectable = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let count = NSTextField(labelWithString: L("Calls: %1$@", "\(callers.count)"))
        count.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        count.textColor = .secondaryLabelColor

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
            tableColumn.title = column.title
            tableColumn.resizingMask = .userResizingMask
            tableColumn.width = width(of: column)
            table.addTableColumn(tableColumn)
        }
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder

        goButton.target = self
        goButton.action = #selector(goChosen)
        goButton.keyEquivalent = "\r"
        goButton.isEnabled = !callers.isEmpty
        let close = NSButton(title: L("Close"), target: self, action: #selector(closeChosen))
        close.keyEquivalent = "\u{1b}"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, close, goButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, count, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(2, after: title)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let rows = CGFloat(min(max(callers.count, 6), 16))
        let tall = scroll.heightAnchor.constraint(equalToConstant: rows * (table.rowHeight + 2) + 28)
        tall.priority = .defaultLow
        tall.isActive = true
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 640).isActive = true
        view = stack
        if !callers.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(table)
    }

    /// A column wide enough for what it holds, up to a limit.
    private func width(of column: Column) -> CGFloat {
        let font = column == .caller || column == .kind ? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                                                       : CodePaneView.codeFont()
        var width = (column.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
        for caller in callers {
            width = max(width, (text(caller, column) as NSString).size(withAttributes: [.font: font]).width)
        }
        return min(ceil(width) + 16, 320)
    }

    /// Goes to the caller in row `row`: what a double click and Go To do.
    func choose(row: Int) {
        guard callers.indices.contains(row) else { return }
        let caller = callers[row]
        dismissSheet()
        onChoose(caller)
    }

    @objc private func rowDoubleClicked() {
        // A double click on the header is not a row.
        guard table.clickedRow >= 0 else { return }
        choose(row: table.clickedRow)
    }

    @objc private func goChosen() { choose(row: table.selectedRow) }

    @objc private func closeChosen() { dismissSheet() }

    private func dismissSheet() {
        guard let window = view.window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }
}

extension CodeCallersSheet: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { callers.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let column = Column(rawValue: id.rawValue),
              callers.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = field
            cell.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }()
        let caller = callers[row]
        cell.textField?.font = column == .caller || column == .kind
            ? .systemFont(ofSize: NSFont.systemFontSize) : CodePaneView.codeFont()
        cell.textField?.stringValue = text(caller, column)
        cell.textField?.textColor = column == .kind || caller.use == nil && column != .caller
            ? .secondaryLabelColor : .labelColor
        return cell
    }
}
