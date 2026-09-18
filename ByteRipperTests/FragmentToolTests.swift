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
