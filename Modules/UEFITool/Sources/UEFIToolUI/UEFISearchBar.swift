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
/// It holds no query of its own. What it shows is `UEFISearchSettings`', and
/// what the reader changes goes back there; the other pane's bar reads the
/// same and follows.
// help: panel.uefi.search
@MainActor final class UEFISearchBar: NSView, NSSearchFieldDelegate {
    /// The reader asked for the next match, or the previous.
    var onSearch: ((UEFITreeSearch.Direction) -> Void)?
    /// The reader stopped a search that was still reading branches.
    var onStop: (() -> Void)?

    private let field = NSSearchField()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let typePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let subtypePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let stopButton = NSButton()
    private let meNote = NSTextField(wrappingLabelWithString: "")
    private var observer: NSObjectProtocol?

    /// What the status line says when there is something to say.
    enum Status: Equatable {
        case none
        case notFound
        case searching
    }

    var status: Status = .none {
        didSet { updateStatus() }
    }

    /// Where in the file the row the search is looking at lies, from 0 to 1.
    var progress: Double = 0 {
        didSet { progressBar.doubleValue = min(max(progress, 0), 1) }
    }

    /// Whether the image has an ME region, which the search does not go into.
    var showsMENote = false {
        didSet { meNote.isHidden = !showsMENote }
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

        meNote.stringValue = L("The contents of an ME region are not searched.")
        meNote.font = NSFont.systemFont(ofSize: max(ToolPanelFont.size - 1, 9))
        meNote.textColor = .tertiaryLabelColor
        meNote.isHidden = true

        let top = NSStackView(views: [field, previousButton, nextButton])
        top.orientation = .horizontal
        top.spacing = 8
        top.alignment = .centerY

        let bottom = NSStackView(views: [typePopUp, subtypePopUp, statusLabel, progressBar, stopButton])
        bottom.orientation = .horizontal
        bottom.spacing = 10
        bottom.alignment = .centerY

        let column = NSStackView(views: [top, bottom, meNote])
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
            meNote.widthAnchor.constraint(equalTo: column.widthAnchor),
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
        typePopUp.font = ToolPanelFont.body()
        subtypePopUp.font = ToolPanelFont.body()
        statusLabel.font = ToolPanelFont.body()
        meNote.font = NSFont.systemFont(ofSize: max(ToolPanelFont.size - 1, 9))
    }

    // MARK: - What it shows

    /// Puts the stored query on the controls, without storing it back.
    private func reload() {
        let query = UEFISearchSettings.query
        if field.stringValue != query.text, field.currentEditor() == nil {
            field.stringValue = query.text
        }
        fillTypes(selecting: query.type)
        fillSubtypes(of: query.type, selecting: query.subtype)
        let hasQuery = !query.isEmpty
        previousButton.isEnabled = hasQuery
        nextButton.isEnabled = hasQuery
        if !hasQuery { status = .none }
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
        store(text: field.stringValue)
    }

    /// Return is Next, and Shift-Return Previous — the field's own behaviour
    /// rather than a shortcut of the panel's.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let shifted = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        onSearch?(shifted ? .backward : .forward)
        return true
    }

    /// The field's own action: the clear button, which empties it.
    @objc private func fieldAction() {
        store(text: field.stringValue)
    }

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
