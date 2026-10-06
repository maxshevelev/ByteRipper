import ALSplitView
import XCTest
@testable import ByteRipper

/// Tests for window zoom-to-fit (§3.1): double-clicking the title bar / Window
/// > Zoom sizes the window to the loaded files' real content — the width to
/// the hex grid(s) plus the taller pane's content height (header/status chrome
/// included) — both capped at the screen's visible size. The top edge stays
/// put; only the bottom edge moves.
@MainActor
final class ZoomToFitTests: XCTestCase {
    private func findPanes(in view: NSView) -> [FilePaneView] {
        var found: [FilePaneView] = []
        if let pane = view as? FilePaneView {
            found.append(pane)
        }
        for sub in view.subviews {
            found.append(contentsOf: findPanes(in: sub))
        }
        return found
    }

    private func findPane(in view: NSView) -> FilePaneView? {
        findPanes(in: view).first
    }

    /// The comparison's split — not the outer minimap split, which is an
    /// `ALSplitView` too and would be found first by a plain depth-first scan.
    /// The comparison split is the one whose panes wrap the file panes.
    private func findSplitView(in view: NSView) -> ALSplitView? {
        if let split = view as? ALSplitView,
           split.panes.contains(where: { $0 is FilePaneView
               || $0.subviews.contains { $0 is FilePaneView } }) {
            return split
        }
        for sub in view.subviews {
            if let found = findSplitView(in: sub) { return found }
        }
        return nil
    }

    private func makeController() -> MainWindowController {
        let controller = MainWindowController()
        _ = controller.mainViewController.view  // loadView + viewDidLoad → empty mode
        return controller
    }

