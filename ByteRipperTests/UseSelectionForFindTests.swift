import ByteRipperCore
import XCTest
@testable import ByteRipper

/// §11 Use Selection for Find (⌘E): the selection becomes the pattern the next
/// Find will look for, and nothing else happens — the bar is not opened and no
/// search is run. Which column the selection was made in decides what the
/// pattern says: bytes from the hex column, text from the decoded-text column.
@MainActor
final class UseSelectionForFindTests: XCTestCase {
    /// The find feature's persistence — the history the bar prefills from and
    /// the case toggle — pointed at a throwaway domain, so these tests neither
    /// read nor overwrite the real app's remembered searches.
    private var isolatedSuiteName = ""
    private var isolatedDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        (isolatedSuiteName, isolatedDefaults) = isolatedDefaults(for: self)
        FindHistoryStore.defaults = isolatedDefaults
        FindBarView.defaults = isolatedDefaults
    }

    override func tearDown() {
        discardIsolatedDefaults(isolatedSuiteName, isolatedDefaults)
        FindHistoryStore.defaults = .standard
        FindBarView.defaults = .standard
        isolatedDefaults = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A real controller in a real window with one file open (single-file mode).
    private func makeController(_ bytes: [UInt8]) throws -> (MainViewController, NSWindow, URL) {
        let url = try tempFile(bytes)
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(NSSize(width: 800, height: 600))
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        return (controller, window, url)
    }

    private func cleanup(_ controller: MainViewController, _ url: URL) {
        controller.windowModel.pane1.close()
        try? FileManager.default.removeItem(at: url)
    }

    /// The bar whether or not it is showing: every test here is about a bar
    /// that stays closed.
    private func bar(_ window: NSWindow) throws -> FindBarView {
        try XCTUnwrap(descendants(of: window.contentView!, FindBarView.self).first,
                      "the bar lives in the hierarchy between shows")
    }

    /// Selects `range` in the pane with the caret typing in `region` — a
    /// selection made in the hex column or in the decoded-text one (§7).
    ///
    /// The region is set *after* the selection, which is the order a real drag
    /// puts them in (`hexEditor(_:didClickAt:region:…)`): installing a
    /// selection resets the pane's editing state, and the caret's column is
    /// part of that.
    private func select(_ range: Range<UInt64>, region: HexInputRegion,
                        in controller: MainViewController) {
        let pane = controller.windowModel.pane1
        pane.setSelection(SelectionModel(start: range.lowerBound, end: range.upperBound,
                                         fileSize: pane.fileSize))
        pane.setInputRegion(region)
    }

    /// Types into the bar's pattern field the way a user does: the field's text
    /// changes *and* the control reports it, which is what tells the bar the
    /// pattern is now the user's own.
    private func typePattern(_ text: String, in bar: FindBarView) {
        guard let field = descendants(of: bar, NSSearchField.self).first else {
            return XCTFail("the bar has a pattern field")
        }
        if let editor = field.currentEditor() as? NSTextView {
            editor.string = text
            field.textDidChange(Notification(name: NSControl.textDidChangeNotification,
                                             object: editor))
        } else {
            field.stringValue = text
            field.textDidChange(Notification(name: NSControl.textDidChangeNotification,
                                             object: field))
        }
    }

    // MARK: - The command itself

    /// The whole point of ⌘E: the pattern is loaded and the bar is left closed.
    /// The next ⌘F opens on it.
    func testItLoadsThePatternWithoutOpeningTheBar() throws {
        let (controller, window, url) = try makeController([0x41, 0x42, 0xDE, 0xAD, 0xBE, 0xEF])
        defer { cleanup(controller, url) }

        select(2..<5, region: .hex, in: controller)
        controller.useSelectionForFind()

        XCTAssertTrue(try bar(window).isHidden, "⌘E must not open the Find bar")
        XCTAssertEqual(try bar(window).stagedPatternForTests,
                       SelectionFindPattern(text: "DE AD BE", encoding: .hex))
        XCTAssertNil(controller.transientNotice,
                     "and it passes silently: no plate over the dump")

        controller.findPattern()
        XCTAssertFalse(try bar(window).isHidden)
        XCTAssertEqual(try bar(window).patternTextForTests, "DE AD BE",
                       "the bar opens on the pattern ⌘E loaded")
        XCTAssertEqual(try bar(window).encodingForTests, .hex,
                       "and under the encoding that goes with it")
    }

    /// No search is run: nothing is selected anew, and the pane has no matches
    /// to show greys for.
    func testItRunsNoSearch() throws {
        let (controller, window, url) = try makeController(
            [0x41, 0x42, 0x43, 0x41, 0x42, 0x43])
        defer { cleanup(controller, url) }

        select(0..<2, region: .hex, in: controller)
        controller.useSelectionForFind()

        XCTAssertNil(controller.windowModel.pane1.matchSet,
                     "⌘E states what to look for; it does not look")
        XCTAssertEqual(controller.windowModel.pane1.hexSelection().start, 0,
                       "and the selection stays where the user put it")
        XCTAssertEqual(controller.windowModel.pane1.hexSelection().end, 2)
        XCTAssertTrue(try bar(window).isHidden)
    }

    /// A selection made in the hex column is bytes, whatever they could also be
    /// read as.
    func testTheHexColumnGivesBytes() throws {
        let (controller, _, url) = try makeController(Array("BIOS".utf8))
        defer { cleanup(controller, url) }

        select(0..<4, region: .hex, in: controller)
        controller.useSelectionForFind()

        XCTAssertEqual(controller.stagedFindPatternForTests,
                       SelectionFindPattern(text: "42 49 4F 53", encoding: .hex))
    }

    /// A selection made in the decoded-text column is the text it reads as,
    /// searched as UTF-8.
    func testTheDecodedTextColumnGivesText() throws {
        let (controller, _, url) = try makeController(Array("AMI BIOS".utf8))
        defer { cleanup(controller, url) }

        select(4..<8, region: .ascii, in: controller)
        controller.useSelectionForFind()

        XCTAssertEqual(controller.stagedFindPatternForTests,
                       SelectionFindPattern(text: "BIOS", encoding: .utf8))
    }

    /// Bytes selected in the text column that are not text come back as bytes:
    /// a pattern of replacement characters would find nothing that is in the
    /// file (§11).
    func testTheDecodedTextColumnFallsBackToBytes() throws {
        let (controller, _, url) = try makeController([0xFF, 0xFF, 0xFE, 0x80])
        defer { cleanup(controller, url) }

        select(0..<3, region: .ascii, in: controller)
        controller.useSelectionForFind()

        XCTAssertEqual(controller.stagedFindPatternForTests,
                       SelectionFindPattern(text: "FF FF FE", encoding: .hex))
    }

    /// A pattern loaded into an **open** bar replaces what the field said, and
    /// ends the search that field described — a count left standing would be
    /// about a pattern that is no longer there (§11).
    func testAnOpenBarShowsThePatternAndDropsTheOldCount() throws {
        let (controller, window, url) = try makeController(
            [0x41, 0x42, 0x41, 0x42, 0xDE, 0xAD])
        defer { cleanup(controller, url) }

        controller.findPattern()
        let openBar = try bar(window)
        openBar.setPatternForTests("41")
        openBar.setEncodingForTests(.hex)
        openBar.pressFindForTests(.forward)
        XCTAssertTrue(pumpUntil(3) { controller.windowModel.pane1.matchSet != nil },
                      "the first search must land, so there is a count to drop")

        select(4..<6, region: .hex, in: controller)
        controller.useSelectionForFind()

        XCTAssertFalse(try bar(window).isHidden, "an open bar stays open")
        XCTAssertEqual(try bar(window).patternTextForTests, "DE AD",
                       "and says what it will now search for")
        XCTAssertEqual(try bar(window).countTextForTests, "",
                       "the count described the pattern that was there")
        XCTAssertNil(controller.windowModel.pane1.highlightedMatchSet,
                     "and so did the greys")
    }

    /// The loaded pattern is what the *next* open offers, and only until the
    /// user says something newer: typing in the field is theirs, and a later
    /// open offers what they left there rather than reviving the selection.
    func testTypingInTheFieldSupersedesTheLoadedPattern() throws {
        let (controller, window, url) = try makeController([0x41, 0x42, 0xDE, 0xAD])
        defer { cleanup(controller, url) }

        select(2..<4, region: .hex, in: controller)
        controller.useSelectionForFind()
        controller.findPattern()

        let openBar = try bar(window)
        typePattern("41 42", in: openBar)
        XCTAssertNil(openBar.stagedPatternForTests,
                     "what the user typed is the newer statement")
    }

    // MARK: - Refusals

    /// A selection too long to be a pattern is refused in words rather than
    /// quietly truncated: a shortened pattern would find places the user never
    /// asked about (§11).
    func testAnOverlongSelectionIsRefused() throws {
        let size = Int(MainViewController.maxSelectionFindBytes) + 16
        let (controller, window, url) = try makeController(Array(repeating: 0xFF, count: size))
        defer { cleanup(controller, url) }

        select(0..<UInt64(size), region: .hex, in: controller)
        controller.useSelectionForFind()

        XCTAssertNil(try bar(window).stagedPatternForTests, "nothing was loaded")
        XCTAssertEqual(controller.transientNotice?.lines.first,
                       "Selection too long to search for")

        // And the limit itself is usable: one byte less is taken.
        select(0..<MainViewController.maxSelectionFindBytes, region: .hex, in: controller)
        controller.useSelectionForFind()
        XCTAssertNotNil(try bar(window).stagedPatternForTests,
                        "the limit is a length that works, not one that fails")
    }

    /// Nothing selected is nothing to take, so the menu item is dimmed — the
    /// same rule Copy follows.
    func testTheMenuItemNeedsASelection() throws {
        let (controller, _, url) = try makeController([0x41, 0x42, 0x43])
        defer { cleanup(controller, url) }

        let item = try XCTUnwrap(MainMenu.makeEditMenu().items.first {
            $0.action == #selector(MainViewController.useSelectionForFind)
        }, "the Edit menu must offer Use Selection for Find")

        XCTAssertFalse(controller.validateMenuItem(item), "no selection, nothing to take")
        select(0..<2, region: .hex, in: controller)
        XCTAssertTrue(controller.validateMenuItem(item))
    }

    // MARK: - The menu item

    /// ⌘E, beside Find, wired to the command — the standard placement and the
    /// standard key.
    func testTheEditMenuCarriesTheCommand() throws {
        let items = MainMenu.makeEditMenu().items
        let item = try XCTUnwrap(items.first { $0.title == "Use Selection for Find" })
        XCTAssertEqual(item.action, #selector(MainViewController.useSelectionForFind))
        XCTAssertEqual(item.keyEquivalent, "e")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])

        let titles = items.map(\.title)
        let find = try XCTUnwrap(titles.firstIndex(of: "Find"))
        XCTAssertEqual(titles[find + 1], "Use Selection for Find",
                       "it loads the pattern Find will use, so it sits beside Find")
    }
}
