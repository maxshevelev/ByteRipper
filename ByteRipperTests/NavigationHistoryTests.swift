import ByteRipperCore
import XCTest
@testable import ByteRipper

/// §10.6 — the history itself, without a document: what records, what walking
/// does to the two stacks, and what is stepped over.
final class NavigationHistoryModelTests: XCTestCase {
    private let everywhere: (Int) -> Bool = { _ in true }

    func testBackReturnsToWhereTheJumpLeftAndForwardComesBack() {
        var history = NavigationHistory<Int>()
        history.record(leaving: 1)
        history.record(leaving: 2)
        XCTAssertEqual(history.goBack(from: 3, isReachable: everywhere), 2)
        XCTAssertEqual(history.goBack(from: 2, isReachable: everywhere), 1)
        XCTAssertNil(history.goBack(from: 1, isReachable: everywhere))
        XCTAssertEqual(history.goForward(from: 1, isReachable: everywhere), 2)
        XCTAssertEqual(history.goForward(from: 2, isReachable: everywhere), 3)
        XCTAssertNil(history.goForward(from: 3, isReachable: everywhere))
    }

    func testANewJumpClearsTheForwardStack() {
        var history = NavigationHistory<Int>()
        history.record(leaving: 1)
        _ = history.goBack(from: 2, isReachable: everywhere)
        XCTAssertTrue(history.canGoForward(from: 1, isReachable: everywhere))
        history.record(leaving: 1)
        XCTAssertFalse(history.canGoForward(from: 5, isReachable: everywhere))
    }

    func testTwoJumpsFromOnePlaceAreOneWayBack() {
        var history = NavigationHistory<Int>()
        history.record(leaving: 1)
        history.record(leaving: 1)
        XCTAssertEqual(history.backStack, [1])
    }

    func testThePlaceTheUserIsOnAndUnreachablePlacesAreSteppedOver() {
        var history = NavigationHistory<Int>()
        history.record(leaving: 1)
        history.record(leaving: 2)
        history.record(leaving: 3)
        // 3 is where the user already is, 2 is in a file since closed.
        XCTAssertEqual(history.goBack(from: 3, isReachable: { $0 != 2 }), 1)
        XCTAssertFalse(history.canGoBack(from: 1, isReachable: { $0 != 2 }))
    }

    func testTheHistoryKeepsItsLastFiftyPlaces() {
        var history = NavigationHistory<Int>()
        for place in 0..<70 { history.record(leaving: place) }
        XCTAssertEqual(history.backStack.count, 50)
        XCTAssertEqual(history.backStack.first, 20)
    }
}

/// §10.6 in a window: which acts record, and what Back and Forward put back.
@MainActor
final class NavigationHistoryFlowTests: XCTestCase {
    private var urls: [URL] = []
    private var controller: MainViewController?
    private var window: NSWindow?

    override func tearDown() {
        controller?.windowModel.pane1.close()
        controller?.windowModel.pane2.close()
        for url in urls { try? FileManager.default.removeItem(at: url) }
        urls = []
        window?.orderOut(nil)
        window = nil
        controller = nil
        super.tearDown()
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<4 {
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            window.layoutIfNeeded()
        }
    }

    private func makeWindow() -> (MainViewController, NSWindow) {
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        self.controller = controller
        self.window = window
        return (controller, window)
    }

    private func openSingle(_ bytes: [UInt8]) throws -> (MainViewController, NSWindow) {
        let (controller, window) = makeWindow()
        let url = try tempFile(bytes)
        urls.append(url)
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        settle(window)
        return (controller, window)
    }

    private func top(_ controller: MainViewController, _ pane: PaneViewModel) throws -> UInt64 {
        try XCTUnwrap(controller.filePaneView(for: pane)).firstVisibleOffset
    }

    /// Go To records the place it leaves — the caret and the rows on screen —
    /// and Back puts both back; Forward returns to the jump's end.
    func testBackUndoesAGoToAndForwardRedoesIt() throws {
        let (controller, _) = try openSingle([UInt8](repeating: 0x11, count: 0x10000))
        let pane = controller.windowModel.pane1
        pane.moveCaret(to: 0x40, center: false)
        let topBefore = try top(controller, pane)
        XCTAssertFalse(controller.canNavigateBack, "nothing to go back to before a jump")

        controller.goToForTesting(offset: 0x8000)
        XCTAssertEqual(pane.caretOffset, 0x8000)
        let topAfter = try top(controller, pane)
        XCTAssertTrue(controller.canNavigateBack)

        controller.navigateBack()
        XCTAssertEqual(pane.caretOffset, 0x40)
        XCTAssertEqual(try top(controller, pane), topBefore, "the same rows on screen")
        XCTAssertFalse(controller.canNavigateBack)
        XCTAssertTrue(controller.canNavigateForward)

        controller.navigateForward()
        XCTAssertEqual(pane.caretOffset, 0x8000)
        XCTAssertEqual(try top(controller, pane), topAfter)
        XCTAssertFalse(controller.canNavigateForward)
    }

