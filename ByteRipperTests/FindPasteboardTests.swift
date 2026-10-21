import ByteRipperCore
import ToolModuleKit
import XCTest
@testable import ByteRipper

/// §11 and the Mac's find pasteboard (`FindPasteboard`): ⌘E and every search
/// put their string there, and a bar that opens or a Find Next (⌘G) takes it
/// back when another search — elsewhere in the app, or in another app — put a
/// new one there.
@MainActor
final class FindPasteboardTests: XCTestCase {
    private var isolatedSuiteName = ""
    private var isolatedDefaults: UserDefaults!
    private var runPasteboard: NSPasteboard!
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        (isolatedSuiteName, isolatedDefaults) = isolatedDefaults(for: self)
        FindHistoryStore.defaults = isolatedDefaults
        FindBarView.defaults = isolatedDefaults
        // A pasteboard of the test's own: what another app would have written
        // is written here.
        runPasteboard = FindPasteboard.pasteboard
        pasteboard = NSPasteboard.withUniqueName()
        FindPasteboard.pasteboard = pasteboard
    }

    override func tearDown() {
        FindPasteboard.pasteboard = runPasteboard
        pasteboard.releaseGlobally()
        discardIsolatedDefaults(isolatedSuiteName, isolatedDefaults)
        FindHistoryStore.defaults = .standard
        FindBarView.defaults = .standard
        isolatedDefaults = nil
        super.tearDown()
    }

    // MARK: - Fixtures

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

    private func bar(_ window: NSWindow) throws -> FindBarView {
        try XCTUnwrap(descendants(of: window.contentView!, FindBarView.self).first)
    }

    /// What another app does with its Use Selection for Find.
    private func writeElsewhere(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private var findString: String? { pasteboard.string(forType: .string) }

    // MARK: - Writing

    /// ⌘E is the Mac's Use Selection for Find: the pattern goes on the find
    /// pasteboard, where any other search can read it.
    func testUseSelectionForFindPutsThePatternOnThePasteboard() throws {
        let (controller, _, url) = try makeController([0x41, 0x42, 0xDE, 0xAD, 0xBE, 0xEF])
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        pane.setSelection(SelectionModel(start: 2, end: 5, fileSize: pane.fileSize))
        pane.setInputRegion(.hex)

        controller.useSelectionForFind()

        XCTAssertEqual(findString, "DE AD BE")
    }

    /// A search run from the bar makes its pattern the find string.
    func testASearchFromTheBarPutsItsPatternOnThePasteboard() throws {
        let (controller, window, url) = try makeController(Array("xxBIOSxx".utf8))
        defer { cleanup(controller, url) }
        controller.findPattern()
        try bar(window).setPatternTextForTests("BIOS")

        try bar(window).pressFindForTests(.forward)

        XCTAssertEqual(findString, "BIOS")
    }

    // MARK: - Reading

    /// A string searched for elsewhere is what the bar opens on — over the
    /// search history it would otherwise be filled from.
    func testTheBarOpensOnAStringSearchedForElsewhere() throws {
        let (controller, window, url) = try makeController(Array("xxBIOSxx".utf8))
        defer { cleanup(controller, url) }
        writeElsewhere("BIOS")

        controller.findPattern()

        XCTAssertEqual(try bar(window).patternTextForTests, "BIOS")
    }

    /// One the bar has already seen does not replace what is in its field: a
    /// pattern the reader typed stays.
    func testAStringAlreadySeenLeavesTheFieldAlone() throws {
        let (controller, window, url) = try makeController(Array("xxBIOSxxEFIxx".utf8))
        defer { cleanup(controller, url) }
        writeElsewhere("BIOS")
        controller.findPattern()
        try bar(window).setPatternTextForTests("EFI")

        controller.findNextMatch()

        XCTAssertEqual(try bar(window).patternTextForTests, "EFI",
                       "the find string has not changed since the bar took it")
        XCTAssertTrue(pumpUntil(5) { controller.windowModel.pane1.hexSelection().start == 8 },
                      "and ⌘G looks for what the field holds")
    }

    // MARK: - Find Next and Find Previous

    /// ⌘G with the bar shut finds the find string's next match, opens the bar
    /// to say what is being looked for, and leaves the keyboard in the dump.
    func testFindNextWithTheBarShutFindsAndKeepsTheKeyboardInTheDump() throws {
        let (controller, window, url) = try makeController(Array("xxBIOSxxBIOSxx".utf8))
        defer { cleanup(controller, url) }
        let hex = try XCTUnwrap(descendants(of: window.contentView!, HexView.self).first)
        window.makeFirstResponder(hex)
        writeElsewhere("BIOS")

        controller.findNextMatch()

        let pane = controller.windowModel.pane1
        XCTAssertTrue(pumpUntil(5) { pane.hexSelection().start == 2 && pane.hexSelection().end == 6 },
                      "selection \(pane.hexSelection())")
        XCTAssertFalse(try bar(window).isHidden, "the bar shows what is being looked for")
        XCTAssertEqual(try bar(window).patternTextForTests, "BIOS")
        XCTAssertTrue(window.firstResponder === hex, "the keyboard stays in the dump")

        controller.findNextMatch()
        XCTAssertTrue(pumpUntil(5) { pane.hexSelection().start == 8 }, "the next one")
        controller.findPreviousMatch()
        XCTAssertTrue(pumpUntil(5) { pane.hexSelection().start == 2 }, "and back")
        XCTAssertTrue(window.firstResponder === hex)
    }

    /// ⌘G and ⇧⌘G in the Edit menu, between Find and Use Selection for Find —
    /// the order of every Mac app's Find commands.
    func testTheEditMenuCarriesFindNextAndPrevious() throws {
        let items = MainMenu.makeEditMenu().items
        let next = try XCTUnwrap(items.first { $0.title == "Find Next" })
        XCTAssertEqual(next.action, #selector(MainViewController.findNextMatch))
        XCTAssertEqual(next.keyEquivalent, "g")
        XCTAssertEqual(next.keyEquivalentModifierMask, [.command])
        let previous = try XCTUnwrap(items.first { $0.title == "Find Previous" })
        XCTAssertEqual(previous.action, #selector(MainViewController.findPreviousMatch))
        XCTAssertEqual(previous.keyEquivalent, "G", "⇧⌘G")

        let titles = items.map(\.title)
        let find = try XCTUnwrap(titles.firstIndex(of: "Find"))
        XCTAssertEqual(Array(titles[find...].prefix(4)),
                       ["Find", "Find Next", "Find Previous", "Use Selection for Find"])
    }
}
