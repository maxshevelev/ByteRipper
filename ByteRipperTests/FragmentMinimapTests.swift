import XCTest
import UEFIImage
@testable import ByteRipper

/// A fragment panel carries a minimap of its own, over the part it holds
/// (`Design/FRAGMENT_PANELS_PLAN.md`). The panel covers the tab's own map, so
/// the one on screen is always the panel's, and the commands mean it.
@MainActor
final class FragmentMinimapTests: XCTestCase {
    private var defaultsName: String?

    override func setUp() {
        super.setUp()
        let isolated = isolatedDefaults(for: self)
        defaultsName = isolated.name
        DocumentSurface.minimapDefaults = isolated.store
    }

    override func tearDown() {
        if let defaultsName { discardIsolatedDefaults(defaultsName, DocumentSurface.minimapDefaults) }
        DocumentSurface.minimapDefaults = .standard
        super.tearDown()
    }

    private func makeController() throws -> (MainViewController, NSWindow, URL) {
        let controller = MainViewController()
        let window = makeTestWindow(width: 900, height: 600)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
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

    /// The panel's map maps the part, not the dump it came out of.
    func testThePanelsMapShowsThePart() throws {
        let (controller, _, url) = try makeController()
        defer { cleanup(controller, url) }

        let id = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                       named: "part", animated: false))

        let surface = try XCTUnwrap(controller.fragments.surface(id))
        XCTAssertEqual(surface.minimapView.maps.map(\.fileSize), [0x80],
                       "one map, the size of the part")
        XCTAssertEqual(controller.minimapView.maps.map(\.fileSize), [0x400],
                       "and the tab's own map still maps the dump")
    }

    /// It opens with the map the tab has: on if the tab's is on, off if not.
    func testThePanelOpensWithTheMapTheTabHas() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }

        let closed = try XCTUnwrap(controller.openFragment([0x01], named: "shut", animated: false))
        XCTAssertFalse(try XCTUnwrap(controller.fragments.surface(closed)).minimapPanelVisible)

        controller.setMinimapPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        let open = try XCTUnwrap(controller.openFragment([0x01], named: "open", animated: false))

        XCTAssertTrue(try XCTUnwrap(controller.fragments.surface(open)).minimapPanelVisible,
                      "someone working with the map on wants it on the part too")
    }

    /// The toggle means the panel while one is up, and the tab again once it is
    /// folded — the panel covers the tab's map, so it is the only one to mean.
    func testTheToggleMeansThePanelWhileItIsUp() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let id = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                       named: "part", animated: false))
        window.layoutIfNeeded()
        let surface = try XCTUnwrap(controller.fragments.surface(id))

        controller.toggleMinimap()

        XCTAssertTrue(surface.minimapPanelVisible, "the panel's map opened")
        XCTAssertFalse(controller.minimapPanelVisible, "the tab's did not")

        controller.fragments.collapse(animated: false)
        controller.toggleMinimap()
        XCTAssertTrue(controller.minimapPanelVisible, "with nothing in front, the tab's own")
        XCTAssertTrue(surface.minimapPanelVisible, "and the panel kept its own")
    }

    /// The panel's map marks the panel's own list. A part's offsets are its
    /// own, so the dump's marks would be marks in the wrong file.
    func testThePanelsMapMarksThePanelsOwnList() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        _ = controller.windowModel.bookmarkStore.add(rowContaining: 0x100)
        let id = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                       named: "part", animated: false))
        window.layoutIfNeeded()
        let surface = try XCTUnwrap(controller.fragments.surface(id))
        XCTAssertTrue(surface.minimapView.bookmarks.isEmpty,
                      "the dump's marks are not the part's")

        try XCTUnwrap(controller.fragments.pane(id)).bookmarkStore?.toggle(rowContaining: 0x10)

        XCTAssertEqual(surface.minimapView.bookmarks.count, 1, "its own list reaches its own map")
        XCTAssertEqual(controller.minimapView.bookmarks.count, 1, "and the tab's map is untouched")
    }

    /// The band that says where in the part you are follows the part's own
    /// scroll. It was drawn from the tab's panes before, so a panel's map had
    /// no band at all.
    func testTheViewportBandFollowsThePartsOwnScroll() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let id = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x400),
                                                       named: "part", animated: false))
        let surface = try XCTUnwrap(controller.fragments.surface(id))
        controller.setMinimapPanelVisible(of: surface, true, animated: false)
        window.layoutIfNeeded()
        let paneView = controller.paneView(for: try XCTUnwrap(controller.fragments.pane(id)))

        paneView.onHexViewportChanged?(0x80..<0x100)

        XCTAssertEqual(surface.minimapView.viewports, [0x80..<0x100],
                       "the part's own map got the band")
        XCTAssertFalse(controller.minimapView.viewports.contains(0x80..<0x100),
                       "and the dump's map kept its own band, not the part's")
    }

    /// A drag over the panel's map scrolls the part, not the dump behind it.
    func testADragOverThePanelsMapScrollsThePart() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let id = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x4000),
                                                       named: "part", animated: false))
        let surface = try XCTUnwrap(controller.fragments.surface(id))
        controller.setMinimapPanelVisible(of: surface, true, animated: false)
        window.layoutIfNeeded()
        let paneView = controller.paneView(for: try XCTUnwrap(controller.fragments.pane(id)))
        var scrolledTo: Range<UInt64>?
        paneView.onHexViewportChanged = { scrolledTo = $0 }

        surface.minimapView.onScrollToOffset?(0x2000)

        XCTAssertEqual(scrolledTo?.lowerBound, 0x2000,
                       "the map scrolled the pane it maps")
    }

    /// The panel's map pulls its bytes from the part: the feed is wired to that
    /// surface's pane, so an edit in the part reads as modified on its own map
    /// and nowhere else.
    ///
    /// Taken out of the dump rather than made up, because a part reads as
    /// modified against the bytes it was opened with — one from nowhere has
    /// nothing to be modified against.
    func testThePanelsMapReadsThePartsOwnBytes() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let bytes = [UInt8](repeating: 0xAA, count: 0x80)
        let origin = try XCTUnwrap(DocumentOrigin(parent: controller.windowModel.pane1,
                                                  source: 0x100..<0x180, partName: "part",
                                                  layout: .image, content: bytes))
        let id = try XCTUnwrap(controller.openFragment(bytes, named: "part", origin: origin,
                                                       animated: false))
        window.layoutIfNeeded()
        let surface = try XCTUnwrap(controller.fragments.surface(id))
        let feed = try XCTUnwrap(surface.minimapView.byteStates, "the panel's map has a feed")
        XCTAssertEqual(feed(0, 0x10..<0x11).map(\.isModified), [false])

        try XCTUnwrap(controller.fragments.pane(id))
            .applyToolWrites([(offset: 0x10, bytes: [0xFF])], named: "Patch")

        XCTAssertEqual(feed(0, 0x10..<0x11).map(\.isModified), [true],
                       "the part's own map sees the part's own edit")
        let tabFeed = try XCTUnwrap(controller.minimapView.byteStates)
        XCTAssertEqual(tabFeed(0, 0x10..<0x11).map(\.isModified), [false],
                       "and the dump behind it is untouched")
    }
}
