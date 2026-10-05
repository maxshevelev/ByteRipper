import AppKit
import ALSplitView
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
        pane.finishTransitionForTesting()
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
        XCTAssertEqual(frame.width, 533, accuracy: 1, "two thirds of the window")
        XCTAssertEqual(frame.minX, 237, accuracy: 1, "the rest clear on the left, for the table")
        XCTAssertEqual(frame.maxX, 770, accuracy: 1, "a margin on the right")
        XCTAssertEqual(frame.minY, 30, accuracy: 1, "and at the bottom")
        XCTAssertEqual(frame.maxY, 570, accuracy: 1, "and at the top")
        XCTAssertEqual(pane.detail.frame.size, frame.size, "the list fills the card")
        XCTAssertEqual(pane.detail.expandButtonForTesting?.accessibilityLabel(), "Close")

        XCTAssertTrue(pane.toggleQuickLook())
        pane.finishTransitionForTesting()
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

    /// The details' own rows, clicked into to select a value, are the
    /// details too: Space there opens them larger, and hands the focus to the
    /// table, so the arrows move its selection.
    func testSpaceInTheDetailsOpens() {
        pane.detail.prepareForRows(subject: "row")
        let fields = ToolFieldList(fields: [.init(label: "Kind", value: NSAttributedString(string: "File"))])
        pane.detail.content.addArrangedSubview(fields)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(fields))
        XCTAssertTrue(pane.handleKeyWhileShut(key(" ", code: 49)))
        XCTAssertTrue(pane.isQuickLookShown)
        XCTAssertTrue(window.firstResponder === table, "the focus is the table's")
        XCTAssertTrue(pane.handleKeyWhileShown(key("\u{F701}", code: 125)))
        XCTAssertEqual(table.selectedRow, 1, "and the arrows move it")
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
        XCTAssertFalse(pane.isQuickLookShown, "one beside it closes it")
    }

    func testLeavingTheWindowPutsTheListBack() {
        fill()
        pane.showQuickLook()
        pane.removeFromSuperview()
        XCTAssertFalse(pane.isQuickLookShown)
        XCTAssertNil(pane.quickLookCardForTesting)
        XCTAssertTrue(pane.detail.superview === pane)
    }

    /// In a splitter, the pane folds away while the card is out — the table
    /// above takes the whole height — and opens to the size it had when the
    /// card is back.
    func testThePaneFoldsAwayWhileTheCardIsOut() throws {
        let root = try XCTUnwrap(window.contentView)
        pane.removeFromSuperview()
        let split = ALSplitView(frame: root.bounds)
        split.isVertical = false
        let above = NSView()
        split.addPane(above)
        split.addPane(pane)
        split.setPaneLayout(.fill, at: 0)
        split.setPaneLayout(.proportional(1.0 / 3), at: 1)
        root.addSubview(split)
        split.layoutSubtreeIfNeeded()
        let open = pane.frame.height
        XCTAssertGreaterThan(open, 150)

        fill()
        XCTAssertTrue(pane.showQuickLook())
        pane.finishTransitionForTesting()
        XCTAssertEqual(pane.frame.height, 0, accuracy: 0.5, "the pane is folded")
        XCTAssertEqual(above.frame.height, split.bounds.height, accuracy: 0.5, "the table has the whole height")

        pane.closeQuickLook()
        pane.finishTransitionForTesting()
        XCTAssertEqual(pane.frame.height, open, accuracy: 0.5, "the pane is back at its size")
        XCTAssertEqual(split.paneLayouts[1], .proportional(1.0 / 3), "and its share")
        XCTAssertTrue(pane.detail.superview === pane, "with the list in it")
    }

    /// The flight runs: the card leaves from where the pane is and lands
    /// where it rests, on the splitter's clock.
    func testTheCardFliesOutOfThePane() throws {
        let root = try XCTUnwrap(window.contentView)
        pane.removeFromSuperview()
        let split = ALSplitView(frame: root.bounds)
        split.isVertical = false
        split.addPane(NSView())
        split.addPane(pane)
        split.setPaneLayout(.proportional(1.0 / 3), at: 1)
        root.addSubview(split)
        split.layoutSubtreeIfNeeded()
        let paneFrame = pane.convert(pane.bounds, to: nil)

        fill()
        pane.showQuickLook()
        let card = try XCTUnwrap(pane.quickLookCardForTesting)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertLessThan(card.frame.height, 300, "it starts near the pane: \(card.frame), pane \(paneFrame)")
        }
        let resting = NSRect(x: 237, y: 30, width: 533, height: 540)
        let deadline = Date().addingTimeInterval(2)
        while card.frame != resting, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(card.frame, resting)
        XCTAssertEqual(pane.frame.height, 0, accuracy: 0.5, "the pane folded on the same clock")
        pane.closeQuickLook()
        while pane.quickLookCardForTesting != nil, Date() < deadline.addingTimeInterval(2) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(pane.detail.superview === pane, "it lands back in the pane")
        XCTAssertEqual(pane.frame.height, paneFrame.height, accuracy: 0.5)
    }

    /// The corner buttons stay in the corner while the rows scroll under
    /// them.
    func testTheCornerButtonsDoNotScrollWithTheRows() throws {
        let list = pane.detail
        list.prepareForRows(subject: "row")
        for index in 0..<60 {
            list.content.addArrangedSubview(NSTextField(labelWithString: "Field \(index)"))
        }
        window.contentView?.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(list.expandButtonForTesting)
        let before = button.convert(button.bounds, to: nil)

        list.documentView?.scroll(NSPoint(x: 0, y: 300))
        list.reflectScrolledClipView(list.contentView)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(list.documentVisibleRect.minY, 100, "the premise: the rows scrolled")
        XCTAssertEqual(button.convert(button.bounds, to: nil), before, "the button stayed where it was")
        let box = list.convert(list.bounds, to: nil)
        XCTAssertGreaterThan(before.maxY, box.maxY - 30, "in the list's top band")
        XCTAssertGreaterThan(before.minX, box.midX, "and its trailing half")
    }
}
