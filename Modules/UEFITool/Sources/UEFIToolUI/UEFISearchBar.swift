import AppKit
import HelpUI
import Localization
import ToolModuleKit
import UEFITool

/// The tree's search bar, between the title and the tree: what to look for
/// on one line — the text, and the two arrows that go to the next and the
/// previous match — and what kind of node on the next, with the one thing the
/// search leaves out said under them when the image has it.
///
/// In its Contents mode it looks for a pattern in what the nodes hold rather
/// than for a node by its name: a text or hex bytes, in the whole tree or in
/// the node selected and everything under it — the box beside the switch says
/// which, and names the node — all at once: Find All, and the results panel
/// under the tree (`UEFIContentResultsView`).
///
/// Three lines: what to search — the switch, the box, and the note on the ME
/// region, which neither search goes into; the text, with the arrows or with
/// the pattern's kind and Find All; and the name search's type and subtype,
/// with how the search went.
///
/// It holds no query of its own. What it shows is `UEFISearchSettings`', and
/// what the reader changes goes back there; the other pane's bar reads the
/// same and follows.
// help: panel.uefi.search
@MainActor final class UEFISearchBar: NSView, NSSearchFieldDelegate {
    /// The reader asked for the next match, or the previous.
    var onSearch: ((UEFITreeSearch.Direction) -> Void)?
    /// The reader stopped a search that was still reading branches.
    var onStop: (() -> Void)?
    /// The reader asked for every match of the Contents search.
    var onFindAll: (() -> Void)?

    private let field = NSSearchField()
    private let modeControl = NSSegmentedControl()
    private let findAllButton = NSButton()
    private let encodingPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scopeCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let scopeLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let typePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let subtypePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let stopButton = NSButton()
    private let meNote = NSTextField(labelWithString: "")
    private var observer: NSObjectProtocol?

    /// What the status line says when there is something to say.
    enum Status: Equatable {
        case none
        case notFound
        case searching
        /// A hex pattern the Contents search cannot read.
        case badPattern
    }

    var status: Status = .none {
        didSet { updateStatus(); updateBottomRow() }
    }

    /// Where in the file the row the search is looking at lies, from 0 to 1.
    var progress: Double = 0 {
        didSet { progressBar.doubleValue = min(max(progress, 0), 1) }
    }

    /// Whether the image has an ME region, which the search does not go into.
    var showsMENote = false {
        didSet { updateMENote() }
    }

    private var mode: UEFISearchSettings.Mode = UEFISearchSettings.mode

