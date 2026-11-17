import AppPalette
import ByteRipperCore
import Cocoa
import HelpUI
import Localization

// MARK: - The history

/// The last addresses and sums typed where an address or a length is asked
/// for, most recent first (§10.1, issue #9). One list for the whole app: an
/// address worked out for a cut is as likely to be wanted in Select Block as in
/// the form it was typed in. Persisted in `UserDefaults`, like the last Find
/// query, so it survives a relaunch.
///
/// An entry is text a field can be given back: a plain address in the form the
/// app writes one (`0x0007AF00`), or a sum exactly as it was typed
/// (`0x1FE000 + 40`) — kept as typed so it can be read again and corrected,
/// which is the reason to keep it at all.
enum AddressHistoryStore {
    /// The key Go To's history has always had: the addresses already there are
    /// entries of this list as they stand.
    static let userDefaultsKey = "GoToHistory"
    static let limit = 10

    /// The defaults domain the history lives in. Swappable so tests run against
    /// an isolated store instead of the user's own (§11 does the same).
    static var defaults: UserDefaults = AppDefaults.store

    /// The recorded entries, most recent first.
    static var recent: [String] {
        defaults.stringArray(forKey: userDefaultsKey) ?? []
    }

    /// Records an address: moves it to the front, dropping any older entry for
    /// the same address, and caps the list at `limit`.
    static func record(_ offset: UInt64) {
        record(entry: offset.hexAddress)
    }

