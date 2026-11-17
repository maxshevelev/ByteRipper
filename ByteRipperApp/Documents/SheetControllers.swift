import AppPalette
import Cocoa
import ByteRipperCore
import Localization

// MARK: - Shared sheet chrome

/// Base class for the input dialogs (Go To Position, Select Block).
/// Builds a titled sheet with a field stack, an inline error label, and a
/// Cancel/Submit button row; subclasses add fields and validation (§10).
class SheetViewController: NSViewController {
    let titleText: String
    let messageText: String?
    private(set) var contentStack: NSStackView!
    private(set) var errorLabel: NSTextField!
    /// What the sheet has to say when nothing is wrong — a sum read back under
    /// the field it was typed in (issue #9). On the error's own line: there is
    /// one or the other, never both.
    private(set) var noteLabel: NSTextField!
    private(set) var buttonRow: NSStackView!
    private(set) var submitButton: NSButton!
    /// The Esc button, so a subclass that wants it to say something else
    /// can say so. Matching it by its title instead worked only while the
    /// title was English: `L("Cancel")` is «Отмена» in Russian, and the
    /// relabel then found nothing and left the wrong word standing.
    private(set) var cancelButton: NSButton!

    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    /// Set synchronously around the `makeFirstResponder` call in `viewDidAppear`.
    /// AppKit fires the field's action (`submitPressed`) as a side effect of
    /// `makeFirstResponder` ending the field-editing session that the sheet's
    /// initial focus started; suppressing it keeps the sheet from dismissing
    /// itself before it ever attaches.
    private var presentationInProgress = false

    init(title: String, message: String?) {
        self.titleText = title
        self.messageText = message
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 16, right: 18)

        let titleLabel = NSTextField(labelWithString: titleText)
        titleLabel.font = .boldSystemFont(ofSize: 13)

        root.addArrangedSubview(titleLabel)

        if let messageText {
            let messageLabel = NSTextField(wrappingLabelWithString: messageText)
            messageLabel.font = .systemFont(ofSize: 12)
            messageLabel.textColor = .secondaryLabelColor
            root.addArrangedSubview(messageLabel)
        }

        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        root.addArrangedSubview(contentStack)

        // Indented to the fields' own left edge, not the sheet's: the message is
        // about a field, and a line starting under the labels reads as a line of
        // the sheet (§10).
        errorLabel = NSTextField(labelWithString: "")
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = SemanticColors.bad
        let errorIndent = NSView()
        errorIndent.translatesAutoresizingMaskIntoConstraints = false
        errorIndent.widthAnchor.constraint(equalToConstant: Self.fieldLabelWidth).isActive = true
        noteLabel = NSTextField(labelWithString: "")
        noteLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.lineBreakMode = .byTruncatingMiddle
        // A long sum is cut in the middle rather than widening the sheet.
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noteLabel.isSelectable = true
        noteLabel.isHidden = true
        let errorRow = NSStackView(views: [errorIndent, errorLabel, noteLabel])
        errorRow.orientation = .horizontal
        errorRow.alignment = .centerY
        errorRow.spacing = Self.fieldRowSpacing
        root.addArrangedSubview(errorRow)

        buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonRow.addArrangedSubview(spacer)

        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1B}"  // Esc
        buttonRow.addArrangedSubview(cancel)
        cancelButton = cancel

        let submit = NSButton(title: L("OK"), target: self, action: #selector(submitPressed))
        submit.keyEquivalent = "\r"
        buttonRow.addArrangedSubview(submit)
        submitButton = submit

        root.addArrangedSubview(buttonRow)
        // The message belongs to the fields above it, so it sits close under them
        // and the full gap is the one before the buttons (§10).
        root.setCustomSpacing(5, after: contentStack)
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            buttonRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36),
        ])

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentView.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
        ])
        // A concrete default frame lets `presentAsSheet` size the sheet window
        // even before auto layout runs (the view arrives with a zero frame).
        // Height is only a starting point — nothing pins a minimum, so a sheet is
        // as tall as its own rows: a floor of 200 pt left the one-field sheets
        // (Fill Selection) with a hand's width of nothing between the field and
        // the buttons, because the slack had to go somewhere.
        contentView.frame = NSRect(x: 0, y: 0, width: 420, height: 170)
        view = contentView
    }

    /// The starting frame is made as wide as the rows the subclass added in its
    /// own `loadView`: it is only where layout starts from, but rows wider than
    /// it — the address rows, a longer translation — are laid out clipped until
    /// a window resizes it.
    override func viewDidLoad() {
        super.viewDidLoad()
        view.frame.size.width = max(view.frame.width, view.fittingSize.width)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let field = firstField() {
            // The sheet's initial focus already made the field's field editor
            // first responder; calling makeFirstResponder again ends that
            // editing session synchronously, and `textDidEndEditing` sends the
            // field's action (`submitPressed`). Suppress that transient event —
            // a real submit from the OK button / Return happens later, after the
            // sheet is attached and this flag is clear again.
            presentationInProgress = true
            view.window?.makeFirstResponder(field)
            presentationInProgress = false
            // The caret lands after the "0x" prefix via `AddressField`, which
            // never selects the field's whole text on focus.
        }
    }

    // MARK: - Overridable

    /// The first focusable text field (default: nil).
    func firstField() -> NSView? { nil }

    /// Returns an error message, or nil when the input is valid.
    func validate() -> String? { nil }

    /// Called after successful validation and dismissal.
    func handleSubmit() { onSubmit?() }

    /// Called when the user cancels.
    func handleCancel() { onCancel?() }

    // MARK: - Actions

    @objc func submitPressed() {
        // Ignore the action fired by the sheet's initial focus setup (see
        // `presentationInProgress`); the user cannot have submitted yet.
        guard !presentationInProgress else { return }
        if let error = validate() {
            showError(error)
            return
        }
        dismiss(self)
        handleSubmit()
    }

    @objc func cancelPressed() {
        dismiss(self)
        handleCancel()
    }

    func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        noteLabel.isHidden = true
    }

    fileprivate func showNote(_ note: String?) {
        noteLabel.stringValue = note ?? ""
        noteLabel.isHidden = note == nil
    }

    /// Re-runs `validate()` on every keystroke (fired from the field's
    /// `textDidChange`) and updates the error label, so a stale error clears
    /// the moment the input becomes valid instead of lingering until the user
    /// submits or leaves the field (§10). Both hex (with "0x") and decimal
    /// inputs validate the same way `submitPressed` does. `fileprivate` so the
    /// subclasses' field builders can wire `onTextChange` to it.
    fileprivate func updateLiveError() {
        if let error = liveProblem() {
            showError(error)
        } else {
            errorLabel.isHidden = true
            showNote(liveNote())
        }
    }

    /// What is wrong while the user types (default: `validate()`). A sheet
    /// whose field can hold something unfinished rather than wrong — a sum
    /// ending at its operator — excuses that field here, and only that one:
    /// OK still refuses it, through `validate()`.
    func liveProblem() -> String? { validate() }

    /// What to show on the message's line while the input is valid (default:
    /// nothing).
    func liveNote() -> String? { nil }

    /// The width every row's label column gets, and the gap to the field beside
    /// it. Shared with the error message, which is indented by exactly this much
    /// so it lines up with the fields it is about.
    static let fieldLabelWidth: CGFloat = 110
    static let fieldRowSpacing: CGFloat = 8

    /// Builds a label + text field row inside `contentStack` and returns the field.
    func addFieldRow(label text: String, initial: String) -> NSTextField {
        // A byte sequence, not an address (those are `AddressField`): the
        // caret lands after the pattern offered, so it can be added to.
        let field = CaretAtEndTextField(string: initial)
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.onTextChange = { [weak self] in self?.updateLiveError() }
        addRow(leading: fieldLabel(text), field: field, width: 240, name: text)
        return field
    }

    /// The same row for an address or a length: the app's one field for those
    /// (`AddressField`), which takes a sum as well as a number and shows what
    /// it comes to. Wider than a plain field — it holds the sum, the result and
    /// the list of recent entries side by side.
    func addAddressRow(label text: String, initial: String) -> AddressField {
        addAddressRow(leading: fieldLabel(text), initial: initial, name: text)
    }

    /// An address row behind any leading view — a label, or the radio button
    /// that names the field instead of one.
    func addAddressRow(leading: NSView, initial: String, name: String) -> AddressField {
        let field = AddressField(text: initial)
        field.onTextChange = { [weak self, weak field] in
            self?.lastEditedAddressField = field
            self?.updateLiveError()
        }
        addRow(leading: leading, field: field, width: 300, name: name)
        return field
    }

    /// The address field typed in last — the one whose sum the sheet reads back.
    fileprivate(set) weak var lastEditedAddressField: AddressField?

    /// A row's label: right-aligned in the label column.
    private func fieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    private func addRow(leading: NSView, field: NSTextField, width: CGFloat, name: String) {
        leading.translatesAutoresizingMaskIntoConstraints = false
        leading.widthAnchor.constraint(equalToConstant: Self.fieldLabelWidth).isActive = true

        field.target = self
        field.action = #selector(submitPressed)
        // §10: submit only on OK / Return — losing focus (e.g. clicking another
        // field) must NOT activate the selection. The flag lives on the cell.
        field.cell?.sendsActionOnEndEditing = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        field.setAccessibilityLabel(name)  // §15: VoiceOver names the field.

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Self.fieldRowSpacing
        row.addArrangedSubview(leading)
        row.addArrangedSubview(field)
        contentStack.addArrangedSubview(row)
    }
}

