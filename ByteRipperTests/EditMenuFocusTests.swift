import ByteRipperCore
import XCTest
@testable import ByteRipper

/// The Edit menu's Undo, Redo, Cut, Copy and Select All go to whatever has the
/// focus: a text field being typed in acts on its own text, and only a dump
/// with the focus acts on bytes. The menu used to send the dump's own actions,
/// which no field answers, so ⌘A in the find bar or a dialog selected the whole
/// file, ⌘C copied bytes and ⌘Z undid a byte edit.
@MainActor
final class EditMenuFocusTests: XCTestCase {
    private let selectAll = #selector(NSText.selectAll(_:))
    private let copy = #selector(NSText.copy(_:))
    private let cut = #selector(NSText.cut(_:))
    private let undo = #selector(MainViewController.undo(_:))
    private let redo = #selector(MainViewController.redo(_:))

    private var savedPasteboard: String?

    override func setUp() {
        super.setUp()
        savedPasteboard = NSPasteboard.general.string(forType: .string)
    }

    override func tearDown() {
        NSPasteboard.general.clearContents()
        if let savedPasteboard { NSPasteboard.general.setString(savedPasteboard, forType: .string) }
        super.tearDown()
    }

    private func makeController(_ bytes: [UInt8]) throws -> (MainViewController, NSWindow, URL) {
        let url = try tempFile(bytes)
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        return (controller, window, url)
    }

    private func cleanup(_ controller: MainViewController, _ url: URL) {
        controller.windowModel.pane1.close()
        try? FileManager.default.removeItem(at: url)
    }

    /// The find bar's pattern field, focused, holding `text` with the caret
    /// after its third character.
    private func editFindField(_ controller: MainViewController, _ window: NSWindow,
                               text: String) throws -> NSTextView {
        controller.findPattern()
        let field = try XCTUnwrap(descendants(of: window.contentView!, FindBarView.self).first
            .flatMap { descendants(of: $0, NSTextField.self).first { $0.isEditable } },
            "the find bar's pattern field")
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.string = text
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        return editor
    }

    private func focusDump(_ window: NSWindow) throws {
        let hex = try XCTUnwrap(descendants(of: window.contentView!, HexView.self).first)
        XCTAssertTrue(window.makeFirstResponder(hex))
    }

    /// Sends `action` the way the menu does: to the first responder, and on
    /// down the chain to the first one that answers.
    @discardableResult
    private func send(_ action: Selector, in window: NSWindow) throws -> Bool {
        try XCTUnwrap(window.firstResponder).tryToPerform(action, with: nil)
    }

    /// Whether the menu would offer `action` right now.
    private func enabled(_ action: Selector, in window: NSWindow) -> Bool {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        guard let target = chainTarget(for: action, in: window) else { return false }
        return (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
    }

    private func chainTarget(for action: Selector, in window: NSWindow) -> NSObject? {
        var responder = window.firstResponder
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        return nil
    }

    // MARK: - The menu

    /// The items send the standard actions, so the responder chain decides.
    func testTheMenuSendsTheStandardActions() throws {
        let edit = try XCTUnwrap(MainMenu.build(appTarget: NSObject()).items.compactMap(\.submenu).first {
            $0.items.contains { $0.keyEquivalent == "a" && $0.keyEquivalentModifierMask == .command }
        })
        func action(_ key: String) -> Selector? {
            edit.items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == .command }?.action
        }
        XCTAssertEqual(action("a"), selectAll)
        XCTAssertEqual(action("c"), copy)
        XCTAssertEqual(action("x"), cut)
        XCTAssertEqual(action("z"), undo)
        XCTAssertEqual(action("Z"), redo)
        XCTAssertEqual(NSStringFromSelector(undo), "undo:")
        XCTAssertEqual(NSStringFromSelector(redo), "redo:")
    }

    // MARK: - In a text field

