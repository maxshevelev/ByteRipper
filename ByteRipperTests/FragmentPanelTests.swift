import AppPalette
import XCTest
@testable import ByteRipper

/// `Design/FRAGMENT_PANELS_PLAN.md`: a part of a file opened as a panel over
/// the window that holds it — the geometry that leaves the parent showing, the
/// slide, the dock of pills, and the marks a panel keeps to itself.
@MainActor
final class FragmentPanelTests: XCTestCase {
    /// A real controller in a real window, laid out, so the panel host has a
    /// size to place panels in.
    private func makeController() -> (MainViewController, NSWindow) {
        let controller = MainViewController()
        let window = makeTestWindow()
        window.contentViewController = controller
        // Taking a controller shrinks the window to what its view asks for, and
        // an empty window asks for nothing: without this the panel host has no
        // height to place a panel in.
        window.setContentSize(NSSize(width: 800, height: 600))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    private func cleanup(_ controller: MainViewController) {
        for id in controller.fragments.dock.panels {
            controller.fragments.close(id, animated: false)
        }
        controller.windowModel.pane1.close()
        controller.windowModel.pane2.close()
    }

    private func host(of controller: MainViewController) throws -> FragmentPanelHost {
        try XCTUnwrap(descendants(of: controller.view, FragmentPanelHost.self).first)
    }

    private func strip(of controller: MainViewController) throws -> FragmentDockStrip {
        try XCTUnwrap(descendants(of: controller.view, FragmentDockStrip.self).first)
    }

    // MARK: - The geometry

    /// The panel's top edge covers a fifth of the parent's header: enough of an
    /// overlap to say the panel is over it, little enough that the header is
    /// still readable.
    func testThePanelCoversAFifthOfTheParentsHeader() {
        let height = FragmentPanelLayout.panelHeight(hostHeight: 600)
        XCTAssertEqual(height, 600 - FragmentPanelLayout.parentPeek)
        XCTAssertEqual(FragmentPanelLayout.parentPeek,
                       FilePaneView.headerHeight * 0.8, accuracy: 0.001)
        XCTAssertEqual(FragmentPanelLayout.headerCoveredShare, 0.2)
    }

    /// In a short window the peek gives way before the panel does: the part is
    /// what was asked for.
    func testAShortAreaGivesUpThePeekBeforeTheMinimum() {
        let short = FragmentPanelLayout.minimumPanelHeight + FragmentPanelLayout.parentPeek - 10
        XCTAssertEqual(FragmentPanelLayout.panelHeight(hostHeight: short),
                       FragmentPanelLayout.minimumPanelHeight,
                       "the panel keeps its minimum and the peek takes the loss")
    }

    /// And in an area smaller than the minimum the panel takes what there is
    /// rather than hanging off the bottom.
    func testThePanelNeverOutgrowsItsArea() {
        for height in [0.0, 40.0, 100.0, 159.0, 200.0, 600.0, 2000.0] {
            let panel = FragmentPanelLayout.panelHeight(hostHeight: height)
            XCTAssertGreaterThanOrEqual(panel, 0, "at host height \(height)")
            XCTAssertLessThanOrEqual(panel, height, "at host height \(height)")
        }
    }

    // MARK: - Opening

    /// Opening a part raises a panel and puts a pill in the dock, named after
    /// the part.
    func testOpeningAFragmentRaisesAPanelAndPutsAPillInTheDock() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }

        let id = try XCTUnwrap(controller.openFragment([0xAA, 0xBB], named: "NVRAM",
                                                       animated: false))

