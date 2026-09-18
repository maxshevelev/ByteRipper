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

        host.openPart([0x01, 0x02, 0x03], named: "inner.bin", linkedTo: 0x10..<0x20)

        XCTAssertEqual(controller.fragments.count, 2, "two panels, side by side in the dock")
        let inner = try XCTUnwrap(controller.fragments.expanded)
        let deeper = try XCTUnwrap(controller.fragments.pane(inner))
        let origin = try XCTUnwrap(deeper.origin)
        XCTAssertTrue(origin.parent === part, "its parent is the panel it came out of")
        XCTAssertFalse(origin.parent === controller.windowModel.pane1)
        XCTAssertEqual(origin.sourceRange, 0x10..<0x20,
                       "and the range is in that panel's own offsets, not the dump's")
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
