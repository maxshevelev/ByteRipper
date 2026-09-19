import XCTest
import ToolModuleKit
@testable import ByteRipper

/// A tool-module opened on a fragment panel reads the part, and the commands
/// that open it mean the panel while one is up
/// (`Design/FRAGMENT_PANELS_PLAN.md`).
@MainActor
final class FragmentToolTests: XCTestCase {
    private var defaultsName: String?

    override func setUp() {
        super.setUp()
        installToolStubs()
        let isolated = isolatedDefaults(for: self)
        defaultsName = isolated.name
        ToolController.defaults = isolated.store
        ToolController.changeDelay = 0
    }

    override func tearDown() {
        if let defaultsName { discardIsolatedDefaults(defaultsName, ToolController.defaults) }
        ToolController.defaults = .standard
        ToolController.changeDelay = 0.15
        super.tearDown()
    }

    private func makeController() throws -> (MainViewController, NSWindow, URL) {
        let controller = MainViewController()
        let window = makeTestWindow(width: 900, height: 600)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        let url = try tempFile([UInt8](repeating: 0xAA, count: 0x100))
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        return (controller, window, url)
    }

    private func cleanup(_ controller: MainViewController, _ url: URL) {
        for id in controller.fragments.dock.panels {
            controller.fragments.close(id, animated: false)
        }
        controller.windowModel.pane1.close()
        try? FileManager.default.removeItem(at: url)
    }

    private func activateToolFromTheMenu(_ controller: MainViewController) {
        let item = NSMenuItem()
        item.representedObject = StubToolA.identifier
        controller.activateTool(item)
    }

    /// Tools ▸ ⟨module⟩ with a panel up opens the tool on the panel, not on the
    /// dump behind it — a tool panel opened behind a panel that covers the
    /// whole content area is a panel nobody can see.
    func testTheToolsMenuOpensTheToolOnThePanelInFront() throws {
        let (controller, _, url) = try makeController()
        defer { cleanup(controller, url) }
        let id = try XCTUnwrap(controller.openFragment([UInt8](0..<32), named: "part",
                                                       animated: false))
        let part = try XCTUnwrap(controller.fragments.pane(id))

        activateToolFromTheMenu(controller)

        let surface = try XCTUnwrap(controller.fragments.surface(id))
        XCTAssertEqual(surface.tools.activeIdentifier, StubToolA.identifier)
        XCTAssertTrue(surface.tools.boundPane === part, "and it reads the part")
        XCTAssertNil(controller.tools.activeIdentifier, "the tab's own panel is untouched")
    }

    /// Folded again, the same command means the tab's own tool panel — and the
    /// panel's choice is still the panel's when it comes back up.
    func testFoldingThePanelGivesTheCommandBackToTheTab() throws {
        let (controller, _, url) = try makeController()
        defer { cleanup(controller, url) }
        let id = try XCTUnwrap(controller.openFragment([UInt8](0..<32), named: "part",
                                                       animated: false))
        activateToolFromTheMenu(controller)
        controller.fragments.collapse(animated: false)

        activateToolFromTheMenu(controller)

        XCTAssertEqual(controller.tools.activeIdentifier, StubToolA.identifier,
                       "with nothing in front, the tab's own")
        XCTAssertEqual(controller.fragments.surface(id)?.tools.activeIdentifier,
                       StubToolA.identifier, "and the panel kept its own")
    }

    /// An edit in the part reaches the tool reading it. Nothing told it before:
    /// the panel's pane had none of the wiring the tab's panes get.
    func testAnEditInThePartReachesTheToolReadingIt() throws {
        let (controller, _, url) = try makeController()
        defer { cleanup(controller, url) }
        let id = try XCTUnwrap(controller.openFragment([UInt8](0..<32), named: "part",
                                                       animated: false))
        activateToolFromTheMenu(controller)
        let before = StubToolA.log.changes.count

        try XCTUnwrap(controller.fragments.pane(id))
            .applyToolWrites([(offset: 0, bytes: [0xFF])], named: "Patch")

        XCTAssertTrue(pumpUntil(1) { StubToolA.log.changes.count > before },
                      "the tool hears that the part changed under it")
    }

