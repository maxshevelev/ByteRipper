import XCTest
@testable import ByteRipper

/// Where the Find bar stands: over the content it searches — the panes and
/// the minimap — never over the tool panel; and on a fragment panel, over the
/// panel's own dump rather than the tab's behind it.
@MainActor
final class FindBarPlacementTests: XCTestCase {
    private var defaultsName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        installToolStubs()
        (defaultsName, defaults) = isolatedDefaults(for: self)
        FindHistoryStore.defaults = defaults
        FindBarView.defaults = defaults
        ToolController.defaults = defaults
        DocumentSurface.minimapDefaults = defaults
    }

    override func tearDown() {
        FindHistoryStore.defaults = .standard
        FindBarView.defaults = .standard
        ToolController.defaults = .standard
        DocumentSurface.minimapDefaults = .standard
        discardIsolatedDefaults(defaultsName, defaults)
        defaults = nil
        super.tearDown()
    }

    private func makeController() throws -> (MainViewController, NSWindow, URL) {
        let controller = MainViewController()
        let window = makeTestWindow(width: 1400, height: 700)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1400, height: 700))
        let url = try tempFile([UInt8](repeating: 0xAA, count: 0x400))
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

    private func inWindow(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

    private func shownBar(_ window: NSWindow) throws -> FindBarView {
        try XCTUnwrap(descendants(of: window.contentView!, FindBarView.self).first { !$0.isHidden },
                      "the find bar is up")
    }

    /// With the tool panel and the minimap both open, the bar spans the panes
    /// and the minimap, starts where the tool panel ends, and stands above
    /// both; the tool panel keeps its whole height.
    func testTheBarStandsOverThePanesAndTheMinimapNotTheToolPanel() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        controller.tools.activate(StubToolA.identifier, animated: false)
        controller.surface.minimap.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()

        controller.findPattern()
        window.layoutIfNeeded()

        let bar = inWindow(try shownBar(window))
        let tool = inWindow(controller.tools.panel)
        let panes = inWindow(controller.paneHost)
        let minimap = inWindow(controller.minimapPanel)
        XCTAssertGreaterThan(bar.height, 0)
        XCTAssertGreaterThan(tool.width, 0, "the premise: the tool panel is open")
        XCTAssertGreaterThan(minimap.width, 0, "the premise: the minimap is open")

        XCTAssertGreaterThanOrEqual(bar.minX, tool.maxX - 0.5, "the bar does not reach over the tool panel")
        XCTAssertEqual(bar.minX, panes.minX, accuracy: 0.5, "it starts where the panes start")
        XCTAssertEqual(bar.maxX, minimap.maxX, accuracy: 0.5, "and ends where the minimap ends")
        XCTAssertGreaterThanOrEqual(panes.maxY, 0)
        XCTAssertEqual(bar.minY, panes.maxY, accuracy: 0.5, "the panes start under it")
        XCTAssertEqual(bar.minY, minimap.maxY, accuracy: 0.5, "and so does the minimap")
        XCTAssertEqual(tool.maxY, bar.maxY, accuracy: 0.5, "the tool panel keeps its full height")
    }

    /// Closing the bar gives the height back to the panes and the minimap.
    func testClosingTheBarGivesTheHeightBack() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let before = inWindow(controller.paneHost)

        controller.findPattern()
        window.layoutIfNeeded()
        XCTAssertLessThan(inWindow(controller.paneHost).height, before.height, "the bar took its height")

        controller.toggleFindBar()
        window.layoutIfNeeded()
        XCTAssertEqual(inWindow(controller.paneHost), before, "and gave it back")
    }

    /// On a fragment panel the bar is the panel's: inside the panel, over its
    /// dump. Folding the panel takes the bar back over the tab's panes.
    func testOnAFragmentPanelTheBarStandsOverThePanelsDump() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let id = try XCTUnwrap(controller.openFragment([UInt8](0..<64), named: "part", animated: false))
        let panel = try XCTUnwrap(controller.fragments.surface(id))
        window.layoutIfNeeded()

        controller.findPattern()
        window.layoutIfNeeded()

        let bar = try shownBar(window)
        XCTAssertTrue(controller.findBarSurfaceForTests === panel, "the panel in front holds the bar")
        XCTAssertTrue(bar.isDescendant(of: panel.contentHost), "inside the panel's content")
        let panes = inWindow(panel.paneHost)
        XCTAssertEqual(inWindow(bar).minY, panes.maxY, accuracy: 0.5, "over the panel's dump")
        XCTAssertEqual(inWindow(bar).minX, panes.minX, accuracy: 0.5)

        controller.fragments.collapse(animated: false)
        window.layoutIfNeeded()

        let back = try shownBar(window)
        XCTAssertTrue(back.isDescendant(of: controller.contentHost),
                      "folded, the bar stands over the tab's panes again")
        XCTAssertTrue(controller.findBarSurfaceForTests === controller.surface)
        XCTAssertEqual(inWindow(back).minY, inWindow(controller.paneHost).maxY, accuracy: 0.5)
    }
}
