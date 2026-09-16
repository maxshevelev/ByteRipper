import XCTest
import ToolModuleKit
@testable import ByteRipper

/// The tool-module panel: the split's leading pane, what opens it, how wide it
/// opens, and what it does to the window (`Design/TOOL_MODULES_PLAN.md`).
@MainActor
final class ToolPanelTests: XCTestCase {
    private var defaultsName: String?
    private var url: URL?
    private var controller: MainViewController?

    override func setUp() {
        super.setUp()
        installToolStubs()
        let isolated = isolatedDefaults(for: self)
        defaultsName = isolated.name
        ToolController.defaults = isolated.store
        // The minimap's stored width shares the isolation: a test that opens
        // it must not read whatever width this machine's user last dragged it
        // to, and must not write one back.
        MainViewController.minimapDefaults = isolated.store
    }

    override func tearDown() {
        controller?.windowModel.pane1.close()
        if let url { try? FileManager.default.removeItem(at: url) }
        if let defaultsName {
            discardIsolatedDefaults(defaultsName, ToolController.defaults)
        }
        ToolController.defaults = .standard
        MainViewController.minimapDefaults = .standard
        controller = nil
        url = nil
        super.tearDown()
    }

    /// A window wide enough that a 500 pt panel is not clamped by the dump's
    /// own minimum — the clamp has a test of its own — and narrow enough that
    /// it still fits on a laptop screen once the panel has grown it, which is
    /// what the window-move test needs.
    private func makeController(width: CGFloat = 900) throws -> (MainViewController, NSWindow) {
        let file = try tempFile([UInt8](repeating: 0xFF, count: 0x100))
        url = file
        let controller = MainViewController()
        self.controller = controller
        let window = makeTestWindow(width: width, height: 700)
        window.contentViewController = controller
        // Installing a content view controller resizes the window to the view's
        // own size, so the width this test asked for is set afterwards — and
        // the window is placed with room on its left, since opening the panel
        // moves that edge and a window against the screen's edge would be
        // pushed back the other way.
        window.setContentSize(NSSize(width: width, height: 700))
        if let visible = window.screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visible.midX - width / 2, y: visible.minY + 100))
        }
        try controller.windowModel.pane1.open(url: file)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        return (controller, window)
    }

    private func panelWidth(_ controller: MainViewController) -> CGFloat {
        controller.view.layoutSubtreeIfNeeded()
        return controller.toolPanelWidth()
    }

    // MARK: - Opening and closing

    func testThePanelIsClosedUntilAModuleIsPicked() throws {
        let (controller, _) = try makeController()

        XCTAssertFalse(controller.tools.isPanelVisible)
        XCTAssertEqual(panelWidth(controller), 0)
    }

    func testActivatingAModuleOpensThePanelAtTheWidthItAsksFor() throws {
        let (controller, _) = try makeController()

        controller.tools.activate(StubToolB.identifier, animated: false)

        XCTAssertTrue(controller.tools.isPanelVisible)
        XCTAssertEqual(panelWidth(controller), StubToolB.preferredPanelWidth, accuracy: 1)
    }

    /// What the header answers is *which file* — a session is bound to the pane
    /// it was opened for, so in a comparison the panel and the pane being typed
    /// in can be different files.
    func testTheHeaderNamesTheModuleAndTheFile() throws {
        let (controller, _) = try makeController()

        controller.tools.activate(StubToolA.identifier, animated: false)

        XCTAssertEqual(controller.tools.panel.title, StubToolA.title)
        XCTAssertEqual(controller.tools.panel.fileName, controller.windowModel.pane1.status.fileName)
    }

    // MARK: - The header's file selector

    /// Opens a second file into the other pane, so there is something to switch
    /// between. Returns the second file's URL.
    @discardableResult
    private func openSecondFile(_ controller: MainViewController) throws -> URL {
        let file = try tempFile([UInt8](repeating: 0x01, count: 0x80))
        controller.openFiles(into: 1, urls: [file])
        controller.windowModel.setActivePane(0)
        controller.refreshToolPanelHeader()
        return file
    }

    /// With both panes open the selector offers both names, in pane order, and
    /// ticks the pane the session is reading.
    func testTheSelectorOffersBothPanesAndTicksTheBoundOne() throws {
        let (controller, _) = try makeController()
        try openSecondFile(controller)

        controller.tools.activate(StubToolA.identifier, animated: false)

        XCTAssertEqual(controller.tools.panel.paneTitles,
                       [controller.windowModel.pane1.status.fileName,
                        controller.windowModel.pane2.status.fileName])
        XCTAssertEqual(controller.tools.panel.tickedPaneIndex, 0,
                       "the session started against pane 1")
    }

    /// Every entry names its own pane, and the ticked one is the entry the
    /// closed popup draws: there is one answer to *which file* — the file the
    /// session reads — and one list to answer it with.
    func testTheEntriesNameTheirOwnPanesAndTheHeaderNamesTheTickedOne() throws {
        let (controller, _) = try makeController()
        try openSecondFile(controller)
        controller.tools.activate(StubToolA.identifier, animated: false)
        controller.activatePaneForTesting(1)
        let selector = controller.tools.panel.paneSelector

        // The entry under the pointer is somewhere to send the tool, so it has
        // to say where that is — pane order, one name each.
        XCTAssertEqual(controller.tools.panel.paneTitles,
                       [controller.windowModel.pane1.status.fileName,
                        controller.windowModel.pane2.status.fileName])

        // And the selected entry — the one the header draws while the menu is
        // shut — is the pane the tool is reading, not the pane the user is in.
        XCTAssertEqual(controller.tools.panel.tickedPaneIndex, 0)
        XCTAssertEqual(selector.titleOfSelectedItem,
                       controller.windowModel.pane1.status.fileName)
    }

    /// Switching the active pane does not take the tool with it: the session
    /// goes on reading the file it was opened for, and the header goes on
    /// naming that file. Dropping a pane on the panel and choosing one in the
    /// selector are the only two gestures that change which file the panel is
    /// on.
    func testTheHeaderKeepsNamingTheBoundFileWhenTheOtherPaneIsActivated() throws {
        let (controller, window) = try makeController()
        try openSecondFile(controller)
        controller.tools.activate(StubToolA.identifier, animated: false)
        let fileOfPane1 = controller.windowModel.pane1.status.fileName

        controller.activatePaneForTesting(1)
        window.layoutIfNeeded()

        XCTAssertEqual(controller.windowModel.activePaneIndex, 1,
                       "the premise: the user has clicked into pane 2")
        XCTAssertTrue(controller.tools.boundPane === controller.windowModel.pane1,
                      "the session is where it was opened")
        XCTAssertEqual(controller.tools.panel.fileName, fileOfPane1,
                       "so the header goes on naming pane 1's file")
        XCTAssertEqual(controller.tools.panel.tickedPaneIndex, 0)
        XCTAssertEqual(controller.tools.panel.paneTitles,
                       [fileOfPane1, controller.windowModel.pane2.status.fileName],
                       "and the menu still says which pane each entry stands for")
    }

    /// Picking the other pane moves the tool onto it through the same door a
    /// drop uses — a new session, bound to the new pane — and the header
    /// follows the tool, naming the file it now reads.
    ///
    /// And, like a drop, it moves the *tool* and not the user: the active pane
    /// is where the user is working and sending a tool somewhere does not
    /// change that, so the header names the file the user is not in.
    func testChoosingTheOtherPaneMovesTheSessionToIt() throws {
        let (controller, _) = try makeController()
        try openSecondFile(controller)
        controller.tools.activate(StubToolA.identifier, animated: false)

        controller.tools.selectPane(at: 1)

        XCTAssertTrue(controller.tools.boundPane === controller.windowModel.pane2,
                      "the session is bound to the pane that was chosen")
        XCTAssertEqual(controller.tools.panel.tickedPaneIndex, 1,
                       "the tick follows the tool")
        XCTAssertEqual(controller.tools.panel.fileName,
                       controller.windowModel.pane2.status.fileName,
                       "and the header names the file the tool has moved to")
        XCTAssertEqual(controller.windowModel.activePaneIndex, 0,
                       "while the user stays where they were")
    }

    /// Swapping the panes moves the session's pane to the other position, and
    /// the header's list is in pane order — so without a re-read the tick would
    /// come to sit on the file the tool is *not* reading, which is the one
    /// thing the header exists to say.
    func testSwappingThePanesMovesTheTickWithTheSession() throws {
        let (controller, _) = try makeController()
        try openSecondFile(controller)
        controller.tools.activate(StubToolA.identifier, animated: false)
        let fileOfPane1 = controller.windowModel.pane1.status.fileName

        controller.swapPanes()

        XCTAssertTrue(controller.tools.boundPane === controller.windowModel.pane2,
                      "the session's pane has moved to the other position")
        XCTAssertEqual(controller.tools.panel.tickedPaneIndex, 1)
        XCTAssertEqual(controller.tools.panel.fileName, fileOfPane1,
                       "and the header goes on naming the same file")
    }

    /// With one file open there is nowhere to move the tool, so the selector is
    /// disabled rather than being a control that does nothing.
    func testTheSelectorIsDisabledWithOneFileOpen() throws {
        let (controller, _) = try makeController()
        controller.tools.activate(StubToolA.identifier, animated: false)

        XCTAssertFalse(controller.tools.panel.paneSelector.isEnabled)
    }

    /// And live once there is a second file to move to.
    func testTheSelectorIsEnabledWithTwoFilesOpen() throws {
        let (controller, _) = try makeController()
        try openSecondFile(controller)
        controller.tools.activate(StubToolA.identifier, animated: false)

        XCTAssertTrue(controller.tools.panel.paneSelector.isEnabled)
    }

    /// A closed pane keeps its entry, disabled, so the list is the same length
    /// in the same order whatever is open.
    func testAClosedPaneKeepsADisabledEntry() throws {
        let (controller, _) = try makeController()
        try openSecondFile(controller)
        controller.tools.activate(StubToolA.identifier, animated: false)

        controller.closePane(at: 1)

        XCTAssertEqual(controller.tools.panel.paneTitles.count, 2,
                       "the entry stays, so position always means the same pane")
        XCTAssertFalse(controller.tools.panel.paneSelector.itemArray[1].isEnabled,
                       "and it is not somewhere the tool can be sent")
    }

    /// Ending the session takes the tick with it: nothing open means no pane is
    /// the one being read, and the header must not go on saying one is.
    func testNoneLeavesNoPaneTicked() throws {
        let (controller, _) = try makeController()
        try openSecondFile(controller)
        controller.tools.activate(StubToolA.identifier, animated: false)

        controller.tools.activate(nil, animated: false)

        XCTAssertNil(controller.tools.panel.tickedPaneIndex)
    }

    /// The header is chrome beside the dump, not a dark bar in front of it: the
    /// same translucent fill the panes' own headers use. It was
    /// `underPageBackgroundColor` — a page's *surround*, which reads as a slab
    /// of dark grey next to a light dump.
    func testTheHeaderIsTheSameChromeAsAPanesHeader() throws {
        let (controller, _) = try makeController()
        controller.tools.activate(StubToolA.identifier, animated: false)

        XCTAssertEqual(controller.tools.panel.headerFill, NSColor.tertiarySystemFill.cgColor)
        XCTAssertNotEqual(controller.tools.panel.headerFill,
                          NSColor.underPageBackgroundColor.cgColor)
    }

    /// And it carries the wrench the toolbar's Tools button carries, so the
    /// panel and the button that opened it read as one thing.
    func testTheHeaderCarriesTheToolsIcon() throws {
        let (controller, _) = try makeController()
        controller.tools.activate(StubToolA.identifier, animated: false)

        XCTAssertNotNil(controller.tools.panel.headerIcon)
    }

    func testNoneClosesThePanel() throws {
        let (controller, _) = try makeController()
        controller.tools.activate(StubToolA.identifier, animated: false)

        controller.tools.activate(nil, animated: false)

        XCTAssertFalse(controller.tools.isPanelVisible)
        XCTAssertEqual(panelWidth(controller), 0)
    }

    func testThePanelsCloseButtonIsToolsNone() throws {
        let (controller, _) = try makeController()
        controller.tools.activate(StubToolA.identifier, animated: false)

        controller.tools.panel.onClose?()

        XCTAssertNil(controller.tools.activeIdentifier)
        XCTAssertFalse(controller.tools.isPanelVisible)
    }

    // MARK: - Width

    /// A FIT table wants twice what a tree does, so the width the user drags is
    /// remembered per tool-module rather than shared.
    func testTheWidthTheUserDragsIsRememberedForThatModuleAlone() throws {
        let (controller, _) = try makeController()
        controller.tools.activate(StubToolA.identifier, animated: false)

        controller.panelSplit.setDividerPosition(360, at: MainViewController.toolDividerIndex)
        controller.tools.activate(StubToolB.identifier, animated: false)
        let widthOfB = panelWidth(controller)
        controller.tools.activate(StubToolA.identifier, animated: false)

        XCTAssertEqual(widthOfB, StubToolB.preferredPanelWidth, accuracy: 1,
                       "B opens at its own width, not at the one dragged for A")
        XCTAssertEqual(panelWidth(controller), 360, accuracy: 1,
                       "A opens where it was left")
    }

    /// The file is what the window is for: the panel stops growing rather than
    /// the dump disappearing.
    func testThePanelNeverSqueezesTheDumpBelowItsMinimum() throws {
        let (controller, _) = try makeController(width: 700)

        controller.tools.activate(StubToolB.identifier, animated: false)

        let width = panelWidth(controller)
        XCTAssertLessThan(width, StubToolB.preferredPanelWidth)
        XCTAssertGreaterThanOrEqual(700 - width, ToolController.minContentWidth)
    }

    /// A drag cannot open a panel that has no tool-module in it.
    func testWhileClosedTheDividerCannotBeDraggedOpen() throws {
        let (controller, _) = try makeController()

        controller.panelSplit.setDividerPosition(300, at: MainViewController.toolDividerIndex)

        XCTAssertEqual(panelWidth(controller), 0)
    }

    // MARK: - The window

    /// A window dragged wider than its hex grid has room in it, and the panel
    /// opens into that room first: the window grows only by what the room
    /// cannot cover, and the dump gives up its spare width rather than its
    /// content. Closing the panel puts both back — the room returns to the
    /// dump, and the window gives up only what it actually gained.
    func testThePanelSpendsTheDumpsSpareWidthBeforeTheWindowGrows() throws {
        let (controller, window) = try makeController()
        let before = window.frame
        let contentBefore = controller.contentHost.frame.width
        let slack = controller.dumpAreaSlack()
        XCTAssertGreaterThan(slack, 0, "the premise: this window is wider than its grid")
        XCTAssertLessThan(slack, StubToolA.preferredPanelWidth,
                          "and not so much wider that the panel fits in the room alone")

        controller.tools.activate(StubToolA.identifier, animated: false)
        window.layoutIfNeeded()

        XCTAssertEqual(window.frame.maxX, before.maxX, accuracy: 1,
                       "the right edge stays put; the left one carries the change")
        XCTAssertEqual(window.frame.width,
                       before.width + StubToolA.preferredPanelWidth - slack, accuracy: 2,
                       "the window grows by the panel's width less the room already there")
        XCTAssertEqual(controller.contentHost.frame.width, contentBefore - slack, accuracy: 2,
                       "the dump gave up its spare width, and nothing more")
        XCTAssertEqual(controller.dumpAreaSlack(), 0, accuracy: 2,
                       "which is exactly the width its grid needs")

        controller.tools.activate(nil, animated: false)
        window.layoutIfNeeded()

        XCTAssertEqual(window.frame.width, before.width, accuracy: 2,
                       "closing gives back what opening took, and no more")
        XCTAssertEqual(controller.contentHost.frame.width, contentBefore, accuracy: 2,
                       "and the dump has its room back")
    }

    /// With no room to spare the rule is the old one: the window carries the
    /// whole panel, so the dump keeps the width its content needs.
    func testWithNoSpareWidthTheWindowCarriesTheWholePanel() throws {
        let (controller, window) = try makeController()

        // Take the window down to exactly the width the hex grid wants.
        let content = try XCTUnwrap(window.contentView).frame
        window.setContentSize(NSSize(width: content.width - controller.dumpAreaSlack(),
                                     height: content.height))
        window.layoutIfNeeded()
        XCTAssertEqual(controller.dumpAreaSlack(), 0, accuracy: 2, "the premise: no room left")

        let before = window.frame
        let contentBefore = controller.contentHost.frame.width
        controller.tools.activate(StubToolA.identifier, animated: false)
        window.layoutIfNeeded()

        XCTAssertEqual(window.frame.width, before.width + StubToolA.preferredPanelWidth,
                       accuracy: 2, "the window carries all of it")
        XCTAssertEqual(controller.contentHost.frame.width, contentBefore, accuracy: 2,
                       "so the dump keeps its width")
    }

    // MARK: - Beside the minimap

    /// The same rule on the trailing edge: the minimap opens into the dump's
    /// spare width before the window's right edge moves. Its width fits inside
    /// the room this window has, so the window does not move at all — and
    /// hiding it again leaves the window where it was rather than shrinking it
    /// by a panel the window never paid for.
    func testTheMinimapAlsoOpensIntoTheDumpsSpareWidth() throws {
        let (controller, window) = try makeController()
        let before = window.frame.width
        let contentBefore = controller.contentHost.frame.width
        let width = controller.minimapPreferredPanelWidth + controller.panelSplit.dividerThickness
        XCTAssertLessThan(width, controller.dumpAreaSlack(),
                          "the premise: the panel fits in the room the window already has")

        controller.setMinimapPanelVisible(true, animated: false)
        window.layoutIfNeeded()

        XCTAssertEqual(window.frame.width, before, accuracy: 1,
                       "the room covered it, so the window did not move")
        XCTAssertEqual(controller.contentHost.frame.width, contentBefore - width, accuracy: 2,
                       "the dump gave the panel its spare width")

        controller.setMinimapPanelVisible(false, animated: false)
        window.layoutIfNeeded()

        XCTAssertEqual(window.frame.width, before, accuracy: 1,
                       "and hiding it leaves the window where it was")
        XCTAssertEqual(controller.contentHost.frame.width, contentBefore, accuracy: 2,
                       "with the room back in the dump")
    }

    /// Both panels open at once, one on each edge, with the dump between them —
    /// the case that broke when the split gained a third pane and every divider
    /// index moved.
    func testBothPanelsOpenOnTheirOwnEdges() throws {
        let (controller, window) = try makeController(width: 1400)

        controller.tools.activate(StubToolA.identifier, animated: false)
        controller.setMinimapPanelVisible(true, animated: false)
        window.layoutIfNeeded()

        let panel = controller.tools.panel.frame
        let content = controller.contentHost.frame
        let minimap = controller.minimapPanel.frame
        XCTAssertEqual(panel.minX, 0, accuracy: 1)
        XCTAssertLessThanOrEqual(panel.maxX, content.minX)
        XCTAssertLessThanOrEqual(content.maxX, minimap.minX)
        XCTAssertGreaterThan(minimap.width, 0)
        XCTAssertGreaterThan(content.width, 0)
    }
}