    /// A zone-map a tool-module publishes for the part reaches the part's own
    /// map at once. It used to reach the tab's instead, so the panel's gutter
    /// stayed as it was until the map was hidden and shown again.
    func testZonesPublishedForThePartReachThePartsOwnMap() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let id = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x200),
                                                       named: "part", animated: false))
        let surface = try XCTUnwrap(controller.fragments.surface(id))
        surface.minimap.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        activateToolFromTheMenu(controller)
        let host = try XCTUnwrap(StubToolA.log.session?.host as? PaneToolHost)

        host.publish(ZoneMap(zones: [Zone(id: "fv", name: "FFSv2", range: 0x40..<0x80)]))

        XCTAssertEqual(surface.minimapView.zoneBrackets.first?.count, 1,
                       "the part's gutter drew the zone without being hidden and shown")
        XCTAssertTrue(controller.minimapView.zoneBrackets.allSatisfy(\.isEmpty),
                      "and the dump's gutter is not where a part's zones go")
    }

    /// Closing a panel that another panel came out of kills the link rather
    /// than leaving it looking alive. It looked alive: the header went on
    /// naming the closed panel and Update in Parent stayed available, and what
    /// it would have written to is a document nobody could see.
    func testClosingAParentPanelKillsTheChildsLink() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let outer = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                          named: "part", animated: false))
        activateToolFromTheMenu(controller)
        let host = try XCTUnwrap(StubToolA.log.session?.host as? PaneToolHost)
        host.openPart([0x01, 0x02, 0x03], named: "inner.bin", linkedTo: 0x10..<0x20)
        let inner = try XCTUnwrap(controller.fragments.expanded)
        let deeper = try XCTUnwrap(controller.fragments.pane(inner))
        window.layoutIfNeeded()
        XCTAssertEqual(deeper.origin?.state, .intact, "the premise: the link is good")

        controller.fragments.close(outer, animated: false)

        XCTAssertEqual(deeper.origin?.state, .parentClosed,
                       "the panel it came out of is gone, and the link knows")
        let item = NSMenuItem(title: "", action: #selector(MainViewController.updateInParent),
                              keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(item),
                       "so Update in Parent is not on offer")
        XCTAssertEqual(try XCTUnwrap(deeper.origin).explanation.contains("no longer open"), true,
                       "and the header says why")
    }

    /// A closed panel is let go of — its pane, its surface and its view.
    ///
    /// Under an autorelease pool, and that is the point of the test as much as
    /// the release is: AppKit hands objects back through one, so a weak
    /// reference read before the pool drains says "still here" about something
    /// already on its way out. Read without the pool, this looked like a leak
    /// and was not one.
    func testAClosedPanelIsReleased() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        weak var pane: PaneViewModel?
        weak var surface: DocumentSurface?
        weak var panel: FragmentPanelView?

        try autoreleasepool {
            let id = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                           named: "part", animated: false))
            let held = try XCTUnwrap(controller.fragments.surface(id))
            held.minimap.setPanelVisible(true, animated: false)
            held.tools.activate(StubToolA.identifier, animated: false)
            window.layoutIfNeeded()
            pane = controller.fragments.pane(id)
            surface = held
            panel = controller.fragments.panelView(id)
            XCTAssertNotNil(pane)
            controller.fragments.close(id, animated: false)
        }

        // And after a turn of the run loop: some of the letting go is posted
        // rather than done on the spot.
        _ = pumpUntil(1) { pane == nil }
        XCTAssertNil(pane, "the pane of a closed panel")
        XCTAssertNil(surface, "and its surface")
        XCTAssertNil(panel, "and the panel itself")
    }

    /// Closing a panel that others came out of asks first — a link that dies
    /// without a word is one the reader meets later, when Update in Parent
    /// refuses.
    func testClosingAPanelOthersCameOutOfAsksFirst() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let outer = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                          named: "part", animated: false))
        activateToolFromTheMenu(controller)
        let host = try XCTUnwrap(StubToolA.log.session?.host as? PaneToolHost)
        host.openPart([0x01, 0x02, 0x03], named: "inner.bin", linkedTo: 0x10..<0x20)
        window.layoutIfNeeded()
        XCTAssertEqual(controller.fragments.count, 2)

        var asked: [String] = []
        var buttons: [String] = []
        controller.fragmentCloseConfirm = { alert in
            asked.append(alert.messageText + " " + alert.informativeText)
            buttons = alert.buttons.map(\.title)
            return .alertSecondButtonReturn  // Cancel
        }
        controller.closeFragment(outer)

        XCTAssertEqual(buttons, ["Close and Break Link", "Cancel"],
                       "the button says what closing does, not just that it closes")
        XCTAssertEqual(asked.count, 1, "asked once, and cancelled there")
        XCTAssertEqual(asked.first?.contains("One panel was opened out of it"), true,
                       asked.first ?? "not asked")
        XCTAssertEqual(controller.fragments.count, 2, "cancelled, so nothing closed")

        controller.fragmentCloseConfirm = { _ in .alertFirstButtonReturn }  // Close
        controller.closeFragment(outer)
        XCTAssertEqual(controller.fragments.count, 1, "and closing goes through when told to")
    }

    /// An unsaved panel that others came out of asks both questions, one after
    /// the other — the links first, then its own bytes. Folded into one dialog
    /// the second half went unread, which is the same as not asking.
    func testBothQuestionsAreAskedInTurn() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let outer = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                          named: "part", animated: false))
        let part = try XCTUnwrap(controller.fragments.pane(outer))
        activateToolFromTheMenu(controller)
        let host = try XCTUnwrap(StubToolA.log.session?.host as? PaneToolHost)
        host.openPart([0x01, 0x02, 0x03], named: "inner.bin", linkedTo: 0x10..<0x13)
        window.layoutIfNeeded()
        // The panel now has a part hanging off it and bytes of its own that
        // have never been anywhere. It has no parent itself, so what it is
        // asked about its own bytes is the ordinary save question.
        try part.applyToolWrites([(offset: 0, bytes: [0xFF])], named: "Patch")

        var titles: [String] = []
        controller.fragmentCloseConfirm = { alert in
            titles.append(alert.messageText)
            return .alertFirstButtonReturn
        }
        MainViewController.modalResponder = { alert in
            titles.append(alert.messageText)
            return .alertSecondButtonReturn  // Don't Save, where that is asked
        }
        defer { MainViewController.modalResponder = nil }

        controller.closeFragment(outer)

        XCTAssertEqual(titles.count, 2, "two questions, not one: \(titles)")
        XCTAssertEqual(titles.first?.hasPrefix("Close "), true,
                       "the links first — what closing does to other panels")
        XCTAssertEqual(titles.last?.hasPrefix("Save changes"), true,
                       "then this panel's own bytes: \(titles)")
    }

    /// Closing the *dump* parts were taken out of asks the same question. The
    /// link dies exactly as it does when a panel closes — it just dies from
    /// the other end, and that end used to close in silence.
    func testClosingTheDumpPartsCameOutOfAsksFirst() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        activateToolFromTheMenu(controller)
        let host = try XCTUnwrap(StubToolA.log.session?.host as? PaneToolHost)
        host.openPart([0x01, 0x02, 0x03], named: "part.bin", linkedTo: 0x10..<0x13)
        window.layoutIfNeeded()
        XCTAssertEqual(controller.fragments.count, 1)
        XCTAssertTrue(controller.fragments.pane(controller.fragments.dock.panels[0])?
            .origin?.parent === controller.windowModel.pane1, "opened out of the dump")

        var asked: [String] = []
        controller.fragmentCloseConfirm = { alert in
            asked.append(alert.messageText + " " + alert.informativeText)
            return .alertSecondButtonReturn  // Cancel
        }
        controller.closePane(at: 0)

        XCTAssertEqual(asked.count, 1, "asked once, and cancelled there")
        XCTAssertEqual(asked.first?.contains("One panel was opened out of it"), true,
                       asked.first ?? "not asked")
        XCTAssertTrue(controller.windowModel.pane1.isOpen, "cancelled, so the dump stays")

        controller.fragmentCloseConfirm = { _ in .alertFirstButtonReturn }  // Close
        controller.closePane(at: 0)
        XCTAssertFalse(controller.windowModel.pane1.isOpen,
                       "and closing goes through when told to")
        XCTAssertEqual(controller.fragments.pane(controller.fragments.dock.panels[0])?
            .origin?.state, .parentClosed, "the part stays, with its way back gone")
    }

    /// A dump nothing came out of closes without a question.
    func testClosingADumpNothingCameOutOfAsksNothing() throws {
        let (controller, _, url) = try makeController()
        defer { cleanup(controller, url) }
        _ = controller.openFragment([UInt8](repeating: 0, count: 0x80), named: "part",
                                    animated: false)
        controller.fragments.collapse(animated: false)
        var asked = false
        controller.fragmentCloseConfirm = { _ in asked = true; return .alertSecondButtonReturn }

        controller.closePane(at: 0)

        XCTAssertFalse(asked, "a panel opened out of nothing leads nowhere")
        XCTAssertFalse(controller.windowModel.pane1.isOpen)
    }

    /// A panel nothing came out of closes without a question.
    func testClosingAPanelNothingCameOutOfAsksNothing() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let id = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                       named: "part", animated: false))
        window.layoutIfNeeded()
        var asked = false
        controller.fragmentCloseConfirm = { _ in asked = true; return .alertSecondButtonReturn }

        controller.closeFragment(id)

        XCTAssertFalse(asked, "nothing leads here, so there is nothing to warn about")
        XCTAssertTrue(controller.fragments.isEmpty)
    }

    // MARK: - Closing the window

    /// Closing the window asks about a part holding an edit nobody has back.
    /// The panels are documents too; they were taken without a word.
    func testClosingTheWindowAsksAboutAPartHoldingAnEdit() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let id = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                       named: "part", animated: false))
        try XCTUnwrap(controller.fragments.pane(id))
            .applyToolWrites([(offset: 0, bytes: [0xFF])], named: "Patch")

        var titles: [String] = []
        MainViewController.modalResponder = { alert in
            titles.append(alert.messageText)
            return .alertThirdButtonReturn  // Cancel
        }
        defer { MainViewController.modalResponder = nil }

        XCTAssertFalse(controller.windowShouldClose(window), "cancelled, so the window stays")
        XCTAssertEqual(titles, ["Save changes before closing?"])
        XCTAssertEqual(controller.fragments.count, 1, "and the part stays with it")
    }

    /// Answered, the panel goes and the window closes — and the question about
    /// the files behind it is still asked, after.
    func testTheWindowClosesOncePartsAreAnsweredFor() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let id = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                       named: "part", animated: false))
        try XCTUnwrap(controller.fragments.pane(id))
            .applyToolWrites([(offset: 0, bytes: [0xFF])], named: "Patch")
        try controller.windowModel.pane1.applyToolWrites([(offset: 0, bytes: [0x01])],
                                                         named: "Patch")

        var titles: [String] = []
        MainViewController.modalResponder = { alert in
            titles.append(alert.messageText)
            return .alertSecondButtonReturn  // Don't Save
        }
        defer { MainViewController.modalResponder = nil }

        XCTAssertTrue(controller.windowShouldClose(window))
        XCTAssertEqual(titles.count, 2, "the part, then the files: \(titles)")
        XCTAssertTrue(controller.fragments.isEmpty, "the part was answered for and went")
    }

    /// A panel with nothing to lose is not asked about — and not closed
    /// either, in case the question about the files is the one cancelled.
    func testAPartWithNothingToLoseIsLeftAlone() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        _ = controller.openFragment([UInt8](repeating: 0, count: 0x80), named: "part",
                                    animated: false)
        try controller.windowModel.pane1.applyToolWrites([(offset: 0, bytes: [0x01])],
                                                         named: "Patch")

        var titles: [String] = []
        MainViewController.modalResponder = { alert in
            titles.append(alert.messageText)
            return .alertThirdButtonReturn  // Cancel the files question
        }
        defer { MainViewController.modalResponder = nil }

        XCTAssertFalse(controller.windowShouldClose(window))
        XCTAssertEqual(titles, ["Save changes before closing?"], "asked only about the file")
        XCTAssertEqual(controller.fragments.count, 1, "the panel is still there")
    }

    /// Closing the window does not ask what closing one panel asks: nothing is
    /// stranded when the whole window goes at once.
    func testClosingTheWindowDoesNotAskAboutLinks() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let outer = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                          named: "part", animated: false))
        activateToolFromTheMenu(controller)
        let host = try XCTUnwrap(StubToolA.log.session?.host as? PaneToolHost)
        host.openPart([0x01, 0x02, 0x03], named: "inner.bin", linkedTo: 0x10..<0x13)
        window.layoutIfNeeded()
        try XCTUnwrap(controller.fragments.pane(outer))
            .applyToolWrites([(offset: 0, bytes: [0xFF])], named: "Patch")

        var asked = false
        controller.fragmentCloseConfirm = { _ in asked = true; return .alertSecondButtonReturn }
        MainViewController.modalResponder = { _ in .alertSecondButtonReturn }  // Don't Save
        defer { MainViewController.modalResponder = nil }

        XCTAssertTrue(controller.windowShouldClose(window))
        XCTAssertFalse(asked, "the panel the link led to is going the same way")
    }

    /// What quitting counts before it starts asking: the modified files and
    /// the parts holding something, and nothing else. A panel with nothing to
    /// lose is not a document anybody has to answer for.
    func testTheTabCountsWhatItWouldAskAbout() throws {
        let (controller, _, url) = try makeController()
        defer { cleanup(controller, url) }
        XCTAssertEqual(controller.unsavedDocumentCount, 0, "a clean tab asks nothing")

        try controller.windowModel.pane1.applyToolWrites([(offset: 0, bytes: [0x01])],
                                                         named: "Patch")
        XCTAssertEqual(controller.unsavedDocumentCount, 1, "the file")

        _ = controller.openFragment([UInt8](repeating: 0, count: 0x80), named: "clean",
                                    animated: false)
        XCTAssertEqual(controller.unsavedDocumentCount, 1, "a part nobody edited is not one")

        let edited = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                           named: "edited", animated: false))
        try XCTUnwrap(controller.fragments.pane(edited))
            .applyToolWrites([(offset: 0, bytes: [0xFF])], named: "Patch")
        XCTAssertEqual(controller.unsavedDocumentCount, 2, "the file and the edited part")
    }

    // MARK: - The wall

    /// Nothing the mouse does over a raised panel may reach the tab behind it —
    /// not its panes, not its minimap, not its tool panel — at any point of the
    /// area the panel covers. Swept rather than sampled, because the whole
    /// trouble with this is that a strip of the tab shows above the panel on
    /// purpose and the panes look reachable.
    func testNoPointBehindARaisedPanelReachesTheTab() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        controller.surface.minimap.setPanelVisible(true, animated: false)
        controller.tools.activate(StubToolA.identifier, animated: false)
        window.layoutIfNeeded()
        _ = controller.openFragment([UInt8](repeating: 0, count: 0x200), named: "part",
                                    animated: false)
        window.layoutIfNeeded()

        let host = try XCTUnwrap(descendants(of: controller.view, FragmentPanelHost.self).first)
        let content = try XCTUnwrap(window.contentView)
        let tab = controller.surface.view
        let area = host.convert(host.bounds, to: nil)
        var leaks: [String] = []
        for x in stride(from: area.minX + 1, to: area.maxX - 1, by: 20) {
            for y in stride(from: area.minY + 1, to: area.maxY - 1, by: 10) {
                guard let hit = content.hitTest(NSPoint(x: x, y: y)) else { continue }
                if hit.isDescendant(of: tab) {
                    leaks.append("(\(Int(x)),\(Int(y))) \(type(of: hit))")
                }
            }
        }
        XCTAssertEqual(leaks, [], "these points reach the tab through the panel")
    }

    /// And an event the panel's own views do not want stops at the wall rather
    /// than climbing the responder chain to something behind that still wants
    /// it. A right-click is the one that showed: the tool panel in front had no
    /// menu of its own, so the click went looking for one.
    func testTheWallAnswersNothingAndOffersNoMenu() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let host = try XCTUnwrap(descendants(of: controller.view, FragmentPanelHost.self).first)
        XCTAssertFalse(host.acceptsFirstMouse(for: nil), "with no panel it is not in the way")

        _ = controller.openFragment([UInt8](repeating: 0, count: 0x200), named: "part",
                                    animated: false)
        window.layoutIfNeeded()

        XCTAssertTrue(host.acceptsFirstMouse(for: nil),
                      "a click that merely brings the window forward is not a click on a pane")
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertNil(host.menu(for: click), "no menu of its own, and none from what it covers")
        // The overrides are what stop the climb; calling them must simply do
        // nothing rather than pass anything on.
        host.rightMouseDown(with: click)
        host.mouseDown(with: click)
        host.scrollWheel(with: click)
    }

    /// A drag does not travel the responder chain: the window looks for a view
    /// registered for what is being dragged, so a wall that is not registered
    /// is no wall at all and a file dropped on a panel landed in the drop zones
    /// of the panes underneath.
    func testTheWallRefusesADraggedFileWhileAPanelIsUp() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let host = try XCTUnwrap(descendants(of: controller.view, FragmentPanelHost.self).first)
        XCTAssertEqual(host.registeredDraggedTypes, [],
                       "with no panel it must not be a destination: refusing is all it can do, "
                           + "and a window that always refuses never takes a file again")

        let id = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x200),
                                                       named: "part", animated: false))
        window.layoutIfNeeded()

        XCTAssertTrue(host.registeredDraggedTypes.contains(.fileURL), "a file")
        XCTAssertTrue(host.registeredDraggedTypes.contains(.pane), "and a pane")
        let drag = FakeDraggingInfo(fileURLs: [url])
        XCTAssertEqual(host.draggingEntered(drag), [], "nothing is on offer")
        XCTAssertEqual(host.draggingUpdated(drag), [])
        XCTAssertFalse(host.prepareForDragOperation(drag))
        XCTAssertFalse(host.performDragOperation(drag))

        controller.fragments.close(id, animated: false)
        XCTAssertEqual(host.registeredDraggedTypes, [],
                       "and the last panel leaving gives the drags back to the tab")
    }

    /// The panel's own tool panel takes no drops either. It is in front of the
    /// wall, not behind it, and what it would have done is replace the file in
    /// a pane of the tab — the pane the panel is covering.
    func testThePanelsToolPanelTakesNoDrops() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let id = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x200),
                                                       named: "part", animated: false))
        activateToolFromTheMenu(controller)
        window.layoutIfNeeded()
        let panel = try XCTUnwrap(controller.fragments.surface(id)).tools.panel

        let drag = FakeDraggingInfo(fileURLs: [url])
        XCTAssertEqual(panel.draggingEntered(drag), [], "refused")
        XCTAssertEqual(panel.draggingUpdated(drag), [])
        XCTAssertFalse(panel.performDragOperation(drag))
        XCTAssertEqual(controller.windowModel.pane1.document?.url, url,
                       "and the tab's own file is untouched")
        XCTAssertTrue(controller.tools.panel.takesDrops,
                      "while the tab's own panel goes on taking them")
    }

    /// A part taken out of a panel belongs to **that panel**, not to the dump
    /// behind it: the dock stays flat, and the links form the chain
    /// (`Design/FRAGMENT_PANELS_PLAN.md`).
    func testAPartOpenedFromAPanelHasThatPanelAsItsParent() throws {
        let (controller, _, url) = try makeController()
        defer { cleanup(controller, url) }
        let outer = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                          named: "part", animated: false))
        let part = try XCTUnwrap(controller.fragments.pane(outer))
        activateToolFromTheMenu(controller)
        let host = try XCTUnwrap(StubToolA.log.session?.host as? PaneToolHost)

        host.openPart([0x01, 0x02, 0x03], named: "inner.bin", linkedTo: 0x10..<0x13)

        XCTAssertEqual(controller.fragments.count, 2, "two panels, side by side in the dock")
        let inner = try XCTUnwrap(controller.fragments.expanded)
        let deeper = try XCTUnwrap(controller.fragments.pane(inner))
        let origin = try XCTUnwrap(deeper.origin)
        XCTAssertTrue(origin.parent === part, "its parent is the panel it came out of")
        XCTAssertFalse(origin.parent === controller.windowModel.pane1)
        XCTAssertEqual(origin.sourceRange, 0x10..<0x13,
                       "and the range is in that panel's own offsets, not the dump's")

        // And putting it back raises the panel it goes into rather than the
        // dump: what the reader wants to see is where the bytes landed.
        try deeper.applyToolWrites([(offset: 0, bytes: [0xFF])], named: "Patch")
        controller.performUpdateInParent(of: deeper)
        XCTAssertEqual(controller.fragments.expanded, outer,
                       "the parent panel comes to the front")
    }

    /// The panel's tool panel opens inside the panel: it takes width from that
    /// surface's split and leaves the window's own alone.
    func testThePanelsToolPanelDoesNotMoveTheWindow() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        _ = controller.openFragment([UInt8](0..<32), named: "part", animated: false)
        window.layoutIfNeeded()
        let frame = window.frame

        activateToolFromTheMenu(controller)
        window.layoutIfNeeded()

        XCTAssertEqual(window.frame, frame,
                       "a tool opened inside a panel is not the window's business")
        XCTAssertEqual(controller.toolPanelWidth(), 0, "and the tab's own panel stays shut")
    }
}
