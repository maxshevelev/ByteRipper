import ByteRipperCore
import XCTest
@testable import ByteRipper

/// Edit ▸ Select All (⌘A) goes to whatever has the focus: a text field being
/// typed in selects its own text, and only a dump with the focus selects every
/// byte. The menu used to send the dump's own action, which no field answers,
/// so ⌘A in the find bar or a dialog selected the whole file instead.
@MainActor
final class SelectAllFocusTests: XCTestCase {
    private let selectAll = #selector(NSText.selectAll(_:))

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

    /// The menu item sends the standard action, so the responder chain decides.
    func testTheMenuSendsTheStandardAction() throws {
        let edit = try XCTUnwrap(MainMenu.build(appTarget: NSObject()).items.compactMap(\.submenu).first {
            $0.items.contains { $0.keyEquivalent == "a" && $0.keyEquivalentModifierMask == .command }
        })
        let item = try XCTUnwrap(edit.items.first { $0.keyEquivalent == "a" })
        XCTAssertEqual(item.action, selectAll)
    }

    func testInAFieldItSelectsTheFieldsText() throws {
        let (controller, window, url) = try makeController([UInt8](repeating: 0x41, count: 64))
        defer { cleanup(controller, url) }

        controller.findPattern()
        let field = try XCTUnwrap(descendants(of: window.contentView!, FindBarView.self).first
            .flatMap { descendants(of: $0, NSTextField.self).first { $0.isEditable } },
            "the find bar's pattern field")
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.string = "41 42 43"
        editor.setSelectedRange(NSRange(location: 3, length: 0))

        XCTAssertTrue(try XCTUnwrap(window.firstResponder).tryToPerform(selectAll, with: nil))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 8),
                       "the field's own text is selected")
        XCTAssertTrue(controller.windowModel.pane1.hexSelection().isEmpty,
                      "and the dump's selection is left alone")
    }

    func testInTheDumpItSelectsEveryByte() throws {
        let (controller, window, url) = try makeController([UInt8](repeating: 0x41, count: 64))
        defer { cleanup(controller, url) }

        let hex = try XCTUnwrap(descendants(of: window.contentView!, HexView.self).first)
        XCTAssertTrue(window.makeFirstResponder(hex))
        XCTAssertTrue(try XCTUnwrap(window.firstResponder).tryToPerform(selectAll, with: nil))
        let selection = controller.windowModel.pane1.hexSelection()
        XCTAssertEqual(selection.start, 0)
        XCTAssertEqual(selection.end, 64, "every byte of the file")
    }
}