    /// Records what a field held when it was acted on: a sum as it was typed, a
    /// lone number as the address it names — so one address typed two ways is
    /// one entry.
    static func record(_ expression: OffsetExpression, typedAs text: String) {
        guard expression.isSum else { return record(expression.value) }
        record(entry: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func record(entry: String) {
        // One entry per sum however it was spaced or cased: `0x1FE000+40` and
        // `0x1fe000 + 0x28` are the same sum, and the latest typing stands.
        let key = sameness(entry)
        var entries = recent.filter { sameness($0) != key }
        entries.insert(entry, at: 0)
        defaults.set(Array(entries.prefix(limit)), forKey: userDefaultsKey)
    }

    /// What two entries are compared by: their terms in hex, in order.
    private static func sameness(_ entry: String) -> String {
        (try? OffsetExpression.parse(entry))?.hexText ?? entry
    }
}

// MARK: - The field

/// The one field an address or a length is typed in (issue #9): Go To, Select
/// Block, a bookmark's address, a cut's.
///
/// It takes a number as it always did, and a sum — `0x1FE000 + 4096` — where
/// the number is still arithmetic (`OffsetExpression`). What was typed is never
/// rewritten: the sum stays in the field to be read again and corrected, and
/// what it comes to is drawn beside it, at the field's right edge, in heavier
/// type — **that** is the number the form acts on. A lone number typed without
/// its `0x` gets the same treatment, because `40` and `0x40` are the mistake
/// this field exists to make visible.
///
/// At the right edge is the list of what was typed before
/// (`AddressHistoryStore`), also under **↓**. Picking an entry only fills the
/// field; acting on it is still the form's own key.
///
/// The field does not select its whole text when it gains focus: the caret
/// lands after the text, so a field that opens as `0x` is ready for hex digits
/// (§10), and one that opens with an address is ready for `+ 0x40`.
// help: editing.address-arithmetic
@MainActor
final class AddressField: CaretAtEndTextField {
    private let resultLabel = ResultLabel(labelWithString: "")
    private(set) var historyButton: NSButton!

    override class var cellClass: AnyClass? {
        get { AddressFieldCell.self }
        set {}
    }

    init(text: String) {
        super.init(frame: .zero)
        isEditable = true
        isSelectable = true
        isBezeled = true
        drawsBackground = true
        cell?.isScrollable = true
        cell?.wraps = false
        cell?.usesSingleLineMode = true
        font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        resultLabel.lineBreakMode = .byTruncatingHead
        addSubview(resultLabel)

        let image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(showHistory))
        button.title = ""
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.refusesFirstResponder = true
        ControlHelp.describe(button, L("Addresses and sums entered before"))
        addSubview(button)
        historyButton = button

        stringValue = text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: What the field holds

    /// What the text comes to, or why it comes to nothing. Parsed once per
    /// text: the result, the form's check and its message line all ask.
    var evaluation: Result<OffsetExpression, OffsetExpression.ParseError> {
        let text = stringValue
        if let parsed, parsed.text == text { return parsed.result }
        let result: Result<OffsetExpression, OffsetExpression.ParseError>
        do {
            result = .success(try OffsetExpression.parse(text))
        } catch {
            result = .failure(error as? OffsetExpression.ParseError ?? .invalidInput)
        }
        parsed = (text, result)
        return result
    }

    private var parsed: (text: String, result: Result<OffsetExpression, OffsetExpression.ParseError>)?

    /// The number a form acts on: the lone number typed, or what the sum comes
    /// to. Nil while the text names none.
    var value: UInt64? { (try? evaluation.get())?.value }

    /// A sum, read back in full for a form that has a line to put it on:
    /// `0x1FE000 + 0x28 = 0x1FE028 (2089000)` — every term in hex as it was
    /// understood, then the result in both bases. Nil for anything but a sum.
    var breakdown: String? {
        guard let sum = try? evaluation.get(), sum.isSum else { return nil }
        return "\(sum.hexText) = \(sum.hexValue) (\(sum.value))"
    }

    /// The sentence for a sum that comes to no address, for a form that says
    /// what is wrong in words. Nil when the text names a number, and when the
    /// form's own "invalid" message — which names the field — is the right
    /// one: text that is no number, or a lone number too large, there being no
    /// sum to have a result. A form that waits for an unfinished sum while it
    /// is typed asks only once the user acts on it.
    var problemMessage: String? {
        guard case .failure(let error) = evaluation else { return nil }
        switch error {
        case .negative: return L("The result is negative.")
        case .outOfRange: return isTypedAsSum ? L("The result does not fit in 64 bits.") : nil
        case .incomplete: return L("The sum is not finished.")
        case .invalidInput: return nil
        }
    }

    /// The text has an operator in it — whatever its terms come to.
    private var isTypedAsSum: Bool {
        stringValue.contains { $0 == "+" || $0 == "-" }
    }

    /// Puts what the field holds into the list of recent entries — called by the
    /// form once it has acted on it. A sum is always worth keeping; a lone
    /// number only where it was an address gone to (`always`), or the list
    /// would fill with every length ever typed.
    func recordInHistory(always: Bool = false) {
        guard let expression = try? evaluation.get(), always || expression.isSum else { return }
        AddressHistoryStore.record(expression, typedAs: stringValue)
    }

    // MARK: The result beside the text

    /// What is drawn at the right edge: `= 0x1FE028` for a sum, and for a lone
    /// number that was not typed with its `0x`. Empty when the text already
    /// *is* the number as the app writes one, or names none.
    var resultText: String {
        guard let expression = try? evaluation.get() else { return "" }
        let typed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard expression.isSum || !typed.hasPrefix("0x") else { return "" }
        return "= " + expression.hexValue
    }

    override var stringValue: String {
        didSet { refreshResult() }
    }

    override var textColor: NSColor? {
        didSet { refreshResult() }
    }

    override var isEnabled: Bool {
        didSet { refreshResult() }
    }

    override func textDidChange(_ notification: Notification) {
        refreshResult()
        super.textDidChange(notification)
    }

    /// What the result was last drawn from — compared rather than the label's
    /// own attributed string, which comes back with attributes of its own.
    private var drawnResult: (text: String, color: NSColor?, enabled: Bool)?

    private func refreshResult() {
        guard historyButton != nil else { return }   // a setter run by `super.init`
        let text = resultText
        historyButton.isEnabled = isEnabled
        // A keystroke that leaves the result as it was — most of them inside
        // a term, and the form's own colour change after it — changes nothing.
        if let drawnResult, drawnResult.text == text, drawnResult.color == textColor,
           drawnResult.enabled == isEnabled { return }
        drawnResult = (text, textColor, isEnabled)
        let font = NSFont.monospacedSystemFont(ofSize: self.font?.pointSize ?? 12, weight: .semibold)
        // The result is the number acted on, so it reads first: the text's own
        // colour — red with it when a form refuses the address — in heavier
        // type, behind a quiet `=`.
        let strong = isEnabled ? (textColor ?? .labelColor) : NSColor.tertiaryLabelColor
        let attributed = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: strong])
        if !text.isEmpty {
            attributed.addAttribute(.foregroundColor,
                                    value: isEnabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
                                    range: NSRange(location: 0, length: 1))
        }
        resultLabel.attributedStringValue = attributed
        resultLabel.isHidden = text.isEmpty
        // At once rather than at the next layout pass: the field editor has to
        // make room before the next key lands.
        layoutAdornments()
    }

    override func layout() {
        super.layout()
        layoutAdornments()
    }

    private static let buttonWidth: CGFloat = 20
    private static let gap: CGFloat = 6

    /// Places the list button and the result at the right edge and takes their
    /// width away from the text, so a long sum scrolls beside the result rather
    /// than under it.
    private func layoutAdornments() {
        guard let cell = cell as? AddressFieldCell else { return }
        historyButton.frame = NSRect(x: bounds.maxX - Self.buttonWidth - 1, y: 1,
                                     width: Self.buttonWidth, height: bounds.height - 2)
        var inset = Self.buttonWidth
        if !resultLabel.isHidden {
            // The text keeps at least two fifths of the field: the result can be
            // read in the form's line or by widening nothing, the sum being
            // typed cannot.
            let room = max(0, bounds.width * 0.6 - Self.buttonWidth - Self.gap)
            let size = resultLabel.attributedStringValue.size()
            let width = min(ceil(size.width) + 4, room)
            let height = ceil(size.height)
            resultLabel.frame = NSRect(x: historyButton.frame.minX - width,
                                       y: ((bounds.height - height) / 2).rounded(),
                                       width: width, height: height)
            inset += width + Self.gap
        }
        guard cell.trailingInset != inset else { return }
        cell.trailingInset = inset
        needsDisplay = true
        // The field editor's clip took its frame — the cell's drawing rect —
        // when editing began, and AppKit fits it again only on a resize. It is
        // given the narrowed rect here, and the caret kept in sight.
        if let editor = currentEditor() as? NSTextView, let clip = editor.superview {
            clip.frame = cell.drawingRect(forBounds: bounds)
            editor.scrollRangeToVisible(editor.selectedRange())
        }
    }

