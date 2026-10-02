import ByteRipperCore
import XCTest
import ToolModuleKit
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

    /// A panel with room to spare opens its map into that room: the window keeps
    /// its width, and gives nothing back on hiding it.
    func testOpeningThePanelsMapDoesNotWidenAWindowThatHasRoom() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let id = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                       named: "part", animated: false))
        let surface = try XCTUnwrap(controller.fragments.surface(id))
        window.layoutIfNeeded()
        let paneView = controller.paneView(for: try XCTUnwrap(controller.fragments.pane(id)))
        XCTAssertGreaterThan(controller.dumpAreaSlack(of: surface), surface.minimapPreferredPanelWidth + 1,
                             "the window is set up with room")
        let before = window.frame.width

        surface.minimap.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(window.frame.width, before, accuracy: 0.5, "shown")
        XCTAssertGreaterThanOrEqual(surface.contentHost.frame.width, paneView.contentFitWidth,
                                    "and the dump still fits its grid")

        surface.minimap.setPanelVisible(false, animated: false)
        XCTAssertEqual(window.frame.width, before, accuracy: 0.5, "hidden")
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

        controller.surface.minimap.setPanelVisible(true, animated: false)
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
    func testThePanelsMapMarksTheSharedListAtThePartsOffsets() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let bytes = [UInt8](repeating: 0, count: 0x80)
        let origin = try XCTUnwrap(DocumentOrigin(parent: controller.windowModel.pane1,
                                                  source: 0x100..<0x180, partName: "part",
                                                  layout: .image, content: bytes))
        _ = controller.windowModel.bookmarkStore.add(rowContaining: 0x110)
        let id = try XCTUnwrap(controller.openFragment(bytes, named: "part", origin: origin,
                                                       animated: false))
        window.layoutIfNeeded()
        let surface = try XCTUnwrap(controller.fragments.surface(id))
        XCTAssertEqual(surface.minimapView.bookmarks.map(\.row), [0x10],
                       "the dump's mark, at the offset the part has it at")

        try XCTUnwrap(controller.fragments.pane(id)).bookmarks?.toggle(rowContaining: 0x20)

        XCTAssertEqual(surface.minimapView.bookmarks.map(\.row), [0x10, 0x20])
        XCTAssertEqual(controller.minimapView.bookmarks.map(\.row), [0x110, 0x120],
                       "and the tab's map has both, at the dump's offsets")
    }

    /// A decompressed body has no marks at all: the file's offsets do not reach
    /// its bytes, so its map carries nothing however the window's list grows.
    func testADecompressedPanelsMapCarriesNoMarks() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let bytes = [UInt8](repeating: 0, count: 0x80)
        let origin = try XCTUnwrap(DocumentOrigin(parent: controller.windowModel.pane1,
                                                  source: 0x100..<0x180, partName: "body",
                                                  layout: .image, kind: .decompressed,
                                                  content: bytes))
        _ = controller.windowModel.bookmarkStore.add(rowContaining: 0x110)
        let id = try XCTUnwrap(controller.openFragment(bytes, named: "body", origin: origin,
                                                       animated: false))
        window.layoutIfNeeded()
        let surface = try XCTUnwrap(controller.fragments.surface(id))

        XCTAssertTrue(surface.minimapView.bookmarks.isEmpty)
        XCTAssertNil(try XCTUnwrap(controller.fragments.pane(id)).bookmarks,
                     "and there is no list to add one to")
    }

    /// A search in the part re-marks the part's own map, not the dump's behind
    /// it (`Design/FRAGMENT_PANELS_PLAN.md`). The match overlay was the one feed
    /// a fragment's map missed: it still asked the tab's map to redraw, so a
    /// search in a panel left the panel's strokes stale.
    func testASearchInThePartReMarksThePartsOwnMap() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }

        let id = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0x41, count: 0x80),
                                                       named: "part", animated: false))
        let surface = try XCTUnwrap(controller.fragments.surface(id))
        let part = try XCTUnwrap(controller.fragments.pane(id))

        // Both maps in overview and on screen, so either could be the one a
        // search re-marks: the part's must be, the dump's must not be.
        controller.surface.minimap.setRenderMode(.overview)
        controller.surface.minimap.setPanelVisible(true, animated: false)
        surface.minimap.setRenderMode(.overview)
        surface.minimap.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        _ = pumpUntil(3.0) { (surface.minimapView.overviewSummaries.first?.rowCount ?? 0) > 0 }

        let partWalks = surface.minimap.matchOverlayWalksForTesting
        let tabWalks = controller.matchOverlayWalksForTesting

        let set = MatchSet(pattern: SearchPattern(bytes: [0xDE, 0xAD], encoding: .hex),
                           folding: .exact, extent: 0x80, starts: [0x10, 0x40])
        part.setMatches(set, current: 0)

        XCTAssertTrue(pumpUntil(3.0) { surface.minimap.matchOverlayWalksForTesting > partWalks },
                      "the part's map re-marks its matches")
        XCTAssertEqual(controller.matchOverlayWalksForTesting, tabWalks,
                       "and the dump behind it is left alone")
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
        surface.minimap.setPanelVisible(true, animated: false)
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
        surface.minimap.setPanelVisible(true, animated: false)
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

    // MARK: - The strip's and the gutter's menus

    /// A right-click on the panel's segment strip offers the piece's menu,
    /// and its items act on the part — not on the dump behind it, whose map
    /// the window's own commands address.
    func testThePanelsSegmentStripOffersItsMenuAndActsOnThePart() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let id = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                       named: "part", animated: false))
        window.layoutIfNeeded()
        let part = try XCTUnwrap(controller.fragments.pane(id))
        XCTAssertTrue(part.segmentStore.addCut(at: 0x40), "precondition: the part has two pieces")
        let surface = try XCTUnwrap(controller.fragments.surface(id))

        let menu = try XCTUnwrap(surface.minimapView.segmentStripMenu?(0, 1, .zero),
                                 "the panel's strip offers a menu")
        let select = try XCTUnwrap(menu.items.first { $0.title == "Select Segment S1" },
                                   "the menu names the part's own piece: \(menu.items.map(\.title))")
        NSApp.sendAction(try XCTUnwrap(select.action), to: select.target, from: select)

        let selection = part.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x40..<0x80, "the part's piece is selected")
        XCTAssertTrue(controller.windowModel.pane1.hexSelection().isEmpty,
                      "and nothing in the dump behind it")
    }

    /// The same for the zone gutter: a bracket on the panel's map offers the
    /// zone's menu, and Select selects the zone in the part.
    func testThePanelsZoneGutterOffersItsMenuAndActsOnThePart() throws {
        let (controller, window, url) = try makeController()
        defer { cleanup(controller, url) }
        let id = try XCTUnwrap(controller.openFragment([UInt8](repeating: 0, count: 0x80),
                                                       named: "part", animated: false))
        window.layoutIfNeeded()
        let part = try XCTUnwrap(controller.fragments.pane(id))
        part.setZones(ZoneMap(zones: [Zone(id: "hdr", name: "Header", range: 0x10..<0x20)]))
        let surface = try XCTUnwrap(controller.fragments.surface(id))
        surface.minimap.syncZones()

        let menu = try XCTUnwrap(surface.minimapView.zoneBracketMenu?(0, "hdr"),
                                 "the panel's gutter offers a menu")
        let select = try XCTUnwrap(menu.items.first { $0.title.hasPrefix("Select Zone") })
        NSApp.sendAction(try XCTUnwrap(select.action), to: select.target, from: select)

        let selection = part.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x10..<0x20, "the part's zone is selected")
        XCTAssertTrue(controller.windowModel.pane1.hexSelection().isEmpty,
                      "and nothing in the dump behind it")
    }
}
