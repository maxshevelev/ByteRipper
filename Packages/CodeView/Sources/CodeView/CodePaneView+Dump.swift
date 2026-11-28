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

// The hex dump under the code.
extension CodePaneView {
    // MARK: - The hex dump

    public var isHexDumpVisible: Bool { hexDumpVisible }
    /// The bar over the module's bytes and how tall the bytes are, for a test.
    var dumpBar: CodeDumpBar { hexDumpBar }
    var hexDumpPaneHeight: CGFloat { moduleHexView.frame.height }

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

    @objc func toggleHexDump() {
        setHexDumpVisible(!hexDumpVisible)
    }

    func updateHexDumpButton() {
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
    func layOutNavigatorColumns() {
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
    func postFont(_ entry: CodeArtifact.PostCode, _ column: PostColumn) -> NSFont {
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

    func configure(_ table: NSTableView, identifier: String) {
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

    func configureC() {
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
        PlateLayoutManager.install(in: cTextView)
        PlateLayoutManager.install(in: descriptionView.textView)
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
    /// line names it. The spinner turns beside it while the app reads the
    /// chosen analysis.
    func recipeMenu() -> NSView {
        drawRecipeIcon()
        drawRecipeTitle()
        recipeLine.setChoices(recipes.enumerated().map { .init(title: Self.recipeSummary(of: $1), tag: $0) },
                              chosen: recipes.firstIndex { $0.recipe.id == manifest.recipe.id })
        recipeLine.onChoose = { [weak self] index in self?.chooseRecipe(at: index) }
        recipeLine.translatesAutoresizingMaskIntoConstraints = false
        // Above the stacks' own hugging as the plain line was, so the text is
        // shown whole while the row has room and gives way, truncated, first.
        recipeLine.setContentCompressionResistancePriority(.init(498), for: .horizontal)
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
    func recipeVersions() -> NSView {
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
    func drawRecipeIcon() {
        let size = max(Self.recipeFont().pointSize, 9)
        recipeLine.setIcon(NSImage(systemSymbolName: "tray", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular)))
    }

    /// The line's text: the analysis and the Ghidra version in the quiet grey
    /// of the versions line, whatever the pointer is doing.
    func drawRecipeTitle() {
        recipeLine.title = Self.recipeSummary(of: manifest)
        recipeLine.setFont(Self.recipeFont())
    }

    func label(_ text: String, font: NSFont,
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

}