    /// An arrow key is not a jump: the history is not filled a row at a time,
    /// and Back after walking goes to where the last jump started.
    func testTheCaretWalkingRecordsNothing() throws {
        let (controller, _) = try openSingle([UInt8](repeating: 0x11, count: 0x10000))
        let pane = controller.windowModel.pane1
        controller.goToForTesting(offset: 0x4000)
        for _ in 0..<5 { pane.moveCaret(by: 16, center: false) }
        XCTAssertEqual(controller.windowModel.navigationHistory.backStack.count, 1)
        controller.navigateBack()
        XCTAssertEqual(pane.caretOffset, 0)
        // Forward goes back to where the walk ended, not to where the jump landed.
        controller.navigateForward()
        XCTAssertEqual(pane.caretOffset, 0x4000 + 5 * 16)
    }

    /// A tool moving the dump is not a step by itself: a tree reveals on
    /// every row its arrow keys pass. The tool says which moves are steps.
    func testAToolsRevealAndZoneScrollRecordNothing() throws {
        let (controller, _) = try openSingle([UInt8](repeating: 0x11, count: 0x10000))
        let pane = controller.windowModel.pane1
        controller.revealForTool(0x1000..<0x1010, in: pane, select: false)
        controller.showZoneStartForTool(0x8000, in: pane)
        XCTAssertTrue(controller.windowModel.navigationHistory.backStack.isEmpty)
    }

    /// A place in a file that is no longer in its pane is not one to go to.
    func testAPlaceInAReplacedFileIsSkipped() throws {
        let (controller, window) = try openSingle([UInt8](repeating: 0x11, count: 0x10000))
        controller.goToForTesting(offset: 0x4000)
        XCTAssertTrue(controller.canNavigateBack)
        let other = try tempFile([UInt8](repeating: 0x22, count: 0x10000))
        urls.append(other)
        try controller.windowModel.pane1.open(url: other)
        settle(window)
        XCTAssertFalse(controller.canNavigateBack)
    }

    /// In a comparison a jump moves both panes, and Back puts both back.
    func testBackPutsBothPanesOfAComparisonBack() throws {
        var left = [UInt8](repeating: 0x11, count: 300 * 16)
        var right = left
        left[100 * 16] = 0xDE
        right[100 * 16] = 0x00
        let (controller, window) = makeWindow()
        let urlA = try tempFile(left), urlB = try tempFile(right)
        urls += [urlA, urlB]
        try controller.windowModel.pane1.open(url: urlA)
        try controller.windowModel.pane2.open(url: urlB)
        controller.apply(mode: .comparison)
        settle(window)
        let panes = descendants(of: window.contentView!, FilePaneView.self)
        XCTAssertTrue(pumpUntil(5) { panes.contains { $0.comparisonInfo.contains("differing") } })

        controller.nextDifference()
        XCTAssertTrue(pumpUntil(5) { controller.windowModel.pane1.caretOffset == 1600 })
        XCTAssertEqual(controller.windowModel.pane2.caretOffset, 1600)

        controller.navigateBack()
        XCTAssertEqual(controller.windowModel.pane1.caretOffset, 0)
        XCTAssertEqual(controller.windowModel.pane2.caretOffset, 0)
    }

    /// The commands are in the View menu on ⌘[ and ⌘], and a ‹ › pair in the
    /// toolbar, both following whether there is anywhere to go.
    func testTheMenuItemsAndTheToolbarFollowTheHistory() throws {
        let menu = MainMenu.makeViewMenu()
        let back = try XCTUnwrap(menu.items.first { $0.action == #selector(MainViewController.navigateBack) })
        let forward = try XCTUnwrap(menu.items.first { $0.action == #selector(MainViewController.navigateForward) })
        XCTAssertEqual(back.keyEquivalent, "[")
        XCTAssertEqual(forward.keyEquivalent, "]")
        XCTAssertEqual(back.keyEquivalentModifierMask, [.command])

        let (controller, _) = try openSingle([UInt8](repeating: 0x11, count: 0x10000))
        XCTAssertFalse(controller.validateMenuItem(back))
        controller.goToForTesting(offset: 0x4000)
        XCTAssertTrue(controller.validateMenuItem(back))
        XCTAssertFalse(controller.validateMenuItem(forward))

        let item = NSToolbarItem(itemIdentifier: .navigateBack)
        item.action = #selector(MainViewController.navigateBack)
        XCTAssertTrue(controller.validateToolbarItem(item))
    }
}