    /// The name of the node selected in the tree; nil for none. The Contents
    /// search starts there while the box is ticked.
    var selectedNodeName: String? {
        didSet { if selectedNodeName != oldValue { updateScope() } }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        observer = NotificationCenter.default.addObserver(
            forName: UEFISearchSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Layout

    private func build() {
        field.placeholderString = L("Name or GUID")
        field.delegate = self
        field.target = self
        field.action = #selector(fieldAction)
        // Regular controls, as the dump's Find bar has: a small field and
        // small pop-ups read as a lesser search than the one above the dump.
        field.controlSize = .regular
        field.font = ToolPanelFont.body()
        // The field takes the width the arrows leave; the second line's status
        // takes what its pop-ups leave. Said, so the layout has one answer.
        field.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        ControlHelp.describe(field, name: L("Search the tree"),
                             tooltip: L("Part of a node's name or of its GUID"))

        modeControl.segmentCount = 2
        modeControl.setLabel(L("Names"), forSegment: 0)
        modeControl.setLabel(L("Contents"), forSegment: 1)
        modeControl.trackingMode = .selectOne
        modeControl.controlSize = .regular
        modeControl.font = ToolPanelFont.body()
        modeControl.target = self
        modeControl.action = #selector(modeChosen)
        modeControl.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        ControlHelp.describe(modeControl, name: L("What to search"),
                             tooltip: L("Search the nodes' names and GUIDs, or the bytes the nodes hold"))

        findAllButton.title = L("Find All")
        findAllButton.bezelStyle = .rounded
        findAllButton.controlSize = .regular
        findAllButton.font = ToolPanelFont.body()
        findAllButton.target = self
        findAllButton.action = #selector(findAllClicked)
        findAllButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        ControlHelp.describe(findAllButton, name: L("Find All"),
                             tooltip: L("List every place the pattern occurs, compressed sections included"))

        encodingPopUp.controlSize = .regular
        encodingPopUp.font = ToolPanelFont.body()
        encodingPopUp.target = self
        encodingPopUp.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        encodingPopUp.addItems(withTitles: [L("Text"), L("Hex")])
        encodingPopUp.action = #selector(encodingChosen)
        ControlHelp.describe(encodingPopUp, name: L("Pattern"),
                             tooltip: L("Text is found in ASCII and in UTF-16, in any case; hex is bytes, ?? for any byte"))

        scopeCheck.title = L("The whole tree")
        scopeCheck.font = ToolPanelFont.body()
        scopeCheck.target = self
        scopeCheck.action = #selector(scopeChosen)
        scopeCheck.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        ControlHelp.describe(scopeCheck, name: L("The whole tree"),
                             tooltip: L("Search the whole tree; unticked, the selected node and what is under it"))
        scopeLabel.font = ToolPanelFont.body()
        scopeLabel.textColor = .secondaryLabelColor
        scopeLabel.lineBreakMode = .byTruncatingMiddle
        scopeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scopeLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)


        configure(previousButton, symbol: "chevron.left", name: L("Previous match"),
                  tooltip: L("Go to the previous node that matches"), action: #selector(previousClicked))
        configure(nextButton, symbol: "chevron.right", name: L("Next match"),
                  tooltip: L("Go to the next node that matches"), action: #selector(nextClicked))

        typePopUp.controlSize = .regular
        subtypePopUp.controlSize = .regular
        typePopUp.font = ToolPanelFont.body()
        subtypePopUp.font = ToolPanelFont.body()
        typePopUp.target = self
        typePopUp.action = #selector(typeChosen)
        subtypePopUp.target = self
        subtypePopUp.action = #selector(subtypeChosen)
        ControlHelp.describe(typePopUp, name: L("Type"), tooltip: L("Only nodes of this type"))
        ControlHelp.describe(subtypePopUp, name: L("Subtype"),
                             tooltip: L("Only files or sections of this kind"))

        statusLabel.font = ToolPanelFont.body()
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        for popUp in [typePopUp, subtypePopUp] {
            popUp.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        }

        // Where "Not found" is said: the line that reports how the search went.
        // It shows where in the file the search is looking — not how much is
        // left, which nobody knows before the branches are read.
        progressBar.style = .bar
        progressBar.controlSize = .regular
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        configure(stopButton, symbol: "xmark.circle.fill", name: L("Stop searching"),
                  tooltip: L("Stop reading branches to look for a match"), action: #selector(stopClicked))
        stopButton.contentTintColor = .tertiaryLabelColor

        meNote.stringValue = L("ME Region is not searched")
        meNote.font = NSFont.systemFont(ofSize: max(ToolPanelFont.size - 1, 9))
        meNote.lineBreakMode = .byTruncatingTail
        meNote.maximumNumberOfLines = 1
        meNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        meNote.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        meNote.textColor = .tertiaryLabelColor
        meNote.isHidden = true

        let head = NSStackView(views: [modeControl, scopeCheck, scopeLabel, meNote])
        head.orientation = .horizontal
        head.spacing = 10
        head.alignment = .centerY
        head.setCustomSpacing(4, after: scopeCheck)

        let top = NSStackView(views: [field, previousButton, nextButton, encodingPopUp, findAllButton])
        top.orientation = .horizontal
        top.spacing = 8
        top.alignment = .centerY

        let bottom = NSStackView(views: [typePopUp, subtypePopUp,
                                         statusLabel, progressBar, stopButton])
        bottom.orientation = .horizontal
        bottom.spacing = 10
        bottom.alignment = .centerY

        bottomRow = bottom
        let column = NSStackView(views: [head, top, bottom])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 4, right: 0)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            top.widthAnchor.constraint(equalTo: column.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: column.widthAnchor),
            head.widthAnchor.constraint(equalTo: column.widthAnchor),
            progressBar.widthAnchor.constraint(equalToConstant: 90),
            stopButton.widthAnchor.constraint(equalToConstant: 16),
            stopButton.heightAnchor.constraint(equalToConstant: 16),
            previousButton.widthAnchor.constraint(equalToConstant: 18),
            nextButton.widthAnchor.constraint(equalToConstant: 18)
        ])
        // The status line as the status says, from the start: `status` sets
        // it only when it changes, and until the first search the stop
        // button stood at the bar's end with no progress bar beside it.
        updateStatus()
    }

    private func configure(_ button: NSButton, symbol: String, name: String, tooltip: String,
                           action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        ControlHelp.describe(button, name: name, tooltip: tooltip)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    /// The panel's type size moved.
    func applyFont() {
        field.font = ToolPanelFont.body()
        modeControl.font = ToolPanelFont.body()
        findAllButton.font = ToolPanelFont.body()
        encodingPopUp.font = ToolPanelFont.body()
        scopeCheck.font = ToolPanelFont.body()
        scopeLabel.font = ToolPanelFont.body()
        typePopUp.font = ToolPanelFont.body()
        subtypePopUp.font = ToolPanelFont.body()
        statusLabel.font = ToolPanelFont.body()
        meNote.font = NSFont.systemFont(ofSize: max(ToolPanelFont.size - 1, 9))
    }

    // MARK: - What it shows

    /// Puts the stored query on the controls, without storing it back.
    private func reload() {
        let newMode = UEFISearchSettings.mode
        if newMode != mode {
            mode = newMode
            status = .none
        }
        let contents = mode == .contents
        modeControl.selectedSegment = contents ? 1 : 0
        for view in [previousButton, nextButton, typePopUp, subtypePopUp] as [NSView] { view.isHidden = contents }
        for view in [findAllButton, encodingPopUp, scopeCheck] as [NSView] { view.isHidden = !contents }
        updateMENote()
        updateBottomRow()
        if contents {
            let content = UEFISearchSettings.content
            if field.stringValue != content.text, field.currentEditor() == nil || field.placeholderString != contentPlaceholder {
                field.stringValue = content.text
            }
            field.placeholderString = contentPlaceholder
            ControlHelp.describe(field, name: L("Search the contents"),
                                 tooltip: L("A text, or hex bytes such as 24 ?? 4D 49"))
            encodingPopUp.selectItem(at: content.isHex ? 1 : 0)
            scopeCheck.state = content.wholeTree ? .on : .off
            updateScope()
            findAllButton.isEnabled = !content.text.trimmingCharacters(in: .whitespaces).isEmpty
            return
        }
        let query = UEFISearchSettings.query
        if field.stringValue != query.text, field.currentEditor() == nil || field.placeholderString != namesPlaceholder {
            field.stringValue = query.text
        }
        field.placeholderString = namesPlaceholder
        ControlHelp.describe(field, name: L("Search the tree"),
                             tooltip: L("Part of a node's name or of its GUID"))
        fillTypes(selecting: query.type)
        fillSubtypes(of: query.type, selecting: query.subtype)
        let hasQuery = !query.isEmpty
        previousButton.isEnabled = hasQuery
        nextButton.isEnabled = hasQuery
        if !hasQuery { status = .none }
    }

    /// The third line: the name search's type and subtype; in Contents mode
    /// there only to say a pattern is not one.
    private var bottomRow: NSStackView?

    private func updateBottomRow() {
        bottomRow?.isHidden = mode == .contents && status != .badPattern
    }

    /// The words after the box, while it is clear: the node Find All will
    /// start from.
    private func updateScope() {
        let content = UEFISearchSettings.content
        scopeLabel.isHidden = mode != .contents || content.wholeTree
        scopeLabel.stringValue = selectedNodeName.map { L("from %1$@", $0) }
            ?? L("Nothing selected: the whole tree")
        scopeLabel.toolTip = scopeLabel.stringValue
    }

    private var namesPlaceholder: String { L("Name or GUID") }
    private var contentPlaceholder: String {
        UEFISearchSettings.content.isHex ? L("Hex bytes") : L("Text to find")
    }

    /// The note on the ME region, which neither search goes into, while the
    /// image has one — but not for a Contents search from the selected node,
    /// whose own place is what the line says then.
    private func updateMENote() {
        let fromNode = mode == .contents && !UEFISearchSettings.content.wholeTree
        meNote.isHidden = !showsMENote || fromNode
    }

    private func fillTypes(selecting type: UInt8?) {
        typePopUp.removeAllItems()
        typePopUp.addItem(withTitle: L("Any type"))
        typePopUp.lastItem?.tag = -1
        for choice in UEFITreeSearchChoices.types {
            typePopUp.addItem(withTitle: choice.name)
            typePopUp.lastItem?.tag = Int(choice.code)
        }
        typePopUp.selectItem(withTag: type.map(Int.init) ?? -1)
    }

    private func fillSubtypes(of type: UInt8?, selecting subtype: UInt8?) {
        subtypePopUp.removeAllItems()
        subtypePopUp.addItem(withTitle: L("Any subtype"))
        subtypePopUp.lastItem?.tag = -1
        let choices = UEFITreeSearchChoices.subtypes(of: type)
        for choice in choices {
            subtypePopUp.addItem(withTitle: choice.name)
            subtypePopUp.lastItem?.tag = Int(choice.code)
        }
        subtypePopUp.isEnabled = !choices.isEmpty
        subtypePopUp.selectItem(withTag: choices.isEmpty ? -1 : (subtype.map(Int.init) ?? -1))
    }

    private func updateStatus() {
        switch status {
        case .badPattern:
            statusLabel.stringValue = L("Not a hex pattern")
            statusLabel.isHidden = false
            progressBar.isHidden = true
            stopButton.isHidden = true
        case .none, .notFound:
            statusLabel.stringValue = status == .notFound ? L("Not found") : ""
            statusLabel.isHidden = false
            progressBar.isHidden = true
            stopButton.isHidden = true
        case .searching:
            statusLabel.isHidden = true
            progressBar.isHidden = false
            stopButton.isHidden = false
        }
    }

    /// The text field takes the keyboard: the bar has just been opened.
    func focusField() {
        window?.makeFirstResponder(field)
    }

    // MARK: - What the reader does

    private func storeContent(_ change: (inout UEFISearchSettings.Content) -> Void) {
        var content = UEFISearchSettings.content
        change(&content)
        if status != .searching { status = .none }
        UEFISearchSettings.content = content
    }

    private func store(text: String? = nil, type: UInt8?? = nil, subtype: UInt8?? = nil) {
        var query = UEFISearchSettings.query
        if let text { query.text = text }
        if let type { query.type = type }
        if let subtype { query.subtype = subtype }
        if !UEFITreeQuery.hasSubtypes(query.type) { query.subtype = nil }
        status = .none
        UEFISearchSettings.query = query
    }

    func controlTextDidChange(_ notification: Notification) {
        if mode == .contents {
            let text = field.stringValue
            storeContent { $0.text = text }
        } else {
            store(text: field.stringValue)
        }
    }

    /// Return is Next, and Shift-Return Previous — the field's own behaviour
    /// rather than a shortcut of the panel's.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if mode == .contents {
            onFindAll?()
            return true
        }
        let shifted = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        onSearch?(shifted ? .backward : .forward)
        return true
    }

    /// The field's own action: the clear button, which empties it.
    @objc private func fieldAction() {
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    @objc private func modeChosen() {
        UEFISearchSettings.mode = modeControl.selectedSegment == 1 ? .contents : .names
    }

    @objc private func encodingChosen() {
        let isHex = encodingPopUp.indexOfSelectedItem == 1
        storeContent { $0.isHex = isHex }
    }

    @objc private func scopeChosen() {
        let wholeTree = scopeCheck.state == .on
        storeContent { $0.wholeTree = wholeTree }
    }

    @objc private func findAllClicked() { onFindAll?() }

    @objc private func typeChosen() {
        let tag = typePopUp.selectedItem?.tag ?? -1
        store(type: .some(tag < 0 ? nil : UInt8(tag)), subtype: .some(nil))
    }

    @objc private func subtypeChosen() {
        let tag = subtypePopUp.selectedItem?.tag ?? -1
        store(subtype: .some(tag < 0 ? nil : UInt8(tag)))
    }

    @objc private func previousClicked() { onSearch?(.backward) }
    @objc private func nextClicked() { onSearch?(.forward) }
    @objc private func stopClicked() { onStop?() }
}