        XCTAssertEqual(controller.fragments.count, 1)
        XCTAssertEqual(controller.fragments.expanded, id, "what you asked for is on screen")
        let pills = try strip(of: controller).pillsForTesting
        XCTAssertEqual(pills.map(\.title), ["NVRAM"])
        XCTAssertTrue(pills[0].isUp, "the pill of the panel in front is the filled one")
    }

    /// The panel is an ordinary hex panel: the header with the name is the
    /// pane's own, not chrome invented for the panel.
    func testThePanelShowsTheFragmentInAPaneOfItsOwn() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }

        let id = try XCTUnwrap(controller.openFragment([UInt8](0..<32), named: "ME body",
                                                       animated: false))

        let panel = try XCTUnwrap(controller.fragments.panelView(id))
        let panes = descendants(of: panel, FilePaneView.self)
        XCTAssertEqual(panes.count, 1, "one pane, in the panel's own surface")
        XCTAssertEqual(controller.fragments.pane(id)?.status.fileName, "ME body")
        XCTAssertEqual(controller.fragments.pane(id)?.fileSize, 32)
        XCTAssertNotNil(controller.fragments.surface(id)?.minimapView,
                        "and its own minimap, which is what makes it a surface")
    }

    /// Only one panel is ever up: opening a second folds the first, and its
    /// view goes below the area it slides in.
    func testASecondPanelFoldsTheFirst() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }

        let first = try XCTUnwrap(controller.openFragment([0x01], named: "one", animated: false))
        let second = try XCTUnwrap(controller.openFragment([0x02], named: "two", animated: false))

        XCTAssertEqual(controller.fragments.expanded, second)
        let folded = try XCTUnwrap(controller.fragments.panelView(first))
        XCTAssertLessThan(folded.frame.maxY, 1, "the folded panel is out of the clipped area")
        let up = try XCTUnwrap(controller.fragments.panelView(second))
        XCTAssertEqual(up.frame.minY, 0, "and the one that is up sits on the dock's edge")
        XCTAssertEqual(try strip(of: controller).pillsForTesting.filter(\.isUp).count, 1)
    }

    // MARK: - Folding and raising

    /// Clicking the pill of the panel on screen folds it; clicking a folded
    /// one raises it.
    func testThePillRaisesAndFoldsItsPanel() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let id = try XCTUnwrap(controller.openFragment([0x01], named: "one", animated: false))

        controller.fragments.toggle(id, animated: false)
        XCTAssertNil(controller.fragments.expanded, "the dump behind comes back")
        XCTAssertEqual(controller.fragments.count, 1, "folding is not closing")

        controller.fragments.toggle(id, animated: false)
        XCTAssertEqual(controller.fragments.expanded, id)
    }

    /// With nothing up, the area the panels live in is transparent to the
    /// pointer — otherwise a tab that had once opened a panel would have an
    /// unreachable dump.
    func testTheAreaIsTransparentWhileNothingIsUp() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let panelHost = try host(of: controller)

        XCTAssertNil(panelHost.hitTest(NSPoint(x: 10, y: 10)), "nothing has ever been opened")

        let id = try XCTUnwrap(controller.openFragment([0x01], named: "one", animated: false))
        controller.fragments.collapse(animated: false)
        XCTAssertTrue(panelHost.isHidden, "a folded panel leaves the panes to the pointer")
        XCTAssertNil(panelHost.hitTest(NSPoint(x: 10, y: 10)))
        _ = id
    }

    // MARK: - Closing

    /// Closing takes the pill, lets go of the pane, and — for the last one —
    /// takes the dock away.
    func testClosingAPanelTakesItsPillAndTheLastOneTakesTheDock() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let first = try XCTUnwrap(controller.openFragment([0x01], named: "one", animated: false))
        let second = try XCTUnwrap(controller.openFragment([0x02], named: "two", animated: false))

        controller.fragments.close(second, animated: false)
        XCTAssertEqual(try strip(of: controller).pillsForTesting.map(\.title), ["one"])
        XCTAssertNil(controller.fragments.expanded,
                     "closing the panel that was up leaves the dump showing, not the next pill")
        XCTAssertNil(controller.fragments.pane(second))

        controller.fragments.close(first, animated: false)
        XCTAssertTrue(controller.fragments.isEmpty)
        XCTAssertTrue(pumpUntil(1) { (try? self.strip(of: controller).frame.height) == 0 },
                      "the dock gives its height back when the last panel goes")
    }

    /// A panel let go of rather than closed keeps its document: the pane is
    /// handed over whole, which is what tearing one off into a tab needs.
    func testReleasingAPanelHandsBackItsPaneStillOpen() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let id = try XCTUnwrap(controller.openFragment([0x01, 0x02], named: "part", animated: false))

        let released = try XCTUnwrap(controller.fragments.release(id, animated: false))

        XCTAssertTrue(controller.fragments.isEmpty, "the dock has let it go")
        XCTAssertTrue(released.pane.isOpen, "but the document is still open, to be put somewhere")
        XCTAssertEqual(released.pane.fileSize, 2)
        XCTAssertNil(released.pane.bookmarkStore,
                     "it travels with no list, to take its new home's")
        released.pane.close()
    }

    /// The header's ✕ closes the panel. It is the pane's own button, and it did
    /// nothing at all until the panel's pane view was given the wiring the
    /// tab's panes get.
    func testTheHeadersCloseButtonClosesThePanel() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let id = try XCTUnwrap(controller.openFragment([0x01, 0x02], named: "part",
                                                       animated: false))
        let panel = try XCTUnwrap(controller.fragments.panelView(id))
        let close = try XCTUnwrap(descendants(of: panel, NSButton.self).first {
            $0.accessibilityLabel() == "Close pane"
        })

        close.performClick(nil)

        XCTAssertTrue(controller.fragments.isEmpty, "the panel goes, and its pill with it")
        XCTAssertTrue(try strip(of: controller).pillsForTesting.isEmpty)
    }

    /// And the header's right-click menu is this part's, not the dump's.
    func testTheHeaderCarriesThePartsOwnMenu() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let id = try XCTUnwrap(controller.openFragment([0x01, 0x02], named: "part",
                                                       animated: false))
        let paneView = controller.paneView(for: try XCTUnwrap(controller.fragments.pane(id)))

        let menu = try XCTUnwrap(paneView.paneMenu, "the header has a menu at all")
        XCTAssertTrue(menu.items.contains { $0.title == "Open in New Tab" })
    }

    // MARK: - While a panel is in front

    /// The panel takes the keyboard. Without this the dump behind kept the
    /// first responder, so every key went into the file the reader could not
    /// see — and folding gives it back.
    func testThePanelInFrontTakesTheKeyboard() throws {
        let (controller, window) = makeController()
        defer { cleanup(controller) }
        let url = try tempFile([UInt8](repeating: 0xAA, count: 0x200))
        defer { try? FileManager.default.removeItem(at: url) }
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        let dumpHex = try XCTUnwrap(descendants(of: controller.view, HexView.self).first)

        let id = try XCTUnwrap(controller.openFragment([0x01, 0x02], named: "part", animated: false))
        window.layoutIfNeeded()
        let panel = try XCTUnwrap(controller.fragments.panelView(id))
        let partHex = try XCTUnwrap(descendants(of: panel, HexView.self).first)
        XCTAssertTrue(window.firstResponder === partHex, "the part has the keyboard")

        controller.fragments.collapse(animated: false)
        XCTAssertTrue(window.firstResponder === dumpHex, "and folding gives it back to the dump")
    }

    /// The tab's panes take no orders while a panel is over them: a command
    /// that rearranged or joined something nobody can see would look like it
    /// did nothing.
    func testTheTabsPaneCommandsAreRefusedWhileAPanelIsUp() throws {
        let (controller, window) = makeController()
        defer { cleanup(controller) }
        let url = try tempFile([UInt8](repeating: 0xAA, count: 0x200))
        defer { try? FileManager.default.removeItem(at: url) }
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        let join = NSMenuItem(title: "Append File…",
                              action: #selector(MainViewController.appendFile), keyEquivalent: "")
        XCTAssertTrue(controller.validateMenuItem(join), "with nothing in front, the panes answer")

        _ = controller.openFragment([0x01], named: "part", animated: false)
        XCTAssertFalse(controller.validateMenuItem(join), "and refuse while a panel covers them")

        controller.fragments.collapse(animated: false)
        XCTAssertTrue(controller.validateMenuItem(join), "folded, they answer again")
    }

    /// The first panel of a tab stands where every later one does. It did not:
    /// it was raised while the dock was still growing from nothing, so it was
    /// measured against a stage a dock's height too tall and sat that much too
    /// high.
    func testTheFirstPanelStandsWhereTheNextOneWould() throws {
        let (controller, window) = makeController()
        defer { cleanup(controller) }

        let first = try XCTUnwrap(controller.openFragment([0x01], named: "one", animated: false))
        window.layoutIfNeeded()
        let host = try XCTUnwrap(descendants(of: controller.view, FragmentPanelHost.self).first)
        let firstFrame = try XCTUnwrap(controller.fragments.panelView(first)).frame
        XCTAssertEqual(firstFrame, FragmentPanelView.restingFrame(in: host),
                       "the first panel is placed on the stage the dock leaves it")

        // And the second, opened with the dock already there, lands in the same
        // place — which is the whole of what "as if it were not the first"
        // means.
        let second = try XCTUnwrap(controller.openFragment([0x02], named: "two", animated: false))
        window.layoutIfNeeded()
        XCTAssertEqual(try XCTUnwrap(controller.fragments.panelView(second)).frame, firstFrame)
        XCTAssertEqual(try strip(of: controller).frame.height, FragmentDockStrip.height,
                       "with the dock at its full height under both")
    }

    // MARK: - The landing's arithmetic

    /// A panel folded into its pill comes down on the pill — whatever the
    /// layer's anchor point is. It did not: a layer-backed NSView anchors at
    /// (0, 0) rather than at the centre, and a translation worked out between
    /// centres put the panel left of the window and below it.
    func testAPanelLandsExactlyOnItsPill() {
        let panel = NSRect(x: 0, y: 36, width: 900, height: 520)
        let pill = NSRect(x: 12, y: 8, width: 160, height: 24)
        for anchor in [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)] {
            let t = PanelLanding.transform(from: panel, on: pill, anchor: anchor)
            let landed = PanelLanding.landed(panel, with: t, anchor: anchor)
            XCTAssertEqual(landed.minX, pill.minX, accuracy: 0.001, "x at anchor \(anchor)")
            XCTAssertEqual(landed.minY, pill.minY, accuracy: 0.001, "y at anchor \(anchor)")
            XCTAssertEqual(landed.width, pill.width, accuracy: 0.001, "width at anchor \(anchor)")
            XCTAssertEqual(landed.height, pill.height, accuracy: 0.001, "height at anchor \(anchor)")
        }
    }

    /// A panel that lands on a pill to its right goes right, not left — the
    /// direction is the whole message of the flight.
    func testTheFlightGoesTowardsThePill() {
        let panel = NSRect(x: 0, y: 36, width: 900, height: 520)
        let far = NSRect(x: 700, y: 8, width: 160, height: 24)
        let t = PanelLanding.transform(from: panel, on: far, anchor: .zero)
        XCTAssertGreaterThan(t.tx, 0, "towards a pill on the right")
        XCTAssertLessThan(t.ty, 0, "and downwards, into the dock")
    }

    // MARK: - Where a fold lands

    /// Folding flies the panel into its own pill rather than dropping it off
    /// the bottom, because every pill looks like every other and the flight is
    /// the only thing that says which one it went into. The flight is over the
    /// dock, so the area stops clipping for its length and clips again after.
    func testAFoldFliesIntoItsPillAndLeavesNoTraceBehind() throws {
        let (controller, window) = makeController()
        defer { cleanup(controller) }
        let id = try XCTUnwrap(controller.openFragment([0x01, 0x02], named: "part", animated: false))
        window.layoutIfNeeded()
        let panel = try XCTUnwrap(controller.fragments.panelView(id))
        let strip = try self.strip(of: controller)
        XCTAssertNotNil(strip.pillFrame(for: id), "there is a pill to fly into")

        controller.fragments.collapse(animated: true)
        XCTAssertTrue(pumpUntil(2) { panel.superview == nil },
                      "the flight ends with the panel off the stage")

        let host = try XCTUnwrap(descendants(of: controller.view, FragmentPanelHost.self).first)
        XCTAssertEqual(host.layer?.masksToBounds, true, "and the area clips again afterwards")
        XCTAssertTrue(CATransform3DIsIdentity(panel.layer?.transform ?? CATransform3DIdentity),
                      "with nothing left of the flight on the panel itself")
        XCTAssertEqual(controller.fragments.count, 1, "folded, not closed")
    }

    // MARK: - The link when there is nowhere left to go

    /// A panel whose parent has closed stops showing a chain: the way back is
    /// gone, so the symbol says so and the button stops being one.
    func testALinkThatLeadsNowhereStopsLookingLikeALink() throws {
        let (controller, window) = makeController()
        defer { cleanup(controller) }
        let outer = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                          named: "part", animated: false))
        let part = try XCTUnwrap(controller.fragments.pane(outer))
        let bytes: [UInt8] = [0x01, 0x02, 0x03]
        let origin = try XCTUnwrap(DocumentOrigin(parent: part, source: 0x10..<0x13,
                                                  partName: "inner", layout: .image,
                                                  content: bytes))
        let inner = try XCTUnwrap(controller.openFragment(bytes, named: "inner.bin",
                                                          origin: origin, animated: false))
        window.layoutIfNeeded()
        let deeper = try XCTUnwrap(controller.fragments.pane(inner))
        let link = controller.paneView(for: deeper).linkButton
        XCTAssertEqual(controller.paneView(for: deeper).linkSymbolName, "link",
                       "while the way back is good")
        XCTAssertEqual(link.contentTintColor, NSColor.secondaryLabelColor, "drawn quietly")

        controller.fragmentCloseConfirm = { _ in .alertFirstButtonReturn }
        controller.closeFragment(outer)
        window.layoutIfNeeded()

        XCTAssertEqual(deeper.origin?.state, .parentClosed)
        XCTAssertEqual(controller.paneView(for: deeper).linkSymbolName, "xmark.octagon",
                       "the chain goes")
        XCTAssertEqual(link.contentTintColor, SemanticColors.bad,
                       "and the whole row goes red — grey on grey is not an indication")
        XCTAssertEqual(link.toolTip?.contains("no longer open"), true, "with the reason under it")
    }

    // MARK: - What a panel's header menu may and may not do

    /// The commands that put a document *into a pane* are not offered in a
    /// panel: a part has no pane beside it, and what they reached for was one
    /// of the tab's — Duplicate replaced the file behind the panel with a copy
    /// of the part.
    func testTheCommandsThatActOnTheTabsPanesAreNotOfferedInAPanel() throws {
        let (controller, window) = makeController()
        defer { cleanup(controller) }
        let url = try tempFile([UInt8](repeating: 0xAA, count: 0x200))
        defer { try? FileManager.default.removeItem(at: url) }
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        let id = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                       named: "part", animated: false))
        let part = try XCTUnwrap(controller.fragments.pane(id))
        let menu = controller.makePaneMenu(for: part)

        for title in ["Duplicate", "New File", "Open…"] {
            let item = try XCTUnwrap(menu.items.first { $0.title == title }, title)
            XCTAssertFalse(controller.validateMenuItem(item), "\(title) must be refused")
        }
        // And the tab's own pane still offers them.
        let dumpMenu = controller.makePaneMenu(for: controller.windowModel.pane1)
        let dup = try XCTUnwrap(dumpMenu.items.first { $0.title == "Duplicate" })
        XCTAssertTrue(controller.validateMenuItem(dup))
    }

    /// Rename in a panel renames the part. It did nothing: the view it asked
    /// for was looked up among the tab's two panes, and a panel's is neither.
    func testRenameInAPanelReachesThePart() throws {
        let (controller, window) = makeController()
        defer { cleanup(controller) }
        let id = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                       named: "part", animated: false))
        window.layoutIfNeeded()
        let part = try XCTUnwrap(controller.fragments.pane(id))
        XCTAssertNotNil(controller.filePaneView(for: part),
                        "the panel's pane has a view, and this is how it is found")

        let menu = controller.makePaneMenu(for: part)
        let rename = try XCTUnwrap(menu.items.first { $0.title == "Rename" })
        XCTAssertTrue(controller.validateMenuItem(rename), "an untitled part can be renamed")
        _ = rename.target?.perform(rename.action, with: rename)

        XCTAssertTrue(try XCTUnwrap(controller.filePaneView(for: part)).isRenaming,
                      "the header's name field is open on the part")
    }

    /// Close in a panel's header menu closes the panel, not one of the tab's
    /// panes — it asked for pane 1 or 2 by index, and a panel's pane is neither.
    func testCloseInAPanelsMenuClosesThePanel() throws {
        let (controller, window) = makeController()
        defer { cleanup(controller) }
        let url = try tempFile([UInt8](repeating: 0xAA, count: 0x200))
        defer { try? FileManager.default.removeItem(at: url) }
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        let id = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                       named: "part", animated: false))
        let part = try XCTUnwrap(controller.fragments.pane(id))
        let menu = controller.makePaneMenu(for: part)
        let close = try XCTUnwrap(menu.items.first { $0.title == "Close" })

        _ = close.target?.perform(close.action, with: close)

        XCTAssertTrue(controller.fragments.isEmpty, "the panel went")
        XCTAssertTrue(controller.windowModel.pane1.isOpen, "and the dump stayed")
    }

    // MARK: - Out into a tab

    /// A panel dragged onto the New Tab strip leaves for a tab of its own, and
    /// what leaves is the pane object — the document, its edits and its undo
    /// travel with it rather than being opened again.
    func testDraggingAPanelToTheNewTabStripMovesItIntoATab() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let id = try XCTUnwrap(controller.openFragment([0x01, 0x02, 0x03], named: "part",
                                                       animated: false))
        let part = try XCTUnwrap(controller.fragments.pane(id))
        let tab = MainViewController()
        defer { tab.windowModel.pane1.close() }
        controller.makeSiblingTab = { tab }

        controller.tearOffPaneToNewTab(draggedPaneID: part.dragID)

        XCTAssertTrue(controller.fragments.isEmpty, "the dock has let it go")
        XCTAssertTrue(tab.windowModel.pane1 === part, "the pane itself moved, bytes and all")
        XCTAssertEqual(tab.windowModel.pane1.fileSize, 3)
    }

    /// Its marks go with it: they were made against the part's own offsets and
    /// mean the same rows wherever it lands.
    func testThePanelsMarksTravelWithIt() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let id = try XCTUnwrap(controller.openFragment([UInt8](0..<64), named: "part",
                                                       animated: false))
        try XCTUnwrap(controller.fragments.pane(id)).bookmarkStore?.toggle(rowContaining: 0x20)
        let tab = MainViewController()
        defer { tab.windowModel.pane1.close() }
        controller.makeSiblingTab = { tab }

        controller.tearOffPaneToNewTab(draggedPaneID: try XCTUnwrap(controller.fragments.pane(id)).dragID)

        XCTAssertEqual(tab.windowModel.bookmarkStore.bookmarks.count, 1)
    }

    /// With Option held it is a copy: the tab gets a document holding the same
    /// bytes and the panel stays where it was.
    func testOptionDraggingAPanelCopiesItAndLeavesThePanel() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let id = try XCTUnwrap(controller.openFragment([0x01, 0x02, 0x03], named: "part",
                                                       animated: false))
        let part = try XCTUnwrap(controller.fragments.pane(id))
        let tab = MainViewController()
        defer { tab.windowModel.pane1.close() }
        controller.makeSiblingTab = { tab }

        controller.tearOffPaneToNewTab(draggedPaneID: part.dragID, copying: true)

        XCTAssertEqual(controller.fragments.count, 1, "the panel stays")
        XCTAssertFalse(tab.windowModel.pane1 === part, "and the tab holds a copy, not the part")
        XCTAssertEqual(tab.windowModel.pane1.fileSize, 3)
    }

    /// A folded panel has no header to drag, so its pill carries the same
    /// command in its own menu.
    func testAPillsMenuOffersOpeningThePanelInATab() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let id = try XCTUnwrap(controller.openFragment([0x01, 0x02], named: "part",
                                                       animated: false))
        let part = try XCTUnwrap(controller.fragments.pane(id))
        controller.fragments.collapse(animated: false)
        let tab = MainViewController()
        defer { tab.windowModel.pane1.close() }
        controller.makeSiblingTab = { tab }
        controller.fragments.refreshDock()

        let pill = try XCTUnwrap(strip(of: controller).pillsForTesting.first)
        let menu = try XCTUnwrap(pill.menu(for: NSEvent()))
        let item = try XCTUnwrap(menu.items.first { $0.title == "Open in New Tab" })
        XCTAssertTrue(item.isEnabled, "there is a window to put a tab beside")
        _ = item.target?.perform(item.action, with: item)

        XCTAssertTrue(controller.fragments.isEmpty)
        XCTAssertTrue(tab.windowModel.pane1 === part)
    }

    /// With no window to put a tab beside, the item is there and dimmed rather
    /// than missing — the same rule the pane header's twin follows.
    func testThePillsTabItemIsDimmedWithNoWindowToPutATabBeside() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        _ = controller.openFragment([0x01], named: "part", animated: false)

        let pill = try XCTUnwrap(strip(of: controller).pillsForTesting.first)
        let menu = try XCTUnwrap(pill.menu(for: NSEvent()))
        let item = try XCTUnwrap(menu.items.first { $0.title == "Open in New Tab" })
        XCTAssertFalse(item.isEnabled)
    }

    // MARK: - What a panel keeps to itself

    /// A part's offsets are its own, so its marks are its own: a bookmark made
    /// in a panel is not a bookmark in the window's list.
    func testAPanelsMarksAreItsOwn() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let id = try XCTUnwrap(controller.openFragment([UInt8](0..<64), named: "part",
                                                       animated: false))
        let pane = try XCTUnwrap(controller.fragments.pane(id))

        pane.bookmarkStore?.toggle(rowContaining: 0)

        XCTAssertEqual(pane.bookmarkStore?.bookmarks.count, 1)
        XCTAssertTrue(controller.windowModel.bookmarkStore.bookmarks.isEmpty,
                      "the window's list is about the dump's offsets, not the part's")
    }

    /// The pill is marked once the part holds an edit — a dot, since the pill
    /// has room for a name and no more. Not from birth: a part just taken out
    /// is the parent's own bytes, and there is nothing to put back yet.
    func testThePillIsMarkedOnceThePartIsEdited() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }
        let id = try XCTUnwrap(controller.openFragment([0x01, 0x02], named: "part",
                                                       animated: false))
        let pill = try XCTUnwrap(strip(of: controller).pillsForTesting.first)
        XCTAssertFalse(pill.hasChanges, "nothing has been changed in it yet")

        let pane = try XCTUnwrap(controller.fragments.pane(id))
        try pane.applyToolWrites([(offset: 0, bytes: [0xFF])], named: "Patch")
        XCTAssertTrue(pill.hasChanges,
                      "an edit the parent has not got back is worth a dot, without being asked")

        controller.fragments.close(id, animated: false)
        XCTAssertTrue(try strip(of: controller).pillsForTesting.isEmpty)
    }
}