    /// The uncapped window-frame height for `contentHeight` of content (adds
    /// the title bar). Mirrors `windowWillUseStandardFrame`'s conversion.
    private func rawFrameHeight(for contentHeight: CGFloat, window: NSWindow) -> CGFloat {
        window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 0, height: contentHeight)).height
    }

    /// The frame height `windowWillUseStandardFrame` picks for `contentHeight`:
    /// the content height capped at the screen's visible height.
    private func expectedFrameHeight(for contentHeight: CGFloat, window: NSWindow) -> CGFloat {
        let raw = rawFrameHeight(for: contentHeight, window: window)
        let screen = window.screen ?? NSScreen.main
        return min(raw, screen?.visibleFrame.height ?? raw)
    }

    /// The frame width `windowWillUseStandardFrame` picks for `contentWidth`:
    /// the content width capped at the screen's visible width.
    private func expectedFrameWidth(for contentWidth: CGFloat, window: NSWindow) -> CGFloat {
        let screen = window.screen ?? NSScreen.main
        return min(contentWidth, screen?.visibleFrame.width ?? contentWidth)
    }

    /// Close the panes and delete the temp files. Closing stops the file
    /// watchers: deleting first would fire the external-change prompt, and that
    /// `NSAlert.runModal()` would block the test's main thread forever.
    private func cleanup(_ mainVC: MainViewController, _ urls: URL...) {
        mainVC.windowModel.pane1.close()
        mainVC.windowModel.pane2.close()
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Launch width (§3.1)

    /// The launch window is one pane wide, not two: opening a single file is the
    /// common case, so the saved side-by-side arrangement must not double the
    /// width of a window that has no file in it yet.
    func testLaunchWidthFitsOnePaneEvenSideBySide() throws {
        let saved = LayoutSettings.isVertical
        defer { LayoutSettings.set(isVertical: saved) }
        LayoutSettings.set(isVertical: true)

        let url = try tempFile([UInt8](repeating: 0x41, count: 256))
        let controller = makeController()
        let mainVC = controller.mainViewController
        defer { cleanup(mainVC, url) }
        try mainVC.windowModel.pane1.open(url: url)
        mainVC.apply(mode: .singleFile)
        let pane = try XCTUnwrap(findPane(in: mainVC.view))

        // One pane's grid, or the toolbar's own width where that is wider — the
        // window must not open with its trailing toolbar items already in the
        // overflow menu (§24.4).
        XCTAssertEqual(MainViewController.launchContentWidth(),
                       max(pane.contentFitWidth, MainViewController.toolbarFitWidth), accuracy: 1,
                       "the launch width must be one pane's hex grid, floored at the toolbar's")
        XCTAssertLessThan(MainViewController.launchContentWidth(),
                          pane.contentFitWidth * 2,
                          "a side-by-side arrangement must not double the launch width")
    }

    /// The saved arrangement does not enter into the launch width at all — the
    /// window opens empty, so stacked and side-by-side give the same number.
    func testLaunchWidthIgnoresPaneArrangement() {
        let saved = LayoutSettings.isVertical
        defer { LayoutSettings.set(isVertical: saved) }

        LayoutSettings.set(isVertical: true)
        let sideBySide = MainViewController.launchContentWidth()
        LayoutSettings.set(isVertical: false)
        let stacked = MainViewController.launchContentWidth()

        XCTAssertEqual(sideBySide, stacked, accuracy: 0.5)
    }

    /// The window actually opens at that width, and at the height the landing
    /// screen fits in with the same air above the visible icon as below the
    /// last line — or the screen's visible height when that is less. Goes
    /// through `showWindow`, which is where the launch frame is settled:
    /// assigning the content view controller shrinks the window to the empty
    /// state's fitting size first.
    func testLaunchWindowUsesOnePaneWidthAndFitsTheLandingScreen() throws {
        let saved = LayoutSettings.isVertical
        defer { LayoutSettings.set(isVertical: saved) }
        LayoutSettings.set(isVertical: true)
        // AppKit saves a window's frame into `UserDefaults.standard` itself,
        // so this one key is not the app's to redirect — clearing it in the
        // test suite would leave the real saved frame to be restored.
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame MainWindow")

        let controller = makeController()
        let window = controller.window!
        controller.showWindow(nil)
        defer { window.orderOut(nil) }

        let screen = window.screen ?? NSScreen.main
        let expected = min(MainViewController.launchContentWidth(),
                           screen?.visibleFrame.width ?? .greatestFiniteMagnitude)
        XCTAssertEqual(window.frame.width, expected, accuracy: 1,
                       "the launch frame must use the one-pane width")
        let cap = (screen?.visibleFrame.height ?? 720).rounded(.down)
        XCTAssertLessThanOrEqual(window.frame.height, cap + 1, "capped at the screen's visible height")
        let empty = try XCTUnwrap(findEmptyView(in: window.contentView!))
        window.layoutIfNeeded()
        let content = empty.visibleContentFrameForTesting
        let above = empty.bounds.maxY - content.maxY
        let below = content.minY - empty.bounds.minY
        if window.frame.height < cap - 1 {
            XCTAssertEqual(above, EmptyStateView.launchMargin, accuracy: 2, "the air above the icon")
            XCTAssertEqual(below, EmptyStateView.launchMargin, accuracy: 2, "the air below the last line")
        } else {
            XCTAssertEqual(above, below, accuracy: 2, "a capped window still centres what is seen")
        }
    }

    /// When the release notes arrive after the window was sized, a window
    /// still at its fitted height fits them too; one the user has resized
    /// keeps their size.
    func testTheWindowFitsTheReleaseNotesThatArriveLaterUnlessResized() throws {
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame MainWindow")
        let controller = makeController()
        let window = controller.window!
        controller.showWindow(nil)
        defer { window.orderOut(nil) }
        let empty = try XCTUnwrap(findEmptyView(in: window.contentView!))
        let fitted = window.frame
        let notes = Array(repeating: "A long sentence about what this release reads that wraps.", count: 12)
            .joined(separator: " ")
        let release = Release(version: try XCTUnwrap(AppVersion("0.9.0")),
                              page: try XCTUnwrap(URL(string: "https://example.com")), body: notes)

        empty.showReleaseNotes(release, isRunningBuild: true)
        let cap = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 720
        if fitted.height < cap - 1 {
            XCTAssertGreaterThan(window.frame.height, fitted.height, "the notes are fitted in")
        }
        XCTAssertEqual(window.frame.maxY, fitted.maxY, accuracy: 1, "the top edge stays")

        let resized = NSRect(x: window.frame.minX, y: window.frame.minY, width: window.frame.width, height: 500)
        window.setFrame(resized, display: false)
        empty.showReleaseNotes(release, isRunningBuild: false)
        XCTAssertEqual(window.frame.height, 500, accuracy: 0.5, "a resized window keeps its size")
    }

    private func findEmptyView(in view: NSView) -> EmptyStateView? {
        if let empty = view as? EmptyStateView { return empty }
        for sub in view.subviews {
            if let found = findEmptyView(in: sub) { return found }
        }
        return nil
    }

    /// A restored frame's height gives way to the landing screen's: a window
    /// saved as tall as the screen opens at the fitted height, keeping its top
    /// edge.
    func testRestoredFrameHeightGivesWayToTheLandingScreen() throws {
        let controller = makeController()
        let window = controller.window!
        let visible = try XCTUnwrap(window.screen ?? NSScreen.main).visibleFrame
        window.setFrame(NSRect(x: visible.minX, y: visible.minY,
                               width: 800, height: visible.height), display: false)
        let top = window.frame.maxY

        controller.showWindow(nil)
        defer { window.orderOut(nil) }

        let fitted = try XCTUnwrap(controller.mainViewController.emptyStateFittingWindowHeight())
        XCTAssertEqual(window.frame.height, min(fitted, visible.height.rounded(.down)), accuracy: 1)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 1, "the top edge stays")
    }

    func testEmptyModeKeepsPreferredFrame() {
        let controller = makeController()
        let window = controller.window!
        let preferred = NSRect(x: 0, y: 0, width: 3000, height: 2000)

        let frame = controller.mainViewController.windowWillUseStandardFrame(window, defaultFrame: preferred)

        XCTAssertEqual(frame, preferred)
    }

    func testSingleFileFitsContentWidthAndHeight() throws {
        let url = try tempFile([UInt8](repeating: 0x41, count: 256))
        let controller = makeController()
        let window = controller.window!
        let mainVC = controller.mainViewController
        defer { cleanup(mainVC, url) }
        window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 700), display: false)
        let before = window.frame

        try mainVC.windowModel.pane1.open(url: url)
        mainVC.apply(mode: .singleFile)
        let pane = try XCTUnwrap(findPane(in: mainVC.view))

        let frame = mainVC.windowWillUseStandardFrame(window, defaultFrame: NSRect(x: 0, y: 0, width: 3000, height: 2000))

        XCTAssertEqual(frame.width, expectedFrameWidth(for: pane.contentFitWidth, window: window),
                       accuracy: 1, "width must fit the hex grid")
        XCTAssertEqual(frame.height, expectedFrameHeight(for: pane.contentFitHeight, window: window),
                       accuracy: 1, "height must fit the hex content")
        XCTAssertEqual(frame.origin.x, before.origin.x, accuracy: 0.5, "x must be kept")
        // The top edge stays put — the window grows/shrinks from the bottom.
        XCTAssertEqual(frame.origin.y + frame.height, before.origin.y + before.height, accuracy: 0.5)
        // Zoom-to-fit must be much smaller than the preferred (max) frame.
        XCTAssertLessThan(frame.width, 1000)
        XCTAssertLessThan(frame.height, 1000)

        // And the Zoom gesture actually routes through that delegate method:
        // the window is not on screen here, so `performZoom` applies the
        // standard frame synchronously instead of animating to it.
        window.performZoom(nil)
        XCTAssertEqual(window.frame.width, frame.width, accuracy: 1,
                       "performZoom applies the width the delegate returned")
        XCTAssertEqual(window.frame.height, frame.height, accuracy: 1,
                       "and its height")
        XCTAssertEqual(window.frame.origin.x, before.origin.x, accuracy: 0.5, "x must be kept")
    }

    /// A visible minimap panel shares the content area, so zoom-to-fit adds the
    /// panel's preferred width (plus the divider) to the hex grid's fit.
    func testZoomAccountsForVisibleMinimapPanel() throws {
        let url = try tempFile([UInt8](repeating: 0x41, count: 256))
        let controller = makeController()
        let window = controller.window!
        let mainVC = controller.mainViewController
        defer { cleanup(mainVC, url) }
        try mainVC.windowModel.pane1.open(url: url)
        mainVC.apply(mode: .singleFile)
        window.layoutIfNeeded()

        let split = mainVC.panelSplit
        let pane = try XCTUnwrap(findPane(in: mainVC.view))

        // Without the panel the fitted width is just the hex grid.
        let hidden = mainVC.windowWillUseStandardFrame(
            window, defaultFrame: NSRect(x: 0, y: 0, width: 3000, height: 2000))
        XCTAssertEqual(hidden.width, expectedFrameWidth(for: pane.contentFitWidth, window: window),
                       accuracy: 1, "a hidden panel adds nothing")

        // Shown at its preferred width, the fit grows by panel + divider.
        mainVC.surface.minimap.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        let shown = mainVC.windowWillUseStandardFrame(
            window, defaultFrame: NSRect(x: 0, y: 0, width: 3000, height: 2000))
        let expected = pane.contentFitWidth + mainVC.minimapPreferredPanelWidth + split.dividerThickness
        XCTAssertEqual(shown.width, expectedFrameWidth(for: expected, window: window),
                       accuracy: 1, "the fit makes room for the visible panel")
    }

    /// With a fragment panel up the window is fitted around the panel: its dump's
    /// grid and its own map, not the tab's.
    func testZoomAccountsForTheFragmentPanelsMinimap() throws {
        let url = try tempFile([UInt8](repeating: 0x41, count: 256))
        let controller = makeController()
        let window = controller.window!
        let mainVC = controller.mainViewController
        defer {
            for id in mainVC.fragments.dock.panels { mainVC.fragments.close(id, animated: false) }
            cleanup(mainVC, url)
        }
        try mainVC.windowModel.pane1.open(url: url)
        mainVC.apply(mode: .singleFile)
        window.layoutIfNeeded()
        let id = try XCTUnwrap(mainVC.openFragment([UInt8](repeating: 0x42, count: 64),
                                                   named: "part", animated: false))
        let surface = try XCTUnwrap(mainVC.fragments.surface(id))
        let part = try XCTUnwrap(surface.paneViewsInMapOrder().first)
        window.layoutIfNeeded()
        let defaultFrame = NSRect(x: 0, y: 0, width: 3000, height: 2000)

        let hidden = mainVC.windowWillUseStandardFrame(window, defaultFrame: defaultFrame)
        XCTAssertEqual(hidden.width, expectedFrameWidth(for: part.contentFitWidth, window: window),
                       accuracy: 1, "fitted around the part, with no map")

        surface.minimap.setPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        let shown = mainVC.windowWillUseStandardFrame(window, defaultFrame: defaultFrame)
        let expected = part.contentFitWidth + surface.minimapPreferredPanelWidth
            + surface.panelSplit.dividerThickness
        XCTAssertEqual(shown.width, expectedFrameWidth(for: expected, window: window),
                       accuracy: 1, "and with room for the panel's map")
    }

    /// The height follows the panel too: its own title bar, rows and status bar,
    /// the peek of the tab's header above it, and the dock below.
    func testZoomHeightFitsTheFragmentPanelWithItsHeaderAndDock() throws {
        let url = try tempFile([UInt8](repeating: 0x41, count: 256))
        let controller = makeController()
        let window = controller.window!
        let mainVC = controller.mainViewController
        defer {
            for id in mainVC.fragments.dock.panels { mainVC.fragments.close(id, animated: false) }
            cleanup(mainVC, url)
        }
        try mainVC.windowModel.pane1.open(url: url)
        mainVC.apply(mode: .singleFile)
        window.layoutIfNeeded()
        let id = try XCTUnwrap(mainVC.openFragment([UInt8](repeating: 0x42, count: 64),
                                                   named: "part", animated: false))
        let part = try XCTUnwrap(mainVC.fragments.surface(id)?.paneViewsInMapOrder().first)
        window.layoutIfNeeded()

        let frame = mainVC.windowWillUseStandardFrame(
            window, defaultFrame: NSRect(x: 0, y: 0, width: 3000, height: 2000))
        let content = part.contentFitHeight + FragmentPanelLayout.parentPeek + FragmentDockStrip.height
        XCTAssertEqual(frame.height, expectedFrameHeight(for: content, window: window), accuracy: 1)
    }

    /// The tool panel makes the same claim on the leading edge that the minimap
    /// makes on the trailing one, so zoom-to-fit adds it too: fitting the hex
    /// grids alone zooms the window to a width the dump does not actually get
    /// (`Design/TOOL_MODULES_PLAN.md`).
    func testZoomAccountsForTheToolPanel() throws {
        installToolStubs()
        let (suite, store) = isolatedDefaults(for: self)
        ToolController.defaults = store
        defer {
            discardIsolatedDefaults(suite, store)
            ToolController.defaults = .standard
        }
        let url = try tempFile([UInt8](repeating: 0x41, count: 256))
        let controller = makeController()
        let window = controller.window!
        let mainVC = controller.mainViewController
        defer { cleanup(mainVC, url) }
        try mainVC.windowModel.pane1.open(url: url)
        mainVC.apply(mode: .singleFile)
        window.layoutIfNeeded()

        let split = mainVC.panelSplit
        let pane = try XCTUnwrap(findPane(in: mainVC.view))
        let closed = mainVC.windowWillUseStandardFrame(
            window, defaultFrame: NSRect(x: 0, y: 0, width: 3000, height: 2000))
        XCTAssertEqual(closed.width, expectedFrameWidth(for: pane.contentFitWidth, window: window),
                       accuracy: 1, "no tool-module open, so nothing is added")

        mainVC.tools.activate(StubToolA.identifier, animated: false)
        window.layoutIfNeeded()
        XCTAssertTrue(mainVC.tools.isPanelVisible, "the stub opened the panel")
        let panelWidth = mainVC.toolPanelWidth()
        XCTAssertGreaterThan(panelWidth, 0, "and it has a width")

        let open = mainVC.windowWillUseStandardFrame(
            window, defaultFrame: NSRect(x: 0, y: 0, width: 3000, height: 2000))
        let expected = pane.contentFitWidth + panelWidth + split.dividerThickness
        XCTAssertEqual(open.width, expectedFrameWidth(for: expected, window: window),
                       accuracy: 1, "the fit makes room for the panel and its divider")
    }

    /// The width counted is the one the panel *has*, not the one the
    /// tool-module asked for: zoom fits the window around what is on screen,
    /// and the user may have dragged the panel wider.
    func testZoomFollowsADraggedToolPanel() throws {
        installToolStubs()
        let (suite, store) = isolatedDefaults(for: self)
        ToolController.defaults = store
        defer {
            discardIsolatedDefaults(suite, store)
            ToolController.defaults = .standard
        }
        let url = try tempFile([UInt8](repeating: 0x41, count: 256))
        let controller = makeController()
        let window = controller.window!
        let mainVC = controller.mainViewController
        defer { cleanup(mainVC, url) }
        try mainVC.windowModel.pane1.open(url: url)
        mainVC.apply(mode: .singleFile)
        window.setContentSize(NSSize(width: 1400, height: 700))
        window.layoutIfNeeded()
        mainVC.tools.activate(StubToolA.identifier, animated: false)
        window.layoutIfNeeded()

        let wider = StubToolA.preferredPanelWidth + 120
        mainVC.setToolPanelWidth(wider, animated: false)
        window.layoutIfNeeded()
        let dragged = mainVC.toolPanelWidth()
        XCTAssertEqual(dragged, wider, accuracy: 1, "the panel took the wider width")

        let split = mainVC.panelSplit
        let pane = try XCTUnwrap(findPane(in: mainVC.view))
        let frame = mainVC.windowWillUseStandardFrame(
            window, defaultFrame: NSRect(x: 0, y: 0, width: 3000, height: 2000))
        let expected = pane.contentFitWidth + dragged + split.dividerThickness
        XCTAssertEqual(frame.width, expectedFrameWidth(for: expected, window: window),
                       accuracy: 1, "the fit follows the width the panel has")
    }

    /// Side-by-side: the width must fit both grids plus the divider, the height
    /// the taller of the two files.
    func testComparisonVerticalFitsBothPanes() throws {
        AppDefaults.store.set(true, forKey: "ComparisonPaneLayoutIsVertical")
        let url1 = try tempFile([UInt8](repeating: 0x41, count: 4096))
        let url2 = try tempFile([UInt8](repeating: 0x42, count: 512))
        let controller = makeController()
        let window = controller.window!
        let mainVC = controller.mainViewController
        defer { cleanup(mainVC, url1, url2) }
        window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 700), display: false)

        try mainVC.windowModel.pane1.open(url: url1)
        try mainVC.windowModel.pane2.open(url: url2)
        mainVC.apply(mode: .comparison)
        let panes = findPanes(in: mainVC.view)
        XCTAssertEqual(panes.count, 2)
        let divider = try XCTUnwrap(findSplitView(in: mainVC.view))
        let expectedWidth = panes[0].contentFitWidth + panes[1].contentFitWidth + divider.dividerThickness
        let expectedHeight = max(panes[0].contentFitHeight, panes[1].contentFitHeight)

        let frame = mainVC.windowWillUseStandardFrame(window, defaultFrame: NSRect(x: 0, y: 0, width: 3000, height: 2000))

        XCTAssertEqual(frame.width, expectedFrameWidth(for: expectedWidth, window: window),
                       accuracy: 1, "width must fit both grids plus the divider")
        XCTAssertEqual(frame.height, expectedFrameHeight(for: expectedHeight, window: window),
                       accuracy: 1, "height must fit the taller of the two files")
    }

    /// Stacked: both panes share the full width, so the width fits the wider
    /// grid; the height still targets the taller file's content.
    func testComparisonStackedFitsBothPanes() throws {
        AppDefaults.store.set(false, forKey: "ComparisonPaneLayoutIsVertical")
        let url1 = try tempFile([UInt8](repeating: 0x41, count: 4096))
        let url2 = try tempFile([UInt8](repeating: 0x42, count: 512))
        let controller = makeController()
        let window = controller.window!
        let mainVC = controller.mainViewController
        defer { cleanup(mainVC, url1, url2) }
        window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 700), display: false)

        try mainVC.windowModel.pane1.open(url: url1)
        try mainVC.windowModel.pane2.open(url: url2)
        mainVC.apply(mode: .comparison)
        let panes = findPanes(in: mainVC.view)
        XCTAssertEqual(panes.count, 2)
        let expectedWidth = max(panes[0].contentFitWidth, panes[1].contentFitWidth)
        let expectedHeight = max(panes[0].contentFitHeight, panes[1].contentFitHeight)

        let frame = mainVC.windowWillUseStandardFrame(window, defaultFrame: NSRect(x: 0, y: 0, width: 3000, height: 2000))

        XCTAssertEqual(frame.width, expectedFrameWidth(for: expectedWidth, window: window),
                       accuracy: 1, "width must fit the wider grid")
        XCTAssertEqual(frame.height, expectedFrameHeight(for: expectedHeight, window: window),
                       accuracy: 1, "height must fit the taller of the two files")
    }

    /// When the content is taller than the screen, the height caps at the
    /// screen's visible height instead of growing off-screen.
    func testTallContentCapsAtScreenHeight() throws {
        let url = try tempFile([UInt8](repeating: 0x41, count: 256 * 1024))
        let controller = makeController()
        let window = controller.window!
        let mainVC = controller.mainViewController
        defer { cleanup(mainVC, url) }
        window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 700), display: false)

        try mainVC.windowModel.pane1.open(url: url)
        mainVC.apply(mode: .singleFile)
        let pane = try XCTUnwrap(findPane(in: mainVC.view))
        let uncapped = rawFrameHeight(for: pane.contentFitHeight, window: window)

        let frame = mainVC.windowWillUseStandardFrame(window, defaultFrame: NSRect(x: 0, y: 0, width: 3000, height: 2000))

        let screen = window.screen ?? NSScreen.main
        if let screen {
            XCTAssertGreaterThan(uncapped, screen.visibleFrame.height,
                                 "precondition: the content must exceed the screen")
            XCTAssertEqual(frame.height, screen.visibleFrame.height, accuracy: 1,
                           "the height must cap at the screen's visible height")
        } else {
            XCTAssertEqual(frame.height, uncapped, accuracy: 1,
                           "no screen to cap at — the content height is used")
        }
    }
}
