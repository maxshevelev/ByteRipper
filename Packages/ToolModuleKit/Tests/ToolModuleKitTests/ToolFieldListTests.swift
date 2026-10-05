import AppKit
import XCTest
@testable import ToolModuleKit

/// A detail's name/value rows: a view per row, a name too long for its column
/// wrapped onto a further line, and the text selected across the rows.
@MainActor
final class ToolFieldListTests: XCTestCase {
    private var window: NSWindow!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    override func tearDown() async throws {
        window.close()
        window = nil
    }

    private func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: ToolPanelFont.body()])
    }

    /// A list `width` wide, laid out in the window.
    private func list(_ fields: [(String, NSAttributedString)], width: CGFloat = 360,
                      nameWidth: CGFloat = 80) -> ToolFieldList {
        let list = ToolFieldList(fields: fields.map { .init(label: $0.0, value: $0.1) },
                                 nameWidth: nameWidth)
        let root = window.contentView!
        root.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: root.topAnchor),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.widthAnchor.constraint(equalToConstant: width),
        ])
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        return list
    }

    func testAViewPerRowAndNothingElse() {
        let list = list([("Kind", plain("File")), ("Size", plain("0x10")), ("GUID", plain("8C8CE578"))])
        XCTAssertEqual(list.subviews.count, 3)
        XCTAssertEqual(list.rows.map(\.texts), [["Kind", "File"], ["Size", "0x10"], ["GUID", "8C8CE578"]])
        XCTAssertEqual(list.rows[1].frame.minY, list.rows[0].frame.maxY, "the rows follow one another")
        XCTAssertEqual(list.frame.height, list.rows.last!.frame.maxY, "and the list is as tall as they are")
    }

    /// A name longer than its column goes on onto a further line rather than
    /// being cut short, and the row is as tall as the two lines.
    func testANameTooLongForItsColumnWraps() {
        let list = list([("Kind", plain("File")),
                         ("Integrity check of the whole volume", plain("Valid"))])
        let one = list.rows[0].frame.height - ToolFieldList.rowSpacing
        let wrapped = list.rows[1].frame.height
        XCTAssertGreaterThan(wrapped, one * 1.5, "the long name takes two lines or more")
    }

    /// A value wraps inside what is left of the width, and a narrower list
    /// gives it more lines.
    func testAValueWrapsInsideTheRestOfTheWidth() {
        let hash = plain(String(repeating: "0123456789ABCDEF ", count: 6))
        let wide = list([("Hash", hash)], width: 1_000)
        let wideHeight = wide.frame.height
        wide.removeFromSuperview()
        let narrow = list([("Hash", hash)], width: 240)
        XCTAssertGreaterThan(narrow.frame.height, wideHeight * 1.5)
        XCTAssertLessThanOrEqual(narrow.rows[0].frame.maxX, 240)
    }

    /// A drag from the first row into the value of the last selects both, the
    /// name and value of a row a tab apart and each row on its line.
    func testADragSelectsAcrossRows() {
        let list = list([("Kind", plain("File")), ("Size", plain("0x10"))])
        let start = list.spot(at: NSPoint(x: 0, y: list.rows[0].frame.midY))
        list.extend(start..<start, to: NSPoint(x: 400, y: list.rows[1].frame.midY))
        XCTAssertEqual(list.selectedText, "Kind\tFile\nSize\t0x10")
        XCTAssertNotNil(list.rows[0].selectedRange)

        // From the value of the first: its name is left out.
        let value = list.spot(at: NSPoint(x: 80 + ToolFieldRow.columnSpacing, y: list.rows[0].frame.midY))
        XCTAssertEqual(value.mark, ToolTextMark(part: 1, index: 0))
        list.extend(value..<value, to: NSPoint(x: 400, y: list.rows[0].frame.midY))
        XCTAssertEqual(list.selectedText, "File")
    }

    /// The tick a passed check carries is drawn, not copied: it is the one
    /// character a reader did not read.
    func testThePassedChecksTickIsNotCopied() {
        let list = list([("Checksum", ToolValueTone.good.attributedValue("Valid"))])
        XCTAssertTrue(list.rows[0].attributedValue.string.contains("\u{FFFC}"), "the tick is drawn")
        XCTAssertEqual(list.rows[0].valueText, "Valid")
        list.selectAll(nil)
        XCTAssertEqual(list.selectedText, "Checksum\tValid")
    }

    /// ⌘C copies while the list has the focus, and the focus leaving takes
    /// the selection with it.
    func testCommandCCopiesAndTheFocusLeavingClears() throws {
        let list = list([("Kind", plain("File"))])
        let other = NSTextField()
        window.contentView!.addSubview(other)
        XCTAssertTrue(window.makeFirstResponder(list))
        list.selectAll(nil)

        let copy = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "c",
            charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        NSPasteboard.general.clearContents()
        XCTAssertTrue(list.performKeyEquivalent(with: copy))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Kind\tFile")

        window.makeFirstResponder(other)
        XCTAssertNil(list.selection)
        XCTAssertNil(list.rows[0].selectedRange)
        XCTAssertFalse(list.performKeyEquivalent(with: copy), "⌘C is someone else's again")
    }
}
