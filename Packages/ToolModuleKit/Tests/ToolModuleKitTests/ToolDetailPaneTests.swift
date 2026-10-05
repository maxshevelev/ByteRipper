import AppKit
import XCTest
@testable import ToolModuleKit

/// The large view a row's detail opens into: Space, the corner button, Esc and
/// a click outside — and the one list moving between its pane and the card.
@MainActor
final class ToolDetailPaneTests: XCTestCase {
    private var window: NSWindow!
    private var pane: ToolDetailPane!
    private var table: NSTableView!
    private let rows = Rows()

    /// Five rows for the arrow keys to move through.
    private final class Rows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 5 }
        func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
            "Row \(row)"
        }
    }

    override func setUp() async throws {
        // Not deferred: a key event finds its window by number, and a deferred
        // window has none until it is shown.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = root

        table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("c")))
        table.dataSource = rows
        table.frame = NSRect(x: 0, y: 300, width: 800, height: 300)
        root.addSubview(table)
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)

        pane = ToolDetailPane()
        root.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            pane.heightAnchor.constraint(equalToConstant: 200),
        ])
        pane.attach(to: table)
        window.makeFirstResponder(table)
        root.layoutSubtreeIfNeeded()
    }

    override func tearDown() async throws {
        pane.closeQuickLook()
        pane.finishFadeForTesting()
        window.close()
        window = nil
        pane = nil
        table = nil
    }

    private func fill() {
        pane.detail.prepareForRows(subject: "row")
        pane.detail.content.addArrangedSubview(NSTextField(labelWithString: "Field"))
    }

    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func click(at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)!
    }

    /// What a click at `point`, in the window, lands on — and its landing.
    private func deliver(_ event: NSEvent) {
        pane.handleClickWhileShown(event)
        let content = window.contentView!
        content.hitTest(content.convert(event.locationInWindow, from: nil))?.mouseDown(with: event)
    }

    func testTheCornerButtonIsThereOnlyWhileThereAreRows() {
        XCTAssertNil(pane.detail.expandButtonForTesting, "a placeholder has nothing to show larger")
        fill()
        let button = pane.detail.expandButtonForTesting
        XCTAssertNotNil(button)
        XCTAssertEqual(button?.accessibilityLabel(), "Expand")
        pane.detail.showPlaceholder("Select a row to see what it is.")
        XCTAssertNil(pane.detail.expandButtonForTesting)
    }

    func testABareListHasNoCornerButton() {
        let list = ToolDetailScroll()
        list.prepareForRows(subject: "row")
        XCTAssertNil(list.expandButtonForTesting,
                     "a list with no large view to open — the ME Summary — carries none")
    }

    func testNothingToShowIsNotTaken() {
        XCTAssertFalse(pane.toggleQuickLook(), "Space on no row is left to the table")
        XCTAssertFalse(pane.isQuickLookShown)
    }

    func testTheListMovesIntoACardInTheMiddleOfTheWindowAndBack() throws {
        fill()
        XCTAssertTrue(pane.toggleQuickLook())
        let card = try XCTUnwrap(pane.quickLookCardForTesting)
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(pane.detail.isDescendant(of: card), "the list itself, not a copy")
        XCTAssertTrue(pane.detail.isExpanded)
        let frame = card.convert(card.bounds, to: nil)
        XCTAssertEqual(frame.midX, 400, accuracy: 1)
        XCTAssertEqual(frame.midY, 300, accuracy: 1)
        XCTAssertGreaterThan(frame.width, 500, "large: most of the window")
        XCTAssertLessThan(frame.width, 800, "but not to its edge")
        XCTAssertEqual(pane.detail.expandButtonForTesting?.accessibilityLabel(), "Close")

        XCTAssertTrue(pane.toggleQuickLook())
        pane.finishFadeForTesting()
        XCTAssertNil(pane.quickLookCardForTesting)
        XCTAssertTrue(pane.detail.superview === pane, "back in its pane")
        XCTAssertFalse(pane.detail.isExpanded)
        XCTAssertEqual(pane.detail.expandButtonForTesting?.accessibilityLabel(), "Expand")
    }

    func testTheCornerButtonOpensAndCloses() throws {
        fill()
        try XCTUnwrap(pane.detail.expandButtonForTesting).performClick(nil)
        XCTAssertTrue(pane.isQuickLookShown)
        try XCTUnwrap(pane.detail.expandButtonForTesting).performClick(nil)
        XCTAssertFalse(pane.isQuickLookShown)
    }

    func testSpaceOnTheTableOpens() {
        fill()
        XCTAssertFalse(pane.handleKeyWhileShut(key(" ", code: 49, modifiers: .command)),
                       "a modified Space is someone else's shortcut")
        XCTAssertTrue(pane.handleKeyWhileShut(key(" ", code: 49)))
        XCTAssertTrue(pane.isQuickLookShown)
    }

    func testSpaceElsewhereIsNotTaken() {
        fill()
        window.makeFirstResponder(nil)
        XCTAssertFalse(pane.handleKeyWhileShut(key(" ", code: 49)),
                       "Space in the dump or a text field is theirs")
    }

    func testSpaceAndEscClose() {
        fill()
        pane.showQuickLook()
        XCTAssertTrue(pane.handleKeyWhileShown(key(" ", code: 49)))
        XCTAssertFalse(pane.isQuickLookShown)

        pane.showQuickLook()
        XCTAssertTrue(pane.handleKeyWhileShown(key("\u{1B}", code: 53)))
        XCTAssertFalse(pane.isQuickLookShown)
    }

    func testTheArrowsStillMoveTheTable() {
        fill()
        pane.showQuickLook()
        XCTAssertTrue(pane.handleKeyWhileShown(key(String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)),
                                                   code: 125, modifiers: [.numericPad, .function])))
        XCTAssertEqual(table.selectedRow, 1, "the card follows the selection, as Quick Look does")
        XCTAssertTrue(pane.isQuickLookShown)
        XCTAssertFalse(pane.handleKeyWhileShown(key("c", code: 8, modifiers: .command)),
                       "Copy is the selected value's")
    }

    func testAClickOutsideTheCardClosesAndOneOnItDoesNot() throws {
        fill()
        pane.showQuickLook()
        let card = try XCTUnwrap(pane.quickLookCardForTesting)
        window.contentView?.layoutSubtreeIfNeeded()
        let inside = card.convert(card.bounds, to: nil)

        deliver(click(at: NSPoint(x: inside.midX, y: inside.midY)))
        XCTAssertTrue(pane.isQuickLookShown, "a click on the card is the card's")

        deliver(click(at: NSPoint(x: 5, y: 5)))
        XCTAssertFalse(pane.isQuickLookShown, "one on the dimmed window closes it")
    }

    func testLeavingTheWindowPutsTheListBack() {
        fill()
        pane.showQuickLook()
        pane.removeFromSuperview()
        XCTAssertFalse(pane.isQuickLookShown)
        XCTAssertNil(pane.quickLookCardForTesting)
        XCTAssertTrue(pane.detail.superview === pane)
    }
}
