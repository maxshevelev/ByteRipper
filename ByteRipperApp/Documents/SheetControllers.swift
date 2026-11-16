import AppPalette
import Cocoa
import ByteRipperCore
import Localization

// MARK: - Shared sheet chrome

/// The Fill sheet's field — a byte sequence, not an address (those are
/// `AddressField`). An `NSTextField` that doesn't select its whole text when
/// it gains focus: the caret lands after the existing text, so the pattern
/// offered can be added to as well as replaced. AppKit's default is select-all
/// on focus. Also fires `onTextChange` on every edit so the sheet can
/// re-validate live.
private final class HexInputField: NSTextField {
    /// Called on every edit (typing, deleting, replacing) — the sheet uses it
    /// to re-validate the input and update the error label as the user types.
    var onTextChange: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let focused = super.becomeFirstResponder()
        if focused, let editor = currentEditor() as? NSTextView {
            let length = (stringValue as NSString).length
            editor.selectedRange = NSRange(location: length, length: 0)
        }
        return focused
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        onTextChange?()
    }
}

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

    private func showNote(_ note: String?) {
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
        if isStillTyping {
            // A sum that ends at its operator is not a mistake yet: the sheet
            // waits for the rest and says nothing (issue #9).
            errorLabel.isHidden = true
            showNote(nil)
        } else if let error = validate() {
            showError(error)
        } else {
            errorLabel.isHidden = true
            showNote(liveNote())
        }
    }

    /// True while a field holds something that is unfinished rather than wrong.
    /// Only the live message waits for it — OK still refuses, through
    /// `validate()`.
    var isStillTyping: Bool { false }

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
        let field = HexInputField(string: initial)
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

        // Address rows are wider than the base sheet's starting frame allows
        // for; the frame is only where layout starts from, but it has to hold
        // the rows, or they are laid out clipped until a window resizes it.
        view.frame.size.width = 472

        startField = addAddressRow(label: L("Start:"),
                                   initial: presetStart.map { String(format: "0x%X", $0) } ?? "0x")

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
    }

    /// The End or Length field, whichever the radios make the active one.
    private var secondField: AddressField {
        endRadio.state == .on ? endField : lengthField
    }

    /// Why `field` names no number, or nil when it names one: the sentence for
    /// a sum that comes to nothing usable, else the field's own `invalid`.
    private func problem(in field: AddressField, invalid: String) -> String? {
        guard case .failure(let error) = field.evaluation else { return nil }
        return AddressField.message(for: error) ?? invalid
    }

    override var isStillTyping: Bool {
        [startField!, secondField].contains { $0.evaluation == .failure(.incomplete) }
    }

    /// The sum being typed, read back in hex with its result (issue #9).
    override func liveNote() -> String? {
        guard let field = lastEditedAddressField, field.isEnabled else { return nil }
        return field.breakdown
    }

    override func validate() -> String? {
        if let error = startError() { return error }
        guard let start = startField.value else { return nil }
        if endRadio.state == .on {
            if let error = problem(in: endField, invalid: L("Invalid end offset.")) { return error }
            guard let end = endField.value else { return nil }
            if start > end {
                return L("Start must not exceed end.")
            }
            // End is the address of the block's LAST byte, so it must point at
            // a real byte — the maximum is fileSize - 1 (the selection's
            // half-open upper bound is end + 1).
            if end >= fileSize {
                return L("End is beyond the end of the file.")
            }
        } else if let error = problem(in: lengthField, invalid: L("Invalid length.")) {
            return error
        }
        return nil
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
        if let error = problem(in: startField, invalid: L("Invalid start offset.")) { return error }
        guard let start = startField.value, start <= fileSize else {
            return L("Start is beyond the end of the file.")
        }
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

