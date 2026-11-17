import ByteRipperCore
import XCTest
@testable import ByteRipper

/// The one field an address or a length is typed in (issue #9): what it shows
/// beside the text, what it reads back, and the list of what was typed before.
/// The forms it sits in have their own tests; these are the field's contract.
@MainActor
final class AddressFieldTests: XCTestCase {
    private var isolatedSuiteName = ""
    private var isolatedDefaults: UserDefaults!
    private var previousDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        (isolatedSuiteName, isolatedDefaults) = isolatedDefaults(for: self)
        previousDefaults = AddressHistoryStore.defaults
        AddressHistoryStore.defaults = isolatedDefaults
    }

    override func tearDown() {
        discardIsolatedDefaults(isolatedSuiteName, isolatedDefaults)
        AddressHistoryStore.defaults = previousDefaults
        isolatedDefaults = nil
        super.tearDown()
    }

    /// The result is drawn for a sum, and for a lone number typed without its
    /// `0x` — `40` and `0x40` being the mistake the field makes visible. A
    /// number already written as the app writes one needs nothing beside it.
    func testTheResultBesideTheText() {
        let cases: [(typed: String, result: String)] = [
            ("0x1FE000 + 40", "= 0x1FE028"),
            ("0x2C0000 - 1024", "= 0x2BFC00"),
            ("4096", "= 0x1000"),
            ("beef", "= 0xBEEF"),
            ("0x1000", ""),
            ("0X0007af00", ""),
            ("  0x10  ", ""),
            // Nothing to show for text that names no number.
            ("0x", ""),
            ("0x10 +", ""),
            ("0x10 - 0x20", ""),
            ("zz", ""),
        ]
        let field = AddressField(text: "0x")
        for testCase in cases {
            field.stringValue = testCase.typed
            XCTAssertEqual(field.resultText, testCase.result, "\"\(testCase.typed)\"")
        }
    }

    func testTheValueIsWhatTheTextComesTo() {
        let field = AddressField(text: "0x1FE000 + 4096")
        XCTAssertEqual(field.value, 0x1FF000)
        field.stringValue = "0x10 +"
        XCTAssertNil(field.value)
        XCTAssertEqual(field.evaluation, .failure(.incomplete))
    }

    /// Only a sum is read back: a lone number has its result beside it already.
    func testTheBreakdownIsForASum() {
        let field = AddressField(text: "0x1FE000 + 40")
        XCTAssertEqual(field.breakdown, "0x1FE000 + 0x28 = 0x1FE028 (2089000)")
        field.stringValue = "4096"
        XCTAssertNil(field.breakdown)
        field.stringValue = "0x10 +"
        XCTAssertNil(field.breakdown)
    }

    /// A sum is kept as typed; a lone number is kept only where the form says
    /// it was an address gone to, and then as the address it names.
    func testWhatGoesIntoTheHistory() {
        let field = AddressField(text: "4096")
        field.recordInHistory()
        XCTAssertEqual(AddressHistoryStore.recent, [], "a length typed in a sheet is not history")

        field.recordInHistory(always: true)
        XCTAssertEqual(AddressHistoryStore.recent, ["0x00001000"])

        field.stringValue = "  0x1FE000 + 40 "
        field.recordInHistory()
        field.recordInHistory()
        XCTAssertEqual(AddressHistoryStore.recent, ["0x1FE000 + 40", "0x00001000"],
                       "as typed, once, most recent first")

        field.stringValue = "0x10 +"
        field.recordInHistory(always: true)
        XCTAssertEqual(AddressHistoryStore.recent.count, 2, "nothing that names no number")
    }

    /// One sum typed with other spacing or case, or with a term in the other
    /// base, is one entry: the latest typing stands.
    func testOneSumIsOneEntryHoweverItWasTyped() {
        AddressHistoryStore.record(0x7AF00)
        for text in ["0x1FE000+40", "0x1FE000 + 40", "0x1fe000 + 0x28"] {
            AddressField(text: text).recordInHistory()
        }
        AddressField(text: "0x7af00").recordInHistory(always: true)
        XCTAssertEqual(AddressHistoryStore.recent, ["0x0007AF00", "0x1fe000 + 0x28"])
    }

    /// The list shows a sum with what it comes to, and picking a row gives the
    /// field the sum alone — the text a field can evaluate again.
    func testTheListShowsSumsWithTheirResults() throws {
        AddressHistoryStore.record(0x7AF00)
        let field = AddressField(text: "0x1FE000 + 40")
        field.recordInHistory()

        let items = field.historyMenu().items
        XCTAssertEqual(items.map { $0.attributedTitle?.string }, ["0x1FE000 + 40 = 0x1FE028", "0x0007AF00"])
        XCTAssertEqual(items.map { $0.representedObject as? String }, ["0x1FE000 + 40", "0x0007AF00"])

        var changes = 0
        let other = AddressField(text: "0x")
        other.onTextChange = { changes += 1 }
        other.pick(try XCTUnwrap(items[0].representedObject as? String))
        XCTAssertEqual(other.stringValue, "0x1FE000 + 40")
        XCTAssertEqual(other.value, 0x1FE028)
        XCTAssertEqual(changes, 1, "a picked entry re-validates the form, as typing does")
    }

    /// The words for what is wrong: a sum's result, an unfinished sum — and
    /// nothing for a lone number, where the form's own message names the field.
    func testTheProblemIsNamedOnlyForASum() {
        XCTAssertNil(AddressField(text: "0x10").problemMessage)
        XCTAssertNil(AddressField(text: "zz").problemMessage)
        XCTAssertNil(AddressField(text: "0x1FFFFFFFFFFFFFFFF").problemMessage, "too large, but no sum")
        XCTAssertEqual(AddressField(text: "0xFFFFFFFFFFFFFFFF + 1").problemMessage,
                       "The result does not fit in 64 bits.")
        XCTAssertEqual(AddressField(text: "0x10 - 0x20").problemMessage, "The result is negative.")
        XCTAssertEqual(AddressField(text: "0x10 +").problemMessage, "The sum is not finished.")
    }

    /// The field edits in a field editor of its own — the one that opens the
    /// list on ↓ — and an entry picked into a field not being edited makes it
    /// the one being edited, so the pick can be undone there too.
    func testAPickIntoAnUnfocusedFieldFocusesIt() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let other = NSTextField(string: "")
        other.frame = NSRect(x: 20, y: 70, width: 300, height: 22)
        let field = AddressField(text: "0x40")
        field.frame = NSRect(x: 20, y: 20, width: 300, height: 22)
        try XCTUnwrap(window.contentView).addSubview(other)
        try XCTUnwrap(window.contentView).addSubview(field)
        window.makeFirstResponder(other)

        field.pick("0x1FE000 + 40")
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertFalse(editor === window.fieldEditor(false, for: nil), "the field's own editor")
        XCTAssertEqual(field.stringValue, "0x1FE000 + 40")
        XCTAssertTrue(editor.undoManager?.canUndo ?? false, "the pick can be taken back")
    }

    /// An entry picked while the field is being edited is an edit of its own:
    /// it is announced as typing is, and **⌘Z** brings back what was typed.
    func testAPickInTheEditorIsUndoable() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let field = AddressField(text: "0x")
        field.frame = NSRect(x: 20, y: 20, width: 300, height: 22)
        try XCTUnwrap(window.contentView).addSubview(field)
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let undo = try XCTUnwrap(editor.undoManager)
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        var changes = 0
        field.onTextChange = { changes += 1 }

        undo.beginUndoGrouping()
        editor.insertText("1F", replacementRange: editor.selectedRange())
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        field.pick("0x1FE000 + 40")
        undo.endUndoGrouping()
        XCTAssertEqual(field.stringValue, "0x1FE000 + 40")
        XCTAssertEqual(field.value, 0x1FE028)
        XCTAssertEqual(changes, 2, "the pick is announced as the typing was")

        undo.undo()
        XCTAssertEqual(field.stringValue, "0x1F", "what was typed before the pick")
        undo.redo()
        XCTAssertEqual(field.stringValue, "0x1FE000 + 40")
    }

    func testAnEmptyListSaysSo() {
        let items = AddressField(text: "0x").historyMenu().items
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].isEnabled)
    }

    /// The text makes room for the result while it is being typed: the field
    /// editor is narrowed as the result appears, so a long sum scrolls beside
    /// the result instead of running under it — and typing goes on.
    func testTheEditorMakesRoomForTheResult() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let field = AddressField(text: "0x")
        field.frame = NSRect(x: 20, y: 20, width: 300, height: 22)
        try XCTUnwrap(window.contentView).addSubview(field)
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 2, length: 0), "the caret is behind the prefix")
        let before = try XCTUnwrap(editor.superview).frame.width

        editor.string = "0x1FE000 + 40"
        field.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))

        XCTAssertLessThan(try XCTUnwrap(editor.superview).frame.width, before - 40)
        XCTAssertTrue(field.currentEditor() === editor, "still being edited")
        XCTAssertEqual(field.frame.width, 300)
        XCTAssertEqual(field.stringValue, "0x1FE000 + 40")
    }
}