// Go To Position was a sheet of its own until the bookmark list arrived; both
// answer "go where?", so they are one form now — `GoToBookmarksController`
// (§10.1).

// MARK: - Select Block (§10.2)

/// Select a range by Start and one of End or Length. Three fields — Start, End,
/// Length — with standard radio buttons before End and Length: exactly one of
/// the two is active at a time, and the inactive field is disabled but keeps the
/// value the user typed, so switching back restores it (§10.2). The radios are
/// plain `NSButton` radio buttons (no custom controls); exclusivity is managed
/// by their shared action.
///
/// End is the address of the block's LAST byte (inclusive) — the selection's
/// half-open `[start, end)` is built as `[start, end + 1)`.
///
/// A `presetStart` opens the sheet from the offset context menu ("Select Block
/// from Here at «address»"): Start is pre-filled with that address, the Length option is
/// active from the start, and the cursor lands in the Length field.
final class SelectBlockSheetController: SheetViewController {
    private let fileSize: UInt64
    private let presetStart: UInt64?
    private let onSelect: (SelectionModel) -> Void

    /// `private(set)` so tests can read the widgets and set their values.
    private(set) var startField: AddressField!
    private(set) var endField: AddressField!
    private(set) var lengthField: AddressField!
    private(set) var endRadio: NSButton!
    private(set) var lengthRadio: NSButton!
    /// The bottom-left shortcuts: select from the Start field's position to the
    /// beginning of the file, or to its end.
    private(set) var toBeginningButton: NSButton!
    private(set) var toEndButton: NSButton!