    // MARK: The list

    /// The list of recent entries as a menu, each row a sum with what it comes
    /// to, or an address. Internal so a test can read it: a menu being tracked
    /// cannot be driven from a test.
    func historyMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // The Find bar's row size, so the app's lists of recent entries read
        // alike; monospaced, since these are addresses.
        let size = PatternQueryControls.menuRowSize
        let regular = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let strong = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        for entry in AddressHistoryStore.recent {
            // No action: the row chosen is read back from the menu when it
            // closes (`showHistory`), not sent as one.
            let item = NSMenuItem(title: entry, action: nil, keyEquivalent: "")
            item.representedObject = entry
            let title = NSMutableAttributedString(string: entry, attributes: [.font: regular])
            if let sum = try? OffsetExpression.parse(entry), sum.isSum {
                title.append(NSAttributedString(string: " = ", attributes: [
                    .font: regular, .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                title.append(NSAttributedString(string: sum.hexValue, attributes: [.font: strong]))
            }
            item.attributedTitle = title
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: L("Nothing entered yet"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        return menu
    }

    @objc func showHistory() {
        guard isEnabled else { return }
        let menu = historyMenu()
        menu.minimumWidth = bounds.width
        // Under the field, flush with its left edge, as a combo box's list is.
        let below = NSPoint(x: 0, y: isFlipped ? bounds.maxY + 3 : -3)
        // The chosen row is taken from the menu itself rather than from an
        // action it sends. The Segments form is a modal window and its cut
        // popover a window of its own beside it: AppKit shows a menu there and
        // lets a row be chosen, and then does not deliver the row's action to
        // a target outside the modal window — the field stayed as it was.
        let choice = HistoryChoice()
        menu.delegate = choice
        guard menu.popUp(positioning: nil, at: below, in: self),
              let entry = choice.item?.representedObject as? String else { return }
        pick(entry)
    }

    /// Fills the field with an entry of the list, as if it had been typed: the
    /// form re-validates, nothing is acted on, and **⌘Z** takes it back.
    func pick(_ entry: String) {
        // The list's button never takes the focus, so the field may not be
        // the one being edited: it is made so first, and the entry goes in as
        // an edit there — undoable like any other.
        if currentEditor() == nil { window?.makeFirstResponder(self) }
        if let editor = currentEditor() as? NSTextView {
            // Through the text view's own edit, so the undo stack holds the
            // replacement and the change is announced as a typed one is.
            let whole = NSRange(location: 0, length: (editor.string as NSString).length)
            guard editor.shouldChangeText(in: whole, replacementString: entry) else { return }
            editor.replaceCharacters(in: whole, with: entry)
            editor.didChangeText()
            editor.selectedRange = NSRange(location: (entry as NSString).length, length: 0)
        } else {
            // A field in no window: nothing to undo in, nothing to focus.
            stringValue = entry
            onTextChange?()
            (delegate as? NSControlTextEditingDelegate)?
                .controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: self))
        }
    }
}

/// The field's own field editor, so **↓** can open the list with nothing of
/// AppKit's overridden: the key reaches the text view's `moveDown(_:)` only
/// after the form's delegate has been offered it and declined, as with any
/// field — and a field editor of a cell's own is public API
/// (`NSCell.fieldEditor(for:)`).
private final class AddressFieldEditor: NSTextView {
    weak var field: AddressField?

    override func moveDown(_ sender: Any?) {
        guard let field else { return super.moveDown(sender) }
        field.showHistory()
    }
}

/// Remembers the row of the history menu the pointer or the keys were on last —
/// which, when the menu closes with a choice made, is the row chosen.
private final class HistoryChoice: NSObject, NSMenuDelegate {
    private(set) var item: NSMenuItem?

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        // The highlight is taken away as the menu closes; the last row it was
        // on is the one that matters.
        if let item { self.item = item }
    }
}

/// The field's cell: the text stops short of the result and the list button.
private final class AddressFieldCell: NSTextFieldCell {
    var trailingInset: CGFloat = 0

    private lazy var editor: AddressFieldEditor = {
        let editor = AddressFieldEditor(frame: .zero)
        editor.isFieldEditor = true
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        editor.field = controlView as? AddressField
        return editor
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var inner = super.drawingRect(forBounds: rect)
        inner.size.width = max(0, inner.width - trailingInset)
        return inner
    }

    /// A sum longer than its room is cut off at the room's edge. While it is
    /// being edited the field editor does that; at rest the cell draws the
    /// text itself, and without this it runs on under the result.
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        drawingRect(forBounds: cellFrame).clip()
        super.drawInterior(withFrame: cellFrame, in: controlView)
    }
}

/// The result: read, never clicked. A click on it is a click on the field.
private final class ResultLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