    func testInAFieldSelectAllSelectsTheFieldsText() throws {
        let (controller, window, url) = try makeController([UInt8](repeating: 0x41, count: 64))
        defer { cleanup(controller, url) }
        let editor = try editFindField(controller, window, text: "41 42 43")

        XCTAssertTrue(try send(selectAll, in: window))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 8),
                       "the field's own text is selected")
        XCTAssertTrue(controller.windowModel.pane1.hexSelection().isEmpty,
                      "and the dump's selection is left alone")
    }

    func testInAFieldCopyAndCutTakeTheFieldsText() throws {
        let (controller, window, url) = try makeController([UInt8](repeating: 0x41, count: 64))
        defer { cleanup(controller, url) }
        controller.windowModel.pane1.selectAll()   // bytes selected that ⌘C must not take
        let editor = try editFindField(controller, window, text: "41 42 43")
        editor.setSelectedRange(NSRange(location: 0, length: 5))

        NSPasteboard.general.clearContents()
        XCTAssertTrue(try send(copy, in: window))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "41 42",
                       "the field's selected text, not the dump's bytes")
        XCTAssertNil(NSPasteboard.general.data(forType: .rawBytes))

        NSPasteboard.general.clearContents()
        XCTAssertTrue(enabled(cut, in: window), "Cut is offered in a field")
        XCTAssertTrue(try send(cut, in: window))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "41 42")
        XCTAssertEqual(editor.string, " 43", "and taken out of the field")
    }

    func testInAFieldUndoUndoesTheTypingNotTheBytes() throws {
        let (controller, window, url) = try makeController([UInt8](repeating: 0x41, count: 64))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        try pane.pasteWrite([0x01])   // a byte edit ⌘Z must leave alone
        let editor = try editFindField(controller, window, text: "")
        editor.insertText("FF", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "FF")

        XCTAssertTrue(enabled(undo, in: window), "the typing can be undone")
        XCTAssertTrue(try send(undo, in: window))
        XCTAssertEqual(editor.string, "", "the typing is undone")
        XCTAssertEqual(try pane.document?.read(at: 0, length: 1), [0x01], "the byte edit is not")

        XCTAssertTrue(try send(redo, in: window))
        XCTAssertEqual(editor.string, "FF", "and redone")
    }

    // MARK: - In the dump

    func testInTheDumpSelectAllSelectsEveryByte() throws {
        let (controller, window, url) = try makeController([UInt8](repeating: 0x41, count: 64))
        defer { cleanup(controller, url) }
        try focusDump(window)

        XCTAssertTrue(try send(selectAll, in: window))
        let selection = controller.windowModel.pane1.hexSelection()
        XCTAssertEqual(selection.start, 0)
        XCTAssertEqual(selection.end, 64, "every byte of the file")
    }

    func testInTheDumpCopyTakesTheBytesAndCutIsNotOffered() throws {
        let (controller, window, url) = try makeController([0x41, 0x42, 0x43, 0x44])
        defer { cleanup(controller, url) }
        try focusDump(window)
        XCTAssertTrue(try send(selectAll, in: window))

        NSPasteboard.general.clearContents()
        XCTAssertTrue(try send(copy, in: window))
        XCTAssertEqual(NSPasteboard.general.data(forType: .rawBytes), Data([0x41, 0x42, 0x43, 0x44]))
        XCTAssertFalse(enabled(cut, in: window), "bytes are not cut: it would shorten the file")
    }

    func testInTheDumpUndoUndoesTheByteEdit() throws {
        let (controller, window, url) = try makeController([0x41, 0x42, 0x43, 0x44])
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        try focusDump(window)
        try pane.pasteWrite([0x01])
        XCTAssertEqual(try pane.document?.read(at: 0, length: 1), [0x01])

        XCTAssertTrue(enabled(undo, in: window))
        XCTAssertTrue(try send(undo, in: window))
        XCTAssertEqual(try pane.document?.read(at: 0, length: 1), [0x41], "the edit is undone")
        XCTAssertTrue(try send(redo, in: window))
        XCTAssertEqual(try pane.document?.read(at: 0, length: 1), [0x01], "and redone")
    }
}