    init(fileSize: UInt64, presetStart: UInt64? = nil, onSelect: @escaping (SelectionModel) -> Void) {
        self.fileSize = fileSize
        self.presetStart = presetStart
        self.onSelect = onSelect
        // No message when the start is already filled in ("Select Block from Here at
        // «address»", §10.2): the Start field shows that address, the Length option is
        // already the active one, and a sentence saying both was the sheet
        // narrating its own fields back at the user.
        super.init(title: L("Select Block"),
                   message: presetStart == nil
                       ? L("Select a byte range by absolute offsets. End is the block's last byte.")
                       : nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        super.loadView()

        // Two shortcuts in the bottom-left corner (before the spacer that pins
        // Cancel/OK to the right): select from the Start field's position to the
        // beginning of the file, or to its end. They only read the Start field —
        // the End/Length option is irrelevant to a selection that runs to a file
        // boundary.
        toBeginningButton = NSButton(title: L("To Beginning"), target: self, action: #selector(toBeginningPressed))
        toEndButton = NSButton(title: L("To End"), target: self, action: #selector(toEndPressed))
        buttonRow.insertArrangedSubview(toBeginningButton, at: 0)
        buttonRow.insertArrangedSubview(toEndButton, at: 1)

        startField = addAddressRow(label: L("Start:"),
                                   initial: presetStart.map(OffsetExpression.hex) ?? "0x")

        let end = addRadioFieldRow(title: L("End"), action: #selector(modeRadioChanged(_:)))
        endRadio = end.radio
        endField = end.field

        let length = addRadioFieldRow(title: L("Length"), action: #selector(modeRadioChanged(_:)))
        lengthRadio = length.radio
        lengthField = length.field

        if presetStart != nil {
            // §10.2 "Select Block from Here at «address»": Start is pre-filled with the
            // right-clicked address, so Length is the active option from the
            // start. `isEnabled = false` keeps the End field's value untouched.
            endRadio.state = .off
            lengthRadio.state = .on
            endField.isEnabled = false
            lengthField.isEnabled = true
        } else {
            // Default: End mode — End is editable, Length is disabled but
            // retains its text. `isEnabled = false` keeps `stringValue` untouched.
            endRadio.state = .on
            lengthRadio.state = .off
            lengthField.isEnabled = false
        }
    }

    override func firstField() -> NSView? {
        // §10.2: with a pre-filled start the user's job is the length, so focus
        // the Length field (and position its caret after the "0x" prefix).
        presetStart != nil ? lengthField : startField
    }

    /// Builds a radio button + address field row (the End / Length pair). The
    /// radio carries the field's name, replacing the label column of
    /// `addAddressRow(label:)`; the same fixed width keeps the fields
    /// column-aligned with Start's.
    private func addRadioFieldRow(title: String, action: Selector) -> (radio: NSButton, field: AddressField) {
        let radio = NSButton(radioButtonWithTitle: title, target: self, action: action)
        radio.font = .systemFont(ofSize: 12)
        return (radio, addAddressRow(leading: radio, initial: "0x", name: title))
    }

    /// The shared radio action keeps the two options mutually exclusive: clicking
    /// one turns the other off and swaps which field is editable. The field that
    /// becomes disabled keeps its value, so switching back restores it (§10.2).
    @objc private func modeRadioChanged(_ sender: NSButton) {
        let useLength = sender === lengthRadio
        endRadio.state = useLength ? .off : .on
        lengthRadio.state = useLength ? .on : .off
        endField.isEnabled = !useLength
        lengthField.isEnabled = useLength
        // A sum read back from the field just switched off goes, and the one
        // in the field switched on takes its place; Start's stays. An error
        // already shown is checked again — but the switch does not raise one
        // for a field nobody has typed in yet.
        if lastEditedAddressField === (useLength ? endField : lengthField) {
            lastEditedAddressField = secondField
        }
        if errorLabel.isHidden || errorLabel.stringValue.isEmpty {
            showNote(liveNote())
        } else {
            updateLiveError()
        }
    }

    /// The End or Length field, whichever the radios make the active one.
    private var secondField: AddressField {
        endRadio.state == .on ? endField : lengthField
    }

    /// What a field holds, as the checks need it: the number it names, the
    /// sentence for why it names none — or, for the field being typed in, a sum
    /// still waiting for its last term.
    private enum Reading {
        case number(UInt64)
        case wrong(String)
        case waiting
    }

    private func read(_ field: AddressField, invalid: String, waiting: AddressField?) -> Reading {
        switch field.evaluation {
        case .success(let expression):
            return .number(expression.value)
        case .failure(.incomplete) where field === waiting:
            return .waiting
        case .failure:
            return .wrong(field.problemMessage ?? invalid)
        }
    }

    /// Only the field being typed in waits: an unfinished sum left behind in
    /// another field, or any other mistake in one, is named as usual.
    override func liveProblem() -> String? {
        let typing = lastEditedAddressField.flatMap { $0.isEnabled ? $0 : nil }
        return problem(waitingFor: typing)
    }

    /// The sum being typed, read back in hex with its result (issue #9).
    override func liveNote() -> String? {
        guard let field = lastEditedAddressField, field.isEnabled else { return nil }
        return field.breakdown
    }

    override func validate() -> String? { problem(waitingFor: nil) }

    /// The first thing wrong, or nil. With no field `waiting`, nil means every
    /// field in use names a number — there is no path that lets a field with
    /// none through.
    private func problem(waitingFor waiting: AddressField?) -> String? {
        let start: UInt64?
        switch startReading(waitingFor: waiting) {
        case .wrong(let message): return message
        case .waiting: start = nil
        case .number(let value): start = value
        }
        if endRadio.state == .on {
            switch read(endField, invalid: L("Invalid end offset."), waiting: waiting) {
            case .wrong(let message):
                return message
            case .waiting:
                break
            case .number(let end):
                if let start, start > end {
                    return L("Start must not exceed end.")
                }
                // End is the address of the block's LAST byte, so it must point
                // at a real byte — the maximum is fileSize - 1 (the selection's
                // half-open upper bound is end + 1).
                if end >= fileSize {
                    return L("End is beyond the end of the file.")
                }
            }
        } else if case .wrong(let message) = read(lengthField, invalid: L("Invalid length."), waiting: waiting) {
            return message
        }
        return nil
    }

    /// The Start field read, with the file's end checked as well.
    private func startReading(waitingFor waiting: AddressField?) -> Reading {
        let reading = read(startField, invalid: L("Invalid start offset."), waiting: waiting)
        if case .number(let start) = reading, start > fileSize {
            return .wrong(L("Start is beyond the end of the file."))
        }
        return reading
    }

    override func handleSubmit() {
        guard let start = startField.value, start <= fileSize else { return }
        if endRadio.state == .on {
            guard let end = endField.value, end < fileSize else { return }
            keepSums(in: [startField, endField])
            // End is the last byte INCLUDED; the internal half-open range ends
            // just past it.
            onSelect(SelectionModel(start: start, end: end + 1, fileSize: fileSize))
        } else {
            guard let length = lengthField.value else { return }
            keepSums(in: [startField, lengthField])
            onSelect(SelectionModel(start: start, length: length, fileSize: fileSize))
        }
    }

    /// A sum the selection was made from goes into the fields' list, so it can
    /// be picked again and corrected. A plain number does not: the list would
    /// fill with every length ever typed.
    private func keepSums(in fields: [AddressField]) {
        // The start last, so it is the entry the list opens on.
        for field in fields.reversed() { field.recordInHistory() }
    }

    // MARK: - To Beginning / To End

    /// The error for the Start field alone, or nil when it names a valid
    /// position. The two boundary buttons ignore the End/Length option, so they
    /// validate only what they actually use.
    private func startError() -> String? {
        if case .wrong(let message) = startReading(waitingFor: nil) { return message }
        return nil
    }

    /// "To Beginning": select `[0, start)` — from the file's start to the
    /// position the Start field names.
    @objc private func toBeginningPressed() {
        if let error = startError() {
            showError(error)
            return
        }
        dismiss(self)
        submitToBeginning()
    }

    /// "To End": select `[start, fileSize)` — from the position the Start field
    /// names to the file's end.
    @objc private func toEndPressed() {
        if let error = startError() {
            showError(error)
            return
        }
        dismiss(self)
        submitToEnd()
    }

    /// The selection "To Beginning" produces: `[0, start)`. Reads and parses the
    /// Start field itself, so a test drives it without presenting the sheet —
    /// the button action only adds the dismiss.
    func submitToBeginning() {
        guard let start = startField.value, start <= fileSize else { return }
        startField.recordInHistory()
        onSelect(SelectionModel(start: 0, end: start, fileSize: fileSize))
    }

    /// The selection "To End" produces: `[start, fileSize)`.
    func submitToEnd() {
        guard let start = startField.value, start <= fileSize else { return }
        startField.recordInHistory()
        onSelect(SelectionModel(start: start, end: fileSize, fileSize: fileSize))
    }
}

// MARK: - Fill Selection (§7.3)

/// Remembers the last byte pattern used in Edit > Fill Selection with… so the
/// next fill starts from it instead of always defaulting to `FF`. Persisted in
/// `UserDefaults` (same pattern as `WordSize`), so it survives app restarts.
enum FillPatternStore {
    static let userDefaultsKey = "LastFillPattern"
    static let defaultPattern = "FF"

    /// The last pattern the user filled with, or `defaultPattern` when none is
    /// saved yet.
    static var last: String {
        AppDefaults.store.string(forKey: userDefaultsKey) ?? defaultPattern
    }

    /// Persists `pattern` as the value to offer next time.
    static func save(_ pattern: String) {
        AppDefaults.store.set(pattern, forKey: userDefaultsKey)
    }
}

/// Edit > Fill Selection with…: a hex byte sequence repeated across the
/// selection, defaulting to the last used pattern (or `FF`). Uses the same hex
/// parsing as Find.
final class FillSheetController: SheetViewController {
    private var bytesField: NSTextField!
    private let onFill: ([UInt8]) -> Void

    init(selectionCount: UInt64, onFill: @escaping ([UInt8]) -> Void) {
        self.onFill = onFill
        super.init(title: L("Fill Selection with…"),
                   message: L("Fill the selected %1$@ byte(s) by repeating the byte sequence.", selectionCount))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        super.loadView()
        bytesField = addFieldRow(label: L("Bytes:"), initial: FillPatternStore.last)
    }

    override func firstField() -> NSView? { bytesField }

    override func validate() -> String? {
        let text = bytesField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return L("Enter at least one byte (e.g. FF).") }
        do {
            _ = try SearchEngine.parsePattern(text, encoding: .hex)
            return nil
        } catch {
            return L("Invalid hex — use pairs like DE AD BE EF.")
        }
    }

    override func handleSubmit() {
        guard let pattern = try? SearchEngine.parsePattern(bytesField.stringValue, encoding: .hex) else { return }
        // Remember the raw text as typed (trimmed of surrounding whitespace), so
        // the next fill offers the same pattern (§7.3).
        FillPatternStore.save(bytesField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        onFill(pattern.bytes)
    }
}

// MARK: - Find history (§11)

/// Remembers the last searches (pattern + encoding + case-sensitivity) so the
/// Find bar can offer them in the pattern combo and default to the most recent
/// one. Persisted in `UserDefaults` (same pattern as `WordSize`); capped at 10
/// entries, most recent first, one entry per (pattern, encoding) pair.
enum FindHistoryStore {
    static let userDefaultsKey = "FindHistory"
    static let limit = 10

    /// The defaults domain the history lives in. Swappable so tests run against
    /// an isolated store instead of the real app's `UserDefaults.standard`
    /// (which would otherwise pick up and pollute the user's own searches §11).
    static var defaults: UserDefaults = AppDefaults.store

    /// A recent search is `SearchPatternEntry` with no name — a favourite is
    /// the same thing named, and one type serves both lists in the bar's menu
    /// (§11, `Design/PATTERN_LIBRARY_IDEA.md`).
    typealias Entry = SearchPatternEntry

    /// The saved searches, most recent first.
    static var recent: [Entry] {
        // The stored rows now mix Strings and a Bool, so the array casts to
        // [[String: Any]] (a [[String: String]] cast would fail and wipe the
        // whole history).
        guard let raw = defaults.array(forKey: userDefaultsKey) as? [[String: Any]] else { return [] }
        return raw.compactMap(Entry.init(stored:))
    }

    /// Forgets every recent search — **Clear Recents** in the Find bar's menu
    /// (§11). The favourites are a separate list and are not touched.
    static func clear() {
        defaults.removeObject(forKey: userDefaultsKey)
    }

    /// The most recent search — the default the sheet offers on open.
    static var mostRecent: Entry? { recent.first }

    /// Records a search: moves the (pattern, encoding) pair to the front,
    /// dropping any older entry with the SAME pair, and capping the list at
    /// `limit`. The same pattern under a different encoding is a separate item
    /// — "abcd" as ASCII and "abcd" as hex both stay in the history (§11).
    /// The `caseSensitive` flag rides along with the pair: re-recording the same
    /// pair with a different flag replaces the entry (latest search wins), and
    /// the flag is what the dropdown's "(CS)" suffix reflects.
    ///
    /// Returns whether the list actually changed. Re-running the search that is
    /// already at the front changes nothing, and that is the common case: every
    /// press of ‹ › records the same pair, and the caller would otherwise
    /// rebuild the dropdown's items each time (§11).
    @discardableResult
    static func record(pattern: String, encoding: SearchEncoding,
                       caseSensitive: Bool = false) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let before = recent
        var entries = before.filter { !($0.pattern == trimmed && $0.encoding == encoding) }
        entries.insert(Entry(pattern: trimmed, encoding: encoding, caseSensitive: caseSensitive), at: 0)
        let capped = Array(entries.prefix(limit))
        guard capped != before else { return false }
        defaults.set(capped.map(\.recentValue), forKey: userDefaultsKey)
        return true
    }
}

